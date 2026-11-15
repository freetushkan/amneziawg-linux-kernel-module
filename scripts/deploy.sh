#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build and install the amneziawg kernel module from this repository with
# DKMS, for every installed kernel that has headers.
#
#   deploy.sh install   [options]   clone (if needed), build, install
#   deploy.sh update    [options]   fetch, reset to --ref, rebuild, install
#   deploy.sh uninstall             remove every DKMS version of the module
#   deploy.sh status                what is installed, built and loaded
#
# Options:
#   --repo URL     repository to clone (default: origin of this checkout, or
#                  https://github.com/freetushkan/amneziawg-linux-kernel-module)
#   --ref REF      branch, tag or commit (default: master, or the branch the
#                  checkout is on)
#   --dir DIR      where the checkout lives
#                  (default: /usr/src/amneziawg-linux-kernel-module)
#   --compat N     set the 'compat' module parameter persistently (0, 1, 2)
#   --reload       load the new module now. Interfaces come back the way they
#                  were brought up: awg-quick@ units are restarted, awg-quick
#                  configs in /etc/amnezia/amneziawg are taken down and up, and
#                  other interfaces are saved (awg settings, addresses, routes)
#                  and recreated. Runs detached, so an SSH session through one
#                  of the tunnels may freeze for a moment but the reload
#                  finishes even if it drops.
#   --no-deps      do not install packages
#
# The DKMS version is 1.0.0+g<commit>, so 'dkms status' shows which commit
# is built, upgrades do not need --force, and old versions are removed.
#
# Can be run straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/freetushkan/amneziawg-linux-kernel-module/master/scripts/deploy.sh | bash -s -- install

set -Eeuo pipefail

NAME=amneziawg
BASE_VERSION=1.0.0
DEFAULT_REPO=https://github.com/freetushkan/amneziawg-linux-kernel-module
DIR=/usr/src/amneziawg-linux-kernel-module
REPO=
REF=
COMPAT=
RELOAD=0
DEPS=1

if [ -t 1 ]; then B=$'\e[1m' R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' N=$'\e[0m'; else B='' R='' G='' Y='' N=''; fi
log()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'die "line $LINENO: \"$BASH_COMMAND\" failed"' ERR

usage() { sed -n '4,25p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------- arguments

CMD=${1:-}
[ -n "$CMD" ] || usage 1
shift
while [ $# -gt 0 ]; do
	case $1 in
	--repo) REPO=${2:?}; shift ;;
	--ref) REF=${2:?}; shift ;;
	--dir) DIR=${2:?}; shift ;;
	--compat) COMPAT=${2:?}; shift ;;
	--reload) RELOAD=1 ;;
	--force-reload) RELOAD=1 ;; # older name of --reload
	--no-deps) DEPS=0 ;;
	-h|--help) usage 0 ;;
	*) die "unknown option: $1" ;;
	esac
	shift
done
case $COMPAT in ''|0|1|2) ;; *) die "--compat must be 0, 1 or 2" ;; esac
[ "$(id -u)" = 0 ] || die "run as root"

exec 9>/run/lock/$NAME-deploy.lock
flock -n 9 || die "another deploy is running"

# ---------------------------------------------------------------- helpers

# Headers to install for a kernel release on Debian/Ubuntu/Proxmox: the
# exact package for the running kernel, plus the meta package of its flavor
# so that future kernels come with headers and DKMS builds for them too.
header_packages() {
	local k=$1 flavor
	case $k in
	*-pve) echo "proxmox-headers-$k proxmox-default-headers" ;;
	*)
		flavor=$(echo "$k" | sed 's/^[0-9.]*-[0-9]*-//')
		echo "linux-headers-$k"
		if [ "$flavor" != "$k" ]; then echo "linux-headers-$flavor"; fi
		;;
	esac
}

install_deps() {
	[ $DEPS = 1 ] || return 0
	if ! command -v apt-get >/dev/null; then
		warn "not a Debian-like system: make sure git, make, gcc, dkms and kernel headers are installed"
		return 0
	fi
	log "Installing build dependencies"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq --no-install-recommends git build-essential make dkms >/dev/null
	local p
	for p in $(header_packages "$(uname -r)"); do
		if apt-get install -y -qq --no-install-recommends "$p" >/dev/null 2>&1; then
			ok "$p"
		else
			warn "could not install $p"
		fi
	done
	# Packaged builds of the module would fight with ours over the same name.
	local pkgs
	pkgs=$({ dpkg-query -W -f '${Package} ${Status}\n' amneziawg amneziawg-dkms 2>/dev/null || true; } |
		awk '/ installed$/ {print $1}')
	if [ -n "$pkgs" ]; then
		log "Removing packaged module: $pkgs"
		apt-get purge -y -qq $pkgs >/dev/null
	fi
}

# On update: only fetch headers for the running kernel if they are missing,
# e.g. after booting into a kernel that arrived without them.
ensure_running_headers() {
	local k p
	k=$(uname -r)
	kernel_has_headers "$k" && return 0
	[ $DEPS = 1 ] && command -v apt-get >/dev/null || return 0
	log "Installing headers for $k"
	apt-get update -qq
	for p in $(header_packages "$k"); do
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$p" \
			>/dev/null 2>&1 && ok "$p" || warn "could not install $p"
	done
}

dkms_versions() { # every DKMS version of the module, one per line
	{ dkms status -m $NAME 2>/dev/null || true; } |
		sed -n "s|^${NAME}[/,] *\([^,:]*\).*|\1|p" | sort -u
}

interfaces() {
	{ ip -o link show type $NAME 2>/dev/null || true; } | awk -F': ' '{print $2}' | cut -d@ -f1
}

kernel_has_headers() { [ -e "/lib/modules/$1/build/Makefile" ]; }

srcversion_of() { modinfo -k "$1" -F srcversion $NAME 2>/dev/null || true; }

# ---------------------------------------------------------------- source

repo_default() {
	if [ -z "$REPO" ]; then
		if [ -d "$DIR/.git" ]; then
			REPO=$(git -C "$DIR" remote get-url origin 2>/dev/null || echo "$DEFAULT_REPO")
		else
			REPO=$DEFAULT_REPO
		fi
	fi
	if [ -z "$REF" ]; then
		REF=$(git -C "$DIR" symbolic-ref --short -q HEAD 2>/dev/null || echo master)
	fi
}

fetch_source() {
	repo_default
	if [ -d "$DIR/.git" ]; then
		log "Updating $DIR to $REF"
		git -C "$DIR" remote set-url origin "$REPO"
		git -C "$DIR" fetch -q --prune --tags origin
	else
		log "Cloning $REPO into $DIR"
		rm -rf "$DIR"
		git clone -q "$REPO" "$DIR"
	fi
	local target
	if git -C "$DIR" rev-parse -q --verify "origin/$REF^{commit}" >/dev/null; then
		target=origin/$REF
		git -C "$DIR" checkout -q -B "$REF" "$target"
	elif git -C "$DIR" rev-parse -q --verify "$REF^{commit}" >/dev/null; then
		target=$REF
		git -C "$DIR" checkout -q --detach "$target"
	else
		die "no such branch, tag or commit: $REF"
	fi
	git -C "$DIR" reset -q --hard "$target"
	git -C "$DIR" clean -qfdx
	ok "$(git -C "$DIR" log -1 --format='%h %s')"
}

# ---------------------------------------------------------------- build

build_install() {
	local commit version src k built=0 failed=0 running
	commit=$(git -C "$DIR" rev-parse --short=10 HEAD)
	version=$BASE_VERSION+g$commit
	src=/usr/src/$NAME-$version
	running=$(uname -r)

	log "DKMS version $version"
	if ! dkms_versions | grep -qxF "$version"; then
		rm -rf "$src"
		make -s -C "$DIR/src" dkms-install DKMSDIR="$src" >/dev/null
		# REMAKE_INITRD is deprecated, and the module is not needed early.
		sed -i -e "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$version\"/" \
			-e '/^REMAKE_INITRD=/d' "$src/dkms.conf"
		dkms add -m $NAME -v "$version" >/dev/null
	fi

	for k in /lib/modules/*/; do
		k=$(basename "$k")
		if ! kernel_has_headers "$k"; then
			[ "$k" = "$running" ] && warn "$k (running): no headers, skipped" ||
				warn "$k: no headers, skipped"
			continue
		fi
		if dkms install -m $NAME -v "$version" -k "$k" --force >/tmp/$NAME-dkms.log 2>&1; then
			ok "$k"
			built=$((built + 1))
		else
			warn "$k: build failed, see /var/lib/dkms/$NAME/$version/build/make.log"
			tail -n 5 /tmp/$NAME-dkms.log | sed 's/^/      /' >&2
			failed=$((failed + 1))
			[ "$k" = "$running" ] && failed=$((failed + 100))
		fi
	done
	kernel_has_headers "$running" ||
		warn "running kernel $running has no headers: the module will only be available after booting a kernel listed above"
	[ $built -gt 0 ] || die "the module was not built for any kernel"

	# Drop older versions only once the new one is in place.
	local v
	for v in $(dkms_versions); do
		[ "$v" = "$version" ] && continue
		dkms remove -m $NAME -v "$v" --all >/dev/null 2>&1 || true
		rm -rf "/usr/src/$NAME-$v"
		ok "removed old version $v"
	done
	[ $failed -lt 100 ] || die "the module did not build for the running kernel $running"
}

# ---------------------------------------------------------------- runtime

set_compat() {
	[ -n "$COMPAT" ] || return 0
	echo "options $NAME compat=$COMPAT" > /etc/modprobe.d/$NAME.conf
	[ -w /sys/module/$NAME/parameters/compat ] &&
		echo "$COMPAT" > /sys/module/$NAME/parameters/compat
	ok "compat=$COMPAT (/etc/modprobe.d/$NAME.conf)"
}

loaded_is_current() {
	[ -e /sys/module/$NAME/srcversion ] || return 1
	[ "$(cat /sys/module/$NAME/srcversion)" = "$(srcversion_of "$(uname -r)")" ]
}

# Snapshot of an interface not managed by awg-quick, to recreate it after the
# module is reloaded: awg settings, addresses, MTU, state and routes in all
# tables. Rules, nftables/iptables and the like refer to the interface by
# name and survive by themselves.
snapshot_interface() { # $1 = interface, $2 = directory
	local i=$1 S=$2/$1
	mkdir -p "$S"
	awg showconf "$i" > "$S/awg.conf"
	ip -o link show dev "$i" | sed -n 's/.* mtu \([0-9]*\).*/\1/p' > "$S/mtu"
	ip -o link show dev "$i" | grep -q '[<,]UP[,>]' && touch "$S/up"
	ip -o addr show dev "$i" | awk '{
		for (k = 1; k <= NF; k++) if ($k == "inet" || $k == "inet6") {
			a = $(k + 1); if ($(k + 2) == "peer") a = a " peer " $(k + 3)
			if (a !~ /^fe80/) print ($k == "inet6" ? "-6" : "-4"), a
		} }' > "$S/addr"
	{
		ip -4 route show table all dev "$i" | sed 's/^/-4 /'
		ip -6 route show table all dev "$i" | sed 's/^/-6 /'
	} | grep -vE '^-[46] (local|broadcast|multicast|anycast) |proto kernel|^-6 fe80::' > "$S/routes" || true
}

# Runs detached from the terminal, so it finishes and brings the tunnels back
# even if the SSH session it was started from goes through one of them and
# drops meanwhile.
reload_worker() {
	cat <<'EOS'
#!/bin/bash
D=$1 NAME=amneziawg rc=0
exec >>"$D/log" 2>&1 </dev/null
trap '' HUP
say() { echo "$*"; }
restore() {
	local i=$1 S=$D/$1 fam r
	ip link add "$i" type $NAME || { say "  ! $i: could not recreate"; rc=1; return; }
	awg setconf "$i" "$S/awg.conf" || { say "  ! $i: awg setconf failed"; rc=1; }
	[ -s "$S/mtu" ] && ip link set "$i" mtu "$(cat "$S/mtu")"
	while read -r fam r; do ip "$fam" addr add $r dev "$i" || rc=1; done < "$S/addr"
	[ -e "$S/up" ] && ip link set "$i" up
	while read -r fam r; do
		ip "$fam" route add $r dev "$i" 2>/dev/null ||
			ip "$fam" route replace $r dev "$i" 2>/dev/null || { say "  ! $i: route $r"; rc=1; }
	done < "$S/routes"
	say "  ✓ $i restored"
}
while read -r how i; do
	case $how in
	unit) systemctl stop "awg-quick@$i" && say "  ✓ awg-quick@$i stopped" ;;
	quick) awg-quick down "$i" >/dev/null 2>&1 && say "  ✓ awg-quick down $i" || ip link del "$i" ;;
	snap) ip link del "$i" ;;
	esac
done < "$D/plan"
# Only this module: 'modprobe -r' would also try its dependencies and fail
# when WireGuard uses them, although this module is gone. Interfaces are
# torn down asynchronously, so give the references a moment to drop.
unload() {
	local t
	for t in 1 2 3 4 5 6 7 8 9 10; do
		[ -e /sys/module/$NAME ] || return 0
		rmmod $NAME 2>/dev/null && return 0
		sleep 0.5
	done
	[ ! -e /sys/module/$NAME ]
}
if unload; then
	modprobe $NAME && say "  ✓ module reloaded" || { say "  ! modprobe $NAME failed"; rc=1; }
else
	say "  ! the module is still in use, not reloaded"; rc=1
fi
# Bring everything back whatever happened above.
[ -e /sys/module/$NAME ] || modprobe $NAME || { say "  ! the module cannot be loaded at all"; rc=1; }
while read -r how i; do
	case $how in
	unit) systemctl start "awg-quick@$i" && say "  ✓ awg-quick@$i started" ||
		{ say "  ! awg-quick@$i did not start"; rc=1; } ;;
	quick) awg-quick up "$i" >/dev/null 2>"$D/$i.err" && say "  ✓ awg-quick up $i" ||
		{ say "  ! awg-quick up $i: $(tail -n 1 "$D/$i.err")"; rc=1; } ;;
	snap) restore "$i" ;;
	esac
done < "$D/plan"
say "@@done rc=$rc"
EOS
}

reload_module() {
	if [ -z "$(srcversion_of "$(uname -r)")" ]; then
		warn "no module for the running kernel $(uname -r), nothing to load"
		return
	fi
	if [ ! -e /sys/module/$NAME ]; then
		modprobe $NAME && ok "module loaded"
		return
	fi
	if loaded_is_current; then
		ok "loaded module is already this build"
		return
	fi
	if [ $RELOAD = 0 ]; then
		warn "the loaded module is the previous build: run with --reload or reboot to switch"
		return
	fi

	local D=/run/$NAME-reload units i via ssh_dev n
	units=$({ systemctl list-units --plain --no-legend --state=active 'awg-quick@*.service' 2>/dev/null || true; } |
		awk '{print $1}')
	rm -rf "$D"
	mkdir -m 700 "$D"
	: > "$D/plan"
	log "Reloading the module"
	for i in $(interfaces); do
		if echo "$units" | grep -qx "awg-quick@$i.service"; then
			echo "unit $i" >> "$D/plan"; ok "$i: awg-quick@$i"
		elif [ -e "/etc/amnezia/amneziawg/$i.conf" ]; then
			echo "quick $i" >> "$D/plan"; ok "$i: awg-quick, /etc/amnezia/amneziawg/$i.conf"
		else
			command -v awg >/dev/null || die "$i is not managed by awg-quick and awg is not installed to save it"
			snapshot_interface "$i" "$D"
			echo "snap $i" >> "$D/plan"
			ok "$i: saved ($(wc -l < "$D/$i/addr") addresses, $(wc -l < "$D/$i/routes") routes)"
		fi
	done
	if [ -n "${SSH_CONNECTION:-}" ]; then
		ssh_dev=$(ip route get "${SSH_CONNECTION%% *}" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
		if grep -qx "[a-z]* $ssh_dev" "$D/plan" 2>/dev/null; then
			warn "this SSH session goes through $ssh_dev: it may freeze for a few seconds;" \
				"the reload carries on if it drops (log: $D/log)"
		fi
	fi

	reload_worker > "$D/reload.sh"
	: > "$D/log"
	if command -v systemd-run >/dev/null && [ -d /run/systemd/system ]; then
		via=systemd-run
		systemd-run --quiet --collect --unit="$NAME-reload-$$" "$(command -v bash)" "$D/reload.sh" "$D"
	else
		via=setsid
		setsid -f bash "$D/reload.sh" "$D" </dev/null >/dev/null 2>&1
	fi

	# Follow the log; the worker does not depend on this terminal.
	n=0
	for _ in $(seq 1 240); do
		sed -n "$((n + 1)),\$p" "$D/log" | grep -v '^@@done' || true
		n=$(wc -l < "$D/log")
		grep -q '^@@done' "$D/log" && break
		sleep 0.5
	done
	if ! grep -q '^@@done rc=0' "$D/log"; then
		grep -q '^@@done' "$D/log" ||
			die "the reload ($via) has not finished in 2 minutes, see $D/log"
		die "the reload had problems, see $D/log and $D/plan"
	fi
	rm -rf "$D"
	loaded_is_current && ok "running the new build" || warn "loaded module does not match the build"
}

# ---------------------------------------------------------------- commands

status() {
	local v k s
	log "Source"
	if [ -d "$DIR/.git" ]; then
		ok "$DIR: $(git -C "$DIR" symbolic-ref --short -q HEAD || echo detached) $(git -C "$DIR" log -1 --format='%h %s')"
	else
		warn "$DIR: no checkout"
	fi
	log "DKMS"
	dkms status -m $NAME 2>/dev/null | sed 's/^/  /'
	[ -n "$(dkms_versions)" ] || warn "not installed"
	log "Kernels"
	for k in /lib/modules/*/; do
		k=$(basename "$k")
		s=$(srcversion_of "$k")
		if [ -n "$s" ]; then ok "$k: srcversion $s"
		elif kernel_has_headers "$k"; then warn "$k: headers present, module missing"
		else warn "$k: no headers, no module"
		fi
	done
	log "Loaded"
	if [ -e /sys/module/$NAME ]; then
		if loaded_is_current; then ok "current build"; else warn "outdated build: reload or reboot"; fi
		ok "compat=$(cat /sys/module/$NAME/parameters/compat 2>/dev/null || echo n/a)"
		for v in $(interfaces); do
			ok "interface $v"
		done
	else
		warn "not loaded"
	fi
}

uninstall() {
	local v
	log "Removing DKMS builds"
	for v in $(dkms_versions); do
		dkms remove -m $NAME -v "$v" --all >/dev/null 2>&1 || true
		rm -rf "/usr/src/$NAME-$v"
		ok "removed $v"
	done
	rm -f /etc/modprobe.d/$NAME.conf
	[ -e /sys/module/$NAME ] && warn "the module is still loaded until reboot or 'modprobe -r $NAME'"
	ok "the checkout in $DIR is kept"
}

# One compound command, read in full before it runs: the checkout this file
# lives in may be rewritten by fetch_source().
{
	case $CMD in
	install|update)
		if [ "$CMD" = install ]; then install_deps; else ensure_running_headers; fi
		fetch_source
		build_install
		set_compat
		reload_module
		;;
	uninstall) uninstall ;;
	status) status ;;
	*) usage 1 ;;
	esac
	exit 0
}
