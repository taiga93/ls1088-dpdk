#!/bin/sh
# Seam 3: bmchwaccel-syncd against a stand-in engine (tool.c) and the real
# conntrack of the built kernel, in QEMU. The image of the LS1088 boots as
# QEMU "virt"; inside it a network namespace "router" forwards and
# masquerades from "client" (10.1.0.10) to "server" (10.2.0.10) with its own
# conntrack, independent of the router configuration of the image (fw3,
# security mode nac). The daemon runs in "router"; the stand-in engine logs
# what the daemon asks of it, and the checks read that log and conntrack.
#
#   client eth8 ── hub 1 ── eth6  router  eth7 ── hub 2 ── eth9 server
#   10.1.0.10               10.1.0.1      10.2.0.1           10.2.0.10
#
# eth1 is QEMU's user network, with host port SSH_PORT to the board's SSH
# (192.168.5.1:22, br-lan); eth0 (wan) a user network of its own; eth2 to
# eth5, the other ports of br-lan, have no cable: wired, they would make a
# loop through br-lan. eth6 to eth9 are in no bridge.
#
# Run as root inside the build container, once the image is built:
#   docker exec ubuntu20 sh /home/working/<tree>/package/bmc/bmcHwAccelDpdk/tests/daemon/qemu-test.sh [SCENARIO...]
# Scenarios: dump events unlearned route neigh link keepalive ipsec ipsec-way
# ipsec-rekey restart stop (all by default). ipsec: the SAs of the real xfrm
# of "router" (ip xfrm), the daemon started with --tunnels 2. ipsec-way: the
# way to the peer of an SA (VLAN, PPPoE, kept on the CPU, a route that comes
# later); the daemon reads the PPPoE sessions and what is kept on the CPU
# from files of the test (--pppoe, --kept). ipsec-rekey:
# the image's strongSwan in "router" and in "client", a tunnel between them
# rekeyed every 20 s. The stand-in engine holds eth6 of "router" as its port:
# eth7 masquerades, and the kernel deletes the connections masqueraded
# through an interface that goes down (with no event of conntrack).
# KEEP=1 leaves the board up at the end, for a look.
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=$HERE/../../src
TOP=$(CDPATH= cd -- "$HERE/../../../../.." && pwd)
BUILD=$(ls -d "$TOP"/build_dir/target-*/linux-layerscape_armv8_64b 2>/dev/null | head -1)
TARGET=$(ls -d "$TOP"/staging_dir/target-aarch64_generic_glibc 2>/dev/null | head -1)
CC=$(ls "$TOP"/staging_dir/toolchain-aarch64_generic_gcc-*_glibc/bin/aarch64-openwrt-linux-gnu-gcc 2>/dev/null | head -1)
QEMU=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}
SSH_PORT=${SSH_PORT:-23122}
SCENARIOS=${*:-dump events unlearned route neigh link keepalive ipsec ipsec-way ipsec-rekey restart stop}

[ -n "$BUILD" ] && [ -f "$BUILD/Image" ] && [ -f "$BUILD/root.squashfs" ] && [ -n "$CC" ] || {
	echo "qemu-test: no kernel, root.squashfs or toolchain under build_dir/staging_dir; build the image first" >&2
	exit 2
}

W=$(mktemp -d)
qemu_pid=
rc=0
cleanup() {
	[ -z "$qemu_pid" ] || { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; }
	rm -rf "$W"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; rc=1; }

# The daemon and the tool, built as the package builds the daemon.
export STAGING_DIR="$TOP/staging_dir"
for prog in "bmchwaccel-syncd $SRC/syncd.c $SRC/sync.c $SRC/watch.c $SRC/sa.c" "tool $HERE/tool.c"; do
	set -- $prog
	name=$1
	shift
	"$CC" -O2 -std=gnu11 -Wall -Wextra -Werror -I"$TARGET/usr/include" -L"$TARGET/usr/lib" \
		-Wl,-rpath-link,"$TARGET/usr/lib" -o "$W/$name" "$@" -lnetfilter_conntrack -lnfnetlink || {
		echo "qemu-test: cannot build $name" >&2
		exit 2
	}
done

SSH_OPTS="-p $SSH_PORT -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# shellcheck disable=SC2086
vm() { ssh $SSH_OPTS root@127.0.0.1 "$1"; }
# shellcheck disable=SC2086
vm_put() { ssh $SSH_OPTS root@127.0.0.1 "cat > $2 && chmod +x $2" < "$1"; }

# The device tree of "virt" with the board name of the LS1046A-RDB: the
# board scripts give the image its usual ports, and the board script of the
# LS1088 (phy_init) has nothing to do.
"$QEMU" -M virt,dumpdtb="$W/virt.dtb" -cpu cortex-a72 -smp 2 -m 512 -nographic >/dev/null 2>&1
dtc -I dtb -O dts "$W/virt.dtb" 2>/dev/null |
	sed 's/compatible = "linux,dummy-virt";/compatible = "fsl,ls1046a-rdb", "linux,dummy-virt";/' |
	dtc -I dts -O dtb -o "$W/board.dtb" 2>/dev/null
# The root filesystem with Tăng tốc phần cứng disabled: a boot in the engine
# layout fails it without DPAA2 and restarts, and in QEMU the first boots
# cannot keep the reason on their overlay yet, so each one would choose the
# engine layout again.
"$TOP/staging_dir/host/bin/unsquashfs4" -q -d "$W/root" "$BUILD/root.squashfs" >/dev/null &&
	printf "config global 'global'\n\toption enabled '0'\n" > "$W/root/etc/config/bmchwaccel" &&
	"$TOP/staging_dir/host/bin/mksquashfs4" "$W/root" "$W/root.squashfs" -nopad -noappend -root-owned \
		-comp xz -quiet >/dev/null || {
	echo "qemu-test: cannot make the root filesystem" >&2
	exit 2
}
rm -rf "$W/root"
dd if="$W/root.squashfs" of="$W/disk.img" bs=1M conv=sync 2>/dev/null
truncate -s +64M "$W/disk.img"
"$QEMU" -M virt -cpu cortex-a72 -smp 2 -m 512 -nographic -dtb "$W/board.dtb" \
	-kernel "$BUILD/Image" -append "root=/dev/vda rootfstype=squashfs rootwait console=ttyAMA0" \
	-drive file="$W/disk.img",if=none,id=d0,format=raw -device virtio-blk-pci,drive=d0,addr=0x08 \
	-netdev user,id=n0,net=10.0.2.0/24 -device virtio-net-pci,netdev=n0,addr=0x10 \
	-netdev "user,id=n1,net=192.168.5.0/24,host=192.168.5.2,dhcpstart=192.168.5.200,hostfwd=tcp:127.0.0.1:$SSH_PORT-192.168.5.1:22" \
	-device virtio-net-pci,netdev=n1,addr=0x11 \
	-device virtio-net-pci,addr=0x12 -device virtio-net-pci,addr=0x13 \
	-device virtio-net-pci,addr=0x14 -device virtio-net-pci,addr=0x15 \
	-netdev hubport,id=n6,hubid=1 -device virtio-net-pci,netdev=n6,addr=0x16 \
	-netdev hubport,id=n7,hubid=2 -device virtio-net-pci,netdev=n7,addr=0x17 \
	-netdev hubport,id=n8,hubid=1 -device virtio-net-pci,netdev=n8,addr=0x18 \
	-netdev hubport,id=n9,hubid=2 -device virtio-net-pci,netdev=n9,addr=0x19 \
	> "$W/serial.log" 2>&1 < /dev/null &
qemu_pid=$!

# Up, and in the kernel layout.
i=0
until [ "$(vm 'cat /var/run/bmchwaccel/layout 2>/dev/null; uptime' 2>/dev/null | head -1)" = kernel ]; do
	i=$((i + 1))
	if [ $i -gt 120 ] || ! kill -0 "$qemu_pid" 2>/dev/null; then
		echo "qemu-test: the board did not come up in the kernel layout" >&2
		vm 'cat /var/run/bmchwaccel/layout; uptime; logread | tail -20' >&2
		grep -a -i -E 'bmcHwAccel|layout|reboot|login' "$W/serial.log" | tail -20 >&2
		tail -15 "$W/serial.log" >&2
		exit 2
	fi
	sleep 3
done
# the services of the boot settle before the network namespaces are made
sleep 20

vm 'mkdir -p /tmp/t/fe' && vm_put "$W/bmchwaccel-syncd" /tmp/t/syncd && vm_put "$W/tool" /tmp/t/tool || {
	echo "qemu-test: cannot copy the programs to the board" >&2
	exit 2
}
R='ip netns exec router'
C='ip netns exec client'
S='ip netns exec server'
vm "set -e
	modprobe nf_conntrack_netlink 2>/dev/null || true
	modprobe nf_conntrack_ftp 2>/dev/null || true
	for ns in router client server; do ip netns add \$ns; ip netns exec \$ns ip link set lo up; done
	ip link set eth6 netns router; ip link set eth7 netns router
	ip link set eth8 netns client; ip link set eth9 netns server
	$R ip addr add 10.1.0.1/24 dev eth6; $R ip link set eth6 up
	$R ip addr add 10.2.0.1/24 dev eth7; $R ip link set eth7 up
	$C ip addr add 10.1.0.10/24 dev eth8; $C ip link set eth8 up; $C ip route add default via 10.1.0.1
	$S ip addr add 10.2.0.10/24 dev eth9; $S ip link set eth9 up
	$R sysctl -q -w net.ipv4.ip_forward=1
	$R iptables -t nat -A POSTROUTING -o eth7 -j MASQUERADE
	$R iptables -t raw -A PREROUTING -p tcp --dport 21 -j CT --helper ftp
	$R iptables -t mangle -A FORWARD -p tcp --dport 5003 -j CONNMARK --set-xmark 0x10000/0x10000
	for p in 21 5001 5003 5005; do ($S /tmp/t/tool tcp-serve \$p >/dev/null 2>&1 &); done
	# nothing answers on 5004
	for p in 5002 5006 5008; do ($S /tmp/t/tool udp-echo \$p >/dev/null 2>&1 &); done
	sleep 1
	$C ping -c 1 -W 2 10.2.0.10 >/dev/null" || {
	echo "qemu-test: cannot set up the namespaces" >&2
	exit 2
}

# The engine and the daemon; the log of the engine starts empty.
# (pkill -f would match the shell of the command that runs it: pid files instead)
engine_start() {
	vm "rm -f /tmp/t/fe/log
		echo 'port eth6 link=up speed=1000 rx_bytes=0 tx_bytes=0 rx_packets=0 tx_packets=0' > /tmp/t/fe/ports
		/tmp/t/tool engine /tmp/t/engine.sock /tmp/t/fe >/dev/null 2>&1 &
		echo \$! > /tmp/t/engine.pid; sleep 1"
}
engine_stop() { vm 'kill $(cat /tmp/t/engine.pid)'; }
daemon_start() {
	vm "$R /tmp/t/syncd --socket /tmp/t/engine.sock --keepalive 2 --tunnels 2 --kept /tmp/t/on_cpu --pppoe /tmp/t/pppoe --verbose >> /tmp/t/syncd.log 2>&1 &
		echo \$! > /tmp/t/syncd.pid"
}
daemon_stop() { vm 'kill -TERM $(cat /tmp/t/syncd.pid); sleep 1'; }
# A TCP connection from the client to port $1 of the server, held open.
tcp_open() {
	vm "($C sh -c 'echo \$\$ > /tmp/t/tcp-$1.pid; exec /tmp/t/tool tcp-hold 10.2.0.10 $1' >/dev/null 2>&1 &)
		sleep 2"
}
tcp_close() { vm "kill \$(cat /tmp/t/tcp-$1.pid)"; }
# Its source port, as conntrack has it in the original direction.
tcp_sport() {
	vm "$R conntrack -L -p tcp --orig-port-dst $1 2>/dev/null" |
		awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^sport=/) { print substr($i, 7); exit } }'
}
# UDP from source port $2 to port $1: answered (assured after 2 s) unless $3 is noreply.
udp_flow() { vm "$C /tmp/t/tool udp-ping 10.2.0.10 $1 $2 8 500 ${3:-} >/dev/null"; }
tcp_bind() { echo "bind tcp 10.1.0.10 $2 10.2.0.10 $1 10.2.0.10 $1 10.2.0.1 $2"; }
udp_bind() { echo "bind udp 10.1.0.10 $2 10.2.0.10 $1 10.2.0.10 $1 10.2.0.1 $2"; }
# Whether the log of the engine has the line $1, waiting up to $2 seconds (5).
logged() {
	i=0
	while [ $i -le "${2:-5}" ]; do
		vm "grep -q -x -F -e '$1' /tmp/t/fe/log" && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}
times_logged() { vm "grep -c -x -F -e '$1' /tmp/t/fe/log"; }
# Whether a line of the log of the engine matches the extended regex $1, waiting up to $2 seconds (5).
logged_re() {
	i=0
	while [ $i -le "${2:-5}" ]; do
		vm "grep -q -E -e '$1' /tmp/t/fe/log" && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}
# The number of the first line of the log of the engine that is $1 (exactly).
line_of() { vm "grep -n -x -F -e '$1' /tmp/t/fe/log | head -1 | cut -d: -f1"; }
check() { # description, then a command
	desc=$1
	shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
check_eq() { # description, value, wanted
	if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: $2, not $3"; fi
}
not() { ! "$@"; }
# Tunnel IPsec: the keys of tests/esp/linux-esp.sh; SAs of the router (10.1.0.1 on eth6, the
# engine's port) with the client (10.1.0.10), and of 10.2.0.1 on eth7, no port of the engine
K=$(i=16; while [ $i -lt 48 ]; do printf %02x $i; i=$((i + 1)); done)
A=$(i=64; while [ $i -lt 96 ]; do printf %02x $i; i=$((i + 1)); done)
ALG="enc 'cbc(aes)' 0x$K auth-trunc 'hmac(sha256)' 0x$A 128"
# the truncation of old proposals, which the engine does not do
ALG96="enc 'cbc(aes)' 0x$K auth-trunc 'hmac(sha256)' 0x$A 96"
UDP="encap espinudp 4500 4500 0.0.0.0"
M=16777216	# SA_MARGIN, 2^24
xs() { vm "$R ip xfrm state $*"; }
# An SA of the router: out|in, SPI, reqid, then what ip xfrm takes besides.
sa_out() { spi=$1 reqid=$2; shift 2; xs add src 10.1.0.1 dst 10.1.0.10 proto esp spi "$spi" reqid "$reqid" "$@"; }
sa_in() { spi=$1 reqid=$2; shift 2; xs add src 10.1.0.10 dst 10.1.0.1 proto esp spi "$spi" reqid "$reqid" "$@"; }
# oseq, bytes or packets of the kernel's SA SPI to DST from SRC, in decimal
sa_field() { # field, spi, src, dst
	vm "$R ip -s xfrm state get src $3 dst $4 proto esp spi $2" | tr '\n' ' ' | awk -v f="$1" '{
		if (f == "oseq" && match($0, /oseq 0x[0-9a-f]+/)) { print substr($0, RSTART + 5, RLENGTH - 5); exit }
		if (f == "bytes" && match($0, /current:[ \t]*[0-9]+\(bytes\)/)) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit }
		if (f == "packets" && match($0, /[0-9]+\(packets\)/)) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit }
	}' | { read -r v; case $v in 0x*) printf '%d' "$v" ;; *) echo "$v" ;; esac; }
}
# Whether the kernel's field reaches the value within $5 seconds (6).
sa_field_is() { # field, spi, src, dst, want, seconds
	i=0
	while [ $i -le "${6:-6}" ]; do
		[ "$(sa_field "$1" "$2" "$3" "$4")" = "$5" ] && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}
said() { vm "grep -q -F -e '$1' /tmp/t/syncd.log"; }

for scenario in $SCENARIOS; do
	echo "== $scenario"
	case $scenario in
	dump)
		# Open before the daemon starts: handed over from the dump of conntrack.
		tcp_open 5001
		tcp_open 21
		tcp_open 5003
		udp_flow 5002 41002
		udp_flow 5004 41004 noreply
		engine_start
		daemon_start
		p=$(tcp_sport 5001)
		check "the daemon claims the engine" logged claim
		check "an assured TCP connection is handed over" logged "$(tcp_bind 5001 "$p")"
		check "an assured UDP connection is handed over" logged "$(udp_bind 5002 41002)"
		check_eq "with BE_LIBERAL both ways in conntrack" \
			"$(vm "$R /tmp/t/tool ct tcp 10.1.0.10 $p 10.2.0.10 5001" | sed 's/.*liberal=//')" orig,reply
		check "UDP without an answer is not" not logged "$(udp_bind 5004 41004)" 0
		check "nor TCP with a helper (FTP)" not vm "grep -q ' 10.2.0.10 21 ' /tmp/t/fe/log"
		check "nor TCP kept on the CPU (0x10000)" not vm "grep -q ' 10.2.0.10 5003 ' /tmp/t/fe/log"
		vm "$C ping -c 6 -i 1 10.2.0.10 >/dev/null 2>&1"
		check "nor ICMP" not vm "grep -q '^bind icmp' /tmp/t/fe/log"
		check "the engine is emptied after the claim" logged flush 0
		check_eq "nor the UDP connection twice" "$(times_logged "$(udp_bind 5002 41002)")" 1
		;;
	events)
		vm ': > /tmp/t/fe/log'
		tcp_open 5005
		p=$(tcp_sport 5005)
		check "a new TCP connection is handed over once established" logged "$(tcp_bind 5005 "$p")"
		vm "$R conntrack -U -p tcp --orig-port-dst 5005 --mark 0x10000/0x10000 >/dev/null 2>&1"
		check "the keep bit takes it back" logged "unbind tcp 10.1.0.10 $p 10.2.0.10 5005"
		vm ': > /tmp/t/fe/log'
		vm "$R conntrack -U -p tcp --orig-port-dst 5005 --mark 0/0x10000 >/dev/null 2>&1"
		check "without the bit it is handed over again" logged "$(tcp_bind 5005 "$p")"
		tcp_close 5005
		check "it leaves ESTABLISHED: taken back" logged "unbind tcp 10.1.0.10 $p 10.2.0.10 5005"
		udp_flow 5008 41008
		check "a new UDP connection is handed over once assured" logged "$(udp_bind 5008 41008)"
		vm "$R conntrack -D -p udp --orig-port-dst 5008 >/dev/null 2>&1"
		check "destroyed: taken back" logged "unbind udp 10.1.0.10 41008 10.2.0.10 5008"
		;;
	unlearned)
		vm ': > /tmp/t/fe/log; echo 2 > /tmp/t/fe/unlearned'
		vm "$R conntrack -D -p udp --orig-port-dst 5006 >/dev/null 2>&1"
		udp_flow 5006 41006
		check "a bind the engine could not make is tried again until it is made" logged "$(udp_bind 5006 41006)" 8
		sleep 4
		check_eq "three times: twice refused, then made" "$(times_logged "$(udp_bind 5006 41006)")" 3
		;;
	route)
		p=$(tcp_sport 5001)
		vm ': > /tmp/t/fe/log; rm -f /tmp/t/fe/flushed'
		vm "$R ip route add 192.0.2.0/24 via 10.2.0.10"
		check "a route added: the engine lets go of what goes to its network" logged "flush-route 192.0.2.0/24"
		vm "$R ip route del 192.0.2.0/24 via 10.2.0.10"
		sleep 2
		check_eq "deleted: the same" "$(times_logged "flush-route 192.0.2.0/24")" 2
		# the stand-in engine says it let go of the TCP connection of dump
		vm "echo 'conn tcp 10.1.0.10 $p 10.2.0.10 5001' > /tmp/t/fe/flushed; : > /tmp/t/fe/log"
		vm "$R ip route add 10.2.0.10/32 dev eth7"
		check "a route to the server" logged "flush-route 10.2.0.10/32"
		check "a connection the engine let go of is handed over again" logged "$(tcp_bind 5001 "$p")"
		vm "rm -f /tmp/t/fe/flushed; $R ip route del 10.2.0.10/32 dev eth7; sleep 1; : > /tmp/t/fe/log"
		vm "$R ip route add default via 10.2.0.10"
		check "the default route: the engine lets go of everything" logged flush
		check "and everything is handed over again" logged "$(tcp_bind 5001 "$p")"
		vm "$R ip route del default via 10.2.0.10; sleep 1; : > /tmp/t/fe/log"
		vm "$R ip rule add from 10.9.9.9 lookup 100"
		check "a rule added: everything" logged flush
		vm ': > /tmp/t/fe/log'
		vm "$R ip rule del from 10.9.9.9 lookup 100"
		check "a rule deleted: everything" logged flush
		vm ': > /tmp/t/fe/log'
		vm "$R ip nexthop add id 9 via 10.2.0.10 dev eth7"
		check "a nexthop object (FRR): everything" logged flush
		vm ': > /tmp/t/fe/log'
		vm "$R ip nexthop replace id 9 via 10.2.0.1 dev eth7 2>/dev/null || $R ip nexthop del id 9"
		check "replaced: everything" logged flush
		vm "$R ip nexthop del id 9 2>/dev/null; sleep 1; : > /tmp/t/fe/log"
		vm "$R ip addr add 10.3.0.1/24 dev eth7"
		check "an address added: what goes to the routes it brings" logged "flush-route 10.3.0.0/24"
		vm ': > /tmp/t/fe/log'
		vm "$R ip addr del 10.3.0.1/24 dev eth7"
		check "an address gone: everything" logged flush
		vm ': > /tmp/t/fe/log'
		vm "$C ping -c 3 -i 0.5 10.2.0.10 >/dev/null 2>&1; sleep 1"
		check "traffic changes no route" not vm "grep -q '^flush' /tmp/t/fe/log"
		;;
	neigh)
		mac=$(vm "$S cat /sys/class/net/eth9/address")
		vm "$R ping -c 1 -W 2 10.2.0.10 >/dev/null 2>&1; sleep 1; : > /tmp/t/fe/log"
		vm "$R ip neigh replace 10.2.0.10 lladdr 02:00:00:00:00:99 dev eth7 nud permanent"
		check "a neighbour with another MAC address: what was sent to the old one is let go of" \
			logged "flush-mac $mac"
		vm "$R ip neigh replace 10.2.0.10 lladdr 02:00:00:00:00:99 dev eth7 nud permanent; sleep 2"
		check "the same address again: nothing" not vm "grep -q -x -F 'flush-mac 02:00:00:00:00:99' /tmp/t/fe/log"
		vm "$R ip neigh del 10.2.0.10 dev eth7; $R ping -c 2 -W 2 10.2.0.10 >/dev/null 2>&1"
		check "deleted, then learned again with the real one: what was sent to the one it had" \
			logged "flush-mac 02:00:00:00:00:99"
		;;
	link)
		vm ': > /tmp/t/fe/log'
		vm "$R ip link set eth6 down"
		check "a port of the engine down: what goes through it is let go of" logged "flush-port eth6"
		vm "$R ip link set eth6 up; sleep 3"
		check_eq "once, and nothing when it comes back" "$(times_logged "flush-port eth6")" 1
		# a bridge of two ports, each a veth to the server's namespace
		vm "$R ip link add br9 type bridge
			for v in v8 v9; do
				$R ip link add \$v type veth peer name w\${v#v} netns server
				$R ip link set \$v master br9; $R ip link set \$v up; $S ip link set w\${v#v} up
			done
			$R ip link set br9 up
			i=0; until $R ip link show v9 | grep -q LOWER_UP && $R ip link show br9 | grep -q LOWER_UP; do
				i=\$((i + 1)); [ \$i -lt 20 ] || break; sleep 0.5; done; sleep 1; : > /tmp/t/fe/log"
		vm "$R ip link set v9 down; sleep 2"
		check "a port of a bridge down: nothing" not vm "grep -q '^flush' /tmp/t/fe/log"
		vm "$R ip link set br9 down"
		check "another interface down: everything" logged flush
		vm "$R ip link del br9; $R ip link del v8; $R ip link del v9; $C ping -c 1 -W 2 10.2.0.10 >/dev/null 2>&1"
		;;
	keepalive)
		# The UDP connection of "unlearned", bound, quiet now: only the engine forwards it.
		ct() { vm "$R /tmp/t/tool ct udp 10.1.0.10 41006 10.2.0.10 5006" | sed -n 's/^timeout=\([0-9]*\).*/\1/p'; }
		vm "$R sysctl -q -w net.netfilter.nf_conntrack_udp_timeout_stream=30"
		vm "$R conntrack -D -p udp --orig-port-dst 5006 >/dev/null 2>&1; : > /tmp/t/fe/log"
		udp_flow 5006 41006
		logged "$(udp_bind 5006 41006)" 8 || fail "the UDP connection is handed over"
		vm "echo 'conn udp 10.1.0.10 41006 10.2.0.10 5006 idle=500' > /tmp/t/fe/active"
		sleep 10
		t=$(ct)
		check "conntrack keeps a connection the engine still forwards ($t s left of 30)" test "${t:-0}" -ge 27
		vm "echo 'conn udp 10.1.0.10 41006 10.2.0.10 5006 idle=20000' > /tmp/t/fe/active"
		sleep 4
		t=$(ct)
		check "counted from its last packet ($t s left, 20 s after it)" sh -c "[ ${t:-0} -ge 7 ] && [ ${t:-0} -le 10 ]"
		vm "echo 'conn tcp 192.0.2.1 1 198.51.100.1 2 idle=10' > /tmp/t/fe/active"
		check "a connection the daemon does not know is taken back" logged "unbind tcp 192.0.2.1 1 198.51.100.1 2"
		vm ': > /tmp/t/fe/active'
		# expired entries go when the garbage collector of conntrack meets them: up to a minute later
		check "quiet: conntrack ends it after its timeout, and it is taken back" \
			logged "unbind udp 10.1.0.10 41006 10.2.0.10 5006" 90
		;;
	ipsec)
		vm ': > /tmp/t/fe/log; rm -f /tmp/t/fe/sa /tmp/t/fe/sa-full; $R ip xfrm state flush'
		sa_out 0xc0000001 1 mode tunnel replay-oseq 5 $ALG $UDP
		check "an outbound SA through a port of the engine goes there, from the kernel's oseq + 2^24" \
			logged "sa-add out 0xc0000001 10.1.0.1 10.1.0.10 4500 4500 1 cbc $K sha256 $A 0 $((5 + M))"
		check "the kernel goes on past the engine's numbers at once" \
			sa_field_is oseq 0xc0000001 10.1.0.1 10.1.0.10 $((5 + 2 * M - 1)) 3
		sa_in 0xc0000002 1 mode tunnel replay-window 32 $ALG $UDP
		check "an inbound SA too, with its window" \
			logged "sa-add in 0xc0000002 10.1.0.10 10.1.0.1 4500 4500 1 cbc $K sha256 $A 32 0"
		# what stays with the kernel: one SA for each condition
		sa_out 0xc0000010 1 mode transport $ALG
		sa_out 0xc0000011 1 mode tunnel flag esn replay-window 128 $ALG
		sa_out 0xc0000012 1 mode tunnel $ALG96
		sa_out 0xc0000013 1 mode tunnel replay-oseq 0xfb000000 $ALG
		sa_in 0xc0000014 1 mode tunnel replay-window 256 $ALG
		xs add src 10.2.0.1 dst 10.2.0.10 proto esp spi 0xc0000015 reqid 1 mode tunnel $ALG
		xs add src 10.9.9.1 dst 10.9.9.2 proto esp spi 0xc0000016 reqid 1 mode tunnel $ALG
		xs add src fd00::1 dst fd00::2 proto esp spi 0xc0000017 reqid 1 mode tunnel $ALG
		# (ESP in UDP of another kind: the kernel takes no espinudp-nonike any more; tests/unit/sa_test.c)
		sleep 2
		for c in "10, out) stays on the kernel: not tunnel mode" "11, out) stays on the kernel: extended sequence numbers" \
			"12, out) stays on the kernel: algorithms the hardware does not do" \
			"13, out) stays on the kernel: sequence numbers near their end" \
			"14, in) stays on the kernel: an anti-replay window above 128" \
			"15, out) stays on the kernel: not through a port of Tăng tốc phần cứng" \
			"16, out) stays on the kernel: not of an address of the router" \
			"17, out) stays on the kernel: not IPv4"; do
			check "stays on the kernel: ${c#*: }" said "(key 0xc00000$c"
		done
		check "and none of them goes to the engine" not vm "grep -q 'sa-add .* 0xc000001' /tmp/t/fe/log"
		# the tunnels: reqid 1 and 2 (--tunnels 2), not 3
		sa_out 0xc0000021 2 mode tunnel $ALG $UDP
		sa_out 0xc0000031 3 mode tunnel $ALG $UDP
		check "an SA of a second tunnel goes" logged "sa-add out 0xc0000021 10.1.0.1 10.1.0.10 4500 4500 2 cbc $K sha256 $A 0 $M"
		check "not one of a third: the most tunnels" said "(key 0xc0000031, out) stays on the kernel: the most tunnels already"
		check "it does not go to the engine" not vm "grep -q 'sa-add .* 0xc0000031 ' /tmp/t/fe/log"
		# the engine refuses: the daemon does not hold it
		vm 'touch /tmp/t/fe/sa-full'
		sa_out 0xc0000022 2 mode tunnel $ALG $UDP
		check "an SA the engine refuses stays on the kernel" said "(key 0xc0000022, out) stays on the kernel: err full"
		vm 'rm -f /tmp/t/fe/sa-full'
		# the engine's numbers into the kernel every second, its counters every 5 s
		vm "printf 'sa spi=0xc0000001 dir=out reqid=1 src=10.1.0.1 dst=10.1.0.10 bytes=1000 packets=10 seq=20000000 failed=0 dropped=0\n' > /tmp/t/fe/sa
			printf 'sa spi=0xc0000002 dir=in reqid=1 src=10.1.0.10 dst=10.1.0.1 bytes=2000 packets=20 failed=0 dropped=0\n' >> /tmp/t/fe/sa"
		check "the kernel's oseq is the engine's last number + 2^24 within a second or two" \
			sa_field_is oseq 0xc0000001 10.1.0.1 10.1.0.10 $((20000000 + M)) 3
		check "the engine's bytes are added to the outbound SA's" sa_field_is bytes 0xc0000001 10.1.0.1 10.1.0.10 1000 7
		check "and its packets" sa_field_is packets 0xc0000001 10.1.0.1 10.1.0.10 10 1
		check "to the inbound one's too" sa_field_is bytes 0xc0000002 10.1.0.10 10.1.0.1 2000 1
		vm "sed -i 's/bytes=1000 packets=10 seq=20000000/bytes=1500 packets=15 seq=21000000/' /tmp/t/fe/sa"
		check "only what was added since" sa_field_is bytes 0xc0000001 10.1.0.1 10.1.0.10 1500 7
		check_eq "the oseq follows" "$(sa_field oseq 0xc0000001 10.1.0.1 10.1.0.10)" $((21000000 + M))
		# an inbound SA as strongSwan makes it: an SPI first, then the SA in it (UPDSA)
		spi=$(xs allocspi src 10.1.0.10 dst 10.1.0.1 proto esp mode tunnel reqid 2 | sed -n 's/.*spi \(0x[0-9a-f]*\).*/\1/p' | head -1)
		xs update src 10.1.0.10 dst 10.1.0.1 proto esp spi "$spi" reqid 2 mode tunnel replay-window 64 $ALG $UDP
		check "an SA updated into the SPI strongSwan asked for goes" \
			logged "sa-add in $(printf 0x%08x "$spi") 10.1.0.10 10.1.0.1 4500 4500 2 cbc $K sha256 $A 64 0"
		# the engine says its tunnel let go of a connection (it had no outbound SA left)
		[ -n "$(tcp_sport 5001)" ] || tcp_open 5001
		p=$(tcp_sport 5001)
		vm "printf 'sa spi=0xc0000021 dir=out reqid=2 src=10.1.0.1 dst=10.1.0.10 bytes=0 packets=0 seq=$M failed=0 dropped=0\n' >> /tmp/t/fe/sa
			echo 'conn tcp 10.1.0.10 $p 10.2.0.10 5001' > /tmp/t/fe/sa-conns; : > /tmp/t/fe/log"
		xs del src 10.1.0.1 dst 10.1.0.10 proto esp spi 0xc0000021
		check "an SA deleted from the kernel is let go of" logged "sa-del 0xc0000021 10.1.0.10"
		check "the connections its tunnel let go of are handed over again" logged "$(tcp_bind 5001 "$p")" 5
		check "and said" said "(key 0xc0000021, out): 1 connections go through the kernel until they are accelerated again"
		vm "sed -i '/0xc0000021/d' /tmp/t/fe/sa"
		# only the tunnel of reqid 1 from here on: which tunnels a dump hands over first is the kernel's order
		xs del src 10.1.0.1 dst 10.1.0.10 proto esp spi 0xc0000022
		xs del src 10.1.0.1 dst 10.1.0.10 proto esp spi 0xc0000031
		xs del src 10.1.0.10 dst 10.1.0.1 proto esp spi "$spi"
		sa_out 0xc0000005 1 mode tunnel $ALG $UDP limit time-hard 2
		logged "sa-add out 0xc0000005 10.1.0.1 10.1.0.10 4500 4500 1 cbc $K sha256 $A 0 $M" || fail "an SA that expires goes"
		check "an SA that expires hard is let go of" logged "sa-del 0xc0000005 10.1.0.10" 6
		# the engine started again: everything handed over again, from the kernel's oseq + 2^24
		engine_stop
		sleep 2
		engine_start
		check "an engine started again is emptied of SAs" logged sa-flush 5
		check "and gets the outbound SA again, numbered past the kernel's" \
			logged "sa-add out 0xc0000001 10.1.0.1 10.1.0.10 4500 4500 1 cbc $K sha256 $A 0 $((21000000 + 2 * M))"
		check "and the inbound one" logged "sa-add in 0xc0000002 10.1.0.10 10.1.0.1 4500 4500 1 cbc $K sha256 $A 32 0"
		# the daemon stops: the SAs are let go of in order, the last number into the kernel (the
		# engine started again from 21000000 + 2^25: its last number is past that)
		vm "sed -i 's/seq=21000000/seq=60000000/' /tmp/t/fe/sa; : > /tmp/t/fe/log"
		daemon_stop
		check "a daemon that stops lets go of the SAs first: stopped" logged "sa-stop 0xc0000001 10.1.0.10"
		check "then deleted once its last number is in the kernel" \
			vm "grep -x -e 'sa-stop 0xc0000001 10.1.0.10' -e 'sa-del 0xc0000001 10.1.0.10' /tmp/t/fe/log | tr '\\n' ' ' | grep -q '^sa-stop .* sa-del '"
		check_eq "and writes the last number of each into the kernel" \
			"$(sa_field oseq 0xc0000001 10.1.0.1 10.1.0.10)" $((60000000 + M))
		check "then closes its session" logged '-- closed'
		daemon_start
		check "a daemon started again hands them over again" \
			logged "sa-add out 0xc0000001 10.1.0.1 10.1.0.10 4500 4500 1 cbc $K sha256 $A 0 $((60000000 + 2 * M))" 8
		# Q12: an outbound SA whose engine's first number is just below SA_SEQ_LEAVE goes; once
		# the engine's number reaches it, it is let go of in order, and the kernel goes on 2^24 past
		L=$(((1 << 32) - (1 << 26) - (1 << 22)))
		sa_out 0xc0000041 1 mode tunnel replay-oseq $((L - M - 1)) $ALG $UDP
		check "an outbound SA that starts just below the end of the engine's numbers goes" \
			logged "sa-add out 0xc0000041 10.1.0.1 10.1.0.10 4500 4500 1 cbc $K sha256 $A 0 $((L - 1))"
		vm ": > /tmp/t/fe/log; printf 'sa spi=0xc0000041 dir=out reqid=1 src=10.1.0.1 dst=10.1.0.10 bytes=0 packets=0 seq=$L failed=0 dropped=0\n' >> /tmp/t/fe/sa"
		check "once the engine's number reaches SA_SEQ_LEAVE it is stopped" logged "sa-stop 0xc0000041 10.1.0.10" 3
		check "then deleted" logged "sa-del 0xc0000041 10.1.0.10"
		check_eq "and the kernel goes on from 2^24 past the engine's last number" \
			"$(sa_field oseq 0xc0000041 10.1.0.1 10.1.0.10)" $((L + M))
		check "said why" said "(key 0xc0000041, out) goes through the kernel again: its sequence numbers near their end"
		vm "sed -i '/0xc0000041/d' /tmp/t/fe/sa"
		vm ': > /tmp/t/fe/log'
		xs flush
		check "the kernel's SAs flushed: every SA let go of" logged "sa-del 0xc0000002 10.1.0.1"
		vm 'rm -f /tmp/t/fe/sa'
		;;
	ipsec-way)
		# spec-ipsec: Điều kiện giao SA. The way to the peer through a VLAN on the port of the
		# engine, a PPPoE session (a veth named as one, the sessions of the kernel in a file of
		# the test, as /proc/net/pppoe lists them), a WAN kept on the CPU (the registrations
		# of bmcHwAccel in a file of the test), and a peer that has a way only later.
		vm ": > /tmp/t/fe/log; rm -f /tmp/t/fe/sa /tmp/t/fe/sa-full /tmp/t/fe/sa-conns /tmp/t/on_cpu /tmp/t/pppoe
			$R ip xfrm state flush
			$R ip link add link eth6 name eth6.30 type vlan id 30
			$R ip addr add 10.3.0.1/24 dev eth6.30; $R ip link set eth6.30 up
			$R ip link add pppoe-wan type veth peer name pppoe-peer
			$R ip addr add 10.4.0.1/24 dev pppoe-wan; $R ip link set pppoe-peer up; $R ip link set pppoe-wan up"
		pppoe() { vm "printf 'Id       Address              Device     PPPDevice  Unit\n00000001 02:00:00:00:00:10 %10s  pppoe-wan  0\n' $1 > /tmp/t/pppoe"; }
		xs add src 10.3.0.1 dst 10.3.0.10 proto esp spi 0xc0000051 reqid 1 mode tunnel $ALG $UDP
		check "an SA through a VLAN on the port of the engine goes" \
			logged "sa-add out 0xc0000051 10.3.0.1 10.3.0.10 4500 4500 1 cbc $K sha256 $A 0 $M"
		pppoe eth6
		xs add src 10.4.0.1 dst 10.4.0.10 proto esp spi 0xc0000061 reqid 1 mode tunnel $ALG $UDP
		check "an SA through a PPPoE session on the port goes" \
			logged "sa-add out 0xc0000061 10.4.0.1 10.4.0.10 4500 4500 1 cbc $K sha256 $A 0 $M"
		xs add src 10.4.0.10 dst 10.4.0.1 proto esp spi 0xc0000062 reqid 1 mode tunnel replay-window 32 $ALG $UDP
		check "and its inbound one" \
			logged "sa-add in 0xc0000062 10.4.0.10 10.4.0.1 4500 4500 1 cbc $K sha256 $A 32 0"
		xs del src 10.4.0.1 dst 10.4.0.10 proto esp spi 0xc0000061
		xs del src 10.4.0.10 dst 10.4.0.1 proto esp spi 0xc0000062
		pppoe eth6.30
		xs add src 10.4.0.1 dst 10.4.0.10 proto esp spi 0xc0000063 reqid 1 mode tunnel $ALG $UDP
		check "an SA through a PPPoE session on a VLAN on the port goes" \
			logged "sa-add out 0xc0000063 10.4.0.1 10.4.0.10 4500 4500 1 cbc $K sha256 $A 0 $M"
		xs del src 10.4.0.1 dst 10.4.0.10 proto esp spi 0xc0000063
		pppoe eth7
		xs add src 10.4.0.1 dst 10.4.0.10 proto esp spi 0xc0000064 reqid 1 mode tunnel $ALG $UDP
		check "not one through a PPPoE session on another device" \
			said "(key 0xc0000064, out) stays on the kernel: not through a port of Tăng tốc phần cứng"
		xs del src 10.4.0.1 dst 10.4.0.10 proto esp spi 0xc0000064
		# Q15: bmcqos shapes the WAN (bmchwaccel keep bmcqos wan eth6)
		vm ": > /tmp/t/fe/log; $R ip xfrm state flush; printf 'bmcqos\twan\teth6\n' > /tmp/t/on_cpu"
		pppoe eth6.30
		sleep 1
		sa_out 0xc0000071 1 mode tunnel $ALG $UDP
		xs add src 10.3.0.1 dst 10.3.0.10 proto esp spi 0xc0000072 reqid 1 mode tunnel $ALG $UDP
		xs add src 10.4.0.1 dst 10.4.0.10 proto esp spi 0xc0000073 reqid 1 mode tunnel $ALG $UDP
		sleep 2
		for c in 71 72 73; do
			check "an SA of a WAN kept on the CPU stays on the kernel ($c)" \
				said "(key 0xc00000$c, out) stays on the kernel: its WAN is kept on the CPU"
		done
		check "none of them goes to the engine" not vm "grep -q 'sa-add .* 0xc000007' /tmp/t/fe/log"
		# what bmcHwAccel does when what is kept changes: the daemon is started again
		vm "printf 'bmcqos\twan\teth7\n' > /tmp/t/on_cpu"
		daemon_stop
		daemon_start
		for c in "71 10.1.0.1 10.1.0.10" "72 10.3.0.1 10.3.0.10" "73 10.4.0.1 10.4.0.10"; do
			set -- $c
			check "another WAN kept: the SA goes once the daemon starts again ($1)" \
				logged "sa-add out 0xc00000$1 $2 $3 4500 4500 1 cbc $K sha256 $A 0 $M" 8
		done
		vm "rm -f /tmp/t/on_cpu; : > /tmp/t/fe/log; $R ip xfrm state flush"
		# a peer without a way yet: on the kernel; the way comes, the SA goes, as the routing changes
		xs add src 10.1.0.1 dst 10.5.0.10 proto esp spi 0xc0000081 reqid 1 mode tunnel $ALG $UDP
		check "an SA of a peer without a route stays on the kernel" \
			said "(key 0xc0000081, out) stays on the kernel: not through a port of Tăng tốc phần cứng"
		vm "$R ip route add 10.5.0.0/24 via 10.1.0.10 dev eth6"
		check "once the route through the port comes, it goes" \
			logged "sa-add out 0xc0000081 10.1.0.1 10.5.0.10 4500 4500 1 cbc $K sha256 $A 0 $M" 4
		# Q14: the way changing again leaves the SA held
		vm "$R ip route del 10.5.0.0/24"
		sleep 3
		check "the route going leaves the SA with the engine" not vm "grep -q 'sa-del 0xc0000081' /tmp/t/fe/log"
		vm ": > /tmp/t/fe/log; $R ip xfrm state flush; rm -f /tmp/t/pppoe
			$R ip link del eth6.30; $R ip link del pppoe-wan"
		check "flushed: let go of" logged "sa-del 0xc0000081 10.5.0.10"
		;;
	ipsec-rekey)
		# Q9: two strongSwans of the image, in "router" and in "client", each with a /var/run and
		# files of its own (the mount is made in the mount namespace ip netns exec starts it in).
		# "client" is the peer, as PC3 on the bench: it starts the tunnel and rekeys it, a
		# CHILD_SA of 40 s rekeyed 20 s before its end; the router answers, its lifetime the
		# default one. The subnets are nobody's: no traffic of the other scenarios goes in.
		vm ": > /tmp/t/fe/log; rm -f /tmp/t/fe/sa /tmp/t/fe/sa-full /tmp/t/fe/sa-conns; $R ip xfrm state flush"
		for side in router client; do
			case $side in
			router) l=10.1.0.1 r=10.1.0.10 ls=10.21.0.0/24 rs=10.31.0.0/24 auto=add life=1h margin=9m ;;
			client) l=10.1.0.10 r=10.1.0.1 ls=10.31.0.0/24 rs=10.21.0.0/24 auto=start life=40s margin=20s ;;
			esac
			vm "mkdir -p /tmp/t/sw-$side/run && cd /tmp/t/sw-$side &&
				printf '%s\n' 'conn t17' '	auto=$auto' '	keyexchange=ikev2' '	ike=aes256-sha256-modp2048!' \
					'	esp=aes256-sha256!' '	left=$l' '	leftid=@$l' '	leftsubnet=$ls' '	leftauth=psk' \
					'	right=$r' '	rightid=@$r' '	rightsubnet=$rs' '	rightauth=psk' '	type=tunnel' \
					'	forceencaps=yes' '	lifetime=$life' '	margintime=$margin' '	rekeyfuzz=0%' > ipsec.conf &&
				echo '@10.1.0.1 @10.1.0.10 : PSK \"seam3-test-key\"' > ipsec.secrets &&
				printf '%s\n' 'charon {' '	install_routes = no' '	load_modular = yes' '	plugins {' \
					'		include /etc/strongswan.d/charon/*.conf' '		stroke {' \
					'			secrets_file = /tmp/t/sw-$side/ipsec.secrets' '		}' '	}' '}' > strongswan.conf &&
				(ip netns exec $side sh -c 'mount -o bind /tmp/t/sw-$side/run /tmp/run &&
					STRONGSWAN_CONF=/tmp/t/sw-$side/strongswan.conf exec /usr/lib/ipsec/starter \
						--daemon charon --nofork --conf /tmp/t/sw-$side/ipsec.conf' \
					</dev/null >/tmp/t/sw-$side/log 2>&1 &)
				sleep 2"
		done
		out_re='^sa-add out 0x[0-9a-f]+ 10\.1\.0\.1 10\.1\.0\.10 4500 4500 [0-9]+ cbc '
		in_re='^sa-add in 0x[0-9a-f]+ 10\.1\.0\.10 10\.1\.0\.1 4500 4500 [0-9]+ cbc '
		check "the tunnel comes up: its outbound SA goes to the engine" logged_re "$out_re" 30
		check "and its inbound one" logged_re "$in_re" 5
		# the n-th SA of a direction: SPI and reqid, and what the engine is told to start from
		nth() { vm "grep -E -e '$1' /tmp/t/fe/log | sed -n '$2p' | cut -d' ' -f3,8,14"; }
		set -- $(nth "$out_re" 1)
		out1=$1 reqid=$2
		set -- $(nth "$in_re" 1)
		in1=$1
		i=0
		while [ -z "$(nth "$out_re" 2)" ] && [ $i -lt 40 ]; do sleep 1; i=$((i + 1)); done
		set -- $(nth "$out_re" 2)
		out2=${1:-} reqid2=${2:-} first2=${3:-}
		check "strongSwan rekeys: a new outbound SA goes to the engine" test -n "$out2"
		check_eq "of the same tunnel (reqid)" "$reqid2" "$reqid"
		check "under another SPI" test "$out2" != "$out1"
		check_eq "numbered from the new SA's oseq + 2^24" "$first2" "$M"
		sa_field_is oseq "$out2" 10.1.0.1 10.1.0.10 $((2 * M - 1)) 8
		check_eq "the kernel's new outbound SA goes on past the engine's numbers" \
			"$(sa_field oseq "$out2" 10.1.0.1 10.1.0.10)" $((2 * M - 1))
		set -- $(nth "$in_re" 2)
		in2=${1:-}
		check "a new inbound SA too, of the same tunnel" test -n "$in2" -a "${2:-}" = "$reqid"
		check "the old outbound SA is let go of" logged "sa-del $out1 10.1.0.10" 15
		check "after the new one went to the engine: the tunnel never lacks one" \
			test "$(line_of "sa-del $out1 10.1.0.10")" -gt "$(line_of "$(vm "grep -E -e '$out_re' /tmp/t/fe/log | sed -n 2p")")"
		check "the old inbound SA is let go of" logged "sa-del $in1 10.1.0.1" 5
		check "it does not stay on the kernel" not said "(key $out2, out) stays on the kernel"
		vm 'kill $(cat /tmp/t/sw-*/run/starter.charon.pid /tmp/t/sw-*/run/charon.pid 2>/dev/null) 2>/dev/null; sleep 2'
		xs flush
		check "the tunnel gone: its SAs are let go of" logged "sa-del $out2 10.1.0.10" 5
		vm 'rm -rf /tmp/t/sw-client /tmp/t/sw-router'
		;;
	restart)
		p=$(tcp_sport 5001)
		engine_stop
		sleep 2
		engine_start
		check "an engine started again is claimed again" logged claim 5
		check "and gets what is open again" logged "$(tcp_bind 5001 "$p")"
		;;
	stop)
		daemon_stop
		check "a daemon that stops closes its session: the engine lets go of everything" logged '-- closed'
		;;
	*)
		fail "no scenario $scenario"
		;;
	esac
done
if [ $rc -ne 0 ]; then
	echo "-- log of the engine:"
	vm 'cat /tmp/t/fe/log' | tail -40 | sed 's/^/    | /'
	echo "-- log of the daemon:"
	vm 'cat /tmp/t/syncd.log' | tail -40 | sed 's/^/    | /'
	echo "-- serial console:"
	tail -30 "$W/serial.log" | sed 's/^/    | /'
fi
# KEEP=1: the board stays up for a look (ssh -p SSH_PORT root@127.0.0.1 in the container) until killed
[ -z "${KEEP:-}" ] || { echo "kept: ssh -p $SSH_PORT root@127.0.0.1"; while kill -0 "$qemu_pid" 2>/dev/null; do sleep 5; done; }
exit $rc
