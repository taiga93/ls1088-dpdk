#!/bin/sh
# Stand-in for the client mode of the daemon (`cmm -c <command>`), which always exits 0. The texts are the
# ones of the daemon's source (ASK mono-1.0.7), not captured on a board.
#   -c 'show stat connection query'    $FAKE_ACCELERATED connections in the hardware; "down": no daemon answers
[ "${1:-}" = -c ] || exit 0
if [ "${FAKE_ACCELERATED:-down}" = down ]; then
	echo 'cmmClient: CMM handle creation failed' >&2
	exit 0
fi
case "$2" in
	'show stat connection query')
		printf 'Maximum Active Connections: 131072 \nNumber of Active Connections: %s \n' "$FAKE_ACCELERATED"
		;;
esac
exit 0
