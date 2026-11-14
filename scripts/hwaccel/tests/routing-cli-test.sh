#!/bin/sh
# The golden tests of the two CLIs brought over from the 24.10 firmware,
# bmcdynrouting and bmcmultiwan: once with the shell of this machine, once with
# the busybox of the built root filesystem, where the CLIs of the image itself
# must be the ones of package/bmc. Nothing is started: no FRR, no mwan3.
# scripts/dynrouting-cluster and scripts/multiwan-cluster run them for real.
#
# Run as root inside the build container (aarch64, same as the board):
#   docker exec ubuntu20 sh /home/working/<tree>/scripts/hwaccel/tests/routing-cli-test.sh
#
# ROOTFS=<dir> takes the busybox of another root filesystem, such as the one of
# a 24.10 tree, and leaves out the comparison with the files of that image.
set -u

TOP=$(cd "$(dirname "$0")/../../.." && pwd)
ROOT=${ROOTFS:-$(ls -d "$TOP"/build_dir/target-*/root-layerscape 2>/dev/null | head -1)}
[ -n "$ROOT" ] && [ -x "$ROOT/bin/busybox" ] || { echo "routing-cli-test: no root filesystem with a busybox; build the image first" >&2; exit 2; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rc=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; rc=1; }

mkdir "$W/root"
(cd "$ROOT" && tar cf - --exclude=./lib/modules --exclude=./lib/firmware .) | tar xf - -C "$W/root"
mkdir -p "$W/root/tmp" "$W/root/pkg"

for pkg in bmcDynRouting bmcMultiWAN; do
	src=$TOP/package/bmc/$pkg
	if sh "$src/tests/run.sh" > "$W/out" 2>&1; then
		ok "$pkg: $(tail -n 1 "$W/out")"
	else
		fail "$pkg: golden tests with the shell of this machine"; sed 's/^/      | /' "$W/out"
	fi

	# The busybox of the image has no diff: its run writes the goldens anew,
	# into an empty directory, and they are compared here.
	cp -R "$src" "$W/root/pkg/$pkg"
	rm -f "$W/root/pkg/$pkg/tests/golden"/*
	chroot "$W/root" /bin/sh -c "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; cd /pkg/$pkg && UPDATE_GOLDEN=1 sh tests/run.sh" \
		> "$W/out" 2>&1
	count=$(ls "$src/tests/golden" | wc -l | tr -d ' ')
	if [ "$count" -gt 0 ] && diff -r "$src/tests/golden" "$W/root/pkg/$pkg/tests/golden" > "$W/diff" 2>&1; then
		ok "$pkg: $count golden outputs are the same with the busybox of ${ROOTFS:-the image}"
	else
		fail "$pkg: golden outputs differ with the busybox of ${ROOTFS:-the image}"
		sed 's/^/      | /' "$W/diff" | head -60
	fi

	# What the image runs is what was tested.
	[ -z "${ROOTFS:-}" ] || continue
	if (cd "$src/src" && find usr -type f) | while read -r f; do cmp -s "$src/src/$f" "$ROOT/$f" || exit 1; done; then
		ok "$pkg: the image has the CLI and its library of package/bmc/$pkg"
	else
		fail "$pkg: a file under /usr of the image is not the one of package/bmc/$pkg/src"
	fi
done

[ $rc -eq 0 ] && echo "routing-cli-test: PASS" || echo "routing-cli-test: FAIL"
exit $rc
