#!/bin/sh

IP=$(/sbin/ifconfig br-lan | grep 'inet addr' | awk '{print $2}' | cut -d: -f2)

if [ -z "$IP" ]; then
    logger -t SquidClamAV "Can't get IP br-lan"
    exit 1
fi

logger -t SquidClamAV "Update IP redirect for squidclamav to $IP"

sed -i "s|redirect http://.*/cgi-bin/clwarn.cgi|redirect http://$IP/cgi-bin/clwarn.cgi|g" /etc/c-icap/squidclamav.conf

