#!/bin/sh
# Acceptance of the LS1088A-RDB firmware on a real board, driven over SSH from
# PC1. The functions and the board-independent items are those of
# scripts/hwaccel/acceptance.sh (the LS1046A-RDB), read from that script; the
# ports, the kernel lines and the items of the kernel layout are this board's.
# In the kernel layout every port is on the kernel driver dpaa2-eth and every
# packet goes through Linux, as on the 24.10 firmware: its numbers are what the
# later layouts are measured against. In the engine layout (Tăng tốc phần cứng
# enabled, bmcHwAccelDpdk) eth0 and eth1 are DPNIs linked to the DPNIs of
# bmchwaccel-engine, which holds dpmac.1 and dpmac.2.
#
# Cabling:
#
#   PC1 192.168.5.x ── eth1 [br-lan 192.168.5.1] LS1088 [wan 192.168.2.1] eth0 ── PC2 192.168.2.10
#   runs this script    10GBASE-T                                SFP+ with a     runs "iperf3 -s"
#                                                                10G RJ45 module
#
# What scripts/hwaccel/acceptance.sh says of PC1, PC2 and the board holds here:
# ssh without a password, PC2 without a gateway, the board switched to
# security mode off and given WAN_ADDR on a wan without an address for the
# items that need it, and put back when the script ends.
#
# Usage: scripts/ls1088/acceptance.sh [item...]
# Items, in the default order:
#   boot            kernel version and MC firmware; phy_init made the ports:
#                   eth0 to eth8 are dpmac.1 to dpmac.9, each with the MAC
#                   address of its dpmac and one flow steering entry, and
#                   dpmac.10 has none; no kernel line tells of trouble, those
#                   of the MC, QBMan and DPAA2 drivers included. In the
#                   kernel layout no hugepages are reserved; in the engine
#                   layout the ports of the engine's MACs reach them through
#                   the engine, which runs, and hugepages are reserved.
#   firewall        fw3 on iptables-legacy is running; no fw4, no software flow
#                   offloading
#   ports           wan is on eth0, br-lan bridges eth1 to eth7; eth8 is in
#                   neither
#   wan-link        the SFP+ port with the 10G RJ45 module PC2 is cabled to:
#                   its link must be up. What ethtool says of it, the link
#                   the MC reports for its dpmac and its last link events are
#                   printed; the speed of the copper side is what PC2 shows
#                   (bench.md).
#   baseline        PC1 -> PC2, routed and masqueraded from br-lan to wan,
#                   iperf3 -P 4 for DURATION seconds. The Mbps, the packets
#                   of the wan port and the load of every CPU of the board
#                   (busy and softirq, over WINDOW seconds in the middle of
#                   the run) are the numbers of the kernel layout: printed,
#                   not judged. Passes when iperf3 gave a result and the
#                   board masqueraded the connections to PC2.
#   baseline-back   PC2 -> PC1 over the same kind of connection (iperf3 -R)
# Run only when named:
#   soak            PC1 sends to PC2 as in baseline for SOAK seconds, in one
#                   iperf3 run, and the load of the board is read every
#                   SOAK_EVERY seconds. At the end the board must be in the
#                   same boot, no kernel line of the run may tell of trouble,
#                   and no minute of the run may have stood still. The item
#                   prints the Mbps of every minute, the busiest CPU of the
#                   looks and the memory available at both ends. PC1 must not
#                   go to sleep under it (bench.md). In the engine layout the
#                   engine of the start must still run at the end, not one
#                   its supervisor started again, and a status on at the
#                   start must be on at the end.
#   reboots         the board is rebooted REBOOTS times in a row. Every boot
#                   must pass the checks of boot, be in the layout of the
#                   boot the item began in (an engine layout that falls back
#                   on the kernel layout fails, with the reason of the
#                   status) and carry the traffic of baseline; its Mbps are
#                   printed, not judged. The item stops at the first boot
#                   that fails and leaves the board in it.
#   idle            the engine layout with no traffic for IDLE seconds: every
#                   CPU of a worker of the engine must be busy less than
#                   IDLE_MAX %. The CPU of each thread of the engine is
#                   printed.
#   restart         the engine is killed (kill -9) while PC1 pings the board
#                   and PC2 every 0.1 s: it must be started again on the
#                   container of the boot, with no DPAA2 object made or gone,
#                   and both must answer again. The longest time without an
#                   answer is printed.
#   carrier         the operator unplugs the cable of the wan port, then
#                   plugs it back, when the script says so: the port must
#                   lose its carrier and netifd must see wan down, then both
#                   come back, within CARRIER_WAIT seconds each. When the
#                   engine holds the port, "bmchwaccel ports" must say its
#                   link is down, then up, as well, and so must the web UI
#                   (get_ether_port_status.sh: inactive, then active) when it
#                   is installed.
#   wire-stats      PC1 -> PC2 as in baseline; "bmchwaccel ports" is read
#                   twice, WINDOW seconds apart. The engine must hold eth1
#                   and the wan port, both with their link up and a speed.
#                   Between the two answers the bytes eth1 received and the
#                   wan port sent on their cables must each have grown by
#                   STATS_LOW to STATS_HIGH percent of what iperf3 carried
#                   in that window. The speed is the one the MC has for the
#                   dpmac (the SFP+ side of the 10G RJ45 module: 10000, as
#                   wan-link shows in the kernel layout); the copper side is
#                   what PC2 shows (bench.md).
#   wire-stats-back the same with iperf3 -R: the wan port receives and eth1
#                   sends
#   webui-ports, webui-ports-back  as wire-stats and wire-stats-back, with the
#                   bytes, the link (active) and the speed the web UI
#                   dashboard shows: those of get_net_stats.sh and
#                   get_ether_port_status.sh, the scripts it calls (bmcwebUI
#                   ticket 02 of hw-accel-ls1088); the bytes against what
#                   iperf3 carried in the time the board measured between
#                   the two reads
#   pdump           dpdk-pdump captures the cable side of eth1 while the
#                   board pings PC1: the capture must have the requests the
#                   board sent and the replies PC1 sent.
# Items of bmchwaccel in the engine layout, which read the state of Tăng tốc
# phần cứng from "bmchwaccel status", as boot and reboots do:
#   onoff           bmchwaccel disable while iperf3 -P 4 runs as in baseline
#                   for ONOFF_TIME seconds, enable a while later: off with
#                   reboot_required, then on again, one syslog line each, and
#                   iperf3 runs to its end with no second under 1 Mbps. Off,
#                   the kernel's eth0 and eth1
#                   each see at least ENGINE_MIN packets in WINDOW seconds;
#                   on again, WARMUP seconds later, the connections are
#                   accelerated as accel judges it.
#   enable-boot     disabled and rebooted: the kernel layout, off. Enabled
#                   there: off with reboot_required, the status says it
#                   takes effect after a restart, and the board does not
#                   restart by itself within ENABLE_WAIT seconds. Rebooted:
#                   the engine layout, on.
#   deaths          the engine is killed (kill -9) twice: each time it is
#                   on again within DEATH_WAIT seconds. Killed a third time
#                   within 5 minutes: the board restarts in the kernel
#                   layout, unavailable for the reason "engine", which
#                   /etc/bmcHwAccel keeps and syslog tells. Enabled: off
#                   with reboot_required and nothing kept; rebooted: the
#                   engine layout, on.
# Items of the accelerated path (route + NAT br-lan -> wan through the engine
# and bmchwaccel-syncd):
#   accel           iperf3 -P 4 PC1 -> PC2 for DURATION seconds: at least
#                   ACCEL_PCT % of BASE_MBPS (the kernel layout, ticket 03);
#                   eth0 and eth1 of the kernel get and send fewer than
#                   KERNEL_MAX packets in WINDOW seconds, the cable side of
#                   eth1 counts at least ENGINE_MIN; bmchwaccel status on,
#                   with connections counted
#   accel-back      the same PC2 -> PC1 (iperf3 -R), against BASE_BACK_MBPS
#   accel-vlan, accel-vlan-back  as accel and accel-back, PC1 sending from
#                   VLAN_CLIENT through the VLAN interface VLAN_PARENT.VLAN_ID
#                   of the board (ticket 10; bench.md)
#   accel-pppoe, accel-pppoe-back  as accel and accel-back with wan dialling
#                   PPPoE to the PPPoE server on eth0; the iperf3 server is
#                   PPPOE_SERVER, or the peer of the session
#   accel-vlan-pppoe, accel-vlan-pppoe-back  both
#   accel-redial    PPPoE dials again under a UDP flow to DROP_PORT the
#                   engine carries: the session is ended and kept down for
#                   WINDOW seconds, as pppoe-drop of the LS1046 does it. The
#                   engine holds no connection while it is down, fewer than
#                   KERNEL_MAX packets leave the cable of eth0, the session
#                   comes back, and iperf3 -P 4 over the new one passes as
#                   accel does
#   accel-udp       iperf3 -u at UDP_RATE, which PC2 answers: as accel, with
#                   ACCEL_PCT % of UDP_RATE arriving, and a UDP connection in
#                   the engine
#   accel-udp-back  the same PC2 -> PC1 (iperf3 -u -R)
#   udp-oneway      UDP to ONEWAY_PORT of PC2, where nothing answers: never
#                   in the engine, the kernel's eth1 gets it all
#   keep-mark       under iperf3 -P 4 the bit 0x10000 set on the connections
#                   by hand (conntrack -U): out of the engine within KEEP_MS,
#                   through the kernel; cleared: accelerated again; iperf3
#                   runs to its end
#   daemon-kill     bmchwaccel-syncd killed (kill -9) under iperf3 -P 4: the
#                   engine lets go of every connection, the kernel carries
#                   them, iperf3 runs to its end; the daemon is started again
#                   and the connections are accelerated again within
#                   DAEMON_WAIT seconds; while it is dead the status is
#                   unavailable, reason daemon
#   daemon-block    the daemon killed under iperf3 -P 4 and PC1 blocked by
#                   macfilter before it is back: iperf3 stops while blocked;
#                   macfilter is put back as it was
#   accel-1g        PC1 cabled to ONEG_PORT (the operator does it first):
#                   iperf3 -P 4 runs through the kernel, the engine holds no
#                   connection
# Run only when named, LONG seconds each (600):
#   udp-long        iperf3 -u at UDP_LONG_RATE for LONG seconds: accelerated
#                   at every minute, iperf3 receives all along
#   udp-expire      UDP that stops: conntrack ends it after its timeout,
#                   counted from its last datagram, and the engine lets go
#   tcp-long        iperf3 -P 4 for LONG seconds, then its end: at most
#                   INVALID_MAX INVALID packets in conntrack, no connection
#                   left ESTABLISHED, the engine empty
# Items next to the features of the firmware (ticket 09), in the engine layout:
#   reroute         one iperf3 -P 4 run PC1 -> PC2 while the way to PC2
#                   changes on the board twice: a blackhole route, then a
#                   neighbour entry with a MAC address nobody has. Each time
#                   the engine lets go of the connections within KEEP_MS
#                   (nothing leaves the cable of eth0 into the blackhole in
#                   STALL seconds, and the engine takes none again; with the
#                   other MAC address they may be accelerated again towards
#                   it, which is following the new way); with the way right
#                   again they are
#                   accelerated again within REROUTE_WAIT seconds, and
#                   iperf3 runs to its end
#   qos, qos-back   bmcqos on wan at QOS_MBPS both ways: "bmchwaccel status"
#                   lists wan in on_cpu, iperf3 -P 4 keeps the limit (80 to
#                   105 %) through the kernel, no TCP connection in the
#                   engine; bmcqos off again: nothing listed, and a new run
#                   is accelerated
#   block           macfilter, client_control, blocked services and bmcfido
#                   against a UDP flow the engine carries, as the item of
#                   scripts/hwaccel/acceptance.sh does it (bmchwaccel sweep),
#                   read with the kernel's counters of eth1 and the engine's
#                   of the cable of eth0
#   block-other     PC3, a second machine of br-lan (any port), blocked in
#                   turn by macfilter, macfilter in its whitelist mode with
#                   PC1 alone in the list, client_control and bmcfido while
#                   iperf3 -P 4 of PC1 runs through the engine: PC3 loses what
#                   it had open through the board, every stream of PC1 stays
#                   in the engine all along (listed every 0.1 s), the kernel
#                   sees fewer than KERNEL_MAX packets of eth1 in WINDOW s,
#                   iperf3 never stops. Not run without PC3
#   ftp             PC2 runs ftp-server.py of this directory (bench.md): PC1
#                   downloads FTP_MB MB at FTP_RATE in passive and in active
#                   mode; whole, with the FTP helper in conntrack, and the
#                   engine holds no connection of PC2 meanwhile
#   ipsec-accel     a tunnel the VPN page set up with a peer behind wan
#                   (ticket 16 of .scratch/hw-accel-ls1088): iperf3 -P 4 TCP
#                   from PC1 to IPSEC_TARGET reaches IPSEC_MBPS, and back
#                   (-R) ACCEL_PCT % of iperf3 -R from SERVER, the peer, to
#                   PC1 outside the tunnel; meanwhile the kernel sees fewer
#                   than KERNEL_MAX packets of eth0 in WINDOW s, bmchwaccel
#                   status has ipsec_sa >= 2 and accelerated > 0, the engine
#                   holds connections to IPSEC_TARGET, the bytes of the
#                   kernel's SAs grow, and the peer's XfrmInStateSeqError
#                   and XfrmInNoStates stay as they were (over PEER_SSH).
#                   Each run says the load of the workers and their cycles
#                   per packet (busy time over the packets of the cables)
#   ipsec-rekey, ipsec-kill, ipsec-disable, ipsec-syncd, ipsec-limit,
#   ipsec-many, ipsec-algo
#                   ticket 17 of .scratch/hw-accel-ls1088, through the tunnel
#                   of ipsec-accel (BOARD_CONN, PEER_CONN), with PEER_SSH:
#                   strongSwan rekeying under iperf3; the engine killed; Tăng
#                   tốc phần cứng disabled and enabled; the daemon killed;
#                   the numbers of the outbound SA near their end (XFRMAE);
#                   MANY tunnels; tunnels of GCM, ChaCha20-Poly1305 and ESN.
#                   See the comment of each item_ipsec_* function
#   tx-limit        ticket 21, the engine started again each time UCI
#                   tx_limit changes: TX_PORT at TX_TEST_MBPS, the engine
#                   logs the limit (down to a step of 8 Mbps) and one iperf3
#                   flow to SERVER gets 85 to 105 % of it; no limit, the
#                   flow reaches TX_MIN again; TX_LIMIT_MBPS, iperf3 -P 4 to
#                   SERVER reaches TX_MIN and with PEER_SSH the peer (SERVER)
#                   got no frame with a bad CRC. 3 stops of the engine in 5
#                   minutes restart the router in the kernel layout: the
#                   item waits before the third, about 6 minutes in all, and
#                   wants the engine to have run 5 minutes before it. UCI is
#                   put back as it was; the engine keeps TX_LIMIT_MBPS until
#                   it next starts
#   ipsec-replay    ticket 23, through the tunnel of ipsec-accel: the
#                   inbound SA of BOARD_CONN has an anti-replay window of
#                   128 in the kernel, and the engine holds it
#   ipsec-reorder   iperf3 -P 8 through the tunnel, so that its connections
#                   are on several workers: of IPSEC_CAPTURE packets of ESP
#                   that reach the peer (tcpdump over PEER_SSH, with sudo),
#                   how many came after one with a higher number, and by
#                   how much at most. A measure: fails only without capture
#   ipsec-sweep, ipsec-qos, ipsec-route, ipsec-mtu, ipsec-pppoe, ipsec-vlan,
#   ipsec-mwan
#                   ticket 18 of .scratch/hw-accel-ls1088, the tunnel next to
#                   the Feature BMC: client_control, macfilter
#                   and bmcfido block PC1 and its traffic through the tunnel
#                   stops within SWEEP_MS; bmcqos on wan keeps the tunnel's
#                   SAs with the kernel (ipsec_sa 0) and the limit holds;
#                   the way to the peer changes (blackhole, MAC, the wan
#                   port down) and the tunnel is accelerated again; large
#                   packets with and without DF; the tunnel over PPPoE and
#                   from a VLAN of PC1; Multi-WAN beside it. See the comment
#                   of each item_ipsec_* function
#   mwan            Multi-WAN with wan2 on MWAN_PORT towards ISP B, set up as
#                   the mwan items of the LS1046 do it: mwan-rule, what goes
#                   to MWAN_TARGET2 leaves through wan2 and is never
#                   accelerated; mwan-lost, under a UDP flow to MWAN_TARGET
#                   the engine carries through wan, wan becomes Mất Internet:
#                   bmcMultiWAN removes its connections and fewer than
#                   KERNEL_MAX packets leave the cable of eth0 in WINDOW s,
#                   the flow leaves through wan2
#   features, features-in  as on the LS1046, but with Tăng tốc phần cứng on
# reboots waits up to MARK_WAIT seconds for the mark of an engine layout boot
# to go before each reboot: two reboots in a row before it went keep the next
# boots in the kernel layout, as hangs would.
#   features-in, webui, sysupgrade, sysupgrade-old
#                   as scripts/hwaccel/acceptance.sh describes them; they read
#                   this board as they read the LS1046A-RDB. A board without
#                   bmchwaccel is tested as it is.
#
# Environment: that of scripts/hwaccel/acceptance.sh, with these defaults for
# this board:
#   FIRMWARE     sysupgrade image of the sysupgrade items (the one of the
#                LS1088A-RDB under bin/ of this tree)
#   REBOOTS      boots of the reboots item            (5)
#   IDLE         seconds of the idle item             (60)
#   IDLE_MAX     most busy % of a worker CPU in idle  (5)
#   CARRIER_WAIT seconds the carrier item waits for a cable to go or come (60)
#   ENABLE_WAIT  seconds enable-boot watches for a restart nobody asked (30)
#   DEATH_WAIT   seconds deaths waits for a killed engine to be on again (60)
#   ONOFF_TIME   seconds of the iperf3 run of onoff    (60)
#   MARK_WAIT    seconds reboots waits for the mark of a boot to go (180)
#   BASE_MBPS, BASE_BACK_MBPS  baseline and baseline-back of the kernel
#                layout on this bench (ticket 03: 704, 592)
#   ACCEL_PCT    % of the baseline accel and accel-back need (95)
#   KERNEL_MAX   packets of eth0 or eth1 the kernel may see in WINDOW s (1000)
#   ENGINE_MIN   packets the cable side must count in WINDOW s (10000)
#   UDP_RATE     rate of accel-udp (300M); UDP_LONG_RATE of udp-long (50M)
#   ONEWAY_PORT  port of PC2 nothing listens on (5299)
#   ONEG_PORT    1G port of accel-1g (eth3)
#   KEEP_MS      most ms a marked connection may stay in the engine (1000)
#   DAEMON_WAIT  seconds daemon-kill waits for acceleration again (30)
#   LONG         seconds of udp-long and tcp-long (600)
#   INVALID_MAX  INVALID packets tcp-long allows (0)
#   STALL        seconds reroute keeps each wrong way (5)
#   REROUTE_WAIT seconds reroute waits for acceleration again (30)
#   FTP_PORT, FTP_FILE, FTP_MB, FTP_RATE  the server of ftp on PC2 and the
#                download (21, hwaccel-ftp.bin, 64, 8M: some 8 s each)
#   IPSEC_TARGET address behind the tunnel of the ipsec items (none: not tested)
#   IPSEC_MBPS   what ipsec-accel needs from PC1 to IPSEC_TARGET (850)
#   PEER_SSH     user@address of the IPsec peer, ssh and sudo without a
#                password (none: its counters are not read)
#   PEER_KEY     identity file for PEER_SSH (none: ssh's own)
#   PEER_KNOWN_HOSTS  known_hosts file for PEER_SSH (none: ssh's own), for a
#                bench whose peer at that address changed
#   PEER_IF      interface of the peer for the capture of ipsec-reorder (any)
#   IPSEC_CAPTURE packets of ESP ipsec-reorder captures (20000)
#   TX_PORT      port of tx-limit (WAN_PORT); TX_TEST_MBPS the limit whose
#                rate it measures (300); TX_LIMIT_MBPS the one for the
#                module behind TX_PORT (980), with which iperf3 -P 4 must
#                reach TX_MIN Mbps (900)
#   BOARD_CONN, PEER_CONN  the conn of the bench's tunnel in /etc/ipsec.conf
#                of the board and of the peer (t14)
#   REKEY_TIME   seconds of iperf3 of ipsec-rekey (600)
#   REKEY_LIFE   lifetime of the peer's CHILD_SA in ipsec-rekey, rekeyed 30 s
#                before its end (2m)
#   REKEY_MIN    rekeys ipsec-rekey needs (5: 600 s at one each 90 s gives 6)
#   KILL_TIME    seconds of iperf3 of ipsec-kill and ipsec-syncd (45)
#   KILL_GAP     the one gap under 1 Mbps ipsec-kill allows, in seconds (10:
#                the engine starts again in some 7 s)
#   XFRMAE       the xfrmae tool for the board (ticket 13), which ipsec-limit
#                writes the kernel's oseq with (none: not tested)
#   LIMIT_LEFT   numbers ipsec-limit leaves the engine before it lets go of
#                the SA (300000: some 4 s of iperf3)
#   MANY         tunnels of ipsec-many (256); MANY_WAIT seconds they have to
#                come up (180)
#   PC3          address of the second machine of br-lan for block-other
#                (none: not tested)
#   IPSEC_PEER   address of the tunnel's peer for ipsec-route (the host of
#                PEER_SSH)
#   SWEEP_MS     most ms ipsec-sweep allows from the rule to the end of the
#                traffic through the tunnel (1000); SWEEP_QUIET the packets in
#                0.5 s out of the wan cable that count as none (20); SWEEP_LOOK
#                the seconds it looks for that (5)
#   IPSEC_QOS_PCT  least % of QOS_MBPS ipsec-qos needs through the tunnel (70:
#                cake counts the outer packets)
#   LINK_DOWN, LINK_WAIT  seconds ipsec-route keeps the wan port down (5), and
#                waits for the tunnel held again after (90)
#   IPSEC_PING_FIT  bytes of data of the largest ping with DF that fits the
#                tunnel (1394: MTU 1422 less 28); IPSEC_PING_SIZES the larger
#                ones (1400 1436 1472), answered only without DF
#   IPSEC_UDP_LEN, IPSEC_UDP_RATE  datagrams of ipsec-mtu (3000 bytes at 20M);
#                IPSEC_TCP_MIN the Mbps of its TCP run (100)
#   IPSEC_PAYLOAD_PCT  % of a packet of the MTU left to the data in ESP
#                (95), for the threshold of ipsec-pppoe
#   IPSEC_PEER_WINDOW  the anti-replay window ipsec-qos gives the peer's
#                strongSwan when it has a smaller one (1024): through the
#                kernel of the board the tunnel's ESP leaves out of order
#   IPSEC_PPPOE_DIRECT  where ipsec-pppoe measures iperf3 outside the tunnel
#                over the PPPoE session (the peer of the session): an
#                address of the peer that PC1 routes through the board
#   IPSEC_FAR, IPSEC_FAR_PORT  address in the peer's far network that
#                ipsec-mtu gives a network namespace on the peer, and the
#                port of its iperf3 server (10.20.0.30, 5310)
#   MWAN_CONN, MWAN_IPSEC_TARGET  a conn of the board to a peer behind wan2
#                and an address behind it, for ipsec-mwan (none: that part
#                not tested); MWAN_IPSEC_GAP the seconds under 1 Mbps it
#                allows the tunnel on wan when wan2 goes down and up (10)
#   VLAN_PARENT  device of the VLAN of the -vlan items (eth1)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
FIRMWARE=${FIRMWARE:-$(ls "$HERE"/../../bin/targets/layerscape/armv8_64b-glibc/*fsl_ls1088a-rdb-sdboot-squashfs-sysupgrade.bin 2>/dev/null | head -1)}
firmware=$FIRMWARE
REBOOTS=${REBOOTS:-5}
IDLE=${IDLE:-60}
IDLE_MAX=${IDLE_MAX:-5}
CARRIER_WAIT=${CARRIER_WAIT:-60}
ENABLE_WAIT=${ENABLE_WAIT:-30}
DEATH_WAIT=${DEATH_WAIT:-60}
ONOFF_TIME=${ONOFF_TIME:-60}
MARK_WAIT=${MARK_WAIT:-180}
BASE_MBPS=${BASE_MBPS:-704}
BASE_BACK_MBPS=${BASE_BACK_MBPS:-592}
ACCEL_PCT=${ACCEL_PCT:-95}
KERNEL_MAX=${KERNEL_MAX:-1000}
ENGINE_MIN=${ENGINE_MIN:-10000}
UDP_RATE=${UDP_RATE:-300M}
UDP_LONG_RATE=${UDP_LONG_RATE:-50M}
ONEWAY_PORT=${ONEWAY_PORT:-5299}
ONEG_PORT=${ONEG_PORT:-eth3}
KEEP_MS=${KEEP_MS:-1000}
DAEMON_WAIT=${DAEMON_WAIT:-30}
LONG=${LONG:-600}
INVALID_MAX=${INVALID_MAX:-0}
STALL=${STALL:-5}
REROUTE_WAIT=${REROUTE_WAIT:-30}
FTP_PORT=${FTP_PORT:-21}
FTP_FILE=${FTP_FILE:-hwaccel-ftp.bin}
FTP_MB=${FTP_MB:-64}
FTP_RATE=${FTP_RATE:-8M}
IPSEC_TARGET=${IPSEC_TARGET:-}
IPSEC_MBPS=${IPSEC_MBPS:-850}
PEER_SSH=${PEER_SSH:-}
PEER_KEY=${PEER_KEY:-}
PEER_KNOWN_HOSTS=${PEER_KNOWN_HOSTS:-}
PEER_IF=${PEER_IF:-any}
IPSEC_CAPTURE=${IPSEC_CAPTURE:-20000}
TX_PORT=${TX_PORT:-}
TX_TEST_MBPS=${TX_TEST_MBPS:-300}
TX_LIMIT_MBPS=${TX_LIMIT_MBPS:-980}
TX_MIN=${TX_MIN:-900}
BOARD_CONN=${BOARD_CONN:-t14}
PEER_CONN=${PEER_CONN:-t14}
REKEY_TIME=${REKEY_TIME:-600}
REKEY_LIFE=${REKEY_LIFE:-2m}
REKEY_MIN=${REKEY_MIN:-5}
KILL_TIME=${KILL_TIME:-45}
KILL_GAP=${KILL_GAP:-10}
XFRMAE=${XFRMAE:-}
LIMIT_LEFT=${LIMIT_LEFT:-300000}
MANY=${MANY:-256}
MANY_WAIT=${MANY_WAIT:-180}
PC3=${PC3:-}
IPSEC_PEER=${IPSEC_PEER:-${PEER_SSH#*@}}
SWEEP_MS=${SWEEP_MS:-1000}
SWEEP_QUIET=${SWEEP_QUIET:-20}
SWEEP_LOOK=${SWEEP_LOOK:-5}
IPSEC_QOS_PCT=${IPSEC_QOS_PCT:-70}
LINK_DOWN=${LINK_DOWN:-5}
LINK_WAIT=${LINK_WAIT:-90}
IPSEC_PING_FIT=${IPSEC_PING_FIT:-1394}
IPSEC_PING_SIZES=${IPSEC_PING_SIZES:-1400 1436 1472}
IPSEC_UDP_LEN=${IPSEC_UDP_LEN:-3000}
IPSEC_UDP_RATE=${IPSEC_UDP_RATE:-20M}
IPSEC_TCP_MIN=${IPSEC_TCP_MIN:-100}
IPSEC_PAYLOAD_PCT=${IPSEC_PAYLOAD_PCT:-95}
IPSEC_FAR=${IPSEC_FAR:-10.20.0.30}
IPSEC_PPPOE_DIRECT=${IPSEC_PPPOE_DIRECT:-}
IPSEC_PEER_WINDOW=${IPSEC_PEER_WINDOW:-1024}
IPSEC_FAR_PORT=${IPSEC_FAR_PORT:-5310}
MWAN_CONN=${MWAN_CONN:-}
MWAN_IPSEC_TARGET=${MWAN_IPSEC_TARGET:-}
MWAN_IPSEC_GAP=${MWAN_IPSEC_GAP:-10}
# The VLAN of PC1 on the cable of the engine's LAN port (ticket 10)
VLAN_PARENT=${VLAN_PARENT:-eth1}
ACCEPTANCE_LIB=1
# shellcheck source=../hwaccel/acceptance.sh
. "$HERE/../hwaccel/acceptance.sh"
# Without an image of this board the script read must not fall back on one of
# the LS1046A-RDB.
FIRMWARE=$firmware

# Port roles of the LS1088A-RDB (spec, Cổng), for item_ports.
WAN_PORT=eth0
LAN_PORTS="eth1 eth2 eth3 eth4 eth5 eth6 eth7"
LAN_OPTIONAL=
# The port of the engine PC1 is cabled to (the wan port is the other one).
ENGINE_LAN_PORT=eth1
# The MACs that phy_init gives a port, in the order of the ports: dpmac.1 is
# eth0. The others must have none.
PORT_MACS="1 2 3 4 5 6 7 8 9"
MC_VERSION=10.39.0
# trouble_fn reads this: on this board the lines of the MC, QBMan and DPAA2
# drivers that name an error, and a frame from a queue without a context.
KERNEL_ASK='(fsl-mc|fsl_mc|dprc|dpni|dpmac|dpio|dpcon|dpbp|dpaa2|qbman).*(error|fail|timeout|invalid)|without context'

# ---- scripts run on the board (busybox ash)

info_script() { links_fn; cat <<'EOF'
# hwaccel:info
uname -a
dmesg | grep -E 'MC firmware version' | head -1
logread | grep 'phy_init' | tail -10
for d in /sys/class/net/eth*; do
	echo "${d##*/} $(basename "$(readlink "$d/device")") $(cat "$d/address") $(links "$d")"
done
ip -br link
exit 0
EOF
}

# The DPAA2 layout of this boot: per port "port <name> <dpni> <dpmac> <flow
# steering entries> <MAC address> <MAC address of the dpmac> <kernel|engine>"
# (engine: the dpni is linked to the engine's DPNI of the dpmac), "free
# <dpmac>" for every dpmac without an endpoint, the layout bmcHwAccelDpdk
# decided, the MACs it gives the engine and whether the engine runs, and the
# kernel lines of trouble.
layout_script() { trouble_fn; cat <<'EOF'
# hwaccel:layout
echo "kernel=$(uname -r)"
echo "mc=$(dmesg | sed -n 's/.*MC firmware version: \([0-9.]*\).*/\1/p' | head -1)"
[ -e /var/run/phy_init.done ] && echo phy_init=done
echo "hugepages=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)"
echo "layout=$(cat /var/run/bmchwaccel/layout 2>/dev/null)"
[ ! -x /usr/lib/bmcHwAccelDpdk/layout ] || echo "engine_macs=$(/usr/lib/bmcHwAccelDpdk/layout ports)"
pidof bmchwaccel-engine > /dev/null && echo "engine=running"
! command -v bmchwaccel > /dev/null || echo "status=$(bmchwaccel status 2>&1 | head -1)"
for d in /sys/class/net/eth*; do
	dpni=$(basename "$(readlink "$d/device")")
	info=$(restool dpni info "$dpni" 2>/dev/null)
	mac=$(echo "$info" | sed -n 's/^endpoint: \(dpmac\.[0-9]*\),.*/\1/p')
	via=kernel
	if [ -z "$mac" ]; then
		peer=$(echo "$info" | sed -n 's/^endpoint: \(dpni\.[0-9]*\),.*/\1/p')
		mac=$(awk -v y="$peer" '$1 == "port" && $4 == y && y != "" { print $2 }' /var/run/bmchwaccel/container 2>/dev/null)
		[ -z "$mac" ] || via=engine
	fi
	echo "port ${d##*/} $dpni ${mac:--} $(echo "$info" | sed -n 's/^fs_entries: //p') $(cat "$d/address")" \
		"$(restool dpmac info "${mac:-none}" 2>/dev/null | sed -n 's/^MAC address: //p') $via"
done
for m in $(restool dprc show dprc.1 2>/dev/null | awk '$1 ~ /^dpmac\./ { print $1 }'); do
	restool dpmac info "$m" 2>/dev/null | grep -q '^endpoint: No object' && echo "free $m"
done
echo "trouble=$(dmesg | trouble | grep -c .)"
echo "@trouble"
dmesg | trouble | tail -20
echo "@log"
logread | grep 'phy_init' | tail -12
exit 0
EOF
}

# PORT comes from the caller: the link of the port, what ethtool and the MC say
# of it, and its last link events.
wanlink_script() { cat <<'EOF'
# hwaccel:wanlink
dpni=$(basename "$(readlink "/sys/class/net/$PORT/device")")
mac=$(restool dpni info "$dpni" 2>/dev/null | sed -n 's/^endpoint: \(dpmac\.[0-9]*\),.*/\1/p')
echo "carrier=$(cat "/sys/class/net/$PORT/carrier" 2>/dev/null)"
echo "speed=$(cat "/sys/class/net/$PORT/speed" 2>/dev/null)"
echo "dpmac=$mac"
echo "@ethtool"
ethtool "$PORT" 2>&1 | grep -E 'Speed|Duplex|Auto-negotiation|Port:|Link detected'
echo "@mc"
restool dpmac info "$mac" 2>&1 | grep -E '^endpoint|link type|ethernet interface|rate'
echo "@events"
dmesg | grep "$PORT: Link" | tail -5
exit 0
EOF
}

# WINDOW, SERVER and PORT come from the caller. The load of every CPU over
# WINDOW seconds, "cpu <cpu> <busy %> <softirq %>", the packets PORT passed in
# that time, and the connections to SERVER the board masqueraded.
load_script() { cat <<'EOF'
# hwaccel:load
cpus() { grep '^cpu[0-9]' /proc/stat; }
pkts() { echo "$(cat "/sys/class/net/$PORT/statistics/rx_packets") $(cat "/sys/class/net/$PORT/statistics/tx_packets")"; }
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
cpus > /tmp/hwaccel-load-a
p0=$(pkts)
sleep "$WINDOW"
cpus > /tmp/hwaccel-load-b
p1=$(pkts)
# user nice system idle iowait irq softirq steal: busy is all but idle and iowait.
awk 'NR == FNR { for (i = 2; i <= 9; i++) a[$1, i] = $i; next }
	{
		t = 0
		for (i = 2; i <= 9; i++) { d[i] = $i - a[$1, i]; t += d[i] }
		if (t > 0) printf "cpu %s %d %d\n", substr($1, 4), 100 * (t - d[5] - d[6]) / t + 0.5, 100 * d[8] / t + 0.5
	}' /tmp/hwaccel-load-a /tmp/hwaccel-load-b
rm -f /tmp/hwaccel-load-a /tmp/hwaccel-load-b
set -- $p0 $p1
echo "port_rx=$(($3 - $1))"
echo "port_tx=$(($4 - $2))"
echo "masq=$(awk -v s="$SERVER" '{
	n = 0
	for (i = 1; i <= NF; i++) if ($i ~ /^(src|dst)=/) v[++n] = substr($i, 5)
	if (n >= 4 && v[2] == s && v[4] != v[1]) m++
} END { print m + 0 }' /proc/net/nf_conntrack 2>/dev/null)"
echo "free_kb=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)"
exit 0
EOF
}

# ---- the items of this board

# The answer of layout_script in $TMP/layout -> layout_text, with a reason
# for everything that is not the kernel layout of this board.
layout_check() {
	kernel=$(value "$TMP/layout" kernel); mc=$(value "$TMP/layout" mc)
	[ "$kernel" = "$KERNEL" ] || why "kernel is ${kernel:-unknown}, need $KERNEL"
	[ "$mc" = "$MC_VERSION" ] || why "MC firmware is ${mc:-not in the kernel log}, need $MC_VERSION"
	[ "$(value "$TMP/layout" phy_init)" = done ] || why "phy_init has not run in this boot"
	pages=$(value "$TMP/layout" hugepages)
	engine_macs=
	state=$(status_field "$TMP/layout" state)
	if [ "$(value "$TMP/layout" layout)" = engine ]; then
		engine_macs=$(value "$TMP/layout" engine_macs)
		[ "${pages:-0}" -gt 0 ] 2>/dev/null || why "no hugepages are reserved for the engine"
		[ "$(value "$TMP/layout" engine)" = running ] || why "the engine does not run"
		[ -z "$(value "$TMP/layout" status)" ] || status_check "$TMP/layout" on
	else
		[ "$pages" = 0 ] || why "${pages:-an unknown number of} hugepages are reserved; the kernel layout has none"
		[ "$state" != on ] || why "bmchwaccel status says on in the kernel layout"
	fi
	port=0
	port_reasons_before=$reasons; reasons=
	for m in $PORT_MACS; do
		set -- $(awk -v p="eth$port" '$1 == "port" && $2 == p { print $3, $4, $5, $6, $7, $8 }' "$TMP/layout")
		if [ $# -eq 0 ]; then
			why "there is no eth$port (dpmac.$m)"
		else
			[ "$2" = "dpmac.$m" ] || why "eth$port ($1) is on $2, need dpmac.$m"
			[ "${3:-}" = 1 ] || why "eth$port ($1) has ${3:-an unknown number of} flow steering entries, need 1"
			[ -n "${4:-}" ] && [ "${4:-}" = "${5:-}" ] ||
				why "eth$port has the MAC address ${4:-none}, its dpmac ${5:-none}"
			case " $engine_macs " in
			*" dpmac.$m "*) [ "${6:-kernel}" = engine ] || why "eth$port ($1) does not reach dpmac.$m through the engine" ;;
			*) [ "${6:-kernel}" = kernel ] || why "eth$port ($1) reaches dpmac.$m through the engine, which does not hold it" ;;
			esac
		fi
		port=$((port + 1))
	done
	ports=$(grep -c '^port ' "$TMP/layout")
	[ "$ports" -eq $port ] || why "the board has $ports ethN ports, need $port"
	free=$(sed -n 's/^free //p' "$TMP/layout" | tr '\n' ' ' | sed 's/ $//')
	for m in $(sed -n 's/^free //p' "$TMP/layout"); do
		case " $PORT_MACS " in *" ${m#dpmac.} "*) why "$m has no port" ;; esac
	done
	if [ -z "$reasons" ]; then
		layout_text="eth0-eth$((port - 1)) on dpmac.$(echo $PORT_MACS | cut -d' ' -f1)-$(echo $PORT_MACS | awk '{ print $NF }'), each with 1 flow steering entry and the MAC address of its dpmac"
	else
		layout_text="$ports ethN ports, not those phy_init makes"
	fi
	reasons="$port_reasons_before$reasons"
	[ -z "$engine_macs" ] ||
		layout_text="engine layout: $layout_text, $(awk '$1 == "port" && $8 == "engine" { printf "%s%s", sep, $2; sep = " and " }' "$TMP/layout") through the engine"
	layout_text="$layout_text; without a port: ${free:-none}; MC ${mc:-?}"
	trouble=$(value "$TMP/layout" trouble)
	[ "$trouble" = 0 ] || why "${trouble:-an unknown number of} kernel line(s) tell of trouble (marked ! below)"
}

item_layout() {
	board "$(layout_script)" > "$TMP/layout"
	layout_check
	report boot "kernel $kernel; $layout_text; ${pages:-?} hugepages; ${trouble:-?} kernel line(s) of trouble${state:+; bmchwaccel status: $state}"
	section "$TMP/layout" trouble | sed 's/^/               ! /'
	section "$TMP/layout" log | sed 's/^/               | /'
}

item_wan_link() {
	board "PORT=$WAN_PORT
$(wanlink_script)" > "$TMP/wanlink"
	case "$(value "$TMP/wanlink" carrier)" in
	1) link=up ;;
	0) link=down ;;
	*) link=unknown ;;
	esac
	[ $link = up ] ||
		why "$WAN_PORT has no link: is PC2 cabled to the 10G RJ45 module, and the module in the SFP+ cage?"
	report wan-link "$WAN_PORT ($(value "$TMP/wanlink" dpmac)) link $link, speed $(value "$TMP/wanlink" speed) Mb/s as the kernel has it; the copper side is what PC2 shows"
	for s in ethtool mc events; do
		section "$TMP/wanlink" $s | sed "s/^[[:space:]]*/               | $s: /"
	done
}

# The load of the board over WINDOW seconds, in $TMP/load-<name>.
load() { # name
	board "ITEM=$1
WINDOW=$WINDOW
SERVER='$server'
PORT=$WAN_PORT
$(load_script)" > "$TMP/load-$1"
}

# "CPU busy/softirq %: 0 40/31, 1 3/0, ..." from a load answer.
load_text() { # file
	awk '$1 == "cpu" { printf "%s%s %s/%s", sep, $2, $3, $4; sep = ", " }' "$1" | sed 's/^/CPU busy\/softirq % /'
}

# The busiest CPU of a load answer: "<cpu> <busy %>".
busiest() { # file
	awk '$1 == "cpu" && (b == "" || $3 > b) { c = $2; b = $3 } END { if (b != "") print c, b }' "$1"
}

# PC1 and PC2 over br-lan -> wan, as an item names it, with the load of the
# board read in the middle of the run: the throughput in mbps, the load in
# $TMP/load-<item>. Fails with the reasons set when there is no result.
carry() { # item [iperf3 option]
	item=$1
	reverse=${2:-}
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || return 1
	board "$(flush_script)"
	# shellcheck disable=SC2086
	"$IPERF3" -c "$server" -t "$DURATION" -P 4 -J -T "$item" $reverse > "$TMP/iperf-$item.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	load "$item"
	wait "$iperf_pid"
	iperf_pid=
	mbps=$(iperf_mbps "$TMP/iperf-$item.json")
	if [ -z "$mbps" ]; then
		err=$(iperf_error "$TMP/iperf-$item.json")
		why "iperf3: ${err:-no report; is \"iperf3 -s\" running on $server?}"
		return 1
	fi
	masq=$(value "$TMP/load-$item" masq)
	[ "${masq:-0}" -ge 1 ] 2>/dev/null ||
		why "no connection to $server is masqueraded on the board: the traffic did not go from br-lan to wan through it"
	carried_text="$WAN_PORT +$(value "$TMP/load-$item" port_rx) rx, +$(value "$TMP/load-$item" port_tx) tx packets in $WINDOW s; $(load_text "$TMP/load-$item"); ${masq:-0} masqueraded"
}

item_baseline() { # baseline | baseline-back
	reverse=
	[ "$1" != baseline-back ] || reverse=-R
	if carry "$1" $reverse; then
		report "$1" "$mbps Mbps$(iperf_detail "$TMP/iperf-$1.json"); $carried_text"
	else
		report "$1" "not measured"
	fi
}

# The kernel layout under traffic for SOAK seconds.
item_soak_kernel() {
	item=soak
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report soak "not tested"; return; }
	board "$(flush_script)"
	board "ACTION=start
$(soak_script)" > "$TMP/soak-start"
	mark=$(value "$TMP/soak-start" mark)
	[ -n "$mark" ] || {
		why "the board did not leave its mark in the logs at the start"
		report soak "not tested"
		return
	}

	began=$(date +%s)
	"$IPERF3" -c "$server" -t "$SOAK" -i $SOAK_SPAN -P 4 -J -T soak > "$TMP/iperf-soak.json" 2>/dev/null &
	iperf_pid=$!
	last=$((SOAK - WINDOW - SOAK_MARGIN))
	at=$WARMUP; looks=0; worst=
	while :; do
		[ $((at + WINDOW + SOAK_MARGIN)) -lt $last ] || at=$last
		ahead=$((began + at - $(date +%s)))
		[ $ahead -le 0 ] || sleep $ahead
		kill -0 "$iperf_pid" 2>/dev/null || [ -n "$(iperf_mbps "$TMP/iperf-soak.json")" ] || break
		load soak
		set -- $(busiest "$TMP/load-soak")
		if [ $# -eq 2 ] && { [ -z "$worst" ] || [ "$2" -gt "${worst#* }" ]; }; then
			worst="$1 $2"
		fi
		looks=$((looks + 1))
		[ $at -lt $last ] || break
		at=$((at + SOAK_EVERY))
	done
	wait "$iperf_pid"
	iperf_pid=
	board "ACTION=end
MARK='$mark'
$(soak_script)" > "$TMP/soak-end"

	mbps=$(iperf_mbps "$TMP/iperf-soak.json")
	if [ -z "$mbps" ]; then
		err=$(iperf_error "$TMP/iperf-soak.json")
		why "iperf3: ${err:-no report; is \"iperf3 -s\" running on $server, and did PC1 stay awake?}"
		speed="no iperf3 result"
	else
		first=$(iperf_span_mbps "$TMP/iperf-soak.json" 0 $SOAK_SPAN)
		final=$(iperf_span_mbps "$TMP/iperf-soak.json" $((SOAK - SOAK_SPAN)))
		[ -n "$first" ] && [ -n "$final" ] ||
			why "the iperf3 report does not reach from second 0 to second $SOAK: the run ended early"
		idle=$(iperf_idle "$TMP/iperf-soak.json" 0)
		[ "$idle" -eq 0 ] || why "$idle minute(s) of the run carried less than 1 Mbps"
		speed="$mbps Mbps over $SOAK s, first minute ${first:-?}, last minute ${final:-?}$(iperf_detail "$TMP/iperf-soak.json" | sed 's/slowest second/slowest minute/')"
	fi
	[ "$(value "$TMP/soak-end" boot_id)" = "$(value "$TMP/soak-start" boot_id)" ] ||
		why "the board is in another boot than at the start: it rebooted under the run"
	[ "$(value "$TMP/soak-end" kernel_mark)" = yes ] ||
		why "the kernel log no longer has the mark of the start: its lines of the run cannot be told from older ones"
	trouble=$(section "$TMP/soak-end" trouble | grep -c .)
	[ "$trouble" -eq 0 ] || why "$trouble kernel line(s) of the run tell of trouble (marked ! below)"
	free_was=$(value "$TMP/soak-start" free_kb); free_now=$(value "$TMP/soak-end" free_kb)
	# In the engine layout one engine carries the whole run, on all along: a
	# restart the supervisor did under it is a fault too.
	engine_text=
	engine_was=$(value "$TMP/soak-start" daemon); engine_now=$(value "$TMP/soak-end" daemon)
	if [ -n "$engine_was" ]; then
		end_state=$(status_field "$TMP/soak-end" state)
		end_reason=$(status_field "$TMP/soak-end" reason)
		end_state="${end_state:-no status}${end_reason:+ ($end_reason)}"
		if [ "$engine_now" = "$engine_was" ]; then
			engine_text="; the engine $engine_was all along, $end_state at the end"
		else
			why "the engine was started again under the run: $engine_was at the start, ${engine_now:-none} at the end"
			engine_text="; the engine $engine_was at the start, ${engine_now:-none} at the end, $end_state at the end"
		fi
		[ "$(status_field "$TMP/soak-start" state)" != on ] || status_check "$TMP/soak-end" on "at the end"
	fi

	busy_text="no CPU load read"
	[ -z "$worst" ] || busy_text="busiest CPU ${worst% *} at ${worst#* } %"
	report soak "$speed; $looks looks at the board, $busy_text; memory available: ${free_was:-?} kB at the start, ${free_now:-?} kB at the end$engine_text"
	[ -z "$mbps" ] || echo "               | Mbps of every minute: $(TIMELINE_BARS=0 iperf_timeline "$TMP/iperf-soak.json")"
	section "$TMP/soak-end" trouble | sed 's/^/               ! /'
	section "$TMP/soak-end" kernel | sed 's/^/               | /'
}

# REBOOTS boots in a row, each passing the checks of boot (in the layout it
# is enabled for), in the layout of the boot the item began in, and carrying
# the traffic of baseline.
item_reboots_kernel() {
	item=reboots
	n=0
	first_layout=
	while [ $n -lt "$REBOOTS" ]; do
		n=$((n + 1))
		# Two reboots in a row before the boot finished starting the engine
		# layout keep the next boots out of it, as hangs would (bmcHwAccelDpdk).
		if ! hwaccel_until "reboots-mark-$n" "$MARK_WAIT" mark_gone "reboots-mark-$n"; then
			why "boot $((n - 1)): the mark of the boot is still there $MARK_WAIT s after it came up"
			report reboots "stopped before boot $n of $REBOOTS"
			return
		fi
		[ $n -gt 1 ] || first_layout=$(value "$TMP/hw-reboots-mark-1" layout)
		switch reboot > "$TMP/switch"
		[ -n "$(value "$TMP/switch" boot_id)" ] || {
			why "boot $n: the board did not take the reboot command"
			report reboots "stopped before boot $n of $REBOOTS"
			return
		}
		tagged "boot $n" wait_boot booted || {
			report reboots "boot $n of $REBOOTS did not come up"
			return
		}
		back=$waited
		board "ITEM=reboots-$n
$(layout_script)" > "$TMP/layout"
		tagged "boot $n" layout_check
		layout=$(value "$TMP/layout" layout)
		boot_state=${state:-}
		reason=$(status_field "$TMP/layout" reason)
		[ -z "$reason" ] || boot_state="$boot_state ($reason)"
		# A boot of the engine layout that falls back on the kernel layout
		# nobody asked for: the reason is in the status.
		[ -z "$first_layout" ] || [ "$layout" = "$first_layout" ] ||
			why "boot $n: the ${layout:-unknown} layout, bmchwaccel status ${boot_state:-none}; the reboots began in the $first_layout layout"
		# The layout of earlier boots is asked for again in the new one.
		net_key=
		tagged "boot $n" carry reboots || {
			report reboots "stopped in boot $n of $REBOOTS, which could not be measured"
			return
		}
		printf '%-14s boot %s of %s: back after %s s; %s layout%s; %s kernel line(s) of trouble; %s Mbps; %s\n' \
			reboots $n "$REBOOTS" "$back" "${layout:-?}" "${boot_state:+, $boot_state}" "${trouble:-?}" "$mbps" "$(load_text "$TMP/load-reboots")"
		[ -z "$reasons" ] || break
	done
	if [ -z "$reasons" ]; then
		report reboots "$n boots, each passing the checks of boot and carrying the traffic of baseline"
	else
		report reboots "boot $n of $REBOOTS failed; stopped there, the board is still in that boot"
		section "$TMP/layout" trouble | sed 's/^/               ! /'
		section "$TMP/layout" log | sed 's/^/               | /'
	fi
}

# IDLE comes from the caller: the load of every CPU and the CPU of every
# thread of the engine over IDLE seconds, "cpu <cpu> <busy %> <softirq %>",
# "thread <name> <cpu it last ran on> <% of a CPU>", and "worker_cpus=".
idle_script() { cat <<'EOF'
# hwaccel:idle
pid=$(pidof bmchwaccel-engine)
[ -n "$pid" ] || { echo "engine=none"; exit 0; }
echo "engine=$pid"
cpus() { grep '^cpu[0-9]' /proc/stat; }
# name, CPU, utime + stime (the names of the threads of DPDK have no space; its
# workers are rte-worker-N in the DPDK of the dpdk package, lcore-worker-N or
# dpdk-workerN in others)
threads() {
	for t in /proc/$pid/task/*; do
		awk '{ gsub(/[()]/, "", $2); print $2, $39, $14 + $15 }' "$t/stat" 2>/dev/null
	done
}
cpus > /tmp/idle-ca; threads > /tmp/idle-ta
sleep "$IDLE"
cpus > /tmp/idle-cb; threads > /tmp/idle-tb
awk 'NR == FNR { for (i = 2; i <= 9; i++) a[$1, i] = $i; next }
	{
		t = 0
		for (i = 2; i <= 9; i++) { d[i] = $i - a[$1, i]; t += d[i] }
		if (t > 0) printf "cpu %s %.1f %.1f\n", substr($1, 4), 100 * (t - d[5] - d[6]) / t, 100 * d[8] / t
	}' /tmp/idle-ca /tmp/idle-cb
awk -v s="$IDLE" 'NR == FNR { a[$1] = $3; next } { printf "thread %s %s %.2f\n", $1, $2, ($3 - a[$1]) / s }' \
	/tmp/idle-ta /tmp/idle-tb
echo "worker_cpus=$(awk '$1 ~ /-worker-?[0-9]+$/ { printf "%s%s", sep, $2; sep = " " }' /tmp/idle-tb)"
rm -f /tmp/idle-ca /tmp/idle-cb /tmp/idle-ta /tmp/idle-tb
exit 0
EOF
}

# The engine, its container and the DPAA2 objects: "pid=", "dprc=",
# "objects=" (every object of every container), and with ACTION=kill the
# engine is killed (kill -9) a second after the answer, detached: the answer
# goes out through the engine.
engine_script() { cat <<'EOF'
# hwaccel:engine
pid=$(pidof bmchwaccel-engine)
echo "pid=$pid"
echo "dprc=$(awk '$1 == "dprc" { print $2 }' /var/run/bmchwaccel/container 2>/dev/null)"
echo "objects=$(for c in $(restool dprc list 2>/dev/null | awk '{ print $1 }'); do
	restool dprc show "$c" 2>/dev/null | awk '$1 ~ /^dp[a-z]+\.[0-9]+$/ { print $1 }'
done | sort | md5sum | cut -c1-12) $(for c in $(restool dprc list 2>/dev/null | awk '{ print $1 }'); do
	restool dprc show "$c" 2>/dev/null | awk '$1 ~ /^dp[a-z]+\.[0-9]+$/'
done | wc -l)"
/usr/lib/bmcHwAccelDpdk/container check > /dev/null 2>&1 && echo "container=complete"
if [ "${ACTION:-}" = kill ] && [ -n "$pid" ]; then
	setsid sh -c "sleep 1; kill -9 $pid" < /dev/null > /dev/null 2>&1 &
	echo "killed=$pid"
fi
exit 0
EOF
}

# PORT and IFACE come from the caller: the carrier of PORT, whether netifd
# has IFACE up, the answer of "bmchwaccel ports", the layout of the boot and
# what the web UI shows of the ports (get_ether_port_status.sh, without
# blanks).
carrier_script() { cat <<'EOF'
# hwaccel:carrier
echo "carrier=$(cat "/sys/class/net/$PORT/carrier" 2>/dev/null)"
echo "up=$(ifstatus "$IFACE" 2>/dev/null | sed -n 's/^[[:space:]]*"up": \([a-z]*\),*/\1/p' | head -1)"
! command -v bmchwaccel > /dev/null || echo "ports=$(bmchwaccel ports 2>&1 | head -1)"
echo "layout=$(/usr/lib/bmcHwAccelDpdk/layout current 2>/dev/null)"
W=/etc/bmcweb/backend/scripts/network/get_ether_port_status.sh
[ ! -r "$W" ] || echo "web=$(bash "$W" 2>/dev/null | tr -d ' \t\n')"
exit 0
EOF
}

# WINDOW comes from the caller: the answer of "bmchwaccel ports", then the
# one WINDOW seconds later.
wirestats_script() { cat <<'EOF'
# hwaccel:wirestats
echo "first=$(bmchwaccel ports 2>&1 | head -1)"
sleep "$WINDOW"
echo "second=$(bmchwaccel ports 2>&1 | head -1)"
exit 0
EOF
}

# WINDOW comes from the caller: what the web UI dashboard shows of the ports,
# read from the scripts it calls, without blanks: the answer of
# get_net_stats.sh, the one WINDOW seconds later and the hundredths of a
# second between the starts of the two (the script takes a while, the
# counters are read at the same point of each run), then the answer of
# get_ether_port_status.sh. The scripts live where the 24.10 firmware puts
# them.
webports_script() { cat <<'EOF'
# hwaccel:webports
D=/etc/bmcweb/backend/scripts/network
[ -r "$D/get_net_stats.sh" ] && [ -r "$D/get_ether_port_status.sh" ] || { echo "no_script=yes"; exit 0; }
flat() { bash "$D/$1" 2>/dev/null | tr -d ' \t\n'; }
cs() { awk '{ printf "%d", $1 * 100 }' /proc/uptime; }
t=$(cs)
echo "first=$(flat get_net_stats.sh)"
sleep "$WINDOW"
echo "gap_cs=$(($(cs) - t))"
echo "second=$(flat get_net_stats.sh)"
echo "web_ports=$(flat get_ether_port_status.sh)"
exit 0
EOF
}

# PEER comes from the caller: dpdk-pdump on the cable side of eth1 while the
# board pings PEER 5 times; "request=" and "reply=" are the ICMP echoes of
# the capture.
pdump_script() { cat <<'EOF'
# hwaccel:pdump
[ -n "$PEER" ] || PEER=${SSH_CONNECTION%% *}
echo "peer=$PEER"
x=$(/usr/lib/bmcHwAccelDpdk/container check 2>/dev/null | awk '$1 == "port" && $2 == "eth1" { print $3 }')
dprc=$(awk '$1 == "dprc" { print $2 }' /var/run/bmchwaccel/container 2>/dev/null)
[ -n "$x" ] || { echo "wire=none"; exit 0; }
echo "wire=$x"
rm -f /tmp/pdump.pcap
DPRC=$dprc dpdk-pdump -l 6 --log-level='*:warning' -- \
	--pdump "device_id=$x,queue=*,rx-dev=/tmp/pdump.pcap,tx-dev=/tmp/pdump.pcap,total-num-mbufs=2047" \
	> /tmp/pdump.log 2>&1 &
p=$!
# its EAL takes some 15 s on the board to start; the capture file is there
# once its port is (its output is buffered)
i=0
while [ ! -f /tmp/pdump.pcap ] && [ $i -lt 60 ]; do
	sleep 1
	i=$((i + 1))
done
echo "ready=$i"
echo "huge_free=$(awk '/HugePages_Free/ { print $2 }' /proc/meminfo)"
sleep 2
# busybox ping: whole seconds apart only
ping -c 5 -W 1 "$PEER" > /dev/null 2>&1
sleep 1
kill -INT $p 2>/dev/null
sleep 2
kill -9 $p 2>/dev/null
echo "request=$(tcpdump -nr /tmp/pdump.pcap "icmp[0] == 8 and dst host $PEER" 2>/dev/null | wc -l)"
echo "reply=$(tcpdump -nr /tmp/pdump.pcap "icmp[0] == 0 and src host $PEER" 2>/dev/null | wc -l)"
echo "@log"
tail -5 /tmp/pdump.log
exit 0
EOF
}

item_idle() {
	board "IDLE=$IDLE
$(idle_script)" > "$TMP/idle"
	[ "$(value "$TMP/idle" engine)" != none ] || {
		why "the engine does not run"
		report idle "not measured"
		return
	}
	workers=$(value "$TMP/idle" worker_cpus)
	[ -n "$workers" ] || why "the engine has no worker thread"
	text=
	for c in $workers; do
		busy=$(awk -v c="$c" '$1 == "cpu" && $2 == c { print $3 }' "$TMP/idle")
		text="$text${text:+, }$c $busy"
		awk -v b="$busy" -v m="$IDLE_MAX" 'BEGIN { exit !(b != "" && b < m) }' ||
			why "CPU $c of a worker is ${busy:-?} % busy, need less than $IDLE_MAX %"
	done
	report idle "$IDLE s without traffic: worker CPUs busy % $text; $(load_text "$TMP/idle" | sed 's/^CPU/all CPUs/')"
	awk '$1 == "thread" { printf "               | thread %s on CPU %s: %s %% of a CPU\n", $2, $3, $4 }' "$TMP/idle"
}

# The longest gap between two answers of the pings in $1 (0.1 s apart), in s.
ping_gap() {
	sed -n 's/.*icmp_seq=\([0-9]*\).*/\1/p' "$1" | awk -v n="$2" '
		{ if (NR > 1 && $1 - last > gap) gap = $1 - last; last = $1; got++ }
		END {
			if (n - 1 - last > gap) gap = n - 1 - last
			if (got) printf "%.1f %d\n", gap / 10, got; else print "- 0"
		}'
}

item_restart() {
	n=300
	# wan given an address when it has none from DHCP, so that PC2 answers
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report restart "not tested"; return; }
	board "$(engine_script)" > "$TMP/engine-a"
	pid=$(value "$TMP/engine-a" pid)
	[ -n "$pid" ] || { why "the engine does not run"; report restart "not tested"; return; }
	[ "$(value "$TMP/engine-a" container)" = complete ] || why "the container of the engine is not complete before the kill"
	ping -i 0.1 -c $n "$BOARD" > "$TMP/restart-board" 2>&1 &
	p1=$!
	ping -i 0.1 -c $n "$SERVER" > "$TMP/restart-server" 2>&1 &
	p2=$!
	sleep 3
	board "ACTION=kill
$(engine_script)" > "$TMP/engine-kill"
	wait $p1 $p2
	board "$(engine_script)" > "$TMP/engine-b"
	new=$(value "$TMP/engine-b" pid)
	[ -n "$new" ] && [ "$new" != "$pid" ] || why "the engine was not started again (pid ${new:-none}, was $pid)"
	[ "$(value "$TMP/engine-b" container)" = complete ] || why "the container of the engine is not complete after the restart"
	[ "$(value "$TMP/engine-b" dprc)" = "$(value "$TMP/engine-a" dprc)" ] || why "the engine runs on another container"
	[ "$(value "$TMP/engine-b" objects)" = "$(value "$TMP/engine-a" objects)" ] ||
		why "DPAA2 objects were made or are gone: $(value "$TMP/engine-a" objects) before, $(value "$TMP/engine-b" objects) after"
	set -- $(ping_gap "$TMP/restart-board" $n)
	gap_board=$1; got_board=$2
	set -- $(ping_gap "$TMP/restart-server" $n)
	gap_server=$1; got_server=$2
	for f in board server; do
		last=$(sed -n 's/.*icmp_seq=\([0-9]*\).*/\1/p' "$TMP/restart-$f" | tail -1)
		[ "${last:-0}" -ge $((n - 20)) ] || why "the pings to the $f do not answer again after the kill"
	done
	report restart "engine $pid killed, $new started again on $(value "$TMP/engine-b" dprc), objects as before; longest time without an answer: board ${gap_board} s ($got_board of $n), $SERVER ${gap_server} s ($got_server of $n)"
}

# A field of a port in a "bmchwaccel ports" answer of a board answer; nothing
# when the answer does not list the port.
port_field() { # file, name of the answer, port, field
	value "$1" "$2" | tr '{' '\n' | grep "\"interface\":\"$3\"" |
		sed -n "s/.*\"$4\":\"\{0,1\}\([a-z0-9]*\).*/\1/p" | head -1
}

item_carrier() {
	wait_carrier() { # carrier up link web-status phase
		i=0
		while [ $i -lt "$CARRIER_WAIT" ]; do
			board "ITEM=carrier-$5
PORT=$WAN_PORT
IFACE=wan
$(carrier_script)" > "$TMP/carrier"
			# in the engine layout the engine holds the port: its link must follow
			wire=$(port_field "$TMP/carrier" ports "$WAN_PORT" link)
			[ "$(value "$TMP/carrier" layout)" != engine ] || [ -n "$wire" ] || wire=none
			# and so must the port on the web UI, when it is there
			web=$(port_field "$TMP/carrier" web "$WAN_PORT" status)
			[ -z "$(value "$TMP/carrier" web)" ] || [ -n "$web" ] || web=none
			[ "$(value "$TMP/carrier" carrier)" = "$1" ] && [ "$(value "$TMP/carrier" up)" = "$2" ] &&
				{ [ -z "$wire" ] || [ "$wire" = "$3" ]; } && { [ -z "$web" ] || [ "$web" = "$4" ]; } && return 0
			sleep 1
			i=$((i + 1))
		done
		return 1
	}
	# wan given an address when it has none from DHCP, so that it is up. A
	# static wan keeps its link without a carrier (force_link is 1 for it in
	# netifd), DHCP does not: the address set here goes with the carrier too.
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report carrier "not tested"; return; }
	board '[ -d /etc/hwaccel-orig ] && [ "$(uci -q get network.wan.proto)" = static ] || exit 0
uci set network.wan.force_link=0 && uci commit network && ifup wan
i=0
while [ $i -lt 20 ] && ! ifstatus wan | grep -q "\"up\": true"; do sleep 1; i=$((i + 1)); done
exit 0' > /dev/null
	echo "carrier: unplug the cable of $WAN_PORT (PC2) now" >&2
	if wait_carrier 0 false down inactive down; then
		gone=$i
		gone_wire=$wire
		gone_web=$web
		echo "carrier: plug the cable of $WAN_PORT back now" >&2
		if wait_carrier 1 true up active up; then
			report carrier "$WAN_PORT lost its carrier and wan went down ${gone} s after the prompt${gone_wire:+, bmchwaccel ports link $gone_wire}${gone_web:+, web UI $gone_web}; both came back ${i} s after the next${wire:+, link $wire}${web:+, web UI $web}"
		else
			why "$WAN_PORT: carrier $(value "$TMP/carrier" carrier), wan up $(value "$TMP/carrier" up)${wire:+, bmchwaccel ports link $wire}${web:+, web UI $web} $CARRIER_WAIT s after the cable was to be plugged back"
			report carrier "did not come back"
		fi
	else
		why "$WAN_PORT: carrier $(value "$TMP/carrier" carrier), wan up $(value "$TMP/carrier" up)${wire:+, bmchwaccel ports link $wire}${web:+, web UI $web} $CARRIER_WAIT s after the cable was to be unplugged"
		report carrier "did not go down"
	fi
}

# The cable counters of the engine's ports under iperf3 -P 4 from PC1 to PC2
# (-R: back), against what iperf3 carried while they were read: as
# "bmchwaccel ports" gives them (wire-stats), or as the web UI dashboard
# shows them (webui-ports).
item_wire_stats() { # wire-stats | wire-stats-back | webui-ports | webui-ports-back
	item=$1
	reverse=; case $item in *-back) reverse=-R ;; esac
	case $item in
	webui-*) script=$(webports_script); said="the web UI"; link_answer=web_ports; link_key=status; link_up=active ;;
	*) script=$(wirestats_script); said="bmchwaccel ports"; link_answer=second; link_key=link; link_up=up ;;
	esac
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report "$item" "not measured"; return; }
	board "$(flush_script)"
	# shellcheck disable=SC2086
	"$IPERF3" -c "$server" -t "$DURATION" -P 4 -J -T "$item" $reverse > "$TMP/iperf-$item.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "ITEM=$item
WINDOW=$WINDOW
$script" > "$TMP/wirestats-$item"
	wait "$iperf_pid"
	iperf_pid=
	f=$TMP/wirestats-$item
	mbps=$(iperf_mbps "$TMP/iperf-$item.json")
	if [ -z "$mbps" ]; then
		err=$(iperf_error "$TMP/iperf-$item.json")
		why "iperf3: ${err:-no report; is \"iperf3 -s\" running on $server?}"
		report "$item" "no iperf3 result"
		return
	fi
	if [ "$(value "$f" no_script)" = yes ]; then
		why "get_net_stats.sh or get_ether_port_status.sh is not on the board; the web UI package must be installed"
		report "$item" "the scripts of the web UI dashboard are missing"
		return
	fi
	text=
	missing=
	between="$WINDOW s"
	gap_text=
	for p in "$ENGINE_LAN_PORT" "$WAN_PORT"; do
		link=$(port_field "$f" "$link_answer" "$p" "$link_key")
		speed=$(port_field "$f" "$link_answer" "$p" speed)
		if [ -z "$link" ] || [ -z "$(port_field "$f" first "$p" rx_bytes)" ] || [ -z "$(port_field "$f" second "$p" rx_bytes)" ]; then
			why "$said does not list $p"
			missing=1
			continue
		fi
		[ "$link" = "$link_up" ] || why "$said: $p link $link while iperf3 runs"
		[ "$speed" -gt 0 ] 2>/dev/null || why "$said: $p speed $speed"
		text="$text, $p link $link speed $speed"
	done
	span=$(iperf_span_mbps "$TMP/iperf-$item.json" "$WARMUP" "$((WARMUP + WINDOW))")
	if [ -n "$missing" ]; then
		:
	elif [ -z "$span" ] || [ "$span" -le 0 ] 2>/dev/null; then
		why "iperf3 reported no throughput for the window [$WARMUP, $((WARMUP + WINDOW))] s; the bytes were not judged"
	else
		# Mbps over the window -> bytes of application payload in it, over
		# the time between the two reads when the board measured it.
		payload=$((span * 125000 * WINDOW))
		gap_cs=$(value "$f" gap_cs)
		if [ "$gap_cs" -gt 0 ] 2>/dev/null; then
			between="$((gap_cs / 100)).$(printf '%02d' $((gap_cs % 100))) s"
			gap_text=", $between between the reads"
			payload=$((span * 125000 * gap_cs / 100))
		fi
		if [ -n "$reverse" ]; then
			set -- "$WAN_PORT" rx_bytes "$ENGINE_LAN_PORT" tx_bytes
		else
			set -- "$ENGINE_LAN_PORT" rx_bytes "$WAN_PORT" tx_bytes
		fi
		lo=$((payload * STATS_LOW / 100)); hi=$((payload * STATS_HIGH / 100))
		while [ $# -gt 0 ]; do
			a=$(port_field "$f" first "$1" "$2"); b=$(port_field "$f" second "$1" "$2")
			grew=$((${b:-0} - ${a:-0}))
			[ "$grew" -ge "$lo" ] ||
				why "$1 $2 grew by $grew bytes in $between, need at least $lo (${STATS_LOW}% of the $payload bytes iperf3 carried)"
			[ "$grew" -le "$hi" ] ||
				why "$1 $2 grew by $grew bytes in $between, more than $hi (${STATS_HIGH}% of the $payload bytes iperf3 carried)"
			text="$text, $1 $2 +$grew"
			shift 2
		done
	fi
	failed=$reasons
	report "$item" "$mbps Mbps${span:+, $span Mbps in the $WINDOW s window}$gap_text${text}; the copper side of $WAN_PORT is what PC2 shows"
	[ -z "$failed" ] || { value "$f" first; value "$f" second; value "$f" web_ports; } | sed 's/^/               | /'
}

item_pdump() {
	board "PEER='$PC1'
$(pdump_script)" > "$TMP/pdump"
	peer=$(value "$TMP/pdump" peer)
	wire=$(value "$TMP/pdump" wire)
	[ "$wire" != none ] || { why "eth1 has no cable side of the engine (not the engine layout?)"; report pdump "not tested"; return; }
	req=$(value "$TMP/pdump" request); rep=$(value "$TMP/pdump" reply)
	[ "${req:-0}" -ge 5 ] || why "the capture has ${req:-no} echo requests to $peer, need 5"
	[ "${rep:-0}" -ge 5 ] || why "the capture has ${rep:-no} echo replies from $peer, need 5"
	report pdump "dpdk-pdump on $wire (cable side of eth1), capturing after $(value "$TMP/pdump" ready) s with $(value "$TMP/pdump" huge_free) hugepages left: $req echo requests to and $rep replies from $peer"
	[ -z "$reasons" ] || section "$TMP/pdump" log | sed 's/^/               | /'
}

# ACTION comes from the caller: "bmchwaccel ACTION" (enable or disable; none:
# nothing), then what the board says of Tăng tốc phần cứng: its answer, the
# answer of "bmchwaccel status", the boot, the layout of the boot, whether the
# mark of the boot is still there, why the boots after are in the kernel
# layout (what /etc/bmcHwAccel keeps), the engine, and the syslog lines of
# bmcHwAccel. With KILL=yes the engine is killed (kill -9) a second after the
# answer, detached: the answer goes out through the engine.
hwaccel_script() { cat <<'EOF'
# hwaccel:state
[ -z "${ACTION:-}" ] || echo "answer=$(bmchwaccel "$ACTION" 2>&1 | head -1)"
echo "status=$(bmchwaccel status 2>&1 | head -1)"
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
logread | grep -q 'init complete' && echo init=complete
echo "layout=$(/usr/lib/bmcHwAccelDpdk/layout current 2>/dev/null)"
if [ -e /etc/bmcHwAccel/booting ]; then echo mark=yes; else echo mark=no; fi
echo "kept=$(cat /etc/bmcHwAccel/unavailable 2>/dev/null)"
pid=$(pidof bmchwaccel-engine)
echo "engine=$pid"
if [ "${KILL:-}" = yes ] && [ -n "$pid" ]; then
	setsid sh -c "sleep 1; kill -9 $pid" < /dev/null > /dev/null 2>&1 &
	echo "killed=$pid"
fi
echo "@log"
logread | grep 'bmcHwAccel' | tail -8
exit 0
EOF
}

# What the board says of Tăng tốc phần cứng, after ACTION, in $TMP/hw-<name>.
hwaccel() { # name [action [kill]]
	board "ITEM=$1
ACTION=${2:-}
KILL=${3:-}
$(hwaccel_script)" > "$TMP/hw-$1" 2>&1
}

# Checks the answer in $TMP/hw-<name>: the state, "reboot_required" and the
# layout of the boot.
hwaccel_check() { # name state reboot_required layout
	status_check "$TMP/hw-$1" "$2" "$1"
	required=$(status_field "$TMP/hw-$1" reboot_required)
	[ "$required" = "$3" ] || why "$1: reboot_required is ${required:-missing}, need $3"
	[ "$(value "$TMP/hw-$1" layout)" = "$4" ] || why "$1: the $(value "$TMP/hw-$1" layout) layout, need the $4 layout"
}

# "on, reboot_required false, engine layout" of $TMP/hw-<name>.
hwaccel_text() { # name
	text=$(status_field "$TMP/hw-$1" state)
	reason=$(status_field "$TMP/hw-$1" reason)
	[ -z "$reason" ] || text="$text ($reason)"
	echo "$text, reboot_required $(status_field "$TMP/hw-$1" reboot_required), $(value "$TMP/hw-$1" layout) layout"
}

# Asks the board again until the condition $3... holds for its answer in
# $TMP/hw-<name>, at most $2 seconds.
hwaccel_until() { # name seconds condition...
	name=$1 limit=$2
	shift 2
	polled=0
	while [ $polled -lt "$limit" ]; do
		hwaccel "$name" && "$@" && return 0
		sleep 2
		polled=$((polled + 2))
	done
	return 1
}

# Another engine than $2 runs, and the state is on, in $TMP/hw-<name>.
engine_back() { # name pid before
	[ -n "$(value "$TMP/hw-$1" engine)" ] && [ "$(value "$TMP/hw-$1" engine)" != "$2" ] &&
		[ "$(status_field "$TMP/hw-$1" state)" = on ]
}

# The mark of the boot in $TMP/hw-<name> is gone: the boot finished starting
# the engine layout, and a reboot now does not keep the next one out of it.
mark_gone() { # name
	[ "$(value "$TMP/hw-$1" mark)" != yes ]
}

# Reboots the board and waits for the new boot; fails with a reason.
reboot_board() { # what for
	switch reboot > "$TMP/switch"
	[ -n "$(value "$TMP/switch" boot_id)" ] || { why "$1: the board did not take the reboot command"; return 1; }
	tagged "$1" wait_boot booted
}

# A sample of the board, read while Tăng tốc phần cứng is off under traffic
# -> off_text, with a reason for a port of the engine the kernel saw too
# few packets of.
off_judge() { # file
	off_text=
	for p in eth0 eth1; do
		kernel=$(grown "$1" "$p")
		[ -n "$kernel" ] && [ "$kernel" -ge "$ENGINE_MIN" ] ||
			why "only ${kernel:-no} packets of $p went through the kernel in $WINDOW s, need at least $ENGINE_MIN: the engine still carried the connections"
		off_text="$off_text, kernel $p +${kernel:-?}"
	done
	off_text="in $WINDOW s:${off_text#,}"
}

item_onoff() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report onoff "not tested"; return; }
	hwaccel onoff-before
	hwaccel_check onoff-before on false engine
	[ -z "$reasons" ] || { report onoff "not tested: Tăng tốc phần cứng is not on in the engine layout"; return; }
	board "$(flush_script)"
	"$IPERF3" -c "$server" -t "$ONOFF_TIME" -P 4 -J -T onoff > "$TMP/iperf-onoff.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	hwaccel onoff-off disable
	board "ITEM=onoff-off
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/accel-onoff-off"
	hwaccel onoff-on enable
	sleep "$WARMUP"
	board "ITEM=onoff-on
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/accel-onoff-on"
	wait "$iperf_pid"
	iperf_pid=
	hwaccel_check onoff-off off true engine
	tagged disabled off_judge "$TMP/accel-onoff-off"
	hwaccel_check onoff-on on false engine
	tagged enabled accel_judge "$TMP/accel-onoff-on" "$ENGINE_LAN_PORT"
	for line in 'turned off' 'turned on'; do
		cat "$TMP/hw-onoff-off" "$TMP/hw-onoff-on" | grep -q "bmcHwAccel.*Tăng tốc phần cứng $line" ||
			why "syslog has no line \"Tăng tốc phần cứng $line\""
	done
	mbps=$(iperf_mbps "$TMP/iperf-onoff.json")
	err=$(iperf_error "$TMP/iperf-onoff.json")
	[ -n "$mbps" ] && [ -z "$err" ] || why "iperf3 did not run to its end: ${err:-no report}"
	idle=$(iperf_idle "$TMP/iperf-onoff.json" 0)
	[ "$idle" -eq 0 ] || why "$idle second(s) of iperf3 carried less than 1 Mbps: TCP stood still"
	report onoff "disabled $WARMUP s into iperf3 -P 4: $(hwaccel_text onoff-off), $off_text; enabled: $(hwaccel_text onoff-on), $WARMUP s later $accel_text; iperf3 ${mbps:-?} Mbps over $ONOFF_TIME s, not interrupted"
	section "$TMP/hw-onoff-on" log | sed 's/^/               | /'
}

item_enable_boot() {
	hwaccel enable-before
	hwaccel_check enable-before on false engine
	[ -z "$reasons" ] || { report enable-boot "not tested: Tăng tốc phần cứng is not on in the engine layout"; return; }
	hwaccel enable-disabled disable
	reboot_board disabled || { report enable-boot "the board did not come back"; return; }
	hwaccel enable-kernel
	hwaccel_check enable-kernel off false kernel
	hwaccel enable-enabled enable
	hwaccel_check enable-enabled off true kernel
	case "$(value "$TMP/hw-enable-enabled" status)" in
	*"after a restart"*) ;;
	*) why "the status does not say that it takes effect after a restart: $(value "$TMP/hw-enable-enabled" status)" ;;
	esac
	sleep "$ENABLE_WAIT"
	hwaccel enable-waited
	[ "$(value "$TMP/hw-enable-waited" boot_id)" = "$(value "$TMP/hw-enable-enabled" boot_id)" ] ||
		why "the board restarted by itself after enable"
	hwaccel_check enable-waited off true kernel
	reboot_board enabled || { report enable-boot "the board did not come back"; return; }
	hwaccel enable-after
	hwaccel_check enable-after on false engine
	report enable-boot "disabled and restarted: $(hwaccel_text enable-kernel); enabled: $(hwaccel_text enable-enabled), no restart in $ENABLE_WAIT s; restarted: $(hwaccel_text enable-after)"
}

item_deaths() {
	hwaccel deaths-before
	hwaccel_check deaths-before on false engine
	[ -z "$reasons" ] || { report deaths "not tested: Tăng tốc phần cứng is not on in the engine layout"; return; }
	back_text=
	pid=$(value "$TMP/hw-deaths-before" engine)
	for k in 1 2; do
		hwaccel "deaths-kill-$k" "" yes
		start=$(date +%s)
		if hwaccel_until "deaths-back-$k" "$DEATH_WAIT" engine_back "deaths-back-$k" "$pid"; then
			back_text="$back_text, kill $k: on again after $(($(date +%s) - start)) s"
			pid=$(value "$TMP/hw-deaths-back-$k" engine)
		else
			why "kill $k: the engine did not come back on within $DEATH_WAIT s ($(hwaccel_text "deaths-back-$k"))"
			report deaths "stopped after kill $k"
			return
		fi
	done
	hwaccel deaths-kill-3 "" yes
	# The boot that ends with the kill, for wait_boot.
	cp "$TMP/hw-deaths-kill-3" "$TMP/switch"
	tagged "kill 3" wait_boot booted || { report deaths "the board did not restart after the third kill"; return; }
	hwaccel deaths-after
	hwaccel_check deaths-after unavailable false kernel
	[ "$(status_field "$TMP/hw-deaths-after" reason)" = engine ] ||
		why "the reason is $(status_field "$TMP/hw-deaths-after" reason), need engine"
	[ -n "$(value "$TMP/hw-deaths-after" kept)" ] || why "/etc/bmcHwAccel keeps no reason"
	grep -q 'bmcHwAccel.*Tăng tốc phần cứng unavailable' "$TMP/hw-deaths-after" ||
		why "the syslog of the new boot has no line \"Tăng tốc phần cứng unavailable\""
	hwaccel deaths-enabled enable
	hwaccel_check deaths-enabled off true kernel
	[ -z "$(value "$TMP/hw-deaths-enabled" kept)" ] || why "enable left the reason in /etc/bmcHwAccel"
	reboot_board enabled || { report deaths "the board did not come back after enable"; return; }
	hwaccel deaths-on
	hwaccel_check deaths-on on false engine
	report deaths "${back_text#, }; kill 3: the router restarted, $(hwaccel_text deaths-after), kept: $(value "$TMP/hw-deaths-after" kept); enabled: $(hwaccel_text deaths-enabled); restarted: $(hwaccel_text deaths-on)"
	section "$TMP/hw-deaths-after" log | sed 's/^/               | /'
}

# ---- the accelerated path (ticket 08 of .scratch/hw-accel-ls1088)

# WINDOW comes from the caller: the packets the kernel's eth0 and eth1 got
# and sent ("<first|second>_<port>=RX TX") and those the engine's cable
# sides got and sent ("<first|second>_wire_<port>=RX TX", from "bmchwaccel
# ports"), read twice WINDOW apart; then what bmchwaccel says, the connections the engine holds and the
# conntrack lines of the iperf3 server's port.
accelsample_script() { cat <<'EOF'
# hwaccel:accelsample
snap() {
	for p in eth0 eth1; do
		echo "$1_$p=$(cat /sys/class/net/$p/statistics/rx_packets) $(cat /sys/class/net/$p/statistics/tx_packets)"
	done
	bmchwaccel ports 2>/dev/null | head -1 | tr '{' '\n' |
		sed -n 's/.*"interface":"\([a-z0-9]*\)".*"rx_packets":\([0-9]*\),"tx_packets":\([0-9]*\).*/\1 \2 \3/p' |
		while read -r p r t; do echo "$1_wire_$p=$r $t"; done
}
snap first
sleep "$WINDOW"
snap second
echo "status=$(bmchwaccel status 2>&1 | head -1)"
echo "tcp_conns=$(bmchwaccel-ctl list 2>/dev/null | grep -c '^conn tcp')"
echo "udp_conns=$(bmchwaccel-ctl list 2>/dev/null | grep -c '^conn udp')"
echo "@conntrack"
grep -E "dport=${SPORT:-5201} " /proc/net/nf_conntrack | head -16
exit 0
EOF
}

# The growth of "<second>_<what>" over "<first>_<what>" in a sample: rx + tx.
grown() { # file, what
	set -- $(value "$1" "first_$2") $(value "$1" "second_$2")
	[ $# -eq 4 ] && echo $(($3 + $4 - $1 - $2))
}

# A sample under traffic that is to be accelerated -> accel_text, with a
# reason for packets of eth0 or eth1 that reached the kernel, an engine that
# did not forward, and a status that does not count the connections.
accel_judge() { # file, port the traffic comes in on
	text=
	for p in eth0 eth1; do
		kernel=$(grown "$1" "$p")
		[ -n "$kernel" ] || why "no kernel counters of $p"
		[ -z "$kernel" ] || [ "$kernel" -lt "$KERNEL_MAX" ] ||
			why "$kernel packets of $p went through the kernel in $WINDOW s, need fewer than $KERNEL_MAX"
		text="$text, kernel $p +${kernel:-?}"
	done
	w=$(grown "$1" "wire_$2")
	[ -n "$w" ] && [ "$w" -ge "$ENGINE_MIN" ] ||
		why "the cable side of $2 counted ${w:-no} packets in $WINDOW s, need at least $ENGINE_MIN"
	status_check "$1" on
	counted=$(status_field "$1" accelerated)
	[ "${counted:-0}" -gt 0 ] 2>/dev/null || why "bmchwaccel status counts ${counted:-no} accelerated connections"
	accel_text="in $WINDOW s:${text#,}, engine $2 +${w:-?}; bmchwaccel status: ${state:-no answer}, ${counted:-?} accelerated"
}

# What an accel item needs (item_plan of scripts/hwaccel/acceptance.sh): the
# -vlan items send from VLAN_CLIENT through the VLAN interface
# VLAN_PARENT.VLAN_ID of the board, the -pppoe items and accel-redial have
# wan dial PPPoE, -vlan-pppoe both (ticket 10).
accel_plan() { # item
	case $1 in
	accel-vlan-pppoe*) item_plan pppoe; need_vlans=$VLAN_ID; client=$VLAN_CLIENT ;;
	accel-vlan*) item_plan vlan-wan ;;
	accel-pppoe* | accel-redial) item_plan pppoe ;;
	*) item_plan brlan-wan ;;
	esac
}

# iperf3 -P 4 to server, from client when it is set, with the board sampled
# in the middle of the run -> mbps and accel_text, with the reasons of
# accel_judge. Fails with a reason when iperf3 gave no result.
accel_run() { # name, iperf3 option (-R or nothing), port the traffic comes in on
	board "$(flush_script)"
	# shellcheck disable=SC2086
	"$IPERF3" -c "$server" ${client:+-B "$client"} -t "$DURATION" -P 4 -J -T "$1" $2 \
		> "$TMP/iperf-$1.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "ITEM=$1
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/accel-$1"
	wait "$iperf_pid"
	iperf_pid=
	mbps=$(iperf_mbps "$TMP/iperf-$1.json")
	if [ -z "$mbps" ]; then
		err=$(iperf_error "$TMP/iperf-$1.json")
		why "iperf3: ${err:-no report; is \"iperf3 -s\" running on $server?}"
		return 1
	fi
	accel_judge "$TMP/accel-$1" "$3"
}

# iperf3 -P 4 through the engine, PC1 -> PC2 (-back: PC2 -> PC1, iperf3
# -R), against the baseline of the kernel layout (ticket 03); over a VLAN of
# the LAN, PPPoE or both as accel_plan says.
item_accel() { # accel[-vlan|-pppoe|-vlan-pppoe][-back]
	item=$1
	case $item in
	*-back) reverse=-R; base=$BASE_BACK_MBPS; in_port=$WAN_PORT ;;
	*) reverse=; base=$BASE_MBPS; in_port=$ENGINE_LAN_PORT ;;
	esac
	accel_plan "$item"
	net_ready "$need_wan" "$need_vlans" || { report "$item" "not measured"; return; }
	server=${server:-$wan_peer}
	accel_run "$item" "$reverse" "$in_port" || { report "$item" "no iperf3 result"; return; }
	min=$((base * ACCEL_PCT / 100))
	[ "$mbps" -ge "$min" ] || why "$mbps Mbps is below $min Mbps ($ACCEL_PCT % of $base Mbps in the kernel layout)"
	failed=$reasons
	report "$item" "$mbps Mbps ($((mbps * 100 / base)) % of $base Mbps in the kernel layout); $accel_text"
	[ -z "$failed" ] || section "$TMP/accel-$item" conntrack | sed 's/^/               | /'
}

# SERVER, DROP_PORT and WINDOW come from the caller (drop_env), WAN_PORT
# too. PPPoE dials
# again under a UDP flow the engine carries, the session ended as pppoe-drop
# of scripts/hwaccel/acceptance.sh ends it: an access concentrator name no
# server has, kept for WINDOW seconds, with the flow dropped quietly
# meanwhile. What the engine holds and what leaves the cable of eth0 while
# the session is down; the session before and after.
redial_script() { cat <<'EOF'
# hwaccel:redial
addr() { ip -4 -o addr show dev pppoe-wan 2>/dev/null | awk '{ print $4; exit }'; }
# Id, MAC address of the server, Ethernet device: the session of wan
session() {
	awk -v dev="$(uci -q get network.wan.device)" 'NR > 1 && $3 == dev { print $1; exit }' \
		/proc/net/pppoe 2>/dev/null
}
held() { bmchwaccel-ctl count 2>/dev/null | awk '{ print $2 }'; }
wire_tx() { bmchwaccel-ctl ports 2>/dev/null | sed -n "s/^port $WAN_PORT .* tx_packets=\([0-9]*\).*/\1/p"; }
echo "session_before=$(session)"
echo "addr_before=$(addr)"
# the flow, by its original direction: conn udp SIP SPORT SERVER DROP_PORT ...
echo "udp_before=$(bmchwaccel-ctl list 2>/dev/null | grep -c "^conn udp [0-9.]* [0-9]* $SERVER $DROP_PORT ")"
# With the session down the board has no route for the flow and would answer
# it with ICMP unreachable, which stops the sender. Drop the flow quietly
# instead.
iptables -t mangle -I PREROUTING -p udp -d "$SERVER" --dport "$DROP_PORT" -j DROP
# An access concentrator name that no server has: pppd ends the session and
# cannot open a new one, while the wan port stays up.
uci set network.wan.ac=hwaccel-no-such-ac
uci commit network
/etc/init.d/network reload
i=0
while [ $i -lt 15 ] && [ -n "$(addr)" ]; do sleep 1; i=$((i + 1)); done
[ -z "$(addr)" ] && echo down=yes || echo down=no
echo "held_down=$(held)"
echo "wire_tx_before=$(wire_tx)"
sleep "$WINDOW"
echo "wire_tx_after=$(wire_tx)"
echo "held_after=$(held)"
uci delete network.wan.ac
uci commit network
/etc/init.d/network reload
i=0
while [ $i -lt 40 ]; do
	[ -n "$(addr)" ] && iptables -t nat -S 2>/dev/null | grep -q -- '-o pppoe-wan ' && break
	sleep 1
	i=$((i + 1))
done
# Only now may the flow pass again: let through before the masquerade rule of
# the new session is there, it would go on without NAT for as long as it lasts.
iptables -t mangle -D PREROUTING -p udp -d "$SERVER" --dport "$DROP_PORT" -j DROP
[ -n "$(addr)" ] && echo up=yes || echo up=no
echo "session_after=$(session)"
echo "addr_after=$(addr)"
EOF
}

# PPPoE dials again (ticket 10). Under a UDP flow to DROP_PORT of the peer
# that the engine carries, the session ends for WINDOW seconds: the engine
# must hold no connection while it is down, and fewer than KERNEL_MAX
# packets leave the cable of eth0. The session must come back; iperf3 -P 4
# over the new one is then accelerated as in accel-pppoe.
item_accel_redial() {
	accel_plan accel-redial
	net_ready "$need_wan" "$need_vlans" || { report accel-redial "not tested"; return; }
	server=${server:-$wan_peer}
	board "$(flush_script)"
	"$IPERF3" -c "$server" -p "$DROP_PORT" -u -b "$DROP_RATE" -l "$DROP_LEN" \
		-t $((WARMUP + WINDOW + REDIAL_MAX)) -J -T accel-redial > "$TMP/iperf-accel-redial.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	# The flow has to outlast the session; an iperf3 that is gone gave up.
	if ! kill -0 "$iperf_pid" 2>/dev/null; then
		wait "$iperf_pid"
		iperf_pid=
		err=$(iperf_error "$TMP/iperf-accel-redial.json")
		why "iperf3: ${err:-ended early}; is \"iperf3 -s -p $DROP_PORT\" running on $server?"
		report accel-redial "not tested"
		return
	fi
	dropping=1
	board "$(drop_env)
WAN_PORT=$WAN_PORT
$(redial_script)" > "$TMP/redial"
	if [ -n "$(value "$TMP/redial" up)" ]; then
		dropping=0
	else
		# The board script did not get to its end: put the wan back now.
		board "$(drop_env)
$(undrop_script)" && dropping=0
	fi
	[ "$(value "$TMP/redial" up)" = yes ] || net_key=
	kill "$iperf_pid" 2>/dev/null
	wait "$iperf_pid" 2>/dev/null
	iperf_pid=

	before=$(value "$TMP/redial" session_before); after=$(value "$TMP/redial" session_after)
	[ "$(value "$TMP/redial" udp_before)" -ge 1 ] 2>/dev/null ||
		why "the UDP flow was not in the engine before the session ended, so nothing was tested"
	if [ "$(value "$TMP/redial" down)" != yes ]; then
		why "the PPPoE session did not go down"
		report accel-redial "session ${before:-?}"
		return
	fi
	held=$(value "$TMP/redial" held_down)
	[ "$held" = 0 ] || why "the engine held ${held:-?} connections once the session was down, need none"
	held=$(value "$TMP/redial" held_after)
	[ "$held" = 0 ] || why "the engine held ${held:-?} connections after $WINDOW s without the session, need none"
	left=
	tx_before=$(value "$TMP/redial" wire_tx_before); tx_after=$(value "$TMP/redial" wire_tx_after)
	if [ "$tx_before" -ge 0 ] 2>/dev/null && [ "$tx_after" -ge 0 ] 2>/dev/null; then
		left=$((tx_after - tx_before))
		[ "$left" -lt "$KERNEL_MAX" ] ||
			why "$left packets left the cable of $WAN_PORT while the session was down, need fewer than $KERNEL_MAX"
	else
		why "bmchwaccel-ctl ports gave no tx packets of the cable of $WAN_PORT"
	fi
	# accel_judge has a text of its own
	redial="session ${before:-?} ($(value "$TMP/redial" addr_before)) ended for $WINDOW s: the engine held $(value "$TMP/redial" held_down) connections, ${left:-?} packets left the cable of $WAN_PORT"
	if [ "$(value "$TMP/redial" up)" != yes ]; then
		why "the PPPoE session did not come back"
		report accel-redial "$redial; not back"
		return
	fi
	redial="$redial; back as session ${after:-?} ($(value "$TMP/redial" addr_after))"
	# A server may give the same number again; the session is a new one all the same.
	[ "$after" != "$before" ] || redial="$redial, the number of the session before"
	if accel_run accel-redial-new "" "$ENGINE_LAN_PORT"; then
		min=$((BASE_MBPS * ACCEL_PCT / 100))
		[ "$mbps" -ge "$min" ] || why "$mbps Mbps is below $min Mbps ($ACCEL_PCT % of $BASE_MBPS Mbps in the kernel layout)"
		redial="$redial; then iperf3 -P 4 over it: $mbps Mbps, $accel_text"
	fi
	report accel-redial "$redial"
}

# iperf3 -u -J report -> "MBPS LOST": what reached PC2 (the rate sent less
# the datagrams PC2 reported lost) and the % lost; nothing without a summary.
iperf_udp() {
	awk '{ s = s $0 }
	END {
		i = index(s, "\"end\":")
		if (!i) exit
		s = substr(s, i)
		i = index(s, "\"sum\":")
		if (!i) exit
		s = substr(s, i)
		if (!match(s, /"bits_per_second":[ \t]*[0-9.eE+]+/)) exit
		b = substr(s, RSTART, RLENGTH); sub(/.*:[ \t]*/, "", b)
		l = 0
		if (match(s, /"lost_percent":[ \t]*[0-9.eE+-]+/)) { l = substr(s, RSTART, RLENGTH); sub(/.*:[ \t]*/, "", l) }
		printf "%d %.1f\n", b * (100 - l) / 100 / 1000000, l
	}' "$1"
}

# UDP that the other end answers (iperf3 -u: the server answers the first
# datagram of each stream, which makes the connection assured), at UDP_RATE,
# PC1 -> PC2 (-R: back): at least ACCEL_PCT % of it arrives.
item_accel_udp() { # accel-udp | accel-udp-back
	item=$1
	if [ "$item" = accel-udp-back ]; then reverse=-R; in_port=$WAN_PORT; else reverse=; in_port=$ENGINE_LAN_PORT; fi
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report "$item" "not measured"; return; }
	board "$(flush_script)"
	# shellcheck disable=SC2086
	"$IPERF3" -c "$server" -u -b "$UDP_RATE" -t "$DURATION" -J -T "$item" $reverse > "$TMP/iperf-$item.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "ITEM=$item
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/$item"
	wait "$iperf_pid"
	iperf_pid=
	set -- $(iperf_udp "$TMP/iperf-$item.json")
	rate=$(echo "$UDP_RATE" | sed 's/M$//')
	if [ $# -ne 2 ]; then
		why "iperf3: $(iperf_error "$TMP/iperf-$item.json")"
	else
		[ "$1" -ge $((rate * ACCEL_PCT / 100)) ] 2>/dev/null ||
			why "$1 Mbps arrived of $UDP_RATE, need at least $ACCEL_PCT %"
	fi
	accel_judge "$TMP/$item" "$in_port"
	[ "$(value "$TMP/$item" udp_conns)" -ge 1 ] 2>/dev/null || why "the engine holds no UDP connection"
	report "$item" "${1:-?} Mbps arrived of $UDP_RATE (${2:-?} % lost); $accel_text, $(value "$TMP/$item" udp_conns) UDP connection(s) in the engine"
}

# UDP that nothing answers: PC1 sends to a port of PC2 where nobody listens,
# for WINDOW seconds and more. It is never accelerated: the engine holds no
# UDP connection and the kernel's eth1 gets every datagram.
item_udp_oneway() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report udp-oneway "not tested"; return; }
	board "$(flush_script)"
	n=$(((WARMUP + WINDOW + 2) * 200))
	python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i in range(int(sys.argv[3])):
    s.sendto(b"x" * 200, (sys.argv[1], int(sys.argv[2])))
    time.sleep(0.005)' "$server" "$ONEWAY_PORT" "$n" &
	sender=$!
	sleep "$WARMUP"
	board "ITEM=udp-oneway
WINDOW=$WINDOW
SPORT=$ONEWAY_PORT
$(accelsample_script)" > "$TMP/udp-oneway"
	wait "$sender"
	k=$(grown "$TMP/udp-oneway" eth1)
	udp=$(value "$TMP/udp-oneway" udp_conns)
	[ "${udp:-1}" = 0 ] || why "the engine holds ${udp:-?} UDP connection(s)"
	# some 200 datagrams a second: most of them must reach the kernel
	[ "${k:-0}" -ge $((WINDOW * 150)) ] || why "only ${k:-no} packets of eth1 reached the kernel in $WINDOW s"
	report udp-oneway "UDP to $server:$ONEWAY_PORT without an answer: kernel eth1 +${k:-?} in $WINDOW s, ${udp:-?} UDP connection(s) in the engine"
}

# ACTION (mark or clear) comes from the caller: the conntrack mark of the
# connections to the iperf3 server's port gets the bit that keeps them on the
# CPU, or loses it, and "gone=" is how long until the engine holds no TCP
# connection (mark), "back=" until it holds one again (clear), in ms, or
# "never" within 5 s.
markwatch_script() { cat <<'EOF'
# hwaccel:markwatch
held() { bmchwaccel-ctl list 2>/dev/null | grep -c '^conn tcp'; }
ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }
echo "held_before=$(held)"
start=$(ms)
if [ "$ACTION" = mark ]; then
	conntrack -U -p tcp --orig-port-dst 5201 --mark 0x10000/0x10000 >/dev/null 2>&1
	key=gone
else
	conntrack -U -p tcp --orig-port-dst 5201 --mark 0/0x10000 >/dev/null 2>&1
	key=back
fi
while :; do
	n=$(held)
	{ [ "$ACTION" = mark ] && [ "$n" = 0 ]; } || { [ "$ACTION" = clear ] && [ "$n" -gt 0 ]; } && break
	[ $(($(ms) - start)) -lt 5000 ] || { echo "$key=never"; exit 0; }
	sleep 0.05
done
echo "$key=$(($(ms) - start))"
exit 0
EOF
}

# The bit 0x10000 set by hand on running connections: they leave the engine
# within KEEP_MS and go through the kernel; cleared, they come back.
item_keep_mark() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report keep-mark "not tested"; return; }
	board "$(flush_script)"
	"$IPERF3" -c "$server" -t "$((WARMUP * 3 + WINDOW * 2 + 10))" -P 4 -J -T keep-mark > "$TMP/iperf-keep-mark.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "ACTION=mark
$(markwatch_script)" > "$TMP/mark-on"
	board "ITEM=mark-kept
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/mark-kept"
	board "ACTION=clear
$(markwatch_script)" > "$TMP/mark-off"
	sleep "$WARMUP"
	board "ITEM=mark-back
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/mark-back"
	wait "$iperf_pid"
	iperf_pid=
	[ "$(value "$TMP/mark-on" held_before)" -gt 0 ] 2>/dev/null || why "the engine held no TCP connection before the mark"
	gone=$(value "$TMP/mark-on" gone)
	[ "$gone" != never ] && [ "${gone:-99999}" -le "$KEEP_MS" ] 2>/dev/null ||
		why "the connections left the engine after ${gone:-?} ms, need at most $KEEP_MS"
	k=$(grown "$TMP/mark-kept" "$ENGINE_LAN_PORT")
	[ "${k:-0}" -ge "$KERNEL_MAX" ] || why "only ${k:-no} packets of $ENGINE_LAN_PORT went through the kernel in $WINDOW s while marked"
	[ "$(value "$TMP/mark-kept" tcp_conns)" = 0 ] || why "the engine held $(value "$TMP/mark-kept" tcp_conns) TCP connection(s) while they were marked"
	back=$(value "$TMP/mark-off" back)
	[ "$back" != never ] || why "cleared, the connections did not come back to the engine within 5 s"
	accel_judge "$TMP/mark-back" "$ENGINE_LAN_PORT"
	err=$(iperf_error "$TMP/iperf-keep-mark.json")
	mbps=$(iperf_mbps "$TMP/iperf-keep-mark.json")
	[ -n "$mbps" ] && [ -z "$err" ] || why "iperf3 did not run to its end: ${err:-no report}"
	report keep-mark "marked: out of the engine after ${gone:-?} ms, kernel $ENGINE_LAN_PORT +${k:-?} in $WINDOW s; cleared: back after ${back:-?} ms, $accel_text; iperf3 ${mbps:-?} Mbps"
}

# ACTION=kill: the daemon is killed (kill -9, detached); "gone=" is how long
# until the engine holds no connection, in ms. Without ACTION: the daemon's
# pid and the connections the engine holds.
daemonkill_script() { cat <<'EOF'
# hwaccel:daemonkill
held() { bmchwaccel-ctl count 2>/dev/null | awk '{ print $2 }'; }
ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }
echo "pid=$(pidof bmchwaccel-syncd)"
echo "held=$(held)"
if [ "${ACTION:-}" = kill ]; then
	pid=$(pidof bmchwaccel-syncd)
	[ -n "$pid" ] || exit 0
	start=$(ms)
	kill -9 $pid
	while [ "$(held)" != 0 ]; do
		[ $(($(ms) - start)) -lt 5000 ] || { echo "gone=never"; exit 0; }
		sleep 0.05
	done
	echo "gone=$(($(ms) - start))"
fi
echo "status=$(bmchwaccel status 2>&1 | head -1)"
exit 0
EOF
}

# The daemon killed under iperf3 -P 4: the engine lets go of every connection
# at once, TCP goes on through the kernel without a break; the supervisor
# starts the daemon again, which hands the connections over anew.
item_daemon_kill() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report daemon-kill "not tested"; return; }
	board "$(flush_script)"
	"$IPERF3" -c "$server" -t "$DURATION" -P 4 -J -T daemon-kill > "$TMP/iperf-daemon-kill.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "ITEM=before
$(daemonkill_script)" > "$TMP/dk-before"
	board "ACTION=kill
$(daemonkill_script)" > "$TMP/dk-kill"
	board "ITEM=dk-kernel
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/dk-kernel"
	i=0
	while [ $i -lt "$DAEMON_WAIT" ]; do
		board "ITEM=after
$(daemonkill_script)" > "$TMP/dk-after"
		[ "$(value "$TMP/dk-after" held)" -gt 0 ] 2>/dev/null && break
		sleep 1
		i=$((i + 1))
	done
	wait "$iperf_pid"
	iperf_pid=
	pid=$(value "$TMP/dk-before" pid)
	[ -n "$pid" ] || why "no daemon ran before the kill"
	[ "$(value "$TMP/dk-before" held)" -gt 0 ] 2>/dev/null || why "the engine held no connection before the kill"
	gone=$(value "$TMP/dk-kill" gone)
	[ "$gone" != never ] && [ -n "$gone" ] || why "the engine still held connections 5 s after the daemon died"
	status_check "$TMP/dk-kill" unavailable "the daemon dead"
	[ "$(status_field "$TMP/dk-kill" reason)" = daemon ] ||
		why "the daemon dead: the reason is $(status_field "$TMP/dk-kill" reason), need daemon"
	k=$(grown "$TMP/dk-kernel" "$ENGINE_LAN_PORT")
	[ "${k:-0}" -ge "$KERNEL_MAX" ] || why "only ${k:-no} packets of $ENGINE_LAN_PORT went through the kernel in $WINDOW s after the kill"
	new=$(value "$TMP/dk-after" pid)
	[ -n "$new" ] && [ "$new" != "$pid" ] || why "the daemon was not started again (pid ${new:-none}, was $pid)"
	[ "$(value "$TMP/dk-after" held)" -gt 0 ] 2>/dev/null || why "the engine held no connection again within $DAEMON_WAIT s"
	status_check "$TMP/dk-after" on "after the restart"
	err=$(iperf_error "$TMP/iperf-daemon-kill.json")
	mbps=$(iperf_mbps "$TMP/iperf-daemon-kill.json")
	[ -n "$mbps" ] && [ -z "$err" ] || why "iperf3 did not run to its end: ${err:-no report}"
	idle=$(iperf_idle "$TMP/iperf-daemon-kill.json" 0)
	[ "${idle:-0}" -le 1 ] || why "iperf3 carried less than 1 Mbps in $idle of its seconds"
	report daemon-kill "daemon $pid killed: the engine let go of everything after ${gone:-?} ms, unavailable/daemon, kernel $ENGINE_LAN_PORT +${k:-?} in $WINDOW s; daemon $new again, connections back after ${i} s; iperf3 ${mbps:-?} Mbps, ${idle:-?} s under 1 Mbps"
}

# ACTION (block or unblock) comes from the caller. block: the daemon is killed
# (kill -9), and once the engine holds nothing, macfilter blocks the MAC of
# PC1 (the SSH peer), before the supervisor starts the daemon again: "gone="
# as in daemonkill_script, "rules=" the DROP rules for the MAC. unblock: the
# entry goes, macfilter is disabled as it was.
blockdaemon_script() { cat <<'EOF'
# hwaccel:blockdaemon
S=/etc/bmcweb/backend/scripts/firewall/macfilter.sh
held() { bmchwaccel-ctl count 2>/dev/null | awk '{ print $2 }'; }
ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }
pc1=${SSH_CONNECTION%% *}
mac=$(ip neigh show "$pc1" 2>/dev/null | sed -n 's/.* lladdr \([0-9a-fA-F:]*\).*/\1/p' | head -1 | tr a-f A-F)
echo "mac=$mac"
if [ "$ACTION" = block ]; then
	echo "held_before=$(held)"
	start=$(ms)
	kill -9 $(pidof bmchwaccel-syncd) 2>/dev/null
	while [ "$(held)" != 0 ]; do
		[ $(($(ms) - start)) -lt 3000 ] || break
		sleep 0.05
	done
	echo "gone=$(($(ms) - start))"
	bash $S enable >/dev/null 2>&1
	bash $S mode blacklist >/dev/null 2>&1
	bash $S add "$mac" >/dev/null 2>&1
	echo "blocked_at=$(($(ms) - start))"
	echo "rules=$(iptables -S MAC_FILTER 2>/dev/null | grep -c -i -- "--mac-source $mac -j DROP")"
else
	bash $S remove "$mac" >/dev/null 2>&1
	bash $S disable >/dev/null 2>&1
	echo "rules=$(iptables -S MAC_FILTER 2>/dev/null | grep -c -i -- "--mac-source $mac -j DROP")"
	echo "held=$(held)"
	echo "status=$(bmchwaccel status 2>&1 | head -1)"
fi
exit 0
EOF
}

# A machine that macfilter blocks while the daemon is dead loses its running
# connections at once: the engine let go of them when the daemon died, so
# the rule meets their next packets in the kernel.
item_daemon_block() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report daemon-block "not tested"; return; }
	board "$(flush_script)"
	"$IPERF3" -c "$server" -t "$((WARMUP + WINDOW + 10))" -P 4 -J -T daemon-block > "$TMP/iperf-daemon-block.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "ACTION=block
$(blockdaemon_script)" > "$TMP/db-block"
	sleep "$WINDOW"
	board "ACTION=unblock
$(blockdaemon_script)" > "$TMP/db-unblock"
	wait "$iperf_pid"
	iperf_pid=
	[ -n "$(value "$TMP/db-block" mac)" ] || why "the board does not know the MAC of PC1"
	[ "$(value "$TMP/db-block" held_before)" -gt 0 ] 2>/dev/null || why "the engine held no connection before"
	[ "$(value "$TMP/db-block" rules)" -ge 1 ] 2>/dev/null || why "macfilter did not take the MAC of PC1"
	[ "$(value "$TMP/db-unblock" rules)" = 0 ] || why "the macfilter entry is still there after the item"
	# the seconds of iperf3 while blocked, the first two spared
	idle=$(iperf_idle "$TMP/iperf-daemon-block.json" "$((WARMUP + 2))" "$((WARMUP + WINDOW))")
	[ "${idle:-0}" -ge $((WINDOW - 3)) ] ||
		why "iperf3 still carried data in $((WINDOW - 2 - ${idle:-0})) of the $((WINDOW - 2)) seconds PC1 was blocked"
	report daemon-block "daemon killed, the engine empty after $(value "$TMP/db-block" gone) ms, PC1 ($(value "$TMP/db-block" mac)) blocked by macfilter $(value "$TMP/db-block" blocked_at) ms after the kill: iperf3 stopped in ${idle:-?} of $((WINDOW - 2)) s; unblocked: $(status_field "$TMP/db-unblock" state), $(value "$TMP/db-unblock" held) held"
}

# PC1 cabled to ONEG_PORT, a 1G port the kernel keeps: its connections to PC2
# are never accelerated, and they work.
oneg_script() { cat <<'EOF'
# hwaccel:oneg
pc1=${SSH_CONNECTION%% *}
mac=$(ip neigh show "$pc1" 2>/dev/null | sed -n 's/.* lladdr \([0-9a-fA-F:]*\).*/\1/p' | head -1)
echo "port=$(bridge fdb show br br-lan 2>/dev/null | grep -i "^$mac " | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
exit 0
EOF
}

item_accel_1g() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report accel-1g "not measured"; return; }
	board "$(oneg_script)" > "$TMP/oneg"
	port=$(value "$TMP/oneg" port)
	[ "$port" = "$ONEG_PORT" ] || { why "PC1 is on ${port:-an unknown port}, not on $ONEG_PORT: cable it there"; report accel-1g "not measured"; return; }
	board "$(flush_script)"
	"$IPERF3" -c "$server" -t "$DURATION" -P 4 -J -T accel-1g > "$TMP/iperf-accel-1g.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "ITEM=accel-1g
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/accel-1g"
	wait "$iperf_pid"
	iperf_pid=
	mbps=$(iperf_mbps "$TMP/iperf-accel-1g.json")
	err=$(iperf_error "$TMP/iperf-accel-1g.json")
	[ -n "$mbps" ] && [ -z "$err" ] || why "iperf3: ${err:-no report}"
	k=$(grown "$TMP/accel-1g" "$WAN_PORT")
	[ "${k:-0}" -ge $((KERNEL_MAX * 10)) ] || why "only ${k:-no} packets of $WAN_PORT went through the kernel in $WINDOW s"
	[ "$(value "$TMP/accel-1g" tcp_conns)" = 0 ] || why "the engine holds $(value "$TMP/accel-1g" tcp_conns) TCP connection(s)"
	report accel-1g "PC1 on $ONEG_PORT: ${mbps:-?} Mbps, kernel $WAN_PORT +${k:-?} in $WINDOW s, $(value "$TMP/accel-1g" tcp_conns) TCP connection(s) in the engine"
}

# The conntrack timeout and state of the iperf3 connections (dport 5201) and
# the INVALID count of conntrack, summed over the CPUs.
ctstate_script() { cat <<'EOF'
# hwaccel:ctstate
n=0
for v in $(awk 'NR > 1 { print $5 }' /proc/net/stat/nf_conntrack); do n=$((n + 0x$v)); done
echo "invalid=$n"
echo "held=$(bmchwaccel-ctl count 2>/dev/null | awk '{ print $2 }')"
echo "@conntrack"
grep -E 'dport=5201 ' /proc/net/nf_conntrack
exit 0
EOF
}

# LONG seconds of UDP that PC2 answers (iperf3 -u, longer than the 180 s UDP
# timeout of conntrack): the connection stays accelerated and in conntrack
# all along, and iperf3 receives every second.
item_udp_long() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report udp-long "not tested"; return; }
	board "$(flush_script)"
	"$IPERF3" -c "$server" -u -b "$UDP_LONG_RATE" -t "$LONG" -J -T udp-long > "$TMP/iperf-udp-long.json" 2>/dev/null &
	iperf_pid=$!
	looks=0; held_all=1
	while kill -0 "$iperf_pid" 2>/dev/null; do
		sleep 60
		kill -0 "$iperf_pid" 2>/dev/null || break
		board "WINDOW=1
$(accelsample_script)" > "$TMP/udp-long-look"
		looks=$((looks + 1))
		[ "$(value "$TMP/udp-long-look" udp_conns)" -ge 1 ] 2>/dev/null || held_all=0
	done
	wait "$iperf_pid"
	iperf_pid=
	[ "$held_all" = 1 ] || why "the engine held no UDP connection at one of the $looks looks"
	set -- $(iperf_udp "$TMP/iperf-udp-long.json")
	mbps=${1:-}
	[ -n "$mbps" ] || why "iperf3: $(iperf_error "$TMP/iperf-udp-long.json")"
	idle=$(iperf_idle "$TMP/iperf-udp-long.json" 0)
	[ "${idle:-0}" = 0 ] || why "iperf3 received less than 1 Mbps in $idle of its seconds"
	report udp-long "$LONG s of UDP at $UDP_LONG_RATE: ${mbps:-?} Mbps reached PC2 (${2:-?} % lost), accelerated at all $looks looks"
}

# UDP that stops: conntrack ends the connection after its timeout
# (nf_conntrack_udp_timeout_stream), counted from the last datagram, and the
# engine lets go of it. The connection is asked for by its tuple (conntrack
# -G): a read of /proc/net/nf_conntrack can miss a line while the table
# changes.
item_udp_expire() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report udp-expire "not tested"; return; }
	board "$(flush_script)"
	"$IPERF3" -c "$server" -u -b 10M -t "$WARMUP" -T udp-expire > /dev/null 2>&1
	board 'echo "timeout=$(cat /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream)"
echo "sport=$(conntrack -L -p udp --orig-port-dst 5201 2>/dev/null | awk "{ for (i = 1; i <= NF; i++) if (\$i ~ /^sport=/) { print substr(\$i, 7); exit } }")"
echo "held=$(bmchwaccel-ctl list | grep -c "^conn udp")"' > "$TMP/expire-0"
	timeout=$(value "$TMP/expire-0" timeout)
	sport=$(value "$TMP/expire-0" sport)
	[ -n "$sport" ] || { why "conntrack has no UDP connection to $server:5201"; report udp-expire "not tested"; return; }
	[ "$(value "$TMP/expire-0" held)" -ge 1 ] 2>/dev/null || why "the UDP connection was not accelerated"
	start=$(date +%s)
	gone=
	# conntrack drops expired entries when its garbage collector meets them
	while [ $(($(date +%s) - start)) -lt $((${timeout:-180} + 90)) ]; do
		sleep 5
		board "conntrack -G -p udp -s \${SSH_CONNECTION%% *} -d $server --sport $sport --dport 5201 >/dev/null 2>&1 && echo ct=1 || echo ct=0
echo \"held=\$(bmchwaccel-ctl list | grep -c '^conn udp [0-9.]* $sport ')\"" > "$TMP/expire-n"
		if [ "$(value "$TMP/expire-n" ct)" = 0 ]; then
			gone=$(($(date +%s) - start))
			break
		fi
	done
	[ -n "$gone" ] || why "the UDP connection is still in conntrack $((${timeout:-180} + 90)) s after its last datagram"
	[ -z "$gone" ] || [ "$gone" -ge $((${timeout:-180} - 10)) ] ||
		why "conntrack ended it after $gone s, before its timeout of $timeout s"
	[ "$(value "$TMP/expire-n" held)" = 0 ] || why "the engine still holds it"
	report udp-expire "quiet UDP: gone from conntrack ${gone:-?} s after its last datagram (timeout $timeout s), and from the engine"
}

# LONG seconds of TCP through the engine, then its end: the FIN and RST that
# reach the kernel after so long are not INVALID (BE_LIBERAL), and the
# connections close in conntrack.
item_tcp_long() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report tcp-long "not tested"; return; }
	board "$(flush_script)"
	board "$(ctstate_script)" > "$TMP/tl-before"
	"$IPERF3" -c "$server" -t "$LONG" -P 4 -J -T tcp-long > "$TMP/iperf-tcp-long.json" 2>/dev/null &
	iperf_pid=$!
	sleep $((LONG / 2))
	board "$(ctstate_script)" > "$TMP/tl-mid"
	wait "$iperf_pid"
	iperf_pid=
	sleep 5
	board "$(ctstate_script)" > "$TMP/tl-after"
	[ "$(value "$TMP/tl-mid" held)" -ge 4 ] 2>/dev/null || why "the engine held $(value "$TMP/tl-mid" held) connections half-way, need 4"
	inv=$(($(value "$TMP/tl-after" invalid) - $(value "$TMP/tl-before" invalid)))
	[ "$inv" -le "$INVALID_MAX" ] || why "conntrack counted $inv INVALID packets during the run, need at most $INVALID_MAX"
	open=$(section "$TMP/tl-after" conntrack | grep -c ESTABLISHED)
	[ "$open" = 0 ] || why "$open iperf3 connection(s) are still ESTABLISHED in conntrack after the end"
	[ "$(value "$TMP/tl-after" held)" = 0 ] || why "the engine still holds $(value "$TMP/tl-after" held) connection(s)"
	err=$(iperf_error "$TMP/iperf-tcp-long.json")
	mbps=$(iperf_mbps "$TMP/iperf-tcp-long.json")
	[ -n "$mbps" ] && [ -z "$err" ] || why "iperf3 did not end cleanly: ${err:-no report}"
	report tcp-long "$LONG s of iperf3 -P 4: ${mbps:-?} Mbps; at the end $inv INVALID, none ESTABLISHED, the engine empty"
	section "$TMP/tl-after" conntrack | head -8 | sed 's/^/               | /'
}

# ---- next to the features of the firmware (ticket 09 of .scratch/hw-accel-ls1088)

# ACTION (route or neigh), SERVER, WAN_PORT, STALL and WAIT come from the
# caller. Under traffic to SERVER that the engine carries, the way to SERVER
# changes on the board: "route" sends it into a blackhole (a route of its
# own), "neigh" gives its neighbour entry a MAC address nobody has. "gone="
# is how long until the engine holds no TCP connection, in ms, "stalled="
# what the cable side of WAN_PORT sent in the STALL seconds after; then the
# change is undone (also when the session is cut short) and "back=" is how
# long until as many TCP connections as before forward packets in the
# engine again ("busy": the streams of iperf3), or "never" within WAIT
# seconds.
reroute_script() { cat <<'EOF'
# hwaccel:reroute
held() { bmchwaccel-ctl list 2>/dev/null | grep -c '^conn tcp'; }
# those that forwarded a packet within the last second: the streams of iperf3, not its quiet control connection
busy() { bmchwaccel-ctl active 1000 2>/dev/null | grep -c '^conn tcp'; }
wire_tx() { bmchwaccel-ctl ports 2>/dev/null | sed -n "s/^port $WAN_PORT .* tx_packets=\([0-9]*\).*/\1/p"; }
ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }
mac_of() { ip -4 neigh show "$SERVER" dev "$WAN_PORT" 2>/dev/null | sed -n 's/.* lladdr \([0-9a-f:]*\).*/\1/p' | head -1; }
undo() {
	ip route del blackhole "$SERVER/32" 2>/dev/null
	if [ "$ACTION" = neigh ]; then
		# learned anew: the address of SERVER
		ip neigh del "$SERVER" dev "$WAN_PORT" 2>/dev/null
		ping -c 1 -W 1 "$SERVER" >/dev/null 2>&1
	fi
}
trap undo HUP INT TERM
echo "mac=$(mac_of)"
echo "held_before=$(held)"
before=$(busy)
echo "busy_before=$before"
start=$(ms)
case "$ACTION" in
route) ip route add blackhole "$SERVER/32" ;;
neigh) ip neigh replace "$SERVER" lladdr 02:00:00:00:00:99 dev "$WAN_PORT" nud permanent ;;
esac
while [ "$(held)" != 0 ] && [ $(($(ms) - start)) -lt 5000 ]; do sleep 0.05; done
if [ "$(held)" = 0 ]; then echo "gone=$(($(ms) - start))"; else echo "gone=never"; fi
t0=$(wire_tx)
sleep "$STALL"
t1=$(wire_tx)
echo "stalled=$((${t1:-0} - ${t0:-0}))"
echo "held_stalled=$(held)"
undo
trap - HUP INT TERM
start=$(ms)
# every one of them: a bind refused while the way was wrong is tried again
# less and less often
while [ "$(busy)" -lt "$before" ] && [ $(($(ms) - start)) -lt $((WAIT * 1000)) ]; do sleep 0.2; done
if [ "$(busy)" -ge "$before" ]; then echo "back=$(($(ms) - start))"; else echo "back=never"; fi
echo "held_back=$(busy)"
echo "mac_after=$(mac_of)"
echo "@log"
logread | grep bmchwaccel-syncd | tail -4
exit 0
EOF
}

reroute() { # action -> answer of the board
	board "ACTION=$1
SERVER='$server'
WAN_PORT='$WAN_PORT'
STALL=$STALL
WAIT=$REROUTE_WAIT
$(reroute_script)"
}

# One iperf3 -P 4 run PC1 -> PC2 through the engine while the way to PC2
# changes twice on the board: a blackhole route, then a neighbour entry with
# another MAC address. Each time the engine lets go of the connections within
# KEEP_MS, nothing of them leaves the cable of the wan port while the way is
# wrong (the blackhole), and once the way is right again they are
# accelerated again within REROUTE_WAIT seconds; iperf3 runs to its end.
item_reroute() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report reroute "not tested"; return; }
	board "$(flush_script)"
	"$IPERF3" -c "$server" -t "$((2 * WARMUP + WINDOW + 2 * (STALL + REROUTE_WAIT) + 10))" -P 4 -J -T reroute \
		> "$TMP/iperf-reroute.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	reroute route > "$TMP/reroute-route"
	reroute neigh > "$TMP/reroute-neigh"
	sleep "$WARMUP"
	board "ITEM=reroute
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/reroute-after"
	wait "$iperf_pid"
	iperf_pid=
	ways=
	for way in route neigh; do
		f=$TMP/reroute-$way
		[ "$(value "$f" held_before)" -gt 0 ] 2>/dev/null || why "$way: the engine held no TCP connection before"
		gone=$(value "$f" gone); back=$(value "$f" back)
		[ "$gone" != never ] && [ "${gone:-99999}" -le "$KEEP_MS" ] 2>/dev/null ||
			why "$way: the connections left the engine after ${gone:-?} ms, need at most $KEEP_MS"
		[ "$back" != never ] && [ -n "$back" ] ||
			why "$way: $(value "$f" held_back) of $(value "$f" busy_before) streams were accelerated again within $REROUTE_WAIT s once the way was right"
		ways="$ways; $way: out of the engine after ${gone:-?} ms, wan cable +$(value "$f" stalled) and $(value "$f" held_stalled) in the engine during the $STALL s, ${back:-?} ms to be back"
	done
	# nothing goes into a blackhole, so nothing can be learned of the way there
	[ "$(value "$TMP/reroute-route" held_stalled)" = 0 ] ||
		why "route: the engine held $(value "$TMP/reroute-route" held_stalled | grep . || echo an unknown number of) TCP connection(s) while PC2 was routed into a blackhole"
	stalled=$(value "$TMP/reroute-route" stalled)
	[ "${stalled:-99999}" -lt "$KERNEL_MAX" ] 2>/dev/null ||
		why "route: ${stalled:-?} packets left the cable of $WAN_PORT while PC2 was routed into a blackhole"
	[ "$(value "$TMP/reroute-neigh" mac_after)" = "$(value "$TMP/reroute-neigh" mac)" ] ||
		why "neigh: the board has $(value "$TMP/reroute-neigh" mac_after | grep . || echo nothing) for $server after the item, not $(value "$TMP/reroute-neigh" mac)"
	accel_judge "$TMP/reroute-after" "$ENGINE_LAN_PORT"
	err=$(iperf_error "$TMP/iperf-reroute.json")
	mbps=$(iperf_mbps "$TMP/iperf-reroute.json")
	[ -n "$mbps" ] && [ -z "$err" ] || why "iperf3 did not run to its end: ${err:-no report}"
	report reroute "iperf3 ${mbps:-?} Mbps${ways}; after: $accel_text"
	[ -z "$reasons" ] || section "$TMP/reroute-neigh" log | sed 's/^/               | /'
}

# bmcqos on wan (eth0) at QOS_MBPS both ways: status lists wan as kept on the
# CPU, iperf3 -P 4 stays at the limit (5 % over let through, at least 80 %)
# through the kernel with no TCP connection in the engine; bmcqos off again:
# nothing listed, and a new run is accelerated again.
item_qos_engine() { # qos | qos-back
	item=$1
	if [ "$item" = qos-back ]; then reverse=-R; in_port=$WAN_PORT; else reverse=; in_port=$ENGINE_LAN_PORT; fi
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report "$item" "not tested"; return; }
	# set before the board is touched, for cleanup
	shaping=1
	qos on > "$TMP/qos"
	qos_dev=$(value "$TMP/qos" dev)
	for way in up down; do
		case "$(value "$TMP/qos" $way)" in
		*cake*) ;;
		*) why "bmcqos did not shape what goes $way through ${qos_dev:-wan}: $(value "$TMP/qos" $way)" ;;
		esac
	done
	value "$TMP/qos" status | grep -q "\"device\":\"$qos_dev\",\"reason\":\"bmcqos\"" ||
		why "with bmcqos on, bmchwaccel status does not list wan ${qos_dev:-?} as kept on the CPU for bmcqos"
	for run in on off; do
		if [ $run = off ]; then
			qos off > "$TMP/qos-off"
			shaping=0
			! value "$TMP/qos-off" status | grep -q '"reason":"bmcqos"' ||
				why "with bmcqos off again, bmchwaccel status still lists it as keeping traffic on the CPU"
		fi
		board "$(flush_script)"
		# shellcheck disable=SC2086
		"$IPERF3" -c "$server" -t "$DURATION" -P 4 -J -T "$item-$run" $reverse > "$TMP/iperf-$item-$run.json" 2>/dev/null &
		iperf_pid=$!
		sleep "$WARMUP"
		board "ITEM=$item-$run
WINDOW=$WINDOW
$(accelsample_script)" > "$TMP/$item-$run"
		wait "$iperf_pid"
		iperf_pid=
	done
	mbps=$(iperf_mbps "$TMP/iperf-$item-on.json")
	if [ -z "$mbps" ]; then
		why "iperf3 with bmcqos on: $(iperf_error "$TMP/iperf-$item-on.json")"
	else
		[ "$mbps" -le $((QOS_MBPS * 105 / 100)) ] || why "$mbps Mbps is above the limit of $QOS_MBPS Mbps: the limit is not kept"
		[ "$mbps" -ge $((QOS_MBPS * 80 / 100)) ] || why "$mbps Mbps is below 80 percent of the limit of $QOS_MBPS Mbps"
	fi
	k=$(grown "$TMP/$item-on" "$in_port")
	[ "${k:-0}" -ge "$KERNEL_MAX" ] || why "only ${k:-no} packets of $in_port went through the kernel in $WINDOW s with bmcqos on"
	held=$(value "$TMP/$item-on" tcp_conns)
	[ "$held" = 0 ] || why "the engine held ${held:-?} TCP connection(s) with bmcqos on"
	accel_judge "$TMP/$item-off" "$in_port"
	off_mbps=$(iperf_mbps "$TMP/iperf-$item-off.json")
	report "$item" "bmcqos on wan ${qos_dev:-?} at $QOS_MBPS Mbps: ${mbps:-?} Mbps, kernel $in_port +${k:-?} in $WINDOW s, ${held:-?} in the engine; off: ${off_mbps:-?} Mbps, $accel_text"
}

# The block item of the LS1046 (macfilter, client_control, blocked services
# and bmcfido against a running flow, which bmchwaccel sweep takes out of the
# hardware) reads the packets of PC1's port that reached the CPU with the
# per-CPU counters of DPAA1 and what left the wan port with the kernel's
# total, which the hardware feeds there. Here the kernel's counters of eth1
# count only what reached the kernel, and what left the cable of eth0 is the
# engine's count; the daemon is bmchwaccel-syncd.
lib_bridge_script=$(bridge_script)
bridge_script() {
	# a library whose lines changed would leave the counters of the LS1046 here
	[ "$(printf '%s\n' "$lib_bridge_script" | grep -c -F -e 'rx() { ethtool -S ' \
		-e 'tx() { cat "/sys/class/net/$OUT/statistics/tx_packets"' -e 'pidof cmm')" = 5 ] || {
		echo "acceptance: bridge_script of scripts/hwaccel/acceptance.sh changed; adapt its counters here" >&2
		exit 2
	}
	printf '%s\n' "$lib_bridge_script" | sed \
		-e 's#^\([[:space:]]*\)rx() { ethtool -S .*#\1rx() { cat "/sys/class/net/$IN/statistics/rx_packets" 2>/dev/null; }#' \
		-e 's#^\([[:space:]]*\)tx() { cat "/sys/class/net/$OUT/statistics/tx_packets".*#\1tx() { bmchwaccel-ctl ports 2>/dev/null | sed -n "s/^port $OUT .* tx_packets=\\([0-9]*\\).*/\\1/p"; }#' \
		-e 's#pidof cmm#pidof bmchwaccel-syncd#'
}

bridge_daemon() { # file
	[ "$(value "$1" daemon)" != none ] || why "bmchwaccel-syncd is not running"
	status_check "$1" on
}

# ACTION (macfilter, whitelist, clientctl, fido or end), PC3, SERVER, RULE,
# WINDOW and SETTLE come from the caller. A feature blocks PC3, the other
# machine of br-lan, while the streams of iperf3 of PC1 (the SSH peer) to port
# 5201 of SERVER run through the engine; whitelist is macfilter in its
# whitelist mode with PC1 alone in the list. The kernel's and the cable's
# counters of eth1 are read for WINDOW s before the rule and for WINDOW s
# under it, SETTLE s after it; from the rule on, the streams of PC1 the engine
# holds are listed every 0.1 s: "lost=" those of before it let go of, even for
# a moment. "end" takes away what an earlier call left on the board.
blockother_script() { cat <<'EOF'
# hwaccel:blockother
S=/etc/bmcweb/backend/scripts/firewall
did=/tmp/hwaccel-blockother-did
orig=/tmp/hwaccel-blockother-macfilter
looks=/tmp/hwaccel-blockother-looks
pc1=${SSH_CONNECTION%% *}
lan=$(uci -q get network.lan.ipaddr)
wpid=
ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }
# The scripts of the features keep MAC addresses in upper case.
mac_of() { ip -4 neigh show "$1" 2>/dev/null | sed -n 's/.* lladdr \([0-9a-fA-F:]*\).*/\1/p' | head -1 | tr a-f A-F; }
# the source ports of the streams of PC1 to SERVER in a listing of the engine
streams() { awk -v a="$pc1" -v s="$SERVER" '$1 == "conn" && $2 == "tcp" && $3 == a && $5 == s && $6 == 5201 { printf " %s", $4 }'; }
held() { bmchwaccel-ctl list 2>/dev/null | streams; }
# what PC3 has open through the board, not with the board itself: the board
# answers, as it does the DNS that bmcfirewall turns towards it
pc3_conns() { conntrack -L -s "$PC3" 2>/dev/null | grep -v "src=$lan dst=$PC3 " | grep -c .; }
kernel_rx() { cat /sys/class/net/eth1/statistics/rx_packets 2>/dev/null; }
wire_rx() { bmchwaccel-ctl ports 2>/dev/null | sed -n 's/^port eth1 .* rx_packets=\([0-9]*\).*/\1/p'; }
grew() { if [ -n "$2" ] && [ -n "$3" ]; then echo "$1=$(($3 - $2))"; else echo "$1="; fi; }
undo() {
	[ -z "$wpid" ] || kill "$wpid" 2>/dev/null
	for f in $(cat $did 2>/dev/null); do
		case "$f" in
		macfilter:*)
			# disabled first: a whitelist without PC1 would have PC1 swept
			bash $S/macfilter.sh disable
			for idx in $(uci show macfilter | grep -i "\.mac='${f#macfilter:}'\$" | cut -d. -f2); do
				uci delete "macfilter.$idx"
			done
			status=
			[ ! -e $orig ] || { read -r status mode < $orig; uci set macfilter.settings.mode="$mode"; }
			uci commit macfilter
			[ "$status" != enable ] || bash $S/macfilter.sh enable
			rm -f $orig
			;;
		client:*) bash $S/client_control.sh del "${f#client:}" ;;
		fido)
			# Not fido any more: bmcfido takes its rules and sets away.
			/etc/init.d/bmcfido reload_rules
			bmchwaccel sweep
			;;
		esac >/dev/null 2>&1
	done
	rm -f $did
}
case "$ACTION" in
end)
	undo
	exit 0
	;;
esac
trap 'undo; exit 1' HUP INT TERM
undo
m1=$(mac_of "$pc1"); m3=$(mac_of "$PC3")
echo "pc1=$pc1"
echo "pc1_mac=$m1"
echo "pc3_mac=$m3"
[ -n "$m1" ] && [ -n "$m3" ] || exit 0
before=$(held)
echo "held_before=$before"
c0=$(kernel_rx); w0=$(wire_rx)
sleep "$WINDOW"
c1=$(kernel_rx); w1=$(wire_rx)
# read last: PC3 opens its connections again a while after an earlier call
echo "pc3_before=$(pc3_conns)"
grew kernel_before "$c0" "$c1"
grew wire_before "$w0" "$w1"
start=$(ms)
while :; do
	l=$(bmchwaccel-ctl list 2>/dev/null)
	# a listing the engine did not finish says nothing of what it holds
	case "$(printf '%s\n' "$l" | tail -1)" in ok*) echo "$(ms)$(printf '%s\n' "$l" | streams)" ;; esac
	sleep 0.1
done > $looks &
wpid=$!
case "$ACTION" in
macfilter)
	echo "$(uci -q get macfilter.settings.status) $(uci -q get macfilter.settings.mode)" > $orig
	echo "macfilter:$m3" >> $did
	bash $S/macfilter.sh enable >/dev/null 2>&1
	bash $S/macfilter.sh mode blacklist >/dev/null 2>&1
	said=$(bash $S/macfilter.sh add "$m3" 2>&1)
	rules=$(iptables -w -S MAC_FILTER 2>/dev/null | grep -c -i -- "--mac-source $m3 -j DROP")
	;;
whitelist)
	echo "$(uci -q get macfilter.settings.status) $(uci -q get macfilter.settings.mode)" > $orig
	echo "macfilter:$m1" >> $did
	# PC1 in the list before the mode is in force: one sweep, with PC1 allowed
	bash $S/macfilter.sh disable >/dev/null 2>&1
	uci set macfilter.settings.mode=whitelist
	uci set "macfilter.$(uci add macfilter rule).mac=$m1"
	uci commit macfilter
	said=$(bash $S/macfilter.sh enable 2>&1)
	rules=$(iptables -w -S MAC_FILTER 2>/dev/null | grep -c -i -e "--mac-source $m1 -j RETURN" -e "--ctdir ORIGINAL -j DROP")
	[ "$rules" = 2 ] && rules=1
	;;
clientctl)
	echo "client:$RULE" >> $did
	said=$(bash $S/client_control.sh set "$RULE" "$m3" 00:00 23:59 Mon,Tue,Wed,Thu,Fri,Sat,Sun 2>&1)
	rules=$(iptables -w -S CLIENTCTL 2>/dev/null | grep -c -i -- "--mac-source $m3 .*-j DROP")
	;;
fido)
	if [ "$(uci -q get system.@system[0].security_mode)" = fido ]; then
		said="the security mode is fido: the rules of bmcfido are in use"
		rules=0
	else
		echo fido >> $did
		# PC1 signed in before the rules are: the set is the one bmcfido makes
		ipset -exist create authorized_table hash:ip timeout 14400 comment
		for host in "$pc1" "$SERVER"; do ipset -exist add authorized_table "$host"; done
		uci set system.@system[0].security_mode=fido
		/etc/init.d/bmcfido reload_rules >/dev/null 2>&1
		uci revert system
		said=$(bmchwaccel sweep 2>&1)
		rules=$(iptables -w -S BMC_FIDO 2>/dev/null | grep -c -- "--match-set authorized_table src -j RETURN")
	fi
	;;
esac
echo "swept=$(($(ms) - start))"
echo "rules=$rules"
echo "said=$(echo "$said" | tr -d '\n' | tr -s ' ' | cut -c1-160)"
sleep "$SETTLE"
c2=$(kernel_rx); w2=$(wire_rx)
sleep "$WINDOW"
c3=$(kernel_rx); w3=$(wire_rx)
grew kernel_under "$c2" "$c3"
grew wire_under "$w2" "$w3"
kill "$wpid" 2>/dev/null
wait "$wpid" 2>/dev/null
wpid=
awk -v before="$before" -v start="$start" '
BEGIN { n = split(before, b, " ") }
{
	s = " " $0 " "
	for (i = 1; i <= n; i++)
		if (!index(s, " " b[i] " ")) {
			if (!(b[i] in gone)) { gone[b[i]] = 1; list = list " " b[i] }
			if (at == "") at = $1 - start
		}
}
END { print "lost=" list; print "lost_at=" at; print "looks=" NR }' $looks
rm -f $looks
echo "held_under=$(held)"
echo "pc3_under=$(pc3_conns)"
undo
trap - HUP INT TERM
echo "held_after=$(held)"
exit 0
EOF
}

blockother() { # action -> answer of the board
	board "ACTION=$1
PC3='$PC3'
SERVER='$server'
RULE='$FEATURE_RULE'
WINDOW=$WINDOW
SETTLE=$BRIDGE_SETTLE
$(blockother_script)"
}

# PC3, a second machine of br-lan, is blocked by each feature in turn while
# iperf3 -P 4 of PC1 runs through the engine: macfilter, macfilter in its
# whitelist mode with PC1 alone in the list, client_control and bmcfido. PC3
# loses what it had open through the board (bmchwaccel sweep); every stream
# of PC1 stays in the engine all along, the kernel sees fewer than KERNEL_MAX
# packets of eth1 in WINDOW s under the rule, and iperf3 never stops.
item_block_other() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report block-other "not tested"; return; }
	[ -n "$PC3" ] || { why "set PC3 to the address of the second machine of br-lan"; report block-other "not tested"; return; }
	blocking_other=1
	"$IPERF3" -c "$server" -t "$((WARMUP + 4 * (2 * WINDOW + BRIDGE_SETTLE + 6) + 10))" -P 4 -J -T block-other \
		> "$TMP/iperf-block-other.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	outcomes=
	for rule in macfilter whitelist clientctl fido; do
		blockother $rule > "$TMP/bo-$rule"
		f=$TMP/bo-$rule
		case $rule in
		macfilter) feature=macfilter ;;
		whitelist) feature="macfilter whitelist" ;;
		clientctl) feature=client_control ;;
		*) feature=bmcfido ;;
		esac
		[ -n "$(value "$f" pc3_mac)" ] || { why "$feature: the board has no MAC address for PC3 ($PC3)"; continue; }
		[ -n "$(value "$f" pc1_mac)" ] || { why "$feature: the board has no MAC address for PC1 ($(value "$f" pc1))"; continue; }
		if [ "$(value "$f" rules)" != 1 ]; then
			why "$feature: the board did not take the rule ($(value "$f" said | grep . || echo no answer))"
			continue
		fi
		set -- $(value "$f" held_before)
		held=$#
		[ "$held" -gt 0 ] || why "$feature: the engine held no stream of PC1 before the rule"
		set -- $(value "$f" lost)
		lost=$#
		[ "$lost" = 0 ] ||
			why "$feature: the engine let go of $lost of the $held streams of PC1, the first $(value "$f" lost_at) ms after the rule"
		[ "$(value "$f" looks)" -gt 0 ] 2>/dev/null || why "$feature: no listing of the engine under the rule"
		pc3_before=$(value "$f" pc3_before); pc3_under=$(value "$f" pc3_under)
		[ "${pc3_before:-0}" -gt 0 ] 2>/dev/null ||
			why "$feature: PC3 had nothing open through the board before the rule (have it ping $server all along)"
		[ "${pc3_under:-1}" = 0 ] || why "$feature: PC3 still had ${pc3_under:-an unknown number of} connection(s) through the board under the rule"
		k=$(value "$f" kernel_under); w=$(value "$f" wire_under)
		[ -n "$k" ] && [ "$k" -lt "$KERNEL_MAX" ] ||
			why "$feature: ${k:-an unknown number of} packets of $ENGINE_LAN_PORT went through the kernel in $WINDOW s under the rule, need fewer than $KERNEL_MAX"
		[ -n "$w" ] && [ "$w" -ge "$ENGINE_MIN" ] ||
			why "$feature: the cable side of $ENGINE_LAN_PORT counted ${w:-no} packets in $WINDOW s under the rule, need at least $ENGINE_MIN"
		outcomes="$outcomes; $feature: PC3 ${pc3_before:-?} -> ${pc3_under:-?} connection(s), PC1 $((held - lost))/$held streams in the engine all along ($(value "$f" looks) looks), kernel $ENGINE_LAN_PORT +$(value "$f" kernel_before) before, +${k:-?} under, cable +${w:-?}"
	done
	wait "$iperf_pid"
	iperf_pid=
	blocking_other=0
	err=$(iperf_error "$TMP/iperf-block-other.json")
	mbps=$(iperf_mbps "$TMP/iperf-block-other.json")
	[ -n "$mbps" ] && [ -z "$err" ] || why "iperf3 did not run to its end: ${err:-no report}"
	idle=$(iperf_idle "$TMP/iperf-block-other.json" 0)
	[ "${idle:-0}" = 0 ] || why "iperf3 carried less than 1 Mbps in $idle of its seconds"
	report block-other "PC3 $PC3 ($(value "$TMP/bo-macfilter" pc3_mac)) blocked, PC1 under iperf3 -P 4: ${mbps:-?} Mbps, ${idle:-?} s under 1 Mbps${outcomes}"
}

# ftp-server.py of this directory runs on PC2 (bench.md). PC1 downloads its
# file through the board in passive and in active mode: the FTP helper of the
# firewall (zone lan, port 21) follows the control connection and, in active
# mode, translates the address PC1 gives. Both downloads must be whole, the
# control connection must have the helper in conntrack, and the engine must
# hold no connection of PC2 while they run.
ftpsample_script() { cat <<'EOF'
# hwaccel:ftpsample
sleep 2
# /proc/net/nf_conntrack does not name the helper; conntrack does
echo "helper=$(conntrack -L -p tcp --dport "$FTP_PORT" 2>/dev/null | grep -c 'helper=ftp')"
echo "ct=$(grep -c "dst=$SERVER " /proc/net/nf_conntrack)"
echo "held=$(bmchwaccel-ctl list 2>/dev/null | grep -c " $SERVER ")"
echo "@conntrack"
grep "$SERVER" /proc/net/nf_conntrack | head -8
exit 0
EOF
}

item_ftp() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report ftp "not tested"; return; }
	text=
	for mode in passive active; do
		opt=; [ $mode = passive ] || opt='-P -'
		# shellcheck disable=SC2086
		curl -s $opt --limit-rate "$FTP_RATE" -o /dev/null -w '%{size_download} %{response_code}\n' \
			"ftp://$server:$FTP_PORT/$FTP_FILE" > "$TMP/ftp-$mode" 2>&1 &
		ftp_pid=$!
		board "SERVER='$server'
FTP_PORT=$FTP_PORT
$(ftpsample_script)" > "$TMP/ftp-$mode-board"
		wait "$ftp_pid"
		# shellcheck disable=SC2046
		set -- $(cat "$TMP/ftp-$mode")
		[ "${1:-0}" -ge $((FTP_MB << 20)) ] 2>/dev/null ||
			why "$mode: PC1 got ${1:-no} bytes of $((FTP_MB << 20)) (FTP answer ${2:-none}); is ftp-server.py running on $server (bench.md)?"
		[ "$(value "$TMP/ftp-$mode-board" helper)" -ge 1 ] 2>/dev/null ||
			why "$mode: conntrack has no control connection to port $FTP_PORT with the FTP helper"
		held=$(value "$TMP/ftp-$mode-board" held)
		[ "$held" = 0 ] || why "$mode: the engine held ${held:-?} connection(s) of $server during the download"
		text="$text; $mode: ${1:-?} bytes, $(value "$TMP/ftp-$mode-board" ct) connection(s) to $server in conntrack, ${held:-?} in the engine"
	done
	report ftp "${text#; }"
	[ -z "$reasons" ] || section "$TMP/ftp-active-board" conntrack | sed 's/^/               | /'
}

# TARGET, WINDOW and WAN_PORT come from the caller. Over WINDOW seconds of
# traffic through the tunnel: the load of every CPU ("cpu <cpu> <busy %>
# <softirq %>"), the packets of WAN_PORT the kernel saw, the packets the
# cables of the engine's ports took in, and the bytes the kernel's SAs
# counted; then what the engine holds of TARGET and its SAs.
ipsecaccel_script() { cat <<'EOF'
# hwaccel:ipsecaccel
cpus() { grep '^cpu[0-9]' /proc/stat; }
kern() { echo "$(cat "/sys/class/net/$WAN_PORT/statistics/rx_packets") $(cat "/sys/class/net/$WAN_PORT/statistics/tx_packets")"; }
wire() { bmchwaccel-ctl ports 2>/dev/null | awk '$1 == "port" { for (i = 3; i <= NF; i++) if ($i ~ /^rx_packets=/) n += substr($i, 12) } END { print n + 0 }'; }
bytes() { ip -s xfrm state 2>/dev/null | awk '/lifetime current:/ { getline; n += $1 } END { print n + 0 }'; }
cpus > /tmp/hwaccel-ipsec-a
k0=$(kern); w0=$(wire); b0=$(bytes)
sleep "$WINDOW"
cpus > /tmp/hwaccel-ipsec-b
k1=$(kern); w1=$(wire); b1=$(bytes)
awk 'NR == FNR { for (i = 2; i <= 9; i++) a[$1, i] = $i; next }
	{
		t = 0
		for (i = 2; i <= 9; i++) { d[i] = $i - a[$1, i]; t += d[i] }
		if (t > 0) printf "cpu %s %d %d\n", substr($1, 4), 100 * (t - d[5] - d[6]) / t + 0.5, 100 * d[8] / t + 0.5
	}' /tmp/hwaccel-ipsec-a /tmp/hwaccel-ipsec-b
rm -f /tmp/hwaccel-ipsec-a /tmp/hwaccel-ipsec-b
set -- $k0 $k1
echo "kernel=$(($3 + $4 - $1 - $2))"
echo "wire=$((w1 - w0))"
echo "sa_bytes=$((b1 - b0))"
echo "khz=$(cat /sys/devices/system/cpu/cpu1/cpufreq/cpuinfo_cur_freq 2>/dev/null || echo 1600000)"
echo "workers=$(/usr/lib/bmcHwAccelDpdk/layout workers 2>/dev/null)"
echo "held=$(bmchwaccel-ctl list 2>/dev/null | grep -c " $TARGET ")"
echo "installed=$(ipsec statusall 2>/dev/null | grep -c INSTALLED)"
echo "status=$(bmchwaccel status 2>&1 | head -1)"
echo "@sa"
bmchwaccel-ctl sa 2>/dev/null
echo "@ipsec"
ipsec status 2>/dev/null | head -6
exit 0
EOF
}

# A command on the IPsec peer (PEER_SSH).
peer() {
	ssh -o BatchMode=yes -o ConnectTimeout=5 ${PEER_KEY:+-i "$PEER_KEY"} \
		${PEER_KNOWN_HOSTS:+-o UserKnownHostsFile="$PEER_KNOWN_HOSTS"} "$PEER_SSH" "$@"
}

# The peer's counters of sequence number errors: "<XfrmInStateSeqError>
# <XfrmInNoStates>", or nothing without PEER_SSH or an answer.
peer_seq() {
	[ -n "$PEER_SSH" ] || return 0
	peer cat /proc/net/xfrm_stat 2>/dev/null |
		awk '$1 == "XfrmInStateSeqError" { s = $2 } $1 == "XfrmInNoStates" { n = $2 }
			END { if (s != "") print s, n }'
}

# iperf3 -P PARALLEL (4) to target, the board sampled in the middle -> mbps,
# the sample in $TMP/<name>; a reason when iperf3 gave no result. From the
# address ipsec_bind of PC1 when it is set.
ipsec_bind=
ipsec_run() { # name, target, iperf3 option (-R or nothing)
	# shellcheck disable=SC2086
	"$IPERF3" -c "$2" ${ipsec_bind:+-B "$ipsec_bind"} -t "$DURATION" -P "${PARALLEL:-4}" -J -T "$1" $3 \
		> "$TMP/iperf-$1.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "TARGET='$2'
WINDOW=$WINDOW
WAN_PORT=$WAN_PORT
$(ipsecaccel_script)" > "$TMP/$1"
	wait "$iperf_pid"
	iperf_pid=
	mbps=$(iperf_mbps "$TMP/iperf-$1.json")
	[ -n "$mbps" ] || why "$1: iperf3 to $2: $(iperf_error "$TMP/iperf-$1.json")"
}

# A sample of ipsec_run through the tunnel -> ipsec_text, with a reason for
# each thing the engine should have done and did not.
ipsec_judge() { # file
	k=$(value "$1" kernel)
	[ -n "$k" ] && [ "$k" -lt "$KERNEL_MAX" ] ||
		why "${k:-?} packets of $WAN_PORT went through the kernel in $WINDOW s, need fewer than $KERNEL_MAX"
	status_check "$1" on
	[ "$(value "$1" installed)" -ge 1 ] 2>/dev/null || why "strongSwan has no tunnel INSTALLED"
	sa=$(status_field "$1" ipsec_sa)
	[ "${sa:-0}" -ge 2 ] 2>/dev/null || why "bmchwaccel status has ipsec_sa ${sa:-none}, need at least 2"
	acc=$(status_field "$1" accelerated)
	[ "${acc:-0}" -gt 0 ] 2>/dev/null || why "bmchwaccel status counts ${acc:-no} accelerated connections"
	held=$(value "$1" held)
	[ "${held:-0}" -gt 0 ] 2>/dev/null || why "the engine holds no connection to $IPSEC_TARGET"
	b=$(value "$1" sa_bytes)
	[ "${b:-0}" -ge 1000000 ] 2>/dev/null ||
		why "the kernel's SAs counted ${b:-no} bytes in $WINDOW s: the engine's counts did not reach them"
	# the busy time of the workers (CPU 1 to workers) over what the cables took in
	cyc=$(awk -v w="$(value "$1" workers)" -v khz="$(value "$1" khz)" -v t="$WINDOW" \
		-v n="$(value "$1" wire)" '
		$1 == "cpu" && $2 >= 1 && $2 <= w { busy += $3; list = list sep $3; sep = "/" }
		END { printf "%s %d\n", list, (n > 0 ? busy / 100 * khz * 1000 * t / n : 0) }' "$1")
	ipsec_text="kernel $WAN_PORT +${k:-?} in $WINDOW s, ipsec_sa ${sa:-?}, ${acc:-?} accelerated, the SAs +${b:-?} bytes, workers busy ${cyc% *} %, ${cyc#* } cycles a packet"
}

# The connections of iperf3 through the tunnel, both ways (ticket 16).
item_ipsec_accel() {
	if [ -z "$IPSEC_TARGET" ]; then
		why "set IPSEC_TARGET to an address behind the tunnel (bench.md)"
		report ipsec-accel "not tested"
		return
	fi
	[ -n "$PEER_SSH" ] || why "set PEER_SSH to the peer's user@address, for its sequence number errors"
	seq0=$(peer_seq)
	[ -z "$PEER_SSH" ] || [ -n "$seq0" ] || why "no /proc/net/xfrm_stat from $PEER_SSH"
	# outside the tunnel: what the peer sends PC1 through the engine
	ipsec_run ipsec-direct-back "$SERVER" -R
	direct=$mbps
	ipsec_run ipsec-accel "$IPSEC_TARGET" ""
	out=$mbps
	ipsec_judge "$TMP/ipsec-accel"
	out_text=$ipsec_text
	[ -z "$out" ] || [ "$out" -ge "$IPSEC_MBPS" ] || why "$out Mbps to $IPSEC_TARGET, need $IPSEC_MBPS"
	ipsec_run ipsec-accel-back "$IPSEC_TARGET" -R
	back=$mbps
	ipsec_judge "$TMP/ipsec-accel-back"
	min=$((${direct:-0} * ACCEL_PCT / 100))
	[ -z "$back" ] || [ "$back" -ge "$min" ] ||
		why "$back Mbps back from $IPSEC_TARGET, need $min ($ACCEL_PCT % of ${direct:-?} Mbps from $SERVER outside the tunnel)"
	seq1=$(peer_seq)
	[ -z "$seq0" ] || [ "$seq0" = "$seq1" ] ||
		why "the peer's XfrmInStateSeqError and XfrmInNoStates went from $seq0 to ${seq1:-nothing}"
	failed=$reasons
	report ipsec-accel "to $IPSEC_TARGET ${out:-?} Mbps ($out_text); back ${back:-?} Mbps of ${direct:-?} outside the tunnel ($ipsec_text); the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
	[ -z "$failed" ] || section "$TMP/ipsec-accel" sa | sed 's/^/               | /'
}

# The ESP the engine numbers on several workers, as the peer gets it.
item_ipsec_reorder() {
	if [ -z "$IPSEC_TARGET" ] || [ -z "$PEER_SSH" ]; then
		why "set IPSEC_TARGET and PEER_SSH (bench.md)"
		report ipsec-reorder "not measured"
		return
	fi
	peer=${PEER_SSH#*@}
	peer "sudo timeout $((DURATION + 10)) tcpdump -i $PEER_IF -n -s 64 \
		-c $IPSEC_CAPTURE -w /tmp/hwaccel-esp.pcap 'udp port 4500 and dst host $peer and udp[8:4] != 0' \
		> /dev/null 2>&1" &
	cap_pid=$!
	sleep 2
	PARALLEL=8 ipsec_run ipsec-reorder "$IPSEC_TARGET" ""
	wait "$cap_pid"
	peer 'sudo cat /tmp/hwaccel-esp.pcap; sudo rm -f /tmp/hwaccel-esp.pcap' \
		> "$TMP/ipsec-reorder.pcap" 2>/dev/null
	# the numbers of ESP in UDP, in Ethernet or Linux cooked frames (v1, v2): how many
	# came after a higher one, and the most they were behind it
	# shellcheck disable=SC2046
	set -- $(python3 - "$TMP/ipsec-reorder.pcap" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
if len(d) < 24:
    sys.exit()
link = struct.unpack_from("<I", d, 20)[0]
off, n, late, most, top = 24, 0, 0, 0, None
while off + 16 <= len(d):
    caplen = struct.unpack_from("<I", d, off + 8)[0]
    f = d[off + 16:off + 16 + caplen]
    off += 16 + caplen
    l2 = {1: 14, 113: 16, 276: 20}.get(link, 14)
    if len(f) < l2 + 20:
        continue
    at = l2 + (f[l2] & 15) * 4 + 8 + 4
    if len(f) < at + 4:
        continue
    seq = struct.unpack_from("!I", f, at)[0]
    n += 1
    if top is not None and seq < top:
        late += 1
        most = max(most, top - seq)
    top = seq if top is None else max(top, seq)
print(n, late, most)
PY
)
	[ "${1:-0}" -gt 0 ] 2>/dev/null || why "the peer captured no ESP from the board"
	# what the run did, for the record: no reason of it counts here
	r=$reasons
	[ -z "$mbps" ] || ipsec_judge "$TMP/ipsec-reorder"
	reasons=$r
	report ipsec-reorder "iperf3 -P 8 ${mbps:-?} Mbps; of ${1:-0} packets of ESP at the peer, ${2:-?} came after a higher number, by at most ${3:-?}"
}

# ---- What a port sends at most (ticket 21)

# UCI tx_limit of the board as the list $1 ("PORT:MBPS ..."; nothing: none).
txlimit_set() {
	board "uci -q delete bmchwaccel.global.tx_limit
for l in $1; do uci add_list bmchwaccel.global.tx_limit=\$l; done
uci commit bmchwaccel" > /dev/null 2>&1
}

# The engine started again, detached (SSH goes through it), and on within
# 90 s; the lines it logged since about what TX_PORT sends (after a mark in
# syslog: the log is a ring), in $TMP/txl-<name>. The time it started, in
# seconds of the board's uptime, in txl_started.
txlimit_restart() { # name
	board "logger -t hwaccel-test 'tx-limit $1 $$'
setsid sh -c '/etc/init.d/bmchwaccel-engine restart; /etc/init.d/bmchwaccel-syncd restart; sleep 3; bmchwaccel apply' \\
	< /dev/null > /dev/null 2>&1 &" > /dev/null 2>&1
	txl_started=$(date +%s)
	sleep 10
	waited=10
	until board 'bmchwaccel status' 2>/dev/null | grep -q '"state":"on"'; do
		[ $waited -lt 90 ] || { why "$1: Tăng tốc phần cứng not on 90 s after the engine started again"; break; }
		sleep 2
		waited=$((waited + 2))
	done
	board "logread | awk '/hwaccel-test: tx-limit $1 $$\$/ { f = 1; next } f' | grep ' $TX_PORT sends ' |
	sed 's/.*: $TX_PORT/$TX_PORT/' | sort -u" > "$TMP/txl-$1" 2>/dev/null
}

# The line the engine logs for a limit of $1 Mbps on TX_PORT, as a pattern.
txlimit_line() {
	m=$(($1 / 8 * 8))
	if [ "$m" = "$1" ]; then
		echo "$TX_PORT sends at most $m Mbps ([0-9]* channels)"
	else
		echo "$TX_PORT sends at most $m Mbps ([0-9]* channels; $1 asked, in steps of 8)"
	fi
}

# One iperf3 flow (or -P N) to SERVER -> mbps.
txlimit_iperf() { # name [iperf3 option]
	# shellcheck disable=SC2086
	"$IPERF3" -c "$SERVER" -t "$DURATION" -J ${2:-} > "$TMP/iperf-txl-$1.json" 2>/dev/null
	mbps=$(iperf_mbps "$TMP/iperf-txl-$1.json")
}

# "FRAMES BAD" of the peer's interface with SERVER: what it got, and of it
# with a bad CRC; nothing when it cannot tell.
txlimit_crc() {
	peer "IF=\$(ip -o -4 addr | awk '\$4 ~ \"^$SERVER/\" { print \$2; exit }')
[ -n \"\$IF\" ] && ethtool -S \$IF | awk '/ rx_packets:/ { p = \$2 } / rx_crc_errors:/ { c = \$2 } END { if (p != \"\") print p + 0, c + 0 }'" 2>/dev/null
}

item_tx_limit() {
	TX_PORT=${TX_PORT:-$WAN_PORT}
	before=$(board 'uci -q get bmchwaccel.global.tx_limit' 2>/dev/null)
	# a limit to measure
	txlimit_set "$TX_PORT:$TX_TEST_MBPS"
	txlimit_restart test
	first=$txl_started
	grep -qx "$(txlimit_line "$TX_TEST_MBPS")" "$TMP/txl-test" ||
		why "the engine did not log the limit of $TX_TEST_MBPS Mbps: $(tr '\n' ' ' < "$TMP/txl-test")"
	txlimit_iperf test
	one=$mbps
	[ -n "$one" ] && [ "$one" -ge $((TX_TEST_MBPS * 85 / 100)) ] && [ "$one" -le $((TX_TEST_MBPS * 105 / 100)) ] ||
		why "one flow to $SERVER got ${one:-no} Mbps with $TX_TEST_MBPS, need 85 to 105 % of it"
	# none
	txlimit_set ""
	txlimit_restart none
	[ ! -s "$TMP/txl-none" ] || why "the engine logged a limit with none: $(tr '\n' ' ' < "$TMP/txl-none")"
	txlimit_iperf none
	free=$mbps
	[ -n "$free" ] && [ "$free" -ge "$TX_MIN" ] || why "one flow to $SERVER got ${free:-no} Mbps without a limit, need $TX_MIN"
	# the limit of the module behind TX_PORT, once the first start is 5 minutes away
	left=$((first + 310 - $(date +%s)))
	[ "$left" -le 0 ] || sleep "$left"
	txlimit_set "$TX_PORT:$TX_LIMIT_MBPS"
	txlimit_restart limit
	grep -qx "$(txlimit_line "$TX_LIMIT_MBPS")" "$TMP/txl-limit" ||
		why "the engine did not log the limit of $TX_LIMIT_MBPS Mbps: $(tr '\n' ' ' < "$TMP/txl-limit")"
	c0=
	[ -z "$PEER_SSH" ] || c0=$(txlimit_crc)
	txlimit_iperf limit "-P 4"
	four=$mbps
	[ -n "$four" ] && [ "$four" -ge "$TX_MIN" ] || why "iperf3 -P 4 to $SERVER got ${four:-no} Mbps, need $TX_MIN"
	crc= frames=
	if [ -n "$PEER_SSH" ]; then
		c1=$(txlimit_crc)
		if [ -n "$c0" ] && [ -n "$c1" ]; then
			frames=$((${c1% *} - ${c0% *})) crc=$((${c1#* } - ${c0#* }))
			[ "$frames" -gt 0 ] || why "the peer counted no frame from the board"
			[ "$crc" -eq 0 ] || why "the peer got $crc frames with a bad CRC of $frames"
		else
			why "no CRC counters from the peer's interface with $SERVER (ethtool -S over PEER_SSH)"
		fi
	fi
	# UCI as it was; the engine keeps the limit until it next starts
	txlimit_set "$before"
	report tx-limit "$TX_TEST_MBPS Mbps: one flow ${one:-?} Mbps; none: ${free:-?} Mbps; $TX_LIMIT_MBPS Mbps: -P 4 ${four:-?} Mbps${crc:+, $crc bad CRC at the peer of $frames frames}; tx_limit back to '${before}'"
}

# ---- Tunnel IPsec: the anti-replay window (ticket 23)

# The inbound SA of BOARD_CONN: its window in the kernel and whether the
# engine holds it.
item_ipsec_replay() {
	if [ -z "$IPSEC_TARGET" ]; then
		why "set IPSEC_TARGET (bench.md)"
		report ipsec-replay "not tested"
		return
	fi
	ipsec_state replay
	in=$(value "$TMP/is-replay" spis | tr ' ' '\n' | sed -n "s|^$BOARD_CONN:[0-9a-f]*/\([0-9a-f]*\)$|\1|p" | tail -1)
	win=
	if [ -z "$in" ]; then
		why "strongSwan has no CHILD_SA of $BOARD_CONN"
	else
		win=$(board "ip -d xfrm state | awk '/^src/ { s = 0 } /proto esp spi 0x$in / { s = 1 } s && /replay_window/ { sub(\",\", \"\", \$2); print \$2; exit }'" 2>/dev/null)
		[ "$win" = 128 ] || why "the kernel's SA 0x$in has the window ${win:-of 32 or none}, need 128"
		has_word "$in" "$(engine_spis replay)" || why "the engine does not hold the SA 0x$in"
		has_word "$in" "$(value "$TMP/is-replay" cli)" || why "bmchwaccel sa does not list the SA 0x$in"
	fi
	report ipsec-replay "inbound SA ${in:+0x$in} of $BOARD_CONN: window ${win:-?} in the kernel, held by the engine and listed by bmchwaccel sa"
}

# ---- Tunnel IPsec: rekey, back to the kernel, limits (ticket 17)

# TARGET comes from the caller: the engine's connections to TARGET
# ("held="), the SPIs of the CHILD_SAs strongSwan has, the outbound one then
# the inbound one of each, by the name of their conn ("spis=NAME:OUT/IN ..."),
# the packets of WAN_PORT the kernel got and sent ("kernel="), the state,
# the SPIs "bmchwaccel sa" lists ("cli=") and the SAs the engine holds (@sa).
ipsecstate_script() { cat <<'EOF'
# hwaccel:ipsecstate
echo "held=$(bmchwaccel-ctl list 2>/dev/null | grep -c " $TARGET ")"
echo "spis=$(ipsec statusall 2>/dev/null | sed -n 's/^ *\([^{ ]*\){[0-9]*}: .*SPIs: *\([0-9a-f]*\)_i *\([0-9a-f]*\)_o.*/\1:\3\/\2/p' | tr '\n' ' ')"
echo "installed=$(ipsec statusall 2>/dev/null | grep -c 'INSTALLED, TUNNEL')"
echo "kernel=$(($(cat /sys/class/net/$WAN_PORT/statistics/rx_packets) + $(cat /sys/class/net/$WAN_PORT/statistics/tx_packets)))"
echo "status=$(bmchwaccel status 2>&1 | head -1)"
echo "cli=$(bmchwaccel sa 2>/dev/null | grep -o '"spi":"0x[0-9a-f]*"' | sed 's/.*"0x\([0-9a-f]*\)"/\1/' | tr '\n' ' ')"
echo "@sa"
bmchwaccel-ctl sa 2>/dev/null
exit 0
EOF
}

# The state of the tunnel to TARGET (IPSEC_TARGET) in $TMP/is-<name>.
ipsec_state() { # name [target]
	board "TARGET='${2:-$IPSEC_TARGET}'
WAN_PORT=$WAN_PORT
$(ipsecstate_script)" > "$TMP/is-$1" 2>/dev/null
}

# The SPIs, as strongSwan writes them (8 hex digits), of the outbound SAs
# strongSwan has for the conn $2 (BOARD_CONN), and of those the engine holds,
# in $TMP/is-<name>.
kernel_out_spis() { # name [conn]
	value "$TMP/is-$1" spis | tr ' ' '\n' | sed -n "s|^${2:-$BOARD_CONN}:\([0-9a-f]*\)/.*|\1|p" | tr '\n' ' '
}
engine_out_spis() { # name
	section "$TMP/is-$1" sa | sed -n 's/^sa spi=0x\([0-9a-f]*\) dir=out .*/\1/p' | tr '\n' ' '
}
engine_spis() { # name
	section "$TMP/is-$1" sa | sed -n 's/^sa spi=0x\([0-9a-f]*\) .*/\1/p' | tr '\n' ' '
}

# Whether the word $1 is one of the words $2.
has_word() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# A script on the peer, as root (sudo sh), from stdin.
peer_sh() { peer sudo sh -s; }

# The CHILD_SA of PEER_CONN at the peer with the lifetime $1, rekeyed 30 s
# before its end (restore: as it was); then the tunnel made again, so that
# it has its new lifetime. /etc/ipsec.conf of the peer is kept once in
# /etc/ipsec.conf.t17.
peer_lifetime() { # lifetime | restore
	peer_sh > "$TMP/peer-lifetime" 2>&1 <<EOF
F=/etc/ipsec.conf
[ -f \$F.t17 ] || cp \$F \$F.t17
if [ "$1" = restore ]; then
	mv \$F.t17 \$F
else
	awk -v c="conn $PEER_CONN" -v l="$1" '\$0 == c { print; print "\tlifetime=" l; print "\tmargintime=30s"; print "\trekeyfuzz=0%"; next } { print }' \$F.t17 > \$F
fi
ipsec update
sleep 2
ipsec down $PEER_CONN
EOF
	tunnel_up
}

# The tunnel of the bench made again, by the board: the board's firewall
# may take IKE from wan only as the answer to its own (until ticket 03 of
# bmcwebUI keeps the rules of the VPN page).
tunnel_up() {
	board "ipsec up $BOARD_CONN" > "$TMP/tunnel-up" 2>&1
}

# Waits up to $2 seconds for the engine to hold the outbound SA of the
# tunnel strongSwan has now for the conn $4 (BOARD_CONN), and connections to
# TARGET when $3 is "held": 0 once it does, with the state in
# $TMP/is-<name>.
ipsec_until_held() { # name seconds [held [conn]]
	waited=0
	while [ "$waited" -le "$2" ]; do
		ipsec_state "$1"
		newest=$(kernel_out_spis "$1" "${4:-}" | awk '{ print $NF }')
		if [ -n "$newest" ] && has_word "$newest" "$(engine_out_spis "$1")" &&
			{ [ "${3:-}" != held ] || [ "$(value "$TMP/is-$1" held)" -gt 0 ] 2>/dev/null; }; then
			return 0
		fi
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

# What every ipsec item of this ticket needs.
ipsec_ready() { # item
	if [ -z "$IPSEC_TARGET" ] || [ -z "$PEER_SSH" ]; then
		why "set IPSEC_TARGET and PEER_SSH (bench.md)"
		report "$1" "not tested"
		return 1
	fi
	ipsec_until_held "$1-ready" 10 ||
		{ why "the engine does not hold the outbound SA of $BOARD_CONN ($(kernel_out_spis "$1-ready"))"; report "$1" "not tested"; return 1; }
}

# The iperf3 run in $TMP/iperf-<name>.json -> mbps, and idle (its seconds
# under 1 Mbps), with a reason when it did not run to its end or carried
# less than 1 Mbps in more than $2 of its seconds.
iperf_judge() { # name, seconds under 1 Mbps allowed
	mbps=$(iperf_mbps "$TMP/iperf-$1.json")
	err=$(iperf_error "$TMP/iperf-$1.json")
	[ -n "$mbps" ] && [ -z "$err" ] || why "iperf3 did not run to its end: ${err:-no report}"
	idle=$(iperf_idle "$TMP/iperf-$1.json" 0)
	[ "${idle:-99}" -le "$2" ] || why "iperf3 carried less than 1 Mbps in ${idle:-?} of its seconds, $2 allowed"
}

# iperf3 -J report -> the most seconds in a row under 1 Mbps.
iperf_gap() {
	awk '
	function num(o, key,   v) {
		if (!match(o, "\"" key "\":[ \t]*[0-9.eE+-]+")) return 0
		v = substr(o, RSTART, RLENGTH)
		sub(/.*:[ \t]*/, "", v)
		return v + 0
	}
	{ s = s $0 }
	END {
		while ((i = index(s, "\"sum\":")) > 0) {
			s = substr(s, i + 6)
			o = substr(s, 1, index(s, "}"))
			if (num(o, "bits_per_second") < 1000000) { run++; if (run > most) most = run } else run = 0
		}
		print most + 0
	}' "$1"
}

# A reason when the peer's sequence number errors (peer_seq) went from $1 to something else.
peer_seq_judge() { # before, after
	[ "$1" = "$2" ] || why "the peer's XfrmInStateSeqError and XfrmInNoStates went from ${1:-?} to ${2:-nothing}"
}

# Q9: a rekey every REKEY_LIFE - 30 s at the peer while iperf3 runs for
# REKEY_TIME through the tunnel: TCP never stands still, carries ACCEL_PCT %
# of a run of the same tunnel without a rekey; at least REKEY_MIN rekeys,
# and "bmchwaccel sa" has the new outbound and inbound SA of each within a
# sample (10 s); the engine holds the connections all along; the kernel
# sees fewer than KERNEL_MAX packets of WAN_PORT in 10 s; the peer has no
# sequence number error.
item_ipsec_rekey() {
	ipsec_ready ipsec-rekey || return
	peer_lifetime "$REKEY_LIFE"
	ipsec_until_held rekey-up 30 || why "the tunnel with the peer's lifetime $REKEY_LIFE was not held by the engine within 30 s"
	# the reference: a new CHILD_SA, no rekey before the end of it
	ipsec_run ipsec-rekey-ref "$IPSEC_TARGET" ""
	ref=$mbps
	seq0=$(peer_seq)
	"$IPERF3" -c "$IPSEC_TARGET" -t "$REKEY_TIME" -P 4 -J -T ipsec-rekey > "$TMP/iperf-ipsec-rekey.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	n=0
	end=$(($(date +%s) + REKEY_TIME - WARMUP - 5))
	while [ "$(date +%s)" -lt "$end" ]; do
		ipsec_state "rekey-$n"
		n=$((n + 1))
		sleep 10
	done
	wait "$iperf_pid"
	iperf_pid=
	seq1=$(peer_seq)
	peer_lifetime restore
	ipsec_until_held rekey-restored 30 || why "after the peer's lifetime was put back, the engine did not hold the tunnel again"
	iperf_judge ipsec-rekey 0
	min=$((${ref:-0} * ACCEL_PCT / 100))
	[ -z "$mbps" ] || [ "$mbps" -ge "$min" ] || why "$mbps Mbps over $REKEY_TIME s, need $min ($ACCEL_PCT % of ${ref:-?} Mbps without a rekey)"
	# each outbound SPI strongSwan had, held by the engine in that sample or the next
	spis= late= worst=0 prev=
	i=0
	while [ $i -lt $n ]; do
		f=rekey-$i
		next=rekey-$((i + 1))
		[ "$(value "$TMP/is-$f" held)" -gt 0 ] 2>/dev/null || why "sample $i: the engine held no connection to $IPSEC_TARGET"
		for pair in $(value "$TMP/is-$f" spis | tr ' ' '\n' | sed -n "s|^$BOARD_CONN:||p"); do
			o=${pair%/*}
			has_word "$o" "$spis" || spis="$spis $o"
			for s in "$o" "${pair#*/}"; do
				has_word "$s" "$(value "$TMP/is-$f" cli)" ||
					{ [ -f "$TMP/is-$next" ] && has_word "$s" "$(value "$TMP/is-$next" cli)"; } ||
					has_word "$s" "$late" || late="$late $s"
			done
		done
		k=$(value "$TMP/is-$f" kernel)
		[ -z "$prev" ] || [ -z "$k" ] || [ $((k - prev)) -le "$worst" ] || worst=$((k - prev))
		prev=$k
		i=$((i + 1))
	done
	rekeys=$(($(echo $spis | wc -w) - 1))
	[ "$rekeys" -ge "$REKEY_MIN" ] || why "strongSwan rekeyed $rekeys times in $REKEY_TIME s, need $REKEY_MIN (outbound SPIs:${spis:- none})"
	[ -z "$late" ] || why "bmchwaccel sa did not list the SA$late within a sample"
	[ "$worst" -lt "$KERNEL_MAX" ] || why "the kernel saw $worst packets of $WAN_PORT in one sample, need fewer than $KERNEL_MAX"
	peer_seq_judge "$seq0" "$seq1"
	report ipsec-rekey "$rekeys rekeys in $REKEY_TIME s (outbound SPIs$spis), both SAs of each in bmchwaccel sa; iperf3 ${mbps:-?} Mbps of ${ref:-?} without a rekey, ${idle:-?} s under 1 Mbps; kernel $WAN_PORT at most +$worst in a sample; the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
	iperf_timeline "$TMP/iperf-ipsec-rekey.json" | sed 's/^/               | /'
}

# Q10a: the engine killed (kill -9) under iperf3 through the tunnel: the
# tunnel goes on after the gap of any traffic (the supervisor starts the
# engine again, some 7 s: one gap of KILL_GAP s at most under 1 Mbps, and
# none other), strongSwan keeps its SPIs, and the engine, on again, holds
# the same SAs and the connections again.
item_ipsec_kill() {
	ipsec_ready ipsec-kill || return
	seq0=$(peer_seq)
	"$IPERF3" -c "$IPSEC_TARGET" -t "$KILL_TIME" -P 4 -J -T ipsec-kill > "$TMP/iperf-ipsec-kill.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	ipsec_state kill-before
	hwaccel ipsec-kill "" yes
	pid=$(value "$TMP/hw-ipsec-kill" engine)
	start=$(date +%s)
	hwaccel_until ipsec-kill-back "$DEATH_WAIT" engine_back ipsec-kill-back "$pid" ||
		why "the engine was not on again within $DEATH_WAIT s ($(hwaccel_text ipsec-kill-back))"
	back=$(($(date +%s) - start))
	ipsec_until_held kill-after "$DAEMON_WAIT" held || why "the engine did not hold the tunnel's SA and connections again within $DAEMON_WAIT s"
	again=$(($(date +%s) - start))
	wait "$iperf_pid"
	iperf_pid=
	seq1=$(peer_seq)
	[ "$(value "$TMP/is-kill-before" held)" -gt 0 ] 2>/dev/null || why "the engine held no connection to $IPSEC_TARGET before the kill"
	before=$(value "$TMP/is-kill-before" spis)
	after=$(value "$TMP/is-kill-after" spis)
	[ -n "$before" ] && [ "$before" = "$after" ] || why "strongSwan's SPIs went from ${before:-none} to ${after:-none}"
	iperf_judge ipsec-kill "$KILL_GAP"
	gap=$(iperf_gap "$TMP/iperf-ipsec-kill.json")
	[ "${gap:-99}" -le "$KILL_GAP" ] && [ "${gap:-0}" = "${idle:-?}" ] ||
		why "iperf3 stood still ${gap:-?} s at most in a row, ${idle:-?} s in all: need one gap of at most $KILL_GAP s"
	peer_seq_judge "$seq0" "$seq1"
	report ipsec-kill "engine $pid killed: on again after $back s, the tunnel's SA and connections held again after $again s; strongSwan's SPIs ${before:-?} kept; iperf3 ${mbps:-?} Mbps, one gap of ${gap:-?} s under 1 Mbps; the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
	iperf_timeline "$TMP/iperf-ipsec-kill.json" | sed 's/^/               | /'
}

# Q10b: disable under iperf3 through the tunnel, then enable: TCP never
# stands still, disabled the engine holds neither SA nor connection
# (ipsec_sa 0), strongSwan keeps its SPIs, enabled the engine holds them
# again; the peer has no sequence number error.
item_ipsec_disable() {
	ipsec_ready ipsec-disable || return
	seq0=$(peer_seq)
	"$IPERF3" -c "$IPSEC_TARGET" -t "$ONOFF_TIME" -P 4 -J -T ipsec-disable > "$TMP/iperf-ipsec-disable.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	ipsec_state dis-before
	hwaccel ipsec-dis-off disable
	sleep 3
	ipsec_state dis-off
	hwaccel ipsec-dis-on enable
	ipsec_until_held dis-on "$DAEMON_WAIT" held || why "enabled, the engine did not hold the tunnel's SA and connections again within $DAEMON_WAIT s"
	wait "$iperf_pid"
	iperf_pid=
	seq1=$(peer_seq)
	hwaccel_check ipsec-dis-off off true engine
	sa=$(status_field "$TMP/is-dis-off" ipsec_sa)
	[ "$sa" = 0 ] || why "disabled, bmchwaccel status has ipsec_sa ${sa:-none}, need 0"
	[ "$(value "$TMP/is-dis-off" held)" = 0 ] || why "disabled, the engine still held $(value "$TMP/is-dis-off" held) connections"
	hwaccel_check ipsec-dis-on on false engine
	before=$(value "$TMP/is-dis-before" spis)
	for s in dis-off dis-on; do
		[ "$(value "$TMP/is-$s" spis)" = "$before" ] || why "$s: strongSwan's SPIs went from ${before:-none} to $(value "$TMP/is-$s" spis)"
	done
	iperf_judge ipsec-disable 0
	peer_seq_judge "$seq0" "$seq1"
	report ipsec-disable "disabled $WARMUP s into iperf3: $(hwaccel_text ipsec-dis-off), ipsec_sa ${sa:-?}; enabled: $(hwaccel_text ipsec-dis-on), the tunnel held again; strongSwan's SPIs ${before:-?} kept; iperf3 ${mbps:-?} Mbps, ${idle:-?} s under 1 Mbps; the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
	iperf_timeline "$TMP/iperf-ipsec-disable.json" | sed 's/^/               | /'
}

# The daemon killed: the ms until the engine holds no connection
# ("conns_gone=") and no SA ("sas_gone="), "never" after 5 s; then the
# packets of WAN_PORT the kernel got and sent in the next second, before
# the supervisor starts the daemon again ("kernel_gap=").
syncdkill_script() { cat <<'EOF'
# hwaccel:syncdkill
ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }
pid=$(pidof bmchwaccel-syncd)
echo "pid=$pid"
[ -n "$pid" ] || exit 0
start=$(ms)
kill -9 $pid
c= s=
while [ -z "$c" ] || [ -z "$s" ]; do
	t=$(($(ms) - start))
	[ $t -lt 5000 ] || break
	[ -n "$c" ] || [ "$(bmchwaccel-ctl count 2>/dev/null)" != "ok 0" ] || c=$t
	[ -n "$s" ] || [ "$(bmchwaccel-ctl sa 2>/dev/null | tail -1)" != "ok 0" ] || s=$t
	sleep 0.05
done
echo "conns_gone=${c:-never}"
echo "sas_gone=${s:-never}"
kern() { echo $(($(cat "/sys/class/net/$WAN_PORT/statistics/rx_packets") + $(cat "/sys/class/net/$WAN_PORT/statistics/tx_packets"))); }
k0=$(kern)
sleep 1
echo "kernel_gap=$(($(kern) - k0))"
exit 0
EOF
}

# Q10c: the daemon killed (kill -9) under iperf3 through the tunnel: the
# engine lets go of every connection and SA at once, the tunnel goes on
# through the kernel with the same SPIs, the supervisor starts the daemon
# again and the engine holds the tunnel again.
item_ipsec_syncd() {
	ipsec_ready ipsec-syncd || return
	seq0=$(peer_seq)
	"$IPERF3" -c "$IPSEC_TARGET" -t "$KILL_TIME" -P 4 -J -T ipsec-syncd > "$TMP/iperf-ipsec-syncd.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	ipsec_state syncd-before
	board "WAN_PORT=$WAN_PORT
$(syncdkill_script)" > "$TMP/syncd-kill"
	ipsec_until_held syncd-after "$DAEMON_WAIT" held || why "the engine did not hold the tunnel's SA and connections again within $DAEMON_WAIT s"
	wait "$iperf_pid"
	iperf_pid=
	seq1=$(peer_seq)
	pid=$(value "$TMP/syncd-kill" pid)
	[ -n "$pid" ] || why "no daemon ran"
	for w in conns sas; do
		g=$(value "$TMP/syncd-kill" ${w}_gone)
		[ -n "$g" ] && [ "$g" != never ] || why "the engine still held $w 5 s after the daemon died"
	done
	gap=$(value "$TMP/syncd-kill" kernel_gap)
	[ "${gap:-0}" -ge "$KERNEL_MAX" ] 2>/dev/null ||
		why "the kernel saw ${gap:-no} packets of $WAN_PORT in the second after the engine let go: the tunnel did not go through it"
	before=$(value "$TMP/is-syncd-before" spis)
	after=$(value "$TMP/is-syncd-after" spis)
	[ -n "$before" ] && [ "$before" = "$after" ] || why "strongSwan's SPIs went from ${before:-none} to ${after:-none}"
	iperf_judge ipsec-syncd 1
	peer_seq_judge "$seq0" "$seq1"
	report ipsec-syncd "daemon $pid killed: the engine let go of the connections after $(value "$TMP/syncd-kill" conns_gone) ms and of the SAs after $(value "$TMP/syncd-kill" sas_gone) ms, kernel $WAN_PORT +${gap:-?} in the next second; held again; strongSwan's SPIs ${before:-?} kept; iperf3 ${mbps:-?} Mbps, ${idle:-?} s under 1 Mbps; the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
}

# Q12: the kernel's outbound SA of the tunnel set LIMIT_LEFT numbers before
# where the daemon lets go of it (SA_SEQ_LEAVE of sa.h, 2^32 - 2^26 - 2^22)
# while Tăng tốc phần cứng is disabled, then enabled: the engine starts it
# there, iperf3 runs through the tunnel; the daemon lets go of the SA (in
# order: the kernel's oseq 2^24 past the engine's last number), the tunnel
# goes on through the kernel with the same SPIs, TCP never stands still.
# Then the peer makes the tunnel again. XFRMAE: the xfrmae tool of the
# board (ticket 13), which writes the kernel's oseq.
item_ipsec_limit() {
	ipsec_ready ipsec-limit || return
	[ -n "$XFRMAE" ] && [ -f "$XFRMAE" ] ||
		{ why "set XFRMAE to the xfrmae tool for the board (bench.md)"; report ipsec-limit "not tested"; return; }
	board "cat > /tmp/xfrmae && chmod 755 /tmp/xfrmae" < "$XFRMAE"
	ipsec_state limit-before
	spi=$(kernel_out_spis limit-before | awk '{ print $NF }')
	line=$(section "$TMP/is-limit-before" sa | grep "^sa spi=0x$spi dir=out ")
	src=$(echo "$line" | sed -n 's/.* src=\([0-9.]*\) .*/\1/p')
	dst=$(echo "$line" | sed -n 's/.* dst=\([0-9.]*\) .*/\1/p')
	leave=$(((1 << 32) - (1 << 26) - (1 << 22)))
	hwaccel ipsec-limit-off disable
	board "/tmp/xfrmae set $src $dst 0x$spi oseq $((leave - (1 << 24) - LIMIT_LEFT))" > "$TMP/limit-set" 2>&1 ||
		why "the kernel's oseq could not be set: $(cat "$TMP/limit-set")"
	hwaccel ipsec-limit-on enable
	ipsec_until_held limit-on "$DAEMON_WAIT" || why "enabled, the engine did not hold the tunnel's outbound SA within $DAEMON_WAIT s"
	first=$(section "$TMP/is-limit-on" sa | sed -n "s/^sa spi=0x$spi dir=out .* seq=\([0-9]*\) .*/\1/p")
	seq0=$(peer_seq)
	"$IPERF3" -c "$IPSEC_TARGET" -t "$DURATION" -P 4 -J -T ipsec-limit > "$TMP/iperf-ipsec-limit.json" 2>/dev/null &
	iperf_pid=$!
	wait "$iperf_pid"
	iperf_pid=
	seq1=$(peer_seq)
	ipsec_state limit-after
	board "/tmp/xfrmae get $src $dst 0x$spi; logread | grep -c 'key 0x$spi, out) goes through the kernel again: its sequence numbers near their end'" > "$TMP/limit-after" 2>&1
	oseq=$(sed -n 's/.* oseq=\([0-9]*\) .*/\1/p' "$TMP/limit-after" | head -1)
	[ "${first:-0}" -ge $((leave - LIMIT_LEFT - 1)) ] 2>/dev/null && [ "$first" -lt "$leave" ] ||
		why "the engine held the SA from ${first:-nothing}, need $((leave - LIMIT_LEFT - 1)) up to $leave"
	! has_word "$spi" "$(engine_out_spis limit-after)" || why "the engine still holds 0x$spi"
	[ "$(tail -1 "$TMP/limit-after")" -ge 1 ] 2>/dev/null || why "syslog does not say that 0x$spi went back to the kernel for its numbers"
	[ "${oseq:-0}" -ge $((leave + (1 << 24))) ] 2>/dev/null && [ "$oseq" -lt $((1 << 32)) ] ||
		why "the kernel's oseq is ${oseq:-unknown}, need $((leave + (1 << 24))) at least"
	has_word "$spi" "$(kernel_out_spis limit-after)" || why "strongSwan no longer has 0x$spi: the tunnel was made again"
	iperf_judge ipsec-limit 0
	peer_seq_judge "$seq0" "$seq1"
	report ipsec-limit "0x$spi from $first, $LIMIT_LEFT numbers before the end: let go of, the kernel's oseq $oseq; iperf3 ${mbps:-?} Mbps, ${idle:-?} s under 1 Mbps; the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
	iperf_timeline "$TMP/iperf-ipsec-limit.json" | sed 's/^/               | /'
	# a tunnel with numbers of its own again
	peer "sudo ipsec down $PEER_CONN" > /dev/null 2>&1
	tunnel_up
	ipsec_until_held limit-restored 30 || echo "               (the engine did not hold the tunnel again after the peer made it again)"
}

# Tunnels besides BOARD_CONN and PEER_CONN, on the board and on the peer
# (add), or none (del): one conn "also=" the tunnel of the bench for each
# line "NAME N ESP" of stdin, with the peer's subnet 10.20.N.0/24 in place
# of the bench's and the ESP proposal ESP; the peer gets 10.20.N.10 on lo
# and an iperf3 server on 5300 + N, and starts them. Between "# hwaccel:t17"
# lines of /etc/ipsec.conf, which del removes, with their CHILD_SAs (add
# too: what a run cut short left).
tunnels_conf() { # side (board|peer), conn, add|del, auto (add|start), lines
	cat <<EOF
F=/etc/ipsec.conf
# the CHILD_SAs of the conns go first: ipsec update forgets a conn, not its SAs
while read -r name n esp; do
	ipsec down "\$name{*}" > /dev/null 2>&1
done <<LINES
$5
LINES
sed -i '/^# hwaccel:t17 begin\$/,/^# hwaccel:t17 end\$/d' \$F
side=\$(awk -v c="conn $2" '\$0 == c { on = 1; next } /^conn / { on = 0 }
	on && /subnet=10\\.20\\./ { sub(/^[ \\t]*/, ""); sub(/=.*/, ""); print; exit }' \$F)
if [ "$3" = add ]; then
	echo '# hwaccel:t17 begin' >> \$F
	while read -r name n esp; do
		printf 'conn %s\n\talso=%s\n\t%s=10.20.%s.0/24\n\tesp=%s\n\tauto=%s\n' "\$name" "$2" "\$side" "\$n" "\$esp" "$4" >> \$F
	done <<LINES
$5
LINES
	echo '# hwaccel:t17 end' >> \$F
fi
EOF
	[ "$1" = peer ] || { echo "ipsec update"; return; }
	cat <<EOF
while read -r name n esp; do
	if [ "$3" = add ]; then
		ip addr add 10.20.\$n.10/32 dev lo 2>/dev/null
		iperf3 -s -D -B 10.20.\$n.10 -p \$((5300 + n)) > /dev/null 2>&1
	else
		ip addr del 10.20.\$n.10/32 dev lo 2>/dev/null
		pkill -f "iperf3 -s -D -B 10.20.\$n.10 " 2>/dev/null
	fi
done <<LINES
$5
LINES
ipsec update
EOF
}

# ipsec update only tells the starter, which loads the conns afterwards: the
# peer starts its CHILD_SAs once the board has every conn (up to 120 s),
# since a CHILD_SA the board has no conn for is refused (TS_UNACCEPTABLE)
# and not tried again.
tunnels() { # add|del, lines "NAME N ESP"
	# on stdin: the script of 255 tunnels is longer than dropbear takes in a command
	tunnels_conf board "$BOARD_CONN" "$1" add "$2" | board "sh -s" > "$TMP/tunnels-board-$1" 2>&1 ||
		why "the board did not take the tunnels ($1): $(tail -2 "$TMP/tunnels-board-$1")"
	if [ "$1" = add ]; then
		want=$(echo "$2" | grep -c .)
		waited=0
		while [ "$waited" -lt 120 ]; do
			# a conn "also=" the bench's joins its peer: one "child:" line each
			have=$(board "ipsec statusall 2>/dev/null | grep -c '^ *t17-[0-9a-z]*: *child: '")
			[ "${have:-0}" -ge "$want" ] && break
			sleep 2
			waited=$((waited + 2))
		done
		[ "${have:-0}" -ge "$want" ] || why "the board loaded ${have:-no} of the $want conns in 120 s"
	fi
	tunnels_conf peer "$PEER_CONN" "$1" start "$2" | peer_sh > "$TMP/tunnels-peer-$1" 2>&1
}

# Waits up to $1 seconds for the board to have $2 tunnels INSTALLED, in $TMP/is-<$3>.
tunnels_until() { # seconds count name
	waited=0
	while [ "$waited" -le "$1" ]; do
		ipsec_state "$3"
		[ "$(value "$TMP/is-$3" installed)" -ge "$2" ] 2>/dev/null && return 0
		sleep 2
		waited=$((waited + 2))
	done
	return 1
}

# Q16: MANY tunnels to the peer (the bench's and MANY - 1 more, 10.20.1.0/24
# on): all INSTALLED, the engine holds two SAs of each (ipsec_sa), and
# iperf3 through three of them at once is accelerated: each connection held
# by the engine, the kernel sees fewer than KERNEL_MAX packets of WAN_PORT
# in WINDOW s.
item_ipsec_many() {
	ipsec_ready ipsec-many || return
	lines=$(n=1; while [ $n -lt "$MANY" ]; do echo "t17-$n $n aes256-sha256!"; n=$((n + 1)); done)
	tunnels add "$lines"
	tunnels_until "$MANY_WAIT" "$MANY" many-up || why "$(value "$TMP/is-many-up" installed) tunnels INSTALLED after $MANY_WAIT s, need $MANY"
	sleep 5
	ipsec_state many-up
	sa=$(status_field "$TMP/is-many-up" ipsec_sa)
	[ "$sa" = $((2 * MANY)) ] || why "bmchwaccel status has ipsec_sa ${sa:-none}, need $((2 * MANY))"
	last=$((MANY - 1))
	mid=$((MANY / 2))
	seq0=$(peer_seq)
	pids=
	for n in 1 $mid $last; do
		"$IPERF3" -c "10.20.$n.10" -p $((5300 + n)) -t "$DURATION" -P 2 -J -T "many-$n" > "$TMP/iperf-many-$n.json" 2>/dev/null &
		pids="$pids $!"
	done
	sleep "$WARMUP"
	board "TARGET='10.20.$mid.10'
WINDOW=$WINDOW
WAN_PORT=$WAN_PORT
$(ipsecaccel_script)" > "$TMP/ipsec-many"
	for n in 1 $mid $last; do ipsec_state "many-$n" "10.20.$n.10"; done
	# shellcheck disable=SC2086
	wait $pids
	seq1=$(peer_seq)
	text=
	for n in 1 $mid $last; do
		m=$(iperf_mbps "$TMP/iperf-many-$n.json")
		[ -n "$m" ] && [ "$m" -gt 0 ] || why "iperf3 to 10.20.$n.10: $(iperf_error "$TMP/iperf-many-$n.json")"
		h=$(value "$TMP/is-many-$n" held)
		[ "${h:-0}" -gt 0 ] 2>/dev/null || why "the engine held no connection to 10.20.$n.10"
		text="$text, 10.20.$n.10 ${m:-?} Mbps"
	done
	k=$(value "$TMP/ipsec-many" kernel)
	[ -n "$k" ] && [ "$k" -lt "$KERNEL_MAX" ] || why "${k:-?} packets of $WAN_PORT went through the kernel in $WINDOW s, need fewer than $KERNEL_MAX"
	peer_seq_judge "$seq0" "$seq1"
	tunnels del "$lines"
	tunnels_until 30 1 many-down
	report ipsec-many "$(value "$TMP/is-many-up" installed) tunnels INSTALLED, ipsec_sa ${sa:-?}; three at once:${text#,}, kernel $WAN_PORT +${k:-?} in $WINDOW s; the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
}

# Q4, Q12: a tunnel of AES-GCM-256 is accelerated; one of
# ChaCha20-Poly1305 and one with ESN go through the kernel, carry iperf3,
# and none of their SAs is held (ipsec_sa counts the bench's and GCM's).
item_ipsec_algo() {
	ipsec_ready ipsec-algo || return
	lines="t17-gcm 201 aes256gcm16!
t17-chacha 202 chacha20poly1305!
t17-esn 203 aes256-sha256-esn!"
	tunnels add "$lines"
	tunnels_until 30 4 algo-up || why "$(value "$TMP/is-algo-up" installed) tunnels INSTALLED after 30 s, need 4"
	sleep 3
	ipsec_state algo-up
	sa=$(status_field "$TMP/is-algo-up" ipsec_sa)
	[ "$sa" = 4 ] || why "bmchwaccel status has ipsec_sa ${sa:-none}, need 4 (the bench's tunnel and the GCM one)"
	text=
	for t in "gcm 201 held" "chacha 202 kernel" "esn 203 kernel"; do
		set -- $t
		spi=$(kernel_out_spis algo-up "t17-$1" | awk '{ print $NF }')
		[ -n "$spi" ] || { why "t17-$1 has no SA"; continue; }
		spi_in=$(value "$TMP/is-algo-up" spis | tr ' ' '\n' | sed -n "s|^t17-$1:$spi/\([0-9a-f]*\)\$|\1|p")
		"$IPERF3" -c "10.20.$2.10" -p $((5300 + $2)) -t 15 -P 2 -J -T "algo-$1" > "$TMP/iperf-algo-$1.json" 2>/dev/null &
		iperf_pid=$!
		sleep "$WARMUP"
		ipsec_state "algo-$1" "10.20.$2.10"
		wait "$iperf_pid"
		iperf_pid=
		m=$(iperf_mbps "$TMP/iperf-algo-$1.json")
		[ -n "$m" ] && [ "$m" -gt 0 ] || why "iperf3 through t17-$1: $(iperf_error "$TMP/iperf-algo-$1.json")"
		h=$(value "$TMP/is-algo-$1" held)
		if [ "$3" = held ]; then
			has_word "$spi" "$(engine_spis "algo-$1")" && has_word "$spi_in" "$(engine_spis "algo-$1")" ||
				why "the engine does not hold both SAs of t17-$1 ($spi, $spi_in)"
			[ "${h:-0}" -gt 0 ] 2>/dev/null || why "the engine held no connection through t17-$1"
		else
			! has_word "$spi" "$(engine_spis "algo-$1")" && ! has_word "$spi_in" "$(engine_spis "algo-$1")" ||
				why "the engine holds an SA of t17-$1"
			[ "${h:-1}" = 0 ] || why "the engine held a connection through t17-$1"
		fi
		text="$text, t17-$1 ${m:-?} Mbps (${h:-?} held)"
	done
	tunnels del "$lines"
	tunnels_until 30 1 algo-down
	report ipsec-algo "ipsec_sa ${sa:-?}:${text#,}"
}

# ACTION, WAN_PORT, MWAN_PORT, ISP_A, WINDOW and WAIT come from the caller,
# with Multi-WAN set up as the mwan items of the LS1046 do it (mwan setup):
#   rule   what left the cable of the wan port (the engine's count) and the
#          kernel's MWAN_PORT in WINDOW seconds, and the connections of the
#          engine to TARGET
#   lose   stops the pings that check wan, so that wan is Mất Internet while
#          its link and ISP A stay as they are, and waits for the Chuyển WAN
#          and for bmcMultiWAN to remove the connections of wan; then reads
#          the ports as rule does. "port unreachable" of an ISP is not passed
#          on, which would stop the sender.
#   back   lets the pings pass again and waits for the Chuyển WAN
#   end    takes the rules away
mwanwan_script() { cat <<'EOF'
# hwaccel:mwanwan
block() { iptables -w "$1" OUTPUT -o "$WAN_PORT" -p icmp -d "$ISP_A" -j DROP 2>/dev/null; }
quiet() {
	for d in "$WAN_PORT" "$MWAN_PORT"; do
		iptables -w -t mangle "$1" PREROUTING -i "$d" -p icmp --icmp-type destination-unreachable -j DROP 2>/dev/null
	done
}
mark="hwaccel-mwanwan-$$-$(cut -d' ' -f1 /proc/uptime)"
since() { logread | sed -n "/$mark/,\$p"; }
await() {
	i=0
	while [ $i -lt "$WAIT" ] && ! since | grep -q "bmcMultiWAN: Chuyển WAN: $1"; do
		sleep 1
		i=$((i + 1))
	done
	echo "waited=$i"
	echo "switch=$(since | grep "bmcMultiWAN: Chuyển WAN: $1" | tail -1 | sed 's/.*bmcMultiWAN: //')"
}
wire_tx() { bmchwaccel-ctl ports 2>/dev/null | sed -n "s/^port $WAN_PORT .* tx_packets=\([0-9]*\).*/\1/p"; }
ports() {
	echo "held_tcp=$(bmchwaccel-ctl list 2>/dev/null | grep -c "^conn tcp .* $TARGET ")"
	echo "held_udp=$(bmchwaccel-ctl list 2>/dev/null | grep -c "^conn udp .* $TARGET ")"
	w0=$(wire_tx); m0=$(cat "/sys/class/net/$MWAN_PORT/statistics/tx_packets")
	sleep "$WINDOW"
	w1=$(wire_tx); m1=$(cat "/sys/class/net/$MWAN_PORT/statistics/tx_packets")
	echo "wan_tx=$((${w1:-0} - ${w0:-0}))"
	echo "wan2_tx=$((m1 - m0))"
	echo "held_after=$(bmchwaccel-ctl list 2>/dev/null | grep -c " $TARGET ")"
}
case "$ACTION" in
rule) ports ;;
lose)
	echo "held_udp_before=$(bmchwaccel-ctl list 2>/dev/null | grep -c "^conn udp .* $TARGET ")"
	logger -t hwaccel "$mark"
	quiet -I
	block -I
	await 'wan is M'
	i=0
	while [ $i -lt 5 ] && ! since | grep -q 'connections through wan removed'; do sleep 1; i=$((i + 1)); done
	echo "removed=$(since | sed -n 's/.*Chuyển WAN: \([0-9]*\) connections through wan removed.*/\1/p' | tail -1)"
	sleep 1
	ports
	;;
back)
	logger -t hwaccel "$mark"
	while block -D; do :; done
	await 'wan has Internet again'
	while quiet -D; do :; done
	;;
end)
	while block -D; do :; done
	while quiet -D; do :; done
	;;
esac
exit 0
EOF
}

mwanwan() { # action, target -> answer of the board
	board "ACTION=$1
TARGET='$2'
WAN_PORT='$WAN_PORT'
MWAN_PORT='$MWAN_PORT'
ISP_A='$SERVER'
WINDOW=$WINDOW
WAIT=$MWAN_WAIT
$(mwanwan_script)"
}

# Multi-WAN with wan2 on the 1G port MWAN_PORT towards ISP B, set up as the
# mwan items of the LS1046 do it:
#   mwan-rule  the Luật chọn WAN sends what goes to MWAN_TARGET2 through
#              wan2: iperf3 -P 4 leaves through MWAN_PORT (the kernel's
#              count), not through the cable of the wan port, and is never
#              accelerated (a 1G port)
#   mwan-lost  under a UDP flow to MWAN_TARGET (MWAN_FLOW_PORT) that the
#              engine carries through wan, wan becomes Mất Internet: after
#              the Chuyển WAN bmcMultiWAN removed the connections of wan,
#              fewer than KERNEL_MAX packets leave the cable of the wan port
#              in WINDOW seconds and the flow leaves through wan2. wan gets
#              its pings back after.
item_mwan_engine() {
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report mwan "not tested"; return; }
	multiwan=1
	mwan setup > "$TMP/mwan-setup"
	refused=$(value "$TMP/mwan-setup" refused)
	if [ -n "$refused" ] || [ "$(value "$TMP/mwan-setup" wan2)" != "up online" ]; then
		why "Multi-WAN did not come up: ${refused:-wan $(value "$TMP/mwan-setup" wan), wan2 $(value "$TMP/mwan-setup" wan2)}"
		mwan end > /dev/null; multiwan=0
		report mwan "not tested"
		return
	fi
	board "$(flush_script)"
	"$IPERF3" -c "$MWAN_TARGET2" -t "$DURATION" -P 4 -J -T mwan-rule > "$TMP/iperf-mwan-rule.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	mwanwan rule "$MWAN_TARGET2" > "$TMP/mwan-rule"
	wait "$iperf_pid"; iperf_pid=
	mbps=$(iperf_mbps "$TMP/iperf-mwan-rule.json")
	[ -n "$mbps" ] || why "iperf3 to $MWAN_TARGET2: $(iperf_error "$TMP/iperf-mwan-rule.json")"
	w2=$(value "$TMP/mwan-rule" wan2_tx); w=$(value "$TMP/mwan-rule" wan_tx)
	[ "${w2:-0}" -ge "$KERNEL_MAX" ] || why "only ${w2:-no} packets left $MWAN_PORT (wan2) in $WINDOW s"
	[ "${w:-99999}" -lt "$KERNEL_MAX" ] || why "$w packets left the cable of $WAN_PORT (wan) in $WINDOW s"
	[ "$(value "$TMP/mwan-rule" held_tcp)" = 0 ] || why "the engine held a connection to $MWAN_TARGET2"
	report mwan-rule "to $MWAN_TARGET2: ${mbps:-?} Mbps, $MWAN_PORT +${w2:-?}, wan cable +${w:-?} in $WINDOW s, $(value "$TMP/mwan-rule" held_tcp) in the engine"

	"$IPERF3" -c "$MWAN_TARGET" -p "$MWAN_FLOW_PORT" -u -b "$UDP_LONG_RATE" -t "$((WARMUP + MWAN_WAIT + 2 * WINDOW + 20))" \
		-J -T mwan-lost > "$TMP/iperf-mwan-lost.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	losing_wan=1
	mwanwan lose "$MWAN_TARGET" > "$TMP/mwan-lost"
	mwanwan back "$MWAN_TARGET" > "$TMP/mwan-back"
	losing_wan=0
	kill "$iperf_pid" 2>/dev/null; wait "$iperf_pid" 2>/dev/null; iperf_pid=
	[ "$(value "$TMP/mwan-lost" held_udp_before)" -ge 1 ] 2>/dev/null || why "the engine held no UDP connection to $MWAN_TARGET before"
	[ -n "$(value "$TMP/mwan-lost" switch)" ] || why "no Chuyển WAN of wan within $MWAN_WAIT s"
	removed=$(value "$TMP/mwan-lost" removed)
	[ -n "$removed" ] || why "bmcMultiWAN did not remove the connections of wan"
	w=$(value "$TMP/mwan-lost" wan_tx); w2=$(value "$TMP/mwan-lost" wan2_tx)
	[ "${w:-99999}" -lt "$KERNEL_MAX" ] || why "$w packets left the cable of $WAN_PORT in $WINDOW s after the Chuyển WAN"
	[ "${w2:-0}" -ge "$KERNEL_MAX" ] || why "only ${w2:-no} packets left $MWAN_PORT (wan2) in $WINDOW s after the Chuyển WAN"
	[ -n "$(value "$TMP/mwan-back" switch)" ] || why "wan did not have Internet again within $MWAN_WAIT s"
	report mwan-lost "$(value "$TMP/mwan-lost" switch); ${removed:-no} connections removed; in $WINDOW s after: wan cable +${w:-?}, $MWAN_PORT +${w2:-?}; back: $(value "$TMP/mwan-back" switch)"
	mwan end > /dev/null
	multiwan=0
}

# ---- Tunnel IPsec next to the Feature BMC (ticket 18 of .scratch/hw-accel-ls1088)

# ACTION (clientctl, macfilter, fido or end), TARGET, WAN_PORT, RULE, QUIET
# and LOOK come from the caller. A feature blocks PC1 (the SSH peer: only
# what it forwards, its SSH to the board stays) while iperf3 of PC1 runs to
# TARGET through the tunnel, which the engine carries: the cable of WAN_PORT
# is read every 0.1 s for LOOK s from the rule on, and "stopped=" is the ms
# from the rule to the first look from which it sends fewer than QUIET
# packets in 0.5 s ("never" within LOOK s), "tail=" what it sent in the last
# 2 s of the looks; then the connections to TARGET the engine still holds.
# bmcfido does not sweep on its own when its rules change (cron and the
# firewall include do, within a minute): the fido case sweeps after its
# rules, as the VPN page's switch of the security mode would have to.
# "end" takes away what an earlier call left.
ipsecblock_script() { cat <<'EOF'
# hwaccel:ipsecblock
S=/etc/bmcweb/backend/scripts/firewall
did=/tmp/hwaccel-ipsecblock-did
orig=/tmp/hwaccel-ipsecblock-macfilter
looks=/tmp/hwaccel-ipsecblock-looks
pc1=${SSH_CONNECTION%% *}
ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }
mac_of() { ip -4 neigh show "$1" 2>/dev/null | sed -n 's/.* lladdr \([0-9a-fA-F:]*\).*/\1/p' | head -1 | tr a-f A-F; }
held() { bmchwaccel-ctl list 2>/dev/null | grep -c "^conn tcp .* $TARGET "; }
wire_tx() { bmchwaccel-ctl ports 2>/dev/null | sed -n "s/^port $WAN_PORT .* tx_packets=\([0-9]*\).*/\1/p"; }
undo() {
	for f in $(cat $did 2>/dev/null); do
		case "$f" in
		macfilter:*)
			bash $S/macfilter.sh disable
			for idx in $(uci show macfilter | grep -i "\.mac='${f#macfilter:}'\$" | cut -d. -f2); do
				uci delete "macfilter.$idx"
			done
			status=
			[ ! -e $orig ] || { read -r status mode < $orig; uci set macfilter.settings.mode="$mode"; }
			uci commit macfilter
			[ "$status" != enable ] || bash $S/macfilter.sh enable
			rm -f $orig
			;;
		client:*) bash $S/client_control.sh del "${f#client:}" ;;
		fido)
			/etc/init.d/bmcfido reload_rules
			bmchwaccel sweep
			;;
		esac >/dev/null 2>&1
	done
	rm -f $did $looks
}
case "$ACTION" in
end)
	undo
	exit 0
	;;
esac
trap 'undo; exit 1' HUP INT TERM
undo
m1=$(mac_of "$pc1")
echo "pc1=$pc1"
echo "pc1_mac=$m1"
[ -n "$m1" ] || exit 0
echo "held_before=$(held)"
t0=$(wire_tx)
sleep 1
t1=$(wire_tx)
echo "rate_before=$((${t1:-0} - ${t0:-0}))"
start=$(ms)
case "$ACTION" in
clientctl)
	echo "client:$RULE" >> $did
	said=$(bash $S/client_control.sh set "$RULE" "$m1" 00:00 23:59 Mon,Tue,Wed,Thu,Fri,Sat,Sun 2>&1)
	rules=$(iptables -w -S CLIENTCTL 2>/dev/null | grep -c -i -- "--mac-source $m1 .*-j DROP")
	;;
macfilter)
	echo "$(uci -q get macfilter.settings.status) $(uci -q get macfilter.settings.mode)" > $orig
	echo "macfilter:$m1" >> $did
	bash $S/macfilter.sh enable >/dev/null 2>&1
	bash $S/macfilter.sh mode blacklist >/dev/null 2>&1
	said=$(bash $S/macfilter.sh add "$m1" 2>&1)
	rules=$(iptables -w -S MAC_FILTER 2>/dev/null | grep -c -i -- "--mac-source $m1 -j DROP")
	;;
fido)
	if [ "$(uci -q get system.@system[0].security_mode)" = fido ]; then
		said="the security mode is fido: the rules of bmcfido are in use"
		rules=0
	else
		echo fido >> $did
		# PC1 not signed in: bmcfido drops what it forwards
		ipset -exist create authorized_table hash:ip timeout 14400 comment
		ipset -exist del authorized_table "$pc1"
		uci set system.@system[0].security_mode=fido
		/etc/init.d/bmcfido reload_rules >/dev/null 2>&1
		uci revert system
		said=$(bmchwaccel sweep 2>&1)
		rules=$(iptables -w -S BMC_FIDO 2>/dev/null | grep -c -- "-j DROP")
	fi
	;;
esac
end=$((start + LOOK * 1000))
while [ "$(ms)" -lt "$end" ]; do
	echo "$(ms) $(wire_tx)"
	sleep 0.1
done > $looks
echo "rules=$rules"
echo "said=$(echo "$said" | tr -d '\n' | tr -s ' ' | cut -c1-160)"
awk -v start="$start" -v quiet="$QUIET" '
{ t[NR] = $1; n[NR] = $2 }
END {
	for (i = 1; i <= NR; i++) {
		for (j = i; j <= NR && t[j] - t[i] < 500; j++) ;
		if (j > NR) break
		if (n[j] - n[i] < quiet) { stopped = t[i] - start; break }
	}
	print "stopped=" (stopped == "" ? "never" : stopped)
	for (k = 1; k < NR && t[NR] - t[k] > 2000; k++) ;
	print "tail=" (NR ? n[NR] - n[k] : "")
}' $looks
echo "looks=$(grep -c . $looks)"
echo "held_under=$(held)"
undo
trap - HUP INT TERM
exit 0
EOF
}

ipsecblock() { # action -> answer of the board
	board "ACTION=$1
TARGET='$IPSEC_TARGET'
WAN_PORT='$WAN_PORT'
RULE='$FEATURE_RULE'
QUIET=$SWEEP_QUIET
LOOK=$SWEEP_LOOK
$(ipsecblock_script)"
}

# User story 4: client_control, macfilter and bmcfido each block PC1 while
# iperf3 -P 4 of PC1 runs through the tunnel, which the engine carries: the
# traffic stops within SWEEP_MS (fewer than SWEEP_QUIET packets leave the
# cable of the wan port in 0.5 s), and the engine holds no connection to
# IPSEC_TARGET under the rule. The rule goes again after each, and the next
# feature starts from a tunnel the engine holds.
item_ipsec_sweep() {
	ipsec_ready ipsec-sweep || return
	ipsec_blocking=1
	outcomes=
	for rule in clientctl macfilter fido; do
		case $rule in
		clientctl) feature=client_control ;;
		macfilter) feature=macfilter ;;
		*) feature=bmcfido ;;
		esac
		ipsec_until_held "sweep-$rule" "$DAEMON_WAIT" || why "$feature: the engine did not hold the tunnel's outbound SA before the rule"
		"$IPERF3" -c "$IPSEC_TARGET" -t $((WARMUP + SWEEP_LOOK + 10)) -P 4 -J -T "sweep-$rule" \
			> "$TMP/iperf-sweep-$rule.json" 2>/dev/null &
		iperf_pid=$!
		sleep "$WARMUP"
		ipsecblock $rule > "$TMP/sw-$rule"
		kill "$iperf_pid" 2>/dev/null
		wait "$iperf_pid" 2>/dev/null
		iperf_pid=
		f=$TMP/sw-$rule
		[ -n "$(value "$f" pc1_mac)" ] || { why "$feature: the board has no MAC address for PC1 ($(value "$f" pc1))"; continue; }
		if [ "$(value "$f" rules)" -lt 1 ] 2>/dev/null || [ -z "$(value "$f" rules)" ]; then
			why "$feature: the board did not take the rule ($(value "$f" said | grep . || echo no answer))"
			continue
		fi
		[ "$(value "$f" held_before)" -gt 0 ] 2>/dev/null || why "$feature: the engine held no connection to $IPSEC_TARGET before the rule"
		rate=$(value "$f" rate_before)
		[ "${rate:-0}" -ge $((ENGINE_MIN / WINDOW)) ] 2>/dev/null ||
			why "$feature: only ${rate:-no} packets a second left the cable of $WAN_PORT before the rule"
		stopped=$(value "$f" stopped)
		[ "$stopped" != never ] && [ "${stopped:-99999}" -le "$SWEEP_MS" ] 2>/dev/null ||
			why "$feature: the traffic through the tunnel stopped ${stopped:-?} ms after the rule, need at most $SWEEP_MS"
		tail=$(value "$f" tail)
		[ "${tail:-99999}" -lt $((4 * SWEEP_QUIET)) ] 2>/dev/null ||
			why "$feature: ${tail:-?} packets left the cable of $WAN_PORT in the last 2 s under the rule: the traffic did not stay stopped"
		[ "$(value "$f" held_under)" = 0 ] ||
			why "$feature: the engine still held $(value "$f" held_under) connection(s) to $IPSEC_TARGET under the rule"
		outcomes="$outcomes; $feature: $(value "$f" held_before) held, $rate packets/s out of $WAN_PORT before, stopped after ${stopped:-?} ms (+${tail:-?} in the last 2 s), $(value "$f" held_under) held under it"
	done
	ipsec_blocking=0
	report ipsec-sweep "PC1 $(value "$TMP/sw-clientctl" pc1) blocked under iperf3 -P 4 through the tunnel${outcomes}"
}

# The anti-replay window of the peer's inbound SAs from the board (the
# largest one), or nothing.
peer_window() {
	peer sudo ip xfrm state 2>/dev/null | awk -v peer="$IPSEC_PEER" '
		/^src / { on = ($4 == peer) }
		on && match($0, /replay[-_]window [0-9]+/) { v = substr($0, RSTART, RLENGTH); sub(/.* /, "", v); if (v + 0 > w) w = v + 0 }
		END { if (w != "") print w }'
}

# The peer keeps an anti-replay window of IPSEC_PEER_WINDOW at least: the
# kernel of the board encrypts the tunnel's ESP on the job ring of the SEC,
# which finishes the jobs of one SA out of order, so what goes through the
# kernel leaves out of order (by up to 103 under bmcqos, ticket 18). Lower,
# strongSwan of the peer gets it (/etc/strongswan.d/hwaccel-replay.conf),
# starts again, and the board makes the tunnel again. 0 once the engine
# holds the tunnel with it.
peer_window_ensure() { # item
	w=$(peer_window)
	[ "${w:-0}" -lt "$IPSEC_PEER_WINDOW" ] 2>/dev/null || return 0
	printf 'charon {\n\treplay_window = %s\n}\n' "$IPSEC_PEER_WINDOW" |
		peer "sudo sh -c 'cat > /etc/strongswan.d/hwaccel-replay.conf && ipsec restart'" > /dev/null 2>&1
	sleep 3
	tunnel_up
	ipsec_until_held "$1-window" 60 || { why "the tunnel did not come back after the peer took a window of $IPSEC_PEER_WINDOW"; return 1; }
	w2=$(peer_window)
	[ "${w2:-0}" -ge "$IPSEC_PEER_WINDOW" ] 2>/dev/null ||
		{ why "the peer's window is ${w2:-unknown}, need $IPSEC_PEER_WINDOW (set replay_window of strongSwan there, bench.md)"; return 1; }
	echo "               (the peer's anti-replay window was ${w:-unknown}: now $w2)"
}

# Q15, user story 13: bmcqos shapes wan at QOS_MBPS. Tăng tốc phần cứng
# keeps wan on the CPU, so the daemon starts again and leaves the tunnel's
# SAs with the kernel: ipsec_sa 0, the tunnel INSTALLED with its SPIs, and
# iperf3 -P 4 through it stays under the limit (5 % over let through, at
# least IPSEC_QOS_PCT %: cake counts the outer packets) with no connection
# in the engine. bmcqos off again: the engine holds the tunnel again within
# DAEMON_WAIT s and a run through it is accelerated; the peer, with its
# window of IPSEC_PEER_WINDOW (peer_window_ensure), has no sequence number
# error.
item_ipsec_qos() {
	ipsec_ready ipsec-qos || return
	peer_window_ensure ipsec-qos || { report ipsec-qos "not tested"; return; }
	seq0=$(peer_seq)
	ipsec_state qos-before
	shaping=1
	qos on > "$TMP/iq-on"
	value "$TMP/iq-on" status | grep -q '"reason":"bmcqos"' ||
		why "with bmcqos on, bmchwaccel status does not list wan as kept on the CPU for bmcqos"
	waited=0
	while [ "$waited" -le "$DAEMON_WAIT" ]; do
		ipsec_state qos-on
		case "$(value "$TMP/is-qos-on" status)" in *'"state":"on"'*) break ;; esac
		sleep 1
		waited=$((waited + 1))
	done
	status_check "$TMP/is-qos-on" on "with bmcqos on"
	on_sa=$(status_field "$TMP/is-qos-on" ipsec_sa)
	[ "$on_sa" = 0 ] || why "with bmcqos on, bmchwaccel status has ipsec_sa ${on_sa:-none}, need 0"
	[ "$(value "$TMP/is-qos-on" installed)" -ge 1 ] 2>/dev/null || why "with bmcqos on, strongSwan has no tunnel INSTALLED"
	[ "$(value "$TMP/is-qos-on" spis)" = "$(value "$TMP/is-qos-before" spis)" ] ||
		why "strongSwan's SPIs went from $(value "$TMP/is-qos-before" spis) to $(value "$TMP/is-qos-on" spis)"
	"$IPERF3" -c "$IPSEC_TARGET" -t "$DURATION" -P 4 -J -T ipsec-qos > "$TMP/iperf-ipsec-qos.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	ipsec_state qos-run
	wait "$iperf_pid"
	iperf_pid=
	mbps=$(iperf_mbps "$TMP/iperf-ipsec-qos.json")
	if [ -z "$mbps" ]; then
		why "iperf3 with bmcqos on: $(iperf_error "$TMP/iperf-ipsec-qos.json")"
	else
		[ "$mbps" -le $((QOS_MBPS * 105 / 100)) ] || why "$mbps Mbps is above the limit of $QOS_MBPS Mbps: the limit is not kept"
		[ "$mbps" -ge $((QOS_MBPS * IPSEC_QOS_PCT / 100)) ] ||
			why "$mbps Mbps is below $IPSEC_QOS_PCT percent of the limit of $QOS_MBPS Mbps"
	fi
	on_mbps=$mbps
	on_held=$(value "$TMP/is-qos-run" held)
	[ "$on_held" = 0 ] || why "the engine held ${on_held:-?} connection(s) to $IPSEC_TARGET with bmcqos on"
	sa_run=$(status_field "$TMP/is-qos-run" ipsec_sa)
	[ "$sa_run" = 0 ] || why "under iperf3 with bmcqos on, ipsec_sa is ${sa_run:-none}, need 0"
	qos off > "$TMP/iq-off"
	shaping=0
	! value "$TMP/iq-off" status | grep -q '"reason":"bmcqos"' ||
		why "with bmcqos off again, bmchwaccel status still lists it as keeping traffic on the CPU"
	ipsec_until_held qos-off "$DAEMON_WAIT" || why "with bmcqos off again, the engine did not hold the tunnel's outbound SA within $DAEMON_WAIT s"
	ipsec_run ipsec-qos-off "$IPSEC_TARGET" ""
	ipsec_judge "$TMP/ipsec-qos-off"
	seq1=$(peer_seq)
	peer_seq_judge "$seq0" "$seq1"
	report ipsec-qos "bmcqos on wan at $QOS_MBPS Mbps: ipsec_sa ${on_sa:-?} (${sa_run:-?} under iperf3), iperf3 ${on_mbps:-?} Mbps, ${on_held:-?} in the engine; off: ${mbps:-?} Mbps ($ipsec_text); the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
}

# Q14, user story 14: under iperf3 -P 4 through the tunnel the way to the
# peer (IPSEC_PEER) changes on the board as reroute does it for PC2: a
# blackhole route, then a neighbour entry with a MAC address nobody has.
# Each time the engine lets go of the connections within KEEP_MS, nothing
# leaves the cable of the wan port into the blackhole, and once the way is
# right again they are accelerated again within REROUTE_WAIT s; iperf3 runs
# to its end. Then, under iperf3 again, the wan port goes down for LINK_DOWN
# s and up again: the engine lets go of the tunnel's connections while it
# is down, holds the outbound SA of the tunnel strongSwan has within
# LINK_WAIT s of it up again (the tunnel itself, nothing of the item makes
# it again), and a new run through it is accelerated.
item_ipsec_route() {
	ipsec_ready ipsec-route || return
	[ -n "$IPSEC_PEER" ] || { why "set IPSEC_PEER to the address of the tunnel's peer"; report ipsec-route "not tested"; return; }
	seq0=$(peer_seq)
	"$IPERF3" -c "$IPSEC_TARGET" -t "$((2 * WARMUP + 2 * (STALL + REROUTE_WAIT) + 10))" -P 4 -J -T ipsec-route \
		> "$TMP/iperf-ipsec-route.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	for way in route neigh; do
		board "ACTION=$way
SERVER='$IPSEC_PEER'
WAN_PORT='$WAN_PORT'
STALL=$STALL
WAIT=$REROUTE_WAIT
$(reroute_script)" > "$TMP/ir-$way"
	done
	wait "$iperf_pid"
	iperf_pid=
	ways=
	for way in route neigh; do
		f=$TMP/ir-$way
		[ "$(value "$f" held_before)" -gt 0 ] 2>/dev/null || why "$way: the engine held no TCP connection before"
		gone=$(value "$f" gone); back=$(value "$f" back)
		[ "$gone" != never ] && [ "${gone:-99999}" -le "$KEEP_MS" ] 2>/dev/null ||
			why "$way: the connections through the tunnel left the engine after ${gone:-?} ms, need at most $KEEP_MS"
		[ "$back" != never ] && [ -n "$back" ] ||
			why "$way: $(value "$f" held_back) of $(value "$f" busy_before) streams were accelerated again within $REROUTE_WAIT s once the way was right"
		ways="$ways; $way: out of the engine after ${gone:-?} ms, wan cable +$(value "$f" stalled) and $(value "$f" held_stalled) in the engine during the $STALL s, ${back:-?} ms to be back"
	done
	[ "$(value "$TMP/ir-route" held_stalled)" = 0 ] ||
		why "route: the engine held $(value "$TMP/ir-route" held_stalled) TCP connection(s) while the peer was routed into a blackhole"
	stalled=$(value "$TMP/ir-route" stalled)
	[ "${stalled:-99999}" -lt "$KERNEL_MAX" ] 2>/dev/null ||
		why "route: ${stalled:-?} packets left the cable of $WAN_PORT while the peer was routed into a blackhole"
	[ "$(value "$TMP/ir-neigh" mac_after)" = "$(value "$TMP/ir-neigh" mac)" ] ||
		why "neigh: the board has $(value "$TMP/ir-neigh" mac_after | grep . || echo nothing) for $IPSEC_PEER after the item, not $(value "$TMP/ir-neigh" mac)"
	iperf_judge ipsec-route "$((2 * STALL + 4))"
	route_mbps=$mbps
	# the wan port down and up, as netifd and the daemon see it
	"$IPERF3" -c "$IPSEC_TARGET" -t "$((WARMUP + LINK_DOWN + 10))" -P 4 -J -T ipsec-route-down \
		> "$TMP/iperf-ipsec-route-down.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	ipsec_link_down=1
	board "held() { bmchwaccel-ctl list 2>/dev/null | grep -c '^conn tcp .* $IPSEC_TARGET '; }
echo held_before=\$(held)
ip link set $WAN_PORT down
sleep 1
echo held_down=\$(held)
sleep $((LINK_DOWN > 1 ? LINK_DOWN - 1 : 0))
ip link set $WAN_PORT up" > "$TMP/ir-link" 2>&1
	ipsec_link_down=0
	start=$(date +%s)
	kill "$iperf_pid" 2>/dev/null
	wait "$iperf_pid" 2>/dev/null
	iperf_pid=
	[ "$(value "$TMP/ir-link" held_before)" -gt 0 ] 2>/dev/null ||
		why "link: the engine held no connection to $IPSEC_TARGET before $WAN_PORT went down"
	[ "$(value "$TMP/ir-link" held_down)" = 0 ] ||
		why "link: the engine still held $(value "$TMP/ir-link" held_down | grep . || echo an unknown number of) connection(s) to $IPSEC_TARGET 1 s after $WAN_PORT went down"
	ipsec_until_held link-up "$LINK_WAIT" ||
		why "the engine did not hold the outbound SA of the tunnel strongSwan has within $LINK_WAIT s of $WAN_PORT up again ($(kernel_out_spis link-up | grep . || echo none INSTALLED))"
	up=$(($(date +%s) - start))
	ipsec_run ipsec-route-link "$IPSEC_TARGET" ""
	ipsec_judge "$TMP/ipsec-route-link"
	seq1=$(peer_seq)
	peer_seq_judge "$seq0" "$seq1"
	report ipsec-route "iperf3 ${route_mbps:-?} Mbps${ways}; $WAN_PORT down $LINK_DOWN s: $(value "$TMP/ir-link" held_before) -> $(value "$TMP/ir-link" held_down) held, the tunnel held again after $up s, then ${mbps:-?} Mbps ($ipsec_text); the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
	[ -z "$reasons" ] || section "$TMP/ir-neigh" log | sed 's/^/               | /'
}

# A ping of PC1 to TARGET of SIZE bytes of data, with DF or without: 0 when
# an answer came.
ping_df() { # target, size, df|nodf
	case "$(uname -s)" in
	Darwin) if [ "$3" = df ]; then ping -c 2 -W 1000 -D -s "$2" "$1"; else ping -c 2 -W 1000 -s "$2" "$1"; fi ;;
	*) if [ "$3" = df ]; then ping -c 2 -W 1 -M do -s "$2" "$1"; else ping -c 2 -W 1 -M dont -s "$2" "$1"; fi ;;
	esac > /dev/null 2>&1
}

# Pings of PC1 through the tunnel -> mtu_text, with a reason for each that
# went wrong: with DF, IPSEC_PING_FIT bytes of data (the tunnel's MTU, 1422,
# less 28) answered and IPSEC_PING_FIT + 1 and more not (the kernel says the
# MTU instead); without DF every size of IPSEC_PING_SIZES answered (the
# kernel fragments the ESP, the engine numbers it again).
ipsec_pings() { # target
	mtu_text=
	if ping_df "$1" "$IPSEC_PING_FIT" df; then
		mtu_text="DF $IPSEC_PING_FIT answered"
	else
		why "a ping with DF of $IPSEC_PING_FIT bytes to $1 got no answer"
		mtu_text="DF $IPSEC_PING_FIT no answer"
	fi
	for s in $((IPSEC_PING_FIT + 1)) $IPSEC_PING_SIZES; do
		if ping_df "$1" "$s" df; then
			why "a ping with DF of $s bytes to $1 got an answer: it cannot fit the tunnel"
			mtu_text="$mtu_text, DF $s answered"
		fi
	done
	ok=
	for s in $IPSEC_PING_SIZES; do
		if ping_df "$1" "$s" nodf; then
			ok="$ok $s"
		else
			why "a ping without DF of $s bytes to $1 got no answer"
		fi
	done
	mtu_text="$mtu_text, larger with DF no answer; without DF answered:${ok:- none}"
}

# User story 16: large packets through the tunnel. Pings (ipsec_pings); UDP
# of IPSEC_UDP_LEN bytes a datagram at IPSEC_UDP_RATE for DURATION s each
# way, without DF: the receiver gets at least 99 % of it, and the router
# that puts it into the tunnel fragments the ESP (FragCreates of the
# kernel grows): the board on the way out, the peer on the way back. Back,
# the datagrams come from IPSEC_FAR, a network namespace on the peer that
# the item makes: the peer forwards them, as a router does (what the peer
# sends itself it fragments before ESP, to the tunnel's MTU). TCP with the
# MSS of PC1's cable (DF, the kernel tells PC1 the tunnel's MTU): iperf3
# runs to its end above IPSEC_TCP_MIN Mbps.
item_ipsec_mtu() {
	ipsec_ready ipsec-mtu || return
	seq0=$(peer_seq)
	ipsec_pings "$IPSEC_TARGET"
	text=
	far_made=1
	ipsec_far setup > "$TMP/mtu-far" 2>&1
	for dir in out back; do
		if [ $dir = out ]; then opt=; to=$IPSEC_TARGET; port=5201; at=board; else opt=-R; to=$IPSEC_FAR; port=$IPSEC_FAR_PORT; at=peer; fi
		f0=$(frag_creates $at)
		# shellcheck disable=SC2086
		"$IPERF3" -c "$to" -p "$port" -u -b "$IPSEC_UDP_RATE" -l "$IPSEC_UDP_LEN" -t "$DURATION" -J $opt \
			-T "mtu-udp-$dir" > "$TMP/iperf-mtu-udp-$dir.json" 2>/dev/null
		f1=$(frag_creates $at)
		got=$(udp_received "$TMP/iperf-mtu-udp-$dir.json")
		err=$(iperf_error "$TMP/iperf-mtu-udp-$dir.json")
		[ -z "$err" ] && [ -n "$got" ] || { why "UDP $dir to $to: iperf3 gave no result (${err:-no report})"; continue; }
		[ "${got%.*}" -ge 99 ] || why "UDP $dir: only $got % of the datagrams of $IPSEC_UDP_LEN bytes arrived"
		frags=$((${f1:-0} - ${f0:-0}))
		[ -n "$f0" ] && [ -n "$f1" ] && [ "$frags" -gt 0 ] ||
			why "UDP $dir: the $at fragmented nothing (FragCreates ${f0:-?} -> ${f1:-?}): no ESP in fragments"
		text="$text, UDP of $IPSEC_UDP_LEN bytes $dir $got % arrived, the $at made $frags fragments"
	done
	ipsec_far teardown > /dev/null 2>&1
	far_made=0
	"$IPERF3" -c "$IPSEC_TARGET" -t "$DURATION" -J -T mtu-tcp > "$TMP/iperf-mtu-tcp.json" 2>/dev/null
	iperf_judge mtu-tcp 0
	[ -z "$mbps" ] || [ "$mbps" -ge "$IPSEC_TCP_MIN" ] || why "TCP with DF: $mbps Mbps, need $IPSEC_TCP_MIN"
	seq1=$(peer_seq)
	peer_seq_judge "$seq0" "$seq1"
	report ipsec-mtu "$mtu_text$text, TCP with DF ${mbps:-?} Mbps; the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
}

# The fragments the kernel of the board or of the peer made since its boot (FragCreates).
frag_creates() { # board|peer
	if [ "$1" = board ]; then board 'cat /proc/net/snmp'; else peer cat /proc/net/snmp; fi 2>/dev/null |
		awk '$1 == "Ip:" { if (!n) { for (i = 2; i <= NF; i++) if ($i == "FragCreates") c = i; n = 1 } else print $c }'
}

# On the peer, as root: a network namespace with IPSEC_FAR, behind the peer
# on a veth pair (proxy ARP, a route of its own), and an iperf3 server in it
# on IPSEC_FAR_PORT (setup); all of it away again (teardown).
ipsec_far() { # setup|teardown
	peer_sh <<EOF
ip netns pids t18far 2>/dev/null | xargs -r kill 2>/dev/null
ip route del $IPSEC_FAR/32 table local 2>/dev/null
ip link del t18v0 2>/dev/null
ip netns del t18far 2>/dev/null
[ "$1" = setup ] || exit 0
[ -f /tmp/hwaccel-t18-forward ] || sysctl -n net.ipv4.ip_forward > /tmp/hwaccel-t18-forward
ip netns add t18far
ip link add t18v0 type veth peer name t18v1 netns t18far
ip link set t18v0 up
ip -n t18far link set lo up
ip -n t18far link set t18v1 up
ip -n t18far addr add $IPSEC_FAR/32 dev t18v1
ip -n t18far route add default dev t18v1
sysctl -q -w net.ipv4.conf.t18v0.proxy_arp=1 net.ipv4.ip_forward=1
# the far network is often an address of lo with its prefix (10.20.0.10/24): the
# kernel takes the whole prefix as local, in the table local, where only a longer
# route of that table beats it
ip route add $IPSEC_FAR/32 dev t18v0 table local
ip netns exec t18far iperf3 -s -D -p $IPSEC_FAR_PORT
sleep 1
ip netns exec t18far ping -c 1 -W 2 \$(ip -4 -o addr show | awk '\$4 ~ /^10\.20\.0\./ { sub(/\/.*/, "", \$4); print \$4; exit }') > /dev/null && echo far=up
EOF
	[ "$1" = setup ] || peer_sh <<'EOF'
[ ! -f /tmp/hwaccel-t18-forward ] || { sysctl -q -w net.ipv4.ip_forward="$(cat /tmp/hwaccel-t18-forward)"; rm -f /tmp/hwaccel-t18-forward; }
EOF
}

# iperf3 -J report of UDP -> the % of datagrams that arrived, as the receiver counts them.
udp_received() {
	python3 - "$1" <<'PY' 2>/dev/null
import json, sys
s = json.load(open(sys.argv[1]))["end"]["sum"]
if s.get("packets"):
    print("%.1f" % (100.0 * (s["packets"] - s["lost_packets"]) / s["packets"]))
PY
}

# A conn of the bench's tunnel with other options ($3: "key=value" lines),
# between "# hwaccel:t18 NAME begin/end" lines of /etc/ipsec.conf of the
# board or of the peer (add), or none (del, with its CHILD_SAs).
t18_conf() { # name, add|del, lines
	cat <<EOF
F=/etc/ipsec.conf
ipsec down "$1{*}" > /dev/null 2>&1
ipsec down "$1" > /dev/null 2>&1
sed -i '/^# hwaccel:t18 $1 begin\$/,/^# hwaccel:t18 $1 end\$/d' \$F
if [ "$2" = add ]; then
	{
		echo '# hwaccel:t18 $1 begin'
		echo 'conn $1'
		printf '%s\n' "$3" | awk '{ print "\t" \$0 }'
		echo '# hwaccel:t18 $1 end'
	} >> \$F
fi
ipsec update > /dev/null 2>&1
sleep 2
EOF
}

t18_conn() { # name, add|del, lines of the board, lines of the peer
	t18_conf "$1" "$2" "$3" | board "sh -s" > "$TMP/t18-board-$1-$2" 2>&1
	t18_conf "$1" "$2" "$4" | peer_sh > "$TMP/t18-peer-$1-$2" 2>&1
	if [ "$2" = add ]; then t18_conns="$t18_conns $1"; else t18_conns=$(echo "$t18_conns" | sed "s/ $1\$//; s/ $1 / /"); fi
}

# The tunnel of conn $1 brought up by the board; 0 once the engine holds its
# outbound SA, within $2 seconds.
t18_up() { # conn, seconds
	board "ipsec up $1" > "$TMP/t18-up-$1" 2>&1
	ipsec_until_held "up-$1" "$2" "" "$1"
}

# ACT (add or del), NET and CONN come from the caller: the firewall rules
# of the VPN page (bmc_ipsec_nat, bmc_ipsec_forward; ticket 03 of bmcwebUI)
# for a tunnel between NET and the far network of the conn CONN, as the
# page makes them for its own tunnels, or none.
t18rules_script() { cat <<'EOF'
# hwaccel:t18rules
far=$(sed -n "/^# --- BEGIN:$CONN ---\$/,/^# --- END:$CONN ---\$/s/^[[:space:]]*rightsubnet=//p" /etc/ipsec.conf | head -1)
echo "far=$far"
[ -n "$far" ] || exit 0
rule() { # table, chain, source, destination, direction
	while iptables -w -t "$1" -D "$2" -s "$3" -d "$4" -m policy --dir "$5" --pol ipsec \
		-m comment --comment 'hwaccel t18' -j ACCEPT 2>/dev/null; do :; done
	[ "$ACT" = del ] || iptables -w -t "$1" -I "$2" -s "$3" -d "$4" -m policy --dir "$5" --pol ipsec \
		-m comment --comment 'hwaccel t18' -j ACCEPT
}
rule nat bmc_ipsec_nat "$NET" "$far" out
rule filter bmc_ipsec_forward "$NET" "$far" out
rule filter bmc_ipsec_forward "$far" "$NET" in
echo "rules=$(iptables -w -S bmc_ipsec_forward | grep -c 'hwaccel t18')"
exit 0
EOF
}

t18_rules() { # add|del, local network
	board "ACT=$1
NET='$2'
CONN='$BOARD_CONN'
$(t18rules_script)" > "$TMP/t18-rules-$1" 2>&1
	if [ "$1" = add ]; then t18_nets="$t18_nets $2"; else t18_nets=$(echo "$t18_nets" | sed "s| $2\$||; s| $2 | |"); fi
}

# User story 12: the tunnel over a PPPoE wan (the bench of ticket 10, PC2's
# PPPoE server on the peer, PPPOE_SERVER): a conn of the bench's tunnel
# between the PPPoE addresses (t18-pppoe) in place of BOARD_CONN; the engine
# holds its SAs and its connections, iperf3 -P 4 through it reaches
# ACCEL_PCT % of IPSEC_PAYLOAD_PCT % of iperf3 to the peer outside the tunnel
# over the same PPPoE (the payload ESP leaves of a packet of the MTU), the
# kernel sees fewer than KERNEL_MAX packets of eth0 in WINDOW s; the pings of
# ipsec_pings fit the MTU of the tunnel over PPPoE, which is 1422 as over a
# plain wan: 1492 less 68 of ESP in UDP is 1424, a multiple of the 16 of
# AES-CBC already, as 1432 of 1500 rounds down to it (xfrm_state_mtu() of
# Linux, the engine's). BOARD_CONN again after.
item_ipsec_pppoe() {
	ipsec_ready ipsec-pppoe || return
	item_plan pppoe
	net_ready "$need_wan" "$need_vlans" || { report ipsec-pppoe "not tested"; return; }
	peer_p=$wan_peer
	[ -n "$peer_p" ] && [ -n "$wan_addr" ] || { why "the PPPoE session has no address of its own or of its peer"; report ipsec-pppoe "not tested"; return; }
	mine=${wan_addr%/*}
	seq0=$(peer_seq)
	t18_conn t18-pppoe add "also=$BOARD_CONN
left=$mine
right=$peer_p
auto=add" "also=$PEER_CONN
left=$peer_p
right=$mine
auto=add"
	board "ipsec down $BOARD_CONN" > /dev/null 2>&1
	t18_up t18-pppoe 30 || why "the engine did not hold the outbound SA of the tunnel over PPPoE within 30 s ($(tail -1 "$TMP/t18-up-t18-pppoe"))"
	direct_to=${IPSEC_PPPOE_DIRECT:-$peer_p}
	ipsec_run ipsec-pppoe-direct "$direct_to" ""
	direct=$mbps
	ipsec_run ipsec-pppoe "$IPSEC_TARGET" ""
	ipsec_judge "$TMP/ipsec-pppoe"
	min=$((${direct:-0} * ACCEL_PCT / 100 * IPSEC_PAYLOAD_PCT / 100))
	[ -z "$mbps" ] || [ "$mbps" -ge "$min" ] ||
		why "$mbps Mbps through the tunnel over PPPoE, need $min ($ACCEL_PCT % of $IPSEC_PAYLOAD_PCT % of ${direct:-?} Mbps to $direct_to outside it)"
	ipsec_pings "$IPSEC_TARGET"
	seq1=$(peer_seq)
	peer_seq_judge "$seq0" "$seq1"
	t18_conn t18-pppoe del "" ""
	report ipsec-pppoe "over PPPoE $mine -> $peer_p: ${mbps:-?} Mbps of ${direct:-?} outside the tunnel ($ipsec_text); $mtu_text; the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
	net_ready plain ""
	tunnel_up
	ipsec_until_held pppoe-restored 30 || echo "               (the engine did not hold $BOARD_CONN again after the item)"
}

# User story 12: PC1 on VLAN_ID of VLAN_PARENT (VLAN_CLIENT, ticket 10), a
# conn of the bench's tunnel for the VLAN's network (t18-vlan) next to
# BOARD_CONN, with the firewall rules of a tunnel of the VPN page: iperf3
# -P 4 from VLAN_CLIENT through it reaches IPSEC_MBPS, accelerated as
# ipsec-accel judges it.
item_ipsec_vlan() {
	ipsec_ready ipsec-vlan || return
	item_plan vlan-wan
	net_ready "$need_wan" "$need_vlans" || { report ipsec-vlan "not tested"; return; }
	vnet=${VLAN_CLIENT%.*}.0/24
	seq0=$(peer_seq)
	t18_rules add "$vnet"
	t18_conn t18-vlan add "also=$BOARD_CONN
leftsubnet=$vnet
auto=add" "also=$PEER_CONN
rightsubnet=$vnet
auto=add"
	t18_up t18-vlan 30 || why "the engine did not hold the outbound SA of the tunnel of VLAN $VLAN_ID within 30 s ($(tail -1 "$TMP/t18-up-t18-vlan"))"
	ipsec_bind=$VLAN_CLIENT
	ipsec_run ipsec-vlan "$IPSEC_TARGET" ""
	ipsec_bind=
	ipsec_judge "$TMP/ipsec-vlan"
	[ -z "$mbps" ] || [ "$mbps" -ge "$IPSEC_MBPS" ] || why "$mbps Mbps from $VLAN_CLIENT to $IPSEC_TARGET, need $IPSEC_MBPS"
	seq1=$(peer_seq)
	peer_seq_judge "$seq0" "$seq1"
	t18_conn t18-vlan del "" ""
	t18_rules del "$vnet"
	report ipsec-vlan "from $VLAN_CLIENT (VLAN $VLAN_ID) to $IPSEC_TARGET: ${mbps:-?} Mbps ($ipsec_text); the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
}

# Multi-WAN next to the tunnel (spec-ipsec: Phạm vi, Route): with wan2 on
# MWAN_PORT (a 1G port) towards ISP B, as the mwan item sets it up:
#   - a Chuyển WAN of wan2 (it goes down and up again under iperf3 -P 4
#     through the tunnel on wan) leaves the tunnel alone: iperf3 runs to its
#     end, at most MWAN_IPSEC_GAP s under 1 Mbps, the SPIs are kept and the
#     engine holds the tunnel's connections again within REROUTE_WAIT s;
#   - with MWAN_CONN, a conn of the board to a peer behind wan2, and
#     MWAN_IPSEC_TARGET behind it: that tunnel is INSTALLED, carries iperf3,
#     and the engine holds none of its SAs nor connections.
item_ipsec_mwan() {
	ipsec_ready ipsec-mwan || return
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report ipsec-mwan "not tested"; return; }
	multiwan=1
	mwan setup > "$TMP/ipsec-mwan-setup"
	refused=$(value "$TMP/ipsec-mwan-setup" refused)
	if [ -n "$refused" ] || [ "$(value "$TMP/ipsec-mwan-setup" wan2)" != "up online" ]; then
		why "Multi-WAN did not come up: ${refused:-wan $(value "$TMP/ipsec-mwan-setup" wan), wan2 $(value "$TMP/ipsec-mwan-setup" wan2)}"
		mwan end > /dev/null; multiwan=0
		report ipsec-mwan "not tested"
		return
	fi
	tunnel_up
	ipsec_until_held mwan-before "$DAEMON_WAIT" ||
		why "with Multi-WAN, the engine did not hold the tunnel's outbound SA within $DAEMON_WAIT s"
	seq0=$(peer_seq)
	"$IPERF3" -c "$IPSEC_TARGET" -t "$((WARMUP + MWAN_WAIT + 20))" -P 4 -J -T ipsec-mwan > "$TMP/iperf-ipsec-mwan.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "ifdown wan2; sleep 5; ifup wan2" > /dev/null 2>&1
	ipsec_until_held mwan-after "$REROUTE_WAIT" held || why "the engine did not hold the tunnel's connections again within $REROUTE_WAIT s of wan2 down and up"
	wait "$iperf_pid"
	iperf_pid=
	iperf_judge ipsec-mwan "$MWAN_IPSEC_GAP"
	before=$(value "$TMP/is-mwan-before" spis)
	[ "$(value "$TMP/is-mwan-after" spis)" = "$before" ] ||
		why "strongSwan's SPIs went from ${before:-none} to $(value "$TMP/is-mwan-after" spis)"
	seq1=$(peer_seq)
	peer_seq_judge "$seq0" "$seq1"
	text="wan2 down and up under iperf3 through the tunnel on wan: ${mbps:-?} Mbps, ${idle:-?} s under 1 Mbps, SPIs ${before:-?} kept"
	if [ -n "$MWAN_CONN" ] && [ -n "$MWAN_IPSEC_TARGET" ]; then
		board "ipsec up $MWAN_CONN" > "$TMP/ipsec-mwan-up" 2>&1
		"$IPERF3" -c "$MWAN_IPSEC_TARGET" -t "$DURATION" -P 4 -J -T ipsec-mwan2 > "$TMP/iperf-ipsec-mwan2.json" 2>/dev/null &
		iperf_pid=$!
		sleep "$WARMUP"
		ipsec_state mwan2 "$MWAN_IPSEC_TARGET"
		wait "$iperf_pid"
		iperf_pid=
		m2=$(iperf_mbps "$TMP/iperf-ipsec-mwan2.json")
		[ -n "$m2" ] && [ "$m2" -gt 0 ] || why "iperf3 through $MWAN_CONN: $(iperf_error "$TMP/iperf-ipsec-mwan2.json")"
		spis2=$(kernel_out_spis mwan2 "$MWAN_CONN")
		[ -n "$spis2" ] || why "$MWAN_CONN has no SA INSTALLED"
		for s in $spis2; do
			! has_word "$s" "$(engine_spis mwan2)" || why "the engine holds 0x$s of $MWAN_CONN, a tunnel through wan2 on a 1G port"
		done
		[ "$(value "$TMP/is-mwan2" held)" = 0 ] || why "the engine held a connection to $MWAN_IPSEC_TARGET"
		text="$text; $MWAN_CONN through wan2: ${m2:-?} Mbps, SPIs$spis2 not in the engine"
	else
		why "set MWAN_CONN and MWAN_IPSEC_TARGET: a tunnel through wan2 (bench.md)"
		text="$text; no tunnel through wan2: not tested"
	fi
	mwan end > /dev/null
	multiwan=0
	report ipsec-mwan "$text; the peer's sequence errors ${seq0:-?} -> ${seq1:-?}"
}

# features with Tăng tốc phần cứng on, as this ticket asks: the LS1046 runs
# the item disabled, its board script disabling it at start (and enabling it
# again at the end, which leaves an enabled board as it was).
lib_features_script=$(features_script)
features_script() {
	[ "$(printf '%s\n' "$lib_features_script" | grep -c -F '|| bmchwaccel disable >/dev/null 2>&1')" = 1 ] || {
		echo "acceptance: features_script of scripts/hwaccel/acceptance.sh changed; adapt it here" >&2
		exit 2
	}
	printf '%s\n' "$lib_features_script" | sed 's#|| bmchwaccel disable >/dev/null 2>&1#|| :#'
}

# The engine in the place of cmm, on the "daemon=" line of soak.
lib_soak_script=$(soak_script)
soak_script() {
	[ "$(printf '%s\n' "$lib_soak_script" | grep -c -F 'echo "daemon=$(pidof cmm)"')" = 1 ] || {
		echo "acceptance: soak_script of scripts/hwaccel/acceptance.sh changed; adapt it here" >&2
		exit 2
	}
	printf '%s\n' "$lib_soak_script" | sed 's#echo "daemon=$(pidof cmm)"#echo "daemon=$(pidof bmchwaccel-engine)"#'
}

features_start() {
	net_ready plain "" || return 1
	featuring=1
	feature start > "$TMP/features"
	PC1=$(value "$TMP/features" pc1)
	pc1_mac=$(value "$TMP/features" mac)
	[ -n "$PC1" ] || { why "the board does not know where the ssh session comes from; set PC1"; return 1; }
	[ -n "$pc1_mac" ] || { why "the board has no MAC address for PC1 ($PC1)"; return 1; }
	case "$(value "$TMP/features" status)" in
	none) accel="no bmchwaccel on this board" ;;
	*)
		status_check "$TMP/features" on "Tăng tốc phần cứng must be on for the item"
		accel="Tăng tốc phần cứng on"
		;;
	esac
	[ -z "$reasons" ]
}

# What the items of this ticket leave on the board when the run is cut short,
# before the cleanup of scripts/hwaccel/acceptance.sh.
losing_wan=0
blocking_other=0
ipsec_blocking=0
ipsec_link_down=0
far_made=0
t18_conns=
t18_nets=
t18_cleanup() {
	[ $ipsec_blocking -eq 0 ] || ipsecblock end >/dev/null 2>&1
	[ $ipsec_link_down -eq 0 ] || board "ip link set $WAN_PORT up" >/dev/null 2>&1
	[ $far_made -eq 0 ] || ipsec_far teardown >/dev/null 2>&1
	for c in $t18_conns; do t18_conn "$c" del "" "" >/dev/null 2>&1; done
	for n in $t18_nets; do t18_rules del "$n" >/dev/null 2>&1; done
}
trap '[ $losing_wan -eq 0 ] || mwanwan end "" >/dev/null 2>&1; [ $blocking_other -eq 0 ] || blockother end >/dev/null 2>&1; t18_cleanup; cleanup' EXIT

# ---- main

ITEMS="boot firewall ports wan-link baseline baseline-back soak reboots idle restart carrier wire-stats wire-stats-back pdump onoff enable-boot deaths accel accel-back accel-vlan accel-vlan-back accel-pppoe accel-pppoe-back accel-vlan-pppoe accel-vlan-pppoe-back accel-redial accel-udp accel-udp-back udp-oneway keep-mark daemon-kill daemon-block accel-1g udp-long udp-expire tcp-long reroute qos qos-back block block-other ftp ipsec-accel ipsec-reorder ipsec-rekey ipsec-kill ipsec-disable ipsec-syncd ipsec-limit ipsec-many ipsec-algo ipsec-replay ipsec-sweep ipsec-qos ipsec-route ipsec-mtu ipsec-pppoe ipsec-vlan ipsec-mwan tx-limit mwan features features-in webui webui-ports webui-ports-back sysupgrade sysupgrade-old"
[ $# -gt 0 ] || set -- boot firewall ports wan-link baseline baseline-back
for item in "$@"; do
	case " $ITEMS " in
	*" $item "*) ;;
	*) echo "acceptance: unknown item '$item' ($(echo $ITEMS | sed 's/ /, /g'))" >&2; exit 2 ;;
	esac
done

board "$(info_script)" > "$TMP/info" 2>&1 || {
	echo "acceptance: cannot run commands on root@$BOARD over ssh" >&2
	exit 2
}
echo "== board root@$BOARD =="
cat "$TMP/info"
echo "== results =="
for item in "$@"; do
	case "$item" in
	boot)           item_layout ;;
	firewall)       item_firewall ;;
	ports)          item_ports ;;
	wan-link)       item_wan_link ;;
	baseline|baseline-back) item_baseline "$item" ;;
	soak)           item_soak_kernel ;;
	reboots)        item_reboots_kernel ;;
	idle)           item_idle ;;
	restart)        item_restart ;;
	carrier)        item_carrier ;;
	wire-stats|wire-stats-back|webui-ports|webui-ports-back) item_wire_stats "$item" ;;
	pdump)          item_pdump ;;
	onoff)          item_onoff ;;
	enable-boot)    item_enable_boot ;;
	deaths)         item_deaths ;;
	accel|accel-back|accel-vlan|accel-vlan-back|accel-pppoe|accel-pppoe-back|accel-vlan-pppoe|accel-vlan-pppoe-back)
		item_accel "$item" ;;
	accel-redial)   item_accel_redial ;;
	accel-udp|accel-udp-back) item_accel_udp "$item" ;;
	udp-oneway)     item_udp_oneway ;;
	keep-mark)      item_keep_mark ;;
	daemon-kill)    item_daemon_kill ;;
	daemon-block)   item_daemon_block ;;
	accel-1g)       item_accel_1g ;;
	udp-long)       item_udp_long ;;
	udp-expire)     item_udp_expire ;;
	tcp-long)       item_tcp_long ;;
	reroute)        item_reroute ;;
	qos|qos-back)   item_qos_engine "$item" ;;
	block)          item_block ;;
	block-other)    item_block_other ;;
	ftp)            item_ftp ;;
	ipsec-accel)    item_ipsec_accel ;;
	ipsec-reorder)  item_ipsec_reorder ;;
	ipsec-rekey)    item_ipsec_rekey ;;
	ipsec-kill)     item_ipsec_kill ;;
	ipsec-disable)  item_ipsec_disable ;;
	ipsec-syncd)    item_ipsec_syncd ;;
	ipsec-limit)    item_ipsec_limit ;;
	ipsec-many)     item_ipsec_many ;;
	ipsec-algo)     item_ipsec_algo ;;
	ipsec-replay)   item_ipsec_replay ;;
	ipsec-sweep)    item_ipsec_sweep ;;
	ipsec-qos)      item_ipsec_qos ;;
	ipsec-route)    item_ipsec_route ;;
	ipsec-mtu)      item_ipsec_mtu ;;
	ipsec-pppoe)    item_ipsec_pppoe ;;
	ipsec-vlan)     item_ipsec_vlan ;;
	ipsec-mwan)     item_ipsec_mwan ;;
	tx-limit)       item_tx_limit ;;
	mwan)           item_mwan_engine ;;
	features)       item_features ;;
	features-in)    item_features_in ;;
	webui)          item_webui ;;
	sysupgrade)     item_sysupgrade ;;
	sysupgrade-old) item_sysupgrade_old ;;
	esac
done

if [ $rc -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit $rc
