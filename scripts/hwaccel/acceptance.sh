#!/bin/sh
# Hardware acceleration acceptance on a real LS1046A-RDB, driven over SSH.
#
# Cabling:
#
#   PC1 192.168.5.x ── eth1 [br-lan 192.168.5.1] LS1046 [wan 192.168.2.1] eth0 ── PC2 192.168.2.10
#   runs this script                                                            runs "iperf3 -s"
#
# br-lan is where the firmware puts it, on 192.168.5.0/24. A board on another
# address is named with BOARD.
#
# PC1 may use any br-lan port. PC1 needs ssh and iperf3 (on macOS the built-in
# iperf3-darwin is used when there is no iperf3); the board must accept
# "ssh root@BOARD" without a password prompt. PC2 needs no gateway, the board
# masquerades. The VLAN and PPPoE items need more on PC1 and PC2 (a VLAN
# interface, a PPPoE server, a second iperf3 server); scripts/hwaccel/bench.md
# has the commands.
#
# The script changes the board for the items that need it and puts the network
# and firewall configuration back when it ends:
#   - a board in security mode nac or fido is switched to off, the way the web
#     UI does it: under nac the LAN clients belong to the captive portal and
#     br-lan forwards nothing of a client that did not log in. The portal item
#     switches to nac instead.
#   - a wan without an IPv4 address (PC2 is not a DHCP server) gets WAN_ADDR
#   - the VLAN items add VLAN interfaces to the lan zone
#   - the PPPoE items make wan dial PPPoE
#
# Usage: scripts/hwaccel/acceptance.sh [item...]
# Items, in the default order:
#   boot            kernel version, CDX accepted the FMan microcode, "bmchwaccel
#                   status" says on, and the daemon was started once
#   firewall        fw3 on iptables-legacy is running; no fw4, no software flow
#                   offloading
#   ports           wan is on eth0, br-lan bridges the other ports
#   mac             every port has the MAC address the bootloader gave it; none
#                   uses a temporary MAC
#   brlan-wan       PC1 -> PC2, routed and masqueraded from br-lan to wan
#   brlan-wan-back  PC2 -> PC1 over the same kind of connection (iperf3 -R)
#   toggle          hardware acceleration is disabled and enabled again with
#                   bmchwaccel, without a reboot, under one iperf3 run from PC1
#                   to PC2 as in brlan-wan. The packets must stay off the CPU
#                   before, reach the CPU while "bmchwaccel status" says off
#                   with no accelerated connection, and leave the CPU again once
#                   the status is back to on. While disabled, the CPU must
#                   see as many packets as iperf3 carried. The run must last
#                   through both switches without standing still, with every
#                   stream still carrying data at its end, and reach MIN_MBPS
#                   from the moment it is accelerated again; each switch must
#                   leave one syslog line. While disabled, a second iperf3 run
#                   (to DROP_PORT) opens a new connection, and a ping runs from
#                   PC1 to PC2 all along. A failed item prints, second by
#                   second, what crossed the ports with a link, and every board
#                   counter that changed while disabled.
#   vlan-wan        as brlan-wan, PC1 sending from VLAN_CLIENT through the VLAN
#                   interface VLAN_PARENT.VLAN_ID of the board
#   vlan-wan-back   the same with iperf3 -R
#   pppoe           as brlan-wan, with wan dialling PPPoE to PC2; the iperf3
#                   server is PPPOE_SERVER
#   pppoe-back      the same with iperf3 -R
#   pppoe-drop      the PPPoE session is ended while PC1 sends UDP to the second
#                   iperf3 server (DROP_PORT) through it, and kept down for
#                   WINDOW seconds: the flow must be accelerated before, no
#                   packet may leave the wan port while the session is down,
#                   and the session must come back
#   pppoe-redial    as pppoe, run after pppoe-drop: connections over the new
#                   session are accelerated
# Run only when named:
#   toggle-back     toggle with the traffic the other way: PC2 sends to PC1
#                   (iperf3 -R), as in brlan-wan-back
#   mac-temp        for a boot without MAC addresses from the bootloader
#                   (bench.md): every port has a temporary MAC, locally
#                   administered and made from the SoC unique ID; the kernel log
#                   and syslog name each port; the addresses are the same as in
#                   the boot before, once the item has run in two boots
#   vlan-vlan       PC1 in VLAN_ID -> PC2 in VLAN2_ID, routed without NAT. PC2
#                   has to be on a br-lan port for it, not on wan.
#   vlan-vlan-back  the same with iperf3 -R
#   off-boot        the board is rebooted with hardware acceleration disabled
#                   ("bmchwaccel disable"). While PC1 sends to PC2 as in
#                   brlan-wan, "bmchwaccel status" says off with no accelerated
#                   connection, the ASK modules are not loaded, no connection
#                   is handed to the hardware and the packets reach the CPU.
#                   Hardware acceleration is then enabled and the board
#                   rebooted again: the status must be back to on.
#   soak            PC1 sends to PC2 as in brlan-wan for SOAK seconds, in one
#                   iperf3 run. Every SOAK_EVERY seconds, and once more at the
#                   end, the board is read as in a traffic item: the packets
#                   must stay off the CPU and "bmchwaccel status" must say on.
#                   The run as a whole must reach MIN_MBPS, and its last minute
#                   may be at most 2 percent below its first. At the
#                   end the board must be in the same boot, with the same
#                   daemon process, the three ASK modules, no kernel line that
#                   tells of trouble and no bmcHwAccel syslog line since the
#                   start (the lines of the daemon are printed, not judged). The item prints the Mbps of every minute, the
#                   memory the kernel had free at both ends, and the kernel
#                   lines of the run. PC1 must not go to sleep under it
#                   (bench.md).
#   reboots         the board is rebooted REBOOTS times in a row. In every
#                   boot the checks of the boot item (but for the kernel
#                   version) must pass, the three ASK modules must be loaded,
#                   and the traffic of brlan-wan must be accelerated; its Mbps
#                   are printed, not judged. Each boot also gets the number of
#                   its kernel lines that tell of trouble, to compare the
#                   boots by. The item stops at the first boot that fails and
#                   leaves the board in it.
#   boot-time       how long the boot waited for the firmware of the 10G copper
#                   PHY (AQR113C), which the kernel uploads over MDIO before
#                   the network ports are probed: the upload time and the MDC
#                   frequency from the kernel log, when FMan, each MAC and
#                   each port were probed and when br-lan first forwarded (it
#                   needs a cable on a br-lan port). Seconds are those of the
#                   kernel log: the bootloader's time is not in them. Fails
#                   when the upload failed, the 10G copper port has no
#                   Aquantia PHY, or a kernel that logs the upload time did
#                   not set the MDC frequency. A PHY that still has its
#                   firmware gets no upload: measure in a boot after power-on.
#   ucode-public    for a card that carries the public FMan microcode (106.x)
#                   instead of the ASK one (bench.md): CDX refuses it,
#                   "bmchwaccel status" says unavailable with the reason
#                   microcode, syslog has a bmcHwAccel line that says so, and
#                   PC1 still reaches PC2 as in brlan-wan, routed and
#                   masqueraded by the CPU
#   sysupgrade      the board takes FIRMWARE with sysupgrade, keeping its
#                   configuration, and reboots into it: an option set before is
#                   still there, the network and firewall configuration are
#                   unchanged, the kernel file on the card was written, and
#                   the kernel and root filesystem on the card are those of
#                   the image. Name boot and traffic items after it to see
#                   that the new firmware accelerates.
#   sysupgrade-old  for a board on the 24.10 firmware: the test mode of
#                   sysupgrade (-T, writes nothing) refuses FIRMWARE and says
#                   that the SD card has to be written
#   webui           the web UI of the 24.10 firmware on this base: its server
#                   and the DNS filter run on the board, PC1 gets the login
#                   page, a wrong password is refused, and WEBUI_USER logs in
#                   with WEBUI_PASS. Logged in, every page of WEBUI_PAGES
#                   opens and every request those pages start with
#                   (WEBUI_APIS) is answered without an error. The account
#                   must not be one that still has to change its password.
#   features        macfilter, client_control and ddos_protect do on this
#                   board what they do on the 24.10 firmware, with hardware
#                   acceleration disabled for the item (a board without
#                   bmchwaccel, the 24.10 firmware, is tested as it is). Each
#                   is driven through the script the web UI calls. A
#                   blacklist entry of macfilter for the MAC of PC1 and a
#                   client_control rule for it that covers the whole week
#                   must each stop PC1 from reaching PC2 (ping), and PC1 must
#                   reach PC2 again once the entry is gone. With ddos_protect
#                   enabled only part of FLOOD_PINGS pings sent at 3 a second
#                   must be answered, and all of them once disabled: first
#                   pings to the board, then pings through it to PC2, which
#                   the board forwards.
#                   macfilter and ddos_protect must be disabled on the board
#                   before the item; it leaves them disabled.
#   features-in     NAT 1:1 and a port forward, which need a connection from
#                   the wan side: the item sets each up towards PC1, tells
#                   what to run on PC2, and waits IN_WAIT seconds for that
#                   connection to show up on the board, translated to PC1.
#                   Hardware acceleration is disabled for the item as in
#                   features. NAT 1:1 goes through the script of the web UI
#                   (rule IN_RULE on wan), the port forward through the
#                   script behind the firewall page (FWD_PORT on wan to
#                   IN_PORT on PC1). Both are taken away again.
#   portal          the captive portal (security mode nac, CoovaChilli with
#                   FreeRADIUS) with hardware acceleration as the board has
#                   it, which must be on. PC1 has to hold an address the
#                   portal gave it (PORTAL_CLIENT, bench.md). Before the
#                   login an HTTP request of PC1 to PC2 must be answered with
#                   a redirect to the portal page, no ping of PC1 may be
#                   answered by PC2 and the board may not have forwarded
#                   anything of PC1 to PC2. PC1 then logs in through the
#                   login script of the portal page, as a user the item adds
#                   to the user database: the portal must list PC1 as
#                   authorized and PC2 must answer its pings. After the
#                   logout PC2 must be out of reach again. The user is
#                   removed, and a board in another security mode is put
#                   back into it when the script ends.
#   proxy           squid and the ICAP server run as they do after a boot.
#                   A download of PC1 from the web server on PC2
#                   (HTTP_PORT, HTTP_FILE; bench.md) is sent through squid
#                   the way the firmware does it for the antivirus: a
#                   REDIRECT rule on br-lan to squid's intercept port. The
#                   board must answer PC1 itself, open its own connection
#                   to PC2, ask the ICAP server, and hardware acceleration
#                   must not have taken a connection. Without ClamAV on the
#                   board (not in the image, as on the 24.10 firmware) the
#                   antivirus service cannot scan and PC1 must get squid's
#                   error page; with it PC1 must get the whole file and the
#                   HTTP file tracker, enabled for PC1 by the item, must log
#                   the transfer. The same download without the rule is
#                   made after it and what the tracker logged for it is
#                   printed, not judged: such a connection is forwarded,
#                   and the tracker only sees what reaches the CPU.
#   keep-mark       the trial of the mechanism that keeps traffic on the CPU:
#                   a rule on the board gives every connection to DROP_PORT
#                   the conntrack mark bit that hardware acceleration must
#                   leave alone (0x10000). PC1 sends to the second iperf3
#                   server of PC2 (DROP_PORT) as in brlan-wan: no such
#                   connection may be handed to the hardware, and both the
#                   wan port and the br-lan ports must pass at least
#                   MAX_CPU_PKTS packets to the CPU in WINDOW seconds, so
#                   neither direction is accelerated; its Mbps are printed,
#                   not judged. With the rule still there PC1 then sends to
#                   the first server, and that run must pass as brlan-wan
#                   does. The rule is taken away again.
#   qos             bmcqos is turned on for wan at QOS_MBPS in both
#                   directions, for the item only. "bmchwaccel status" must
#                   list wan as kept on the CPU for bmcqos while it still
#                   says on. PC1 then sends to PC2 as in brlan-wan: the run
#                   must stay at or below QOS_MBPS (5 percent over is let
#                   through) and reach 80 percent of it, no connection to
#                   PC2 may be handed to the hardware and both directions
#                   must reach the CPU, as in keep-mark. With bmcqos turned
#                   off again the status must list nothing for it. The
#                   bmcqos configuration of the board is put back.
#   qos-back        the same with iperf3 -R: the limit on what comes in
#   qos-vlan-vlan   vlan-vlan with bmcqos turned on for wan as in qos: what
#                   does not go through wan must be accelerated as before.
#                   PC2 has to be on a br-lan port for it, as in vlan-vlan.
#   mwan            Multi-WAN with two WANs next to hardware acceleration,
#                   for the item only: the br-lan port MWAN_PORT becomes wan2
#                   towards a second PC, ISP B (SERVER2), next to wan towards
#                   PC2, ISP A (SERVER). Both ISPs answer for two addresses
#                   that stand for the Internet, MWAN_TARGET and
#                   MWAN_TARGET2, with the two iperf3 servers and a third
#                   one (MWAN_FLOW_PORT) on each (bench.md). The default
#                   Chính sách WAN prefers wan; a Luật chọn WAN sends what
#                   goes to MWAN_TARGET2 to a Chính sách WAN that prefers
#                   wan2. Four results:
#                   mwan-default  PC1 sends to MWAN_TARGET: passes as
#                                 brlan-wan does, every accelerated
#                                 connection translated to the address of
#                                 wan, at least MAX_CPU_PKTS packets leaving
#                                 the wan port in WINDOW seconds and fewer
#                                 the wan2 port
#                   mwan-rule     the same to MWAN_TARGET2, through wan2
#                   mwan-lost     under an accelerated UDP flow to
#                                 MWAN_TARGET2 the board stops the pings that
#                                 check wan2, so wan2 is Mất Internet while
#                                 its link and ISP B stay as they are. After
#                                 the Chuyển WAN bmcMultiWAN must have
#                                 removed the connections of wan2 (its syslog
#                                 line), fewer than MAX_CPU_PKTS packets may
#                                 leave the wan2 port in WINDOW seconds, and
#                                 the flow must leave through wan instead,
#                                 with at least as many. A failed result
#                                 prints both ports second by second. A
#                                 new connection to MWAN_TARGET2 must then
#                                 pass as brlan-wan does, through wan.
#                   mwan-back     with a connection to MWAN_TARGET2 open
#                                 through wan, wan2 gets its pings back.
#                                 After that Chuyển WAN the open connection
#                                 must still run, accelerated, through wan,
#                                 and a new one (to DROP_PORT) must be
#                                 accelerated through wan2; no test port may
#                                 pass MAX_CPU_PKTS packets to the CPU.
#                   The Multi-WAN configuration of the board, which must have
#                   Multi-WAN disabled, is put back.
#   mwan-in         with the two WANs of mwan: the item forwards FWD_PORT of
#                   wan2 to PC1 (IN_PORT), tells what to run on the PC of ISP
#                   B (a connection from MWAN_TARGET2, an address outside
#                   the network of wan2) and waits IN_WAIT seconds for that
#                   connection to be handed to the hardware. Its answers must then leave
#                   through wan2, the WAN it came in from, and not through
#                   wan, which the default Chính sách WAN prefers: at least
#                   MAX_CPU_PKTS packets must leave the wan2 port in WINDOW
#                   seconds and fewer the wan port, with the packets off the
#                   CPU.
#   ospf            DynRouting next to hardware acceleration, for the item
#                   only: the br-lan port OSPF_PORT becomes a Link định tuyến
#                   (OSPF_ADDR) towards a neighbour router that runs OSPF and
#                   announces the network of OSPF_TARGET, an address of its
#                   own with the two iperf3 servers and a third one
#                   (OSPF_FLOW_PORT) on it (bench.md). The board runs OSPF
#                   on that link and, passive, on lan. Three results:
#                   ospf-learned    both ends are neighbours and the kernel
#                                   has OSPF's route. PC1 sends to
#                                   OSPF_TARGET: passes as vlan-vlan does
#                                   (no accelerated connection may be
#                                   masqueraded: a Link định tuyến is in a
#                                   zone without NAT), with at least
#                                   MAX_CPU_PKTS packets leaving OSPF_PORT
#                                   in WINDOW seconds
#                   ospf-withdrawn  under an accelerated UDP flow to
#                                   OSPF_TARGET the board stops hearing the
#                                   OSPF packets of the neighbour, as when
#                                   its OSPF is turned off, while the link
#                                   stays up. Once OSPF has withdrawn the
#                                   route, fewer than MAX_CPU_PKTS packets
#                                   may leave OSPF_PORT in WINDOW seconds,
#                                   with PC1 still sending.
#                   ospf-back       the board hears the neighbour again.
#                                   With the route back a new connection
#                                   must pass as in ospf-learned.
#                   The DynRouting configuration of the board, which must
#                   have OSPF disabled, is put back.
#   ospf-move       the same with a second Link định tuyến to the same
#                   neighbour router, on OSPF_PORT2 (OSPF_ADDR2), at a
#                   higher OSPF cost. Two results:
#                   ospf-moved      under one iperf3 run to OSPF_TARGET,
#                                   accelerated through OSPF_PORT, the cost
#                                   of OSPF_PORT is raised above that of
#                                   OSPF_PORT2 in the running OSPF daemon,
#                                   so the route changes its next hop
#                                   without being withdrawn. After it the
#                                   run must be accelerated through
#                                   OSPF_PORT2, with fewer than MAX_CPU_PKTS
#                                   packets leaving OSPF_PORT in WINDOW
#                                   seconds. The run as a whole must reach
#                                   MIN_MBPS without standing still, and
#                                   every stream must still carry data at
#                                   its end.
#                   ospf-ecmp       not a criterion: both links get the
#                                   same cost, and a new run to OSPF_TARGET
#                                   is read as a traffic item is, with the
#                                   route and what left each port. Its
#                                   outcome does not count in RESULT.
#   stats           the numbers the web UI dashboard shows under
#                   accelerated traffic, taken from the very script the
#                   web UI calls (get_net_stats.sh). PC1 sends to PC2 as
#                   in brlan-wan, with a low-rate UDP flow to the second
#                   iperf3 server (DROP_PORT) beside it so the table has a
#                   UDP entry too; the TCP run must be accelerated. The
#                   script is read twice, WINDOW seconds apart. Its
#                   connection counts (all, TCP, UDP) must be within
#                   STATS_SLACK of what the kernel's connection table held
#                   when the item read it, and the accelerated TCP
#                   connection of the run must be in that table,
#                   masqueraded: an accelerated connection the CPU no
#                   longer forwards must still be counted. Between the two
#                   answers the interface bytes the script reports for the
#                   wan port (sent) and for the br-lan ports together
#                   (received) must each have grown by STATS_LOW to
#                   STATS_HIGH percent of what iperf3 carried in that
#                   window: a counter that misses accelerated traffic
#                   would stay near zero while gigabits flow. Those
#                   counters come from /proc/net/dev, which the ASK kernel
#                   feeds the hardware-forwarded bytes of a physical port.
#   stats-back      the same with iperf3 -R: the wan port receives and the
#                   br-lan ports send
#   bridge          PC1 -> PC2 with both on br-lan ports (PC2 at BRIDGE_SERVER,
#                   bench.md), so the board bridges and does not route. Such
#                   traffic is in the hardware like what the board routes,
#                   connection by connection (the daemon runs with -B): MIN_MBPS,
#                   the packets must not reach the CPU, and the hardware must
#                   have the connections to PC2.
#   bridge-block    PC1 sends UDP to the second iperf3 server (DROP_PORT) of
#                   PC2 across br-lan, in the hardware. While the flow runs
#                   the board is told to block the MAC address of PC1: once
#                   by macfilter, once by client_control, each by the script
#                   the web UI calls, which also has the connections of that
#                   machine taken out of the hardware (bmchwaccel sweep).
#                   Then the two features that drop by address: the blocked
#                   services of bmcfirewall (the address of PC2 put in the
#                   ipset of a service, with the rules bmcfirewall writes
#                   for a service blocked for everybody) and bmcfido (its
#                   own rules, with PC1 taken out of the set of the machines
#                   signed in); for these the item runs the sweep itself, as
#                   cron does every minute. Neither is set through its page:
#                   what is shown is that the sweep reads their rules and
#                   takes the flow out.
#                   Nothing of the flow may leave the port of PC2 once the
#                   rule is there. Every flow gets a line: packets on the CPU
#                   and out of the port of PC2 before the rule, out of that
#                   port under the rule, and the packets the rule counted.
#   bridge-neigh    PC1 sends TCP to PC2 across br-lan after the neighbour
#                   entry of PC2 was deleted on the board: such a flow is on
#                   the CPU. bmchwaccel sweep must have the kernel resolve
#                   PC2 (the firewall notes the ends of bridged connections),
#                   and the flow, still running, must go to the hardware.
#   block           the same against a flow the board routes: PC2 behind wan
#                   as in brlan-wan, counted on the wan device.
#   brlan-wan-noab  an experiment, not a criterion: brlan-wan with the
#                   auto_bridge module unloaded. cmm is restarted around it and
#                   the module is loaded again after. Its outcome does not
#                   count in RESULT. On ASK mono-1.0.7 cmm exits without the
#                   module: cdx has no manual bridge mode.
# The traffic items pass when iperf3 -P 4 reaches MIN_MBPS, "bmchwaccel status"
# says on and counts at least one accelerated connection while iperf3 runs, at
# least one accelerated connection is masqueraded (vlan-vlan: at least one
# accelerated connection), and the per-CPU "rx packets" counters of every test
# port grow by fewer than MAX_CPU_PKTS in WINDOW seconds. Those counters only count packets
# that reached the CPU. The interface totals include what the hardware
# forwarded, so they cannot tell the two apart; pppoe-drop uses the total of
# the wan port to see whether anything still leaves it.
#
# Environment:
#   BOARD        board address on br-lan              (192.168.5.1)
#   SERVER       iperf3 server, PC2                   (192.168.2.10)
#   WAN_ADDR     address given to a wan without one   (192.168.2.1/24)
#   PORTS        board ports whose counters are read  (the wan port and the br-lan ports)
#   DURATION     seconds of iperf3                    (30)
#   IPERF3       iperf3 client command                (iperf3, else iperf3-darwin)
#   VLAN_PARENT  board device that carries the VLANs  (br-lan)
#   VLAN_ID      VLAN of PC1; the board is 192.168.VLAN_ID.1/24      (30)
#   VLAN2_ID     VLAN of PC2 in vlan-vlan, 192.168.VLAN2_ID.1/24     (20)
#   VLAN_CLIENT  address of PC1 in VLAN_ID            (192.168.VLAN_ID.10)
#   VLAN_SERVER  address of PC2 in VLAN2_ID           (192.168.VLAN2_ID.10)
#   PPPOE_USER, PPPOE_PASS  PPPoE login of the board  (hwaccel, hwaccel)
#   PPPOE_SERVER iperf3 server of the PPPoE items     (the peer of the session: PC2)
#   DROP_PORT    port of the second iperf3 server     (5202)
#   FIRMWARE     sysupgrade image of the sysupgrade items
#                (the one under bin/ of this tree)
#   UPGRADE_WAIT seconds the board gets to come back after sysupgrade or a
#                reboot                               (300)
#   SOAK         seconds of the soak item             (3600)
#   SOAK_EVERY   seconds between two looks at the board in the soak item (300)
#   REBOOTS      boots of the reboots item            (20)
#   WEBUI_PORT   HTTPS port of the web UI             (3737)
#   WEBUI_USER, WEBUI_PASS  web UI login of the webui item (admin, none)
#   PC1          address of PC1 on br-lan, for the features items
#                (where the ssh session comes from)
#   IN_RULE      number of the NAT 1:1 rule features-in sets (99)
#   IN_PORT      port PC1 listens on in features-in   (5301)
#   FWD_PORT     wan port forwarded to IN_PORT        (5302)
#   QOS_MBPS     limit bmcqos gets in the qos items   (100)
#   IN_WAIT      seconds features-in waits for PC2    (180)
#   PORTAL_CLIENT  address the portal gave PC1        (the address of PC1 in
#                the network of the portal)
#   PORTAL_USER, PORTAL_PASS  portal login the item adds (hwaccel-test, hwaccel-test)
#   HTTP_PORT    port of the web server on PC2        (8080)
#   HTTP_FILE    file it serves, HTTP_MIN_KB or more  (hwaccel-proxy.bin)
#   MWAN_PORT    br-lan port that becomes wan2 in the mwan items (eth2)
#   MWAN_ADDR    address of wan2, in a /24            (192.168.3.1)
#   SERVER2      the PC of ISP B, on wan2             (192.168.3.10)
#   MWAN_TARGET, MWAN_TARGET2  addresses both ISPs answer for
#                (198.51.100.1, 198.51.100.2)
#   MWAN_WAIT    seconds a Chuyển WAN may take        (90)
#   MWAN_FLOW_PORT  port of a third iperf3 server on both ISPs, bound to
#                MWAN_TARGET2 (iperf3 -s -B), for the UDP flow of mwan-lost,
#                which leaves its server busy (5203)
#   OSPF_PORT, OSPF_PORT2  br-lan ports that become Link định tuyến in the
#                ospf items (eth2, eth4)
#   OSPF_ADDR, OSPF_ADDR2  addresses of the board on them, each in a /24
#                (10.17.1.1, 10.17.2.1)
#   OSPF_TARGET  address the neighbour router announces and answers for
#                (10.17.0.1)
#   OSPF_WAIT    seconds OSPF may take to learn or to withdraw a route (90)
#   OSPF_FLOW_PORT  port of a third iperf3 server on the neighbour router,
#                bound to OSPF_TARGET (iperf3 -s -B), for the UDP flow of
#                ospf-withdrawn (5203)
#   BRIDGE_SERVER  address of PC2 on br-lan in the bridge items
#                (address 20 in the network of BOARD)
set -u

BOARD=${BOARD:-192.168.5.1}
SERVER=${SERVER:-192.168.2.10}
WAN_ADDR=${WAN_ADDR:-192.168.2.1/24}
PORTS=${PORTS:-}
DURATION=${DURATION:-30}
VLAN_PARENT=${VLAN_PARENT:-br-lan}
VLAN_ID=${VLAN_ID:-30}
VLAN2_ID=${VLAN2_ID:-20}
VLAN_CLIENT=${VLAN_CLIENT:-192.168.$VLAN_ID.10}
VLAN_SERVER=${VLAN_SERVER:-192.168.$VLAN2_ID.10}
PPPOE_USER=${PPPOE_USER:-hwaccel}
PPPOE_PASS=${PPPOE_PASS:-hwaccel}
PPPOE_SERVER=${PPPOE_SERVER:-}
DROP_PORT=${DROP_PORT:-5202}
FIRMWARE=${FIRMWARE:-$(ls "$(dirname "$0")"/../../bin/targets/layerscape/armv8_64b/*fsl_ls1046a-rdb-sdboot-squashfs-sysupgrade.bin 2>/dev/null | head -1)}
UPGRADE_WAIT=${UPGRADE_WAIT:-300}
SOAK=${SOAK:-3600}
SOAK_EVERY=${SOAK_EVERY:-300}
REBOOTS=${REBOOTS:-20}
WEBUI_PORT=${WEBUI_PORT:-3737}
WEBUI_USER=${WEBUI_USER:-admin}
WEBUI_PASS=${WEBUI_PASS:-}
PC1=${PC1:-}
IN_RULE=${IN_RULE:-99}
IN_PORT=${IN_PORT:-5301}
FWD_PORT=${FWD_PORT:-5302}
IN_WAIT=${IN_WAIT:-180}
PORTAL_CLIENT=${PORTAL_CLIENT:-}
PORTAL_USER=${PORTAL_USER:-hwaccel-test}
PORTAL_PASS=${PORTAL_PASS:-hwaccel-test}
HTTP_PORT=${HTTP_PORT:-8080}
HTTP_FILE=${HTTP_FILE:-hwaccel-proxy.bin}
QOS_MBPS=${QOS_MBPS:-100}
MWAN_PORT=${MWAN_PORT:-eth2}
MWAN_ADDR=${MWAN_ADDR:-192.168.3.1}
SERVER2=${SERVER2:-192.168.3.10}
MWAN_TARGET=${MWAN_TARGET:-198.51.100.1}
MWAN_TARGET2=${MWAN_TARGET2:-198.51.100.2}
MWAN_WAIT=${MWAN_WAIT:-90}
MWAN_FLOW_PORT=${MWAN_FLOW_PORT:-5203}
OSPF_PORT=${OSPF_PORT:-eth2}
OSPF_PORT2=${OSPF_PORT2:-eth4}
OSPF_ADDR=${OSPF_ADDR:-10.17.1.1}
OSPF_ADDR2=${OSPF_ADDR2:-10.17.2.1}
OSPF_TARGET=${OSPF_TARGET:-10.17.0.1}
OSPF_WAIT=${OSPF_WAIT:-90}
OSPF_FLOW_PORT=${OSPF_FLOW_PORT:-5203}
BRIDGE_SERVER=${BRIDGE_SERVER:-${BOARD%.*}.20}
if [ -z "${IPERF3:-}" ]; then
	IPERF3=iperf3
	command -v iperf3 >/dev/null 2>&1 || IPERF3=iperf3-darwin
fi
command -v "$IPERF3" >/dev/null 2>&1 || { echo "acceptance: $IPERF3 not found" >&2; exit 2; }

KERNEL=6.12.94
MIN_MBPS=900
MAX_CPU_PKTS=1000
WINDOW=10
WARMUP=8
# UDP sent through the PPPoE session that pppoe-drop ends: about 10000 packets
# a second, so a flow that is still forwarded cannot hide under MAX_CPU_PKTS.
DROP_RATE=100M
DROP_LEN=1200
# The flow is killed once the session is back; without that it ends by itself
# after the longest the board script waits for the session to go and come back.
REDIAL_MAX=90
# bridge-block, block: seconds between a feature being told to block and the
# window in which nothing may pass. bridge-neigh: between the sweep and the
# window in which the flow must be in the hardware.
BRIDGE_SETTLE=2
# bridge-neigh: seconds the flow runs before it is read; short, as cron may
# sweep meanwhile.
NEIGH_WARMUP=3
# toggle: seconds the connections get to return to the hardware once
# acceleration is enabled again, seconds the two switches may take together, and
# the seconds at the end of the iperf3 run in which every stream must still
# carry data.
TOGGLE_SETTLE=5
TOGGLE_SWITCH_MAX=30
TOGGLE_TAIL=5
# TCP payload of a full packet on this bench (MTU 1500, timestamps), and the
# share of the packets iperf3 carried that the CPU counters must at least show
# while acceleration is disabled; the rest is what the two clocks may differ.
TOGGLE_MSS=1448
TOGGLE_CPU_SHARE=80
# Seconds without data that iperf3 may have while disabled, and again from the
# start of the last window to its end: a switch may cost the sessions a moment.
TOGGLE_IDLE_MAX=1
# soak: seconds of one iperf3 interval, the first and the last of which are
# compared (a minute: the texts of the item say so); the percent the last may be below the first, which is what two
# minutes of the same accelerated run differ by; and the seconds the last look
# at the board ends before iperf3 does.
SOAK_SPAN=60
SOAK_DROP=2
SOAK_MARGIN=10
# Kernel lines that tell of trouble, from anything, as the kernel writes them;
# and from the ASK modules and the FMan and DPAA drivers, any line that names
# an error, in lower or upper case.
KERNEL_TROUBLE='BUG:|Oops|WARNING:|Call trace|Unable to handle|Out of memory|soft lockup|blocked for more than|rcu.*stall'
KERNEL_ASK='(cdx|fci|auto_bridge|fman|dpaa|dpa_).*(error|fail|timeout|invalid)'
# Seconds between two looks at a board that is installing a firmware or
# rebooting.
UPGRADE_POLL=5
# Where the image is put on the board; sysupgrade wants it under /tmp.
UPGRADE_FILE=/tmp/hwaccel-firmware.bin
# webui: the pages of the firewall features, and the requests they start
# with. A request with a body is a POST.
WEBUI_PAGES="/ /ui/firewall/firewall /ui/mac_filter/mac_filter /ui/client_control/client_control /ui/ddos/ddos_protect /ui/network/nat_11 /ui/network/nat"
WEBUI_APIS='/api/macfilter/info /api/client-control /api/ddos/status /api/nat11/get /api/nat /get-firewall-from-table={"tableName":"filter"} /get-firewall-from-table={"tableName":"nat"}'
# features: pings sent to the board, and then through it, at 3 a second, the
# most of them that may be answered with ddos_protect enabled (it lets 1 a
# second through after a burst of 5), and the fewest that must be without it.
FLOOD_PINGS=24
FLOOD_MAX=18
FLOOD_MIN=22
# features: the client_control rule of the item, and seconds between two
# looks at the board in features-in.
FEATURE_RULE=hwaccel-test
IN_POLL=3
# proxy: the smallest file the item takes, well above the size from which the
# HTTP file tracker logs a transfer (64 KiB), and the most seconds the board
# waits for the tracker to write its line after a download.
HTTP_MIN_KB=1024
TRACK_WAIT=15
# ospf: the OSPF cost of the first Link định tuyến and of the second, the
# seconds a change of cost may take to reach the kernel, the seconds the
# hardware gets to follow a route that changed before the ports are read, the
# seconds the iperf3 run of ospf-moved lasts beyond its last look at the
# board, in which every stream must still carry data, and the seconds without
# data that run may have.
OSPF_COST=10
OSPF_COST_HIGH=100
OSPF_MOVE_WAIT=20
OSPF_SETTLE=2
OSPF_TAIL=10
OSPF_IDLE_MAX=1
# stats: the rate of the UDP flow beside the iperf3 run (its only job is to
# put a UDP entry in the table; it need not be accelerated); the number of
# connections a count the web UI reports may differ from the kernel's table
# the item reads moments later by, since both keep changing; and the band the
# interface bytes of a window must grow by, as a percent of the iperf3
# payload of that window. A full TCP packet carries 1448 bytes of payload in
# 1514 on the cable, so the bytes sit a little above the payload (about 105
# percent); the band is wide enough on both sides to absorb the second or so
# by which the board's two reads can be skewed from iperf3's window (at a
# gigabit a second that is about a tenth of the payload). What the band is
# there to catch is a counter blind to accelerated traffic, which stays near
# zero while gigabits flow — far below the low edge however wide it is.
STATS_UDP_RATE=1M
STATS_SLACK=5
STATS_LOW=85
STATS_HIGH=125
# The port of an iperf3 server that is given none.
IPERF_PORT=5201
# Port roles of the 24.10 firmware. A LAN_OPTIONAL port may be missing from
# br-lan: the image leaves out a port that cannot be opened (no PHY).
WAN_PORT=eth0
LAN_PORTS="eth1 eth2 eth4 eth5"
LAN_OPTIONAL="eth3"
# The 10G copper port (MAC9): the end of its device name under /sys/class/net,
# and its PHY on the MDIO bus.
PHY_PORT_DEVICE=ethernet@8
PHY_MDIO_DEVICE=0x0000000001afd000:00

[ "$DURATION" -ge $((WARMUP + WINDOW + 2)) ] 2>/dev/null || {
	echo "acceptance: DURATION must be at least $((WARMUP + WINDOW + 2)) s, the counters are read while iperf3 runs" >&2
	exit 2
}
[ "$SOAK" -ge $((2 * SOAK_SPAN)) ] 2>/dev/null || {
	echo "acceptance: SOAK must be at least $((2 * SOAK_SPAN)) s, its first and last minute are compared" >&2
	exit 2
}
[ "$SOAK_EVERY" -gt $WINDOW ] 2>/dev/null || {
	echo "acceptance: SOAK_EVERY must be more than $WINDOW s, the time one look at the board takes" >&2
	exit 2
}
[ "$REBOOTS" -ge 1 ] 2>/dev/null || {
	echo "acceptance: REBOOTS must be a number, at least 1" >&2
	exit 2
}
vlans_ok=1
for id in "$VLAN_ID" "$VLAN2_ID"; do
	[ "$id" -ge 3 ] 2>/dev/null && [ "$id" -le 254 ] || vlans_ok=0
done
[ $vlans_ok -eq 1 ] && [ "$VLAN_ID" != "$VLAN2_ID" ] || {
	echo "acceptance: VLAN_ID and VLAN2_ID must be two different numbers from 3 to 254" >&2
	exit 2
}

# The board address of a VLAN is 192.168.<id>.1/24, so a VLAN item cannot run
# with a VLAN whose /24 is that of br-lan (BOARD) or of wan (WAN_ADDR).
vlan_clash() {
	lan_net=$(echo "$BOARD" | cut -d. -f1-3)
	wan_net=$(echo "${WAN_ADDR%/*}" | cut -d. -f1-3)
	for id in "$VLAN_ID" "$VLAN2_ID"; do
		case "192.168.$id" in
		"$lan_net") echo "VLAN $id would be 192.168.$id.0/24, the network of br-lan (BOARD $BOARD)"; return ;;
		"$wan_net") echo "VLAN $id would be 192.168.$id.0/24, the network of wan (WAN_ADDR $WAN_ADDR)"; return ;;
		esac
	done
}

TMP=$(mktemp -d)
net_key=
net_temporary=0
net_failed=
wan_dev=
wan_addr=
wan_peer=
ab_unloaded=0
dropping=0
disabled=0
featuring=0
at_portal=0
proxying=0
shaping=0
marking=0
multiwan=0
routing=0
bridging=0
bridge_in=
bridge_out=
block_server=
beside_pid=
ospf_links=
ospf_addrs=
ports_given=
traffic_port=
listen_pid=
iperf_pid=
probe_pid=
ping_pid=
rc=0

# With syslog-ng in the image (as on the 24.10 firmware) the log is in two
# places: logd keeps what procd and the kernel said and everything up to the
# start of syslog-ng, and /var/log/messages, which is all that "logread" then
# shows, has the rest. Every board script gets a logread that gives both.
BOARD_LOGREAD='logread() {
	[ ! -x /usr/libexec/logread-ubox ] || /usr/libexec/logread-ubox "$@"
	[ "$(readlink -f /sbin/logread)" = /usr/libexec/logread-ubox ] || command logread "$@" 2>/dev/null
}'
board() {
	ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$BOARD" "$BOARD_LOGREAD
$1"
}

cleanup() {
	# The board is being put back; a second Ctrl-C must not cut that short.
	trap '' INT TERM
	[ -n "$iperf_pid" ] && kill "$iperf_pid" 2>/dev/null
	[ -n "$beside_pid" ] && kill "$beside_pid" 2>/dev/null
	[ -n "$probe_pid" ] && kill "$probe_pid" 2>/dev/null
	[ -n "$ping_pid" ] && kill "$ping_pid" 2>/dev/null
	[ -n "$listen_pid" ] && kill "$listen_pid" 2>/dev/null
	[ $featuring -eq 1 ] && feature end >/dev/null 2>&1
	[ $at_portal -eq 1 ] && portal end >/dev/null 2>&1
	[ $proxying -eq 1 ] && proxy end >/dev/null 2>&1
	[ $shaping -eq 1 ] && qos off >/dev/null 2>&1
	[ $marking -eq 1 ] && mark off >/dev/null 2>&1
	[ $multiwan -eq 1 ] && mwan end >/dev/null 2>&1
	[ $routing -eq 1 ] && ospf end >/dev/null 2>&1
	[ $bridging -eq 1 ] && bridge end >/dev/null 2>&1
	[ $ab_unloaded -eq 1 ] && autobridge load >/dev/null
	[ $dropping -eq 1 ] && board "$(drop_env)
$(undrop_script)"
	[ $disabled -eq 1 ] && board "# hwaccel:enable
bmchwaccel enable" >/dev/null 2>&1
	[ $net_temporary -eq 1 ] && board "$(unnet_script)"
	rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- scripts run on the board (busybox ash)

# A board function, copied into the board scripts that need it: the link of a
# port (/sys/class/net/<port>), "speed N" (-1 without a link) and "changes N",
# the number of times its link went up or down since the boot.
links_fn() { cat <<'EOF'
links() { echo "speed $(cat "$1/speed" 2>/dev/null || echo -) changes $(cat "$1/carrier_changes" 2>/dev/null || echo -)"; }
EOF
}

# A board function: of the kernel lines it reads, those that tell of trouble.
trouble_fn() { cat <<EOF
trouble() { awk '/$KERNEL_TROUBLE/ || tolower(\$0) ~ /$KERNEL_ASK/'; }
EOF
}

info_script() { links_fn; cat <<'EOF'
# hwaccel:info
uname -a
dmesg | grep -E 'FMan-Controller code|cdx: |start_dpa_app|cdx_ipsec_init|fsl_mac.*(probe|FMan MAC)|temporary MAC|Aquantia' | head -30
logread | grep -i -E 'cmm|bmcHwAccel' | tail -8
for d in /sys/class/net/eth*; do
	echo "${d##*/} $(basename "$(readlink "$d/device")") $(cat "$d/address") $(links "$d")"
done
ip -br link
exit 0
EOF
}

boot_script() { cat <<'EOF'
# hwaccel:boot
echo "kernel=$(uname -r)"
echo "cdx=$(dmesg | grep 'cdx: FMAN firmware' | sed -e 's/^\[[^]]*\] *//' | tail -1)"
[ -c /dev/cdx_ctrl ] && echo cdx_ctrl=yes || echo cdx_ctrl=no
echo "status=$(bmchwaccel status 2>&1 | head -1)"
# How often the daemon was started since its service was: above 1, it died.
echo "starts=$(cat /var/run/bmcHwAccel/daemon-starts 2>/dev/null)"
echo "logged=$(logread | grep 'bmcHwAccel: ' | tail -1)"
# Without the control device the module did not stay loaded: show why.
[ -c /dev/cdx_ctrl ] && exit 0
echo "@log"
dmesg | sed -n '/cdx: /,$p' | grep -v -E 'br-lan|8021q|entered .* (state|mode)' | head -100
logread | grep -E 'kmodloader|cmm|bmcHwAccel' | head -20
EOF
}

# The kernel lines of the PHY firmware upload and of what waited for it: FMan,
# the MACs and the ports are probed once the upload is done.
boottime_script() { cat <<EOF
# hwaccel:boottime
PHY_PORT_DEVICE=$PHY_PORT_DEVICE
PHY_MDIO_DEVICE=$PHY_MDIO_DEVICE
EOF
cat <<'EOF'
echo "@kernel"
dmesg | grep -E 'MDC frequency|Aquantia|FMan-Controller code|FMan MAC address|fsl_dpa: Probed interface|br-lan: port .* entered forwarding state'
echo "@phy"
for d in /sys/class/net/*; do
	case "$(readlink "$d/device")" in *"$PHY_PORT_DEVICE") ;; *) continue ;; esac
	echo "port=${d##*/}"
	# A port that is down has no phydev link: its PHY is then looked up on
	# the MDIO bus.
	phy=$(readlink "$d/phydev/driver" 2>/dev/null) ||
		phy=$(readlink "/sys/bus/mdio_bus/devices/$PHY_MDIO_DEVICE/driver" 2>/dev/null)
	echo "phy=${phy##*/}"
done
exit 0
EOF
}

firewall_script() { cat <<'EOF'
# hwaccel:firewall
[ -x /sbin/fw3 ] && echo fw3=yes || echo fw3=no
[ -e /sbin/fw4 ] && echo fw4=yes || echo fw4=no
echo "iptables=$(iptables -V 2>&1 | head -1)"
echo "zones=$(iptables -S 2>/dev/null | grep -c zone_)"
echo "masq=$(iptables -t nat -S 2>/dev/null | grep -c MASQUERADE)"
echo "flow_uci=$(uci -q get firewall.@defaults[0].flow_offloading)"
echo "flow_mod=$(lsmod | grep -c -E '^(nf_flow_table|xt_FLOWOFFLOAD) ')"
EOF
}

ports_script() { cat <<'EOF'
# hwaccel:ports
echo "wan=$(uci -q get network.wan.device)"
echo "lan=$(uci -q get network.lan.device)"
echo "members=$(ls /sys/class/net/br-lan/brif 2>/dev/null | tr '\n' ' ')"
EOF
}

# ITEM (mac or mac-temp) comes from the caller. The address of every port, how
# it was assigned (1: made up by the kernel) and the ports the kernel warned
# about, in its own log and in syslog. mac-temp also keeps the temporary MACs
# of this boot and of the boot before it where they survive a reboot.
macs_script() { cat <<'EOF'
# hwaccel:macs
for d in /sys/class/net/eth*; do
	echo "port ${d##*/} $(cat "$d/address") $(cat "$d/addr_assign_type")"
done
# "... eth0: ... using temporary MAC 0a:.. (stable, ...)" -> "eth0 0a:.. stable"
warned() {
	sed -n 's/.* \(eth[0-9]*\): .*using temporary MAC \([0-9a-f:]*\) (\([a-z]*\).*/\1 \2 \3/p' | sort -u
}
dmesg | warned | sed 's/^/kernel /'
logread | warned | sed 's/^/syslog /'
[ "$ITEM" = mac-temp ] || exit 0
state=/etc/hwaccel-temp-mac
boot=$(cat /proc/sys/kernel/random/boot_id)
now=$(dmesg | warned | awk '{ printf "%s%s=%s", sep, $1, $2; sep = " " }')
[ -n "$now" ] || exit 0
grep -q "^$boot " $state 2>/dev/null || echo "$boot $now" >> $state
tail -n 2 $state > $state.new && mv $state.new $state
echo "current=$now"
[ "$(wc -l < $state)" -lt 2 ] || echo "previous=$(head -n 1 $state | cut -d' ' -f2-)"
EOF
}

# WAN (plain, pppoe or keep), VLANS, VLAN_PARENT, WAN_ADDR, PPPOE_USER and
# PPPOE_PASS come from the caller. Brings the board to the layout an item needs
# and changes nothing that is already there:
#   plain  wan as configured; a wan that gets no address is given WAN_ADDR
#   pppoe  wan dials PPPoE
#   keep   wan is left alone and not waited for
# one VLAN interface in the lan zone per id in VLANS, and the security mode
# MODE on a board that has security modes (the script of the web UI switches,
# and keeps the port of this ssh session up while it does). The first change
# saves the network and firewall configuration; the copy marks a temporary
# layout, also one left behind by a run that was killed or by a reboot in the
# middle of a run, and it is kept where it survives a reboot.
net_script() { cat <<'EOF'
# hwaccel:net
orig=/etc/hwaccel-orig
dev=$(uci -q get network.wan.device)
changed=
addr() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{ print $4; exit }'; }
save() { [ -d $orig ] || { mkdir $orig && cp /etc/config/network /etc/config/firewall $orig/; }; }
mode() { uci -q get system.@system[0].security_mode; }
apply() {
	[ -n "$changed" ] || return 0
	uci commit network
	uci commit firewall
	/etc/init.d/network reload
	/etc/init.d/firewall reload >/dev/null 2>&1
	changed=
}
# The wan options this script sets, back to what the saved configuration has.
wan_orig() {
	for o in proto ipaddr gateway username password; do
		if v=$(uci -q -c $orig get network.wan.$o); then
			uci set network.wan.$o="$v"
		else
			uci -q delete network.wan.$o
		fi
	done
	changed=1
}
wan_static() {
	save
	uci set network.wan.proto=static
	uci set network.wan.ipaddr="$WAN_ADDR"
	# With a default route: CoovaChilli only starts on a wan that has one.
	uci set network.wan.gateway="$WAN_GW"
	changed=1
}

l3=
case "$WAN" in
plain)
	l3=$dev
	if [ -f $orig/wan-static ]; then
		# An earlier call found that wan gets no address by itself.
		[ "$(uci -q get network.wan.proto)" = static ] || { wan_orig; wan_static; }
	else
		if [ -d $orig ] && [ "$(uci -q get network.wan.proto)" != "$(uci -q -c $orig get network.wan.proto)" ]; then
			# wan dials PPPoE for an earlier item: see what its own
			# configuration gets.
			wan_orig
			apply
			i=0
			while [ $i -lt 10 ] && [ -z "$(addr "$dev")" ]; do sleep 1; i=$((i + 1)); done
		fi
		if [ -z "$(addr "$dev")" ]; then
			wan_static
			touch $orig/wan-static
			echo "note=wan $dev has no address from DHCP; using $WAN_ADDR until the script ends"
		fi
	fi
	;;
pppoe)
	l3=pppoe-wan
	if [ "$(uci -q get network.wan.proto)" != pppoe ]; then
		save
		uci set network.wan.proto=pppoe
		uci set network.wan.username="$PPPOE_USER"
		uci set network.wan.password="$PPPOE_PASS"
		uci -q delete network.wan.ipaddr
		uci -q delete network.wan.gateway
		changed=1
		echo "note=wan dials PPPoE on $dev as $PPPOE_USER until the script ends"
	fi
	;;
esac

zone=$(uci show firewall | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'\$/\1/p" | head -1)
for vid in $VLANS; do
	[ -z "$(uci -q get network.vlan$vid)" ] || continue
	save
	uci set network.vlan$vid=interface
	uci set network.vlan$vid.device="$VLAN_PARENT.$vid"
	uci set network.vlan$vid.proto=static
	uci set network.vlan$vid.ipaddr="192.168.$vid.1"
	uci set network.vlan$vid.netmask=255.255.255.0
	[ -z "$zone" ] || uci add_list "firewall.$zone.network=vlan$vid"
	changed=1
	echo "note=VLAN $vid is $VLAN_PARENT.$vid with 192.168.$vid.1/24 in the lan zone until the script ends"
done
apply

was=$(mode)
if [ -n "$MODE" ] && [ -n "$was" ] && [ "$was" != "$MODE" ]; then
	save
	[ -f $orig/security-mode ] || echo "$was" > $orig/security-mode
	said=$(BMC_ADMIN_IP=${SSH_CONNECTION%% *} bash /etc/bmcweb/backend/scripts/firewall/bmcfido.sh set mode "$MODE" 2>&1 | tr -d '\n' | cut -c1-160)
	echo "note=security mode $MODE instead of $was until the script ends"
	case "$said" in *'"status": 0'*|*'"status":0'*) ;; *) echo "mode_said=$said" ;; esac
fi
tun=$(uci -q get chilli.@chilli[0].tundev)

# fw3 adds the rules of a zone when its interface comes up, and the portal
# starts once wan has its address.
i=0
while [ $i -lt 30 ]; do
	ready=1
	[ "$(mode)" != nac ] || [ "$MODE" != nac ] || [ -n "$(addr "${tun:-tun0}")" ] || ready=0
	if [ -n "$l3" ]; then
		[ -n "$(addr "$l3")" ] && iptables -t nat -S 2>/dev/null | grep -q -- "-o $l3 " || ready=0
	fi
	for vid in $VLANS; do
		[ -n "$(addr "$VLAN_PARENT.$vid")" ] && iptables -S 2>/dev/null | grep -q -- "-i $VLAN_PARENT.$vid " || ready=0
	done
	[ $ready -eq 1 ] && break
	sleep 1
	i=$((i + 1))
done
[ -d $orig ] && echo temporary=yes
echo "mode=$(mode)"
echo "dev=$dev"
[ -z "$l3" ] || echo "addr=$(addr "$l3")"
[ "$WAN" != pppoe ] || echo "peer=$(ip -4 -o addr show dev $l3 2>/dev/null | sed -n 's|.* peer \([0-9.]*\).*|\1|p' | head -1)"
for vid in $VLANS; do
	echo "vlan$vid=$(addr "$VLAN_PARENT.$vid")"
done
EOF
}

unnet_script() { cat <<'EOF'
# hwaccel:unnet
orig=/etc/hwaccel-orig
[ -d $orig ] || exit 0
was=$(cat $orig/security-mode 2>/dev/null)
cp $orig/network $orig/firewall /etc/config/ && rm -r $orig
/etc/init.d/network reload
/etc/init.d/firewall reload >/dev/null 2>&1
[ -z "$was" ] ||
	BMC_ADMIN_IP=${SSH_CONNECTION%% *} bash /etc/bmcweb/backend/scripts/firewall/bmcfido.sh set mode "$was" >/dev/null 2>&1
EOF
}

flush_script() { cat <<'EOF'
# hwaccel:flush
conntrack -F >/dev/null 2>&1
exit 0
EOF
}

# ACTION (unload or load) comes from the caller. cmm keeps a socket of the
# module open, so it is stopped around the change.
autobridge_script() { cat <<'EOF'
# hwaccel:autobridge
[ "$ACTION" = load ] || [ -n "$(pidof cmm)" ] || { echo cmm_before=no; exit 0; }
/etc/init.d/cmm stop
sleep 1
if [ "$ACTION" = unload ]; then rmmod auto_bridge; else modprobe auto_bridge; fi
/etc/init.d/cmm start
sleep 5
lsmod | grep -q '^auto_bridge ' && echo module=loaded || echo module=absent
echo "cmm=$(pidof cmm | cut -d' ' -f1)"
[ -n "$(pidof cmm)" ] && exit 0
echo "@log"
logread | grep -i cmm | tail -12
dmesg | tail -12
EOF
}

# ACTION, SERVER, PC1, MAC, RULE, IN, OUT, WINDOW and SETTLE come from the
# caller. PC1 is on a br-lan port; PC2 at SERVER is on another one (bridge,
# bridge-block) or behind wan (block).
#   start     what the board knows of the two PCs (MAC address and br-lan
#             port of each) and how the daemon runs. A rule that a killed run
#             left behind is taken away first.
#   macfilter, clientctl  the flow from MAC, coming in on the port IN and
#             leaving on OUT, is read over WINDOW seconds: packets that left
#             OUT (the total of a port includes what the hardware sent) and
#             packets of IN that reached the CPU. Then the feature is told to
#             block MAC, by its own script as the web UI does it: the script
#             also has the connections of that machine taken out of the
#             hardware (bmchwaccel sweep). After SETTLE seconds the flow is
#             read again, with the packets the rule counted, and the rule is
#             taken away.
#   service, fido  the same against the two features that drop by address
#             and that nothing but cron sweeps for: so the item runs the
#             sweep itself. service: the address of SERVER is put in the
#             ipset of the first service of /etc/ipset.conf, where DNS would
#             put it, with the two rules bmcfirewall writes into BMC_SVC4
#             for a service blocked for every machine. fido: bmcfido builds
#             its own rules (reload_rules, the security mode being fido for
#             that call only), both PCs are put in the set of the machines
#             signed in, a sweep sees that set, and then PC1 is taken out of
#             it, as when its time is up.
#   neigh-gone   the neighbour entry of SERVER is deleted on the board
#   neigh     the flow is read over WINDOW seconds, the board is swept
#             (which has the kernel resolve the machines that talk through
#             the bridge), and the flow is read again
#   end       takes away a rule that is left
bridge_script() { cat <<'EOF'
# hwaccel:bridge
S=/etc/bmcweb/backend/scripts
did=/tmp/hwaccel-bridge-did
running() {
	pid=$(pidof cmm | cut -d' ' -f1)
	[ -z "$pid" ] || tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
}
state() {
	case " $(running) " in
	"  ") echo daemon=none ;;
	*" -B "*) echo daemon=cpu ;;
	*) echo daemon=hardware ;;
	esac
	echo "cmdline=$(running)"
	echo "status=$(bmchwaccel status 2>&1 | head -1)"
}
unblock() {
	for f in $(cat $did 2>/dev/null); do
		case "$f" in
		macfilter:*) bash $S/firewall/macfilter.sh remove "${f#macfilter:}"; bash $S/firewall/macfilter.sh disable ;;
		client:*) bash $S/firewall/client_control.sh del "${f#client:}" ;;
		service:*)
			f=${f#service:}
			iptables -w -D BMC_SVC4 -p tcp -m set --match-set "${f%%:*}" dst -j REJECT --reject-with tcp-reset
			iptables -w -D BMC_SVC4 -p udp -m set --match-set "${f%%:*}" dst -j DROP
			ipset del "${f%%:*}" "${f#*:}"
			;;
		fido)
			# Not fido any more: bmcfido takes its rules and sets away.
			/etc/init.d/bmcfido reload_rules
			bmchwaccel sweep
			;;
		esac >/dev/null 2>&1
	done
	rm -f $did
}
mac_of() { [ -n "$1" ] && ip -4 neigh show "$1" 2>/dev/null | sed -n 's/.* lladdr \([0-9a-fA-F:]*\).*/\1/p' | head -1; }
# The br-lan port the bridge learned a MAC address on.
port_of() {
	no=$(brctl showmacs br-lan 2>/dev/null | awk -v mac="$1" 'tolower($2) == tolower(mac) && $3 == "no" { print $1; exit }')
	[ -n "$no" ] || return 0
	for p in /sys/class/net/br-lan/brif/*; do
		[ "$(($(cat "$p/port_no")))" != "$no" ] || echo "${p##*/}"
	done
}
case "$ACTION" in
start)
	unblock
	pc1=${PC1:-${SSH_CONNECTION%% *}}
	# Right after the security mode was switched a host may take a few
	# seconds to answer (seen on the board): up to eight tries each.
	for host in $pc1 "$SERVER"; do
		i=0
		while [ $i -lt 8 ] && ! ping -c 1 -W 1 "$host" >/dev/null 2>&1; do i=$((i + 1)); done
	done
	m1=$(mac_of "$pc1"); m2=$(mac_of "$SERVER")
	echo "pc1=$pc1"
	echo "pc1_mac=$m1"
	echo "pc2_mac=$m2"
	[ -z "$m1" ] || echo "pc1_port=$(port_of "$m1")"
	[ -z "$m2" ] || echo "pc2_port=$(port_of "$m2")"
	echo "nf_call=$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null)"
	state
	;;
macfilter|clientctl|service|fido)
	# The scripts of the features keep MAC addresses in upper case.
	MAC=$(echo "$MAC" | tr a-f A-F)
	rx() { ethtool -S "$IN" 2>/dev/null | awk '/rx packets \[TOTAL\]/ { sub(/.*:[ \t]*/, ""); print; exit }'; }
	tx() { cat "/sys/class/net/$OUT/statistics/tx_packets" 2>/dev/null; }
	grew() { if [ -n "$2" ] && [ -n "$3" ]; then echo "$1=$(($3 - $2))"; else echo "$1="; fi; }
	c0=$(rx); t0=$(tx)
	sleep "$WINDOW"
	c1=$(rx); t1=$(tx)
	grew carried "$t0" "$t1"
	grew cpu "$c0" "$c1"
	unblock
	if [ "$ACTION" = macfilter ]; then
		chain=MAC_FILTER
		echo "macfilter:$MAC" >> $did
		bash $S/firewall/macfilter.sh enable >/dev/null 2>&1
		bash $S/firewall/macfilter.sh mode blacklist >/dev/null 2>&1
		said=$(bash $S/firewall/macfilter.sh add "$MAC" 2>&1)
	elif [ "$ACTION" = clientctl ]; then
		chain=CLIENTCTL
		echo "client:$RULE" >> $did
		said=$(bash $S/firewall/client_control.sh set "$RULE" "$MAC" 00:00 23:59 Mon,Tue,Wed,Thu,Fri,Sat,Sun 2>&1)
	elif [ "$ACTION" = service ]; then
		chain=BMC_SVC4
		set=$(awk -F/ '!/^#/ && NF == 2 { split($2, name, ","); print name[1]; exit }' /etc/ipset.conf 2>/dev/null)
		if [ -z "$set" ] || ! ipset -q list -n "$set" >/dev/null; then
			said="no ipset of a service (${set:-none in /etc/ipset.conf})"
		elif ! iptables -w -C FORWARD -j BMC_SVC4 2>/dev/null; then
			# bmcfirewall makes the chain when it starts; a firewall restart
			# takes it away, and nothing puts it back (seen on the board).
			said="the chain BMC_SVC4 of bmcfirewall is not in FORWARD: no blocked service is in force on this board (a firewall restart since bmcfirewall started?)"
		else
			echo "service:$set:$SERVER" >> $did
			ipset -exist add "$set" "$SERVER"
			iptables -w -A BMC_SVC4 -p tcp -m set --match-set "$set" dst -j REJECT --reject-with tcp-reset
			iptables -w -A BMC_SVC4 -p udp -m set --match-set "$set" dst -j DROP
			said=$(bmchwaccel sweep 2>&1)
		fi
	elif [ "$(uci -q get system.@system[0].security_mode)" = fido ]; then
		chain=BMC_FIDO
		said="the security mode is fido: the rules of bmcfido are in use"
	else
		chain=BMC_FIDO
		echo fido >> $did
		uci set system.@system[0].security_mode=fido
		/etc/init.d/bmcfido reload_rules >/dev/null 2>&1
		uci revert system
		for host in ${PC1:-${SSH_CONNECTION%% *}} "$SERVER"; do ipset -exist add authorized_table "$host" 2>/dev/null; done
		bmchwaccel sweep >/dev/null 2>&1
		ipset del authorized_table "${PC1:-${SSH_CONNECTION%% *}}" 2>/dev/null
		said=$(bmchwaccel sweep 2>&1)
	fi
	case "$ACTION" in
	service) echo "rules=$(iptables -w -S $chain 2>/dev/null | grep -c -- "-p udp .*--match-set ${set:-none} dst .*-j DROP")" ;;
	fido) echo "rules=$(iptables -w -S $chain 2>/dev/null | grep -c -- "--match-set authorized_table src -j RETURN")" ;;
	*) echo "rules=$(iptables -w -S $chain 2>/dev/null | grep -c -i -- "--mac-source $MAC .*-j DROP")" ;;
	esac
	echo "said=$(echo "$said" | tr -d '\n' | tr -s ' ' | cut -c1-160)"
	sleep "$SETTLE"
	c2=$(rx); t2=$(tx)
	sleep "$WINDOW"
	c3=$(rx); t3=$(tx)
	grew passed "$t2" "$t3"
	grew cpu_under "$c2" "$c3"
	# The rule that drops is the last one of its chain where there are several.
	echo "counted=$(iptables -w -nvxL $chain 2>/dev/null | awk '$3 == "DROP" { n = $1 } END { print n }')"
	unblock
	;;
neigh-gone)
	ip neigh del "$SERVER" dev br-lan 2>/dev/null
	echo "entry=$(ip -4 neigh show "$SERVER" | grep -c lladdr)"
	;;
neigh)
	rx() { ethtool -S "$IN" 2>/dev/null | awk '/rx packets \[TOTAL\]/ { sub(/.*:[ \t]*/, ""); print; exit }'; }
	tx() { cat "/sys/class/net/$OUT/statistics/tx_packets" 2>/dev/null; }
	grew() { if [ -n "$2" ] && [ -n "$3" ]; then echo "$1=$(($3 - $2))"; else echo "$1="; fi; }
	echo "entry=$(ip -4 neigh show "$SERVER" | grep -c lladdr)"
	c0=$(rx); t0=$(tx)
	sleep "$WINDOW"
	c1=$(rx); t1=$(tx)
	grew carried "$t0" "$t1"
	grew cpu "$c0" "$c1"
	echo "entry_then=$(ip -4 neigh show "$SERVER" | grep -c lladdr)"
	echo "noted=$(ipset -q test bmchwaccel_bridged "$SERVER" 2>/dev/null && echo 1 || echo 0)"
	echo "said=$(bmchwaccel sweep 2>&1 | tr -d '\n' | cut -c1-300)"
	sleep "$SETTLE"
	echo "entry_swept=$(ip -4 neigh show "$SERVER" | grep -c lladdr)"
	c2=$(rx); t2=$(tx)
	sleep "$WINDOW"
	c3=$(rx); t3=$(tx)
	grew passed "$t2" "$t3"
	grew cpu_under "$c2" "$c3"
	echo "cron=$(grep -c 'bmchwaccel sweep' /etc/crontabs/root 2>/dev/null)"
	;;
end)
	unblock
	state
	;;
esac
exit 0
EOF
}

# ITEM, PORTS and WINDOW come from the caller. Without PORTS the counters of
# the wan port and of every br-lan port are read, with the link of each.
sample_script() { links_fn; cat <<'EOF'
# hwaccel:sample
[ -n "$PORTS" ] || PORTS="$(uci -q get network.wan.device) $(ls /sys/class/net/br-lan/brif | tr '\n' ' ')"
echo "@ports $PORTS"
snap() {
	for p in $PORTS; do
		echo "@$1 $p"
		ethtool -S "$p" | grep 'rx packets'
		# The total of a port includes what the hardware sent.
		echo "tx $1 $p $(cat /sys/class/net/$p/statistics/tx_packets 2>/dev/null)"
	done
}
snap before
sleep "$WINDOW"
snap after
for p in $PORTS; do echo "link $p $(links /sys/class/net/$p)"; done
echo "status=$(bmchwaccel status 2>&1 | head -1)"
# Connections whose conntrack mark has the bit that keeps them on the CPU.
echo "kept=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^mark=/ && int(substr($i, 6) / 65536) % 2) n++ } END { print n + 0 }' /proc/net/nf_conntrack)"
echo "@conntrack"
grep PERMANENT /proc/net/nf_conntrack | head -64
EOF
}

# PORTS and WINDOW come from the caller. The dashboard numbers under traffic:
# the script the web UI calls is read twice, WINDOW apart, its JSON flattened
# onto one line each ("webui_before="/"webui_after="); the kernel's own
# connection counts are read once between them (conntrack -L, as the script
# does), and the accelerated connections and the status are read at the end.
# The script lives where the 24.10 firmware puts it; the item needs the web
# UI package (ticket 12).
stats_script() { cat <<'EOF'
# hwaccel:stats
S=/etc/bmcweb/backend/scripts/network/get_net_stats.sh
[ -n "$PORTS" ] || PORTS="$(uci -q get network.wan.device) $(ls /sys/class/net/br-lan/brif | tr '\n' ' ')"
echo "wan_dev=$(uci -q get network.wan.device)"
echo "@ports $PORTS"
if [ ! -r "$S" ]; then
	echo "no_script=yes"
	exit 0
fi
# Flatten the multi-line JSON so the harness reads it off one "key=" line.
echo "webui_before=$(bash "$S" 2>/dev/null | tr -d '\n' | tr -s ' ')"
sleep "$WINDOW"
echo "webui_after=$(bash "$S" 2>/dev/null | tr -d '\n' | tr -s ' ')"
# The kernel's own table, read right after the second answer so a count the
# web UI reported is compared against the table of the same moment.
echo "ct_total=$(conntrack -L 2>/dev/null | grep -c .)"
echo "ct_tcp=$(conntrack -L -p tcp 2>/dev/null | grep -c .)"
echo "ct_udp=$(conntrack -L -p udp 2>/dev/null | grep -c .)"
echo "status=$(bmchwaccel status 2>&1 | head -1)"
echo "@conntrack"
grep PERMANENT /proc/net/nf_conntrack | head -64
EOF
}

# ACTION (on or off) and QOS_KBIT come from the caller. "on" keeps the bmcqos
# configuration of the board aside and turns bmcqos on for the device of wan,
# at the same rate both ways; "off" stops it and puts the configuration back.
# Both answer with the qdisc on the device and on its IFB, and with what
# bmchwaccel then says.
qos_script() { cat <<'EOF'
# hwaccel:qos
orig=/etc/hwaccel-orig-bmcqos
. /lib/functions/network.sh
network_flush_cache
network_get_device dev wan
[ -n "$dev" ] || dev=$(uci -q get network.wan.device)
case "$ACTION" in
on)
	[ -e $orig ] || cp /etc/config/bmcqos $orig
	uci -q batch <<EOB
set bmcqos.global.enabled='1'
set bmcqos.settings.WAN='$dev'
set bmcqos.settings.UPRATE='$QOS_KBIT'
set bmcqos.settings.DOWNRATE='$QOS_KBIT'
EOB
	uci commit bmcqos
	/etc/init.d/bmcqos restart >/dev/null 2>&1
	sleep 2
	;;
off)
	/etc/init.d/bmcqos stop >/dev/null 2>&1
	[ ! -e $orig ] || { cp $orig /etc/config/bmcqos; rm -f $orig; }
	[ "$(uci -q get bmcqos.global.enabled)" != 1 ] || /etc/init.d/bmcqos start >/dev/null 2>&1
	;;
esac
echo "dev=$dev"
echo "up=$(tc qdisc show dev "$dev" root 2>&1 | head -1)"
echo "down=$(tc qdisc show dev "ifb-$dev" root 2>&1 | head -1)"
echo "status=$(bmchwaccel status 2>&1 | head -1)"
EOF
}

# ACTION (on or off) and PORT come from the caller: a rule that gives every
# connection to PORT the conntrack mark bit of what is kept on the CPU. The
# answer has the number of such rules and whether the running daemon was
# given the rule that keeps marked connections out of the hardware.
mark_script() { cat <<'EOF'
# hwaccel:mark
rule="FORWARD -p tcp --dport $PORT -j CONNMARK --set-xmark 0x10000/0x10000"
case "$ACTION" in
on) iptables -w -t mangle -C $rule 2>/dev/null || iptables -w -t mangle -I $rule ;;
off) while iptables -w -t mangle -D $rule 2>/dev/null; do :; done ;;
esac
echo "rules=$(iptables -t mangle -S FORWARD | grep -c -- "--dport $PORT -j CONNMARK")"
echo "deny=$(grep -c 'option mark 65536 mask 65536' /var/run/bmcHwAccel/fastforward 2>/dev/null)"
EOF
}

# ACTION, MWAN_PORT, MWAN_ADDR, ISP_A, ISP_B, TARGET2, PC1, IN_PORT, FWD_PORT,
# WAIT, IN_WAIT, WINDOW and PORTS come from the caller. Multi-WAN with two WANs
# for the mwan items, set up through bmcmultiwan as the web UI does it:
#   setup     keeps the Multi-WAN configuration aside, makes MWAN_PORT the WAN
#             wan2 (static, gateway ISP_B) and gives a static wan without a
#             gateway ISP_A as one; each WAN is checked by pings to its ISP,
#             2 rounds down or up; a Chính sách WAN that prefers wan2 gets
#             what goes to TARGET2; Multi-WAN is enabled. Answers with the
#             state and address of both WANs and the ports to read.
#   lose      stops the pings that check wan2 and waits for the Chuyển WAN.
#             Before, the connections the hardware has; after, what left the
#             two WAN ports and reached the CPU in WINDOW seconds, and how
#             many connections bmcMultiWAN said it removed. While wan2 is
#             Mất Internet an ISP's "port unreachable" is not passed on to
#             the sender of a flow, which would stop sending.
#   back      lets the pings pass again and waits for the Chuyển WAN
#   forward   forwards FWD_PORT of wan2 to PC1:IN_PORT; unforward takes it back
#   inbound   waits IN_WAIT seconds for a connection to FWD_PORT of wan2 that
#             the hardware has, then reads the ports as lose does
#   end       undoes all of it, also what a killed run left behind
# wan2 is made Mất Internet on the board itself, so its link, its routes and
# ISP B stay as they are: only the Chuyển WAN can take a connection off it.
mwan_script() { cat <<'EOF'
# hwaccel:mwan
orig=/etc/hwaccel-orig-mwan
wan_dev=$(uci -q get network.wan.device)
addr() { ip -4 -o addr show dev "$1" 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }'; }
# A bmcmultiwan command; what it refused is in the answer of the board.
cli() {
	answer=$(bmcmultiwan "$@" 2>&1 | head -1)
	case "$answer" in '{"status":0,'*) return 0 ;; esac
	echo "refused=bmcmultiwan $*: $(echo "$answer" | cut -c1-200)"
	return 1
}
# "<link> <internet>" of a WAN, as bmcmultiwan status has it.
state() {
	bmcmultiwan status 2>/dev/null |
		sed -n "s/.*{\"name\":\"$1\",\"link\":\"\([a-z]*\)\",\"internet\":\"\([a-z]*\)\".*/\1 \2/p"
}
block() { iptables -w "$1" OUTPUT -o "$MWAN_PORT" -p icmp -d "$ISP_B" -j DROP 2>/dev/null; }
quiet() {
	for d in "$wan_dev" "$MWAN_PORT"; do
		iptables -w -t mangle "$1" PREROUTING -i "$d" -p icmp --icmp-type destination-unreachable -j DROP 2>/dev/null
	done
}
forward() {
	iptables -w -t nat "$1" PREROUTING -i "$MWAN_PORT" -p tcp --dport "$FWD_PORT" -j DNAT \
		--to-destination "$PC1:$IN_PORT" 2>/dev/null
}
mark="hwaccel-mwan-$$-$(cut -d' ' -f1 /proc/uptime)"
since() { logread | sed -n "/$mark/,\$p"; }
# Waits for the Chuyển WAN line of syslog that starts with $1, WAIT seconds
# at most.
await() {
	i=0
	while [ $i -lt "$WAIT" ] && ! since | grep -q "bmcMultiWAN: Chuyển WAN: $1"; do
		tick wait $i
		sleep 1
		i=$((i + 1))
	done
	echo "waited=$i"
	echo "switch=$(since | grep "bmcMultiWAN: Chuyển WAN: $1" | tail -1 | sed 's/.*bmcMultiWAN: //')"
}
# One line of the trace of a result that fails: the packets that left the two
# WAN ports so far, and the "unreachable" answers of each ISP so far.
answers() {
	iptables -w -t mangle -vnxL PREROUTING 2>/dev/null |
		awk -v d="$1" '/icmptype 3/ && $6 == d { n += $1 } END { print n + 0 }'
}
tick() {
	echo "trace $1 $2: wan $(cat /sys/class/net/$wan_dev/statistics/tx_packets) wan2 $(cat /sys/class/net/$MWAN_PORT/statistics/tx_packets) answers $(answers "$wan_dev") $(answers "$MWAN_PORT")"
}
states() {
	echo "wan=$(state wan)"
	echo "wan2=$(state wan2)"
}
accelerated() {
	echo "@conntrack"
	grep PERMANENT /proc/net/nf_conntrack | head -64
}
snap() {
	# The totals of the WAN ports include what the hardware sent.
	echo "wan_tx_$1=$(cat /sys/class/net/$wan_dev/statistics/tx_packets)"
	echo "wan2_tx_$1=$(cat /sys/class/net/$MWAN_PORT/statistics/tx_packets)"
	for p in $PORTS; do
		echo "@$1 $p"
		ethtool -S "$p" | grep 'rx packets'
	done
}
watch() {
	echo "@ports $PORTS"
	snap before
	i=0
	while [ $i -lt "$WINDOW" ]; do
		[ "$ACTION" != lose ] || tick window $i
		sleep 1
		i=$((i + 1))
	done
	snap after
	echo "status=$(bmchwaccel status 2>&1 | head -1)"
}
undo() {
	while block -D; do :; done
	while quiet -D; do :; done
	while forward -D; do :; done
	[ -d $orig ] || return 0
	cp $orig/mwan3 $orig/bmcMultiWAN /etc/config/
	if [ -f $orig/wan-gateway ]; then
		uci -q delete network.wan.gateway
		uci commit network
	fi
	# Deleting the WAN gives its port back to br-lan and reloads the network.
	if [ "$(uci -q get network.wan2.bmc_role)" = multiwan ]; then
		bmcmultiwan wan del --name wan2 >/dev/null 2>&1
	else
		/etc/init.d/network reload
	fi
	bmcmultiwan apply >/dev/null 2>&1
	rm -r $orig
}

case "$ACTION" in
setup)
	undo
	pc1=${SSH_CONNECTION%% *}
	echo "pc1=$pc1"
	case " $(ls /sys/class/net/br-lan/brif 2>/dev/null | tr '\n' ' ') " in
	*" $MWAN_PORT "*) ;;
	*) echo "refused=$MWAN_PORT is not a port of br-lan; set MWAN_PORT"; exit 0 ;;
	esac
	[ "$(uci -q get bmcMultiWAN.global.enabled)" != 1 ] || {
		echo "refused=Multi-WAN is enabled on this board; the item sets up two WANs of its own and needs it disabled"
		exit 0
	}
	mac=$(ip neigh show "$pc1" 2>/dev/null | sed -n 's/.* lladdr \([0-9a-f:]*\).*/\1/p' | head -1)
	port=
	no=
	[ -z "$mac" ] || no=$(brctl showmacs br-lan 2>/dev/null | awk -v m="$mac" '$2 == m { print $1; exit }')
	for b in /sys/class/net/br-lan/brif/*; do
		[ -z "$no" ] || [ "$(($(cat "$b/port_no" 2>/dev/null)))" != "$no" ] || port=${b##*/}
	done
	[ "$port" != "$MWAN_PORT" ] || {
		echo "refused=PC1 ($pc1) is on $MWAN_PORT, the port that becomes wan2; use another br-lan port for PC1 or set MWAN_PORT"
		exit 0
	}
	mkdir $orig && cp /etc/config/mwan3 /etc/config/bmcMultiWAN $orig/ || {
		echo "refused=the Multi-WAN configuration could not be kept aside"
		exit 0
	}
	if [ "$(uci -q get network.wan.proto)" = static ] && [ -z "$(uci -q get network.wan.gateway)" ]; then
		uci set network.wan.gateway="$ISP_A"
		uci commit network
		touch $orig/wan-gateway
	fi
	cli wan add --name wan2 --port "$MWAN_PORT" --proto static --ipaddr "$MWAN_ADDR" \
		--netmask 255.255.255.0 --gateway "$ISP_B" &&
		cli wan set --name wan --track-ip "$ISP_A" --down 2 --up 2 &&
		cli wan set --name wan2 --track-ip "$ISP_B" --down 2 --up 2 &&
		cli policy set --name hwaccel_b --wan wan2 --wan wan &&
		cli rule set --name hwaccel_to_b --policy hwaccel_b --dest-ip "$TARGET2/32" &&
		cli set --enabled 1 &&
		cli apply || exit 0
	i=0
	while [ $i -lt 60 ]; do
		[ "$(state wan)" = "up online" ] && [ "$(state wan2)" = "up online" ] &&
			iptables -w -t mangle -S mwan3_rules 2>/dev/null | grep -q mwan3_policy_hwaccel_b && break
		sleep 1
		i=$((i + 1))
	done
	states
	echo "wan_dev=$wan_dev"
	echo "wan_addr=$(addr "$wan_dev")"
	echo "wan2_addr=$(addr "$MWAN_PORT")"
	echo "ports=$wan_dev $MWAN_PORT $(ls /sys/class/net/br-lan/brif | tr '\n' ' ')"
	;;
lose)
	accelerated
	logger -t hwaccel "$mark"
	quiet -I
	block -I
	await 'wan2 is M'
	# With hardware acceleration bmcMultiWAN removes the connections right
	# after that line, and the daemon then takes them out of the hardware.
	if ubus -t 5 call service list '{"name":"cmm"}' 2>/dev/null | grep -q '"running": *true'; then
		i=0
		while [ $i -lt 5 ] && ! since | grep -q 'connections through wan2 removed'; do
			sleep 1
			i=$((i + 1))
		done
		sleep 1
	fi
	watch
	echo "removed=$(since | sed -n 's/.*bmcMultiWAN: Chuyển WAN: \([0-9]*\) connections through wan2 removed.*/\1/p' | tail -1)"
	states
	;;
back)
	logger -t hwaccel "$mark"
	while block -D; do :; done
	await 'wan2 has Internet again'
	while quiet -D; do :; done
	states
	;;
forward)
	forward -C || forward -I
	echo "rules=$(iptables -w -t nat -S PREROUTING | grep -c -- "--dport $FWD_PORT -j DNAT")"
	;;
unforward)
	while forward -D; do :; done
	;;
inbound)
	to="dst=$(addr "$MWAN_PORT") "
	i=0
	while [ $i -lt "$IN_WAIT" ]; do
		grep PERMANENT /proc/net/nf_conntrack | grep "dport=$FWD_PORT " | grep -q "$to" && break
		sleep 1
		i=$((i + 1))
	done
	echo "translated=$(grep "dport=$FWD_PORT " /proc/net/nf_conntrack | grep -c "$to")"
	echo "seen=$(grep PERMANENT /proc/net/nf_conntrack | grep "dport=$FWD_PORT " | grep -c "$to")"
	watch
	accelerated
	;;
end)
	undo
	;;
esac
exit 0
EOF
}

# ACTION, LINKS, ADDRS, TARGET, COST, COST_HIGH, WAIT, MOVE_WAIT and SETTLE come
# from the caller. DynRouting with OSPF for the ospf items, set up through
# bmcdynrouting as the web UI does it:
#   setup     keeps the DynRouting configuration aside, makes every port of
#             LINKS a Link định tuyến with its address of ADDRS (a /24), gives
#             a board without a Router ID the first of those addresses, and
#             enables OSPF on lan (passive) and on the links, the first at
#             COST and the second at COST_HIGH. Waits WAIT seconds for a
#             neighbour on every link and for the route to TARGET through
#             the first.
#   withdraw  drops the OSPF packets that come in and waits WAIT seconds for
#             OSPF to take its route to TARGET out of the kernel. Until
#             restore, a "destination unreachable" is not passed on to the
#             sender of a flow, which would stop sending.
#   restore   lets them in again and waits as setup does
#   move      raises the cost of the first link above that of the second in
#             the running OSPF daemon and waits MOVE_WAIT seconds for the
#             kernel to send to TARGET through the second
#   ecmp      gives the first link the cost of the second and waits
#             MOVE_WAIT seconds for a route with a next hop on both
#   end       undoes all of it, also what a killed run left behind
# Each answers with the neighbours of every link, OSPF's routes that cover
# TARGET and the port the kernel sends to TARGET through, SETTLE seconds
# after a route change it waited for. The neighbour is
# lost on the board itself, so the link and the neighbour router stay as they
# are: only the route change can take a connection off the link.
ospf_script() { cat <<'EOF'
# hwaccel:ospf
orig=/etc/hwaccel-orig-ospf
wan_dev=$(uci -q get network.wan.device)
first=${LINKS%% *}
second=${LINKS#* }
[ "$second" != "$LINKS" ] || second=
# A bmcdynrouting command; what it refused is in the answer of the board.
cli() {
	answer=$(bmcdynrouting "$@" 2>&1 | head -1)
	case "$answer" in '{"status":0,'*) return 0 ;; esac
	echo "refused=bmcdynrouting $*: $(echo "$answer" | cut -c1-200)"
	return 1
}
# The name bmcdynrouting gives the Link định tuyến on a port.
link_of() { echo "link_$(printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_')"; }
block() { iptables -w "$1" INPUT -p 89 -m comment --comment hwaccel-ospf -j DROP 2>/dev/null; }
quiet_own() {
	iptables -w "$1" OUTPUT -p icmp --icmp-type destination-unreachable -m comment --comment hwaccel-ospf -j DROP 2>/dev/null
}
quiet_wan() {
	iptables -w -t mangle "$1" PREROUTING -i "$wan_dev" -p icmp --icmp-type destination-unreachable \
		-m comment --comment hwaccel-ospf -j DROP 2>/dev/null
}
unblock() {
	while block -D; do :; done
	while quiet_own -D; do :; done
	while quiet_wan -D; do :; done
}
# OSPF's routes in the kernel (protocol 188) that cover TARGET, on one line.
route() { ip -4 route show match "$TARGET" proto 188 2>/dev/null | tr -s ' \t\n' ' ' | sed 's/ $//'; }
# The port the kernel sends to TARGET through; nothing without a route.
via() { ip -4 -o route get "$TARGET" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }
# Whether one of OSPF's routes has a next hop on the port $1.
through() { case " $(route) " in *" dev $1 "*) return 0 ;; esac; return 1; }
# Neighbours in state Full on the port $1.
full() { vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep 'Full/' | grep -c " $1:"; }
# In the running daemon only: bmcdynrouting would restart it, and the
# neighbours with it.
cost() { vtysh -c 'configure terminal' -c "interface $1" -c "ip ospf cost $2" >/dev/null 2>&1; }
learned() {
	for p in $LINKS; do [ "$(full "$p")" -ge 1 ] || return 1; done
	through "$first" && [ "$(via)" = "$first" ]
}
gone() { [ -z "$(route)" ]; }
moved() { ! through "$first" && [ "$(via)" = "$second" ]; }
both() { through "$first" && through "$second"; }
# Waits $2 seconds at most for $1 to hold, and says whether it does.
await() {
	i=0
	while [ $i -lt "$2" ] && ! "$1"; do
		sleep 1
		i=$((i + 1))
	done
	echo "waited=$i"
	if "$1"; then
		echo "$1=yes"
		sleep "$SETTLE"
	else
		echo "$1=no"
	fi
}
state() {
	for p in $LINKS; do echo "neighbor_$p=$(full "$p")"; done
	echo "route=$(route)"
	echo "via=$(via)"
}
undo() {
	unblock
	[ -d $orig ] || return 0
	# The configuration first: a link that is still an Interface OSPF
	# cannot be deleted. Deleting a link gives its port back to br-lan.
	cp $orig/bmcDynRouting /etc/config/
	for p in $(cat $orig/links 2>/dev/null); do
		bmcdynrouting link del "$p" >/dev/null 2>&1
	done
	bmcdynrouting apply >/dev/null 2>&1
	rm -r $orig
}

case "$ACTION" in
setup)
	undo
	pc1=${SSH_CONNECTION%% *}
	echo "pc1=$pc1"
	[ "$(uci -q get bmcDynRouting.ospf.enabled)" != 1 ] || {
		echo "refused=OSPF is enabled on this board; the item sets up OSPF of its own and needs it disabled"
		exit 0
	}
	mac=$(ip neigh show "$pc1" 2>/dev/null | sed -n 's/.* lladdr \([0-9a-f:]*\).*/\1/p' | head -1)
	port=
	no=
	[ -z "$mac" ] || no=$(brctl showmacs br-lan 2>/dev/null | awk -v m="$mac" '$2 == m { print $1; exit }')
	for b in /sys/class/net/br-lan/brif/*; do
		[ -z "$no" ] || [ "$(($(cat "$b/port_no" 2>/dev/null)))" != "$no" ] || port=${b##*/}
	done
	for p in $LINKS; do
		[ -e "/sys/class/net/br-lan/brif/$p" ] || {
			echo "refused=$p is not a port of br-lan; set OSPF_PORT and OSPF_PORT2"
			exit 0
		}
		[ "$port" != "$p" ] || {
			echo "refused=PC1 ($pc1) is on $p, a port that becomes a Link định tuyến; use another br-lan port for PC1 or set OSPF_PORT and OSPF_PORT2"
			exit 0
		}
	done
	mkdir $orig && cp /etc/config/bmcDynRouting $orig/ || {
		echo "refused=the DynRouting configuration could not be kept aside"
		exit 0
	}
	[ -n "$(uci -q get bmcDynRouting.global.router_id)" ] ||
		cli router-id set --router-id "${ADDRS%% *}" || exit 0
	rows="--interface lan --passive 1"
	c=$COST
	set -- $ADDRS
	for p in $LINKS; do
		cli link add "$p" "$1/24" || exit 0
		echo "$p" >> $orig/links
		rows="$rows --interface $(link_of "$p") --cost $c"
		c=$COST_HIGH
		shift
	done
	# shellcheck disable=SC2086
	cli ospf set --enabled 1 $rows || exit 0
	await learned "$WAIT"
	state
	echo "ports=$wan_dev $LINKS $(ls /sys/class/net/br-lan/brif | tr '\n' ' ')"
	;;
withdraw)
	quiet_own -I
	quiet_wan -I
	block -I
	echo "blocked=$(iptables -w -S INPUT 2>/dev/null | grep -c hwaccel-ospf)"
	await gone "$WAIT"
	state
	;;
restore)
	unblock
	await learned "$WAIT"
	state
	;;
move)
	cost "$first" $((COST_HIGH * 2))
	await moved "$MOVE_WAIT"
	state
	;;
ecmp)
	cost "$first" "$COST_HIGH"
	await both "$MOVE_WAIT"
	state
	;;
end)
	undo
	;;
esac
exit 0
EOF
}

# PORTS, WINDOW and SETTLE come from the caller; iperf3 runs through the board.
# Three windows of WINDOW seconds: acceleration on, disabled, enabled again.
# Each gives the counters at its ends with the uptime at both, then the status,
# the number of conntrack entries the kernel still keeps for the hardware, and
# the limit on traffic through the CPU with the packets it has dropped (only a
# running daemon tells). At both ends of each window it also keeps every counter
# that can say where a packet went, and all along, once a second, the packet
# totals of the ports with a link; both come at the end. The mark tells the
# syslog lines of this run from older ones.
toggle_script() { links_fn; cat <<'EOF'
# hwaccel:toggle
[ -n "$PORTS" ] || PORTS="$(uci -q get network.wan.device) $(ls /sys/class/net/br-lan/brif | tr '\n' ' ')"
echo "@ports $PORTS"
now() { cut -d' ' -f1 /proc/uptime; }
echo "start=$(now)"
# "name<TAB>value" lines: the ports (driver and kernel), the IP layer,
# conntrack, the firewall's INVALID rules, the backlog of the CPUs, the TCP
# window check.
counters() {
	for p in $PORTS; do
		ethtool -S "$p" 2>/dev/null | awk -v p="$p" '{
			i = index($0, ":"); if (!i) next
			k = substr($0, 1, i - 1); v = substr($0, i + 1)
			gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/[ \t]/, "", v)
			if (k !~ /\[CPU [0-9]+\]/ && v ~ /^[0-9]+$/) printf "%s:%s\t%s\n", p, k, v
		}'
		for f in /sys/class/net/$p/statistics/* /sys/class/net/$p/carrier_changes /sys/class/net/$p/speed; do
			printf '%s:%s\t%s\n' "$p" "${f##*/}" "$(cat "$f" 2>/dev/null)"
		done
	done
	awk '/^Ip:/ { if (!n) { split($0, h); n = 1 } else for (i = 2; i <= NF; i++) printf "ip:%s\t%s\n", h[i], $i }' /proc/net/snmp
	conntrack -S 2>/dev/null | tr ' ' '\n' |
		awk -F= 'NF == 2 && $2 ~ /^[0-9]+$/ { n[$1] += $2 } END { for (k in n) printf "conntrack:%s\t%s\n", k, n[k] }'
	iptables -vnxL 2>/dev/null | awk '/INVALID/ { n += $1 } END { printf "iptables:INVALID rules\t%d\n", n }'
	d=0
	while read -r a b rest; do d=$((d + 0x$b)); done < /proc/net/softnet_stat
	printf 'softnet:dropped\t%s\n' "$d"
	printf 'tcp_be_liberal\t%s\n' "$(cat /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal)"
}
TRACE_PORTS=
for p in $PORTS; do
	[ "$(cat /sys/class/net/$p/carrier 2>/dev/null)" = 1 ] && TRACE_PORTS="$TRACE_PORTS $p"
done
trace() {
	while :; do
		line="@tick $(now)"
		for p in $TRACE_PORTS; do
			line="$line $p $(cat /sys/class/net/$p/statistics/rx_packets) $(cat /sys/class/net/$p/statistics/tx_packets) $(cat /sys/class/net/$p/carrier_changes)"
		done
		echo "$line"
		sleep 1
	done
}
trace > /tmp/hwaccel-toggle.trace 2>/dev/null &
trace_pid=$!
window() {
	echo "@window $1"
	for phase in before after; do
		echo "$phase=$(now)"
		for p in $PORTS; do
			echo "@$phase $p"
			ethtool -S "$p" | grep 'rx packets'
		done
		counters > /tmp/hwaccel-toggle.snap-$1-$phase
		[ $phase = after ] || sleep "$WINDOW"
	done
	echo "status=$(bmchwaccel status 2>&1 | head -1)"
	echo "pinned=$(grep -c PERMANENT /proc/net/nf_conntrack)"
	for p in $PORTS; do echo "link $p $(links /sys/class/net/$p)"; done
	cmm -c 'query qmexptrate eth' 2>/dev/null | sed -n \
		-e 's/^QM Exception RATE[^:]*: *\([0-9]*\).*/cpu_limit=\1/p' \
		-e 's/^Red (dropped) packets[^0-9]*\([0-9]*\).*/cpu_dropped=\1/p'
}
mark="hwaccel-toggle-$$-$(now)"
logger -t hwaccel-test "$mark"
window on
echo "@answers"
echo "disable=$(bmchwaccel disable 2>&1 | head -1)"
window off
echo "@answers"
echo "enable=$(bmchwaccel enable 2>&1 | head -1)"
sleep "$SETTLE"
window again
echo "@answers"
logread | sed -n "/$mark/,\$p" > /tmp/hwaccel-toggle.log
echo "logged_off=$(grep -c 'bmcHwAccel.*turned off' /tmp/hwaccel-toggle.log)"
echo "logged_on=$(grep -c 'bmcHwAccel.*turned on' /tmp/hwaccel-toggle.log)"
rm -f /tmp/hwaccel-toggle.log
kill $trace_pid
for w in on off again; do
	for phase in before after; do
		echo "@snap $w-$phase"
		cat /tmp/hwaccel-toggle.snap-$w-$phase
	done
done
echo "@trace"
cat /tmp/hwaccel-toggle.trace
rm -f /tmp/hwaccel-toggle.snap-* /tmp/hwaccel-toggle.trace
EOF
}

# ACTION comes from the caller.
#   disable, enable        saves the choice with bmchwaccel and, when it was
#                          saved, reboots
#   booted-off, booted-on  which boot this is, whether it has finished, and
#                          what it loaded and started
switch_script() { trouble_fn; cat <<'EOF'
# hwaccel:switch
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
case "$ACTION" in
disable|enable|reboot)
	if [ "$ACTION" != reboot ]; then
		echo "answer=$(bmchwaccel "$ACTION" 2>&1 | head -1)"
		saved=$(uci -q get bmchwaccel.global.enabled)
		echo "saved=$saved"
		case "$ACTION$saved" in disable0|enable1) ;; *) exit 0 ;; esac
	fi
	# reboot ends every shell session; this one has to end first.
	(sleep 2; reboot) > /dev/null 2>&1 < /dev/null &
	;;
*)
	# procd says so in syslog once every init script has run.
	logread | grep -q 'init complete' && echo init=complete
	echo "status=$(bmchwaccel status 2>&1 | head -1)"
	echo "modules=$(lsmod | grep -c -E '^(cdx|fci|auto_bridge) ')"
	echo "trouble=$(dmesg | trouble | grep -c .)"
	echo "@trouble"
	dmesg | trouble | tail -20
	;;
esac
exit 0
EOF
}

# ACTION (start or end), and at the end MARK, come from the caller. The start
# leaves a mark in the kernel log and in syslog; the end gives the lines both
# got after it. Without the mark in a log (it has been overwritten) the end
# cannot tell, and says so by leaving out kernel_mark or syslog_mark.
soak_script() { trouble_fn; cat <<'EOF'
# hwaccel:soak
if [ "$ACTION" = start ]; then
	MARK="hwaccel-soak-$$-$(cut -d. -f1 /proc/uptime)"
	echo "$MARK" > /dev/kmsg
	logger -t hwaccel-test "$MARK"
	echo "mark=$MARK"
fi
echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
echo "daemon=$(pidof cmm)"
echo "starts=$(cat /var/run/bmcHwAccel/daemon-starts 2>/dev/null)"
echo "modules=$(lsmod | grep -c -E '^(cdx|fci|auto_bridge) ')"
echo "free_kb=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)"
echo "status=$(bmchwaccel status 2>&1 | head -1)"
[ "$ACTION" = end ] || exit 0
dmesg | grep -q "$MARK" && echo kernel_mark=yes
# The mark is in the log twice: as a kernel line, which logd has, and as the
# line of logger. Only what follows the line of logger is of the run; after
# the kernel line comes all of /var/log/messages, from the boot on.
logread | grep -q "hwaccel-test.*$MARK" && echo syslog_mark=yes
echo "@kernel"
dmesg | sed -n "/$MARK/,\$p" | sed 1d | tail -40
echo "@trouble"
dmesg | sed -n "/$MARK/,\$p" | sed 1d | trouble
echo "@syslog"
logread | awk -v m="$MARK" 'index($0, "hwaccel-test") && index($0, m) { n = 0; next } { line[++n] = $0 } END { for (i = 1; i <= n; i++) print line[i] }' | grep -E 'cmm|bmcHwAccel'
exit 0
EOF
}

# SERVER (the iperf3 server of the item), DROP_PORT, PORTS and WINDOW come from
# the caller; wan dials PPPoE and a UDP flow to SERVER:DROP_PORT runs through
# the session. Ends the session,
# keeps it down for WINDOW seconds and lets it come back.
drop_script() { cat <<'EOF'
# hwaccel:drop
dev=$(uci -q get network.wan.device)
[ -n "$PORTS" ] || PORTS="$dev $(ls /sys/class/net/br-lan/brif | tr '\n' ' ')"
addr() { ip -4 -o addr show dev pppoe-wan 2>/dev/null | awk '{ print $4; exit }'; }
session() { awk '$4 == "pppoe-wan" { print $1; exit }' /proc/net/pppoe 2>/dev/null; }
snap() {
	# The total of the wan port includes what the hardware sent.
	echo "wan_tx_$1=$(cat /sys/class/net/$dev/statistics/tx_packets)"
	for p in $PORTS; do
		echo "@$1 $p"
		ethtool -S "$p" | grep 'rx packets'
	done
}
echo "session_before=$(session)"
echo "@conntrack"
grep PERMANENT /proc/net/nf_conntrack | grep "dport=$DROP_PORT " | head -8
echo "@ports $PORTS"
# With the session down the board has no route for the flow and would answer
# it with ICMP unreachable, which stops the sender. Drop the flow quietly
# instead; a packet that reaches the CPU is counted before this rule sees it.
iptables -t mangle -I PREROUTING -p udp -d "$SERVER" --dport "$DROP_PORT" -j DROP
# An access concentrator name that no server has: pppd ends the session and
# cannot open a new one, while the wan port stays up.
uci set network.wan.ac=hwaccel-no-such-ac
uci commit network
/etc/init.d/network reload
i=0
while [ $i -lt 15 ] && [ -n "$(addr)" ]; do sleep 1; i=$((i + 1)); done
[ -z "$(addr)" ] && echo down=yes || echo down=no
snap before
sleep "$WINDOW"
snap after
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

# What drop_script changes, put back when the script is interrupted in the
# middle of pppoe-drop.
undrop_script() { cat <<'EOF'
# hwaccel:undrop
iptables -t mangle -D PREROUTING -p udp -d "$SERVER" --dport "$DROP_PORT" -j DROP 2>/dev/null
if uci -q get network.wan.ac >/dev/null; then
	uci delete network.wan.ac
	uci commit network
	/etc/init.d/network reload
fi
EOF
}

drop_env() {
	echo "SERVER='$server'
DROP_PORT='$DROP_PORT'
PORTS='$PORTS'
WINDOW=$WINDOW"
}

# ITEM and SERVER come from the caller. What tells why traffic to SERVER is
# not accelerated or slow: the interfaces cmm has given to the hardware, a
# conntrack entry of the traffic, the last words of cmm and the last link
# changes of the ports.
diag_script() { links_fn; cat <<'EOF'
# hwaccel:diag
for q in vlan pppoe; do
	echo "cmm -c 'query $q':"
	cmm -c "query $q" 2>&1 | head -12
done
echo "/proc/net/pppoe:"
cat /proc/net/pppoe 2>&1
echo "conntrack to $SERVER:"
grep "dst=$SERVER " /proc/net/nf_conntrack | head -2
echo "log:"
logread | grep -i -E 'cmm|cdx' | tail -8
# A port that lost its link under the run explains a slow item whose packets
# did not reach the CPU.
echo "links, uptime now $(cut -d. -f1 /proc/uptime) s:"
for d in /sys/class/net/eth*; do echo "${d##*/} $(links "$d")"; done
echo "link messages of the kernel:"
dmesg | grep -i -E 'link is (up|down)|link (up|down)|carrier' | tail -8
EOF
}

# The image arrives on the standard input.
upload_script() { cat <<EOF
# hwaccel:upload
cat > $UPGRADE_FILE
EOF
}

# ITEM, ACTION, FILE, ID and ROOT_SIZE come from the caller.
#   check   what the board runs, what arrived of the image, and what the test
#           mode of sysupgrade says about it; for the sysupgrade item also the
#           kernel and root filesystem the card holds. An image that will not
#           be installed is removed.
#   start   leaves two marks, one in the configuration and one outside what
#           sysupgrade keeps, then installs the image keeping the configuration
#   poll    which boot this is and whether it has finished
#   verify  what is left of the marks, and the kernel and root filesystem the
#           card holds now
upgrade_script() { cat <<'EOF'
# hwaccel:upgrade
log=/tmp/hwaccel-sysupgrade.log
mark=/root/hwaccel-not-kept
sha() { sha256sum | cut -d' ' -f1; }
state() {
	echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
	echo "release=$(. /etc/openwrt_release; echo "$DISTRIB_RELEASE $DISTRIB_REVISION")"
	echo "kernel=$(uname -r)"
	echo "compat=$(uci -q get system.@system[0].compat_version)"
	echo "config=$({ uci show network; uci show firewall; } 2>/dev/null | sha)"
}
# The first two partitions of the disk the board booted from, found the way
# sysupgrade finds them: the kernel is the file fitImage on the first one, the
# root filesystem starts the second one.
card() {
	. /lib/functions.sh
	. /lib/upgrade/common.sh
	export_bootdevice && export_partdevice kernel_part 1 && export_partdevice root_part 2 || return
	echo "card_root=$(head -c "$ROOT_SIZE" "/dev/$root_part" | sha)"
	mkdir -p /tmp/hwaccel-boot
	mount -t ext4 -o ro "/dev/$kernel_part" /tmp/hwaccel-boot 2>/dev/null || return
	echo "card_kernel=$(sha < /tmp/hwaccel-boot/fitImage)"
	echo "kernel_time=$(date -r /tmp/hwaccel-boot/fitImage +%s)"
	umount /tmp/hwaccel-boot
}
case "$ACTION" in
check)
	state
	dir=$(tar -tf "$FILE" 2>/dev/null | grep -m 1 '^sysupgrade-.*/$')
	echo "image_kernel=$(tar -xOf "$FILE" "${dir}kernel" 2>/dev/null | sha)"
	echo "image_root=$(tar -xOf "$FILE" "${dir}root" 2>/dev/null | sha)"
	[ "$ITEM" != sysupgrade ] || card
	echo "@test"
	sysupgrade -T "$FILE" 2>&1
	accepted=$?
	echo "@rc $accepted"
	[ "$ITEM" = sysupgrade ] && [ $accepted -eq 0 ] || rm -f "$FILE"
	;;
start)
	touch /etc/config/hwaccel_test
	uci set hwaccel_test.sysupgrade=mark
	uci set hwaccel_test.sysupgrade.id="$ID"
	uci commit hwaccel_test
	echo "$ID" > $mark
	# sysupgrade ends every shell session; this one has to end first.
	(sleep 2; sysupgrade "$FILE") > $log 2>&1 < /dev/null &
	echo started=yes
	;;
poll)
	echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
	# procd says so in syslog once every init script has run.
	logread | grep -q 'init complete' && echo init=complete
	[ -s $log ] && { echo "@log"; cat $log; }
	exit 0
	;;
verify)
	state
	echo "kept=$(uci -q get hwaccel_test.sysupgrade.id)"
	[ -e $mark ] && echo overlay=old || echo overlay=new
	card
	rm -f /etc/config/hwaccel_test $mark
	;;
esac
EOF
}

upgrade() { # item action -> answer of the board
	board "ITEM=$1
ACTION=$2
FILE=$UPGRADE_FILE
ID='${image_id:-}'
ROOT_SIZE='${image_root_size:-}'
$(upgrade_script)" 2>&1
}

# What serves the web UI on the board. The FIDO server only runs when FIDO is
# the security mode.
webui_script() { cat <<EOF
# hwaccel:webui
echo "server=\$(pgrep -f '[s]erver.bundle.js' | wc -l)"
echo "listen=\$(netstat -ltn 2>/dev/null | grep -c ':$WEBUI_PORT ')"
echo "dnsfilter=\$(pidof bmcfirewall | wc -w)"
echo "fido=\$(pgrep -f '[/]etc/bmcfido/app.js' | wc -l)"
EOF
}

# ACTION comes from the caller, with PC1, MAC, WAN_DEV, RULE, IN_RULE, IN_PORT
# and FWD_PORT where the action needs them. The features are driven through
# the scripts the web UI calls; "said" is their JSON answer on one line.
#   start     who PC1 is, and hardware acceleration disabled when the board
#             has it and it was enabled (remembered for "end")
#   end       what the actions before it set up is taken away (each leaves
#             a mark for it), hardware acceleration is as it was. Nothing
#             else on the board is touched.
#   <feature>-on, <feature>-off  one feature set up or taken away
#   seen      how many connections to PORT of wan the board has translated
#             to PC1 since the feature was set up, and whether PC1 took one
features_script() { cat <<'EOF'
# hwaccel:features
S=/etc/bmcweb/backend/scripts
was=/tmp/hwaccel-features-was
did=/tmp/hwaccel-features-did
said() { echo "said=$(tr -d '\n' | tr -s ' ' | cut -c1-200)"; }
forward() { iptables -t nat "$1" PREROUTING -i "$WAN_DEV" -p tcp --dport "$FWD_PORT" -j DNAT --to-destination "$PC1:$IN_PORT"; }
case "$ACTION" in
start)
	[ -n "$PC1" ] || PC1=${SSH_CONNECTION%% *}
	echo "pc1=$PC1"
	echo "mac=$(ip neigh show "$PC1" 2>/dev/null | sed -n 's/.* lladdr \([0-9a-fA-F:]*\).*/\1/p' | head -1 | tr a-f A-F)"
	echo "macfilter=$(uci -q get macfilter.settings.status)"
	echo "ddos=$(uci -q get ddos_protect.common.status)"
	if command -v bmchwaccel >/dev/null 2>&1; then
		[ -e $was ] || uci -q get bmchwaccel.global.enabled > $was
		[ "$(cat $was)" != 1 ] || bmchwaccel disable >/dev/null 2>&1
		echo "status=$(bmchwaccel status 2>&1 | head -1)"
	else
		echo "status=none"
	fi
	;;
end)
	for f in $(cat $did 2>/dev/null); do
		case "$f" in
		macfilter) bash $S/firewall/macfilter.sh remove "$MAC"; bash $S/firewall/macfilter.sh disable ;;
		client) bash $S/firewall/client_control.sh del "$RULE" ;;
		ddos) bash $S/firewall/ddos_protect.sh set disable ;;
		nat11) bash $S/network/nat_one2one.sh del "$IN_RULE" ;;
		forward) while forward -D 2>/dev/null; do :; done ;;
		esac >/dev/null 2>&1
	done
	[ "$(cat $was 2>/dev/null)" != 1 ] || bmchwaccel enable >/dev/null 2>&1
	rm -f $was $did
	;;
macfilter-on)
	echo macfilter >> $did
	bash $S/firewall/macfilter.sh enable >/dev/null 2>&1
	bash $S/firewall/macfilter.sh mode blacklist >/dev/null 2>&1
	bash $S/firewall/macfilter.sh add "$MAC" 2>&1 | said
	echo "rules=$(iptables -S MAC_FILTER 2>/dev/null | grep -c -i -- "--mac-source $MAC -j DROP")"
	;;
macfilter-off)
	bash $S/firewall/macfilter.sh remove "$MAC" 2>&1 | said
	bash $S/firewall/macfilter.sh disable >/dev/null 2>&1
	;;
client-on)
	echo client >> $did
	bash $S/firewall/client_control.sh set "$RULE" "$MAC" 00:00 23:59 Mon,Tue,Wed,Thu,Fri,Sat,Sun 2>&1 | said
	# Whatever the chain is called: a firmware from before ticket 22 has a
	# web UI script with another name for it than the service of files/.
	echo "rules=$(iptables -S 2>/dev/null | grep -c -i -- "--mac-source $MAC .*-m time ")"
	;;
client-off)
	bash $S/firewall/client_control.sh del "$RULE" 2>&1 | said
	;;
ddos-on)
	echo ddos >> $did
	bash $S/firewall/ddos_protect.sh set enable 2>&1 | said
	echo "rules=$(iptables -S FW_DOS_POLICY 2>/dev/null | grep -c -- '-j DROP')"
	;;
ddos-off)
	bash $S/firewall/ddos_protect.sh set disable 2>&1 | said
	;;
nat11-on)
	# A rule of that number that is on the board already is not the item's.
	if uci -q get "nat11.rule_$IN_RULE" >/dev/null; then
		echo "said=NAT 1:1 rule $IN_RULE exists on the board already; give the item another with IN_RULE"
		echo "rules=0"
		exit 0
	fi
	echo nat11 >> $did
	bash $S/network/nat_one2one.sh set "$IN_RULE" 1 hwaccel wan tcp "$PC1" 2>&1 | grep '"status"' | said
	echo "rules=$(iptables -t nat -S ZONE_NAT_11 2>/dev/null | grep -c -- "-j DNAT --to-destination $PC1")"
	# Only what comes in from now on counts.
	iptables -t nat -Z ZONE_NAT_11 2>/dev/null
	iptables -Z nat_one2one 2>/dev/null
	conntrack -D -p tcp --dport "$IN_PORT" >/dev/null 2>&1
	;;
nat11-off)
	bash $S/network/nat_one2one.sh del "$IN_RULE" 2>&1 | grep '"status"' | said
	;;
forward-on)
	echo forward >> $did
	bash $S/firewall/add-iptables-rule.sh "-t nat -A PREROUTING -i $WAN_DEV -p tcp --dport $FWD_PORT -j DNAT --to-destination $PC1:$IN_PORT" 2>&1 | said
	echo "rules=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c -- "--dport $FWD_PORT -j DNAT --to-destination $PC1:$IN_PORT")"
	iptables -Z zone_wan_forward 2>/dev/null
	conntrack -D -p tcp --dport "$FWD_PORT" >/dev/null 2>&1
	;;
forward-off)
	while forward -D 2>/dev/null; do :; done
	;;
seen)
	# seen: packets the rule of the feature translated, one for each
	# connection that came in. forwarded: packets the filter table then let
	# through to PC1, by the rule NAT 1:1 adds for its address or by the rule
	# of fw3 for translated connections from wan. PC1 took a connection when
	# its reply half is there, which comes from PC1.
	case "$PORT" in
	"$FWD_PORT")
		echo "seen=$(iptables -t nat -vnxL PREROUTING 2>/dev/null | awk -v p="dpt:$FWD_PORT" '$3 == "DNAT" && index($0, p) { n += $1 } END { print n + 0 }')"
		echo "forwarded=$(iptables -vnxL zone_wan_forward 2>/dev/null | awk '$3 == "ACCEPT" && /ctstate DNAT/ { n += $1 } END { print n + 0 }')"
		;;
	*)
		echo "seen=$(iptables -t nat -vnxL ZONE_NAT_11 2>/dev/null | awk '$3 == "DNAT" { n += $1 } END { print n + 0 }')"
		echo "forwarded=$(iptables -vnxL nat_one2one 2>/dev/null | awk '$3 == "ACCEPT" { n += $1 } END { print n + 0 }')"
		;;
	esac
	echo "answered=$(conntrack -L -p tcp 2>/dev/null | grep -E " dport=$PORT .*src=$PC1 dst=[^ ]* sport=$IN_PORT " | grep -c -v UNREPLIED)"
	;;
esac
exit 0
EOF
}

# The captive portal. ACTION, CLIENT (the address the portal gave PC1), SERVER
# and the login come from the caller.
#   start    what runs, the address of the portal, and the login of the item
#            added to the user database (a mark is left for "end", where it
#            survives a reboot)
#   before, after  how the portal lists CLIENT, and how many connections of
#            CLIENT to SERVER the board has forwarded; asked before and after
#            the login
#   fresh    CLIENT as a client that is new on the LAN: logged out, and the
#            connections the board knows of it forgotten
#   logout   CLIENT is logged out. Its connections are left alone: whatever
#            still carries them shows in the pings that follow.
#   end      logout, and the login of the item is removed
portal_script() { cat <<'EOF'
# hwaccel:portal
db=/etc/freeradius3/raddb/radius.db
did=/etc/hwaccel-portal-did
tun=$(uci -q get chilli.@chilli[0].tundev)
session() { chilli_query list 2>/dev/null | awk -v ip="$CLIENT" '$2 == ip { print $1, $3, $5, $6; exit }'; }
logout() {
	set -- $(session)
	[ -z "${1:-}" ] || chilli_query logout "$1" >/dev/null 2>&1
}
user() { sqlite3 "$db" "DELETE FROM radcheck WHERE username = '$USER';$1" 2>&1; }
case "$ACTION" in
start)
	echo "mode=$(uci -q get system.@system[0].security_mode)"
	echo "chilli=$(pidof chilli | cut -d' ' -f1)"
	echo "radiusd=$(pidof radiusd | cut -d' ' -f1)"
	echo "gateway=$(ip -4 -o addr show dev "${tun:-tun0}" 2>/dev/null | awk '{ print $4; exit }')"
	echo "lan_dhcp=$(uci -q get dhcp.lan.ignore)"
	touch $did
	echo "user=$(user "INSERT INTO radcheck (username, attribute, op, value) VALUES ('$USER', 'Cleartext-Password', ':=', '$PASS');" | tr '\n' ' ')"
	echo "status=$(bmchwaccel status 2>&1 | head -1)"
	;;
before|after)
	set -- $(session)
	echo "mac=${1:-}"
	echo "state=${2:-}"
	echo "authorized=${3:-}"
	echo "name=${4:-}"
	echo "forwarded=$(conntrack -L 2>/dev/null | grep -c "src=$CLIENT dst=$SERVER ")"
	echo "status=$(bmchwaccel status 2>&1 | head -1)"
	;;
fresh)
	logout
	conntrack -D -s "$CLIENT" >/dev/null 2>&1
	;;
logout)
	logout
	;;
end)
	[ -e $did ] || exit 0
	[ -z "$CLIENT" ] || logout
	user "" >/dev/null
	rm -f $did
	;;
esac
exit 0
EOF
}

# The proxy and the HTTP file tracker. ACTION, PC1, SERVER, HTTP_PORT and
# HTTP_FILE come from the caller.
#   start        what runs and listens; the tracker enabled for PC1 and
#                HTTP_PORT (its configuration is kept for "end")
#   redirect-on  HTTP of br-lan to SERVER:HTTP_PORT goes to squid's intercept
#                port, as the firmware does it for ports 80 and 443 when the
#                antivirus is enabled
#   redirect-off the rule is taken away
#   before, proxied, direct  asked before the downloads and after each:
#                transfers of HTTP_FILE the tracker has logged (after a
#                download it gets TRACK_WAIT seconds to log one more than
#                LOGGED) and the last of those lines; requests the ICAP
#                server has answered; connections to SERVER:HTTP_PORT: those of
#                PC1 that the board answered itself (redirected) or forwarded,
#                and those of the board (squid)
#   end          everything as it was
proxy_script() { cat <<'EOF'
# hwaccel:proxy
kept=/etc/hwaccel-proxy-tracker
did=/etc/hwaccel-proxy-did
listens() { netstat -ltn 2>/dev/null | grep -c ":$1 "; }
redirect() { iptables -t nat "$1" PREROUTING -i br-lan -p tcp -d "$SERVER" --dport "$HTTP_PORT" -j REDIRECT --to-ports 3128; }
lines() { logread | grep 'http-file-tracker event=http_transfer' | grep "/$HTTP_FILE "; }
case "$ACTION" in
start)
	[ -n "$PC1" ] || PC1=${SSH_CONNECTION%% *}
	echo "pc1=$PC1"
	echo "squid=$(pidof squid | wc -w)"
	echo "intercept=$(listens 3128)"
	echo "bump=$(listens 3129)"
	echo "icap=$(pidof c-icap | wc -w)"
	echo "icap_port=$(listens 1344)"
	echo "clamd=$(pidof clamd | wc -w)"
	[ -e $kept ] || cp /etc/config/http-file-tracker $kept
	uci set http-file-tracker.main.enabled=1
	uci -q del_list http-file-tracker.main.lan_client="$PC1"
	uci add_list http-file-tracker.main.lan_client="$PC1"
	uci -q del_list http-file-tracker.main.http_port="$HTTP_PORT"
	uci add_list http-file-tracker.main.http_port="$HTTP_PORT"
	uci commit http-file-tracker
	# The tracker misses what starts before it reads br-lan: wait for its
	# capture socket, one more than there were without it.
	/etc/init.d/http-file-tracker stop >/dev/null 2>&1
	sleep 1
	sockets=$(wc -l < /proc/net/packet)
	/etc/init.d/http-file-tracker start >/dev/null 2>&1
	i=0
	while [ $i -lt "$TRACK_WAIT" ] && [ "$(wc -l < /proc/net/packet)" -le "$sockets" ]; do
		sleep 1
		i=$((i + 1))
	done
	if [ "$(wc -l < /proc/net/packet)" -gt "$sockets" ]; then
		# It sets its filter and starts reading right after.
		sleep 2
		echo "tracker=$(pidof http-file-tracker | wc -w)"
	else
		echo "tracker=0"
	fi
	echo "status=$(bmchwaccel status 2>&1 | head -1)"
	;;
redirect-on)
	touch $did
	redirect -I
	conntrack -D -p tcp -d "$SERVER" --dport "$HTTP_PORT" >/dev/null 2>&1
	echo "rules=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c -- "-d $SERVER/32 .*--dport $HTTP_PORT -j REDIRECT --to-ports 3128")"
	;;
redirect-off)
	while redirect -D 2>/dev/null; do :; done
	conntrack -D -p tcp -d "$SERVER" --dport "$HTTP_PORT" >/dev/null 2>&1
	rm -f $did
	;;
before|proxied|direct)
	i=0
	while [ "$ACTION" != before ] && [ $i -lt "$TRACK_WAIT" ] && [ "$(lines | wc -l)" -le "$LOGGED" ]; do
		sleep 1
		i=$((i + 1))
	done
	echo "logged=$(lines | wc -l)"
	echo "icap_requests=$(cat /var/log/c-icap_access.log 2>/dev/null | wc -l)"
	echo "line=$(lines | tail -1 | sed 's/.*event=http_transfer //' | cut -c1-240)"
	# A redirected connection of PC1 is answered by the board, a forwarded
	# one by SERVER; squid's own connection does not come from PC1.
	conntrack -L -p tcp 2>/dev/null | awk -v pc1="src=$PC1" -v to="dst=$SERVER" -v port="dport=$HTTP_PORT" -v back="src=$SERVER" '
		{
			n = 0; d = ""; p = ""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^src=/) s[++n] = $i
				if ($i ~ /^dst=/ && d == "") d = $i
				if ($i ~ /^dport=/ && p == "") p = $i
			}
			if (d != to || p != port) next
			if (s[1] != pc1) board++; else if (s[2] == back) forwarded++; else redirected++
		}
		END { printf "from_board=%d\nforwarded=%d\nredirected=%d\n", board, forwarded, redirected }'
	echo "status=$(bmchwaccel status 2>&1 | head -1)"
	;;
end)
	[ ! -e $did ] || { while redirect -D 2>/dev/null; do :; done; rm -f $did; }
	[ -e $kept ] || exit 0
	cp $kept /etc/config/http-file-tracker && rm -f $kept
	/etc/init.d/http-file-tracker restart >/dev/null 2>&1
	;;
esac
exit 0
EOF
}

autobridge() { # unload|load -> module=, cmm=
	board "ACTION=$1
$(autobridge_script)" 2>&1
}

bridge() { # action [, what it belongs to] -> answer of the board
	board "ITEM=${2:-}
ACTION=$1
SERVER='${block_server:-$BRIDGE_SERVER}'
PC1='$PC1'
MAC='${pc1_mac:-}'
RULE='$FEATURE_RULE'
IN='$bridge_in'
OUT='$bridge_out'
WINDOW=$WINDOW
SETTLE=$BRIDGE_SETTLE
$(bridge_script)" 2>&1
}

switch() { # action -> answer of the board
	board "ACTION=$1
$(switch_script)" 2>&1
}

qos() { # action -> answer of the board
	board "ACTION=$1
QOS_KBIT=$((QOS_MBPS * 1000))
$(qos_script)"
}

mark() { # action -> answer of the board
	board "ACTION=$1
PORT=$DROP_PORT
$(mark_script)"
}

mwan() { # action -> answer of the board
	board "ACTION=$1
MWAN_PORT='$MWAN_PORT'
MWAN_ADDR='$MWAN_ADDR'
ISP_A='$SERVER'
ISP_B='$SERVER2'
TARGET2='$MWAN_TARGET2'
PC1='$PC1'
IN_PORT='$IN_PORT'
FWD_PORT='$FWD_PORT'
WAIT=$MWAN_WAIT
IN_WAIT=$IN_WAIT
WINDOW=$WINDOW
PORTS='$PORTS'
$(mwan_script)"
}

ospf() { # action -> answer of the board
	board "ACTION=$1
LINKS='$ospf_links'
ADDRS='$ospf_addrs'
TARGET='$OSPF_TARGET'
COST=$OSPF_COST
COST_HIGH=$OSPF_COST_HIGH
WAIT=$OSPF_WAIT
MOVE_WAIT=$OSPF_MOVE_WAIT
SETTLE=$OSPF_SETTLE
$(ospf_script)"
}

# ---- parsing

# First "key=value" of a board answer.
value() { sed -n "s/^$2=//p" "$1" | head -1; }

# A field of the "bmchwaccel status" answer in a board answer: state (on, off)
# or accelerated (a number). Nothing when the board gave no such answer.
status_field() { # file, field
	value "$1" status | sed -n "s/.*\"$2\":\"\{0,1\}\([a-z0-9_]*\).*/\1/p"
}

# Sets state from the "bmchwaccel status" answer in a board answer, with a
# reason when it is not the wanted one (on, off or unavailable).
status_check() { # file, wanted state [, what the answer belongs to]
	state=$(status_field "$1" state)
	[ "$state" = "$2" ] || why "${3:+$3: }bmchwaccel status says ${state:-nothing}, need $2"
}

# iperf3 -J report -> received Mbps, or nothing when the report has no sum.
iperf_mbps() {
	awk '{ s = s $0 }
	END {
		i = index(s, "\"sum_received\"")
		if (!i) exit
		s = substr(s, i)
		if (!match(s, /"bits_per_second":[ \t]*[0-9.eE+]+/)) exit
		v = substr(s, RSTART, RLENGTH)
		sub(/.*:[ \t]*/, "", v)
		printf "%d\n", v / 1000000
	}' "$1"
}

# iperf3 -J report -> ", slowest second N Mbps[, M retransmits]". A slow start
# shows in the slowest second; retransmits tell loss from a slow sender.
iperf_detail() {
	awk '{ s = s $0 }
	END {
		i = index(s, "\"sum_sent\"")
		if (i && match(substr(s, i, 400), /"retransmits":[ \t]*[0-9]+/)) {
			retr = substr(s, i + RSTART - 1, RLENGTH)
			sub(/.*:[ \t]*/, "", retr)
		}
		while ((i = index(s, "\"sum\":")) > 0) {
			s = substr(s, i + 6)
			if (!match(s, /"bits_per_second":[ \t]*[0-9.eE+]+/)) break
			v = substr(s, RSTART, RLENGTH)
			sub(/.*:[ \t]*/, "", v)
			if (min == "" || v + 0 < min) min = v + 0
		}
		if (min != "") printf ", slowest second %d Mbps", min / 1000000
		if (retr != "") printf ", %d retransmits", retr
	}' "$1"
}

# iperf3 -J report -> mean Mbps between second $2 and second $3 of the run
# (without $3: to its end); nothing when the report has no interval there.
iperf_span_mbps() {
	awk -v from="$2" -v to="${3:-}" '
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
			a = num(o, "start"); b = num(o, "end")
			if (a < from) a = from
			if (to != "" && b > to) b = to
			if (b <= a) continue
			secs += b - a
			bits += num(o, "bits_per_second") * (b - a)
		}
		if (secs > 0) printf "%d\n", bits / secs / 1000000
	}' "$1"
}

# iperf3 -J report -> how many of its intervals between second $2 and second $3
# of the run (without $3: to its end) carried less than 1 Mbps.
iperf_idle() {
	awk -v from="$2" -v to="${3:-}" '
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
			if (num(o, "start") < from || (to != "" && num(o, "end") > to + 0.5)) continue
			if (num(o, "bits_per_second") < 1000000) idle++
		}
		print idle + 0
	}' "$1"
}

# iperf3 -J report -> the Mbps of every interval on one line, with a "|" at each
# of the seconds given after the file.
iperf_timeline() {
	file=$1
	shift
	awk -v marks="$*" -v bars="${TIMELINE_BARS:-1}" '
	function num(o, key,   v) {
		if (!match(o, "\"" key "\":[ \t]*[0-9.eE+-]+")) return 0
		v = substr(o, RSTART, RLENGTH)
		sub(/.*:[ \t]*/, "", v)
		return v + 0
	}
	{ s = s $0 }
	END {
		n = split(marks, m, " ")
		k = 1
		while ((i = index(s, "\"sum\":")) > 0) {
			s = substr(s, i + 6)
			o = substr(s, 1, index(s, "}"))
			while (k <= n && m[k] != "" && m[k] + 0 <= num(o, "start")) { if (bars) printf "| "; k++ }
			printf "%d ", num(o, "bits_per_second") / 1000000
		}
		printf "\n"
	}' "$file"
}

# iperf3 -J report -> how many of its streams carried nothing in the last $2
# intervals; nothing when the report has no per-stream intervals.
iperf_stalled() {
	awk -v want="$2" '
	{ s = s $0 }
	END {
		# The intervals come before the summary, which has streams too.
		if (match(s, /"end":[ \t]*\{/)) s = substr(s, 1, RSTART - 1)
		while ((i = index(s, "\"streams\":")) > 0) {
			s = substr(s, i + 10)
			j = index(s, "\"sum\":")
			block[++n] = j ? substr(s, 1, j - 1) : s
		}
		if (!n) exit
		for (i = (n > want ? n - want + 1 : 1); i <= n; i++) {
			b = block[i]
			while (match(b, /"socket":[ \t]*[0-9]+/)) {
				sock = substr(b, RSTART, RLENGTH)
				b = substr(b, RSTART + RLENGTH)
				if (!match(b, /"bytes":[ \t]*[0-9]+/)) break
				v = substr(b, RSTART, RLENGTH)
				sub(/.*:[ \t]*/, "", v)
				bytes[sock] += v
			}
		}
		for (sock in bytes) if (bytes[sock] == 0) stalled++
		print stalled + 0
	}' "$1"
}

iperf_error() {
	sed -n 's/.*"error":[[:space:]]*"\(.*\)".*/\1/p' "$1" | head -1
}

# Board sample -> one "port delta" line per port; "port -" when a counter is missing.
cpu_deltas() {
	awk '
	$1 == "@ports" { ports = $0; sub(/^@ports */, "", ports); next }
	/^@/ { phase = substr($1, 2); port = $2; next }
	/rx packets \[TOTAL\]/ { v = $0; sub(/.*:[ \t]*/, "", v); n[phase, port] = v; seen[phase, port] = 1 }
	END {
		k = split(ports, p, " ")
		for (i = 1; i <= k; i++) {
			if (seen["before", p[i]] && seen["after", p[i]])
				print p[i], n["after", p[i]] - n["before", p[i]]
			else
				print p[i], "-"
		}
	}' "$1"
}

# Board sample -> "accelerated masqueraded elsewhere": connections to the
# iperf3 server ($1) handed to the hardware, how many of those have a reply
# tuple rewritten by NAT, and how many more do not come from the client ($2,
# may be empty: any client). $4 narrows the count to one protocol.
conntrack_counts() {
	awk -v server="dst=$1 " -v client="$2" -v proto="${4:-}" '
	/^@/ { in_ct = ($1 == "@conntrack"); next }
	in_ct && /PERMANENT/ && index($0, server) && (proto == "" || $3 == proto) {
		ns = nd = 0
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^src=/) src[++ns] = $i
			if ($i ~ /^dst=/) dst[++nd] = $i
		}
		if (client != "" && src[1] != "src=" client) { other++; next }
		acc++
		if (ns >= 2 && nd >= 2 && substr(src[1], 5) != substr(dst[2], 5)) masq++
	}
	END { print acc + 0, masq + 0, other + 0 }' "$3"
}

# Board sample -> "on other": connections to the server ($2; to its port $3,
# when given) handed to the hardware whose answers come back to the address
# $4, the one of the WAN that masquerades them, and those whose answers come
# back to another address.
on_wan() { # file, server, port, WAN address
	awk -v server="dst=$2 " -v port="${3:+dport=$3 }" -v addr="$4" '
	/^@/ { in_ct = ($1 == "@conntrack"); next }
	in_ct && /PERMANENT/ && index($0, server) && (port == "" || index($0, port)) {
		nd = 0
		for (i = 1; i <= NF; i++) if ($i ~ /^dst=/) dst[++nd] = substr($i, 5)
		if (nd >= 2 && dst[2] == addr) on++; else other++
	}
	END { print on + 0, other + 0 }' "$1"
}

# Board answer -> packets that left a WAN port between its two snapshots
# ($2: wan or wan2), or nothing when a total is missing.
tx_left() { # file, wan|wan2
	set -- "$(value "$1" "$2_tx_before")" "$(value "$1" "$2_tx_after")"
	[ "$1" -ge 0 ] 2>/dev/null && [ "$2" -ge 0 ] 2>/dev/null && echo $(($2 - $1))
}

# Board sample of a traffic item -> packets that left a port in its window, or
# nothing when a total is missing.
port_left() { # file, port
	awk -v port="$2" '$1 == "tx" && $3 == port && $4 ~ /^[0-9]+$/ { n[$2] = $4; seen[$2] = 1 }
		END { if (seen["before"] && seen["after"]) print n["after"] - n["before"] }' "$1"
}

# Board sample -> rx packets that reached the CPU on all its ports together, or
# nothing when no port has a counter.
cpu_total() {
	cpu_deltas "$1" | awk '$2 != "-" { n += $2; seen = 1 } END { if (seen) print n }'
}

# The flattened get_net_stats.sh JSON on the "webui_<phase>=" line of a stats
# board answer -> the "sessions" count of a kind (total, tcp, udp), or nothing
# when the line or the number is missing.
stats_session() { # file, before|after, total|tcp|udp
	sed -n "s/^webui_$2=//p" "$1" | head -1 | awk -v key="$3" '
	{
		i = index($0, "\"sessions\"")
		if (!i) exit
		s = substr($0, i)
		if (match(s, "\"" key "\":[ ]*[0-9]+")) {
			v = substr(s, RSTART, RLENGTH); sub(/.*:[ ]*/, "", v); print v
		}
	}'
}

# The same JSON -> the byte counter (rx_bytes or tx_bytes) the script reported
# for an interface. The "interfaces" objects are flat, so splitting on braces
# gives one object each.
stats_ifbytes() { # file, before|after, iface, rx_bytes|tx_bytes
	sed -n "s/^webui_$2=//p" "$1" | head -1 | awk -v iface="$3" -v key="$4" '
	{
		n = split($0, part, /[{}]/)
		for (i = 1; i <= n; i++) {
			if (part[i] ~ ("\"interface\":\"" iface "\"") &&
			    match(part[i], "\"" key "\":[0-9]+")) {
				v = substr(part[i], RSTART, RLENGTH); sub(/.*:/, "", v); print v; exit
			}
		}
	}'
}

# The growth of a byte counter between the two answers, or nothing when either
# end is missing.
stats_grew() { # file, iface, rx_bytes|tx_bytes
	set -- "$(stats_ifbytes "$1" before "$2" "$3")" "$(stats_ifbytes "$1" after "$2" "$3")"
	[ -n "$1" ] && [ -n "$2" ] && echo $(($2 - $1))
}

# The br-lan ports of a stats board answer: its @ports line without the wan
# port ($2).
stats_lan_ports() { # file, wan port
	awk -v wan="$2" '$1 == "@ports" { for (i = 2; i <= NF; i++) if ($i != wan) printf "%s ", $i }' "$1"
}

# A count the web UI reported against the kernel's own, within STATS_SLACK.
stats_count_ok() { # file, total|tcp|udp, kernel count
	ui=$(stats_session "$1" after "$2")
	[ -n "$ui" ] || { why "the web UI reported no $2 connection count"; return; }
	[ -n "$3" ] || return
	diff=$((ui - $3)); [ "$diff" -ge 0 ] || diff=$((-diff))
	[ "$diff" -le "$STATS_SLACK" ] ||
		why "the web UI reported $ui $2 connection(s), the kernel's table held $3 (more than $STATS_SLACK apart)"
}

# A byte counter that grew by STATS_LOW..STATS_HIGH percent of the payload
# iperf3 carried in the window (bytes), with a reason otherwise.
stats_bytes_ok() { # file, iface, rx_bytes|tx_bytes, payload bytes, what it is
	grew=$(stats_grew "$1" "$2" "$3")
	[ -n "$grew" ] || { why "$5: the web UI reported no $3 for $2"; return; }
	lo=$(($4 * STATS_LOW / 100)); hi=$(($4 * STATS_HIGH / 100))
	[ "$grew" -ge "$lo" ] ||
		why "$5: $2 $3 grew by $grew bytes in $WINDOW s, need at least $lo (${STATS_LOW}% of the $4 bytes iperf3 carried): the counter does not include accelerated traffic"
	[ "$grew" -le "$hi" ] ||
		why "$5: $2 $3 grew by $grew bytes in $WINDOW s, more than $hi (${STATS_HIGH}% of the $4 bytes iperf3 carried)"
	stats_text="$stats_text, $2 $3 +$grew"
}

# Whether bmchwaccel answered a switch (disable or enable) of toggle_script
# with success; a reason with its answer when not.
toggle_answer() { # file, switch
	case "$(value "$1" "$2")" in
	'{"status":0,'*) ;;
	*) why "bmchwaccel $2: $(value "$1" "$2")"; return 1 ;;
	esac
}

# Board answer of toggle_script -> the counters that changed between the two
# snapshots of a window ($2: on, off or again), "name +delta" a line.
toggle_counters() { # file, window
	awk -F '\t' -v b="@snap $2-before" -v a="@snap $2-after" '
	/^@/ { sec = $0; next }
	sec == b { v0[$1] = $2; next }
	sec == a { v1[$1] = $2; order[++n] = $1 }
	END {
		for (i = 1; i <= n; i++) {
			k = order[i]
			if (k in v0 && v1[k] != v0[k]) printf "%s %+d\n", k, v1[k] - v0[k]
		}
	}' "$1"
}

# Board answer of toggle_script -> one line per second of its trace: the second
# of the iperf3 run, the Mbps iperf3 had in that second ($2: one number per
# second), whether the ping of that second came back ($3: one character per
# second), and for each port with a link the packets it received and sent,
# with "LINK +n" when its link went down or up in that second.
toggle_trace() { # file, Mbps per second, pings
	awk -v warmup="$WARMUP" -v start="$(value "$1" start)" -v mbps="$2" -v pings="$3" '
	BEGIN { split(mbps, m, " ") }
	$1 == "@trace" { on = 1; next }
	!on || $1 != "@tick" { next }
	{
		at = warmup + $2 - start
		i = int(at) + 1
		line = sprintf("%5.1f s %5s Mbps ping %s", at, (i in m) ? m[i] : "-", substr(pings, i, 1) == "" ? "-" : substr(pings, i, 1))
		for (j = 3; j + 3 <= NF; j += 4) {
			p = $j
			if (p in rx) {
				line = line sprintf("  %s rx %+7d tx %+7d", p, $(j + 1) - rx[p], $(j + 2) - tx[p])
				if ($(j + 3) != ch[p]) line = line sprintf(" LINK %+d", $(j + 3) - ch[p])
			}
			rx[p] = $(j + 1); tx[p] = $(j + 2); ch[p] = $(j + 3)
		}
		if (seen++) print line
	}' "$1"
}

# ping output -> one character per second from its start: "!" answered, "."
# not. macOS counts from 0 and names the lost ones, Linux counts from 1.
ping_seconds() { # file, seconds
	awk -v n="$2" '
	match($0, /icmp_seq[= ][0-9]+/) {
		seq = substr($0, RSTART + 9, RLENGTH - 9) + 0
		if (low == "" || seq < low) low = seq
		if (/bytes from/) ok[seq] = 1
	}
	END {
		first = (low == 0) ? 0 : 1
		for (i = 0; i < n; i++) printf "%s", ((i + first) in ok) ? "!" : "."
		printf "\n"
	}' "$1"
}

# Board answer of toggle_script -> the second of the iperf3 run at which a
# window began or ended. iperf3 started WARMUP seconds before the board script.
toggle_second() { # window, before|after
	awk -v warmup="$WARMUP" -v start="$(value "$TMP/toggle" start)" -v at="$(value "$TMP/toggle-$1" "$2")" '
	BEGIN { if (start != "" && at != "") printf "%.1f\n", warmup + at - start }'
}

# Board answer of toggle_script -> the sample of one of its windows.
toggle_window() { # file, window
	awk -v want="$2" '
	$1 == "@ports" { print; next }
	$1 == "@window" || $1 == "@answers" { on = ($1 == "@window" && $2 == want); next }
	on' "$1"
}

# Board answer of macs_script -> "port mac assign-type kind in-syslog" for every
# board port; kind is what the kernel warning says of a temporary MAC (stable
# or random). "-" for what the board did not report.
mac_table() {
	awk -v ports="$WAN_PORT $LAN_PORTS $LAN_OPTIONAL" '
	function v(x) { return x == "" ? "-" : x }
	$1 == "port" { mac[$2] = $3; type[$2] = $4 }
	$1 == "kernel" { kind[$2] = $4 }
	$1 == "syslog" { logged[$2] = "yes" }
	END {
		n = split(ports, p, " ")
		for (i = 1; i <= n; i++)
			print p[i], v(mac[p[i]]), v(type[p[i]]), v(kind[p[i]]), v(logged[p[i]])
	}' "$1" | sort
}

sha256() { { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1; }

# What sysupgrade said in its test mode, from the answer of upgrade check.
upgrade_said() { sed -n '/^@test$/,/^@rc /p' "$1" | sed -e '1d' -e '$d'; }

# The lines of a board answer between the line "@<name>" and the next line
# that starts with "@", or its end.
section() { # file, name
	awk -v name="@$2" '$0 == name { on = 1; next } /^@/ { on = 0 } on' "$1"
}

# ---- reporting

reasons=
why() { reasons="$reasons               - $*
"; }

report() { # item summary
	if [ -z "$reasons" ]; then
		printf '%-14s PASS  %s\n' "$1" "$2"
	else
		printf '%-14s FAIL  %s\n%s' "$1" "$2" "$reasons"
		rc=1
	fi
	reasons=
}

# ---- items

# The answer of boot_script in $TMP/boot -> a reason for everything that says
# hardware acceleration did not come up as it should in this boot.
boot_check() {
	cdx=$(value "$TMP/boot" cdx); cdx_ctrl=$(value "$TMP/boot" cdx_ctrl)
	case "$cdx" in *"lacks ASK support"*) why "CDX did not accept the FMan microcode" ;; esac
	[ "$cdx_ctrl" = yes ] || why "/dev/cdx_ctrl is missing"
	status_check "$TMP/boot" on
	# A daemon that died at boot and was started again still ends in "on".
	starts=$(value "$TMP/boot" starts)
	[ "$state" != on ] || [ "$starts" = 1 ] ||
		why "the daemon was started ${starts:-an unknown number of} times, need 1: it died and was started again"
}

item_boot() {
	board "$(boot_script)" > "$TMP/boot"
	kernel=$(value "$TMP/boot" kernel)
	[ "$kernel" = "$KERNEL" ] || why "kernel is $kernel, need $KERNEL"
	boot_check

	report boot "kernel $kernel; ${cdx:-no cdx line in dmesg}; bmchwaccel status: ${state:-no answer}"
	sed -n '/^@log$/,$p' "$TMP/boot" | sed -e 1d -e 's/^/               | /'
}

item_firewall() {
	board "$(firewall_script)" > "$TMP/firewall"
	iptables=$(value "$TMP/firewall" iptables); masq=$(value "$TMP/firewall" masq)

	[ "$(value "$TMP/firewall" fw3)" = yes ] || why "fw3 is not installed"
	[ "$(value "$TMP/firewall" fw4)" = no ] || why "fw4 is installed"
	case "$iptables" in *"(legacy)"*) ;; *) why "iptables is not the legacy variant" ;; esac
	[ "$(value "$TMP/firewall" zones)" -gt 0 ] 2>/dev/null || why "fw3 has not loaded its zone chains"
	[ "$masq" -gt 0 ] 2>/dev/null || why "no masquerade rule in the nat table"
	[ "$(value "$TMP/firewall" flow_uci)" != 1 ] || why "firewall.@defaults[0].flow_offloading is 1"
	[ "$(value "$TMP/firewall" flow_mod)" = 0 ] || why "a software flow offloading module is loaded"

	if [ -z "$reasons" ]; then
		report firewall "fw3 on $iptables, $masq masquerade rule(s); no fw4, no software flow offloading"
	else
		report firewall "${iptables:-no iptables}, ${masq:-0} masquerade rule(s)"
	fi
}

item_ports() {
	board "$(ports_script)" > "$TMP/ports"
	wan=$(value "$TMP/ports" wan); lan=$(value "$TMP/ports" lan)
	members=$(echo $(value "$TMP/ports" members))

	[ "$wan" = "$WAN_PORT" ] || why "wan is on ${wan:-no device}, need $WAN_PORT"
	[ "$lan" = br-lan ] || why "lan is on ${lan:-no device}, need br-lan"
	for p in $members; do
		case " $LAN_PORTS $LAN_OPTIONAL " in *" $p "*) ;; *) why "$p is in br-lan" ;; esac
	done
	out=
	for p in $(echo $LAN_PORTS $LAN_OPTIONAL | tr ' ' '\n' | sort); do
		case " $members " in *" $p "*) continue ;; esac
		out="$out $p"
		case " $LAN_PORTS " in *" $p "*) why "$p is not in br-lan" ;; esac
	done

	report ports "wan ${wan:-no device}; br-lan: ${members:-no port}${out:+; not in br-lan:$out}"
}

# mac: the board was given its MAC addresses. mac-temp: it was not, and the
# kernel made them up.
item_mac() { # mac | mac-temp
	item=$1
	board "ITEM=$item
$(macs_script)" > "$TMP/macs"
	mac_table "$TMP/macs" > "$TMP/mactable"
	text=; missing=; temp=; unwarned=; unlogged=; random=; not_local=
	while read -r port mac type kind logged; do
		text="$text, $port $mac"
		[ "$mac" != - ] || { missing="$missing $port"; continue; }
		[ "$type" != 1 ] && [ "$kind" = - ] || temp="$temp $port"
		case "$mac" in ?[26ae]:*) ;; *) not_local="$not_local $port=$mac" ;; esac
		[ "$kind" != - ] || { unwarned="$unwarned $port"; continue; }
		[ "$logged" = yes ] || unlogged="$unlogged $port"
		[ "$kind" = stable ] || random="$random $port"
	done < "$TMP/mactable"
	text=${text#, }

	[ -z "$missing" ] || why "no such port:$missing"
	if [ "$item" = mac ]; then
		[ -z "$temp" ] || why "temporary MAC, no MAC address from the bootloader:$temp"
		mac_duplicates
		[ -n "$reasons" ] || text="$text; from the bootloader"
		report mac "$text"
		return
	fi

	if [ -z "$temp" ]; then
		why "no port uses a temporary MAC: boot with the MAC variables removed from the U-Boot environment (bench.md)"
		report mac-temp "$text"
		return
	fi
	[ -z "$unwarned" ] || why "no temporary MAC warning in the kernel log:$unwarned"
	[ -z "$unlogged" ] || why "the warning is not in syslog (logread):$unlogged"
	[ -z "$random" ] || why "random, changes at every boot (the kernel could not read the SoC unique ID):$random"
	for m in $not_local; do
		why "${m%%=*}: ${m#*=} is not a locally administered unicast address"
	done
	mac_duplicates
	stays=
	before=$(value "$TMP/macs" previous)
	if [ -z "$before" ]; then
		stays="recorded on the board, run mac-temp again after a reboot to see that they stay"
	elif [ "$before" = "$(value "$TMP/macs" current)" ]; then
		stays="the same as before the reboot"
	else
		why "the temporary MACs changed across the reboot; before: $before"
	fi
	[ -n "$reasons" ] || text="$text; from the SoC unique ID, warned in the kernel log and in syslog; $stays"
	report mac-temp "$text"
}

mac_duplicates() {
	for m in $(awk '$2 != "-" { print $2 }' "$TMP/mactable" | sort | uniq -d); do
		why "$m is on more than one port"
	done
}

# What a traffic item needs: the wan mode and the VLANs of the board, the
# iperf3 server, the address of PC1 the connections must come from, and whether
# the board masquerades them. Over PPPoE the server is the peer of the session,
# known once the session is up: PC2 answers UDP from that address, whatever
# address the flow was sent to.
item_plan() {
	need_wan=plain; need_vlans=; server=$SERVER; client=; nat=1
	case "$1" in
	vlan-wan*)
		need_vlans=$VLAN_ID; client=$VLAN_CLIENT ;;
	vlan-vlan*|qos-vlan-vlan)
		need_wan=keep; need_vlans="$VLAN_ID $VLAN2_ID"
		server=$VLAN_SERVER; client=$VLAN_CLIENT; nat=0 ;;
	pppoe*)
		need_wan=pppoe; server=$PPPOE_SERVER ;;
	bridge-*)
		need_wan=keep; server=$BRIDGE_SERVER; nat=0 ;;
	ospf-*)
		server=$OSPF_TARGET; nat=0 ;;
	mwan-default)
		server=$MWAN_TARGET ;;
	mwan-*)
		server=$MWAN_TARGET2 ;;
	esac
}

# Bring the board to a layout, once per layout in a row, and say what had to
# be changed for it. Fails with the reasons set when the layout did not come up.
net_ready() { # wan mode, VLANs [, security mode]
	if [ "$1/$2/${3:-off}" != "$net_key" ]; then
		net_key="$1/$2/${3:-off}"
		# Set before the board is touched: an interrupted call has to be
		# undone as well, and undoing is harmless when nothing was changed.
		net_temporary=1
		board "WAN=$1
VLANS='$2'
MODE=${3:-off}
VLAN_PARENT='$VLAN_PARENT'
WAN_ADDR='$WAN_ADDR'
WAN_GW='$SERVER'
PPPOE_USER='$PPPOE_USER'
PPPOE_PASS='$PPPOE_PASS'
$(net_script)" > "$TMP/net"
		wan_dev=$(value "$TMP/net" dev); wan_addr=$(value "$TMP/net" addr)
		wan_peer=$(value "$TMP/net" peer)
		sed -n 's/^note=//p' "$TMP/net" | while read -r note; do
			printf '%-14s %s\n' net "$note"
		done
		net_failed=
		if [ -z "$wan_addr" ]; then
			case "$1" in
			plain) net_failed="wan (${wan_dev:-no device}) has no IPv4 address" ;;
			pppoe) net_failed="no PPPoE session on wan (${wan_dev:-no device}); is the PPPoE server running on PC2?" ;;
			esac
		fi
		for vid in $2; do
			[ -n "$(value "$TMP/net" "vlan$vid")" ] ||
				net_failed="${net_failed:+$net_failed; }VLAN $vid ($VLAN_PARENT.$vid) did not come up"
		done
		# A board without security modes (before they were brought over)
		# says nothing and forwards br-lan as mode off does.
		net_mode=$(value "$TMP/net" mode)
		[ -z "$net_mode" ] || [ "$net_mode" = "${3:-off}" ] ||
			net_failed="${net_failed:+$net_failed; }the board is in security mode $net_mode and did not switch to ${3:-off}"
		[ -z "$(value "$TMP/net" mode_said)" ] ||
			net_failed="${net_failed:+$net_failed; }the switch to security mode ${3:-off} did not go through: $(value "$TMP/net" mode_said)"
	fi
	[ -z "$net_failed" ] || { why "$net_failed"; return 1; }
}

# The ports of the board over WINDOW seconds, with what bmchwaccel says and
# the connections the hardware has, in $TMP/sample-<name>.
sample() { # name
	board "ITEM=$1
PORTS='$PORTS'
WINDOW=$WINDOW
$(sample_script)" > "$TMP/sample-$1"
}

# Run iperf3 for an item and read the board in the middle of the run: the
# sample is in $TMP/sample-<item>, the throughput in mbps. Fails with the item
# reported when the layout did not come up or iperf3 gave no result. With
# traffic_port set, iperf3 goes to that port of the server.
traffic() { # item [iperf3 option]
	item=$1
	reverse=${2:-}
	item_plan "$item"
	net_ready "$need_wan" "$need_vlans" || { report "$item" "not measured"; return 1; }
	server=${server:-$wan_peer}
	board "$(flush_script)"

	# shellcheck disable=SC2086
	"$IPERF3" -c "$server" ${traffic_port:+-p "$traffic_port"} ${client:+-B "$client"} -t "$DURATION" -P 4 -J \
		-T "$item" $reverse > "$TMP/iperf-$item.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	sample "$item"
	wait "$iperf_pid"
	iperf_pid=

	mbps=$(iperf_mbps "$TMP/iperf-$item.json")
	if [ -z "$mbps" ]; then
		err=$(iperf_error "$TMP/iperf-$item.json")
		why "iperf3: ${err:-no report; is \"iperf3 -s\" running on $server?}"
		[ -z "$client" ] || why "PC1 must have $client on VLAN $VLAN_ID and reach $server through it"
		report "$item" "no iperf3 result"
		return 1
	fi
}

measure() { # item [iperf3 option]
	traffic "$@" || return
	[ "$mbps" -ge "$MIN_MBPS" ] || why "$mbps Mbps is below $MIN_MBPS Mbps"
	accel_check "$TMP/sample-$item"

	failed=$reasons
	report "$item" "$mbps Mbps$(iperf_detail "$TMP/iperf-$item.json"); $accel_text"
	[ -z "$failed" ] || diag
}

# A board sample taken under the traffic of the planned item (item_plan) ->
# accel_text, with a reason for everything that says the traffic was not
# accelerated: packets on the CPU, the status, the connections the hardware
# has.
# A board sample under traffic -> state and counted from "bmchwaccel status",
# with a reason when it does not say on with at least one accelerated
# connection.
accel_status_ok() { # file
	status_check "$1" on
	counted=$(status_field "$1" accelerated)
	[ "$state" != on ] || [ "$counted" -gt 0 ] 2>/dev/null ||
		why "bmchwaccel status counts ${counted:-no} accelerated connections while iperf3 runs"
}

accel_check() { # file
	slow_links "$1"
	cpu_check "$1"
	accel_status_ok "$1"

	set -- $(conntrack_counts "$server" "$client" "$1")
	if [ $nat -eq 1 ]; then
		[ "$2" -gt 0 ] || why "no accelerated connection is masqueraded"
	else
		[ "$1" -gt 0 ] || why "no accelerated connection"
	fi
	[ "$3" -eq 0 ] ||
		why "$3 accelerated connection(s) to $server do not come from $client: PC1 is not sending through VLAN $VLAN_ID"
	accel_text="rx packets on the CPU in $WINDOW s: ${cpu_text#, }; $1 accelerated, $2 masqueraded; bmchwaccel status: ${state:-no answer}, ${counted:-?} accelerated"
}

# A board sample taken under traffic that has to stay on the CPU -> kept_text,
# with a reason for everything that says a part of it went through the
# hardware: too few packets on the CPU from the wan port or from the br-lan
# ports (one direction each), or a connection to the server (to its port $2,
# when given) that was handed to the hardware.
kept_check() { # file [, port]
	cpu_deltas "$1" > "$TMP/deltas"
	wan_pkts=$(awk -v w="$WAN_PORT" '$1 == w && $2 != "-" { print $2 }' "$TMP/deltas")
	lan_pkts=$(awk -v w="$WAN_PORT" '$1 != w && $2 != "-" { n += $2; seen = 1 } END { if (seen) print n }' "$TMP/deltas")
	[ -n "$wan_pkts" ] && [ -n "$lan_pkts" ] || why "the board reported no per-CPU rx packets counters"
	[ -z "$wan_pkts" ] || [ "$wan_pkts" -ge "$MAX_CPU_PKTS" ] ||
		why "$wan_pkts rx packets of $WAN_PORT reached the CPU in $WINDOW s, need at least $MAX_CPU_PKTS: what came in from wan went through the hardware"
	[ -z "$lan_pkts" ] || [ "$lan_pkts" -ge "$MAX_CPU_PKTS" ] ||
		why "$lan_pkts rx packets of the br-lan ports reached the CPU in $WINDOW s, need at least $MAX_CPU_PKTS: what came in from br-lan went through the hardware"
	status_check "$1" on
	handed=$(awk -v server="dst=$server " -v port="${2:+dport=$2 }" '
		/^@/ { in_ct = ($1 == "@conntrack"); next }
		in_ct && /PERMANENT/ && index($0, server) && (port == "" || index($0, port)) { n++ }
		END { print n + 0 }' "$1")
	[ "$handed" -eq 0 ] || why "$handed connection(s) to $server${2:+ port $2} were handed to the hardware"
	marked=$(value "$1" kept)
	kept_text="rx packets on the CPU in $WINDOW s: $WAN_PORT +${wan_pkts:-?}, br-lan ports +${lan_pkts:-?}; $handed handed to the hardware, ${marked:-?} connection(s) carry the mark; bmchwaccel status: ${state:-no answer}"
}

# The trial of the mark that keeps a connection on the CPU.
item_keep_mark() {
	item_plan keep-mark
	net_ready "$need_wan" "$need_vlans" || { report keep-mark "not tested"; return; }
	# Set before the board is touched, for cleanup: taking the rule away is
	# harmless.
	marking=1
	mark on > "$TMP/mark"
	[ "$(value "$TMP/mark" rules)" = 1 ] ||
		why "the board did not take the rule that marks the connections to port $DROP_PORT"
	[ "$(value "$TMP/mark" deny)" -ge 1 ] 2>/dev/null ||
		why "the daemon was not started with the rule that keeps marked connections out of the hardware"

	traffic_port=$DROP_PORT
	traffic keep-mark
	measured=$?
	traffic_port=
	if [ $measured -eq 0 ]; then
		tagged "marked connections" kept_check "$TMP/sample-keep-mark" "$DROP_PORT"
		marked_text="marked connections (port $DROP_PORT): $mbps Mbps, $kept_text"
		if traffic keep-mark-other; then
			[ "$mbps" -ge "$MIN_MBPS" ] || why "other connections: $mbps Mbps is below $MIN_MBPS Mbps"
			tagged "other connections" accel_check "$TMP/sample-keep-mark-other"
			report keep-mark "$marked_text; other connections: $mbps Mbps, $accel_text"
		fi
	fi
	mark off > /dev/null
	marking=0
}

# bmcqos on wan: its limit is kept (qos, qos-back), and what does not go
# through wan is accelerated all the same (qos-vlan-vlan).
item_qos() { # qos | qos-back | qos-vlan-vlan
	item=$1
	reverse=
	[ "$item" != qos-back ] || reverse=-R
	item_plan "$item"
	net_ready "$need_wan" "$need_vlans" || { report "$item" "not tested"; return; }
	# Set before the board is touched, for cleanup: turning it off puts the
	# configuration back, and is harmless when nothing was changed.
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

	if traffic "$item" $reverse; then
		if [ "$item" = qos-vlan-vlan ]; then
			[ "$mbps" -ge "$MIN_MBPS" ] || why "$mbps Mbps is below $MIN_MBPS Mbps"
			accel_check "$TMP/sample-$item"
			qos_text="$mbps Mbps$(iperf_detail "$TMP/iperf-$item.json"); $accel_text"
		else
			[ "$mbps" -le $((QOS_MBPS * 105 / 100)) ] ||
				why "$mbps Mbps is above the limit of $QOS_MBPS Mbps: the limit is not kept"
			[ "$mbps" -ge $((QOS_MBPS * 80 / 100)) ] ||
				why "$mbps Mbps is below 80 percent of the limit of $QOS_MBPS Mbps"
			kept_check "$TMP/sample-$item"
			qos_text="$mbps Mbps$(iperf_detail "$TMP/iperf-$item.json"); $kept_text"
		fi
		measured=0
	else
		measured=1
	fi
	qos off > "$TMP/qos-off"
	shaping=0
	[ $measured -eq 0 ] || return
	! value "$TMP/qos-off" status | grep -q '"reason":"bmcqos"' ||
		why "with bmcqos off again, bmchwaccel status still lists it as keeping traffic on the CPU"
	report "$item" "bmcqos on wan $qos_dev at $QOS_MBPS Mbps: $qos_text"
}

# ---- the web UI dashboard under accelerated traffic

# The connection counts and per-interface bytes the web UI shows (checkboxes 3
# and 4 of ticket 18), read from the very script the web UI calls. PC1 sends
# to PC2 as in brlan-wan, accelerated, with a low-rate UDP flow beside it.
item_stats() { # stats | stats-back
	item=$1
	reverse=; [ "$item" = stats-back ] && reverse=-R
	item_plan brlan-wan
	net_ready "$need_wan" "$need_vlans" || { report "$item" "not measured"; return; }
	server=${server:-$wan_peer}
	board "$(flush_script)"

	# A low-rate UDP flow beside the TCP run so the table has a UDP entry; it
	# need not be accelerated. It is started a second ahead of the TCP run so
	# the two do not race to be logged. Then the TCP run that must be.
	# shellcheck disable=SC2086
	"$IPERF3" -c "$server" -p "$DROP_PORT" -u -b "$STATS_UDP_RATE" -t "$DURATION" $reverse -J \
		-T "$item-udp" > "$TMP/iperf-$item-udp.json" 2>/dev/null &
	beside_pid=$!
	sleep 1
	# shellcheck disable=SC2086
	"$IPERF3" -c "$server" -t "$DURATION" -P 4 $reverse -J -T "$item" > "$TMP/iperf-$item.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	board "PORTS='$PORTS'
WINDOW=$WINDOW
$(stats_script)" > "$TMP/stats-$item"
	wait "$iperf_pid"; iperf_pid=
	kill "$beside_pid" 2>/dev/null; wait "$beside_pid" 2>/dev/null; beside_pid=

	mbps=$(iperf_mbps "$TMP/iperf-$item.json")
	if [ -z "$mbps" ]; then
		err=$(iperf_error "$TMP/iperf-$item.json")
		why "iperf3: ${err:-no report; is \"iperf3 -s\" running on $server?}"
		report "$item" "no iperf3 result"
		return
	fi
	if [ "$(value "$TMP/stats-$item" no_script)" = yes ]; then
		why "get_net_stats.sh is not on the board; the web UI package must be installed (ticket 12)"
		report "$item" "the dashboard script is missing"
		return
	fi

	# Accelerated: the status says on with a count, and a connection to PC2 is
	# masqueraded in the table.
	accel_status_ok "$TMP/stats-$item"
	set -- $(conntrack_counts "$server" "" "$TMP/stats-$item")
	[ "$2" -gt 0 ] || why "no accelerated connection to $server is masqueraded: the run was not accelerated"
	[ "$mbps" -ge "$MIN_MBPS" ] || why "$mbps Mbps is below $MIN_MBPS Mbps"

	# Connection counts: the web UI against the kernel's own table.
	stats_count_ok "$TMP/stats-$item" total "$(value "$TMP/stats-$item" ct_total)"
	stats_count_ok "$TMP/stats-$item" tcp "$(value "$TMP/stats-$item" ct_tcp)"
	stats_count_ok "$TMP/stats-$item" udp "$(value "$TMP/stats-$item" ct_udp)"
	[ "$(stats_session "$TMP/stats-$item" after tcp)" -ge 1 ] 2>/dev/null ||
		why "the web UI reported no TCP connection while the run was on"
	[ "$(stats_session "$TMP/stats-$item" after udp)" -ge 1 ] 2>/dev/null ||
		why "the web UI reported no UDP connection while the flow beside the run was on"

	# Interface bytes: the payload iperf3 carried in the window, and the band
	# the wan port (one direction) and the br-lan ports (the other) must grow by.
	span=$(iperf_span_mbps "$TMP/iperf-$item.json" "$WARMUP" "$((WARMUP + WINDOW))")
	wan=$(value "$TMP/stats-$item" wan_dev)
	stats_text=
	if [ -z "$span" ] || [ "$span" -le 0 ] 2>/dev/null; then
		why "iperf3 reported no throughput for the window [$WARMUP, $((WARMUP + WINDOW))] s; the interface bytes were not judged"
	else
		# Mbps over the window -> bytes of application payload in it.
		payload=$((span * 125000 * WINDOW))
		if [ "$item" = stats-back ]; then wan_dir=rx_bytes; lan_dir=tx_bytes; else wan_dir=tx_bytes; lan_dir=rx_bytes; fi
		stats_bytes_ok "$TMP/stats-$item" "$wan" "$wan_dir" "$payload" "wan port"
		# The br-lan ports together carry the other direction; PC1 is on one.
		lan_grew=0; lan_seen=
		for p in $(stats_lan_ports "$TMP/stats-$item" "$wan"); do
			g=$(stats_grew "$TMP/stats-$item" "$p" "$lan_dir")
			[ -n "$g" ] || continue
			lan_grew=$((lan_grew + g)); lan_seen=1
		done
		if [ -z "$lan_seen" ]; then
			why "br-lan ports: the web UI reported no $lan_dir"
		else
			lo=$((payload * STATS_LOW / 100)); hi=$((payload * STATS_HIGH / 100))
			[ "$lan_grew" -ge "$lo" ] ||
				why "br-lan ports: $lan_dir grew by $lan_grew bytes in $WINDOW s, need at least $lo (${STATS_LOW}% of the $payload bytes iperf3 carried): the counters do not include accelerated traffic"
			[ "$lan_grew" -le "$hi" ] ||
				why "br-lan ports: $lan_dir grew by $lan_grew bytes in $WINDOW s, more than $hi (${STATS_HIGH}% of the $payload bytes iperf3 carried)"
			stats_text="$stats_text, br-lan ports $lan_dir +$lan_grew"
		fi
	fi

	failed=$reasons
	report "$item" "$mbps Mbps; sessions total/tcp/udp $(stats_session "$TMP/stats-$item" after total)/$(stats_session "$TMP/stats-$item" after tcp)/$(stats_session "$TMP/stats-$item" after udp) vs kernel $(value "$TMP/stats-$item" ct_total)/$(value "$TMP/stats-$item" ct_tcp)/$(value "$TMP/stats-$item" ct_udp); bytes in $WINDOW s${stats_text}; bmchwaccel status: ${state:-no answer}, ${counted:-?} accelerated"
	[ -z "$failed" ] || diag
}

# ---- Multi-WAN

# The two WANs of the mwan items: sets mwan_wan and mwan_wan2, the addresses
# of wan and wan2, and reads the wan2 port with the others from here on.
# Fails with the reasons set.
mwan_start() {
	net_ready plain "" || return 1
	# Set before the board is touched, for cleanup: ending only undoes what
	# the board has a mark for.
	multiwan=1
	ports_given=$PORTS
	mwan setup > "$TMP/mwan"
	[ -z "$(value "$TMP/mwan" refused)" ] || { why "$(value "$TMP/mwan" refused)"; return 1; }
	mwan_wan=$(value "$TMP/mwan" wan_addr); mwan_wan2=$(value "$TMP/mwan" wan2_addr)
	[ "$(value "$TMP/mwan" wan)" = "up online" ] ||
		why "wan is \"$(value "$TMP/mwan" wan)\", need link up and Internet: does PC2 ($SERVER) answer the pings of the board?"
	[ "$(value "$TMP/mwan" wan2)" = "up online" ] ||
		why "wan2 ($MWAN_PORT, $MWAN_ADDR) is \"$(value "$TMP/mwan" wan2)\", need link up and Internet: is the PC of ISP B ($SERVER2) on $MWAN_PORT, and does it answer the pings of the board?"
	[ -n "$mwan_wan" ] && [ -n "$mwan_wan2" ] || why "the board gave no address for wan (${mwan_wan:-none}) or wan2 (${mwan_wan2:-none})"
	[ -n "$PORTS" ] || PORTS=$(value "$TMP/mwan" ports)
	[ -z "$reasons" ]
}

mwan_stop() {
	mwan end > /dev/null
	multiwan=0
	PORTS=$ports_given
}

# A board sample under traffic to the server of the planned item -> wan_text,
# with a reason when the hardware has no connection to it (to its port $2,
# when given) through the WAN $3 with the address $4, or has one through
# another WAN.
wan_check() { # file, port, WAN, its address
	set -- "$3" "$4" $(on_wan "$1" "$server" "$2" "$4")
	[ "$3" -gt 0 ] || why "no accelerated connection to $server leaves through $1 (translated to $2)"
	[ "$4" -eq 0 ] || why "$4 accelerated connection(s) to $server do not leave through $1 (translated to $2)"
	wan_text="$3 accelerated through $1"
}

# The same from the ports themselves, which is where the hardware sent: a
# board sample under traffic that has to leave through the WAN $2 (wan or
# wan2) alone -> ports_text, with a reason when fewer than MAX_CPU_PKTS
# packets left its port in the window, or as many left the port of the other
# WAN.
ports_check() { # file, WAN
	if [ "$2" = wan ]; then
		set -- "$1" wan "$wan_dev" wan2 "$MWAN_PORT"
	else
		set -- "$1" wan2 "$MWAN_PORT" wan "$wan_dev"
	fi
	through=$(port_left "$1" "$3"); beside=$(port_left "$1" "$5")
	if [ -z "$through" ] || [ -z "$beside" ]; then
		why "the board reported no tx packets totals for $3 and $5"
	else
		[ "$through" -ge "$MAX_CPU_PKTS" ] ||
			why "only $through packets left $3 ($2) in $WINDOW s, need at least $MAX_CPU_PKTS: the traffic does not leave through $2"
		[ "$beside" -lt "$MAX_CPU_PKTS" ] ||
			why "$beside packets left $5 ($4) in $WINDOW s, need fewer than $MAX_CPU_PKTS: the traffic leaves through $4"
	fi
	ports_text="in $WINDOW s ${through:-?} packets left $3 ($2) and ${beside:-?} $5 ($4)"
}

# A traffic run that has to be accelerated through one WAN, as its own result.
mwan_measure() { # item, WAN, its address
	traffic "$1" || return 1
	[ "$mbps" -ge "$MIN_MBPS" ] || why "$mbps Mbps is below $MIN_MBPS Mbps"
	accel_check "$TMP/sample-$1"
	wan_check "$TMP/sample-$1" "" "$2" "$3"
	ports_check "$TMP/sample-$1" "$2"
	failed=$reasons
	report "$1" "$mbps Mbps$(iperf_detail "$TMP/iperf-$1.json"); $wan_text; $ports_text; $accel_text"
	[ -z "$failed" ] || diag
}

# wan2 is made Mất Internet under an accelerated UDP flow that its Luật chọn
# WAN sends through it. Fails when wan2 did not get there.
mwan_lost() {
	item_plan mwan-lost
	board "$(flush_script)"
	"$IPERF3" -c "$server" -p "$MWAN_FLOW_PORT" -u -b "$DROP_RATE" -l "$DROP_LEN" \
		-t $((WARMUP + MWAN_WAIT + WINDOW + 30)) -J -T mwan-lost > "$TMP/iperf-mwan-lost.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	# The flow has to outlast the Chuyển WAN; an iperf3 that is gone gave up.
	if ! kill -0 "$iperf_pid" 2>/dev/null; then
		wait "$iperf_pid"
		iperf_pid=
		err=$(iperf_error "$TMP/iperf-mwan-lost.json")
		why "iperf3: ${err:-ended early}; is \"iperf3 -s -B $server -p $MWAN_FLOW_PORT\" running on both ISPs (a flow of an earlier run can keep it busy for 2 minutes)?"
		report mwan-lost "not tested"
		return 1
	fi
	mwan lose > "$TMP/mwan-lose"
	sending="PC1 was still sending"
	kill -0 "$iperf_pid" 2>/dev/null || sending="PC1 had stopped sending (iperf3: $(iperf_error "$TMP/iperf-mwan-lost.json"))"
	kill "$iperf_pid" 2>/dev/null
	wait "$iperf_pid" 2>/dev/null
	iperf_pid=

	# udp: the control connection of iperf3 is TCP to the same port.
	set -- $(conntrack_counts "$server" "" "$TMP/mwan-lose" udp)
	[ "$1" -gt 0 ] || why "the UDP flow was not accelerated before wan2 lost Internet, so nothing was tested (iperf3 gets no UDP answer unless the third server is bound to $server: iperf3 -s -B $server -p $MWAN_FLOW_PORT)"
	set -- $(on_wan "$TMP/mwan-lose" "$server" "$MWAN_FLOW_PORT" "$mwan_wan2")
	[ "$2" -eq 0 ] || why "before: $2 accelerated connection(s) to $server did not leave through wan2, where the Luật chọn WAN sends them"
	switch=$(value "$TMP/mwan-lose" switch)
	if [ -z "$switch" ]; then
		why "no Chuyển WAN in syslog $MWAN_WAIT s after the pings of wan2 to $SERVER2 were stopped; bmcmultiwan status has wan2 \"$(value "$TMP/mwan-lose" wan2)\""
		report mwan-lost "wan2 did not become Mất Internet"
		return 1
	fi
	removed=$(value "$TMP/mwan-lose" removed)
	[ "${removed:-0}" -ge 1 ] 2>/dev/null ||
		why "bmcMultiWAN removed no connection of wan2 at the Chuyển WAN (its syslog line: ${removed:-none})"
	left=$(tx_left "$TMP/mwan-lose" wan2); moved=$(tx_left "$TMP/mwan-lose" wan)
	if [ -z "$left" ] || [ -z "$moved" ]; then
		why "the board reported no tx packets totals for $wan_dev and $MWAN_PORT"
	else
		[ "$left" -lt "$MAX_CPU_PKTS" ] ||
			why "$left packets left $MWAN_PORT (wan2) in $WINDOW s after the Chuyển WAN, need fewer than $MAX_CPU_PKTS: connections still flow into the WAN that is Mất Internet"
		[ "$moved" -ge "$MAX_CPU_PKTS" ] ||
			why "only $moved packets left $wan_dev (wan) in $WINDOW s after the Chuyển WAN, need at least $MAX_CPU_PKTS: the flow did not move to wan, so nothing shows that wan2 was left; $sending"
	fi
	lost_text="Chuyển WAN after $(value "$TMP/mwan-lose" waited) s ($switch); ${removed:-0} connection(s) removed; in $WINDOW s after it ${left:-?} packets left $MWAN_PORT (wan2) and ${moved:-?} $wan_dev (wan); $sending"
	lost_failed=$reasons

	# The run of the new connection reports for itself when it gives no
	# result: the reasons so far stay with this result.
	reasons=
	if traffic mwan-new; then
		[ "$mbps" -ge "$MIN_MBPS" ] || why "new connection: $mbps Mbps is below $MIN_MBPS Mbps"
		tagged "new connection" accel_check "$TMP/sample-mwan-new"
		tagged "new connection" wan_check "$TMP/sample-mwan-new" "" wan "$mwan_wan"
		tagged "new connection" ports_check "$TMP/sample-mwan-new" wan
		new_text="$mbps Mbps, $wan_text; $ports_text; $accel_text"
	else
		why "new connection: no iperf3 result (mwan-new above)"
		new_text="not measured"
	fi
	reasons="$lost_failed$reasons"
	report mwan-lost "$lost_text; new connection: $new_text"
	# Second by second: what left the two WAN ports, and the answers of
	# ISP A and ISP B that were kept from the sender.
	[ -z "$lost_failed" ] || sed -n 's/^trace /               | /p' "$TMP/mwan-lose"
}

# wan2 has Internet again under a connection that was opened through wan.
mwan_back() {
	item_plan mwan-back
	board "$(flush_script)"
	"$IPERF3" -c "$server" -t $((2 * WARMUP + MWAN_WAIT + DURATION + 30)) -P 4 -J -T mwan-back-old \
		> "$TMP/iperf-mwan-back-old.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	if ! kill -0 "$iperf_pid" 2>/dev/null; then
		wait "$iperf_pid"
		iperf_pid=
		err=$(iperf_error "$TMP/iperf-mwan-back-old.json")
		why "iperf3: ${err:-ended early}; is \"iperf3 -s\" running on PC2, and does $server answer there?"
		report mwan-back "not tested"
		return
	fi
	mwan back > "$TMP/mwan-back"
	switch=$(value "$TMP/mwan-back" switch)
	if [ -z "$switch" ]; then
		kill "$iperf_pid" 2>/dev/null
		wait "$iperf_pid" 2>/dev/null
		iperf_pid=
		why "no Chuyển WAN in syslog $MWAN_WAIT s after the pings of wan2 to $SERVER2 were let through again; bmcmultiwan status has wan2 \"$(value "$TMP/mwan-back" wan2)\""
		report mwan-back "wan2 did not get Internet again"
		return
	fi
	"$IPERF3" -c "$server" -p "$DROP_PORT" -t "$DURATION" -P 4 -J -T mwan-back-new \
		> "$TMP/iperf-mwan-back-new.json" 2>/dev/null &
	probe_pid=$!
	sleep "$WARMUP"
	sample mwan-back
	wait "$probe_pid"
	probe_pid=
	kill -0 "$iperf_pid" 2>/dev/null ||
		why "open connection: iperf3 ended when wan2 had Internet again: $(iperf_error "$TMP/iperf-mwan-back-old.json")"
	kill "$iperf_pid" 2>/dev/null
	wait "$iperf_pid" 2>/dev/null
	iperf_pid=

	slow_links "$TMP/sample-mwan-back"
	cpu_check "$TMP/sample-mwan-back"
	status_check "$TMP/sample-mwan-back" on
	tagged "open connection" wan_check "$TMP/sample-mwan-back" "$IPERF_PORT" wan "$mwan_wan"
	old_text=$wan_text
	tagged "new connection" wan_check "$TMP/sample-mwan-back" "$DROP_PORT" wan2 "$mwan_wan2"
	# Both WANs carry one of the two connections now.
	for w in "wan $wan_dev" "wan2 $MWAN_PORT"; do
		carried=$(port_left "$TMP/sample-mwan-back" "${w#* }")
		[ "${carried:-0}" -ge "$MAX_CPU_PKTS" ] ||
			why "only ${carried:-no} packets left ${w#* } (${w%% *}) in $WINDOW s, need at least $MAX_CPU_PKTS: one of the two connections does not leave through ${w%% *}"
	done
	new_mbps=$(iperf_mbps "$TMP/iperf-mwan-back-new.json")
	[ -n "$new_mbps" ] ||
		why "new connection: iperf3: $(iperf_error "$TMP/iperf-mwan-back-new.json"); is \"iperf3 -s -p $DROP_PORT\" running on the PC of ISP B?"
	report mwan-back "Chuyển WAN after $(value "$TMP/mwan-back" waited) s ($switch); open connection: $old_text; new connection: ${new_mbps:-?} Mbps beside it, $wan_text; rx packets on the CPU in $WINDOW s: ${cpu_text#, }; bmchwaccel status: ${state:-no answer}"
}

item_mwan() {
	if mwan_start; then
		mwan_measure mwan-default wan "$mwan_wan"
		mwan_measure mwan-rule wan2 "$mwan_wan2"
		if mwan_lost; then mwan_back; fi
	else
		report mwan "not tested"
	fi
	mwan_stop
}

# A connection that comes in through wan2 is answered through wan2.
item_mwan_in() {
	if ! mwan_start; then
		mwan_stop
		report mwan-in "not tested"
		return
	fi
	PC1=${PC1:-$(value "$TMP/mwan" pc1)}
	mwan forward > "$TMP/mwan-forward"
	if [ -z "$PC1" ]; then
		why "the board does not know where the ssh session comes from; set PC1"
	elif [ "$(value "$TMP/mwan-forward" rules)" -ge 1 ] 2>/dev/null; then
		"$IPERF3" -s -1 -p "$IN_PORT" > /dev/null 2>&1 &
		listen_pid=$!
		# From an address that is not in the network of wan2: an answer
		# to that network leaves through wan2 whatever Multi-WAN does.
		printf '%-14s on the PC of ISP B run now:  iperf3 -c %s -p %s -B %s -t 60 -P 4\n' mwan-in "$mwan_wan2" "$FWD_PORT" "$MWAN_TARGET2"
		mwan inbound > "$TMP/mwan-in"
		kill "$listen_pid" 2>/dev/null
		listen_pid=
	else
		why "the board did not take the rule that forwards port $FWD_PORT of wan2 to $PC1:$IN_PORT"
	fi
	if [ -n "$reasons" ]; then
		in_text="not tested"
	elif [ "$(value "$TMP/mwan-in" seen)" -ge 1 ] 2>/dev/null; then
		cpu_check "$TMP/mwan-in"
		status_check "$TMP/mwan-in" on
		out=$(tx_left "$TMP/mwan-in" wan2); astray=$(tx_left "$TMP/mwan-in" wan)
		if [ -z "$out" ] || [ -z "$astray" ]; then
			why "the board reported no tx packets totals for $wan_dev and $MWAN_PORT"
		else
			[ "$out" -ge "$MAX_CPU_PKTS" ] ||
				why "only $out packets left $MWAN_PORT (wan2) in $WINDOW s, need at least $MAX_CPU_PKTS: the answers do not leave through the WAN the connection came in from, or the PC of ISP B stopped sending"
			[ "$astray" -lt "$MAX_CPU_PKTS" ] ||
				why "$astray packets left $wan_dev (wan) in $WINDOW s, need fewer than $MAX_CPU_PKTS: the answers leave through the WAN of the default Chính sách WAN"
		fi
		in_text="$(value "$TMP/mwan-in" seen) accelerated; in $WINDOW s ${out:-?} packets left $MWAN_PORT (wan2) and ${astray:-?} $wan_dev (wan); rx packets on the CPU: ${cpu_text#, }; bmchwaccel status: ${state:-no answer}"
	else
		why "no connection to port $FWD_PORT of wan2 ($mwan_wan2) was handed to the hardware within $IN_WAIT s; $(value "$TMP/mwan-in" translated) such connection(s) were translated to $PC1:$IN_PORT at all"
		in_text="not seen"
	fi
	mwan unforward > /dev/null
	mwan_stop
	report mwan-in "PC1 $PC1; wan2:$FWD_PORT to $PC1:$IN_PORT: $in_text"
}

# ---- DynRouting

# OSPF with the neighbour router over the Link định tuyến on the ports $1:
# reads those ports with the others from here on. Fails with the reasons set.
ospf_start() { # ports
	net_ready plain "" || return 1
	# Set before the board is touched, for cleanup: ending only undoes what
	# the board has a mark for.
	routing=1
	ports_given=$PORTS
	ospf_links=$1
	ospf_addrs=$OSPF_ADDR
	[ "$1" = "$OSPF_PORT" ] || ospf_addrs="$OSPF_ADDR $OSPF_ADDR2"
	ospf setup > "$TMP/ospf"
	[ -z "$(value "$TMP/ospf" refused)" ] || { why "$(value "$TMP/ospf" refused)"; return 1; }
	for p in $ospf_links; do
		[ "$(value "$TMP/ospf" "neighbor_$p")" -ge 1 ] 2>/dev/null ||
			why "no OSPF neighbour on $p $OSPF_WAIT s after OSPF was enabled: is the neighbour router on $p, with OSPF on that port as point-to-point in area 0 (bench.md)?"
	done
	ospf_route=$(value "$TMP/ospf" route)
	if [ -z "$ospf_route" ]; then
		why "OSPF gave the board no route to $OSPF_TARGET: does the neighbour router announce the network of that address?"
	elif [ "$(value "$TMP/ospf" via)" != "$OSPF_PORT" ]; then
		why "the board sends to $OSPF_TARGET through $(value "$TMP/ospf" via), need $OSPF_PORT (OSPF's route: $ospf_route)"
	fi
	[ -n "$PORTS" ] || PORTS=$(value "$TMP/ospf" ports)
	[ -z "$reasons" ]
}

ospf_stop() {
	ospf end > /dev/null
	routing=0
	PORTS=$ports_given
}

# A board sample under traffic that has to leave through the port $2 and, when
# $3 names one, not through that port -> port_text, with a reason when fewer
# than MAX_CPU_PKTS packets left $2 in the window or as many left $3.
carried_check() { # file, port, other port
	carried=$(port_left "$1" "$2")
	if [ -z "$carried" ]; then
		why "the board reported no tx packets total for $2"
	else
		[ "$carried" -ge "$MAX_CPU_PKTS" ] ||
			why "only $carried packets left $2 in $WINDOW s, need at least $MAX_CPU_PKTS: the traffic does not leave through the Link định tuyến on $2"
	fi
	port_text="in $WINDOW s ${carried:-?} packets left $2"
	[ -n "$3" ] || return 0
	beside=$(port_left "$1" "$3")
	[ "${beside:-0}" -lt "$MAX_CPU_PKTS" ] ||
		why "$beside packets left $3 in $WINDOW s, need fewer than $MAX_CPU_PKTS: the traffic leaves through the Link định tuyến on $3"
	port_text="$port_text and ${beside:-?} $3"
}

# A board sample under traffic to OSPF_TARGET that has to be accelerated
# through the Link định tuyến on the port $2 -> link_text.
link_check() { # file, port, other port
	accel_check "$1"
	set -- "$1" "$2" "$3" $(conntrack_counts "$server" "" "$1")
	[ "$5" -eq 0 ] ||
		why "$5 accelerated connection(s) to $server are masqueraded: a Link định tuyến is in a zone without NAT"
	carried_check "$1" "$2" "$3"
	link_text="$port_text; $accel_text"
}

# A traffic run that has to be accelerated through one Link định tuyến, as its
# own result.
ospf_measure() { # item, what happened before it, port, other port
	traffic "$1" || return 1
	[ "$mbps" -ge "$MIN_MBPS" ] || why "$mbps Mbps is below $MIN_MBPS Mbps"
	link_check "$TMP/sample-$1" "$3" "$4"
	failed=$reasons
	report "$1" "$2; $mbps Mbps$(iperf_detail "$TMP/iperf-$1.json"); $link_text"
	[ -z "$failed" ] || diag
}

# The board stops hearing the neighbour router under an accelerated UDP flow
# to the network it learned from it. Fails when OSPF did not withdraw the
# route.
ospf_withdrawn() {
	item_plan ospf-withdrawn
	board "$(flush_script)"
	"$IPERF3" -c "$server" -p "$OSPF_FLOW_PORT" -u -b "$DROP_RATE" -l "$DROP_LEN" \
		-t $((WARMUP + 2 * WINDOW + OSPF_WAIT + 30)) -J -T ospf-withdrawn > "$TMP/iperf-ospf-withdrawn.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	# The flow has to outlast the withdrawal; an iperf3 that is gone gave up.
	if ! kill -0 "$iperf_pid" 2>/dev/null; then
		wait "$iperf_pid"
		iperf_pid=
		err=$(iperf_error "$TMP/iperf-ospf-withdrawn.json")
		why "iperf3: ${err:-ended early}; is \"iperf3 -s -B $server -p $OSPF_FLOW_PORT\" running on the neighbour router (a flow of an earlier run can keep it busy for 2 minutes)?"
		report ospf-withdrawn "not tested"
		return 1
	fi
	sample ospf-flow
	ospf withdraw > "$TMP/ospf-withdraw"
	if [ "$(value "$TMP/ospf-withdraw" gone)" != yes ]; then
		kill "$iperf_pid" 2>/dev/null
		wait "$iperf_pid" 2>/dev/null
		iperf_pid=
		[ "$(value "$TMP/ospf-withdraw" blocked)" -ge 1 ] 2>/dev/null ||
			why "the board did not take the rule that drops the OSPF packets coming in, so it went on hearing the neighbour router"
		why "OSPF still has a route to $server $OSPF_WAIT s after the board stopped hearing the neighbour router (OSPF's route: $(value "$TMP/ospf-withdraw" route); neighbours on $OSPF_PORT: $(value "$TMP/ospf-withdraw" "neighbor_$OSPF_PORT"))"
		report ospf-withdrawn "the route was not withdrawn"
		return 1
	fi
	sample ospf-withdrawn
	sending="PC1 was still sending"
	kill -0 "$iperf_pid" 2>/dev/null || {
		sending="PC1 had stopped sending (iperf3: $(iperf_error "$TMP/iperf-ospf-withdrawn.json"))"
		why "$sending, so nothing shows that the hardware let go of the connection"
	}
	kill "$iperf_pid" 2>/dev/null
	wait "$iperf_pid" 2>/dev/null
	iperf_pid=

	# udp: the control connection of iperf3 is TCP to the same port.
	set -- $(conntrack_counts "$server" "" "$TMP/sample-ospf-flow" udp)
	[ "$1" -gt 0 ] ||
		why "the UDP flow was not accelerated before the route was withdrawn, so nothing was tested (iperf3 gets no UDP answer unless the third server is bound to $server: iperf3 -s -B $server -p $OSPF_FLOW_PORT)"
	before=$(port_left "$TMP/sample-ospf-flow" "$OSPF_PORT"); left=$(port_left "$TMP/sample-ospf-withdrawn" "$OSPF_PORT")
	if [ -z "$before" ] || [ -z "$left" ]; then
		why "the board reported no tx packets total for $OSPF_PORT"
	else
		[ "$before" -ge "$MAX_CPU_PKTS" ] ||
			why "before: only $before packets left $OSPF_PORT in $WINDOW s, need at least $MAX_CPU_PKTS: the flow did not leave through the Link định tuyến"
		[ "$left" -lt "$MAX_CPU_PKTS" ] ||
			why "$left packets left $OSPF_PORT in $WINDOW s after the route was withdrawn, need fewer than $MAX_CPU_PKTS: the hardware still sends the connection through the Link định tuyến of the route that is gone"
	fi
	set -- $(conntrack_counts "$server" "" "$TMP/sample-ospf-withdrawn" udp)
	now=$(value "$TMP/ospf-withdraw" via)
	failed=$reasons
	report ospf-withdrawn "route withdrawn after $(value "$TMP/ospf-withdraw" waited) s; in $WINDOW s ${before:-?} packets left $OSPF_PORT before and ${left:-?} after; the board now sends to $server through ${now:-no port}, $1 such UDP connection(s) in the hardware; $sending"
	item=ospf-withdrawn
	[ -z "$failed" ] || diag
	return 0
}

# The board hears the neighbour router again.
ospf_back() {
	ospf restore > "$TMP/ospf-restore"
	if [ "$(value "$TMP/ospf-restore" learned)" != yes ]; then
		why "the route to $OSPF_TARGET through $OSPF_PORT is not back $OSPF_WAIT s after the board heard the neighbour router again (OSPF's route: $(value "$TMP/ospf-restore" route); neighbours on $OSPF_PORT: $(value "$TMP/ospf-restore" "neighbor_$OSPF_PORT"))"
		report ospf-back "the route did not come back"
		return
	fi
	ospf_measure ospf-back "route back after $(value "$TMP/ospf-restore" waited) s" "$OSPF_PORT" ""
}

item_ospf() {
	if ospf_start "$OSPF_PORT"; then
		ospf_measure ospf-learned "OSPF's route: $ospf_route" "$OSPF_PORT" ""
		if ospf_withdrawn; then ospf_back; fi
	else
		report ospf "not tested"
	fi
	ospf_stop
}

# The route changes its next hop to the second Link định tuyến under one
# accelerated iperf3 run.
ospf_moved() {
	item_plan ospf-moved
	board "$(flush_script)"
	"$IPERF3" -c "$server" -t $((WARMUP + 2 * WINDOW + OSPF_MOVE_WAIT + OSPF_SETTLE + OSPF_TAIL)) -P 4 -J -T ospf-moved \
		> "$TMP/iperf-ospf-moved.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	sample ospf-before
	ospf move > "$TMP/ospf-move"
	if [ "$(value "$TMP/ospf-move" moved)" != yes ]; then
		kill "$iperf_pid" 2>/dev/null
		wait "$iperf_pid" 2>/dev/null
		iperf_pid=
		why "the board still sends to $server through $(value "$TMP/ospf-move" via) $OSPF_MOVE_WAIT s after the cost of $OSPF_PORT was raised above that of $OSPF_PORT2 (OSPF's route: $(value "$TMP/ospf-move" route))"
		report ospf-moved "the route did not move"
		return
	fi
	sample ospf-moved
	wait "$iperf_pid"
	iperf_pid=

	tagged before link_check "$TMP/sample-ospf-before" "$OSPF_PORT" "$OSPF_PORT2"
	before_text=$port_text
	tagged after link_check "$TMP/sample-ospf-moved" "$OSPF_PORT2" "$OSPF_PORT"
	mbps=$(iperf_mbps "$TMP/iperf-ospf-moved.json")
	if [ -z "$mbps" ]; then
		err=$(iperf_error "$TMP/iperf-ospf-moved.json")
		why "iperf3: ${err:-no report}: the TCP sessions did not last over the move, or \"iperf3 -s\" is not running on the neighbour router"
	else
		[ "$mbps" -ge "$MIN_MBPS" ] || why "$mbps Mbps over the whole run is below $MIN_MBPS Mbps"
		idle=$(iperf_idle "$TMP/iperf-ospf-moved.json" 0)
		[ "$idle" -le $OSPF_IDLE_MAX ] || why "iperf3 stood still in $idle of its seconds"
		stalled=$(iperf_stalled "$TMP/iperf-ospf-moved.json" $OSPF_TAIL)
		[ "${stalled:-0}" -eq 0 ] ||
			why "$stalled of the iperf3 streams carried nothing in the last $OSPF_TAIL s: its TCP session did not last"
	fi
	failed=$reasons
	report ospf-moved "route moved from $OSPF_PORT to $OSPF_PORT2 after $(value "$TMP/ospf-move" waited) s (OSPF's route: $(value "$TMP/ospf-move" route)); before: $before_text; after: $link_text; iperf3 over the move: ${mbps:-?} Mbps$(iperf_detail "$TMP/iperf-ospf-moved.json")"
	echo "               | Mbps each second: $(TIMELINE_BARS=0 iperf_timeline "$TMP/iperf-ospf-moved.json")"
	item=ospf-moved
	[ -z "$failed" ] || diag
}

# Both links at the same cost: what the board does with a route that has two
# next hops. Observed, not judged.
ospf_ecmp() {
	rc_before=$rc
	ospf ecmp > "$TMP/ospf-ecmp"
	if [ "$(value "$TMP/ospf-ecmp" both)" != yes ]; then
		why "OSPF's route to $OSPF_TARGET has no next hop on both $OSPF_PORT and $OSPF_PORT2 $OSPF_MOVE_WAIT s after both got the same cost (OSPF's route: $(value "$TMP/ospf-ecmp" route))"
		report ospf-ecmp "no route with two next hops"
	elif traffic ospf-ecmp; then
		accel_check "$TMP/sample-ospf-ecmp"
		report ospf-ecmp "OSPF's route: $(value "$TMP/ospf-ecmp" route); $mbps Mbps$(iperf_detail "$TMP/iperf-ospf-ecmp.json"); in $WINDOW s $(port_left "$TMP/sample-ospf-ecmp" "$OSPF_PORT" | grep . || echo '?') packets left $OSPF_PORT and $(port_left "$TMP/sample-ospf-ecmp" "$OSPF_PORT2" | grep . || echo '?') $OSPF_PORT2; $accel_text"
	fi
	rc=$rc_before
	echo "               (observed: does not count in RESULT)"
}

item_ospf_move() {
	if ospf_start "$OSPF_PORT $OSPF_PORT2"; then
		ospf_moved
		ospf_ecmp
	else
		report ospf-move "not tested"
	fi
	ospf_stop
}

# What the board knows about the traffic of a failed item, under its report.
diag() {
	board "ITEM=$item
SERVER='$server'
$(diag_script)" 2>&1 | sed 's/^/               | /'
}

# Run a check and put a tag before every reason it gives.
tagged() { # tag, check...
	tag=$1; shift
	kept=$reasons; reasons=
	"$@"
	tagged_rc=$?
	# In two steps: the dash of the build container drops the line end of
	# $kept when a command substitution without output follows it in one word.
	new=$(printf '%s' "$reasons" | sed "s/^               - /               - $tag: /")
	[ -z "$new" ] || new="$new
"
	reasons="$kept$new"
	return $tagged_rc
}

# Board sample -> a reason for every port with a link below 1000 Mbps: such an
# item measures the cable or the PC on it, not the board. Its link changes go
# with it.
slow_links() { # file, what the sample belongs to
	# Not a pipeline: why has to run in this shell.
	for slow in $(awk '$1 == "link" && $4 + 0 > 0 && $4 + 0 < 1000 { print $2 ":" $4 ":" $6 }' "$1"); do
		set -- "$1" "${2:-}" "${slow%%:*}" "$(echo "$slow" | cut -d: -f2)" "${slow##*:}"
		why "${2:+$2: }$3 has a link of $4 Mbps ($5 link changes since the boot): check the cable and the PC on it before reading the result"
	done
}

# Board sample -> cpu_text ", port +delta" for every port, with a reason for
# each port that passed MAX_CPU_PKTS packets to the CPU or has no counter.
cpu_check() {
	cpu_text=
	cpu_deltas "$1" > "$TMP/deltas"
	[ -s "$TMP/deltas" ] || why "the board reported no port counters"
	while read -r port delta; do
		if [ "$delta" = - ]; then
			why "$port: no per-CPU rx packets counter"
			cpu_text="$cpu_text, $port ?"
			continue
		fi
		cpu_text="$cpu_text, $port +$delta"
		[ "$delta" -lt "$MAX_CPU_PKTS" ] ||
			why "$port: $delta rx packets reached the CPU, need fewer than $MAX_CPU_PKTS"
	done < "$TMP/deltas"
}

# End the PPPoE session under an accelerated UDP flow. While the session is
# down the hardware must have let go of the flow: nothing leaves the wan port,
# and the packets PC1 keeps sending reach the CPU instead.
item_drop() {
	item_plan pppoe-drop
	net_ready "$need_wan" "$need_vlans" || { report pppoe-drop "not tested"; return; }
	server=${server:-$wan_peer}
	board "$(flush_script)"

	"$IPERF3" -c "$server" -p "$DROP_PORT" -u -b "$DROP_RATE" -l "$DROP_LEN" \
		-t $((WARMUP + WINDOW + REDIAL_MAX)) -J -T pppoe-drop > "$TMP/iperf-pppoe-drop.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	# The flow has to outlast the session; an iperf3 that is gone gave up.
	if ! kill -0 "$iperf_pid" 2>/dev/null; then
		wait "$iperf_pid"
		iperf_pid=
		err=$(iperf_error "$TMP/iperf-pppoe-drop.json")
		why "iperf3: ${err:-ended early}; is \"iperf3 -s -p $DROP_PORT\" running on $server?"
		report pppoe-drop "not tested"
		return
	fi
	dropping=1
	board "$(drop_env)
$(drop_script)" > "$TMP/drop"
	if [ -n "$(value "$TMP/drop" up)" ]; then
		dropping=0
	else
		# The board script did not get to its end (the SSH session broke):
		# take its rule and its access concentrator name away now, and ask
		# the board again what the wan looks like before the next item.
		board "$(drop_env)
$(undrop_script)" && dropping=0
	fi
	[ "$(value "$TMP/drop" up)" = yes ] || net_key=
	kill "$iperf_pid" 2>/dev/null
	wait "$iperf_pid" 2>/dev/null
	iperf_pid=

	before=$(value "$TMP/drop" session_before); after=$(value "$TMP/drop" session_after)
	# udp: the control connection of iperf3 is TCP to the same port.
	set -- $(conntrack_counts "$server" "" "$TMP/drop" udp)
	[ "$1" -gt 0 ] || why "the UDP flow was not accelerated before the session ended, so nothing was tested"
	if [ "$(value "$TMP/drop" down)" != yes ]; then
		why "the PPPoE session did not go down"
		report pppoe-drop "session ${before:-?}"
		return
	fi

	left=
	tx_before=$(value "$TMP/drop" wan_tx_before); tx_after=$(value "$TMP/drop" wan_tx_after)
	if [ "$tx_before" -ge 0 ] 2>/dev/null && [ "$tx_after" -ge 0 ] 2>/dev/null; then
		left=$((tx_after - tx_before))
		[ "$left" -lt "$MAX_CPU_PKTS" ] ||
			why "$left packets left $wan_dev while the session was down, need fewer than $MAX_CPU_PKTS"
	else
		why "the board reported no tx packets total for ${wan_dev:-the wan port}"
	fi
	cpu_deltas "$TMP/drop" > "$TMP/deltas"
	on_cpu=$(awk -v wan="$wan_dev" '$1 != wan && $2 != "-" { n += $2; seen = 1 } END { if (seen) print n }' "$TMP/deltas")
	if [ -z "$on_cpu" ]; then
		why "no per-CPU rx packets counter on the LAN ports"
	elif [ "$on_cpu" -lt "$MAX_CPU_PKTS" ]; then
		why "only $on_cpu packets reached the CPU from the LAN ports while the session was down: the hardware still has the flow, or PC1 stopped sending"
	fi
	if [ "$(value "$TMP/drop" up)" = yes ]; then
		back="back as session ${after:-?} with $(value "$TMP/drop" addr_after)"
	else
		back="not back"
		why "the PPPoE session did not come back"
	fi

	report pppoe-drop "session ${before:-?} ended for $WINDOW s: ${left:-?} packets left $wan_dev, ${on_cpu:-?} reached the CPU from the LAN ports; $back"
}

# Does routing out of br-lan need the auto_bridge module? Measure without it.
# FAIL here answers the question; only a board left without the module or
# without cmm makes the run fail.
item_noab() {
	rc_before=$rc
	noab_experiment
	rc=$rc_before
	echo "               (experiment: does not count in RESULT)"
	[ $ab_unloaded -eq 0 ] || restore_autobridge
}

restore_autobridge() {
	autobridge load > "$TMP/ab"
	ab_unloaded=0
	[ "$(value "$TMP/ab" module)" = loaded ] && [ -n "$(value "$TMP/ab" cmm)" ] || {
		echo "acceptance: auto_bridge or cmm did not come back; reboot the board" >&2
		rc=1
	}
}

noab_experiment() {
	net_ready plain "" || { report brlan-wan-noab "not measured"; return; }
	ab_unloaded=1
	autobridge unload > "$TMP/ab"
	if [ "$(value "$TMP/ab" cmm_before)" = no ]; then
		ab_unloaded=0
		why "cmm is not running"
		report brlan-wan-noab "not measured"
		return
	fi
	if [ "$(value "$TMP/ab" module)" != absent ]; then
		# Nothing changed, and the board script has started cmm again.
		ab_unloaded=0
		why "auto_bridge cannot be unloaded: $(grep -v -E '^(module|cmm)=' "$TMP/ab" | tail -1)"
		report brlan-wan-noab "not measured"
		return
	fi
	if [ -n "$(value "$TMP/ab" cmm)" ]; then
		measure brlan-wan-noab
	else
		why "cmm does not run without auto_bridge"
		report brlan-wan-noab "not measured"
		sed -n '/^@log$/,$p' "$TMP/ab" | sed -e 1d -e 's/^/               | /'
	fi
}

# PC1 and PC2 on two br-lan ports, and the board as the image leaves it. Sets
# bridge_in and bridge_out, the ports of PC1 and PC2. Fails with the reasons
# set when there is nothing to measure between; a daemon that is not as the
# image starts it only gives its reasons.
bridge_start() {
	net_ready keep "" || return 1
	# Set before the board is touched, for cleanup: ending takes away a rule
	# that an interrupted run left.
	bridging=1
	block_server=$BRIDGE_SERVER
	bridge start > "$TMP/bridge"
	bridge_pc1=$(value "$TMP/bridge" pc1)
	pc1_mac=$(value "$TMP/bridge" pc1_mac)
	bridge_in=$(value "$TMP/bridge" pc1_port); bridge_out=$(value "$TMP/bridge" pc2_port)
	[ -n "$(value "$TMP/bridge" pc2_mac)" ] || {
		why "the board gets no answer from $BRIDGE_SERVER on br-lan: PC2 has to be on a br-lan port with that address (bench.md)"
		return 1
	}
	[ -n "$bridge_in" ] && [ -n "$bridge_out" ] || {
		why "the bridge has not learned the port of PC1 (${bridge_pc1:-no address; set PC1}, ${pc1_mac:-no MAC address}: ${bridge_in:-none}) or of PC2 ($BRIDGE_SERVER: ${bridge_out:-none})"
		return 1
	}
	[ "$bridge_in" != "$bridge_out" ] || {
		why "PC1 and PC2 are both behind $bridge_in: the board forwards nothing between them"
		return 1
	}
	[ "$(value "$TMP/bridge" nf_call)" = 1 ] ||
		why "bridge-nf-call-iptables is $(value "$TMP/bridge" nf_call | grep . || echo not there): no iptables rule sees traffic between two br-lan ports"
	bridge_daemon "$TMP/bridge"
	return 0
}

# PC1 on a br-lan port and PC2 behind wan, for a rule against a routed flow.
# Sets bridge_in, the port of PC1, and bridge_out, the wan device.
block_start() {
	net_ready plain "" || return 1
	bridging=1
	block_server=${wan_peer:-$SERVER}
	bridge start > "$TMP/bridge"
	bridge_pc1=$(value "$TMP/bridge" pc1)
	pc1_mac=$(value "$TMP/bridge" pc1_mac)
	bridge_in=$(value "$TMP/bridge" pc1_port); bridge_out=$wan_dev
	[ -n "$bridge_in" ] && [ -n "$bridge_out" ] || {
		why "the bridge has not learned the port of PC1 (${bridge_pc1:-no address; set PC1}, ${pc1_mac:-no MAC address}: ${bridge_in:-none}), or the board has no wan device (${bridge_out:-none})"
		return 1
	}
	bridge_daemon "$TMP/bridge"
	return 0
}

# A board answer -> a reason when the daemon is not the one the image starts,
# with -B and answering. Without -B two machines on br-lan ports are in the
# hardware as a pair of MAC addresses: nothing conntrack does takes them out.
bridge_daemon() { # file
	case "$(value "$1" daemon)" in
	cpu) ;;
	hardware) why "the daemon runs without -B: traffic between two br-lan ports is handed to the hardware by MAC address, not by connection ($(value "$1" cmdline))" ;;
	*) why "the daemon is not running" ;;
	esac
	status_check "$1" on
}

# Takes away what the item left on the board.
bridge_end() {
	bridge end > "$TMP/bridge-end"
	bridging=0
}

# Throughput between two br-lan ports: in the hardware, connection by
# connection, like what the board routes.
item_bridge() {
	bridge_start || { bridge_end; report bridge "not measured"; return; }
	ports_before=$PORTS
	PORTS="$bridge_in $bridge_out"
	traffic bridge-flow
	measured=$?
	PORTS=$ports_before
	[ $measured -eq 0 ] || { bridge_end; report bridge "not measured"; return; }
	slow_links "$TMP/sample-bridge-flow"
	on_cpu=$(cpu_total "$TMP/sample-bridge-flow")
	set -- $(conntrack_counts "$server" "" "$TMP/sample-bridge-flow")
	handed=$1
	[ "$mbps" -ge "$MIN_MBPS" ] || why "$mbps Mbps is below $MIN_MBPS Mbps"
	if [ -z "$on_cpu" ]; then
		why "the board reported no per-CPU rx packets counters for $bridge_in and $bridge_out"
	elif [ "$on_cpu" -ge "$MAX_CPU_PKTS" ]; then
		why "$on_cpu rx packets of $bridge_in and $bridge_out reached the CPU in $WINDOW s, at most $MAX_CPU_PKTS may: traffic between two br-lan ports is not in the hardware"
	fi
	[ "$handed" -ge 1 ] || why "no connection to $BRIDGE_SERVER was handed to the hardware"
	bridge_end
	report bridge "$bridge_in -> $bridge_out: $mbps Mbps$(iperf_detail "$TMP/iperf-bridge-flow.json"); rx packets on the CPU in $WINDOW s: $(cpu_deltas "$TMP/sample-bridge-flow" |
		awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $1, ($2 == "-" ? "?" : "+" $2) }'); $handed connection(s) to $server handed to the hardware"
}

# One feature against one running flow that the hardware carries: its rule is
# set by its own script, which is what has the connections of the blocked
# machine taken out of the hardware (bmchwaccel sweep). -> block_line, and
# blocked (yes, no, or nothing when it could not be told).
bridge_block() { # macfilter|clientctl|service|fido, item
	case "$1" in
	macfilter) feature=macfilter ;;
	clientctl) feature=client_control ;;
	service) feature='blocked services' ;;
	*) feature=bmcfido ;;
	esac
	blocked=
	title="$2-$1"
	"$IPERF3" -c "$block_server" -p "$DROP_PORT" -u -b "$DROP_RATE" -l "$DROP_LEN" \
		-t $((WARMUP + 2 * WINDOW + BRIDGE_SETTLE + 30)) -J -T "$title" > "$TMP/iperf-$title.json" 2>/dev/null &
	iperf_pid=$!
	sleep "$WARMUP"
	if ! kill -0 "$iperf_pid" 2>/dev/null; then
		wait "$iperf_pid"
		iperf_pid=
		err=$(iperf_error "$TMP/iperf-$title.json")
		block_line="$feature: no flow (iperf3: ${err:-ended early}; is \"iperf3 -s -p $DROP_PORT\" running on $block_server?)"
		why "$block_line"
		return
	fi
	bridge "$1" "$2" > "$TMP/block"
	kill "$iperf_pid" 2>/dev/null
	wait "$iperf_pid" 2>/dev/null
	iperf_pid=

	carried=$(value "$TMP/block" carried); cpu=$(value "$TMP/block" cpu)
	passed=$(value "$TMP/block" passed); counted=$(value "$TMP/block" counted)
	if [ "$(value "$TMP/block" rules)" != 1 ]; then
		verdict="the board did not take the rule ($(value "$TMP/block" said | grep . || echo no answer))"
	elif ! [ "$carried" -ge "$MAX_CPU_PKTS" ] 2>/dev/null; then
		verdict="no flow to block: ${carried:-no count of} packets left $bridge_out before the rule"
	elif ! [ "$cpu" -ge 0 ] 2>/dev/null || ! [ "$passed" -ge 0 ] 2>/dev/null; then
		verdict="no count of the packets on the CPU before the rule or out of $bridge_out under it"
	elif [ "$cpu" -ge "$MAX_CPU_PKTS" ]; then
		verdict="nothing shown: the flow was on the CPU before the rule, where every packet meets it"
	elif [ "$passed" -lt "$MAX_CPU_PKTS" ]; then
		blocked=yes
		verdict="blocked"
	else
		blocked=no
		verdict="NOT blocked"
	fi
	block_line="$feature: ${cpu:-?} rx packets of $bridge_in on the CPU and ${carried:-?} out of $bridge_out in $WINDOW s; under the rule ${passed:-?} out of $bridge_out, ${counted:-?} counted by the rule: $verdict"
	[ "$blocked" = yes ] || why "$feature: $verdict"
}

# The four features, one after the other -> block_said, what became of each,
# with a line for each added to block_lines.
bridge_rules() { # item
	block_said=
	block_lines=
	for rule in macfilter clientctl service fido; do
		bridge_block $rule "$1"
		block_lines="$block_lines               | $block_line
"
		case "$blocked" in yes) outcome=blocked ;; no) outcome="NOT blocked" ;; *) outcome="not tested" ;; esac
		block_said="${block_said:+$block_said, }$feature $outcome"
	done
}

# macfilter and client_control against a flow in the hardware between two
# br-lan ports.
item_bridge_block() {
	bridge_start || { bridge_end; report bridge-block "not tested"; return; }
	bridge_rules bridge-block
	bridge_end
	report bridge-block "a rule set against a running flow in the hardware, $bridge_in -> $bridge_out: $block_said"
	printf '%s' "$block_lines"
}

# A flow between two br-lan ports whose far end the board has no neighbour
# entry for runs on the CPU; the sweep has the kernel resolve it, and the
# flow, still running, goes to the hardware.
item_bridge_neigh() {
	bridge_start || { bridge_end; report bridge-neigh "not tested"; return; }
	try=1
	while :; do
		bridge neigh-gone bridge-neigh > "$TMP/neigh-gone"
		"$IPERF3" -c "$BRIDGE_SERVER" -t $((NEIGH_WARMUP + 2 * WINDOW + BRIDGE_SETTLE + 30)) -J -T bridge-neigh > "$TMP/iperf-bridge-neigh.json" 2>/dev/null &
		iperf_pid=$!
		sleep "$NEIGH_WARMUP"
		if ! kill -0 "$iperf_pid" 2>/dev/null; then
			wait "$iperf_pid"
			iperf_pid=
			err=$(iperf_error "$TMP/iperf-bridge-neigh.json")
			why "no flow (iperf3: ${err:-ended early}; is \"iperf3 -s\" running on $BRIDGE_SERVER?)"
			bridge_end
			report bridge-neigh "not tested"
			return
		fi
		bridge neigh bridge-neigh > "$TMP/neigh"
		kill "$iperf_pid" 2>/dev/null
		wait "$iperf_pid" 2>/dev/null
		iperf_pid=
		cpu=$(value "$TMP/neigh" cpu); carried=$(value "$TMP/neigh" carried)
		# cron swept between the entry being deleted and the first look: once more.
		[ $try -lt 2 ] && [ "$cpu" -lt "$MAX_CPU_PKTS" ] 2>/dev/null &&
			[ "$(value "$TMP/neigh" entry)" = 1 ] || break
		try=$((try + 1))
	done
	bridge_end
	cpu_under=$(value "$TMP/neigh" cpu_under); passed=$(value "$TMP/neigh" passed)
	if ! [ "$carried" -ge "$MAX_CPU_PKTS" ] 2>/dev/null; then
		why "no flow to read: ${carried:-no count of} packets left $bridge_out before the sweep"
	elif ! [ "$cpu" -ge 0 ] 2>/dev/null || ! [ "$cpu_under" -ge 0 ] 2>/dev/null; then
		why "no count of the packets of $bridge_in on the CPU"
	else
		[ "$cpu" -ge "$MAX_CPU_PKTS" ] ||
			why "nothing shown: without a neighbour entry of $BRIDGE_SERVER the flow was in the hardware already ($cpu rx packets of $bridge_in on the CPU in $WINDOW s; entry there at the first look: $(value "$TMP/neigh" entry | grep . || echo ?))"
		[ "$(value "$TMP/neigh" noted)" = 1 ] ||
			why "the firewall did not note $BRIDGE_SERVER as an end of a bridged connection (ipset bmchwaccel_bridged)"
		[ "$(value "$TMP/neigh" entry_swept)" = 1 ] ||
			why "the board has no neighbour entry of $BRIDGE_SERVER after the sweep ($(value "$TMP/neigh" said | grep . || echo no answer))"
		[ "$cpu_under" -lt "$MAX_CPU_PKTS" ] ||
			why "$cpu_under rx packets of $bridge_in reached the CPU in $WINDOW s after the sweep, at most $MAX_CPU_PKTS may: the flow did not go to the hardware"
		[ "$passed" -ge "$MAX_CPU_PKTS" ] 2>/dev/null ||
			why "the flow stopped: ${passed:-no count of} packets left $bridge_out after the sweep"
	fi
	[ "$(value "$TMP/neigh" cron)" -ge 1 ] 2>/dev/null || why "cron does not run bmchwaccel sweep (/etc/crontabs/root)"
	report bridge-neigh "$bridge_in -> $bridge_out, the board having no neighbour entry of $BRIDGE_SERVER: ${cpu:-?} rx packets of $bridge_in on the CPU and ${carried:-?} out of $bridge_out in $WINDOW s; after bmchwaccel sweep ${cpu_under:-?} on the CPU and ${passed:-?} out of $bridge_out"
}

# The same against a flow the board routes from br-lan to wan.
item_block() {
	block_start || { bridge_end; report block "not tested"; return; }
	bridge_rules block
	bridge_end
	report block "a rule set against a running flow in the hardware, $bridge_in -> $bridge_out (wan): $block_said"
	printf '%s' "$block_lines"
}

# Reboot the board with hardware acceleration disabled or enabled and wait for
# the new boot to finish; what that boot loaded and started is in $TMP/switch.
# Fails with the reasons set when the choice was not saved or the board did not
# come back.
reboot_with() { # disable|enable
	case "$1" in disable) want=0; booted=booted-off ;; *) want=1; booted=booted-on ;; esac
	# Set before the board is touched, for cleanup: enabling is harmless.
	disabled=1
	switch "$1" > "$TMP/switch"
	if [ "$(value "$TMP/switch" saved)" != $want ]; then
		why "bmchwaccel $1 did not save enabled=$want: $(value "$TMP/switch" answer)"
		return 1
	fi
	disabled=$((1 - want))
	wait_boot $booted
}

# Wait for the boot after the one whose "switch" answer is in $TMP/switch, the
# board being on its way down; the answer of the new boot replaces it, and
# waited is the seconds it took. Fails with a reason when no new boot came up.
wait_boot() { # what the looks at the board are called: booted-on|booted-off
	boot_before=$(value "$TMP/switch" boot_id)
	waited=0
	while [ $waited -lt "$UPGRADE_WAIT" ]; do
		sleep $UPGRADE_POLL
		waited=$((waited + UPGRADE_POLL))
		switch "$1" > "$TMP/switch" 2>/dev/null || continue
		boot_now=$(value "$TMP/switch" boot_id)
		[ -n "$boot_now" ] && [ "$boot_now" != "$boot_before" ] || continue
		[ "$(value "$TMP/switch" init)" = complete ] || continue
		return 0
	done
	why "the board did not come back from the reboot within $UPGRADE_WAIT s"
	return 1
}

# A boot with hardware acceleration disabled forwards on the CPU and loads
# nothing of ASK; enabling it again brings the next boot back to on.
item_off_boot() {
	reboot_with disable || { report off-boot "not tested"; return; }
	# The layout of earlier items is asked for again in the new boot.
	net_key=
	modules=$(value "$TMP/switch" modules)
	[ "$modules" = 0 ] ||
		why "${modules:-an unknown number of} ASK module(s) loaded in a boot with hardware acceleration disabled"
	off_text=
	if traffic off-boot; then
		status_check "$TMP/sample-off-boot" off
		counted=$(status_field "$TMP/sample-off-boot" accelerated)
		[ "$counted" = 0 ] || why "bmchwaccel status counts ${counted:-no number of} accelerated connections"
		set -- $(conntrack_counts "$server" "" "$TMP/sample-off-boot")
		[ "$1" -eq 0 ] || why "$1 connection(s) to $server were handed to the hardware"
		on_cpu=$(cpu_total "$TMP/sample-off-boot")
		if [ -z "$on_cpu" ]; then
			why "no per-CPU rx packets counter"
		elif [ "$on_cpu" -lt "$MAX_CPU_PKTS" ]; then
			why "only $on_cpu rx packets reached the CPU in $WINDOW s: the traffic does not go through the CPU"
		fi
		off_text="disabled: $mbps Mbps, ${on_cpu:-?} rx packets on the CPU in $WINDOW s, bmchwaccel status: ${state:-no answer}, ${counted:-?} accelerated; "
	fi
	# traffic has reported an item it could not measure. The board is enabled
	# again in any case.
	failed=$reasons
	reasons=
	if reboot_with enable; then
		net_key=
		status_check "$TMP/switch" on
		on_text="enabled again: bmchwaccel status: ${state:-no answer}"
	else
		on_text="enabled again: not back"
	fi
	reasons="$failed$reasons"
	[ -n "$off_text" ] || [ -n "$reasons" ] || return 0
	report off-boot "$off_text$on_text"
}

# One iperf3 run of SOAK seconds, accelerated from its first minute to its
# last, on a board that stays as it was.
item_soak() {
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
	# The looks at the board, in seconds of the run: every SOAK_EVERY seconds
	# and a last one that ends SOAK_MARGIN seconds before iperf3 does.
	last=$((SOAK - WINDOW - SOAK_MARGIN))
	at=$WARMUP; looks=0; worst=0
	while :; do
		# A look that would still run when the last one is due gives way to it.
		[ $((at + WINDOW + SOAK_MARGIN)) -lt $last ] || at=$last
		ahead=$((began + at - $(date +%s)))
		[ $ahead -le 0 ] || sleep $ahead
		# iperf3 gone without a result: the rest of the hour would measure
		# nothing.
		kill -0 "$iperf_pid" 2>/dev/null || [ -n "$(iperf_mbps "$TMP/iperf-soak.json")" ] || break
		sample soak
		tagged "second $at" accel_check "$TMP/sample-soak"
		on_cpu=$(cpu_total "$TMP/sample-soak")
		[ "${on_cpu:-0}" -le $worst ] || worst=$on_cpu
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
		[ "$mbps" -ge "$MIN_MBPS" ] || why "$mbps Mbps is below $MIN_MBPS Mbps"
		first=$(iperf_span_mbps "$TMP/iperf-soak.json" 0 $SOAK_SPAN)
		final=$(iperf_span_mbps "$TMP/iperf-soak.json" $((SOAK - SOAK_SPAN)))
		if [ -z "$first" ] || [ -z "$final" ]; then
			why "the iperf3 report does not reach from second 0 to second $SOAK: the run ended early"
		elif [ $((final * 100)) -lt $((first * (100 - SOAK_DROP))) ]; then
			why "the last minute carried $final Mbps, the first $first Mbps: more than $SOAK_DROP % lower"
		fi
		speed="$mbps Mbps over $SOAK s, first minute ${first:-?}, last minute ${final:-?}$(iperf_detail "$TMP/iperf-soak.json" | sed 's/slowest second/slowest minute/')"
	fi

	for key in boot_id daemon starts; do
		was=$(value "$TMP/soak-start" $key); now=$(value "$TMP/soak-end" $key)
		[ -n "$now" ] && [ "$was" = "$now" ] || case $key in
		boot_id) why "the board is in another boot than at the start: it rebooted under the run" ;;
		daemon)  if [ -z "$was$now" ]; then why "no daemon process, at the start or at the end"
			 else why "the daemon process was ${was:-none} at the start and is ${now:-none} now: it died under the run"; fi ;;
		starts)  why "the daemon was started ${now:-an unknown number of} times, ${was:-an unknown number} at the start" ;;
		esac
	done
	modules=$(value "$TMP/soak-end" modules)
	[ "$modules" = 3 ] || why "${modules:-an unknown number of} of the 3 ASK modules are loaded at the end"
	status_check "$TMP/soak-end" on "at the end"
	[ "$(value "$TMP/soak-end" kernel_mark)" = yes ] ||
		why "the kernel log no longer has the mark of the start: its lines of the run cannot be told from older ones"
	[ "$(value "$TMP/soak-end" syslog_mark)" = yes ] ||
		why "syslog no longer has the mark of the start: its lines of the run cannot be told from older ones"
	trouble=$(section "$TMP/soak-end" trouble | grep -c .)
	[ "$trouble" -eq 0 ] || why "$trouble kernel line(s) of the run tell of trouble (marked ! below)"
	logged=$(section "$TMP/soak-end" syslog | grep -c 'bmcHwAccel: ')
	[ "$logged" -eq 0 ] ||
		why "$logged bmcHwAccel syslog line(s) under the run: hardware acceleration was switched or became unavailable"
	free_was=$(value "$TMP/soak-start" free_kb); free_now=$(value "$TMP/soak-end" free_kb)

	failed=$reasons
	report soak "$speed; $looks looks at the board, at most $worst rx packets on the CPU in $WINDOW s; bmchwaccel status at the end: ${state:-no answer}; memory available: ${free_was:-?} kB at the start, ${free_now:-?} kB at the end"
	[ -z "$mbps" ] || echo "               | Mbps of every minute: $(TIMELINE_BARS=0 iperf_timeline "$TMP/iperf-soak.json")"
	# The kernel lines that tell of trouble, then the last kernel lines of the
	# run, then what the daemon and bmcHwAccel wrote to syslog.
	section "$TMP/soak-end" trouble | sed 's/^/               ! /'
	section "$TMP/soak-end" kernel | sed 's/^/               | /'
	section "$TMP/soak-end" syslog | sed -e '/bmcHwAccel: /s/^/               ! /' -e '/^               ! /!s/^/               | /'
	[ -z "$failed" ] || diag
}

# REBOOTS boots in a row, each of which must come up with hardware
# acceleration on and accelerate the traffic of brlan-wan.
item_reboots() {
	item=reboots
	item_plan brlan-wan
	n=0
	while [ $n -lt "$REBOOTS" ]; do
		n=$((n + 1))
		switch reboot > "$TMP/switch"
		# Without the boot the board was in, a new one cannot be told from it.
		[ -n "$(value "$TMP/switch" boot_id)" ] || {
			why "boot $n: the board did not take the reboot command"
			report reboots "stopped before boot $n of $REBOOTS"
			return
		}
		tagged "boot $n" wait_boot booted-on || {
			report reboots "boot $n of $REBOOTS did not come up"
			return
		}
		back=$waited
		modules=$(value "$TMP/switch" modules)
		[ "$modules" = 3 ] || why "boot $n: ${modules:-an unknown number of} of the 3 ASK modules are loaded"
		trouble=$(value "$TMP/switch" trouble)
		section "$TMP/switch" trouble > "$TMP/boot-trouble"
		# The layout of earlier boots is asked for again in the new one.
		net_key=
		board "$(boot_script)" > "$TMP/boot"
		tagged "boot $n" boot_check
		traffic reboots || {
			printf '%-14s %s\n' reboots "stopped in boot $n of $REBOOTS, which could not be measured"
			return
		}
		tagged "boot $n" accel_check "$TMP/sample-reboots"
		printf '%-14s boot %s of %s: back after %s s; %s kernel line(s) of trouble; %s Mbps; %s\n' \
			reboots $n "$REBOOTS" "$back" "${trouble:-?}" "$mbps" "$accel_text"
		[ -z "$reasons" ] || break
	done
	failed=$reasons
	if [ -z "$failed" ]; then
		report reboots "$n boots, hardware acceleration on and the traffic accelerated in each"
	else
		report reboots "boot $n of $REBOOTS failed; stopped there, the board is still in that boot"
		sed 's/^/               ! /' "$TMP/boot-trouble"
		section "$TMP/boot" log | sed 's/^/               | /'
		diag
	fi
}

# key=value lines from the kernel lines of boottime_script; seconds are those
# of the kernel log. A kernel that does not log the upload time is measured
# from "loading firmware" to the FMan line, the first thing probed after it.
boottime_values() { # file
	sed -n '/^@kernel$/,/^@phy$/p' "$1" | awk '
	function ts(line) { sub(/^\[ */, "", line); sub(/\].*/, "", line); return line }
	/FMan-Controller code/ { if (start != "" && gap == "") gap = ts($0) - start }
	/MDC frequency set to/ {
		mdc = $0; sub(/.*set to /, "", mdc); sub(/ Hz.*/, "", mdc)
		was = $0; sub(/.*\(was /, "", was); sub(/ Hz.*/, "", was)
	}
	/loading firmware version/ { start = ts($0) }
	/firmware loaded in/ { took = $0; sub(/.*loaded in /, "", took); sub(/ ms.*/, "", took); took /= 1000 }
	/CRC mismatch|firmware loading failed|failed to find FW|bad firmware|invalid .* in firmware/ {
		if (error == "") { error = $0; sub(/^[^:]*:[^:]*: /, "", error) }
	}
	/fsl_dpa: Probed interface/ {
		if (first == "") first = ts($0)
		last = ts($0); ports = ports (ports == "" ? "" : " ") $NF
	}
	/entered forwarding state/ { if (forwarding == "") forwarding = ts($0) }
	END {
		if (mdc != "") print "mdc=" mdc "\nmdc_was=" was
		if (start != "") printf "start=%.1f\n", start
		if (took != "") printf "took=%.1f\n", took
		else if (gap != "") printf "gap=%.1f\n", gap
		if (error != "") print "error=" error
		if (first != "") {
			printf "probed=%.1f", first
			if (sprintf("%.1f", first) != sprintf("%.1f", last)) printf " to %.1f", last
			print ""; print "ports=" ports
		}
		if (forwarding != "") printf "forwarding=%.1f\n", forwarding
	}'
}

# How long the boot waited for the firmware of the 10G copper PHY, and whether
# the port still has its PHY.
item_boot_time() {
	board "$(boottime_script)" > "$TMP/boottime"
	boottime_values "$TMP/boottime" > "$TMP/boottime.values"
	start=$(value "$TMP/boottime.values" start); took=$(value "$TMP/boottime.values" took)
	gap=$(value "$TMP/boottime.values" gap); error=$(value "$TMP/boottime.values" error)
	mdc=$(value "$TMP/boottime.values" mdc); probed=$(value "$TMP/boottime.values" probed)
	forwarding=$(value "$TMP/boottime.values" forwarding)
	port=$(value "$TMP/boottime" port); phy=$(value "$TMP/boottime" phy)

	if [ -n "$error" ]; then
		why "the PHY firmware upload failed: $error"
		upload="PHY firmware upload failed"
	elif [ -n "$took" ]; then
		upload="PHY firmware upload $took s from second $start"
	elif [ -n "$gap" ]; then
		upload="PHY firmware upload about $gap s from second $start (to the FMan line; this kernel does not log the time)"
	elif [ -n "$start" ]; then
		upload="PHY firmware upload from second $start, end not in the kernel log"
	else
		upload="no PHY firmware upload in this boot (the PHY had its firmware already: power the board off and on to measure)"
	fi
	if [ -n "$mdc" ]; then
		upload="$upload; MDC $mdc Hz, was $(value "$TMP/boottime.values" mdc_was) Hz"
	else
		upload="$upload; MDC not set by the kernel"
		# Only the kernel that sets MDC logs the upload time.
		[ -z "$took" ] || why "the kernel did not set the MDC frequency (dmesg | grep xmdio says why)"
	fi
	[ -n "$port" ] || why "no port on $PHY_PORT_DEVICE: the 10G copper port is missing"
	case "$phy" in
	Aquantia*) ;;
	*) [ -z "$port" ] || why "$port has no Aquantia PHY (${phy:-none}): the 10G copper port lost its PHY" ;;
	esac

	report boot-time "$upload; ports probed at second ${probed:-?} ($(value "$TMP/boottime.values" ports)); br-lan forwarding at second ${forwarding:-?}; ${port:-10G copper port} PHY: ${phy:-none}"
	sed -n '/^@kernel$/,/^@phy$/p' "$TMP/boottime" | sed -e '1d' -e '$d' -e 's/^/               | /'
}

# A card with the public FMan microcode: hardware acceleration is unavailable
# and says why, and the board still routes and masquerades, on the CPU.
item_ucode_public() {
	board "$(boot_script)" > "$TMP/boot"
	cdx=$(value "$TMP/boot" cdx)
	case "$cdx" in
	*"lacks ASK support"*) ;;
	*) why "the card does not carry the public microcode (${cdx:-no cdx line in dmesg})" ;;
	esac
	status_check "$TMP/boot" unavailable
	reason=$(status_field "$TMP/boot" reason)
	[ "$reason" = microcode ] || why "bmchwaccel status gives the reason ${reason:-none}, need microcode"
	logged=$(value "$TMP/boot" logged)
	case "$logged" in
	*unavailable*microcode*) ;;
	*) why "the last syslog line of bmcHwAccel does not say unavailable for the microcode (${logged:-none})" ;;
	esac
	found="${cdx:-no cdx line in dmesg}; bmchwaccel status: ${state:-no answer}${reason:+ ($reason)}"

	# traffic reports an item it could not measure.
	traffic ucode-public || return 0
	set -- $(conntrack_counts "$server" "" "$TMP/sample-ucode-public")
	[ "$1" -eq 0 ] || why "$1 connection(s) to $server were handed to the hardware"
	on_cpu=$(cpu_total "$TMP/sample-ucode-public")
	if [ -z "$on_cpu" ]; then
		why "no per-CPU rx packets counter"
	elif [ "$on_cpu" -lt "$MAX_CPU_PKTS" ]; then
		why "only $on_cpu rx packets reached the CPU in $WINDOW s: the traffic does not go through the CPU"
	fi
	report ucode-public "$found; $mbps Mbps, ${on_cpu:-?} rx packets on the CPU in $WINDOW s"
}

# Disable and enable hardware acceleration under one iperf3 run, from PC1 to
# PC2 (toggle) or from PC2 to PC1 (toggle-back, iperf3 -R). The run can
# only reach MIN_MBPS at its end with the TCP sessions it opened at its start,
# so that also tells that they lasted through both switches.
item_toggle() { # toggle | toggle-back
	item=$1
	reverse=
	[ "$item" != toggle-back ] || reverse=-R
	item_plan toggle
	net_ready "$need_wan" "$need_vlans" || { report "$item" "not tested"; return; }
	board "$(flush_script)"

	run=$((WARMUP + 3 * WINDOW + TOGGLE_SETTLE + TOGGLE_SWITCH_MAX + TOGGLE_TAIL))
	ping -i 1 -c "$run" "$server" > "$TMP/ping-toggle" 2>&1 &
	ping_pid=$!
	"$IPERF3" -c "$server" -t "$run" -P 4 -J -T "$item" $reverse > "$TMP/iperf-$item.json" 2>/dev/null &
	iperf_pid=$!
	# A new connection while disabled: about 4 s into that window, which starts
	# a moment after the first one ends.
	probe_at=$((WARMUP + WINDOW + 4))
	( sleep "$probe_at"
	  "$IPERF3" -c "$server" -p "$DROP_PORT" -t 5 -J -T "$item-probe" $reverse > "$TMP/iperf-$item-probe.json" 2>/dev/null ) &
	probe_pid=$!
	sleep "$WARMUP"
	# Set before the board is touched, for cleanup: enabling is harmless.
	disabled=1
	board "PORTS='$PORTS'
WINDOW=$WINDOW
SETTLE=$TOGGLE_SETTLE
$(toggle_script)" > "$TMP/toggle" 2>&1
	wait "$iperf_pid"
	iperf_pid=
	wait "$probe_pid"
	probe_pid=
	kill "$ping_pid" 2>/dev/null
	wait "$ping_pid" 2>/dev/null
	ping_pid=
	for w in on off again; do
		toggle_window "$TMP/toggle" $w > "$TMP/toggle-$w"
	done
	case "$(value "$TMP/toggle" enable)" in '{"status":0,'*) disabled=0 ;; esac

	mbps=$(iperf_mbps "$TMP/iperf-$item.json")
	err=$(iperf_error "$TMP/iperf-$item.json")
	if [ -z "$mbps" ] && [ -z "$err" ]; then
		why "iperf3: no report; is \"iperf3 -s\" running on $server?"
		report "$item" "not tested"
		return
	fi
	[ -z "$err" ] || why "iperf3 did not run through: $err"

	# iperf3 while each window was open.
	for w in on off again; do
		eval "from_$w=\$(toggle_second $w before) to_$w=\$(toggle_second $w after)"
	done
	mbps_on=; mbps_off=; mbps_again=
	[ -z "$to_on" ] || mbps_on=$(iperf_span_mbps "$TMP/iperf-$item.json" "$from_on" "$to_on")
	[ -z "$to_off" ] || mbps_off=$(iperf_span_mbps "$TMP/iperf-$item.json" "$from_off" "$to_off")

	cpu_on=$(cpu_total "$TMP/toggle-on")
	slow_links "$TMP/toggle-on" before
	status_check "$TMP/toggle-on" on before
	[ "$cpu_on" -lt "$MAX_CPU_PKTS" ] 2>/dev/null ||
		why "before: ${cpu_on:-no counter of} rx packets reached the CPU, need fewer than $MAX_CPU_PKTS: the traffic was not accelerated, so nothing was tested"

	toggle_answer "$TMP/toggle" disable
	cpu_off=$(cpu_total "$TMP/toggle-off")
	status_check "$TMP/toggle-off" off disabled
	off_state=$state
	off_counted=$(status_field "$TMP/toggle-off" accelerated)
	[ "$off_counted" = 0 ] || why "disabled: bmchwaccel status counts ${off_counted:-no number of} accelerated connections"
	# What iperf3 carried in the window, in full packets of one direction; the
	# CPU also sees the acknowledgements of the other.
	carried=
	[ -z "$mbps_off" ] || carried=$((mbps_off * 1000000 / 8 / TOGGLE_MSS * WINDOW))
	if ! [ "$cpu_off" -ge "$MAX_CPU_PKTS" ] 2>/dev/null; then
		why "disabled: ${cpu_off:-no counter of} rx packets reached the CPU in $WINDOW s: the hardware still forwards the traffic, or the TCP sessions stopped"
	elif [ -z "$carried" ]; then
		why "disabled: no iperf3 interval in the window, so the packets on the CPU cannot be compared with what iperf3 carried"
	elif [ "$cpu_off" -lt $((carried * TOGGLE_CPU_SHARE / 100)) ]; then
		why "disabled: $cpu_off rx packets reached the CPU, but iperf3 carried $mbps_off Mbps, at least $carried packets: the hardware still forwards part of the traffic"
	fi
	if [ -n "$to_off" ]; then
		idle=$(iperf_idle "$TMP/iperf-$item.json" "$from_off" "$to_off")
		[ "$idle" -le $TOGGLE_IDLE_MAX ] ||
			why "disabled: iperf3 stood still in $idle of the $WINDOW s: the sessions do not go on through the CPU as they should"
	fi

	cpu_again=; counted=; state=; limit_again=; dropped=
	logged_off=$(value "$TMP/toggle" logged_off); logged_on=$(value "$TMP/toggle" logged_on)
	if [ -z "$logged_on" ]; then
		why "the board script did not get to its end (the SSH session broke); hardware acceleration is enabled again when this script ends"
	else
		toggle_answer "$TMP/toggle" enable
		cpu_again=$(cpu_total "$TMP/toggle-again")
		status_check "$TMP/toggle-again" on "enabled again"
		counted=$(status_field "$TMP/toggle-again" accelerated)
		[ "$state" != on ] || [ "$counted" -gt 0 ] 2>/dev/null ||
			why "enabled again: bmchwaccel status counts ${counted:-no} accelerated connections"
		[ "$cpu_again" -lt "$MAX_CPU_PKTS" ] 2>/dev/null ||
			why "enabled again: ${cpu_again:-no counter of} rx packets reached the CPU, need fewer than $MAX_CPU_PKTS"
		# From the start of the window to the end of the run: as long as a
		# traffic item measures.
		[ -z "$from_again" ] || mbps_again=$(iperf_span_mbps "$TMP/iperf-$item.json" "$from_again")
		[ "$mbps_again" -ge "$MIN_MBPS" ] 2>/dev/null ||
			why "enabled again: ${mbps_again:-no} Mbps from second ${from_again:-?} of iperf3 to its end, below $MIN_MBPS Mbps: the TCP sessions did not last or were not accelerated again"
		if [ -n "$from_again" ]; then
			idle=$(iperf_idle "$TMP/iperf-$item.json" "$from_again")
			[ "$idle" -le $TOGGLE_IDLE_MAX ] ||
				why "enabled again: iperf3 stood still in $idle of the seconds from second $from_again to its end"
		fi
		limit_again=$(value "$TMP/toggle-again" cpu_limit)
		# The other streams fill the link when one has stopped.
		stalled=$(iperf_stalled "$TMP/iperf-$item.json" $TOGGLE_TAIL)
		[ "${stalled:-0}" -eq 0 ] ||
			why "enabled again: $stalled of the iperf3 streams carried nothing in the last $TOGGLE_TAIL s: its TCP session did not last"
		[ "$logged_off" = 1 ] && [ "$logged_on" = 1 ] ||
			why "syslog has ${logged_off:-0} bmcHwAccel line(s) for off and $logged_on for on, need 1 and 1"
	fi

	dropped_on=$(value "$TMP/toggle-on" cpu_dropped); dropped_again=$(value "$TMP/toggle-again" cpu_dropped)
	[ -z "$dropped_on" ] || [ -z "$dropped_again" ] || dropped=$((dropped_again - dropped_on))
	probe=$(iperf_mbps "$TMP/iperf-$item-probe.json")
	probe_err=$(iperf_error "$TMP/iperf-$item-probe.json")
	probe_text="a new connection at second $probe_at: ${probe:-no result}${probe:+ Mbps}${probe_err:+ ($probe_err)}"
	pings=$(ping_seconds "$TMP/ping-toggle" "$run")
	case "$pings" in
	*!*) ;;
	*) pings="$pings (no answer at all: PC2 does not answer ping; Windows does not unless its firewall allows ICMPv4 echo)" ;;
	esac
	failed=$reasons
	report "$item" "rx packets on the CPU in $WINDOW s, and iperf3 meanwhile: ${cpu_on:-?} on (${mbps_on:-?} Mbps), ${cpu_off:-?} disabled (${mbps_off:-?} Mbps), ${cpu_again:-?} enabled again; disabled: bmchwaccel status: ${off_state:-no answer}, ${off_counted:-?} accelerated, $(value "$TMP/toggle-off" pinned) conntrack entries still pinned; enabled again: bmchwaccel status: ${state:-no answer}, ${counted:-?} accelerated, ${mbps_again:-?} Mbps to the end of the run; limit on traffic through the CPU: ${limit_again:-?} packets/s again, ${dropped:-?} dropped by it since the first window; $probe_text; iperf3 over both switches: ${mbps:-?} Mbps$(iperf_detail "$TMP/iperf-$item.json"); syslog: ${logged_off:-?} line off, ${logged_on:-?} line on"
	# Where the run slowed down or stood still: the windows are between "|".
	echo "               | Mbps each second (| on | disabled | enabled again |): $(iperf_timeline "$TMP/iperf-$item.json" "$from_on" "$to_on" "$from_off" "$to_off" "$from_again" "$to_again")"
	echo "               | ping each second (! answered, . lost): $pings"
	echo "               | new connection, Mbps each second: $(TIMELINE_BARS=0 iperf_timeline "$TMP/iperf-$item-probe.json")"
	if [ -n "$failed" ]; then
		echo "               | second by second (s of iperf3, its Mbps, ping, packets per port):"
		toggle_trace "$TMP/toggle" "$(TIMELINE_BARS=0 iperf_timeline "$TMP/iperf-$item.json")" "$pings" | sed 's/^/               |   /'
		for w in on off; do
			echo "               | counters that changed in the window $w:"
			toggle_counters "$TMP/toggle" $w | paste -d ';' - - - - | sed -e 's/;/; /g' -e 's/^/               |   /'
		done
	fi
	[ -z "$failed" ] || board "ITEM=$item
SERVER='$server'
$(diag_script)" 2>&1 | sed 's/^/               | /'
}

# Put FIRMWARE on the board and ask the test mode of sysupgrade about it; the
# answer is in $TMP/upcheck and the exit status of sysupgrade in upgrade_rc.
# Fails with the reasons set when the image is not a sysupgrade image or did
# not arrive whole.
upload_and_test() { # item
	image_dir=; image_kernel=; image_root=; image_root_size=0; image_kernel_size=0; image_id=
	if [ -z "$FIRMWARE" ] || [ ! -f "$FIRMWARE" ]; then
		why "no sysupgrade image: ${FIRMWARE:-set FIRMWARE}"
		return 1
	fi
	image_dir=$(tar -tf "$FIRMWARE" 2>/dev/null | grep -m 1 '^sysupgrade-.*/$')
	if [ -n "$image_dir" ]; then
		image_kernel=$(tar -xOf "$FIRMWARE" "${image_dir}kernel" 2>/dev/null | sha256)
		image_root=$(tar -xOf "$FIRMWARE" "${image_dir}root" 2>/dev/null | sha256)
		image_root_size=$(($(tar -xOf "$FIRMWARE" "${image_dir}root" 2>/dev/null | wc -c)))
		image_kernel_size=$(($(tar -xOf "$FIRMWARE" "${image_dir}kernel" 2>/dev/null | wc -c)))
	fi
	if [ "$image_root_size" -eq 0 ] || [ "$image_kernel_size" -eq 0 ]; then
		why "$FIRMWARE is not a sysupgrade image with a kernel and a root filesystem"
		return 1
	fi
	# The same image always leaves the same mark.
	image_id=$(echo "$image_root" | cut -c 1-12)

	# The temporary layout of earlier items is not in what sysupgrade keeps.
	board "$(unnet_script)"
	net_temporary=0
	net_key=
	board "$(upload_script)" < "$FIRMWARE"
	upgrade "$1" check > "$TMP/upcheck"
	if [ "$(value "$TMP/upcheck" image_kernel)" != "$image_kernel" ] ||
		[ "$(value "$TMP/upcheck" image_root)" != "$image_root" ]; then
		why "the image did not arrive whole on the board ($UPGRADE_FILE)"
		return 1
	fi
	upgrade_rc=$(sed -n 's/^@rc //p' "$TMP/upcheck")
}

item_sysupgrade() {
	upload_and_test sysupgrade || { report sysupgrade "not installed"; return; }
	before="$(value "$TMP/upcheck" release), kernel $(value "$TMP/upcheck" kernel)"
	if [ "$upgrade_rc" != 0 ]; then
		why "sysupgrade -T does not accept the image; a card written before the image version became 3.0 has to be written again"
		report sysupgrade "$before; not installed"
		upgrade_said "$TMP/upcheck" | sed 's/^/               | /'
		return
	fi
	# Not a failure, but then the update is not one to another firmware.
	same_build=
	[ "$(value "$TMP/upcheck" card_root)" != "$image_root" ] ||
		[ "$(value "$TMP/upcheck" card_kernel)" != "$image_kernel" ] ||
		same_build="; the image is the build that was already on the card"

	upgrade sysupgrade start > "$TMP/upstart"
	boot_before=$(value "$TMP/upcheck" boot_id)
	waited=0
	back=0
	while [ $waited -lt "$UPGRADE_WAIT" ]; do
		sleep $UPGRADE_POLL
		waited=$((waited + UPGRADE_POLL))
		upgrade sysupgrade poll > "$TMP/uppoll" 2>/dev/null || continue
		boot_now=$(value "$TMP/uppoll" boot_id)
		[ -n "$boot_now" ] && [ "$boot_now" != "$boot_before" ] || continue
		[ "$(value "$TMP/uppoll" init)" = complete ] || continue
		back=1
		break
	done
	if [ $back -eq 0 ]; then
		why "the board did not come back from a new boot within $UPGRADE_WAIT s"
		report sysupgrade "$before; installing started"
		sed -n '/^@log$/,$p' "$TMP/uppoll" 2>/dev/null | sed -e 1d -e 's/^/               | /'
		return
	fi

	upgrade sysupgrade verify > "$TMP/upverify"
	[ "$(value "$TMP/upverify" kept)" = "$image_id" ] ||
		why "the configuration was not kept: the option set before the upgrade is gone"
	[ "$(value "$TMP/upverify" config)" = "$(value "$TMP/upcheck" config)" ] ||
		why "the network or firewall configuration is not what it was before the upgrade"
	[ "$(value "$TMP/upverify" overlay)" = new ] ||
		why "a file outside the configuration is still there: the root filesystem was not written anew"
	[ "$(value "$TMP/upverify" card_root)" = "$image_root" ] ||
		why "the root filesystem on the card is not the one of the image"
	[ "$(value "$TMP/upverify" card_kernel)" = "$image_kernel" ] ||
		why "the kernel on the card is not the one of the image"
	# The same build has the same kernel; the time stamp tells a file that
	# was written from one that was left alone.
	kernel_time=$(value "$TMP/upverify" kernel_time)
	[ -n "$kernel_time" ] && [ "$kernel_time" != "$(value "$TMP/upcheck" kernel_time)" ] ||
		why "the kernel file on the card was not written: its time stamp is the one from before the upgrade"
	after="$(value "$TMP/upverify" release), kernel $(value "$TMP/upverify" kernel)"
	if [ -z "$reasons" ]; then
		report sysupgrade "$before -> $after, back after $waited s; configuration kept; the card has the kernel and root filesystem of ${FIRMWARE##*/}$same_build"
	else
		report sysupgrade "$before -> $after, back after $waited s"
	fi
}

# A board on the 24.10 firmware has an FMan microcode and a U-Boot environment
# that sysupgrade would leave as they are.
item_sysupgrade_old() {
	upload_and_test sysupgrade-old || { report sysupgrade-old "not tested"; return; }
	compat=$(value "$TMP/upcheck" compat)
	running="$(value "$TMP/upcheck" release), kernel $(value "$TMP/upcheck" kernel), image version ${compat:-not set}"
	upgrade_said "$TMP/upcheck" > "$TMP/upsaid"
	if [ "${compat%%.*}" -ge 3 ] 2>/dev/null; then
		why "the board has image version $compat, that of the new base; this item is for a board on the 24.10 firmware"
	elif [ "$upgrade_rc" = 0 ]; then
		why "sysupgrade -T accepted the image"
	else
		grep -q 'incompatible for sysupgrade based on the image version' "$TMP/upsaid" ||
			why "refused, but not because of the image version"
		grep -q 'Write the whole SD card' "$TMP/upsaid" ||
			why "the message does not say to write the SD card"
	fi
	if [ -z "$reasons" ]; then
		report sysupgrade-old "$running; sysupgrade -T refuses ${FIRMWARE##*/} and says to write the SD card"
	else
		report sysupgrade-old "$running"
	fi
	sed 's/^/               | /' "$TMP/upsaid"
}

# ---- main

# ---- the web UI and the features carried over from the 24.10 firmware

json_string() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# One request to the web UI from PC1, in the session of the item: the HTTP
# status in web_code (000 without an answer), the body in $TMP/web-body, the
# headers in $TMP/web-head. The session cookie is sent as the login gave it,
# not from a cookie file: a board without the time of day (no NTP server in
# reach) gives it an expiry date in the past of PC1, and curl would drop it.
web_cookie=
web() { # method, path, what to accept [, JSON body]
	web_method=$1; web_path=$2; web_accept=$3; web_data=${4:-}
	set -- -k -s -m 20 -o "$TMP/web-body" -D "$TMP/web-head" -w '%{http_code}' -X "$web_method" -H "Accept: $web_accept"
	[ -z "$web_cookie" ] || set -- "$@" -b "$web_cookie"
	[ -z "$web_data" ] || set -- "$@" -H 'Content-Type: application/json' --data "$web_data"
	web_code=$(curl "$@" "https://$BOARD:$WEBUI_PORT$web_path" 2>/dev/null)
	web_code=${web_code:-000}
}
# The body of the last answer on one line, cut short.
web_said() { tr -d '\n' < "$TMP/web-body" 2>/dev/null | tr -s ' ' | cut -c1-120; }

item_webui() {
	command -v curl >/dev/null 2>&1 || { why "curl not found on PC1"; report webui "not tested"; return; }
	board "$(webui_script)" > "$TMP/webui"
	[ "$(value "$TMP/webui" server)" -ge 1 ] 2>/dev/null || why "the web UI server is not running on the board"
	[ "$(value "$TMP/webui" listen)" -ge 1 ] 2>/dev/null || why "nothing listens on port $WEBUI_PORT of the board"
	[ "$(value "$TMP/webui" dnsfilter)" -ge 1 ] 2>/dev/null || why "the DNS filter (bmcfirewall) is not running on the board"
	runs="FIDO server $(value "$TMP/webui" fido) process(es)"

	web_cookie=
	web GET /login text/html
	case "$web_code" in
	200) ;;
	000) why "PC1 gets no answer from https://$BOARD:$WEBUI_PORT/login" ;;
	*) why "the login page answered HTTP $web_code, need 200" ;;
	esac
	web POST /login application/json '{"username":"hwaccel-nobody","password":"wrong"}'
	# No answer at all has its reason above.
	[ "$web_code" = 401 ] || [ -n "$reasons" ] || why "a wrong password was answered with HTTP $web_code, need 401"
	if [ -n "$reasons" ]; then
		report webui "the web UI is not up; $runs"
		return
	fi
	if [ -z "$WEBUI_PASS" ]; then
		why "WEBUI_PASS is not set: the login and the pages were not tried"
		report webui "login page and refusal of a wrong password only; $runs"
		return
	fi
	web POST /login application/json \
		"{\"username\":\"$(json_string "$WEBUI_USER")\",\"password\":\"$(json_string "$WEBUI_PASS")\"}"
	if [ "$web_code" != 200 ]; then
		why "the login of $WEBUI_USER answered HTTP $web_code: $(web_said)"
		report webui "no login; $runs"
		return
	fi
	web_cookie=$(sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\).*/\1/p' "$TMP/web-head" 2>/dev/null | head -1 | tr -d '\r')
	if [ -z "$web_cookie" ]; then
		why "the login of $WEBUI_USER was accepted but set no session cookie"
		report webui "no session; $runs"
		return
	fi
	if grep -q '"mustChangePassword": *true' "$TMP/web-body"; then
		why "$WEBUI_USER has to change its password first; the pages stay closed until then"
		report webui "logged in as $WEBUI_USER, pages not tried; $runs"
		return
	fi
	pages=0
	for path in $WEBUI_PAGES; do
		web GET "$path" text/html
		if [ "$web_code" = 200 ] && grep -q -i '<html' "$TMP/web-body"; then
			pages=$((pages + 1))
		elif [ "$web_code" = 000 ]; then
			why "page $path was not answered"
		else
			why "page $path answered HTTP $web_code"
		fi
	done
	apis=0
	for api in $WEBUI_APIS; do
		case "$api" in
		*=*) web POST "${api%%=*}" application/json "${api#*=}" ;;
		*)   web GET "$api" application/json ;;
		esac
		if [ "$web_code" = 000 ]; then
			why "${api%%=*} was not answered"
		elif [ "$web_code" != 200 ]; then
			why "${api%%=*} answered HTTP $web_code: $(web_said)"
		elif grep -q -E '"error"|"status": *"?-?[1-9]' "$TMP/web-body"; then
			why "${api%%=*} answered with an error: $(web_said)"
		else
			apis=$((apis + 1))
		fi
	done
	report webui "logged in as $WEBUI_USER; $pages page(s) opened, $apis request(s) of those pages answered without an error; $runs"
}

feature() { # action [PORT] -> answer of the board
	board "ACTION=$1
PC1='$PC1'
MAC='${pc1_mac:-}'
WAN_DEV='$wan_dev'
RULE='$FEATURE_RULE'
IN_RULE='$IN_RULE'
IN_PORT='$IN_PORT'
FWD_PORT='$FWD_PORT'
PORT='${2:-}'
$(features_script)" 2>&1
}

# Hardware acceleration out of the way and PC1 known, for both features
# items. Fails with the reasons set.
features_start() {
	net_ready plain "" || return 1
	# Set before the board is touched, for cleanup: ending only undoes what
	# the board has a mark for.
	featuring=1
	feature start > "$TMP/features"
	PC1=$(value "$TMP/features" pc1)
	pc1_mac=$(value "$TMP/features" mac)
	[ -n "$PC1" ] || { why "the board does not know where the ssh session comes from; set PC1"; return 1; }
	[ -n "$pc1_mac" ] || { why "the board has no MAC address for PC1 ($PC1)"; return 1; }
	case "$(value "$TMP/features" status)" in
	none) accel="no bmchwaccel on this board" ;;
	*)
		status_check "$TMP/features" off "hardware acceleration must be disabled for the item"
		accel="hardware acceleration disabled"
		;;
	esac
	[ -z "$reasons" ]
}

features_end() {
	feature end >/dev/null
	featuring=0
}

# The gateway PC1 sends to an address through (macOS, then Linux).
pc1_gateway() {
	gw=$(route -n get "$1" 2>/dev/null | sed -n 's/^ *gateway: *//p')
	[ -n "$gw" ] || gw=$(ip route get "$1" 2>/dev/null | sed -n 's/.* via \([^ ]*\).*/\1/p')
	echo "${gw:-no gateway that could be read}"
}

# Replies to 3 pings from PC1.
reached() { ping -c 3 "$1" 2>/dev/null | grep -c 'bytes from'; }

# The feature of $1 is in place for PC1 after "<feature>-on": it must have
# told so, have its rule, and stop PC1; after "<feature>-off" PC1 is through
# again.
blocks_pc1() { # feature, name of its rule
	feature "$1-on" > "$TMP/feature"
	[ "$(value "$TMP/feature" rules)" -ge 1 ] 2>/dev/null ||
		why "$1: no rule for $pc1_mac after it was set ($(value "$TMP/feature" said))"
	[ "$(reached "$SERVER")" = 0 ] || why "$1: PC1 still reaches $SERVER with $2 in place"
	feature "$1-off" > "$TMP/feature"
	[ "$(reached "$SERVER")" -ge 1 ] || why "$1: PC1 does not reach $SERVER after $2 was taken away"
}

# Replies to FLOOD_PINGS pings sent to $1 at 3 a second.
flood() {
	flood_pids=
	rm -f "$TMP"/flood-*
	for n in 1 2 3; do
		ping -c $((FLOOD_PINGS / 3)) "$1" > "$TMP/flood-$n" 2>&1 &
		flood_pids="$flood_pids $!"
	done
	# shellcheck disable=SC2086
	wait $flood_pids
	cat "$TMP"/flood-* | grep -c 'bytes from'
}

item_features() {
	features_start || { features_end; report features "not tested"; return; }
	for f in macfilter ddos; do
		[ "$(value "$TMP/features" $f)" != enable ] || why "$f is enabled on the board; the item needs it disabled"
	done
	[ "$(reached "$SERVER")" -ge 1 ] ||
		why "PC1 does not reach $SERVER (ping) before anything is set; PC1 sends to it through $(pc1_gateway "$SERVER"), which has to be the board ($BOARD)"
	if [ -n "$reasons" ]; then
		features_end
		report features "not tested; $accel"
		return
	fi
	blocks_pc1 macfilter "the blacklist entry"
	blocks_pc1 client "the rule for the whole week"

	blocked_reasons=$reasons
	feature ddos-on > "$TMP/feature"
	[ "$(value "$TMP/feature" rules)" -ge 1 ] 2>/dev/null ||
		why "ddos_protect: no rule after it was enabled ($(value "$TMP/feature" said))"
	limited=$(flood "$BOARD")
	[ "$limited" -le $FLOOD_MAX ] || why "ddos_protect: the board answered $limited of $FLOOD_PINGS pings while enabled, need at most $FLOOD_MAX"
	limited_fwd=$(flood "$SERVER")
	[ "$limited_fwd" -le $FLOOD_MAX ] || why "ddos_protect: $SERVER answered $limited_fwd of $FLOOD_PINGS pings through the board while enabled, need at most $FLOOD_MAX"
	feature ddos-off > "$TMP/feature"
	free=$(flood "$BOARD")
	[ "$free" -ge $FLOOD_MIN ] || why "ddos_protect: the board answered $free of $FLOOD_PINGS pings once disabled, need at least $FLOOD_MIN"
	free_fwd=$(flood "$SERVER")
	[ "$free_fwd" -ge $FLOOD_MIN ] || why "ddos_protect: $SERVER answered $free_fwd of $FLOOD_PINGS pings through the board once disabled, need at least $FLOOD_MIN"

	features_end
	blocked="macfilter and client_control each stopped it and let it through again"
	[ -z "$blocked_reasons" ] || blocked="macfilter and client_control: see below"
	report features "PC1 $PC1 ($pc1_mac); $blocked; ddos_protect: $limited of $FLOOD_PINGS pings to the board and $limited_fwd through it answered while enabled, $free and $free_fwd once disabled; $accel"
}

# Wait for a connection from the wan side to a port of the board that the
# board translated to PC1. Fails with a reason when none came.
inbound() { # feature, wan port
	"$IPERF3" -s -1 -p "$IN_PORT" > /dev/null 2>&1 &
	listen_pid=$!
	printf '%-14s %s: on PC2 run now:  iperf3 -c %s -p %s -t 2\n' features-in "$1" "${wan_addr%/*}" "$2"
	waited=0
	seen=0
	while [ $waited -lt "$IN_WAIT" ]; do
		sleep $IN_POLL
		waited=$((waited + IN_POLL))
		feature seen "$2" > "$TMP/seen"
		seen=$(value "$TMP/seen" seen)
		[ "${seen:-0}" -ge 1 ] 2>/dev/null && break
	done
	# The first packet of a connection is counted before PC1 has answered
	# it: look once more before judging whether PC1 took it.
	if [ "${seen:-0}" -ge 1 ] 2>/dev/null && [ "$(value "$TMP/seen" answered)" = 0 ]; then
		sleep $IN_POLL
		feature seen "$2" > "$TMP/seen"
	fi
	kill "$listen_pid" 2>/dev/null
	listen_pid=
	if [ "${seen:-0}" -ge 1 ] 2>/dev/null; then
		if [ "$(value "$TMP/seen" answered)" -ge 1 ] 2>/dev/null; then
			in_text="answered by PC1"
		elif [ "$(value "$TMP/seen" forwarded)" -ge 1 ] 2>/dev/null; then
			in_text="sent on to PC1, which did not take it (a firewall on PC1?)"
			gw=$(pc1_gateway "$SERVER")
			[ "$gw" = "$BOARD" ] || in_text="sent on to PC1, which did not take it (PC1 answers $SERVER through $gw, not through the board $BOARD)"
		else
			why "$1: a connection to port $2 of wan was translated to $PC1:$IN_PORT, but the board did not let it through"
			in_text="translated, not let through"
		fi
	else
		why "$1: no connection to port $2 of wan was translated to $PC1:$IN_PORT within $IN_WAIT s"
		in_text="not seen"
	fi
}

item_features_in() {
	features_start || { features_end; report features-in "not tested"; return; }

	feature nat11-on > "$TMP/feature"
	if [ "$(value "$TMP/feature" rules)" -ge 1 ] 2>/dev/null; then
		inbound "NAT 1:1" "$IN_PORT"
		nat11_text=$in_text
		feature nat11-off > "$TMP/feature"
	else
		why "NAT 1:1: no rule towards $PC1 after it was set ($(value "$TMP/feature" said))"
		nat11_text="not set"
	fi

	feature forward-on > "$TMP/feature"
	if [ "$(value "$TMP/feature" rules)" -ge 1 ] 2>/dev/null; then
		inbound "port forward" "$FWD_PORT"
		forward_text=$in_text
		feature forward-off > "$TMP/feature"
	else
		why "port forward: no rule towards $PC1:$IN_PORT after it was added ($(value "$TMP/feature" said))"
		forward_text="not set"
	fi

	features_end
	report features-in "PC1 $PC1; NAT 1:1 on wan: $nat11_text; port forward wan:$FWD_PORT to $PC1:$IN_PORT: $forward_text; $accel"
}

# ---- the captive portal and the proxy

portal() { # action -> answer of the board
	board "ACTION=$1
CLIENT='$PORTAL_CLIENT'
SERVER='$SERVER'
USER='$PORTAL_USER'
PASS='$PORTAL_PASS'
$(portal_script)" 2>&1
}

# The addresses of PC1 (Linux, then macOS).
pc1_addresses() {
	{ ip -4 -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'
	  ifconfig 2>/dev/null | awk '$1 == "inet" { sub(/^addr:/, "", $2); print $2 }'; } | sort -u
}

# Replies to 3 pings PC1 sends from one of its addresses.
reached_from() { # source address, host
	case "$(uname)" in
	Darwin) ping -c 3 -S "$1" "$2" 2>/dev/null | grep -c 'bytes from' ;;
	*) ping -c 3 -I "$1" "$2" 2>/dev/null | grep -c 'bytes from' ;;
	esac
}

# What an HTTP request of PC1 from PORTAL_CLIENT to PC2 gets: the status and
# where a redirect points.
portal_http() {
	curl -s -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' --interface "$PORTAL_CLIENT" "http://$SERVER/" 2>/dev/null
}

item_portal() {
	command -v curl >/dev/null 2>&1 || { why "curl not found on PC1"; report portal "not tested"; return; }
	net_ready plain "" nac || { report portal "not tested"; return; }
	# Set before the board is touched, for cleanup.
	at_portal=1
	portal start > "$TMP/portal"
	[ -n "$(value "$TMP/portal" chilli)" ] || why "CoovaChilli is not running in security mode nac"
	[ -n "$(value "$TMP/portal" radiusd)" ] || why "FreeRADIUS is not running in security mode nac"
	gateway=$(value "$TMP/portal" gateway)
	[ -n "$gateway" ] || why "the portal has no address (no tunnel device of CoovaChilli)"
	[ "$(value "$TMP/portal" lan_dhcp)" = 1 ] || why "the DHCP server of br-lan is not turned off; the portal gives the addresses"
	[ -z "$(value "$TMP/portal" user)" ] || why "the login could not be added to the user database: $(value "$TMP/portal" user)"
	status_check "$TMP/portal" on
	if [ -n "$gateway" ] && [ -z "$PORTAL_CLIENT" ]; then
		# The portal hands out a /24 (192.168.182.0/24 unless the board was
		# given another network of that size).
		net3=$(echo "$gateway" | cut -d. -f1-3)
		PORTAL_CLIENT=$(pc1_addresses | grep "^$net3\\." | head -1)
		[ -n "$PORTAL_CLIENT" ] ||
			why "PC1 has no address in the network of the portal ($gateway): its port must take an address by DHCP (bench.md), or name it with PORTAL_CLIENT"
	fi
	if [ -z "$gateway" ] || [ -z "$PORTAL_CLIENT" ]; then
		portal end > /dev/null; at_portal=0
		report portal "not tested"
		return
	fi
	gateway=${gateway%/*}

	# A client that is new on the LAN.
	portal fresh > /dev/null
	out=$(reached_from "$PORTAL_CLIENT" "$SERVER")
	[ "$out" = 0 ] || why "before the login, $SERVER answered $out of 3 pings of PC1"
	before=$(portal_http)
	case "$before" in
	30[0-9]\ *portal.html*) http_text="HTTP sent to the portal page" ;;
	*)
		why "before the login, HTTP to $SERVER is not sent to the portal page (answer: ${before:-none})"
		http_text="HTTP not sent to the portal page"
		;;
	esac
	portal before > "$TMP/session"
	[ -n "$(value "$TMP/session" mac)" ] || why "the portal does not list $PORTAL_CLIENT; did the portal give PC1 this address?"
	[ "$(value "$TMP/session" authorized)" != 1 ] || why "the portal lists $PORTAL_CLIENT as authorized before the login"
	[ "$(value "$TMP/session" forwarded)" = 0 ] ||
		why "before the login, the board forwarded $(value "$TMP/session" forwarded) connection(s) of PC1 to $SERVER"

	curl -s -m 30 -o "$TMP/login" --interface "$PORTAL_CLIENT" -X POST -H 'Content-Type: application/json' \
		--data "{\"username\":\"$(json_string "$PORTAL_USER")\",\"password\":\"$(json_string "$PORTAL_PASS")\"}" \
		"http://$gateway/cgi-bin/portal_login.sh" >/dev/null 2>&1
	login=$(tr -d '\n' < "$TMP/login" 2>/dev/null | tr -s ' ' | cut -c1-120)
	case "$login" in
	*'"success": true'*|*'"success":true'*) ;;
	*) why "the login script of the portal refused the login (answer: ${login:-none})" ;;
	esac
	portal after > "$TMP/session"
	[ "$(value "$TMP/session" authorized)" = 1 ] ||
		why "after the login, the portal does not list $PORTAL_CLIENT as authorized (it says: $(value "$TMP/session" state))"
	in=$(reached_from "$PORTAL_CLIENT" "$SERVER")
	[ "$in" -ge 1 ] || why "after the login, $SERVER answers no ping of PC1"

	portal logout > /dev/null
	after=$(reached_from "$PORTAL_CLIENT" "$SERVER")
	[ "$after" = 0 ] || why "after the logout, $SERVER answered $after of 3 pings of PC1"

	portal end > /dev/null
	at_portal=0
	report portal "PC1 $PORTAL_CLIENT at the portal $gateway; before the login: $http_text, $out of 3 pings answered; logged in as $PORTAL_USER: $in of 3 pings answered; after the logout: $after of 3; bmchwaccel status: $(status_field "$TMP/portal" state)"
}

proxy() { # action [, tracker lines so far] -> answer of the board
	board "ACTION=$1
LOGGED=${2:-0}
TRACK_WAIT=$TRACK_WAIT
PC1='$PC1'
SERVER='$SERVER'
HTTP_PORT='$HTTP_PORT'
HTTP_FILE='$HTTP_FILE'
$(proxy_script)" 2>&1
}

# PC1 downloads the file from PC2: the HTTP status and the bytes it got.
download() {
	curl -s -m 120 -o /dev/null -w '%{http_code} %{size_download}' "http://$SERVER:$HTTP_PORT/$HTTP_FILE" 2>/dev/null
}

item_proxy() {
	command -v curl >/dev/null 2>&1 || { why "curl not found on PC1"; report proxy "not tested"; return; }
	net_ready plain "" || { report proxy "not tested"; return; }
	proxying=1
	proxy start > "$TMP/proxy"
	PC1=$(value "$TMP/proxy" pc1)
	[ "$(value "$TMP/proxy" squid)" -ge 1 ] 2>/dev/null || why "squid is not running"
	[ "$(value "$TMP/proxy" intercept)" -ge 1 ] 2>/dev/null || why "squid does not listen on its intercept port 3128"
	[ "$(value "$TMP/proxy" bump)" -ge 1 ] 2>/dev/null || why "squid does not listen on its HTTPS intercept port 3129"
	[ "$(value "$TMP/proxy" icap)" -ge 1 ] 2>/dev/null || why "the ICAP server (c-icap) is not running"
	[ "$(value "$TMP/proxy" icap_port)" -ge 1 ] 2>/dev/null || why "the ICAP server does not listen on port 1344"
	[ "$(value "$TMP/proxy" tracker)" -ge 1 ] 2>/dev/null || why "the HTTP file tracker did not start reading br-lan once enabled for $PC1"
	[ -n "$PC1" ] || why "the board does not know where the ssh session comes from; set PC1"
	if [ -n "$reasons" ]; then
		proxy end > /dev/null; proxying=0
		report proxy "not tested"
		return
	fi
	status_check "$TMP/proxy" on

	proxy before > "$TMP/seen"
	logged0=$(value "$TMP/seen" logged)
	icap0=$(value "$TMP/seen" icap_requests)
	proxy redirect-on > "$TMP/redirect"
	[ "$(value "$TMP/redirect" rules)" -ge 1 ] 2>/dev/null || why "the REDIRECT rule to squid is not in the nat table"
	set -- $(download)
	via_code=${1:-000}; via_bytes=${2:-0}
	proxy proxied "$logged0" > "$TMP/seen"
	logged1=$(value "$TMP/seen" logged)
	via_logged=$((logged1 - logged0))
	[ "$(value "$TMP/seen" redirected)" -ge 1 ] 2>/dev/null ||
		why "through squid: the board did not answer a connection of PC1 to $SERVER:$HTTP_PORT itself"
	[ "$(value "$TMP/seen" from_board)" -ge 1 ] 2>/dev/null ||
		why "through squid: the board has no connection of its own to $SERVER:$HTTP_PORT; is the web server of bench.md running on PC2?"
	[ "$(value "$TMP/seen" forwarded)" = 0 ] ||
		why "through squid: $(value "$TMP/seen" forwarded) connection(s) of PC1 to $SERVER:$HTTP_PORT were forwarded past squid"
	[ "$(value "$TMP/seen" icap_requests)" -gt "${icap0:-0}" ] 2>/dev/null ||
		why "through squid: the ICAP server was not asked about the download"
	counted=$(status_field "$TMP/seen" accelerated)
	[ "${counted:-0}" = 0 ] || why "through squid: bmchwaccel status counts $counted accelerated connection(s); traffic of the proxy ends on the board"
	if [ "$(value "$TMP/proxy" clamd)" -ge 1 ] 2>/dev/null; then
		[ "$via_code" = 200 ] || why "through squid: PC1 got HTTP $via_code for http://$SERVER:$HTTP_PORT/$HTTP_FILE"
		[ "$via_code" != 200 ] || [ "$via_bytes" -ge $((HTTP_MIN_KB * 1024)) ] ||
			why "through squid: PC1 got $via_bytes bytes, need a file of $HTTP_MIN_KB KiB or more"
		[ "$via_logged" -ge 1 ] || why "through squid: the HTTP file tracker logged no transfer of $HTTP_FILE"
		via_text="HTTP $via_code, $via_bytes bytes, logged by the tracker $via_logged time(s)"
	else
		# The antivirus service cannot scan without ClamAV, which neither
		# this image nor the one of the 24.10 firmware has, and squid is
		# told not to let through what was not scanned.
		[ "$via_code" = 500 ] ||
			why "through squid: PC1 got HTTP $via_code, need squid's own error page (500): ClamAV is not running and nothing may pass unscanned"
		via_text="HTTP $via_code from squid, as nothing can be scanned without ClamAV (not in the image)"
	fi
	# The last line of the tracker is one of this run only when it logged.
	tracker_line=
	[ "$via_logged" -lt 1 ] || tracker_line=$(value "$TMP/seen" line)
	proxy redirect-off > /dev/null

	# The same download, forwarded. Printed, not judged.
	set -- $(download)
	direct_code=${1:-000}; direct_bytes=${2:-0}
	proxy direct "$logged1" > "$TMP/seen"
	direct_logged=$(($(value "$TMP/seen" logged) - logged1))
	direct_state=$(status_field "$TMP/seen" state); direct_counted=$(status_field "$TMP/seen" accelerated)
	[ -n "$tracker_line" ] || [ "$direct_logged" -lt 1 ] || tracker_line=$(value "$TMP/seen" line)

	proxy end > /dev/null
	proxying=0
	report proxy "PC1 $PC1; through squid: $via_text; without squid (not judged): HTTP $direct_code, $direct_bytes bytes, logged by the tracker $direct_logged time(s), bmchwaccel status ${direct_state:-no answer}, ${direct_counted:-?} accelerated"
	[ -z "$tracker_line" ] || printf '%-14s the tracker: %s\n' proxy "$tracker_line"
}

# scripts/ls1088/acceptance.sh reads this script for its functions and items,
# and runs items of its own beside them.
[ -z "${ACCEPTANCE_LIB:-}" ] || return 0

ITEMS="boot boot-time firewall ports mac mac-temp off-boot soak reboots webui features features-in portal proxy brlan-wan brlan-wan-back toggle toggle-back vlan-wan vlan-wan-back pppoe pppoe-back pppoe-drop pppoe-redial vlan-vlan vlan-vlan-back ucode-public sysupgrade sysupgrade-old keep-mark qos qos-back qos-vlan-vlan mwan mwan-in ospf ospf-move stats stats-back bridge bridge-block bridge-neigh block brlan-wan-noab"
[ $# -gt 0 ] || set -- boot firewall ports mac brlan-wan brlan-wan-back toggle vlan-wan vlan-wan-back \
	pppoe pppoe-back pppoe-drop pppoe-redial
for item in "$@"; do
	case " $ITEMS " in
	*" $item "*) ;;
	*) echo "acceptance: unknown item '$item' ($(echo $ITEMS | sed 's/ /, /g'))" >&2; exit 2 ;;
	esac
	case "$item" in
	vlan-*|qos-vlan-vlan)
		clash=$(vlan_clash)
		[ -z "$clash" ] || {
			echo "acceptance: $clash; give the VLAN items other ids, for example VLAN_ID=30 (bench.md)" >&2
			exit 2
		}
		;;
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
	boot)           item_boot ;;
	firewall)       item_firewall ;;
	ports)          item_ports ;;
	mac|mac-temp)   item_mac "$item" ;;
	off-boot)       item_off_boot ;;
	soak)           item_soak ;;
	reboots)        item_reboots ;;
	boot-time)      item_boot_time ;;
	ucode-public)   item_ucode_public ;;
	toggle|toggle-back) item_toggle "$item" ;;
	sysupgrade)     item_sysupgrade ;;
	sysupgrade-old) item_sysupgrade_old ;;
	bridge)         item_bridge ;;
	bridge-block)   item_bridge_block ;;
	bridge-neigh)   item_bridge_neigh ;;
	block)          item_block ;;
	brlan-wan-noab) item_noab ;;
	pppoe-drop)     item_drop ;;
	webui)          item_webui ;;
	features)       item_features ;;
	features-in)    item_features_in ;;
	portal)         item_portal ;;
	proxy)          item_proxy ;;
	keep-mark)      item_keep_mark ;;
	qos|qos-back|qos-vlan-vlan) item_qos "$item" ;;
	stats|stats-back) item_stats "$item" ;;
	mwan)           item_mwan ;;
	mwan-in)        item_mwan_in ;;
	ospf)           item_ospf ;;
	ospf-move)      item_ospf_move ;;
	*-back)         measure "$item" -R ;;
	*)              measure "$item" ;;
	esac
done

if [ $rc -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit $rc
