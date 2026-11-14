#!/bin/sh
# Golden tests of scripts/ls1088/acceptance.sh with the fake ssh, iperf3,
# ping, route and sleep of scripts/hwaccel/tests/fakebin. Each scenario
# directory under acceptance/ holds the board answers (ssh-*), the iperf3
# reports (iperf-*.json), optional arguments (args), optional environment
# settings (env) and the expected output followed by the calls made, ssh first
# and then iperf3 (expected), as for scripts/hwaccel/tests/acceptance-test.sh.
# The scenarios reach the board at 192.168.1.1 unless their env says
# otherwise.
#
# Usage: scripts/ls1088/tests/acceptance-test.sh [scenario...]
#        UPDATE_EXPECTED=1 scripts/ls1088/tests/acceptance-test.sh <scenario...>
#                         rewrites the expected output of those scenarios
#                         (review the git diff before committing)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
FAKEBIN=$(cd "$HERE/../../hwaccel/tests/fakebin" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

[ $# -gt 0 ] || set -- $(cd "$HERE/acceptance" && ls -d */ | tr -d /)
rc=0
for s in "$@"; do
	args=
	[ -f "$HERE/acceptance/$s/args" ] && args=$(cat "$HERE/acceptance/$s/args")
	: > "$OUT/calls"; : > "$OUT/calls.iperf"
	(
		set -a
		BOARD=192.168.1.1
		# shellcheck disable=SC1090
		[ ! -f "$HERE/acceptance/$s/env" ] || . "$HERE/acceptance/$s/env"
		PATH="$FAKEBIN:$PATH" FIXTURE="$HERE/acceptance/$s" FIXTURE_LOG="$OUT/calls" FIRMWARE="$OUT/firmware.bin"
		# shellcheck disable=SC2086
		sh "$HERE/../acceptance.sh" $args > "$OUT/got" 2>&1
		echo "exit=$?" >> "$OUT/got"
	)
	{ echo "-- calls --"; cat "$OUT/calls" "$OUT/calls.iperf"; } >> "$OUT/got"
	[ "${UPDATE_EXPECTED:-0}" != 1 ] || cp "$OUT/got" "$HERE/acceptance/$s/expected"
	if diff -u "$HERE/acceptance/$s/expected" "$OUT/got" > "$OUT/diff"; then
		echo "ok    $s"
	else
		echo "FAIL  $s"; cat "$OUT/diff"; rc=1
	fi
done
exit $rc
