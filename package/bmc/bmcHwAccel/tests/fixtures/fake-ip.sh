#!/bin/sh
# Stand-in for ip: the neighbour table, and the route to an address (`-o route get <address>`).
case "$*" in
	'neigh show')
		cat <<'TABLE'
192.168.5.99 dev br-lan FAILED
192.168.5.20 dev br-lan lladdr 00:e0:4c:43:42:fb STALE
192.168.5.10 dev br-lan lladdr d0:11:e5:6d:2d:ba REACHABLE
fe80::5 dev br-lan lladdr 02:00:00:00:00:05 REACHABLE
TABLE
		;;
	'-o route get 192.168.5.255') echo 'broadcast 192.168.5.255 dev br-lan src 192.168.5.1 uid 0 \    cache <local,brd> ' ;;
	'-o route get 224.0.0.251') echo 'multicast 224.0.0.251 dev br-lan src 192.168.5.1 uid 0 \    cache <mc> ' ;;
	'-o route get 192.168.5.'*) echo "$4 dev br-lan src 192.168.5.1 uid 0 \\    cache mtu 1500 " ;;
	'-o route get 10.9.9.9') echo '10.9.9.9 via 192.168.5.254 dev br-lan src 192.168.5.1 uid 0 \    cache ' ;;
	'-o route get fd00::40') echo 'fd00::40 from :: dev br-lan proto kernel src fd00::1 metric 256 mtu 1500 pref medium' ;;
	*) exit 2 ;;
esac
