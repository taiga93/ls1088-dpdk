#!/bin/sh
# Stand-in for bmchwaccel-ctl, the client of the control socket of the engine of the DPAA2 boards (texts of
# bmcHwAccelDpdk/src/ctl-client.c and ctl.c):
#   count, flush      $FAKE_ACCELERATED connections in the engine; "down": no engine answers
#   claimed           "ok yes" while the daemon's session is open ($FAKE_CLAIMED yes), "ok no" otherwise
#   ports             two ports: eth0 at 1G with traffic, eth1 without a cable; with $FAKE_ACCELERATED
#                     "garbled", eth1 has a field too many
#   sa                the SAs of Tunnel IPsec: none, or with $FAKE_SA "tunnel" the two of one tunnel, with
#                     "garbled" an inbound one with a "seq"

if [ "${FAKE_ACCELERATED:-down}" = down ]; then
	echo 'bmchwaccel-ctl: /var/run/bmchwaccel-engine.sock: No such file or directory' >&2
	exit 3
fi
case "$1" in
	count|flush) echo "ok $FAKE_ACCELERATED" ;;
	claimed) echo "ok ${FAKE_CLAIMED:-no}" ;;
	ports)
		echo 'port eth0 link=up speed=1000 rx_bytes=123456789012 tx_bytes=4567890123 rx_packets=90123456 tx_packets=3012345'
		if [ "$FAKE_ACCELERATED" = garbled ]; then
			echo 'port eth1 link=down speed=unknown rx_bytes=0 tx_bytes=0 rx_packets=0 tx_packets=0 drops=0'
		else
			echo 'port eth1 link=down speed=unknown rx_bytes=0 tx_bytes=0 rx_packets=0 tx_packets=0'
		fi
		echo ok
		;;
	sa)
		case "${FAKE_SA:-none}" in
			tunnel)
				echo 'sa spi=0xc0000001 dir=out reqid=1 src=192.168.2.10 dst=192.168.2.1 bytes=123456789 packets=98765 seq=16876543 failed=0 dropped=0'
				echo 'sa spi=0xc0000002 dir=in reqid=1 src=192.168.2.1 dst=192.168.2.10 bytes=234567890 packets=87654 failed=1 dropped=0'
				echo 'ok 2'
				;;
			garbled)
				echo 'sa spi=0xc0000002 dir=in reqid=1 src=192.168.2.1 dst=192.168.2.10 bytes=0 packets=0 seq=5 failed=0 dropped=0'
				echo 'ok 1'
				;;
			*) echo 'ok 0' ;;
		esac
		;;
	*) echo 'err unknown-command'; exit 1 ;;
esac
