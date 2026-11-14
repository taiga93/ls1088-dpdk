#!/bin/sh

IP=$(/sbin/ifconfig br-lan | grep 'inet addr' | awk '{print $2}' | cut -d: -f2)

if [ -z "$IP" ]; then
    logger -t Squid "Can't get IP br-lan"
    exit 1
fi

logger -t Squid "Update internal_self_signed for squid to $IP"

sed -i "s|acl internal_self_signed dst.*|acl internal_self_signed dst $IP|g" /etc/squid/squid.conf

