#!/bin/sh
# Find the proprietary ASK FMan microcode and check its sha256.
#
# The file is never part of a git tree. Its name and sha256 are in
# ask-ucode.sha256 next to this script. It is looked up in the directories
# given, in order; the first directory that has a file of that name decides.
#
#   ask-ucode.sh find [--release] <dir>...
#       Print the path of the file when it is there and its sha256 matches.
#       A file with another sha256 is an error. No file at all is a warning
#       and no output in a development build, and an error with --release.
#   ask-ucode.sh state <dir>...
#       Print the sha256 of the file that find would look at, or "none".
#   ask-ucode.sh expected
#       Print the sha256 and the name of the file, as in ask-ucode.sha256.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
read -r HASH NAME < "$HERE/ask-ucode.sha256" || [ -n "${NAME:-}" ] || {
	echo "ask-ucode: cannot read $HERE/ask-ucode.sha256" >&2; exit 1
}

usage() {
	echo "usage: ask-ucode.sh find [--release] <dir>... | state <dir>... | expected" >&2
	exit 2
}

sha256() { { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }

# The first file of the right name in the directories given, if any.
candidate() {
	for d in "$@"; do
		if [ -f "$d/$NAME" ]; then echo "$d/$NAME"; break; fi
	done
}

cmd=${1:-}
[ $# -eq 0 ] || shift
case "$cmd" in
find)
	release=
	[ "${1:-}" != --release ] || { release=1; shift; }
	[ $# -gt 0 ] || usage
	f=$(candidate "$@")
	if [ -z "$f" ]; then
		if [ -n "$release" ]; then
			echo "ask-ucode: ERROR: release build without the ASK FMan microcode." >&2
			echo "ask-ucode:   file:     $NAME" >&2
			echo "ask-ucode:   sha256:   $HASH" >&2
			echo "ask-ucode:   looked in: $*" >&2
			exit 1
		fi
		echo "ask-ucode: WARNING: no $NAME in: $*" >&2
		echo "ask-ucode: WARNING: LS1046A images get the public 106.x microcode and hardware acceleration will not start" >&2
		exit 0
	fi
	got=$(sha256 < "$f")
	if [ "$got" != "$HASH" ]; then
		echo "ask-ucode: ERROR: $f: sha256 mismatch." >&2
		echo "ask-ucode:   expected: $HASH" >&2
		echo "ask-ucode:   found:    $got" >&2
		exit 1
	fi
	echo "$f"
	;;
state)
	[ $# -gt 0 ] || usage
	f=$(candidate "$@")
	if [ -n "$f" ]; then sha256 < "$f"; else echo none; fi
	;;
expected)
	echo "$HASH  $NAME"
	;;
*)
	usage
	;;
esac
