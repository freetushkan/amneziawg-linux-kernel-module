#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Run src/tests/compat.sh in a throwaway VM booted with a stock Ubuntu kernel,
# against two kinds of clients:
#
#   strict  clients run upstream amneziawg built as a second module ("awgup",
#           own genetlink family): they accept only their own format and do
#           not announce themselves;
#   own     clients run this module.
#
# Everything the VM needs is built here: this module, the upstream module,
# awg tools for both genetlink families, and an initramfs with busybox. The
# kernel comes from the Ubuntu archive, so this runs on any Ubuntu host with
# apt (GitHub Actions ubuntu-24.04 included), with KVM when /dev/kvm is
# usable and in (slow) emulation otherwise.
#
#   run.sh [options]
#     --kernel K        Ubuntu kernel release (7.0.0-42-generic), or 'ga' for
#                       the newest 6.8 (noble GA), 'hwe' for the newest one
#                       in the archive (default: hwe)
#     --upstream URL    upstream repository for the strict clients
#     --upstream-ref R  upstream branch, tag or commit (default: master)
#     --tools URL       amneziawg-tools repository
#     --tools-ref R     (default: master)
#     --work DIR        build directory (default: ./vm-work)
#     --report FILE     markdown report (default: DIR/report.md)
#     --tests "1 2 .."  subset of compat.sh tests
#     --no-deps         do not install packages
#
# Exit status: 0 if every test passed (KNOWN upstream issues are allowed).

set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../.." && pwd)
KERNEL=hwe
UPSTREAM=https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
UPSTREAM_REF=master
TOOLS=https://github.com/amnezia-vpn/amneziawg-tools
TOOLS_REF=master
WORK=$PWD/vm-work
REPORT=
TESTS="1 2 3 4 5"
DEPS=1

log() { printf '\e[1m==>\e[0m %s\n' "$*"; }
die() { printf '\e[31merror:\e[0m %s\n' "$*" >&2; exit 2; }
trap 'die "line $LINENO: \"$BASH_COMMAND\" failed"' ERR

while [ $# -gt 0 ]; do
	case $1 in
	--kernel) KERNEL=${2:?}; shift ;;
	--upstream) UPSTREAM=${2:?}; shift ;;
	--upstream-ref) UPSTREAM_REF=${2:?}; shift ;;
	--tools) TOOLS=${2:?}; shift ;;
	--tools-ref) TOOLS_REF=${2:?}; shift ;;
	--work) WORK=${2:?}; shift ;;
	--report) REPORT=${2:?}; shift ;;
	--tests) TESTS=${2:?}; shift ;;
	--no-deps) DEPS=0 ;;
	-h|--help) sed -n '4,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1" ;;
	esac
	shift
done
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
REPORT=${REPORT:-$WORK/report.md}
SUDO=; [ "$(id -u)" = 0 ] || SUDO=sudo

# ------------------------------------------------------------------ kernel

resolve_kernel() {
	local pattern
	case $1 in
	ga) pattern='^linux-image-unsigned-6\.8\.0-[0-9]+-generic$' ;;
	hwe) pattern='^linux-image-unsigned-[0-9.]+-[0-9]+-generic$' ;;
	*) echo "$1"; return ;;
	esac
	apt-cache search --names-only "$pattern" | awk '{print $1}' |
		sed 's/^linux-image-unsigned-//' | sort -V | tail -n 1
}

if [ $DEPS = 1 ]; then
	log "Installing host packages"
	$SUDO apt-get update -qq
fi
K=$(resolve_kernel "$KERNEL")
[ -n "$K" ] || die "no kernel matches '$KERNEL'"
log "Kernel $K"

if [ $DEPS = 1 ]; then
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
		build-essential git kmod cpio zstd xz-utils busybox-static iproute2 iputils-ping \
		wireguard-tools qemu-system-x86 "linux-headers-$K" >/dev/null
fi
[ -e "/lib/modules/$K/build/Makefile" ] || die "no headers for $K"

ROOT=$WORK/root-$K
if [ ! -d "$ROOT/boot" ]; then
	log "Fetching the kernel image and modules"
	mkdir -p "$WORK/debs-$K" "$ROOT"
	(cd "$WORK/debs-$K" && apt-get download -qq "linux-image-unsigned-$K" "linux-modules-$K")
	for d in "$WORK/debs-$K"/*.deb; do dpkg-deb -x "$d" "$ROOT"; done
	depmod -b "$ROOT" "$K"
fi

# ------------------------------------------------------------------ builds

build_module() { # $1 = source dir
	make -s -C "$1" KERNELRELEASE="$K" clean >/dev/null 2>&1 || true
	make -s -C "$1" -j"$(nproc)" KERNELRELEASE="$K" >"$1/build.log" 2>&1
}

log "Building this module"
B=$WORK/build-$K
rm -rf "$B"; mkdir -p "$B"
cp -a "$SRC/src" "$B/own"
build_module "$B/own" || { tail -n 30 "$B/own/build.log"; die "this module does not build for $K"; }
OWN_COMMIT=$(git -C "$SRC" describe --tags --always --dirty 2>/dev/null || echo unknown)

log "Building upstream as 'awgup' ($UPSTREAM_REF)"
rm -rf "$WORK/upstream"
git clone -q "$UPSTREAM" "$WORK/upstream"
git -C "$WORK/upstream" checkout -q "$UPSTREAM_REF"
UP_COMMIT=$(git -C "$WORK/upstream" log -1 --format='%h %s')
cp -a "$WORK/upstream/src" "$B/up"
(
	cd "$B/up"
	grep -rl 'amneziawg-y\|amneziawg\.o' Kbuild compat/Kbuild.include crypto/Kbuild.include 2>/dev/null |
		xargs sed -i 's/amneziawg-y/awgup-y/g; s/amneziawg\.o/awgup.o/g'
	sed -i 's/#define WG_GENL_NAME "amneziawg"/#define WG_GENL_NAME "awgup"/' uapi/wireguard.h
)
if ! build_module "$B/up"; then
	# Upstream may lag behind on build fixes this tree carries: retry with
	# our compat layer, which only adds detection and never changes code.
	log "  upstream does not build for $K as is, retrying with this tree's compat/"
	cp -a "$SRC/src/compat/." "$B/up/compat/"
	sed -i 's/amneziawg-y/awgup-y/g' "$B/up/compat/Kbuild.include"
	build_module "$B/up" || { tail -n 30 "$B/up/build.log"; die "upstream does not build for $K"; }
	UP_COMMIT="$UP_COMMIT (with this tree's compat/)"
fi

log "Building awg tools ($TOOLS_REF)"
rm -rf "$WORK/tools"
git clone -q "$TOOLS" "$WORK/tools"
git -C "$WORK/tools" checkout -q "$TOOLS_REF"
TOOLS_COMMIT=$(git -C "$WORK/tools" log -1 --format='%h')
cp -a "$WORK/tools" "$WORK/tools-up"
make -s -C "$WORK/tools/src" -j"$(nproc)" >/dev/null
sed -i 's/#define WG_GENL_NAME "amneziawg"/#define WG_GENL_NAME "awgup"/' \
	"$WORK/tools-up/src/uapi/linux/linux/wireguard.h"
make -s -C "$WORK/tools-up/src" -j"$(nproc)" >/dev/null

# ------------------------------------------------------------------ initramfs

log "Building the initramfs"
I=$WORK/initrd-$K
rm -rf "$I"
mkdir -p "$I"/{bin,lib/x86_64-linux-gnu,lib64,proc,sys,dev,run,tmp,etc,mods}
cp /usr/bin/busybox "$I/bin/"
for a in $("$I/bin/busybox" --list); do
	[ "$a" = busybox ] || ln -sf busybox "$I/bin/$a"
done
copy_bin() { # $1 = binary, $2 = name in the VM
	rm -f "$I/bin/$2"
	cp -L "$1" "$I/bin/$2"
	local l
	for l in $(ldd "$1" | grep -o '/[^ ]*'); do
		case $l in
		*/ld-linux*) mkdir -p "$I$(dirname "$l")"; cp -L "$l" "$I$l" ;;
		*) cp -L "$l" "$I/lib/x86_64-linux-gnu/" ;;
		esac
	done
}
copy_bin "$(command -v bash)" bash
ln -sf bash "$I/bin/sh"
copy_bin "$(command -v ip)" ip
copy_bin "$(command -v ping)" ping
copy_bin "$(command -v wg)" wg
copy_bin "$WORK/tools/src/wg" awg
copy_bin "$WORK/tools-up/src/wg" awgup

# Modules in load order: dependencies of wireguard, veth and of both modules.
deps=$(modinfo -F depends "$B/own/amneziawg.ko" "$B/up/awgup.ko" | tr ',' '\n')
: > "$I/mods/order"
for m in $deps wireguard veth; do
	modprobe -d "$ROOT" -S "$K" --show-depends "$m" | awk '/^insmod/ {print $2}'
done | awk '!seen[$0]++' | while read -r path; do
	name=$(basename "$path"); name=${name%%.ko*}
	case $path in
	*.zst) zstd -qdc "$path" > "$I/mods/$name.ko" ;;
	*.xz) xz -dc "$path" > "$I/mods/$name.ko" ;;
	*) cp "$path" "$I/mods/$name.ko" ;;
	esac
	echo "$name" >> "$I/mods/order"
done
strip --strip-debug -o "$I/mods/amneziawg.ko" "$B/own/amneziawg.ko"
strip --strip-debug -o "$I/mods/awgup.ko" "$B/up/awgup.ko"
printf 'amneziawg\nawgup\n' >> "$I/mods/order"
cp "$SRC/src/tests/compat.sh" "$I/compat.sh"

cat > "$I/init" <<EOF
#!/bin/sh
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev
mount -t tmpfs tmp /run; mount -t tmpfs tmp /tmp
echo 1 > /proc/sys/kernel/printk
for m in \$(cat /mods/order); do insmod /mods/\$m.ko || echo "@@ insmod \$m failed"; done
echo "@@ BEGIN strict"
AWG=/bin/awg WG=/bin/wg CLIENT_KIND=awgup CLIENT_AWG=/bin/awgup TESTS="$TESTS" bash /compat.sh 2>&1
echo "@@ END strict rc=\$?"
echo "@@ BEGIN own"
AWG=/bin/awg WG=/bin/wg TESTS="$TESTS" bash /compat.sh 2>&1
echo "@@ END own rc=\$?"
echo "@@ BEGIN dmesg"
dmesg | grep -E "amneziawg|awgup|BUG|WARNING|Oops|Call Trace|speaks" | tail -n 200
echo "@@ END dmesg"
poweroff -f
EOF
chmod +x "$I/init"
(cd "$I" && find . | cpio -o -H newc 2>/dev/null | gzip -1) > "$WORK/initrd-$K.gz"

# ------------------------------------------------------------------ run

ACCEL=(-accel tcg)
if [ -w /dev/kvm ]; then ACCEL=(-enable-kvm -cpu host); fi
log "Booting ($([ -w /dev/kvm ] && echo KVM || echo emulation, this takes a while))"
LOG=$WORK/console-$K.log
start=$SECONDS
timeout 2400 qemu-system-x86_64 "${ACCEL[@]}" -m 2048 -smp 2 -nographic -no-reboot \
	-kernel "$ROOT/boot/vmlinuz-$K" -initrd "$WORK/initrd-$K.gz" \
	-append "console=ttyS0 panic=-1 quiet loglevel=1" </dev/null \
	| sed -u 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r$//; s/^.*\(@@ \)/\1/' > "$LOG" || true
took=$((SECONDS - start))

# ------------------------------------------------------------------ report

section() { sed -n "/^@@ BEGIN $1\$/,/^@@ END $1/p" "$LOG" | sed '1d;$d'; }
count() { grep -c "^  $2 " <<<"$1" || true; }

status=0
{
	echo "### Kernel \`$K\`"
	echo
	echo "- this tree: \`$OWN_COMMIT\`"
	echo "- strict clients: upstream \`$UP_COMMIT\`"
	echo "- awg tools: \`$TOOLS_COMMIT\`"
	echo "- VM: $([ -w /dev/kvm ] && echo KVM || echo TCG), ${took}s"
	echo
	echo "| clients | passed | failed | known upstream issues | result |"
	echo "|---|---|---|---|---|"
	for mode in strict own; do
		out=$(section $mode)
		p=$(count "$out" PASS); f=$(count "$out" FAIL); k=$(count "$out" KNOWN)
		if [ $((p + f + k)) = 0 ]; then r="❌ no results"; status=1
		elif grep -q "^@@ END $mode rc=0" "$LOG"; then r="✅"
		elif grep -q "^@@ END $mode" "$LOG"; then r="❌"; status=1
		else r="❌ did not finish"; status=1
		fi
		echo "| $([ $mode = strict ] && echo "upstream module" || echo "this module") | $p | $f | $k | $r |"
	done
	for mode in strict own; do
		bad=$(section $mode | grep -E "^  (FAIL|KNOWN) " || true)
		[ -n "$bad" ] || continue
		echo
		echo "<details><summary>$mode: failures and known issues</summary>"
		echo
		echo '```'
		echo "$bad"
		echo '```'
		echo "</details>"
	done
	if grep -q "^@@ insmod" "$LOG"; then
		echo; echo "Module load errors:"; echo '```'; grep "^@@ insmod" "$LOG"; echo '```'
		status=1
	fi
	if section dmesg | grep -qE "BUG|WARNING|Oops|Call Trace"; then
		echo; echo "**Kernel warnings:**"; echo '```'
		section dmesg | grep -E -A5 "BUG|WARNING|Oops|Call Trace" | head -n 60
		echo '```'
		status=1
	fi
	echo
} > "$REPORT"

cat "$REPORT"
log "Console log: $LOG"
exit $status
