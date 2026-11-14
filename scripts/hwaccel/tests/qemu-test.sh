#!/bin/sh
# Boot the built kernel and root filesystem in QEMU as an LS1046A-RDB with six
# ports and check what needs no FMan: the default network (wan on eth0, br-lan
# on the other ports), fw3 on iptables-legacy, and routed, masqueraded traffic
# from br-lan to wan on the CPU. acceptance.sh runs here against the image's
# own busybox, netifd, fw3 and pppd, with iperf3 traffic from a LAN client: the
# layouts of its VLAN and PPPoE items come up, carry the traffic the item means
# to measure, and are taken away again. Hardware acceleration itself is not
# covered: FMan cannot be emulated, so the ASK modules are kept from loading
# and every traffic item ends in FAIL. Of bmcHwAccel this shows what needs no
# FMan: its service tries to load the modules exactly when the feature is
# enabled, bmchwaccel saves the choice, reports "unavailable" with the reason
# and one syslog line when the modules do not load, leaves the modules alone
# in a boot that follows two failed ones until "bmchwaccel enable", and
# sysupgrade keeps the choice. Of the packages brought over from the 24.10
# firmware it shows the web UI, the DNS filter and the firewall features at
# work in the image, through the webui, features and features-in items of
# acceptance.sh, and the captive portal and the proxy: the first boot is in
# security mode nac, as a new board is, and a LAN client gets its address
# from the portal, is stopped, logs in and gets out (the portal item); with
# the mode switched to off, a download of the client is sent to squid, which
# asks the ICAP server, and a forwarded download is logged by the HTTP file
# tracker (the proxy item). The daemon cannot run here: started all the
# same, it shows the supervisor under the real procd with a daemon that keeps
# dying. Of bmcqos and of what it keeps on the CPU it shows all but the
# hardware: bmcqos runs on this kernel (cake on wan and on its IFB) and keeps
# its limit both ways while VLAN to VLAN is not limited, the connections
# through wan and only those get the conntrack mark that keeps them out of
# the hardware, with the image's own iptables and conntrack, and a firewall
# restart puts the marking rules back. Of traffic between two br-lan ports:
# it stays with the bridge, where the rules of macfilter and client_control
# stop a running flow (the bridge items). Of Multi-WAN next to it: with two
# WANs a connection leaves through the WAN of its Chính sách WAN, a WAN that
# is Mất Internet loses its connections at the Chuyển WAN (a service stands in
# for the daemon, which is what makes bmcMultiWAN remove them), an open
# connection stays where it is when that WAN has Internet again, and what
# comes in through a WAN is answered through it. Of DynRouting next to it:
# with a second FRR as the neighbour router, the board learns a network over a
# Link định tuyến by OSPF and forwards to it without NAT, stops sending into
# the link once OSPF has withdrawn the route, and follows the route to a
# second link when its next hop changes, with the TCP sessions of one iperf3
# run lasting over the change (the ospf items). The temporary MAC of a port
# without a MAC address is not covered either, for the same reason; only the
# way acceptance.sh reads the board for its MAC items is.
#
# The third boot is from the SD card image, as the SD boot variant of the
# board: the sysupgrade item of acceptance.sh installs the built sysupgrade
# image over it. The image's own sysupgrade writes the kernel partition and
# the root partition of the card and carries the configuration over; the new
# root filesystem then boots. QEMU starts the kernel itself, so the kernel
# file written to the card is compared but not booted, and the card is a
# virtio disk, not an MMC one.
#
# The machine is QEMU "virt" with the board name of the LS1046A-RDB in its
# device tree, so the board.d and uci-defaults scripts of that board run.
#   eth0        wan. First boot: QEMU user network 10.0.2.0/24 (DHCP, host is
#               10.0.2.2); host port SSH_PORT + 1 -> 10.0.2.15:22, which the
#               firewall refuses. Second boot: wired to eth7.
#   eth1        br-lan, QEMU user network; host port SSH_PORT -> 192.168.5.1:22
#               and SSH_PORT + 2 -> 192.168.5.1:3737, the web UI
#   eth2        br-lan, wired to eth6
#   eth4        br-lan, wired to eth8
#   eth5        br-lan, wired to eth9
#   eth3        br-lan, no cable
# and three ports that are not board ports, each moved into a network namespace
# of its own:
#   eth6  "client": PC1, 192.168.5.10 and 192.168.10.10 in VLAN 10
#   eth7  "isp":    PC2 on wan, 192.168.2.10, no DHCP server; iperf3 servers
#                   and a PPPoE server (second boot)
#   eth8  "host2":  PC2 on a br-lan port, 192.168.20.10 in VLAN 20; iperf3
#                   server (second boot). For the bridge items also
#                   192.168.5.20 without a VLAN. For the mwan items also ISP B on
#                   wan2, 192.168.3.10 without a VLAN.
#   eth9  also "host2", which is the neighbour router of the ospf items with
#                   it: 10.17.1.2 on eth8 and 10.17.2.2 on eth9, and
#                   10.17.0.1, the network it announces (second boot)
#
# Run as root inside the build container, right after the build:
#   docker exec ubuntu20 sh /home/working/<tree>/scripts/hwaccel/tests/qemu-test.sh
#
# Environment:
#   SSH_PORT  host port forwarded to the board's SSH  (2222)
#   WEB_PORT  host port of the test web server        (18080)
#   BOOTS     the boots to run                        (dhcp isp card)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../.." && pwd)
BUILD=$(ls -d "$TOP"/build_dir/target-*/linux-layerscape_armv8_64b 2>/dev/null | head -1)
SSH_PORT=${SSH_PORT:-2222}
WEB_PORT=${WEB_PORT:-18080}
BOOTS=${BOOTS:-dhcp isp card}
UI_PORT=$((SSH_PORT + 2))
# The account the test gives the web UI: the bcrypt hash of UI_PASS.
UI_USER=hwaccel
UI_PASS=hwaccel-test
UI_HASH='$2b$10$FIm/GCg0rix76HKy9yG87.eEcIay6yxciKBnFSyubSvoJFE.kXsAy'
BIN=$TOP/bin/targets/layerscape/armv8_64b
CARD=$(ls "$BIN"/*fsl_ls1046a-rdb-sdboot-squashfs-sdcard.img.gz 2>/dev/null | head -1)
FIRMWARE=$(ls "$BIN"/*fsl_ls1046a-rdb-sdboot-squashfs-sysupgrade.bin 2>/dev/null | head -1)
QEMU=${QEMU_SYSTEM_AARCH64:-qemu-system-aarch64}

for tool in "$QEMU" dtc python3; do
	command -v "$tool" >/dev/null 2>&1 || { echo "qemu-test: $tool not found" >&2; exit 2; }
done
[ -n "$BUILD" ] && [ -f "$BUILD/Image" ] && [ -f "$BUILD/root.squashfs" ] || {
	echo "qemu-test: no kernel and root.squashfs under build_dir; build the image first" >&2
	exit 2
}
# Not part of the image; the build makes it as a package of its own.
PPPOE_SERVER_BIN=$(ls "$TOP"/build_dir/target-*/rp-pppoe-*/ipkg-install/usr/sbin/pppoe-server 2>/dev/null | head -1)
[ -n "$PPPOE_SERVER_BIN" ] || {
	echo "qemu-test: no pppoe-server under build_dir; build the image first (package rp-pppoe-server)" >&2
	exit 2
}

boots() { case " $BOOTS " in *" $1 "*) return 0 ;; esac; return 1; }
! boots card || { [ -n "$CARD" ] && [ -n "$FIRMWARE" ]; } || {
	echo "qemu-test: no SD card image or no sysupgrade image under bin; build the image first" >&2
	exit 2
}

W=$(mktemp -d)
qemu_pid=
web_pid=
rc=0

stop_vm() {
	[ -n "$qemu_pid" ] && kill "$qemu_pid" 2>/dev/null && wait "$qemu_pid" 2>/dev/null
	qemu_pid=
}
cleanup() {
	stop_vm
	[ -n "$web_pid" ] && kill "$web_pid" 2>/dev/null
	rm -rf "$W"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; rc=1; }
check() { # description, then a command
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

# acceptance.sh calls "ssh ... root@BOARD"; this one adds the forwarded port.
# With SSH_SHARE set all calls go through one connection: the pings of the
# LAN client are ssh calls here, and ddos_protect on br-lan stops a source
# that opens SSH connections one after the other.
mkdir "$W/bin"
cat > "$W/bin/ssh" <<EOF
#!/bin/sh
[ -z "\${SSH_SHARE:-}" ] || set -- -o ControlMaster=auto -o ControlPath="$W/ssh-shared" -o ControlPersist=120 "\$@"
exec /usr/bin/ssh -p $SSH_PORT "\$@"
EOF
chmod +x "$W/bin/ssh"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
# curl of acceptance.sh asks the board for its web UI; from here that is the
# forwarded port. Its http:// requests are PC1's own, to the portal and to the
# wan side: the LAN client makes them, and what it got is fetched from the
# board for -o.
cat > "$W/bin/curl" <<EOF
#!/bin/sh
case "\$*" in *http://*)
	out=; args=; prev=
	for a; do
		[ "\$prev" != -o ] || { out=\$a; a=/tmp/curl-out; }
		prev=\$a
		args="\$args '\$(printf %s "\$a" | sed "s/'/'\\\\\\\\''/g")'"
	done
	"$W/bin/ssh" $SSH_OPTS root@127.0.0.1 "rm -f /tmp/curl-out; ip netns exec client curl \$args"
	rc=\$?
	case "\$out" in ''|/dev/null) ;; *) "$W/bin/ssh" $SSH_OPTS root@127.0.0.1 'cat /tmp/curl-out 2>/dev/null' > "\$out" ;; esac
	exit \$rc
	;;
esac
for a; do
	shift
	case "\$a" in https://127.0.0.1:3737/*) a="https://127.0.0.1:$UI_PORT/\${a#https://127.0.0.1:3737/}" ;; esac
	set -- "\$@" "\$a"
done
exec /usr/bin/curl "\$@"
EOF
chmod +x "$W/bin/curl"
# logread of the checks below reads both logs of the image, as the board
# scripts of acceptance.sh do (see there).
BOARD_LOGREAD='logread() {
	[ ! -x /usr/libexec/logread-ubox ] || /usr/libexec/logread-ubox "$@"
	[ "$(readlink -f /sbin/logread)" = /usr/libexec/logread-ubox ] || command logread "$@" 2>/dev/null
}'
board() {
	# shellcheck disable=SC2086
	"$W/bin/ssh" $SSH_OPTS root@127.0.0.1 "$BOARD_LOGREAD
$1"
}

# The device tree of "virt" with the LS1046A-RDB board name in front. The
# image adds "-sdboot" to the name only when the root device is an MMC one,
# so the SD boot variant gets a device tree with the full name.
"$QEMU" -M virt,dumpdtb="$W/virt.dtb" -cpu cortex-a72 -smp 2 -m 512 -nographic >/dev/null 2>&1
for name in fsl,ls1046a-rdb fsl,ls1046a-rdb-sdboot; do
	dtc -I dtb -O dts "$W/virt.dtb" 2>/dev/null |
		sed "s/compatible = \"linux,dummy-virt\";/compatible = \"$name\", \"linux,dummy-virt\";/" |
		dtc -I dts -O dtb -o "$W/$name.dtb" 2>/dev/null
	[ -s "$W/$name.dtb" ] || { echo "qemu-test: cannot build the device tree" >&2; exit 2; }
done

# iperf3 for acceptance.sh: the same command run by the LAN client, followed by
# a copy of the conntrack table under the title of the run (-T), because
# acceptance.sh flushes the table before its next item. A killed run
# (pppoe-drop ends its flow that way) takes the client's iperf3 with it and
# leaves /tmp/killed-<title> when that iperf3 was still running.
cat > "$W/bin/iperf3" <<EOF
#!/bin/sh
title=; prev=
for a; do [ "\$prev" = -T ] && title=\$a; prev=\$a; done
on_board() { "$W/bin/ssh" $SSH_OPTS root@127.0.0.1 "\$1"; }
trap 'on_board "killall iperf3-client && touch /tmp/killed-\$title; conntrack -L > /tmp/ct-\$title" 2>/dev/null; exit 143' TERM
on_board "exec ip netns exec client /tmp/iperf3-client \$*" &
wait \$!
rc=\$?
on_board "conntrack -L > /tmp/ct-\$title" 2>/dev/null
exit \$rc
EOF
chmod +x "$W/bin/iperf3"

# ping of acceptance.sh is PC1's: the LAN client sends it, and the board is at
# its br-lan address for it, not behind the forwarded SSH port.
cat > "$W/bin/ping" <<EOF
#!/bin/sh
exec "$W/bin/ssh" $SSH_OPTS root@127.0.0.1 "ip netns exec client ping \$(echo "\$*" | sed 's/127\.0\.0\.1/192.168.5.1/')"
EOF
chmod +x "$W/bin/ping"

start_vm() { # wan: cable | isp; disk: nothing | card
	if [ "${2:-}" = card ]; then
		# The SD card as it is written, with its partition table.
		gunzip -c "$CARD" > "$W/disk.img"
		name=fsl,ls1046a-rdb-sdboot
		root=/dev/vda2
	else
		# The squashfs padded to whole sectors, then room for the overlay
		# that OpenWrt creates behind it.
		dd if="$BUILD/root.squashfs" of="$W/disk.img" bs=1M conv=sync 2>/dev/null
		truncate -s +64M "$W/disk.img"
		name=fsl,ls1046a-rdb
		root=/dev/vda
	fi
	if [ "$1" = cable ]; then
		wan="-netdev user,id=n0,net=10.0.2.0/24,hostfwd=tcp:127.0.0.1:$((SSH_PORT + 1))-10.0.2.15:22 -device virtio-net-pci,netdev=n0,addr=0x10"
	else
		wan="-netdev hubport,id=n0,hubid=2 -device virtio-net-pci,netdev=n0,addr=0x10"
	fi
	# The PCI address fixes the order of the ports. module_blacklist keeps the
	# ASK modules out: without FMan there is nothing for them to drive.
	# shellcheck disable=SC2086
	"$QEMU" -M virt -cpu cortex-a72 -smp 2 -m 512 -nographic -dtb "$W/$name.dtb" \
		-kernel "$BUILD/Image" \
		-append "root=$root rootfstype=squashfs rootwait console=ttyAMA0 module_blacklist=cdx,fci,auto_bridge" \
		-drive file="$W/disk.img",if=none,id=d0,format=raw -device virtio-blk-pci,drive=d0,addr=0x08 \
		$wan \
		-netdev "user,id=n1,net=192.168.5.0/24,host=192.168.5.2,dhcpstart=192.168.5.200,hostfwd=tcp:127.0.0.1:$SSH_PORT-192.168.5.1:22,hostfwd=tcp:127.0.0.1:$UI_PORT-192.168.5.1:3737" \
		-device virtio-net-pci,netdev=n1,addr=0x11 \
		-netdev hubport,id=n2,hubid=1 -device virtio-net-pci,netdev=n2,addr=0x12 \
		-device virtio-net-pci,addr=0x13 \
		-netdev hubport,id=n4,hubid=3 -device virtio-net-pci,netdev=n4,addr=0x14 \
		-netdev hubport,id=n5,hubid=4 -device virtio-net-pci,netdev=n5,addr=0x15 \
		-netdev hubport,id=n6,hubid=1 -device virtio-net-pci,netdev=n6,addr=0x16 \
		-netdev hubport,id=n7,hubid=2 -device virtio-net-pci,netdev=n7,addr=0x17 \
		-netdev hubport,id=n8,hubid=3 -device virtio-net-pci,netdev=n8,addr=0x18 \
		-netdev hubport,id=n9,hubid=4 -device virtio-net-pci,netdev=n9,addr=0x19 \
		> "$W/serial-$1${2:+-$2}.log" 2>&1 < /dev/null &
	qemu_pid=$!
}

# Wait until a board command succeeds; give up after 180 s.
wait_board() {
	i=0
	while [ $i -lt 90 ]; do
		board "$1" >/dev/null 2>&1 && return 0
		kill -0 "$qemu_pid" 2>/dev/null || break
		sleep 2
		i=$((i + 1))
	done
	echo "qemu-test: the board did not come up ($1)" >&2
	tail -30 "$W"/serial-*.log >&2
	return 1
}

accept() { # acceptance.sh items... -> $W/accept, exit status in $W/accept.rc
	PATH="$W/bin:$PATH" BOARD=127.0.0.1 VLAN_ID=10 IPERF3="$W/bin/iperf3" DURATION=20 FIRMWARE="$FIRMWARE" \
		sh "$HERE/../acceptance.sh" "$@" > "$W/accept" 2>&1
	echo $? > "$W/accept.rc"
	sed 's/^/    | /' "$W/accept"
}
# A result line of the last accept run, by a regular expression that follows
# the name of the item.
result() { # item, expression
	grep -q -E "^$1 +$2" "$W/accept"
}
# The conntrack entries left by the iperf3 run of an item.
connections() { # item, expression
	board "grep -E 'dport=520[12] ' /tmp/ct-$1 | grep -q -E '$2'"
}

# ---- first boot: wan gets its address from DHCP

if boots dhcp; then
echo "== boot with a DHCP server on wan =="
start_vm cable
# The checks below look at what the whole boot left, bmcHwAccel (S54) included.
wait_board 'ip -4 -o addr show dev eth0 | grep -q inet && iptables -t nat -S | grep -q -- "-o eth0 " &&
	logread | grep -q "init complete"' || exit 1

check "board name is fsl,ls1046a-rdb" board '[ "$(cat /tmp/sysinfo/board_name)" = fsl,ls1046a-rdb ]'
check "no ASK module is loaded" board '! lsmod | grep -q -E "^(cdx|fci|auto_bridge) "'
# The kernel names a module it refused to load.
tried() { board 'dmesg | grep -q "Module cdx is blacklisted"'; }
not_tried() { ! tried; }
check "bmchwaccel: enabled by default" \
	board 'bmchwaccel get | grep -q "\"enabled\":true" && [ "$(uci -q get bmchwaccel.global.enabled)" = 1 ]'
check "bmcHwAccel tried to load the modules at boot" tried
check "the daemon's own init script is disabled, the one of bmcHwAccel enabled" \
	board '[ ! -e /etc/rc.d/S54cmm ] && [ -e /etc/rc.d/S54bmcHwAccel ] && [ -z "$(pidof cmm)" ]'
check "bmchwaccel status: unavailable, the modules did not load; no accelerated connection, nothing kept on the CPU" \
	board 'bmchwaccel status | grep -q "\"state\":\"unavailable\",\"reason\":\"module\",\"enabled\":true,\"accelerated\":0,\"on_cpu\":\[\]}$"'
check "bmchwaccel apply fails when the modules cannot be loaded, with the reason" \
	board 'out=$(bmchwaccel apply); [ $? = 1 ] &&
		echo "$out" | grep -q "^{\"status\":-1,\"message\":\"Tăng tốc phần cứng failed to start: [^\"]*\",\"reason\":\"module\""'
# The boot and the apply above both failed for the same reason.
unavailable_lines() { board 'logread | grep -c "bmcHwAccel: Tăng tốc phần cứng unavailable: "'; }
check "syslog has one bmcHwAccel line for unavailable" [ "$(unavailable_lines)" = 1 ]
check "a load that returned leaves no mark" board '[ ! -e /etc/bmcHwAccel/loading ]'

# The daemon's service, started by hand behind a made-up control device: the
# daemon exits at once without fci, every time.
daemon_runs() { board 'ubus call service list "{\"name\":\"cmm\"}" | grep -q "\"running\": *true"'; }
daemon_gone() { # seconds
	i=0
	while daemon_runs; do
		[ $i -lt "$1" ] || return 1
		sleep 2
		i=$((i + 2))
	done
}
board ': > /dev/cdx_ctrl; /etc/init.d/cmm start'
check "the daemon's service runs under the supervisor" \
	board 'sleep 1; ubus call service list "{\"name\":\"cmm\"}" | grep -q "\"running\": *true" &&
		pgrep -f "[/]usr/lib/bmcHwAccel/supervise" >/dev/null'
check "a daemon that keeps dying: the service ends by itself" daemon_gone 60
check "a daemon that keeps dying: started 5 times" board '[ "$(cat /var/run/bmcHwAccel/daemon-starts)" = 5 ]'
check "a daemon that keeps dying: one syslog line says unavailable for it" \
	board '[ "$(logread | grep -c "bmcHwAccel: Tăng tốc phần cứng unavailable: its service is not running")" = 1 ]'
check "a daemon that keeps dying: no supervisor is left" board '! pgrep -f "[/]usr/lib/bmcHwAccel/supervise" >/dev/null'
# procd starts a service again whose instance has ended; stopping it ends
# the supervisor between two starts of the daemon.
board '/etc/init.d/cmm start'
check "the service starts again after it gave up" \
	board 'sleep 1; [ "$(cat /var/run/bmcHwAccel/daemon-starts)" -lt 5 ] && pgrep -f "[/]usr/lib/bmcHwAccel/supervise" >/dev/null'
board '/etc/init.d/cmm stop'
check "stopping the service ends the supervisor" daemon_gone 10
check "stopped: no supervisor is left, the daemon was not started 5 times" \
	board '! pgrep -f "[/]usr/lib/bmcHwAccel/supervise" >/dev/null && [ "$(cat /var/run/bmcHwAccel/daemon-starts)" -lt 5 ]'
board 'rm -f /dev/cdx_ctrl'

accept boot firewall ports mac
# No cdx here, so the boot item fails on what bmchwaccel status says.
check "acceptance: boot reads bmchwaccel status" \
	grep -q '^  *- bmchwaccel status says unavailable, need on$' "$W/accept"
check "acceptance: firewall passes" grep -q '^firewall  *PASS' "$W/accept"
check "acceptance: ports passes" grep -q '^ports  *PASS  wan eth0; br-lan: eth1 eth2 eth3 eth4 eth5$' "$W/accept"
check "acceptance: mac passes with the addresses QEMU gave the ports" \
	result mac 'PASS  eth0 [0-9a-f:]+, eth1 .*, eth5 [0-9a-f:]+; from the bootloader$'

# A port without a MAC address needs FMan. What the driver logs for such a port
# is written to the kernel log by hand here, one line per board port: the
# script has to find the lines with the dmesg and logread of the image and to
# keep the addresses on the board for the comparison after a reboot.
board 'for d in /sys/class/net/eth[0-5]; do
		echo "<4>fsl_dpa soc:fsl,dpaa:ethernet@0 ${d##*/}: no valid MAC address from the bootloader: using temporary MAC $(cat $d/address) (stable, from the SoC unique ID)" > /dev/kmsg
	done; sleep 2'
accept mac mac-temp
check "acceptance: mac fails when the kernel log names temporary MACs" \
	result mac 'FAIL  eth0 '
check "acceptance: mac-temp finds the warnings in the kernel log and in syslog" \
	result mac-temp 'PASS  eth0 .*; from the SoC unique ID, warned in the kernel log and in syslog; recorded on the board'
# The record becomes one of an earlier boot.
board 'sed -i "s/^[^ ]* /earlier-boot /" /etc/hwaccel-temp-mac'
accept mac-temp
check "acceptance: mac-temp sees the same MACs as in the boot before" \
	result mac-temp 'PASS  eth0 .*; the same as before the reboot$'
check "mac-temp: the board keeps this boot and the one before" \
	board '[ "$(wc -l < /etc/hwaccel-temp-mac)" = 2 ] && head -n 1 /etc/hwaccel-temp-mac | grep -q "^earlier-boot eth0=.* eth5="'
board 'sed -i "s/^earlier-boot eth0=[0-9a-f:]*/earlier-boot eth0=02:00:00:00:00:01/" /etc/hwaccel-temp-mac'
accept mac-temp
check "acceptance: mac-temp fails when a MAC differs from the boot before" \
	grep -q '^  *- the temporary MACs changed across the reboot; before: eth0=02:00:00:00:00:01 ' "$W/accept"
board 'rm /etc/hwaccel-temp-mac'

# ---- the captive portal: the security mode of a new board

check "a new board is in security mode nac" board '[ "$(uci -q get system.@system[0].security_mode)" = nac ]'
check "nac: the DHCP server of br-lan is off, the redirect of uhttpd too" \
	board '[ "$(uci -q get dhcp.lan.ignore)" = 1 ] && [ "$(uci -q get uhttpd.main.redirect_mode)" = 0 ]'
wait_board 'pidof chilli && ip -4 -o addr show dev tun0 | grep -q "inet 192\.168\.182\.1/"' ||
	fail "CoovaChilli did not start once wan had its address"
check "nac: FreeRADIUS runs with the user database of the portal" \
	board 'pidof radiusd && [ -s /etc/freeradius3/raddb/radius.db ] && [ -L /etc/freeradius3/mods-enabled/sql ]'
check "nac: the FIDO server does not run" board '! pgrep -f "[/]etc/bmcfido/app.js" >/dev/null'
check "nac: br-lan keeps its address and forwards nothing by itself" \
	board 'ip -4 -o addr show dev br-lan | grep -q "inet 192\.168\.5\.1/" && iptables -S FORWARD | grep -q -- "-i br-lan -j DROP"'
check "the kernel match of CoovaChilli is loaded and iptables takes a rule with it" \
	board 'lsmod | grep -q "^xt_coova " && iptables -N hwaccel-coova && iptables -A hwaccel-coova -m coova --name hwaccel -j ACCEPT &&
		iptables -F hwaccel-coova && iptables -X hwaccel-coova'
# A new client on the LAN: eth6, wired to the bridge port eth2, asks for an
# address.
board 'ip netns add client && ip link set eth6 netns client &&
	ip netns exec client ip link set lo up && ip netns exec client ip link set eth6 up &&
	ip netns exec client udhcpc -i eth6 -n -q -t 10 -T 2 -s /usr/share/udhcpc/default.script >/dev/null 2>&1' ||
	fail "the LAN client got no address by DHCP"
portal_client=$(board "ip netns exec client ip -4 -o addr show dev eth6 | awk '{ sub(/\\/.*/, \"\", \$4); print \$4; exit }'")
check "the portal gave the LAN client an address of its network (${portal_client:-none})" \
	sh -c "case '$portal_client' in 192.168.182.*) ;; *) exit 1 ;; esac"
check "the client's gateway is the portal" board 'ip netns exec client ip route | grep -q "^default via 192\.168\.182\.1 "'
check "the client resolves the name of the portal page" \
	board 'ip netns exec client nslookup bmc.lan 192.168.182.1 | sed 1,2d | grep -q "Address"'
check "the client gets the portal page from the board" \
	board 'ip netns exec client wget -q -T 10 -O - http://192.168.182.1/portal.html | grep -q -i "<html"'
export PORTAL_CLIENT=$portal_client SERVER=10.0.2.2
accept portal
unset SERVER
# Hardware acceleration cannot be on here; everything else of the item has to
# hold.
check "acceptance: portal stops the client, logs it in, lets it out and stops it again" \
	result portal "FAIL  PC1 $portal_client at the portal 192\\.168\\.182\\.1; before the login: HTTP sent to the portal page, 0 of 3 pings answered; logged in as hwaccel-test: [1-3] of 3 pings answered; after the logout: 0 of 3; bmchwaccel status: unavailable\$"
check "acceptance: portal fails on the state of hardware acceleration only" \
	sh -c "[ \"\$(grep -c '^  *- ' '$W/accept')\" = 1 ] && grep -q '^  *- bmchwaccel status says unavailable, need on\$' '$W/accept'"
check "portal: the board stays in security mode nac, the login of the item is removed" \
	board '[ "$(uci -q get system.@system[0].security_mode)" = nac ] && [ ! -e /etc/hwaccel-orig ] &&
		[ -z "$(sqlite3 /etc/freeradius3/raddb/radius.db "SELECT username FROM radcheck WHERE username = \"hwaccel-test\"")" ]'
check "portal: the login left a line in the audit log of the portal" \
	board 'grep -q "\"event\":\"login\".*\"username\":\"hwaccel-test\"" /etc/bmcweb/logs/portal_audit.jsonl'

# The portal turned off the way the web UI does it; the checks from here on
# are those of a LAN that forwards. QEMU's user network on eth1 has a DHCP
# server of its own, next to which dnsmasq only starts when forced.
board 'uci set dhcp.lan.force=1 && uci commit dhcp'
check "security mode off: the script of the web UI switches" \
	board 'BMC_ADMIN_IP=192.168.5.2 bash /etc/bmcweb/backend/scripts/firewall/bmcfido.sh set mode off | grep -q "\"status\": *0"'
# The script answers before dnsmasq, which it restarts, listens again.
check "off: CoovaChilli and FreeRADIUS are stopped, the rules of the portal are gone, br-lan has its DHCP server" \
	wait_board '[ -z "$(pidof chilli)" ] && [ -z "$(pidof radiusd)" ] && ! iptables -S FORWARD | grep -q -- "-i br-lan -j DROP" &&
		[ ! -e /sys/class/net/tun0 ] && [ "$(uci -q get dhcp.lan.ignore)" = 0 ] && netstat -lun | grep -q ":67 "'
board 'ip netns del client; sleep 1'

lan_client() {
	board 'ip netns add client && ip link set eth6 netns client &&
		ip netns exec client ip link set lo up &&
		ip netns exec client ip link set eth6 up &&
		ip netns exec client ip addr add 192.168.5.10/24 dev eth6 &&
		ip netns exec client ip route add default via 192.168.5.1' || fail "cannot set up the LAN client"
}
# A LAN client behind br-lan: eth6, wired to the bridge port eth2.
lan_client
check "LAN client reaches the board over br-lan" board 'ip netns exec client ping -c 2 -W 3 192.168.5.1'
check "LAN client pings the wan side through the board" board 'ip netns exec client ping -c 3 -W 3 10.0.2.2'
check "the ping is masqueraded to the wan address" \
	board 'conntrack -L -p icmp 2>/dev/null | grep "src=192.168.5.10 dst=10.0.2.2 " | grep -q "src=10.0.2.2 dst=10.0.2.15 "'

echo hwaccel-qemu-test > "$W/index.html"
(cd "$W" && exec python3 -m http.server --bind 127.0.0.1 "$WEB_PORT") >/dev/null 2>&1 &
web_pid=$!
sleep 1
check "LAN client fetches a page from the wan side (TCP)" \
	board "ip netns exec client wget -q -T 10 -O - http://10.0.2.2:$WEB_PORT/index.html | grep -q hwaccel-qemu-test"
check "the TCP connection is masqueraded" \
	board "conntrack -L -p tcp 2>/dev/null | grep 'src=192.168.5.10 dst=10.0.2.2 ' | grep -q 'dst=10.0.2.15 '"
wan_ssh() {
	/usr/bin/ssh -p $((SSH_PORT + 1)) -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 true
}
check "SSH from the wan side fails" [ "$(wan_ssh >/dev/null 2>&1; echo $?)" = 255 ]
check "the wan zone rejected it" \
	board 'iptables -vnL zone_wan_src_REJECT | awk "NR > 2 && \$1 > 0 { n++ } END { exit !n }"'

# ---- the packages brought over from the 24.10 firmware

# Node.js needs a while to read the server under emulation.
wait_board "netstat -ltn | grep -q ':3737 '" || fail "the web UI does not listen on port 3737"
check "the DNS filter runs" board 'pidof bmcfirewall'
check "the DNS filter answers the LAN client: the name of the board is its br-lan address" \
	board 'ip netns exec client nslookup bmc.lan 192.168.5.1 | sed 1,2d | grep -q "192\.168\.5\.1"'
# The feature services of files/ (ticket 22): each is linked into rc.d under
# its own name and has run, with the chains of macfilter and client_control in
# FORWARD and those of NAT 1:1 in place. ddos_protect is disabled as the image
# comes and has no chain, and so is DHCPGuard (ticket 23). acl_control has no
# service: its rules are rules of the firewall configuration.
check "the feature services of files/ are enabled, under names without a carriage return" \
	board 'for s in macfilter ddos_protect client_control nat_one2one dhcpguard; do /etc/init.d/$s enabled || exit 1; done
		! ls /etc/rc.d | grep -q "$(printf "\\r")"'
check "the feature services of files/ ran at boot" \
	board 'iptables -C FORWARD -j MAC_FILTER && iptables -C FORWARD -j CLIENTCTL &&
		iptables -t nat -C PREROUTING -j ZONE_NAT_11 && iptables -C FORWARD -j nat_one2one && ! iptables -S FW_DOS_POLICY'
DHCPGUARD_GONE='ebtables -L FORWARD >/dev/null && ! ebtables -L FORWARD | grep -q DHCPGUARD && ! ebtables -L DHCPGUARD 2>/dev/null &&
	[ "$(uci -q get dhcpguard.main.enabled)" = 0 ] && ! uci -q show dhcpguard | grep -q whitelist'
check "DHCPGuard is disabled and has no ebtables chain; acl_control has no service" \
	board "$DHCPGUARD_GONE"' && [ ! -e /etc/init.d/acl_control ] && ! ls /etc/rc.d | grep -q acl_control'

accept webui
check "acceptance: webui gets the login page and is refused with a wrong password" \
	result webui 'FAIL  login page and refusal of a wrong password only; '
check "acceptance: webui does not log in without a password" grep -q 'WEBUI_PASS is not set' "$W/accept"
# The account the image comes with has to change its password first.
board 'cp /etc/bmcweb/users.json /tmp/users.before'
board 'cat > /etc/bmcweb/users.json' <<EOF
[{"username":"$UI_USER","password":"$UI_HASH","mustChangePassword":false}]
EOF
export WEBUI_USER=$UI_USER WEBUI_PASS=$UI_PASS
accept webui
check "acceptance: webui logs in, opens the firewall pages and gets their data" \
	result webui 'PASS  logged in as hwaccel; 7 page\(s\) opened, 7 request\(s\) of those pages answered without an error; '
board 'cp /tmp/users.before /etc/bmcweb/users.json'
unset WEBUI_USER WEBUI_PASS

# macfilter, client_control and ddos_protect against the LAN client, whose
# pings go through the board to the host side of wan.
export PC1=192.168.5.10 SERVER=10.0.2.2 SSH_SHARE=1
accept features
"$W/bin/ssh" -O exit root@127.0.0.1 2>/dev/null
unset SERVER SSH_SHARE
# The item drives the three features and judges them: each rule is set by
# the script of the web UI and acts on the client, ddos_protect on its pings
# to the board and on those the board forwards.
check "acceptance: features passes for the LAN client and its MAC" \
	result features 'PASS  PC1 192\.168\.5\.10 \(52:54:00:12:34:5C\); macfilter and client_control each stopped it and let it through again; '
check "features: ddos_protect limits the pings to the board and the forwarded ones, and none once disabled" \
	result features 'PASS  .*; ddos_protect: ([0-9]|1[0-8]) of 24 pings to the board and ([0-9]|1[0-8]) through it answered while enabled, 2[2-4] and 2[2-4] once disabled; '
check "features: the client reaches the wan side before and after each feature" \
	sh -c "! grep -q -E 'does not reach 10.0.2.2|once disabled, need' '$W/accept'"
check "features: hardware acceleration was disabled for it and is enabled again" \
	sh -c "grep -q '; hardware acceleration disabled\$' '$W/accept'"
check "features: enabled again" board '[ "$(uci -q get bmchwaccel.global.enabled)" = 1 ]'
check "features: nothing in the output of the item speaks of a failure" sh -c "! grep -q '^  *- ' '$W/accept'"
check "features: no rule of the item is left, macfilter and ddos_protect are disabled" \
	board '! iptables-save | grep -q -i -E "mac-source|FW_DOS_POLICY" &&
		[ "$(uci -q get macfilter.settings.status)" = disable ] && [ "$(uci -q get ddos_protect.common.status)" = disable ] &&
		! uci -q show client_control | grep -q hwaccel-test'
# The whitelist of macfilter, which the item does not use: a listed client
# gets out and the replies to it come back, though they carry another MAC
# address; a client that is not on the list is stopped.
MACFILTER=/etc/bmcweb/backend/scripts/firewall/macfilter.sh
board "bash $MACFILTER enable; bash $MACFILTER mode whitelist; bash $MACFILTER add 52:54:00:12:34:5C" >/dev/null 2>&1
check "macfilter whitelist: the listed LAN client reaches the wan side" \
	board 'ip netns exec client ping -c 2 -W 2 10.0.2.2'
board "bash $MACFILTER remove 52:54:00:12:34:5C; bash $MACFILTER add 02:00:00:00:00:98" >/dev/null 2>&1
check "macfilter whitelist: the LAN client, no longer listed, is stopped" \
	board '! ip netns exec client ping -c 2 -W 2 10.0.2.2'
board "bash $MACFILTER remove 02:00:00:00:00:98; bash $MACFILTER mode blacklist; bash $MACFILTER disable" >/dev/null 2>&1
check "macfilter whitelist: taken away, the client gets out and nothing is left" \
	board 'ip netns exec client ping -c 2 -W 2 10.0.2.2 && ! iptables-save | grep -q -i "mac-source" &&
		[ "$(uci -q get macfilter.settings.mode)" = blacklist ] && [ "$(uci -q get macfilter.settings.status)" = disable ]'

# ---- the proxy and the HTTP file tracker

check "squid and the ICAP server run after the boot, as on the 24.10 firmware" \
	board 'pidof squid >/dev/null && pidof c-icap >/dev/null && netstat -ltn | grep -q ":3128 " && netstat -ltn | grep -q ":1344 "'
check "the HTTP file tracker does not run until it is enabled" board '[ -z "$(pidof http-file-tracker)" ]'
dd if=/dev/urandom of="$W/hwaccel-proxy.bin" bs=1024 count=2048 2>/dev/null
board 'cp /etc/config/http-file-tracker /tmp/tracker.before'
export SERVER=10.0.2.2 HTTP_PORT=$WEB_PORT
accept proxy
# Under emulation the tracker now and then logs nothing for a download (2 of
# 12 while this was written, without a line of its own about it): the item is
# then run once more.
grep -q 'logged by the tracker 1 time' "$W/accept" || accept proxy
unset SERVER HTTP_PORT
# No ClamAV in the image: the antivirus service has nothing to scan with, and
# squid gives the client its error page. The forwarded download is the one
# the tracker can log here.
check "acceptance: proxy sends the download to squid, which asks the ICAP server; forwarded, the tracker logs it" \
	result proxy 'FAIL  PC1 192\.168\.5\.10; through squid: HTTP 500 from squid, as nothing can be scanned without ClamAV \(not in the image\); without squid \(not judged\): HTTP 200, 2097152 bytes, logged by the tracker 1 time\(s\), bmchwaccel status unavailable, 0 accelerated$'
check "acceptance: proxy fails on the state of hardware acceleration only" \
	sh -c "[ \"\$(grep -c '^  *- ' '$W/accept')\" = 1 ] && grep -q '^  *- bmchwaccel status says unavailable, need on\$' '$W/accept'"
check "proxy: the tracker names the client, the server and the file" \
	grep -q "^proxy  *the tracker: .*client_ip=192\.168\.5\.10 .*uri=/hwaccel-proxy\.bin .*bytes_transferred=2097152 " "$W/accept"
check "proxy: the rule to squid is gone" board '! iptables -t nat -S | grep -q "to-ports 3128"'
check "proxy: the configuration of the tracker is as it was" board 'cmp -s /etc/config/http-file-tracker /tmp/tracker.before'
check "proxy: the tracker is stopped again" board 'sleep 3; [ -z "$(pidof http-file-tracker)" ]'

# What the firewall features have saved comes back with the next boot
# (ticket 22). ddos_protect gets a port without a cable here: on br-lan its
# limit of new SSH connections would count those of this test.
FEATURES_ORDER='iptables -S FORWARD | awk "/!fw3/ { exit }
		/ -j (FW_DOS_POLICY|MAC_FILTER|CLIENTCTL)\$/ { n++; if (nat) late = 1 }
		/ -j nat_one2one\$/ { nat = 1 }
		END { exit !(n == 3 && nat && !late) }" &&
	iptables -S INPUT | awk "/!fw3/ { exit } / -j FW_DOS_POLICY\$/ { n++ } END { exit !n }"'
board 'S=/etc/bmcweb/backend/scripts
	uci set ddos_protect.common.interface=eth3 && uci commit ddos_protect
	bash $S/firewall/ddos_protect.sh set enable
	bash $S/firewall/macfilter.sh enable; bash $S/firewall/macfilter.sh add 02:00:00:00:00:99
	bash $S/firewall/client_control.sh set hwaccel-boot 02:00:00:00:00:99 00:00 23:59 Mon,Sun
	bash $S/network/nat_one2one.sh set 9 1 hwaccel-boot wan tcp 192.168.5.99
	bash $S/firewall/acl_control.sh set rule 192.168.5.99 8099 lan
	bash $S/firewall/dhcpguard.sh set whitelist 02:00:00:00:00:98 eth4 hwaccel-boot
	bash $S/firewall/dhcpguard.sh set enable true' >/dev/null 2>&1
check "features before the reboot: in FORWARD the chains that stop traffic, then NAT 1:1, then fw3; in INPUT ddos_protect, then fw3" \
	board "$FEATURES_ORDER"
# DHCPGuard and the ACL (ticket 23). The ebtables rules of DHCPGuard are in a
# chain of their own: FORWARD jumps to it, a listed server on its port goes
# back to FORWARD, every other reply of a DHCP server is dropped. Stopping the
# service takes that chain away, not the configuration and not the rule of
# another feature, which a rule added by hand stands for here.
DHCPGUARD_RULES='ebtables -L FORWARD | grep -q -e "^-j DHCPGUARD" &&
	ebtables -L DHCPGUARD | grep -q "policy: RETURN" && [ "$(ebtables -L DHCPGUARD | grep -c -e "-j ")" = 2 ] &&
	ebtables -L DHCPGUARD --Lmac2 | sed -n 4p | grep -i "02:00:00:00:00:98" | grep -e "-i eth4 " | grep -q -e "-j RETURN" &&
	ebtables -L DHCPGUARD | sed -n 5p | grep -e "--ip-sport 67 --ip-dport 68 " | grep -q -e "-j DROP"'
OTHER_RULE='ebtables -L FORWARD --Lmac2 | grep -i "02:00:00:00:00:97" | grep -q -e "-j ACCEPT"'
ACL_RULES='iptables -S | grep -q "ACL_ALLOW_lan_192\.168\.5\.99_8099.* -j ACCEPT" && iptables -S | grep -q "ACL_DENY_lan_8099.* -j reject"'
check "dhcpguard: enabled by the script of the web UI, its chain has the listed server and the drop" board "$DHCPGUARD_RULES"
check "acl_control: the rule set by the script of the web UI is in the firewall" board "$ACL_RULES"
check "dhcpguard: stopping the service takes its chain away, not the configuration and not the rule of another feature" \
	board "ebtables -A FORWARD -s 02:00:00:00:00:97 -j ACCEPT && /etc/init.d/dhcpguard stop &&
		! ebtables -L DHCPGUARD 2>/dev/null && ! ebtables -L FORWARD | grep -q DHCPGUARD && $OTHER_RULE &&
		[ \"\$(uci -q get dhcpguard.main.enabled)\" = 1 ] && uci -q show dhcpguard | grep -q hwaccel-boot"
check "dhcpguard: starting the service puts the chain back, in front of the other rule" \
	board "/etc/init.d/dhcpguard start && $DHCPGUARD_RULES && $OTHER_RULE &&
		ebtables -L FORWARD | sed -n 4p | grep -q -e '^-j DHCPGUARD'"
board 'ebtables -D FORWARD -s 02:00:00:00:00:97 -j ACCEPT'
# A boot with hardware acceleration disabled does not touch the modules.
boot_id=$(board 'cat /proc/sys/kernel/random/boot_id')
check "bmchwaccel disable saves the choice" \
	board 'bmchwaccel disable | grep -q "^{\"status\":0,.*\"enabled\":false" && [ "$(uci -q get bmchwaccel.global.enabled)" = 0 ]'
board 'reboot'
wait_board "[ \"\$(cat /proc/sys/kernel/random/boot_id)\" != '$boot_id' ] && logread | grep -q 'init complete'" || exit 1
check "disabled: the boot did not try to load the modules" not_tried
check "features after the reboot: the rules of macfilter, client_control, NAT 1:1 and ddos_protect are back" \
	board 'sleep 5
		iptables -S MAC_FILTER | grep -q -i -- "--mac-source 02:00:00:00:00:99 -j DROP" &&
		iptables -S CLIENTCTL | grep -q -i -- "--mac-source 02:00:00:00:00:99 .*-m time .*-j DROP" &&
		iptables -t nat -S ZONE_NAT_11 | grep -q -- "-j DNAT --to-destination 192.168.5.99" &&
		[ "$(iptables -S FW_DOS_POLICY | grep -c -- "-i eth3 .*-j DROP")" = 4 ] &&
		[ "$(uci -q get ddos_protect.common.status)" = enable ]'
check "features after the reboot: the same order of the chains" board "$FEATURES_ORDER"
check "dhcpguard after the reboot: its chain is back with the listed server and the drop" board "$DHCPGUARD_RULES"
check "acl_control after the reboot: fw3 has put the rule back, without a service" board "$ACL_RULES"
check "features: a firewall restart leaves the chains where they are" \
	board "/etc/init.d/firewall restart >/dev/null 2>&1; sleep 3
		$FEATURES_ORDER && $DHCPGUARD_RULES && $ACL_RULES"
board 'S=/etc/bmcweb/backend/scripts
	bash $S/firewall/dhcpguard.sh del whitelist 02:00:00:00:00:98 eth4; bash $S/firewall/dhcpguard.sh set enable false
	bash $S/firewall/acl_control.sh del rule-index 0
	bash $S/firewall/ddos_protect.sh set disable
	uci set ddos_protect.common.interface=br-lan && uci commit ddos_protect
	bash $S/firewall/macfilter.sh remove 02:00:00:00:00:99; bash $S/firewall/macfilter.sh disable
	bash $S/firewall/client_control.sh del hwaccel-boot
	bash $S/network/nat_one2one.sh del 9' >/dev/null 2>&1
check "features: what the reboot check saved is gone" \
	board '! iptables-save | grep -q -E "02:00:00:00:00:99|192\.168\.5\.99|FW_DOS_POLICY" &&
		! uci -q show client_control | grep -q hwaccel-boot && ! uci -q show nat11 | grep -q hwaccel-boot &&
		[ "$(uci -q get macfilter.settings.status)" = disable ] && [ "$(uci -q get ddos_protect.common.status)" = disable ]'
check "dhcpguard, acl_control: what the reboot check saved is gone" \
	board "$DHCPGUARD_GONE"' &&
		! iptables -S | grep -q "ACL_" && ! uci -q show firewall | grep -q "ACL_" && ! uci -q show acl_control | grep -q "=rule$"'
check "disabled: bmchwaccel status says off" \
	board 'bmchwaccel status | grep -q "\"state\":\"off\",\"enabled\":false,\"accelerated\":0"'
# Enabling tries at once, without a reboot; it cannot succeed here.
check "bmchwaccel enable saves the choice and tries to start" \
	board 'out=$(bmchwaccel enable); [ $? = 1 ] && echo "$out" | grep -q "^{\"status\":-1,\"message\":\"Saved, but " &&
		[ "$(uci -q get bmchwaccel.global.enabled)" = 1 ]'
check "enabled again: the modules were tried" tried

# The mark of two boots in a row that the module load broke: the next boot
# leaves the modules alone and says so, until hardware acceleration is enabled
# again.
boot_id=$(board 'cat /proc/sys/kernel/random/boot_id')
board 'echo 2 > /etc/bmcHwAccel/loading; sync; reboot'
wait_board "[ \"\$(cat /proc/sys/kernel/random/boot_id)\" != '$boot_id' ] && logread | grep -q 'init complete'" || exit 1
check "after two failed boots: the boot did not try to load the modules" not_tried
check "after two failed boots: bmchwaccel status says unavailable, boot_skipped" \
	board 'bmchwaccel status | grep -q "\"state\":\"unavailable\",\"reason\":\"boot_skipped\",\"enabled\":true"'
check "after two failed boots: syslog has one bmcHwAccel line for it" \
	board '[ "$(logread | grep -c "bmcHwAccel: Tăng tốc phần cứng unavailable: not started after two failed boots")" = 1 ]'
check "after two failed boots: bmchwaccel apply leaves the modules alone" \
	board 'out=$(bmchwaccel apply); [ $? = 1 ] && echo "$out" | grep -q "\"reason\":\"boot_skipped\",\"action\":\"skip\""'
check "after two failed boots: still not tried, the mark is kept" not_tried
check "the mark is kept" board '[ "$(cat /etc/bmcHwAccel/loading)" = 2 ]'
check "bmchwaccel enable forgets the failed boots and tries" \
	board 'out=$(bmchwaccel enable); [ $? = 1 ] && echo "$out" | grep -q "\"reason\":\"module\",\"action\":\"start\"" &&
		[ ! -e /etc/bmcHwAccel/loading ]'
check "enabled after two failed boots: the modules were tried" tried
stop_vm
fi

# ---- second boot: no DHCP server on wan; the VLAN and PPPoE items

if boots isp; then
echo "== boot without a DHCP server on wan =="
start_vm isp
wait_board 'iptables -S | grep -q zone_lan_forward && ubus call network.interface.lan status | grep -q "\"up\": true"' || exit 1

# This boot is of a fresh image too, in security mode nac; its items measure
# a LAN that forwards.
board 'uci set dhcp.lan.force=1 && uci commit dhcp
	BMC_ADMIN_IP=192.168.5.2 bash /etc/bmcweb/backend/scripts/firewall/bmcfido.sh set mode off >/dev/null 2>&1'
check "security mode off before the traffic items" board '[ "$(uci -q get system.@system[0].security_mode)" = off ]'

# PC1 with a second address in VLAN 10; what it sends from that address leaves
# through the VLAN.
lan_client
board 'cp /usr/bin/iperf3 /tmp/iperf3-client &&
	ip netns exec client ip link add link eth6 name eth6.10 type vlan id 10 &&
	ip netns exec client ip link set eth6.10 up &&
	ip netns exec client ip addr add 192.168.10.10/24 dev eth6.10 &&
	ip netns exec client ip rule add from 192.168.10.10 table 10 &&
	ip netns exec client ip route add default via 192.168.10.1 table 10' || fail "cannot set up VLAN 10 on the LAN client"
# PC2 on the wan port: iperf3 servers and a PPPoE server, no DHCP server.
board 'cat > /tmp/pppoe-server && chmod +x /tmp/pppoe-server' < "$PPPOE_SERVER_BIN"
board 'ip netns add isp && ip link set eth7 netns isp &&
	ip netns exec isp ip link set lo up &&
	ip netns exec isp ip link set eth7 up &&
	ip netns exec isp ip addr add 192.168.2.10/24 dev eth7 &&
	ip netns exec isp iperf3 -s -D &&
	ip netns exec isp iperf3 -s -p 5202 -D &&
	printf "noauth\nmtu 1492\nmru 1492\n" > /tmp/pppoe-server-options &&
	ip netns exec isp /tmp/pppoe-server -k -I eth7 -L 10.99.0.1 -R 10.99.0.2 -N 1 -O /tmp/pppoe-server-options' ||
	fail "cannot set up the wan side"
# PC2 moved to a br-lan port, in VLAN 20.
board 'ip netns add host2 && ip link set eth8 netns host2 &&
	ip netns exec host2 ip link set lo up &&
	ip netns exec host2 ip link set eth8 up &&
	ip netns exec host2 ip link add link eth8 name eth8.20 type vlan id 20 &&
	ip netns exec host2 ip link set eth8.20 up &&
	ip netns exec host2 ip addr add 192.168.20.10/24 dev eth8.20 &&
	ip netns exec host2 ip route add 192.168.10.0/24 via 192.168.20.1 &&
	ip netns exec host2 iperf3 -s -D' || fail "cannot set up the host in VLAN 20"

check "wan has no address" board '[ -z "$(ip -4 -o addr show dev eth0)" ]'
board 'cp /etc/config/network /tmp/network.before; cp /etc/config/firewall /tmp/firewall.before'

accept brlan-wan vlan-wan vlan-vlan pppoe pppoe-drop pppoe-redial
check "acceptance: wan gets the temporary address" \
	result net 'wan eth0 has no address from DHCP; using 192\.168\.2\.1/24 until the script ends$'
# virtio ports have no per-CPU counters and nothing is accelerated, so no
# traffic item can pass here.
check "acceptance: counters of the wan port and of every br-lan port are read" \
	result brlan-wan 'FAIL  [0-9]+ Mbps.* rx packets on the CPU in 10 s: eth0 \?, eth1 \?, eth2 \?, eth3 \?, eth4 \?, eth5 \?; 0 accelerated'
check "brlan-wan: the client's connections are masqueraded to the temporary address" \
	connections brlan-wan 'src=192\.168\.5\.10 dst=192\.168\.2\.10 .* src=192\.168\.2\.10 dst=192\.168\.2\.1 '

check "acceptance: VLAN 10 is added to the board" \
	result net 'VLAN 10 is br-lan\.10 with 192\.168\.10\.1/24 in the lan zone until the script ends$'
check "vlan-wan: iperf3 ran" result vlan-wan 'FAIL  [0-9]+ Mbps'
check "vlan-wan: the connections come from VLAN 10 and are masqueraded" \
	connections vlan-wan 'src=192\.168\.10\.10 dst=192\.168\.2\.10 .* src=192\.168\.2\.10 dst=192\.168\.2\.1 '

check "acceptance: VLAN 20 is added to the board" \
	result net 'VLAN 20 is br-lan\.20 with 192\.168\.20\.1/24 in the lan zone until the script ends$'
check "vlan-vlan: iperf3 ran" result vlan-vlan 'FAIL  [0-9]+ Mbps'
check "vlan-vlan: the connections go from VLAN 10 to VLAN 20 without NAT" \
	connections vlan-vlan 'src=192\.168\.10\.10 dst=192\.168\.20\.10 .* src=192\.168\.20\.10 dst=192\.168\.10\.10 '

check "acceptance: wan dials PPPoE" result net 'wan dials PPPoE on eth0 as hwaccel until the script ends$'
check "pppoe: iperf3 ran" result pppoe 'FAIL  [0-9]+ Mbps'
check "pppoe: the connections are masqueraded to the address of the session" \
	connections pppoe 'src=192\.168\.5\.10 dst=10\.99\.0\.1 .* src=10\.99\.0\.1 dst=10\.99\.0\.2 '

# On the CPU a flow ends with the session; the check that it was accelerated
# before, and the per-CPU counters, cannot pass here.
check "pppoe-drop: the session ends, nothing leaves wan, the session comes back" \
	result pppoe-drop 'FAIL  session [0-9A-F]+ ended for 10 s: [0-9]+ packets left eth0, \? reached the CPU from the LAN ports; back as session [0-9A-F]+ with 10\.99\.0\.2$'
check "pppoe-drop: no reason about packets leaving wan" \
	sh -c "! grep -q 'packets left eth0 while the session was down' '$W/accept'"
check "pppoe-drop: the client was still sending when the session came back" \
	board '[ -e /tmp/killed-pppoe-drop ]'
check "pppoe-drop: the UDP flow runs through the new session" \
	connections pppoe-drop 'udp .*src=192\.168\.5\.10 dst=10\.99\.0\.1 .* src=10\.99\.0\.1 dst=10\.99\.0\.2 '
check "pppoe-redial: iperf3 ran over the new session" result pppoe-redial 'FAIL  [0-9]+ Mbps'
check "pppoe-redial: the connections are masqueraded to the address of the session" \
	connections pppoe-redial 'src=192\.168\.5\.10 dst=10\.99\.0\.1 .* src=10\.99\.0\.1 dst=10\.99\.0\.2 '
check "acceptance: fails without acceleration" [ "$(cat "$W/accept.rc")" = 1 ]

restored() {
	check "$1: the network and firewall configuration are back" \
		board 'cmp -s /etc/config/network /tmp/network.before && cmp -s /etc/config/firewall /tmp/firewall.before'
	check "$1: the saved configuration is removed" board '[ ! -e /etc/hwaccel-orig ]'
	check "$1: wan has no address, no PPPoE session and no VLAN is left" \
		board 'sleep 3; [ -z "$(ip -4 -o addr show dev eth0)" ] && [ ! -e /sys/class/net/pppoe-wan ] &&
			[ ! -e /sys/class/net/br-lan.10 ] && [ ! -e /sys/class/net/br-lan.20 ]'
	check "$1: no rule of the VLANs, of the session or of pppoe-drop is left" \
		board '! iptables-save | grep -q -E "br-lan\.[12]0|pppoe-wan|dport 5202"'
}
restored "after the run"

# From PPPoE back to a plain wan: the script has to find out again that wan
# gets no address by itself.
accept pppoe brlan-wan
check "acceptance: wan dials PPPoE first" result pppoe 'FAIL  [0-9]+ Mbps'
check "acceptance: wan gets the temporary address after PPPoE" \
	result net 'wan eth0 has no address from DHCP; using 192\.168\.2\.1/24 until the script ends$'
check "brlan-wan after PPPoE: the connections are masqueraded to the temporary address" \
	connections brlan-wan 'src=192\.168\.5\.10 dst=192\.168\.2\.10 .* src=192\.168\.2\.10 dst=192\.168\.2\.1 '
restored "after PPPoE then plain"
# What the client's connections looked like, to explain a failed check above.
[ $rc -eq 0 ] || board 'for f in /tmp/ct-*; do echo "== $f"; grep -E "dport=520[12] " $f; done' 2>&1 | sed 's/^/    | /'

# NAT 1:1 and a port forward towards the LAN client, with PC2 on the wan side
# connecting again and again, as the person at PC2 is asked to do once.
board '(while :; do
		ip netns exec isp /tmp/iperf3-client -c 192.168.2.1 -p 5301 -t 1
		ip netns exec isp /tmp/iperf3-client -c 192.168.2.1 -p 5302 -t 1
		sleep 2
	done) > /dev/null 2>&1 < /dev/null &
	echo $! > /tmp/pc2-connects.pid'
export PC1=192.168.5.10
accept features-in
board 'kill "$(cat /tmp/pc2-connects.pid)"'
check "acceptance: features-in sees the connections of PC2 translated to the LAN client and answered" \
	result features-in 'PASS  PC1 192\.168\.5\.10; NAT 1:1 on wan: answered by PC1; port forward wan:5302 to 192\.168\.5\.10:5301: answered by PC1; '
check "features-in: it tells what to run on PC2" \
	grep -q '^features-in  *port forward: on PC2 run now:  iperf3 -c 192\.168\.2\.1 -p 5302 -t 2$' "$W/accept"
check "features-in: neither rule is left" \
	board '! iptables -t nat -S | grep -q -E "DNAT --to-destination 192\.168\.5\.10" && ! uci -q show nat11 | grep -q "rule_99"'
restored "after features-in"

# The web UI dashboard numbers under traffic, read from the real
# get_net_stats.sh of the new-base image (ticket 12 brought it over). Nothing
# is accelerated here, so the item FAILs on the state of hardware acceleration
# and the throughput; what this checks is that the script runs, the harness
# reads its JSON, the connection counts match the kernel's own table and the
# per-interface byte counters were read. The byte band is throughput-dependent
# and not judged here: QEMU has no hardware counters and no fixed speed.
# PC1 is still the LAN client, from features-in; the items after this one
# (bridge, mwan-in) need it as well.
accept stats
check "acceptance: stats reads the dashboard script and compares its counts to the kernel's" \
	sh -c "grep -q '^stats  *FAIL' '$W/accept' && grep -q 'stats .* vs kernel [0-9]' '$W/accept' && ! grep -q 'dashboard script is missing' '$W/accept'"
check "stats: the web UI connection counts are within range of the kernel's table" \
	sh -c "! grep -q 'more than .* apart' '$W/accept'"
check "stats: the web UI reported a TCP and a UDP connection while the runs were on" \
	sh -c "! grep -q -E 'reported no (TCP|UDP) connection' '$W/accept'"
check "stats: the per-interface byte counters were read for the wan and br-lan ports" \
	grep -q '^stats  *FAIL.*bytes in 10 s, eth0 ' "$W/accept"
check "stats: the acceleration state is the expected unavailable (modules blacklisted)" \
	grep -q 'bmchwaccel status says unavailable, need on' "$W/accept"

# The toggle item with the image's own busybox and syslog. Nothing can be
# switched here: the modules do not load, so disabling finds nothing to stop
# and enabling cannot start. The item has to run to its end under one iperf3
# run and leave the feature enabled. Disabling still changes the state, from
# unavailable to off, which syslog gets a line for.
accept toggle
check "toggle: iperf3 ran through the whole item" result toggle 'FAIL  .*iperf3 over both switches: [0-9]+ Mbps'
check "toggle: the board script ran to its end and counted the syslog lines" \
	result toggle 'FAIL  .*syslog: 1 line off, 0 line on$'
check "toggle: every iperf3 stream carried data to the end" [ "$(grep -c 'of the iperf3 streams carried nothing' "$W/accept")" = 0 ]
check "toggle: enabling again was tried" grep -q '^  *- bmchwaccel enable: {"status":-1,"message":"Saved, but ' "$W/accept"
check "toggle: hardware acceleration is left enabled" board '[ "$(uci -q get bmchwaccel.global.enabled)" = 1 ]'

# ---- bmcqos, and what it keeps on the CPU

# The marking rules with the image's own iptables, ip6tables and conntrack.
check "bmcqos is off after a first boot, nothing is kept on the CPU" \
	board '[ "$(uci -q get bmcqos.global.enabled)" = 0 ] && bmchwaccel status | grep -q "\"on_cpu\":\[\]" &&
		! iptables -t mangle -S | grep -q BMCHWACCEL_KEEP'
check "the firewall has the include of bmcHwAccel" \
	board '[ "$(uci -q get firewall.bmchwaccel.path)" = /usr/share/bmcHwAccel/firewall.include ]'
check "bmchwaccel keep: installs the rules for IPv4 and IPv6 and marks every open connection" \
	board 'out=$(bmchwaccel keep qemutest wan eth0) && echo "$out" | grep -q "\"action\":\"install\"" &&
		iptables -t mangle -C FORWARD -j BMCHWACCEL_KEEP &&
		iptables -t mangle -C BMCHWACCEL_KEEP -o eth0 -j CONNMARK --set-xmark 0x10000/0x10000 &&
		ip6tables -t mangle -C BMCHWACCEL_KEEP -i eth0 -j CONNMARK --set-xmark 0x10000/0x10000 &&
		[ "$(conntrack -L 2>/dev/null | grep -c "mark=65536 ")" -ge 1 ]'
check "bmchwaccel status lists it" \
	board 'bmchwaccel status | grep -q "\"on_cpu\":\[{\"scope\":\"wan\",\"device\":\"eth0\",\"reason\":\"qemutest\"}\]"'
check "bmchwaccel keep again: the rules are found, nothing to do" \
	board 'bmchwaccel keep qemutest wan eth0 | grep -q "\"action\":\"none\""'
# What refresh would do is kept: this check has failed under load, and then nothing told why.
check "a firewall reload leaves the rules, or its include puts them back" \
	board '/etc/init.d/firewall reload > /tmp/reload.out 2>&1; bmchwaccel --dry-run refresh > /tmp/refresh-after-reload
		grep -q "\"action\":\"none\"" /tmp/refresh-after-reload'
board 'grep -q "\"action\":\"none\"" /tmp/refresh-after-reload || {
	cat /tmp/refresh-after-reload /tmp/reload.out
	ls -la /var/run/bmcHwAccel
	iptables -w -t mangle -S FORWARD
	ip6tables -w -t mangle -S FORWARD
	logread | tail -n 30
}' 2>&1 | sed 's/^/    | /'
check "a firewall restart: its include puts the rules back" \
	board '/etc/init.d/firewall restart >/dev/null 2>&1; bmchwaccel --dry-run refresh | grep -q "\"action\":\"none\"" &&
		iptables -t mangle -C BMCHWACCEL_KEEP -o eth0 -j CONNMARK --set-xmark 0x10000/0x10000'
check "syslog has one line per change of what is kept" \
	board '[ "$(logread | grep -c "bmcHwAccel: Tăng tốc phần cứng keeps on the CPU: wan eth0 (qemutest)")" = 2 ]'
# A VLAN on the kept device: what is routed through it passes the same device.
check "a device stacked on the kept one is covered once refresh has seen it, and dropped when it is gone" \
	board 'ip link add link eth0 name eth0.77 type vlan id 77 &&
		bmchwaccel refresh | grep -q "\"action\":\"install\"" &&
		iptables -t mangle -C BMCHWACCEL_KEEP -o eth0.77 -j CONNMARK --set-xmark 0x10000/0x10000 &&
		iptables -t mangle -C BMCHWACCEL_KEEP -i eth0 -j CONNMARK --set-xmark 0x10000/0x10000 &&
		bmchwaccel refresh | grep -q "\"action\":\"none\"" &&
		ip link del eth0.77 && bmchwaccel refresh | grep -q "\"action\":\"install\"" &&
		! iptables -t mangle -S BMCHWACCEL_KEEP | grep -q "eth0\.77"'
check "the hotplug script of bmcHwAccel is in the image" board '[ -x /etc/hotplug.d/iface/20-bmcHwAccel ]'
check "bmchwaccel release: the rules are gone and no connection carries the mark" \
	board 'bmchwaccel release qemutest | grep -q "\"action\":\"remove\"" &&
		! iptables -t mangle -S | grep -q BMCHWACCEL_KEEP && ! ip6tables -t mangle -S | grep -q BMCHWACCEL_KEEP &&
		[ "$(conntrack -L 2>/dev/null | grep -c "mark=65536 ")" = 0 ] &&
		bmchwaccel status | grep -q "\"on_cpu\":\[\]"'

# bmcqos on wan at 100 Mbps through the items of acceptance.sh. Nothing is
# accelerated here, so each ends in FAIL; the limit, the registration and the
# marks have to be right. A connection through wan has the mark of bmcHwAccel
# next to the class bmcqos gave it (0x10080 and up); one from VLAN to VLAN
# has neither.
board 'cp /etc/config/bmcqos /tmp/bmcqos.before'
accept qos qos-back qos-vlan-vlan
check "qos: bmcqos shapes both ways on this kernel and is listed as kept on the CPU, then no longer" \
	sh -c "! grep -q -E 'did not shape|does not list|still lists' '$W/accept'"
check "qos: what PC1 sends through wan stays at the limit" \
	result qos 'FAIL  bmcqos on wan eth0 at 100 Mbps: (8[0-9]|9[0-9]|10[0-5]) Mbps'
check "qos-back: what comes in through wan stays at the limit" \
	result qos-back 'FAIL  bmcqos on wan eth0 at 100 Mbps: (8[0-9]|9[0-9]|10[0-5]) Mbps'
check "qos: no reason about the limit" sh -c "! grep -q -E 'above the limit|below 80 percent' '$W/accept'"
check "qos: every connection through wan carries the mark" \
	board 'grep -E "dport=5201 " /tmp/ct-qos | grep -q -E "mark=65[5-7][0-9][0-9] " &&
		! grep -E "dport=5201 " /tmp/ct-qos | grep -q -v -E "mark=65[5-7][0-9][0-9] "'
check "qos-back: every connection through wan carries the mark" \
	board 'grep -E "dport=5201 " /tmp/ct-qos-back | grep -q -E "mark=65[5-7][0-9][0-9] " &&
		! grep -E "dport=5201 " /tmp/ct-qos-back | grep -q -v -E "mark=65[5-7][0-9][0-9] "'
check "qos-vlan-vlan: VLAN to VLAN is not limited" \
	result qos-vlan-vlan 'FAIL  bmcqos on wan eth0 at 100 Mbps: ([2-9][0-9][0-9]|[0-9]{4,}) Mbps'
check "qos-vlan-vlan: its connections carry no mark" \
	board 'grep -q "dst=192\.168\.20\.10 .*dport=5201 .*mark=0 " /tmp/ct-qos-vlan-vlan &&
		! grep "dst=192\.168\.20\.10 .*dport=5201 " /tmp/ct-qos-vlan-vlan | grep -q -v "mark=0 "'
check "after the qos items: the bmcqos configuration is back, nothing shapes, nothing is kept" \
	board 'cmp -s /etc/config/bmcqos /tmp/bmcqos.before && [ ! -e /etc/hwaccel-orig-bmcqos ] &&
		! tc qdisc show dev eth0 | grep -q cake && [ ! -e /sys/class/net/ifb-eth0 ] &&
		! iptables -t mangle -S | grep -q -E "BMCHWACCEL_KEEP|BMCQOS" &&
		bmchwaccel status | grep -q "\"on_cpu\":\[\]"'
restored "after the qos items"

# The trial item: its rule marks the connections to the second server only.
accept keep-mark
check "keep-mark: both runs were made" \
	result keep-mark 'FAIL  marked connections \(port 5202\): [0-9]+ Mbps, .*; other connections: [0-9]+ Mbps, '
check "keep-mark: the connections to the second server carry the mark, the others do not" \
	board 'grep "dport=5202 " /tmp/ct-keep-mark | grep -q "mark=65536 " &&
		! grep "dport=5202 " /tmp/ct-keep-mark | grep -q -v "mark=65536 " &&
		grep "dport=5201 " /tmp/ct-keep-mark-other | grep -q "mark=0 " &&
		! grep "dport=5201 " /tmp/ct-keep-mark-other | grep -q -v "mark=0 "'
check "keep-mark: its rule is taken away" board '! iptables -t mangle -S FORWARD | grep -q "dport 5202"'

# Traffic between two br-lan ports, through the bridge items of acceptance.sh:
# the host in VLAN 20 also gets an address of br-lan without a VLAN and is PC2
# on another br-lan port than the LAN client. The daemon cannot run here, so
# nothing is in the hardware and the items end in FAIL; what has to be right
# is that the board finds the two ports, that the traffic is bridged, that
# macfilter and client_control, told to block by the scripts of the web UI,
# stop a running flow between the two ports, and so do the rules of the
# blocked services and of bmcfido as the item sets them up; and that the
# firewall notes the two ends of the bridged flow, for the sweep that has the
# kernel learn their neighbours.
board 'ip netns exec host2 ip addr add 192.168.5.20/24 dev eth8 &&
	ip netns exec host2 iperf3 -s -p 5202 -D' || fail "cannot set up the host on a second br-lan port"
export BRIDGE_SERVER=192.168.5.20
# bmcfirewall after a firewall restart and after a start with new chains
# (ticket 26): its DNS redirect and the chains of the blocked services are put
# back by its firewall include, and the daemon writes the rules of the
# services that are blocked, here one set through its API.
svc_api() { # the JSON of the blocked services
	board "i=0; while [ \$i -lt 20 ]; do
		[ \"\$(curl -sk -m 5 -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/json' -d '$1' https://127.0.0.1:6677/control/blocked_services/update)\" = 200 ] && exit 0
		sleep 3; i=\$((i + 1)); done; exit 1"
}
svc_there() {
	board 'i=0; while [ $i -lt 10 ]; do
		iptables -w -C FORWARD -j BMC_SVC4 && ip6tables -w -C FORWARD -j BMC_SVC6 &&
			[ "$(iptables -w -S BMC_SVC4 | grep -c -- "--match-set .* dst")" = 2 ] &&
			[ "$(ip6tables -w -S BMC_SVC6 | grep -c -- "--match-set .* dst")" = 2 ] &&
			iptables -w -t nat -C PREROUTING -j BMCFIREWALL_DNS &&
			[ "$(iptables -w -t nat -S BMCFIREWALL_DNS | grep -c -- "--dport 53 -j DNAT")" = 2 ] && exit 0
		sleep 2; i=$((i + 1)); done; exit 1'
}
check "the firewall has the include of bmcfirewall" \
	board '[ "$(uci -q get firewall.bmcfirewall.path)" = /usr/share/bmcfirewall/firewall.include ]'
svc_block() { svc_api '{"ids":["4chan"],"schedule":{"time_zone":"UTC"}}' && svc_there; }
svc_clear() { svc_api '{"ids":[],"schedule":{"time_zone":"UTC"}}'; }
check "bmcfirewall: a service blocked through the API gets its rules" svc_block
check "bmcfirewall: a firewall reload leaves its rules" \
	board '/etc/init.d/firewall reload >/dev/null 2>&1; iptables -w -C FORWARD -j BMC_SVC4 &&
		[ "$(iptables -w -S BMC_SVC4 | grep -c -- "--match-set .* dst")" = 2 ]'
board '/etc/init.d/firewall restart >/dev/null 2>&1'
check "bmcfirewall: after a firewall restart the DNS redirect, the chains and the rules of the service are back" svc_there
board '/etc/init.d/bmcfirewall stop >/dev/null 2>&1; sleep 2
	iptables -w -D FORWARD -j BMC_SVC4; iptables -w -F BMC_SVC4; iptables -w -X BMC_SVC4
	ip6tables -w -D FORWARD -j BMC_SVC6; ip6tables -w -F BMC_SVC6; ip6tables -w -X BMC_SVC6
	/etc/init.d/bmcfirewall start >/dev/null 2>&1' >/dev/null 2>&1
check "bmcfirewall: started with new chains, as after a boot, it writes the rules of the service" svc_there
check "bmcfirewall: the service is no longer blocked, through the API" svc_clear
check "bmcfirewall: the chains are empty and still in FORWARD" \
	board 'sleep 2; iptables -w -C FORWARD -j BMC_SVC4 && ! iptables -w -S BMC_SVC4 | grep -q match-set'
accept bridge bridge-block bridge-neigh
check "bridge: the board finds the ports of the two hosts and the traffic is bridged" \
	result bridge 'FAIL  eth2 -> eth4: [0-9]+ Mbps, '
check "bridge: the connection went from the LAN client to the host, without NAT" \
	board 'grep "dport=5201 " /tmp/ct-bridge-flow | grep "src=192\.168\.5\.10 dst=192\.168\.5\.20 " | grep -q "src=192\.168\.5\.20 dst=192\.168\.5\.10 "'
for f in macfilter client_control 'blocked services' bmcfido; do
	check "bridge-block: $f, told to block, stops a running flow between the two ports" \
		grep -q -E "^ +\| $f: \? rx packets of eth2 on the CPU and [0-9]{4,} out of eth4 in 10 s; under the rule [0-9]{1,3} out of eth4, [0-9]{4,} counted by the rule: " "$W/accept"
done
check "bridge items: no rule and no mark of theirs is left" \
	board '! iptables -S MAC_FILTER | grep -q mac-source && ! iptables -S CLIENTCTL | grep -q mac-source && [ ! -e /tmp/hwaccel-bridge-did ] &&
		! iptables -S BMC_SVC4 | grep -q match-set && ! iptables -S BMC_FIDO 2>/dev/null | grep -q . &&
		! ls /var/run/bmcHwAccel/sweep-only-* >/dev/null 2>&1'
check "bridge-neigh: the flow is read before and after the sweep" \
	result bridge-neigh 'FAIL  eth2 -> eth4, the board having no neighbour entry of 192\.168\.5\.20: \? rx packets of eth2 on the CPU and [0-9]{4,} out of eth4 in 10 s; after bmchwaccel sweep \? on the CPU and [0-9]{4,} out of eth4$'
check "bridge-neigh: the firewall noted the far end of the bridged flow, and cron runs the sweep" \
	sh -c "! grep -q -E 'did not note|cron does not run' '$W/accept'"
check "the ends of bridged connections are noted for bmchwaccel sweep, in both families" \
	board 'ipset list -n bmchwaccel_bridged >/dev/null && ipset list -n bmchwaccel_bridged6 >/dev/null &&
		iptables -t mangle -S FORWARD | grep -q "physdev-is-bridged .*add-set bmchwaccel_bridged dst" &&
		ip6tables -t mangle -S FORWARD | grep -q "physdev-is-bridged .*add-set bmchwaccel_bridged6 src"'
check "who opens connections is noted for bmchwaccel sweep, which cron runs" \
	board 'ipset list -n bmchwaccel_hosts >/dev/null && iptables -t mangle -S FORWARD | grep -q "add-set bmchwaccel_hosts src,src" && grep -q "bmchwaccel sweep" /etc/crontabs/root'
check "the daemon is started with -B unless the option says otherwise" \
	board 'grep -q "^bridge=-B\$" /usr/sbin/cmm-supervise && grep -q "bmchwaccel.global.bridge" /usr/sbin/cmm-supervise'
# DHCPGuard between the two ports (ticket 23): the host stands for a DHCP
# server on another br-lan port than the LAN client. iperf3 sends what such a
# server answers with, UDP from port 67 to port 68 of the client; its TCP
# control connection is not what DHCPGuard looks at. A run that has not ended
# after 15 s did not get its UDP through.
dhcp_reply() {
	board 'ip netns exec client iperf3 -s -p 68 -1 -D -I /tmp/dhcpguard-server.pid; sleep 1
		ip netns exec host2 iperf3 -c 192.168.5.10 -u -b 200k -t 1 -p 68 --cport 67 >/dev/null 2>&1 & c=$!
		n=0; while kill -0 $c 2>/dev/null && [ $n -lt 15 ]; do sleep 1; n=$((n + 1)); done
		if kill $c 2>/dev/null; then r=1; else wait $c; r=$?; fi
		s=$(cat /tmp/dhcpguard-server.pid); kill "$s" 2>/dev/null; rm -f /tmp/dhcpguard-server.pid
		n=0; while kill -0 "$s" 2>/dev/null && [ $n -lt 5 ]; do sleep 1; n=$((n + 1)); done
		exit $r'
}
no_dhcp_reply() { ! dhcp_reply; }
DHCPGUARD=/etc/bmcweb/backend/scripts/firewall/dhcpguard.sh
host2_mac=$(board 'ip netns exec host2 cat /sys/class/net/eth8/address')
check "dhcpguard: disabled, the reply of a DHCP server on another port reaches the LAN client" dhcp_reply
board "bash $DHCPGUARD set enable true" >/dev/null 2>&1
check "dhcpguard: enabled, that reply is stopped" no_dhcp_reply
check "dhcpguard: other traffic between the two ports goes on" board 'ip netns exec client ping -c 2 -W 3 192.168.5.20'
board "bash $DHCPGUARD set whitelist $host2_mac eth2 hwaccel-test" >/dev/null 2>&1
check "dhcpguard: the host's server listed on another port than its own is still stopped" no_dhcp_reply
board "bash $DHCPGUARD del whitelist $host2_mac eth2; bash $DHCPGUARD set whitelist $host2_mac eth4 hwaccel-test" >/dev/null 2>&1
check "dhcpguard: listed on its port, the reply reaches the LAN client" dhcp_reply
board "bash $DHCPGUARD del whitelist $host2_mac eth4; bash $DHCPGUARD set enable false" >/dev/null 2>&1
check "dhcpguard: disabled again, nothing of it is left" board "$DHCPGUARD_GONE"
# The host's address in br-lan goes again: the ospf items reach the LAN client
# through the board, not on the cable.
board 'ip netns exec host2 ip addr del 192.168.5.20/24 dev eth8' || fail "cannot take the host's br-lan address away"
restored "after the bridge items"

# IPsec through the script of the VPN page, with the image's own strongSwan on
# both ends: the board gets a wan address and a tunnel between br-lan and a
# network behind the host on the wan side, where a second strongSwan runs in
# the namespace of that host, with a /var/run and configuration files of its
# own. What the LAN client sends to that network has to arrive there through
# the tunnel and without NAT. The mount that gives the second strongSwan its
# /var/run is made only in the mount namespace "ip netns exec" starts it in. Here the kernel encrypts and decrypts; that the
# hardware does it next to a running daemon only the board can show.
VPN=/etc/bmcweb/backend/scripts/network/vpn_handle.sh
board 'mkdir -p /tmp/ipsec-peer/run && cd /tmp/ipsec-peer &&
	printf "%s\n" "conn hwaccel" "	auto=add" "	keyexchange=ikev2" "	ike=aes256-sha256-modp2048!" "	esp=aes256-sha256!" \
		"	left=192.168.2.10" "	leftid=@hwaccel-192.168.2.10" "	leftsubnet=10.99.0.0/24" "	leftauth=psk" \
		"	right=192.168.2.1" "	rightid=@hwaccel-192.168.2.1" "	rightsubnet=192.168.5.0/24" "	rightauth=psk" \
		"	type=tunnel" "	forceencaps=yes" > ipsec.conf &&
	echo "@hwaccel-192.168.2.1 @hwaccel-192.168.2.10 : PSK \"hwaccel-test-key\"" > ipsec.secrets &&
	printf "%s\n" "charon {" "	load_modular = yes" "	plugins {" "		include /etc/strongswan.d/charon/*.conf" \
		"		stroke {" "			secrets_file = /tmp/ipsec-peer/ipsec.secrets" "		}" "	}" "}" > strongswan.conf &&
	ip addr add 192.168.2.1/24 dev eth0 && ip netns exec isp ip addr add 10.99.0.1/24 dev lo &&
	ip netns exec isp sh -c "[ \"\$(readlink /proc/self/ns/mnt)\" != \"\$(readlink /proc/1/ns/mnt)\" ] &&
		mount -o bind /tmp/ipsec-peer/run /tmp/run &&
		STRONGSWAN_CONF=/tmp/ipsec-peer/strongswan.conf /usr/lib/ipsec/starter --daemon charon --nofork \
			--conf /tmp/ipsec-peer/ipsec.conf >/tmp/ipsec-peer/log 2>&1 &"' ||
	fail "cannot set up the other end of the IPsec tunnel"
check "ipsec: the other end listens for IKE" \
	wait_board 'ip netns exec isp netstat -lun | grep -q ":500 "'
check "ipsec: the script of the VPN page saves the tunnel" \
	board "bash $VPN set hwaccel 192.168.2.1 192.168.5.0/24 192.168.2.10 10.99.0.0/24 hwaccel-test-key | grep -q '\"status\": 0' &&
		grep -q '^conn hwaccel\$' /etc/ipsec.conf && grep -q 'PSK \"hwaccel-test-key\"' /etc/ipsec.secrets"
check "ipsec: the tunnel comes up" \
	wait_board 'ipsec status | grep -q "hwaccel\[[0-9]*\]: ESTABLISHED" && ipsec status | grep -q "hwaccel{[0-9]*}:  *INSTALLED, TUNNEL"'
check "ipsec: the LAN client reaches the network behind the other end" \
	board 'ip netns exec client ping -c 3 -W 3 10.99.0.1'
# Both ends count what they encrypted and decrypted, and the other end takes
# nothing for that network that did not come through the tunnel.
IPSEC_COUNTED='ip -s xfrm state | awk "/current:/ { getline; sub(/.packets.*/, \"\"); if (\$NF + 0 >= 3) n++ } END { exit !(n >= 2) }"'
check "ipsec: the pings went through the tunnel, both ways, on both ends" \
	board "$IPSEC_COUNTED && ip netns exec isp sh -c '$IPSEC_COUNTED'"
check "ipsec: the ping was not masqueraded" \
	board 'conntrack -L -p icmp 2>/dev/null | grep "src=192.168.5.10 dst=10.99.0.1 " | grep -q "src=10.99.0.1 dst=192.168.5.10 "'
board "bash $VPN del hwaccel >/dev/null 2>&1; sleep 2
	kill \$(cat /tmp/ipsec-peer/run/starter.charon.pid /tmp/ipsec-peer/run/charon.pid 2>/dev/null) 2>/dev/null; sleep 2
	ip netns exec isp ip xfrm state flush; ip netns exec isp ip xfrm policy flush
	ip netns exec isp ip addr del 10.99.0.1/24 dev lo; ip addr del 192.168.2.1/24 dev eth0; rm -rf /tmp/ipsec-peer" >/dev/null 2>&1
check "ipsec: the tunnel is taken away and nothing of it is left" \
	board '! grep -q "^conn " /etc/ipsec.conf && ! grep -q hwaccel /etc/ipsec.secrets && [ -z "$(ip xfrm state)" ] &&
		! iptables-save | grep -q -e "--pol ipsec" -e "zone_wan_input -p esp" -e "dport 4500" && ! ip netns exec isp netstat -lun | grep -q ":500 "'
restored "after the IPsec tunnel"

# Multi-WAN with two WANs through the mwan items of acceptance.sh, with the
# image's own mwan3, bmcmultiwan and conntrack: the port of the host in VLAN
# 20 becomes wan2 and that host ISP B, and both ISPs answer for the two
# addresses that stand for the Internet. Nothing is accelerated here, so the
# results end in FAIL; which WAN a connection takes, the two Chuyển WAN and
# what is left of the item afterwards have to be right. The daemon of
# hardware acceleration cannot run here: a service with its name stands in
# for it, so that bmcMultiWAN removes the connections of the WAN that is Mất
# Internet as it does next to a running daemon. Without that the flow would
# stay on wan2, where mwan3 leaves open connections.
board 'for ns in isp host2; do
		ip netns exec $ns ip addr add 198.51.100.1/32 dev lo &&
			ip netns exec $ns ip addr add 198.51.100.2/32 dev lo || exit 1
	done
	ip netns exec host2 ip addr add 192.168.3.10/24 dev eth8 &&
	{ ip netns exec host2 netstat -ltn | grep -q ":5202 " || ip netns exec host2 iperf3 -s -p 5202 -D; } &&
	ip netns exec host2 iperf3 -s -B 198.51.100.2 -p 5203 -D &&
	ip netns exec isp iperf3 -s -B 198.51.100.2 -p 5203 -D &&
	cp /etc/config/mwan3 /tmp/mwan3.before && cp /etc/config/bmcMultiWAN /tmp/bmcMultiWAN.before &&
	ubus call service set "{\"name\":\"cmm\",\"instances\":{\"standin\":{\"command\":[\"/bin/sleep\",\"3600\"]}}}"' ||
	fail "cannot set up the two ISPs"
export MWAN_PORT=eth4
accept mwan
check "mwan-default: iperf3 ran, and its packets left the wan port, not the wan2 port" \
	result mwan-default 'FAIL  [0-9]+ Mbps.*; in 10 s [0-9]{4,} packets left eth0 \(wan\) and [0-9]{1,3} eth4 \(wan2\); '
check "mwan-default: what matches no Luật chọn WAN leaves through wan" \
	board 'grep "dport=5201 " /tmp/ct-mwan-default | grep -q "dst=198\.51\.100\.1 .* dst=192\.168\.2\.1 " &&
		! grep "dport=5201 " /tmp/ct-mwan-default | grep -q "dst=192\.168\.3\.1 "'
check "mwan-rule: iperf3 ran, and its packets left the wan2 port, not the wan port" \
	result mwan-rule 'FAIL  [0-9]+ Mbps.*; in 10 s [0-9]{4,} packets left eth4 \(wan2\) and [0-9]{1,3} eth0 \(wan\); '
check "mwan-rule: what matches the Luật chọn WAN leaves through wan2" \
	board 'grep "dport=5201 " /tmp/ct-mwan-rule | grep -q "dst=198\.51\.100\.2 .* dst=192\.168\.3\.1 " &&
		! grep "dport=5201 " /tmp/ct-mwan-rule | grep -q "dst=192\.168\.2\.1 "'
check "mwan-lost: wan2 is Mất Internet, its connections are removed and the flow leaves through wan" \
	result mwan-lost 'FAIL  Chuyển WAN after [0-9]+ s \(Chuyển WAN: wan2 is Mất Internet; .*hwaccel_b now uses wan\); [1-9][0-9]* connection\(s\) removed; in 10 s after it [0-9]{1,3} packets left eth4 \(wan2\) and [0-9]{4,} eth0 \(wan\); PC1 was still sending; new connection: [0-9]+ Mbps, '
check "mwan: no reason about a connection removed, a flow that stayed or packets through the other WAN" \
	sh -c "! grep -q -E 'removed no connection|still flow into|did not move to wan|does not leave through|the traffic leaves through' '$W/accept'"
check "mwan-lost: the UDP flow went on through wan" \
	board '[ -e /tmp/killed-mwan-lost ] &&
		grep "^udp .*dport=5203 " /tmp/ct-mwan-lost | grep -q "dst=198\.51\.100\.2 .* dst=192\.168\.2\.1 "'
check "mwan-lost: a new connection leaves through wan" \
	board 'grep "dport=5201 " /tmp/ct-mwan-new | grep -q "dst=198\.51\.100\.2 .* dst=192\.168\.2\.1 " &&
		! grep "dport=5201 " /tmp/ct-mwan-new | grep -q "dst=192\.168\.3\.1 "'
check "mwan-back: wan2 has Internet again under an open connection, and a new one ran" \
	result mwan-back 'FAIL  Chuyển WAN after [0-9]+ s \(Chuyển WAN: wan2 has Internet again; .*hwaccel_b now uses wan2\); open connection: 0 accelerated through wan; new connection: [0-9]+ Mbps beside it, '
check "mwan-back: the open connection stays on wan to its end, the new one leaves through wan2" \
	board '[ -e /tmp/killed-mwan-back-old ] &&
		grep "dport=5201 " /tmp/ct-mwan-back-new | grep -q "dst=198\.51\.100\.2 .* dst=192\.168\.2\.1 " &&
		! grep "dport=5201 " /tmp/ct-mwan-back-new | grep -q "dst=192\.168\.3\.1 " &&
		grep "dport=5202 " /tmp/ct-mwan-back-new | grep -q "dst=198\.51\.100\.2 .* dst=192\.168\.3\.1 " &&
		! grep "dport=5202 " /tmp/ct-mwan-back-new | grep -q "dst=192\.168\.2\.1 "'
mwan_gone() {
	check "$1: the Multi-WAN configuration is back, mwan3 is stopped and eth4 is a br-lan port again" \
		board 'cmp -s /etc/config/mwan3 /tmp/mwan3.before && cmp -s /etc/config/bmcMultiWAN /tmp/bmcMultiWAN.before &&
			[ ! -e /etc/hwaccel-orig-mwan ] && [ -e /sys/class/net/br-lan/brif/eth4 ] &&
			! ubus call service list "{\"name\":\"mwan3\"}" | grep -q "\"running\": *true" &&
			! iptables-save | grep -q -E "mwan3|192\.168\.3\.|destination-unreachable -j DROP|dport 5302" &&
			[ -z "$(ip -4 rule show | grep -E "^[123][0-9]{3}:")" ]'
	restored "$1"
}
mwan_gone "after the mwan item"

# A connection from ISP B to the forwarded port of wan2, again and again, as
# the person at that PC is asked to make once. It comes from an address
# outside the network of wan2, so it is answered only when the answers of
# the LAN client leave through wan2 for the mark of the connection, not
# through wan, which the default Chính sách WAN prefers.
board 'rm -f /tmp/isp-b-answered
	(while :; do
		ip netns exec host2 /tmp/iperf3-client -c 192.168.3.1 -p 5302 -B 198.51.100.2 -t 3 && touch /tmp/isp-b-answered
		sleep 2
	done) > /dev/null 2>&1 < /dev/null &
	echo $! > /tmp/isp-b-connects.pid'
export IN_WAIT=40
accept mwan-in
board 'kill "$(cat /tmp/isp-b-connects.pid)"; ubus call service delete "{\"name\":\"cmm\"}"'
check "mwan-in: it tells what to run on the PC of ISP B" \
	grep -q '^mwan-in  *on the PC of ISP B run now:  iperf3 -c 192\.168\.3\.1 -p 5302 -B 198\.51\.100\.2 -t 60 -P 4$' "$W/accept"
check "mwan-in: the connection of ISP B is translated to the LAN client, and not accelerated here" \
	sh -c "grep -q '^mwan-in  *FAIL  PC1 192\.168\.5\.10; wan2:5302 to 192\.168\.5\.10:5301: not seen$' '$W/accept' &&
		grep -q -E '; [1-9][0-9]* such connection\(s\) were translated to 192\.168\.5\.10:5301 at all$' '$W/accept'"
check "mwan-in: the LAN client answered ISP B through wan2" board '[ -e /tmp/isp-b-answered ]'
mwan_gone "after the mwan-in item"

# DynRouting through the ospf items of acceptance.sh, with the image's own
# FRR and bmcdynrouting. The host on eth8 becomes the neighbour router: it
# gets a second port, eth9, on the cable of the board port eth5, an address
# that stands for the network it announces, and a zebra and an ospfd of its
# own (-N: their own sockets, beside the FRR of the board; under other names,
# because bmcdynrouting looks for the daemons of the board by name). Nothing is
# accelerated here, so the results end in FAIL; that OSPF learns the route
# over the Link định tuyến, what leaves which port before and after a route
# change, and what is left of an item afterwards have to be right.
board 'ip link set eth9 netns host2 &&
	ip netns exec host2 ip link set eth9 up &&
	ip netns exec host2 ip addr add 10.17.1.2/24 dev eth8 &&
	ip netns exec host2 ip addr add 10.17.2.2/24 dev eth9 &&
	ip netns exec host2 ip addr add 10.17.0.1/32 dev lo &&
	ip netns exec host2 iperf3 -s -B 10.17.0.1 -p 5204 -D &&
	mkdir -p /var/run/frr/nb /var/lib/frr/nb /tmp/nb && : > /tmp/nb/zebra.conf &&
	chown network:network /var/run/frr/nb /var/lib/frr/nb /tmp/nb &&
	cp /usr/sbin/zebra /tmp/nb/nb-zebra && cp /usr/sbin/ospfd /tmp/nb/nb-ospfd &&
	printf "%s\n" "router ospf" " ospf router-id 10.17.0.1" \
		"interface eth8" " ip ospf area 0" " ip ospf network point-to-point" \
		"interface eth9" " ip ospf area 0" " ip ospf network point-to-point" \
		"interface lo" " ip ospf area 0" > /tmp/nb/ospfd.conf &&
	ip netns exec host2 /tmp/nb/nb-zebra -d -N nb -f /tmp/nb/zebra.conf -i /tmp/nb/zebra.pid &&
	ip netns exec host2 /tmp/nb/nb-ospfd -d -N nb -f /tmp/nb/ospfd.conf -i /tmp/nb/ospfd.pid &&
	cp /etc/config/bmcDynRouting /tmp/bmcDynRouting.before' ||
	fail "cannot set up the neighbour router"
export OSPF_PORT=eth4 OSPF_PORT2=eth5 OSPF_FLOW_PORT=5204
accept ospf
check "ospf-learned: OSPF gave the route over the Link định tuyến, and iperf3 sent through it" \
	result ospf-learned 'FAIL  OSPF.s route: 10\.17\.0\.1 .*via 10\.17\.1\.2 dev eth4 .*; [0-9]+ Mbps.*; in 10 s [0-9]{4,} packets left eth4; '
check "ospf-learned: the connections go to the learned network without NAT" \
	connections ospf-learned 'src=192\.168\.5\.10 dst=10\.17\.0\.1 .* src=10\.17\.0\.1 dst=192\.168\.5\.10 '
check "ospf-withdrawn: OSPF withdraws the route and the flow stops leaving the link" \
	result ospf-withdrawn 'FAIL  route withdrawn after [0-9]+ s; in 10 s [0-9]{4,} packets left eth4 before and [0-9]{1,3} after; the board now sends to 10\.17\.0\.1 through eth0, 0 such UDP connection\(s\) in the hardware; PC1 was still sending$'
check "ospf-withdrawn: fails only because nothing is accelerated here" \
	sh -c "! grep -q -E 'still sends the connection|did not leave through the Link|so nothing shows' '$W/accept'"
check "ospf-back: the route comes back and a new connection takes the link" \
	result ospf-back 'FAIL  route back after [0-9]+ s; [0-9]+ Mbps.*; in 10 s [0-9]{4,} packets left eth4; '
ospf_gone() {
	check "$1: the DynRouting configuration is back, OSPF is stopped and the links are br-lan ports again" \
		board 'cmp -s /etc/config/bmcDynRouting /tmp/bmcDynRouting.before && [ ! -e /etc/hwaccel-orig-ospf ] &&
			[ -e /sys/class/net/br-lan/brif/eth4 ] && [ -e /sys/class/net/br-lan/brif/eth5 ] &&
			[ -z "$(ip -4 route show proto 188)" ] && [ -z "$(ip -4 -o addr show | grep " 10\.17\.")" ] &&
			! iptables-save | grep -q -E "hwaccel-ospf|dynrouting|-p (89|ospf) "'
	restored "$1"
}
ospf_gone "after the ospf item"

accept ospf-move
check "ospf-moved: the route moves to the second link and the run follows it" \
	result ospf-moved 'FAIL  route moved from eth4 to eth5 after [0-9]+ s \(OSPF.s route: 10\.17\.0\.1 .*via 10\.17\.2\.2 dev eth5 [^)]*\); before: in 10 s [0-9]{4,} packets left eth4 and [0-9]{1,3} eth5; after: in 10 s [0-9]{4,} packets left eth5 and [0-9]{1,3} eth4; '
check "ospf-moved: the TCP sessions of the run lasted over the move" \
	sh -c "result_line=\$(grep -E '^ospf-moved +FAIL' '$W/accept') && echo \"\$result_line\" | grep -q -E 'iperf3 over the move: [0-9]+ Mbps' &&
		! grep -q -E 'stood still|did not last|leaves through the Link|does not leave through the Link' '$W/accept'"
check "ospf-ecmp: both links at the same cost give a route with two next hops, and a run under it is read" \
	result ospf-ecmp 'FAIL  OSPF.s route: 10\.17\.0\.1 .*nexthop via 10\.17\.[12]\.2 dev eth[45] weight 1 nexthop via 10\.17\.[12]\.2 dev eth[45] weight 1; [0-9]+ Mbps.*; in 10 s [0-9]+ packets left eth4 and [0-9]+ eth5; '
check "ospf-ecmp: said to be observed only" grep -q '^  *(observed: does not count in RESULT)$' "$W/accept"
ospf_gone "after the ospf-move item"
board 'kill "$(cat /tmp/nb/ospfd.pid)" "$(cat /tmp/nb/zebra.pid)"'

# The soak item with the image's own busybox, kernel log and syslog: nothing
# is accelerated here, but one iperf3 run has to last the two minutes, and the
# board script has to find its marks again and read the board at both ends.
# A kernel line of an ASK module with an error in it, under the run: the item
# has to find it. The run starts up to a minute from here (the layout of the
# item is brought up first) and lasts two.
board '(sleep 90; echo "cdx: hwaccel-test Error -1" > /dev/kmsg) > /dev/null 2>&1 < /dev/null &'
export SOAK=120
accept soak
check "soak: a kernel line of trouble under the run is counted and shown" \
	sh -c "grep -q '^  *- 1 kernel line(s) of the run tell of trouble' '$W/accept' && grep -q '^  *! .*cdx: hwaccel-test Error -1$' '$W/accept'"
check "soak: iperf3 ran the two minutes, first and last compared" \
	result soak 'FAIL  [0-9]+ Mbps over 120 s, first minute [0-9]+, last minute [0-9]+, '
check "soak: the board was read at the start, twice under the run and at the end" \
	result soak 'FAIL  .*; 2 looks at the board, .*; memory available: [0-9]+ kB at the start, [0-9]+ kB at the end$'
check "soak: the marks of the start are found in the kernel log and in syslog" \
	[ "$(grep -c 'no longer has the mark' "$W/accept")" = 0 ]
check "soak: the board stayed in its boot and kept its modules out" \
	sh -c "! grep -q 'another boot' '$W/accept' && grep -q '^  *- 0 of the 3 ASK modules are loaded at the end' '$W/accept'"
stop_vm
fi

# ---- third boot: from the SD card image; sysupgrade

if boots card; then
echo "== boot from the SD card image =="
start_vm cable card
wait_board 'logread | grep -q "init complete" && iptables -t nat -S | grep -q -- "-o eth0 "' || exit 1

check "board name is fsl,ls1046a-rdb-sdboot" board '[ "$(cat /tmp/sysinfo/board_name)" = fsl,ls1046a-rdb-sdboot ]'
check "the root filesystem is the second partition of the card" board 'grep -q "^/dev/root /rom squashfs" /proc/mounts && [ -b /dev/vda2 ]'
check "the image version of the board is 3.0" board '[ "$(uci -q get system.@system[0].compat_version)" = 3.0 ]'
# Something of the operator to carry over, next to the mark of the item, and
# a kernel file that is not the one of the image, to see it replaced.
board 'uci set dhcp.lan.force=1 && uci commit dhcp'
board 'bmchwaccel disable >/dev/null; uci set system.@system[0].description=kept-by-sysupgrade && uci commit system &&
	mkdir -p /tmp/kernel-part && mount -t ext4 /dev/vda1 /tmp/kernel-part &&
	echo stale > /tmp/kernel-part/fitImage && umount /tmp/kernel-part' || fail "cannot prepare the card"
boot_id=$(board 'cat /proc/sys/kernel/random/boot_id')

accept sysupgrade firewall ports
check "acceptance: sysupgrade passes" \
	result sysupgrade 'PASS  .* -> .*, back after [0-9]+ s; configuration kept; the card has the kernel and root filesystem of '
check "the board runs a new boot" board "[ \"\$(cat /proc/sys/kernel/random/boot_id)\" != '$boot_id' ]"
check "sysupgrade wrote the kernel, the root filesystem and the configuration backup" \
	sh -c "grep -q 'Writing kernel' '$W/serial-cable-card.log' && grep -q 'Writing rootfs' '$W/serial-cable-card.log' &&
		grep -q 'Saving config backup' '$W/serial-cable-card.log'"
check "the description set before the upgrade is kept" \
	board '[ "$(uci -q get system.@system[0].description)" = kept-by-sysupgrade ]'
check "hardware acceleration is still disabled after the upgrade" \
	board '[ "$(uci -q get bmchwaccel.global.enabled)" = 0 ] && bmchwaccel get | grep -q "\"enabled\":false"'
check "the image version of the board is still 3.0" board '[ "$(uci -q get system.@system[0].compat_version)" = 3.0 ]'
check "the marks of the item are removed" board '[ ! -e /etc/config/hwaccel_test ] && [ ! -e /root/hwaccel-not-kept ]'
check "acceptance: firewall passes after the upgrade" grep -q '^firewall  *PASS' "$W/accept"
check "acceptance: ports passes after the upgrade" grep -q '^ports  *PASS  wan eth0; br-lan: eth1 eth2 eth3 eth4 eth5$' "$W/accept"
[ $rc -eq 0 ] || grep -a -E 'upgrade|sysupgrade|Writing|Saving|rootfs|mount_root|config' "$W/serial-cable-card.log" | tail -40 | sed 's/^/    | /'

# The reboots item: the board has to go down and come up in a new boot, whose
# status is read. Hardware acceleration is disabled here and nothing answers
# iperf3 in this boot, so the item ends at its first boot.
boot_id=$(board 'cat /proc/sys/kernel/random/boot_id')
export REBOOTS=2
accept reboots
check "reboots: the item ends at the first boot, which cannot be measured" \
	sh -c "grep -q '^reboots  *FAIL  no iperf3 result$' '$W/accept' && ! grep -q 'boot 2' '$W/accept'"
check "reboots: the item says in which boot it stopped" \
	result reboots 'stopped in boot 1 of 2, which could not be measured$'
check "reboots: the status of the new boot is read" \
	grep -q '^  *- boot 1: bmchwaccel status says off, need on$' "$W/accept"
check "reboots: the board runs a new boot" board "[ \"\$(cat /proc/sys/kernel/random/boot_id)\" != '$boot_id' ]"
# The card booted in security mode nac: the item switched it off for its
# traffic and the script put it back at its end.
check "acceptance: a board in security mode nac is switched to off for a traffic item" \
	result net 'security mode off instead of nac until the script ends$'
check "the board is back in security mode nac" \
	board '[ "$(uci -q get system.@system[0].security_mode)" = nac ] && [ ! -e /etc/hwaccel-orig ]'
stop_vm
fi

[ $rc -eq 0 ] && echo "qemu-test: PASS" || echo "qemu-test: FAIL"
exit $rc
