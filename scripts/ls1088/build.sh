#!/bin/sh
# Build the LS1088A-RDB SD image on the v25.12.5 base, with glibc. The full
# image has Tăng tốc phần cứng (bmcHwAccel with bmcHwAccelDpdk), which boots
# the board in the engine layout while it is enabled; otherwise the ports are on the kernel
# driver (dpaa2-eth), as on the 24.10 firmware. The minimal image has the
# DPDK applications for tests, which take ports only when asked.
#
# Run inside the ubuntu20 build container, from any directory:
#   docker exec ubuntu20 sh -c '/home/working/<tree>/scripts/ls1088/build.sh \
#       > /home/working/<tree>/logs/ls1088-build.log 2>&1'
#
# Stages, in order: toolchain (feeds, host tools, toolchain), image (the SD
# image), check (scripts/ls1088/check-image.sh), test (the tests under
# scripts/ls1088/tests, and those of scripts/hwaccel/tests that read the root
# filesystem of this board). Name one or more stages to run only those; the
# default is the first three.
#
# Environment:
#   DL_DIR_SHARED  download cache linked as ./dl when ./dl does not exist
#                  (default: ../../dl-25.12 relative to the tree)
#   GO_BOOTSTRAP_ROOT  a Go installation (1.4 or later) that builds the Go
#                  compiler bmcfirewall needs; as in scripts/hwaccel/build.sh.
#   LS1088_MINIMAL=1  the image of config_LS1088ARDB_MINIMAL: the base and
#                  the board, no BMC packages. files/ is in it all the same, so
#                  the services there log errors at boot.
#   LS1088_RELEASE=1  a release image: the full image without the DPDK test
#                  applications (dpdk-tools), which could take a port away
#                  from the engine.
#   LS1088_DPDKONLY=1  the image of config_LS1088ARDB_DPDKONLY: the engine
#                  and the firewall stack it keeps the first packet on, no BMC
#                  packages, no working IPsec, no dpdk-tools. It takes the
#                  trimmed overlay scripts/ls1088/files-dpdk-only (phy_init,
#                  network, dhcp of files/), not the whole files/, so no BMC
#                  service or certificate is in it. An image to hand over.
#   LS1088_STRIP=1  strip as far as the build allows, with any of the images
#                  above: userspace with --strip-all and without .comment/.note,
#                  the engine with its symbols out of .dynsym
#                  (BMCHWACCEL_HIDE_SYMS), the kernel without kallsyms and
#                  debugfs (so a kernel oops shows addresses only), the kernel
#                  modules with their symbols renamed. The Image and the
#                  modules carry no debug info (the target config keeps
#                  DEBUG_INFO for vmlinux in build_dir only). sstrip and STRIP_KERNEL_EXPORTS are not available
#                  with glibc / on this base. Switching it on or off repacks
#                  every package (the strip runs when a package is packed) and
#                  rebuilds bmcHwAccelDpdk.
set -eu

TOP=$(cd "$(dirname "$0")/../.." && pwd)
cd "$TOP"

export FORCE_UNSAFE_CONFIGURE=1
DL_DIR_SHARED="${DL_DIR_SHARED:-../../dl-25.12}"
MINIMAL=
case "${LS1088_MINIMAL:-0}" in
0) SEED=config_LS1088ARDB ;;
1) MINIMAL=1; SEED=config_LS1088ARDB_MINIMAL ;;
*) echo "ls1088-build: LS1088_MINIMAL must be 0 or 1, not '$LS1088_MINIMAL'" >&2; exit 1 ;;
esac
RELEASE=
case "${LS1088_RELEASE:-0}" in
0) ;;
1) RELEASE=1 ;;
*) echo "ls1088-build: LS1088_RELEASE must be 0 or 1, not '$LS1088_RELEASE'" >&2; exit 1 ;;
esac
[ -z "$MINIMAL" ] || [ -z "$RELEASE" ] ||
	{ echo "ls1088-build: the minimal image is no release image" >&2; exit 1; }
# The DPDK-only image: the engine and its firewall stack, nothing of the BMC
# feature set, no working IPsec. A clean image to hand over.
DPDKONLY=
OVERLAY=
case "${LS1088_DPDKONLY:-0}" in
0) ;;
1) DPDKONLY=1; SEED=config_LS1088ARDB_DPDKONLY ;;
*) echo "ls1088-build: LS1088_DPDKONLY must be 0 or 1, not '$LS1088_DPDKONLY'" >&2; exit 1 ;;
esac
[ -z "$DPDKONLY" ] || { [ -z "$MINIMAL" ] && [ -z "$RELEASE" ]; } ||
	{ echo "ls1088-build: the dpdk-only image is neither the minimal nor a release image" >&2; exit 1; }
if [ -n "$DPDKONLY" ]; then
	OVERLAY=build/files-dpdk-only
	# package/Makefile and image.mk read this in place of $(TOPDIR)/files (the
	# guarded lines there), so no BMC service or certificate of files/ reaches
	# this image.
	export BMC_ROOTFS_FILES="$TOP/$OVERLAY"
	# Hide our function names from the engine's dynamic symbol table (the
	# bmcHwAccelDpdk Makefile reads this).
	export BMCHWACCEL_HIDE_SYMS=1
fi
STRIP=
STRIP_ARGS_MAX="--strip-all --remove-section=.comment --remove-section=.note"
case "${LS1088_STRIP:-0}" in
0) ;;
1) STRIP=1; export BMCHWACCEL_HIDE_SYMS=1 ;;
*) echo "ls1088-build: LS1088_STRIP must be 0 or 1, not '$LS1088_STRIP'" >&2; exit 1 ;;
esac
STRIP_STATE=build/.ls1088-strip-state
DEVICE=fsl_ls1088a-rdb-sdboot
KERNEL=6.12.94
WEBUI=package/bmc/bmcwebUI
BIN=bin/targets/layerscape/armv8_64b-glibc
JOBS=$(nproc)
if [ -z "${GO_BOOTSTRAP_ROOT+set}" ]; then
	GO_BOOTSTRAP_ROOT=
	case "$(uname -m)" in
	aarch64|arm64) [ ! -x /usr/lib/go/bin/go ] || GO_BOOTSTRAP_ROOT=/usr/lib/go ;;
	esac
fi

die() { echo "ls1088-build: $*" >&2; exit 1; }

check_base() {
	grep -qxF "LINUX_VERSION-6.12 = .${KERNEL##*.}" target/linux/generic/kernel-6.12 ||
		die "kernel is not $KERNEL; the base must stay at v25.12.5"
	[ ! -e feeds.conf ] || die "feeds.conf is present; the feeds must come from feeds.conf.default"
}

check_webui() {
	[ -f "$WEBUI/Makefile" ] ||
		die "no web UI in $WEBUI; clone bmcwebUI there, see scripts/hwaccel/build.md"
	if [ -e "$WEBUI/.git" ] && webui_at=$(git -C "$WEBUI" log -1 --format='%h %s' 2>/dev/null); then
		echo "ls1088-build: bmcwebUI at $webui_at"
	else
		echo "ls1088-build: bmcwebUI at an unknown commit"
	fi
}

# The packages of package/ that replace a feed package of the same name; see
# drop_feed_node and the two after it in scripts/hwaccel/build.sh.
drop_feed_copies() {
	for p in node coova-chilli freeradius3 squid frr; do
		rm -f "package/feeds/packages/$p"
	done
}

# The trimmed overlay of the dpdk-only image: only what a first boot needs that
# files/ carries, copied from files/ so it never drifts. phy_init makes the
# DPAA2 ports; network is br-lan/wan; dhcp is the LAN server. None of the BMC
# services, configuration or certificates of files/ comes along.
build_overlay() {
	local dst=$TOP/$OVERLAY
	rm -rf "$dst"
	mkdir -p "$dst/etc/init.d" "$dst/etc/config"
	cp files/etc/init.d/phy_init "$dst/etc/init.d/phy_init"
	cp files/etc/config/network "$dst/etc/config/network"
	cp files/etc/config/dhcp "$dst/etc/config/dhcp"
}

# The strip runs when a package is packed, and a pack depends on the package's
# build and include/package-pack.mk only, not on the configuration: after
# LS1088_STRIP changes, touching package-pack.mk repacks every package (no
# recompile) with the strip of the new .config. The hidden symbols of the
# engine are compiler flags from the environment, so that package is rebuilt.
strip_state() {
	local want="strip=${STRIP:-0}${STRIP:+ args=$STRIP_ARGS_MAX}"
	local have
	have=$(cat "$STRIP_STATE" 2>/dev/null || echo "strip=0")
	[ "$want" != "$have" ] || return 0
	echo "ls1088-build: strip changed ($have -> $want): repacking every package"
	touch include/package-pack.mk
	make package/bmc/bmcHwAccelDpdk/clean
	mkdir -p "$(dirname "$STRIP_STATE")"
	echo "$want" > "$STRIP_STATE"
}

write_config() {
	{ [ -n "$MINIMAL" ] || [ -n "$DPDKONLY" ]; } || check_webui
	drop_feed_copies
	[ -z "$DPDKONLY" ] || build_overlay
	cp "$SEED" .config
	[ -z "$RELEASE" ] || echo "# CONFIG_PACKAGE_dpdk-tools is not set" >> .config
	[ -z "$STRIP" ] || cat >> .config <<-EOF
		CONFIG_USE_STRIP=y
		CONFIG_STRIP_ARGS="$STRIP_ARGS_MAX"
		# CONFIG_KERNEL_DEBUG_INFO is not set
		# CONFIG_KERNEL_KALLSYMS is not set
		# CONFIG_KERNEL_DEBUG_FS is not set
		# CONFIG_KERNEL_DEBUG_KERNEL is not set
	EOF
	[ -z "$GO_BOOTSTRAP_ROOT" ] ||
		echo "CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=\"$GO_BOOTSTRAP_ROOT\"" >> .config
	make defconfig
	# The name of the choice changed from 24.10; with a name it does not
	# know, defconfig quietly picks musl.
	grep -q "^CONFIG_USE_GLIBC=y" .config || die "glibc did not stay selected"
	grep -q "^CONFIG_TARGET_layerscape_armv8_64b_DEVICE_$DEVICE=y" .config ||
		die "device $DEVICE did not stay selected"
	tools=dpdk-tools
	{ [ -z "$RELEASE" ] && [ -z "$DPDKONLY" ]; } || tools=
	# The dpdk-only image has no captive portal, so no kmod-tun.
	reqd="restool layerscape-mc layerscape-dpl bash ip-full dpdk"
	[ -n "$DPDKONLY" ] || reqd="$reqd kmod-tun"
	for p in $reqd $tools; do
		grep -q "^CONFIG_PACKAGE_$p=y" .config || die "package $p is not selected"
	done
	# The fslmc bus of DPDK reads /proc/self/pagemap.
	grep -q "^CONFIG_KERNEL_PROC_PAGE_MONITOR=y" .config || die "the kernel would be built without PROC_PAGE_MONITOR"
	if [ -n "$STRIP" ]; then
		grep -qxF "CONFIG_STRIP_ARGS=\"$STRIP_ARGS_MAX\"" .config || die "the strip arguments did not stay"
		for o in KERNEL_DEBUG_INFO KERNEL_KALLSYMS KERNEL_DEBUG_FS KERNEL_DEBUG_KERNEL; do
			! grep -q "^CONFIG_$o=y" .config || die "$o is still on in the stripped build"
		done
	fi
	strip_state
	# ASK is for the DPAA1 of the LS1046 only. HA (bmcHA) is not on this base.
	for p in cmm kmod-ask-cdx kmod-ask-fci kmod-ask-auto-bridge dpa-app fmc bmcHA; do
		! grep -q "^CONFIG_PACKAGE_$p=y" .config || die "package $p must not be selected"
	done
	if [ -n "$DPDKONLY" ]; then
		# The engine for the DPAA2 board, and the firewall stack it keeps the
		# first packet on; none of the BMC feature set, and no IPsec stack.
		grep -q "^CONFIG_BMCHWACCEL_DPDK=y" .config || die "bmcHwAccel is not built for bmchwaccel-engine"
		for p in bmcHwAccel bmcHwAccelDpdk firewall iptables-zz-legacy ip6tables-zz-legacy \
			iptables-mod-conntrack-extra iptables-mod-physdev kmod-ipt-physdev \
			conntrack ipset kmod-ipt-ipset flock ip-full; do
			grep -q "^CONFIG_PACKAGE_$p=y" .config || die "package $p is not selected"
		done
		for p in firewall4 kmod-nft-offload dpdk-tools \
			bmcwebUI bmcfirewall bmcfido bmcqos bmcMultiWAN bmcDynRouting \
			node easycwmp coova-chilli freeradius3 squid c-icap squidclamav clamav \
			http-file-tracker frr mwan3 strongswan strongswan-charon; do
			! grep -q "^CONFIG_PACKAGE_$p=y" .config || die "package $p must not be in the dpdk-only image"
		done
		return 0
	fi
	if [ -n "$MINIMAL" ]; then
		! grep -q "^CONFIG_PACKAGE_bmcHwAccel=y" .config || die "the minimal image must not have bmcHwAccel"
		return 0
	fi
	# bmcHwAccel on this board drives bmchwaccel-engine, not ASK.
	grep -q "^CONFIG_BMCHWACCEL_DPDK=y" .config || die "bmcHwAccel is not built for bmchwaccel-engine"
	if [ -n "$RELEASE" ] && grep -q "^CONFIG_PACKAGE_dpdk-tools=y" .config; then
		die "release build: dpdk-tools did not stay out"
	fi
	for p in \
		bmcHwAccel bmcHwAccelDpdk \
		firewall iptables-zz-legacy ip6tables-zz-legacy kmod-ebtables \
		ppp-mod-pppoe kmod-pppoe ip-full \
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
	grep -q "^CONFIG_PACKAGE_rp-pppoe-server=m" .config ||
		die "package rp-pppoe-server must be built as a package, not into the image"
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
	rm -f "$BIN"/*"$DEVICE"-squashfs-*
	# Only the images with the web UI build Node.js (bmcfirewall needs its host).
	{ [ -n "$MINIMAL" ] || [ -n "$DPDKONLY" ]; } || make -j"$JOBS" package/lang/node/host/compile
	make -j"$JOBS" || {
		make -j1 V=s > logs/ls1088-build-verbose.log 2>&1 || {
			tail -120 logs/ls1088-build-verbose.log
			die "image build failed; full log in logs/ls1088-build-verbose.log"
		}
	}
}

stage_check() {
	LS1088_MINIMAL=${MINIMAL:-0} LS1088_RELEASE=${RELEASE:-0} LS1088_DPDKONLY=${DPDKONLY:-0} \
		sh scripts/ls1088/check-image.sh
}

stage_test() {
	sh scripts/ls1088/tests/phy-init-test.sh
	sh scripts/ls1088/tests/layout-test.sh
	sh scripts/ls1088/tests/default-network-test.sh
	# The acceptance test and the two below read the BMC packages; the dpdk-only
	# image has none of them, so it stops after the layout and sysupgrade tests.
	[ -n "$DPDKONLY" ] ||
		sh scripts/ls1088/tests/acceptance-test.sh
	DEVICE=fsl,ls1088a-rdb-sdboot sh scripts/hwaccel/tests/sysupgrade-test.sh
	{ [ -z "$MINIMAL" ] && [ -z "$DPDKONLY" ]; } || return 0
	DEVICE=fsl,ls1088a-rdb-sdboot sh scripts/hwaccel/tests/bmc-packages-test.sh
	sh scripts/hwaccel/tests/routing-cli-test.sh
}

[ $# -gt 0 ] || set -- toolchain image check
check_base
for stage in "$@"; do
	case "$stage" in
	toolchain|image|check|test) ;;
	*) die "unknown stage '$stage' (toolchain, image, check, test)" ;;
	esac
	echo "ls1088-build: stage $stage"
	"stage_$stage"
	echo "ls1088-build: stage $stage done"
done
echo "ls1088-build: all stages done${RELEASE:+ (release build)}${DPDKONLY:+ (dpdk-only image)}${STRIP:+ (stripped)}"
