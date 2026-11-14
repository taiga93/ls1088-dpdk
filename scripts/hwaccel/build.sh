#!/bin/sh
# Build the LS1046A-RDB SD image with hardware acceleration (NXP ASK).
#
# Run inside the ubuntu20 build container, from any directory:
#   docker exec ubuntu20 sh -c '/home/working/<tree>/scripts/hwaccel/build.sh \
#       > /home/working/<tree>/logs/hwaccel-build.log 2>&1'
#
# Stages, in order: toolchain (feeds, host tools, toolchain), image (the SD
# image), check (scripts/hwaccel/check-image.sh), test (the tests under
# scripts/hwaccel/tests, one of which boots the image in QEMU). Name one or more
# stages to run only those; the default is the first three. The test stage
# needs qemu-system-aarch64, dtc, python3 and a few free TCP ports.
#
# Environment:
#   DL_DIR_SHARED  download cache linked as ./dl when ./dl does not exist
#                  (default: ../../dl-25.12 relative to the tree)
#   ASK_UCODE_DIR  directory holding the proprietary ASK FMan microcode
#                  (default: ../../ask-ucode relative to the tree)
#   GO_BOOTSTRAP_ROOT  a Go installation (1.4 or later) that builds the Go
#                  compiler bmcfirewall needs. Go cannot build its own first
#                  stage on an arm64 build host, so there the default is
#                  /usr/lib/go when it exists; elsewhere none is needed.
#   HWACCEL_RELEASE=1  release build: stop when the ASK microcode is missing
#                  or has the wrong sha256, and let the check stage fail on an
#                  image without it. Without it a build that finds no file
#                  goes on with the public microcode and ends with a warning.
#                  See README.md.
set -eu

TOP=$(cd "$(dirname "$0")/../.." && pwd)
cd "$TOP"

export FORCE_UNSAFE_CONFIGURE=1
export ASK_UCODE_DIR="${ASK_UCODE_DIR:-$TOP/../../ask-ucode}"
DL_DIR_SHARED="${DL_DIR_SHARED:-../../dl-25.12}"
SEED=config_LS1046ARDB
KERNEL=6.12.94
UCODE_PKG=package/firmware/layerscape/fman-ucode
WEBUI=package/bmc/bmcwebUI
JOBS=$(nproc)
if [ -z "${GO_BOOTSTRAP_ROOT+set}" ]; then
	GO_BOOTSTRAP_ROOT=
	case "$(uname -m)" in
	aarch64|arm64) [ ! -x /usr/lib/go/bin/go ] || GO_BOOTSTRAP_ROOT=/usr/lib/go ;;
	esac
fi

die() { echo "hwaccel-build: $*" >&2; exit 1; }

RELEASE=
case "${HWACCEL_RELEASE:-0}" in
0) ;;
1) RELEASE=1 ;;
*) die "HWACCEL_RELEASE must be 0 or 1, not '$HWACCEL_RELEASE'" ;;
esac
# check-image.sh reads it.
export HWACCEL_RELEASE="${RELEASE:-0}"

# The base is pinned to the kernel of v25.12.5. A different kernel means the
# base moved, which is a decision for a person, not for this script.
check_base() {
	grep -qxF "LINUX_VERSION-6.12 = .${KERNEL##*.}" target/linux/generic/kernel-6.12 ||
		die "kernel is not $KERNEL; the base must stay at v25.12.5"
	# feeds.conf overrides feeds.conf.default, where v25.12.5 pins the feeds.
	[ ! -e feeds.conf ] || die "feeds.conf is present; the feeds must come from feeds.conf.default"
	sh scripts/check-ask-patch-sync.sh
	# The package build makes the same check; here it stops a build before
	# hours of compiling.
	find_ucode > /dev/null ||
		die "the ASK microcode is not usable${RELEASE:+ for a release build}; see scripts/hwaccel/README.md"
}

# Path of the ASK microcode a build will use; nothing when it will use the
# public one.
find_ucode() {
	sh "$UCODE_PKG/ask-ucode.sh" find ${RELEASE:+--release} "$UCODE_PKG/local" "$ASK_UCODE_DIR"
}

# Last lines of the log when the microcode staged for the image, if any, is not
# the ASK one.
warn_public_ucode() {
	staged=$(ls staging_dir/target-*/image/fsl_ls1046a-rdb-fman.bin 2>/dev/null | head -1)
	[ -n "$staged" ] || return 0
	wanted=$(sh "$UCODE_PKG/ask-ucode.sh" expected)
	[ "$(sha256sum < "$staged" | cut -d' ' -f1)" != "${wanted%% *}" ] || return 0
	echo "hwaccel-build: ######################################################################" >&2
	echo "hwaccel-build: WARNING: the image has the public FMan microcode 106.x, not the ASK" >&2
	echo "hwaccel-build: WARNING: microcode. Hardware acceleration will not start. Not for release." >&2
	echo "hwaccel-build: WARNING: wanted: $wanted" >&2
	echo "hwaccel-build: WARNING: in $UCODE_PKG/local or $ASK_UCODE_DIR" >&2
	echo "hwaccel-build: ######################################################################" >&2
}

# bmcwebUI has its own repository; the build takes whatever is checked out in
# package/bmc/bmcwebUI and says which commit that is.
check_webui() {
	[ -f "$WEBUI/Makefile" ] ||
		die "no web UI in $WEBUI; clone bmcwebUI there, see scripts/hwaccel/README.md"
	# Without a repository of its own, git would answer for this tree.
	if [ -e "$WEBUI/.git" ] && webui_at=$(git -C "$WEBUI" log -1 --format='%h %s' 2>/dev/null); then
		echo "hwaccel-build: bmcwebUI at $webui_at"
	else
		echo "hwaccel-build: bmcwebUI at an unknown commit"
	fi
}

# The packages feed of v25.12.5 has node for the build host only. The package
# in package/lang/node builds it for the router too, and two packages of one
# name cannot both be in the build.
drop_feed_node() {
	rm -f package/feeds/packages/node
}

# The same for the captive portal and the proxy: package/coova-chilli,
# package/freeradius3 and package/community/squid are the feed packages of
# v25.12.5 with the BMC changes of the 24.10 tree on top.
drop_feed_portal() {
	for p in coova-chilli freeradius3 squid; do
		rm -f "package/feeds/packages/$p"
	done
}

# And for FRR: package/frr is the feed package of v25.12.5 (10.4.1) with two
# fixes of ripd that upstream made after that release.
drop_feed_frr() {
	rm -f package/feeds/packages/frr
}

write_config() {
	check_webui
	drop_feed_node
	drop_feed_portal
	drop_feed_frr
	cp "$SEED" .config
	[ -z "$RELEASE" ] || echo "CONFIG_FMAN_UCODE_ASK_REQUIRED=y" >> .config
	[ -z "$GO_BOOTSTRAP_ROOT" ] ||
		echo "CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=\"$GO_BOOTSTRAP_ROOT\"" >> .config
	make defconfig
	if [ -n "$RELEASE" ]; then
		grep -q "^CONFIG_FMAN_UCODE_ASK_REQUIRED=y" .config ||
			die "release build: CONFIG_FMAN_UCODE_ASK_REQUIRED did not stay selected"
	fi
	for p in kmod-ask-cdx kmod-ask-fci kmod-ask-auto-bridge cmm dpa-app fmc bmcHwAccel \
		firewall iptables-zz-legacy ip6tables-zz-legacy kmod-ebtables \
		ppp-mod-pppoe kmod-pppoe \
		bmcfirewall bmcfido bmcwebUI easycwmp libmicroxml node \
		coova-chilli kmod-ipt-coova freeradius3 freeradius3-mod-sql-sqlite \
		squid c-icap squidclamav http-file-tracker \
		frr frr-zebra frr-ospfd frr-ripd frr-bgpd frr-watchfrr bmcDynRouting \
		mwan3 bmcMultiWAN \
		bmcqos tc-full kmod-sched-cake kmod-sched-ctinfo kmod-ifb conntrack \
		strongswan strongswan-charon strongswan-ipsec strongswan-mod-stroke \
		strongswan-mod-kernel-netlink strongswan-mod-openssl kmod-ipsec4; do
		grep -q "^CONFIG_PACKAGE_$p=y" .config || die "package $p is not selected"
	done
	# The PPPoE server is for tests/qemu-test.sh only and stays out of the image.
	grep -q "^CONFIG_PACKAGE_rp-pppoe-server=m" .config ||
		die "package rp-pppoe-server must be built as a package, not into the image"
	# kmod-ebtables is what turns on the bridge netfilter family in the kernel
	# now that nftables is gone; cdx and auto_bridge register hooks in it and
	# fail to load without it.
	# The firewall is fw3 on iptables-legacy, as on the 24.10 firmware. No fw4,
	# and no software flow offloading next to the hardware one.
	for p in firewall4 kmod-nft-offload kmod-ipt-offload; do
		! grep -q "^CONFIG_PACKAGE_$p=y" .config || die "package $p must not be selected"
	done
}

stage_toolchain() {
	[ -e dl ] || [ -L dl ] || ln -s "$DL_DIR_SHARED" dl
	[ -d dl ] || die "dl points to a missing directory: $(readlink dl)"
	./scripts/feeds update -a
	./scripts/feeds install -a
	write_config
	make -j"$JOBS" tools/install toolchain/install
}

stage_image() {
	write_config
	make -j"$JOBS" download
	mkdir -p logs
	# A build that fails must not leave the image of an earlier build behind.
	rm -f bin/targets/layerscape/armv8_64b/*fsl_ls1046a-rdb-sdboot-squashfs-*
	# bmcwebUI calls npx without naming Node.js as something its build needs;
	# with the host Node.js in place first it cannot pick up the one of the
	# build machine.
	make -j"$JOBS" package/lang/node/host/compile
	make -j"$JOBS" || {
		# Run again on one job so the failing step is the last thing logged.
		make -j1 V=s > logs/hwaccel-build-verbose.log 2>&1 || {
			tail -120 logs/hwaccel-build-verbose.log
			die "image build failed; full log in logs/hwaccel-build-verbose.log"
		}
	}
}

stage_check() {
	sh scripts/hwaccel/check-image.sh
}

stage_test() {
	sh scripts/hwaccel/tests/acceptance-test.sh
	sh scripts/hwaccel/tests/ask-ucode-test.sh
	sh package/bmc/bmcHwAccel/tests/run.sh
	rootfs=$(ls -d build_dir/target-*/root-layerscape 2>/dev/null | head -1)
	[ -n "$rootfs" ] || die "no root-layerscape under build_dir; build the image first"
	ROOTFS=$rootfs sh package/bmc/bmcHwAccel/tests/run.sh
	sh scripts/hwaccel/tests/default-network-test.sh
	sh scripts/hwaccel/tests/bmc-packages-test.sh
	sh scripts/hwaccel/tests/routing-cli-test.sh
	sh scripts/hwaccel/tests/sysupgrade-test.sh
	sh scripts/hwaccel/tests/qemu-test.sh
}

[ $# -gt 0 ] || set -- toolchain image check
check_base
for stage in "$@"; do
	case "$stage" in
	toolchain|image|check|test) ;;
	*) die "unknown stage '$stage' (toolchain, image, check, test)" ;;
	esac
	echo "hwaccel-build: stage $stage"
	"stage_$stage"
	echo "hwaccel-build: stage $stage done"
done
echo "hwaccel-build: all stages done${RELEASE:+ (release build)}"
warn_public_ucode
