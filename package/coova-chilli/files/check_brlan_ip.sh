#!/bin/sh

INTERFACE="br-lan"
TAG="check_brlan_ip"

current_ip="$(ip -4 addr show dev "$INTERFACE" 2>/dev/null | awk '/inet / {print $2; exit}')"

if [ -n "$current_ip" ]; then
    exit 0
fi

static_ip="$(uci -q get network.lan.ipaddr)"
netmask="$(uci -q get network.lan.netmask)"

if [ -z "$static_ip" ]; then
    logger -t "$TAG" "br-lan has no IPv4 address and network.lan.ipaddr is empty"
    exit 1
fi

if [ -n "$netmask" ]; then
    ifconfig "$INTERFACE" "$static_ip" netmask "$netmask" >/dev/null 2>&1
else
    ifconfig "$INTERFACE" "$static_ip" >/dev/null 2>&1
fi

logger -t "$TAG" "restored $INTERFACE IPv4 address to $static_ip"

if [ -x /etc/init.d/bmcfirewall ]; then
    /etc/init.d/bmcfirewall restart >/dev/null 2>&1 || \
        logger -t "$TAG" "failed to restart bmcfirewall after restoring $INTERFACE"
fi
