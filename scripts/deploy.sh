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
#   --reload       load the new module now: restarts the awg-quick@ units
#                  that are up, refuses if other amneziawg interfaces exist
#   --force-reload like --reload, but also tears down other interfaces
#   --no-deps      do not install packages
#
# The DKMS version is 1.0.0+g<commit>, so 'dkms status' shows which commit
# is built, upgrades do not need --force, and old versions are removed.
#
# Can be run straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/freetushkan/amneziawg-linux-kernel-module/master/scripts/deploy.sh | bash -s -- install

set -euo pipefail

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
	--force-reload) RELOAD=2 ;;
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
		[ "$flavor" != "$k" ] && echo "linux-headers-$flavor"
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
	pkgs=$(dpkg-query -W -f '${Package} ${Status}\n' amneziawg amneziawg-dkms 2>/dev/null |
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
	dkms status -m $NAME 2>/dev/null |
		sed -n "s|^${NAME}[/,] *\([^,:]*\).*|\1|p" | sort -u
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

	local units ifaces managed=() other=() i
	units=$(systemctl list-units --plain --no-legend --state=active 'awg-quick@*.service' 2>/dev/null |
		awk '{print $1}')
	ifaces=$(ip -o link show type $NAME 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
	for i in $ifaces; do
		if echo "$units" | grep -qx "awg-quick@$i.service"; then managed+=("$i"); else other+=("$i"); fi
	done
	if [ ${#other[@]} -gt 0 ] && [ $RELOAD != 2 ]; then
		die "interfaces not managed by awg-quick@: ${other[*]}; bring them down or use --force-reload"
	fi

	log "Reloading the module"
	for i in "${managed[@]}"; do systemctl stop "awg-quick@$i" && ok "stopped awg-quick@$i"; done
	for i in "${other[@]}"; do ip link del "$i" && warn "deleted $i"; done
	modprobe -r $NAME
	modprobe $NAME
	for i in "${managed[@]}"; do systemctl start "awg-quick@$i" && ok "started awg-quick@$i"; done
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
		for v in $(ip -o link show type $NAME 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1); do
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
