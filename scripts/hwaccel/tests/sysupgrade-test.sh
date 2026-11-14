#!/bin/sh
# Which firmware accepts the built sysupgrade image, asked with the test mode
# of sysupgrade (-T, writes nothing) in a copy of a root filesystem, with that
# firmware's own busybox, uci, fwtool and upgrade scripts:
#   - the 24.10 firmware refuses it, and the message says that the SD card has
#     to be written. sysupgrade writes the kernel and the root filesystem only,
#     not the FMan microcode and not the U-Boot environment with the MAC
#     addresses.
#   - a firmware of this base accepts it
#   - a firmware of this base from before the image version was raised
#     refuses it
# The image version of the device comes from the uci-defaults script of each
# firmware; the one of this base is taken from the source tree, so no rebuild
# is needed after editing it. The image itself has to be rebuilt after a
# change to its metadata.
#
# Run as root inside the build container (aarch64, same as the board):
#   docker exec ubuntu20 sh /home/working/<tree>/scripts/hwaccel/tests/sysupgrade-test.sh
#
# Environment:
#   FW2410_ROOT  built root filesystem of the 24.10 firmware
#                (default: build_dir/target-*/root-layerscape of the checkout
#                ../bmcfirewall_ls1046 next to this tree). Without one the
#                first check is skipped, and the last line says so. That
#                directory is what the checkout built last, not a released
#                firmware; the board itself is asked by the sysupgrade-old
#                item of acceptance.sh.
#   DEVICE       board name the image is asked about (fsl,ls1046a-rdb-sdboot)
#   IMG          sysupgrade image (the one of DEVICE under bin/ of this tree)
# scripts/ls1088/build.sh test sets DEVICE for the LS1088A-RDB.
set -u

TOP=$(cd "$(dirname "$0")/../../.." && pwd)
COMPAT_SRC=$TOP/target/linux/layerscape/base-files/etc/uci-defaults/05_fix-compat-version
ROOT=$(ls -d "$TOP"/build_dir/target-*/root-layerscape 2>/dev/null | head -1)
DEVICE=${DEVICE:-fsl,ls1046a-rdb-sdboot}
IMG=${IMG:-$(ls "$TOP"/bin/targets/layerscape/armv8_64b*/*"$(echo "$DEVICE" | tr , _)"-squashfs-sysupgrade.bin 2>/dev/null | head -1)}
FW2410_ROOT=${FW2410_ROOT:-$(ls -d "$TOP"/../bmcfirewall_ls1046/build_dir/target-*/root-layerscape 2>/dev/null | head -1)}
[ -n "$ROOT" ] && [ -n "$IMG" ] || {
	echo "sysupgrade-test: no root-layerscape or no sysupgrade image; build the image first" >&2
	exit 2
}

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rc=0

ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; sed 's/^/    | /' "$W/out"; rc=1; }

# Copy of a root filesystem as a board has it after its first boot: a system
# section, and the image version its uci-defaults script ($2) sets.
fresh_root() { # root, uci-defaults script
	rm -rf "$W/root"
	mkdir "$W/root"
	(cd "$1" && tar cf - --exclude=./lib/modules --exclude=./lib/firmware .) | tar xf - -C "$W/root"
	mkdir -p "$W/root/tmp/sysinfo"
	echo "$DEVICE" > "$W/root/tmp/sysinfo/board_name"
	printf 'config system\n' > "$W/root/etc/config/system"
	cp "$2" "$W/root/tmp/fix-compat-version"
	cp "$IMG" "$W/root/tmp/firmware.bin"
	in_root 'sh /tmp/fix-compat-version'
}

in_root() { chroot "$W/root" /bin/sh -c "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; $1"; }

# sysupgrade -T of the image -> $W/out, exit status in $W/rc
try_image() {
	in_root 'echo "device image version: $(uci -q get system.@system[0].compat_version)"
		sysupgrade -T /tmp/firmware.bin' > "$W/out" 2>&1
	echo $? > "$W/rc"
}

# Both firmwares that must refuse are at image version 2.0.
refused() { # description
	if [ "$(cat "$W/rc")" != 0 ] &&
		grep -q "incompatible for sysupgrade based on the image version (2.0->3.0)" "$W/out" &&
		grep -q 'Write the whole SD card' "$W/out" &&
		grep -q '^Image check failed' "$W/out"; then
		ok "$1"
	else
		fail "$1"
	fi
}

if [ -n "$FW2410_ROOT" ] && [ -d "$FW2410_ROOT" ]; then
	fresh_root "$FW2410_ROOT" "$FW2410_ROOT/etc/uci-defaults/05_fix-compat-version"
	try_image
	refused "the 24.10 firmware refuses the image and says to write the SD card"
	asked=
else
	echo "skip  no 24.10 root filesystem (FW2410_ROOT): the 24.10 firmware was not asked"
	asked=", but the 24.10 firmware was not asked"
fi

fresh_root "$ROOT" "$COMPAT_SRC"
try_image
if [ "$(cat "$W/rc")" = 0 ] && grep -qx 'device image version: 3.0' "$W/out"; then
	ok "a firmware of this base accepts the image"
else
	fail "a firmware of this base accepts the image"
fi

# A card written before the image version was raised: same scripts, device
# still at 2.0.
in_root 'uci set system.@system[0].compat_version=2.0; uci commit system'
try_image
refused "a firmware of this base from before the image version was raised refuses it"

[ $rc -eq 0 ] && echo "sysupgrade-test: PASS$asked" || echo "sysupgrade-test: FAIL"
exit $rc
