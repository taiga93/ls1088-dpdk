#!/bin/sh
# Golden tests of scripts/hwaccel/acceptance.sh with a fake ssh, iperf3 and
# sleep. Each scenario directory holds the board answers (ssh-*), the iperf3
# reports (iperf-*.json), optional arguments (args), optional environment
# settings (env) and the expected output followed by the calls made, ssh first
# and then iperf3 (expected). The sysupgrade items get a made-up image: a tar
# with a kernel member ("kernel") and a root member ("root") behind which
# stands a trailer, as the image metadata does in a real one.
#
# The scenarios are those of a board as a card leaves it, br-lan on
# 192.168.1.1 and PC1 in VLAN 10, unless their env says otherwise;
# bench-defaults runs with the script's own defaults (the bench layout).
#
# Usage: scripts/hwaccel/tests/acceptance-test.sh [scenario...]
#        UPDATE_EXPECTED=1 scripts/hwaccel/tests/acceptance-test.sh <scenario...>
#                         rewrites the expected output of those scenarios
#                         (review the git diff before committing)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

mkdir "$OUT/sysupgrade-test"
echo kernel > "$OUT/sysupgrade-test/kernel"
echo root > "$OUT/sysupgrade-test/root"
(cd "$OUT" && tar -cf firmware.bin sysupgrade-test && echo '{ "metadata_version": "1.1" }' >> firmware.bin)

[ $# -gt 0 ] || set -- $(cd "$HERE" && ls -d */ | tr -d / | grep -v '^fakebin$')
rc=0
for s in "$@"; do
	args=
	[ -f "$HERE/$s/args" ] && args=$(cat "$HERE/$s/args")
	: > "$OUT/calls"; : > "$OUT/calls.iperf"
	(
		set -a
		BOARD=192.168.1.1 VLAN_ID=10
		# shellcheck disable=SC1090
		[ ! -f "$HERE/$s/env" ] || . "$HERE/$s/env"
		PATH="$HERE/fakebin:$PATH" FIXTURE="$HERE/$s" FIXTURE_LOG="$OUT/calls" FIRMWARE="$OUT/firmware.bin"
		# shellcheck disable=SC2086
		sh "$HERE/../acceptance.sh" $args > "$OUT/got" 2>&1
		echo "exit=$?" >> "$OUT/got"
	)
	{ echo "-- calls --"; cat "$OUT/calls" "$OUT/calls.iperf"; } >> "$OUT/got"
	[ "${UPDATE_EXPECTED:-0}" != 1 ] || cp "$OUT/got" "$HERE/$s/expected"
	if diff -u "$HERE/$s/expected" "$OUT/got" > "$OUT/diff"; then
		echo "ok    $s"
	else
		echo "FAIL  $s"; cat "$OUT/diff"; rc=1
	fi
done
exit $rc
