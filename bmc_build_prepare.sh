#!/bin/sh
# Prepare this tree for a build of one board: link ./dl to the shared
# download cache (DL_DIR_SHARED, default ../../dl-25.12), install the feeds of
# feeds.conf.default (src-git, pinned to commits), drop the feed copies of the
# packages that package/ replaces, and write .config from config_<DEVICE>.
#
# Run it in the Linux build container, from any directory:
#   ./bmc_build_prepare.sh LS1088ARDB            then: make -j$(nproc)
#   ./bmc_build_prepare.sh --save LS1088ARDB     write .config back
#
# Devices: one per config_<DEVICE> file at the top of the tree, for example
# LS1088ARDB, LS1088ARDB_MINIMAL, LS1046ARDB. The full builds, with their
# checks of the image, are scripts/ls1088/build.sh and scripts/hwaccel/build.sh;
# they read the same config_<DEVICE> files. Why the files select what they do:
# scripts/ls1088/config.md and scripts/hwaccel/config.md.
#
# Đổi cấu hình (changing a configuration): run this script for the device,
# then make menuconfig, then --save. --save keeps the file free of the build
# host: the Go bootstrap path that build.sh adds is written back empty. Save
# from a development configuration, not from the .config of a release build
# (LS1088_RELEASE=1 or HWACCEL_RELEASE=1 add lines of their own).
set -eu

TOP=$(cd "$(dirname "$0")" && pwd)
cd "$TOP"

usage() {
	echo "Usage: ./bmc_build_prepare.sh [--save] <DEVICE>" >&2
	echo "Devices:" $(ls config_* 2>/dev/null | sed -n 's/^config_\([A-Z0-9_]*\)$/\1/p') >&2
	exit 1
}

SAVE=
[ "${1:-}" != --save ] || { SAVE=1; shift; }
[ $# -eq 1 ] || usage
CONFIG_FILE=config_$1
[ -f "$CONFIG_FILE" ] || { echo "No configuration file: $CONFIG_FILE" >&2; usage; }

if [ -n "$SAVE" ]; then
	[ -f .config ] || { echo "No .config to save" >&2; exit 1; }
	sed 's/^CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=.*/CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=""/' \
		.config > "$CONFIG_FILE"
	echo "Saved .config to $CONFIG_FILE"
	exit 0
fi

[ ! -e feeds.conf ] || { echo "feeds.conf is present; the feeds must come from feeds.conf.default" >&2; exit 1; }
# The download cache shared by the trees, as build.sh links it. Some sources
# are git checkouts packed on the build host (glibc): a fresh pack does not
# match the hash of the base, and the mirror of the base does not have them,
# so they must come from the cache.
DL_DIR_SHARED="${DL_DIR_SHARED:-../../dl-25.12}"
[ -e dl ] || [ -L dl ] || ln -s "$DL_DIR_SHARED" dl
[ -d dl ] || { echo "dl points to a missing directory: $(readlink dl)" >&2; exit 1; }
./scripts/feeds update -a
./scripts/feeds install -a
# The packages of package/ that replace a feed package of the same name: node
# (package/lang/node builds it for the router, the feed only for the host),
# the captive portal and the proxy (the feed packages with the BMC changes of
# the 24.10 tree), FRR (the feed package with two later fixes of ripd). Two
# packages of one name cannot both be in the build. The same list as
# drop_feed_copies in scripts/ls1088/build.sh.
for p in node coova-chilli freeradius3 squid frr; do
	rm -f "package/feeds/packages/$p"
done
cp "$CONFIG_FILE" .config
make defconfig
echo "Wrote .config from $CONFIG_FILE"
