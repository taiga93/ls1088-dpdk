#!/bin/sh

INTERFACE="br-lan"
CHILLI_QUERY="/usr/sbin/chilli_query"

echo "Start check_listgarden_brlan..."

BRLAN_IP=$(ip -4 addr show dev "$INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)

if [ -z "$BRLAN_IP" ]; then
	echo "br-lan has no IP, skip checking listgarden."
	exit 0
fi

echo "Current br-lan IP is $BRLAN_IP"

if [ ! -x "$CHILLI_QUERY" ]; then
	echo "chilli_query not found, skip checking listgarden."
	exit 0
fi

if "$CHILLI_QUERY" listgarden 2>/dev/null | grep -q "host=$BRLAN_IP[[:space:]]"; then
	echo "br-lan IP already exists in chilli listgarden."
	exit 0
fi

echo "br-lan IP is missing from chilli listgarden, restart chilli..."
/etc/init.d/chilli restart
