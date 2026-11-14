#!/bin/sh
# Tests of package/firmware/layerscape/fman-ucode/ask-ucode.sh, the script that
# finds the proprietary ASK FMan microcode and checks its sha256. The script is
# copied next to a made-up ask-ucode.sha256, so no proprietary file is needed.
# Also checks that git can never track the microcode in this tree.
#
# Usage: scripts/hwaccel/tests/ask-ucode-test.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
PKG=$TOP/package/firmware/layerscape/fman-ucode
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

sha256() { { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }

NAME=fman-ucode-ask-9.9.9.bin
mkdir -p "$T/pkg" "$T/empty" "$T/good" "$T/bad" "$T/local-good"
cp "$PKG/ask-ucode.sh" "$T/pkg/"
printf 'the ASK microcode' > "$T/good/$NAME"
cp "$T/good/$NAME" "$T/local-good/$NAME"
printf 'some other file' > "$T/bad/$NAME"
HASH=$(sha256 < "$T/good/$NAME")
BADHASH=$(sha256 < "$T/bad/$NAME")
echo "$HASH  $NAME" > "$T/pkg/ask-ucode.sha256"

rc=0
# check <name> <expected exit> <expected stdout> <stderr must contain...> -- <arguments>
check() {
	name=$1; want_rc=$2; want_out=$3; shift 3
	needles=
	while [ "$1" != -- ]; do needles="$needles$1
"; shift; done
	shift
	got_out=$(sh "$T/pkg/ask-ucode.sh" "$@" 2> "$T/err"); got_rc=$?
	bad=
	[ "$got_rc" -eq "$want_rc" ] || bad="exit $got_rc, expected $want_rc"
	[ "$got_out" = "$want_out" ] || bad="$bad; stdout '$got_out', expected '$want_out'"
	while IFS= read -r n; do
		[ -z "$n" ] || grep -qF -- "$n" "$T/err" || bad="$bad; stderr lacks '$n'"
	done <<EOF
$needles
EOF
	if [ -z "$bad" ]; then
		echo "ok    $name"
	else
		echo "FAIL  $name: $bad"; sed 's/^/      stderr: /' "$T/err"; rc=1
	fi
}

# Development build.
check "dev, no file: nothing found, warning" 0 "" \
	"WARNING" "$NAME" "public" -- find "$T/empty"
check "dev, no such directory: nothing found, warning" 0 "" \
	"WARNING" -- find "$T/missing"
check "dev, right file: found" 0 "$T/good/$NAME" -- find "$T/empty" "$T/good"
check "dev, wrong sha256: error" 1 "" \
	"$T/bad/$NAME" "sha256 mismatch" "$HASH" "$BADHASH" -- find "$T/bad"
check "first directory wins" 0 "$T/local-good/$NAME" -- find "$T/local-good" "$T/good"
check "a wrong file is not skipped for a right one further on" 1 "" \
	"sha256 mismatch" -- find "$T/bad" "$T/good"

# Release build.
check "release, no file: error names the file and the sha256" 1 "" \
	"release build" "$NAME" "$HASH" "$T/empty" -- find --release "$T/empty"
check "release, wrong sha256: error" 1 "" \
	"$T/bad/$NAME" "sha256 mismatch" "$HASH" "$BADHASH" -- find --release "$T/bad"
check "release, right file: found" 0 "$T/good/$NAME" -- find --release "$T/good"

# What the package build is stamped with, so that it runs again when the file
# appears, disappears or changes.
check "state, no file" 0 "none" -- state "$T/empty"
check "state, right file" 0 "$HASH" -- state "$T/good"
check "state, wrong file" 0 "$BADHASH" -- state "$T/bad"

check "expected: the name and sha256 a build looks for" 0 "$HASH  $NAME" -- expected
check "no command: usage" 2 "" "usage" --
check "find without a directory: usage" 2 "" "usage" -- find --release

# The proprietary file must never be tracked by git, wherever it is dropped.
REAL=$(cut -d' ' -f3 "$PKG/ask-ucode.sha256")
for f in "package/firmware/layerscape/fman-ucode/local/$REAL" "$REAL" \
	"package/firmware/layerscape/fman-ucode/local/anything"; do
	if git -C "$TOP" check-ignore -q "$f"; then
		echo "ok    git ignores $f"
	else
		echo "FAIL  git does not ignore $f"; rc=1
	fi
done
tracked=$(git -C "$TOP" ls-files | grep -E 'fman-ucode-ask-.*\.bin$|fman-ucode/local/' || true)
if [ -z "$tracked" ]; then
	echo "ok    no ASK microcode is tracked by git"
else
	echo "FAIL  tracked by git: $tracked"; rc=1
fi

exit $rc
