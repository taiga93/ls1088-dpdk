#!/bin/sh
# Builds, for the machine the tests run on (the ubuntu20 container), the DPDK
# of the dpdk package: same source archive, only what the tests of the engine
# use (EAL, mbuf, ring, hash, rcu, ethdev; the vdev bus, the ring mempool and
# the memif and ring ports). Static libraries, installed into
#   $TOPDIR/build_dir/host/bmcHwAccelDpdk-dpdk/install
# and built again only when this script or the archive changes. Prints the
# directory of libdpdk.pc.
#
#   sh tests/host-dpdk.sh        (TOPDIR: the OpenWrt tree, found from here)
set -eu

pkg=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
top=${TOPDIR:-$(CDPATH= cd -- "$pkg/../../.." && pwd)}
dpdk_tar=$top/dl/dpdk-lf-6.12.49-2.2.0.tar.gz
elf_tar=$top/dl/pyelftools-0.32.tar.gz
out=$top/build_dir/host/bmcHwAccelDpdk-dpdk
pc=$out/install/lib/pkgconfig

for f in "$dpdk_tar" "$elf_tar"; do
	[ -f "$f" ] || {
		echo "host-dpdk: $f is missing; make package/network/utils/layerscape/dpdk/download" >&2
		exit 1
	}
done

stamp=$(cat "$0" "$dpdk_tar" | sha256sum | cut -c1-16)
if [ -f "$out/.stamp" ] && [ "$(cat "$out/.stamp")" = "$stamp" ] && [ -f "$pc/libdpdk.pc" ]; then
	echo "$pc"
	exit 0
fi

rm -rf "$out"
mkdir -p "$out/src" "$out/py"
tar -C "$out/src" --strip-components=1 -xzf "$dpdk_tar"
tar -C "$out/py" --strip-components=1 -xzf "$elf_tar" pyelftools-0.32/elftools
# the build runs python scripts that read ELF files (buildtools/pmdinfogen.py)
export PYTHONPATH=$out/py
export PATH=$top/staging_dir/host/bin:$PATH

# generic: the build machine is an arm64 Mac running Linux in a VM, whose CPU
# the arm config of DPDK does not know
python3 "$top/staging_dir/host/bin/meson.py" setup "$out/build" "$out/src" \
	--prefix="$out/install" --libdir=lib --buildtype=debugoptimized \
	-Ddefault_library=static -Dplatform=generic -Denable_kmods=false \
	-Denable_docs=false -Dtests=false -Ddisable_apps='*' -Ddisable_libs='*' \
	-Denable_drivers=bus/vdev,mempool/ring,net/memif,net/ring \
	>"$out/setup.log" 2>&1 || {
		tail -30 "$out/setup.log" >&2
		exit 1
	}
ninja -C "$out/build" install >"$out/build.log" 2>&1 || {
	tail -30 "$out/build.log" >&2
	exit 1
}
echo "$stamp" >"$out/.stamp"
echo "$pc"
