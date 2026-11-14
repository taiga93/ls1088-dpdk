# Cụm ảo DynRouting

`scripts/dynrouting-cluster` runs the virtual acceptance topology of Định tuyến động (DynRouting phase 2:
OSPF, RIPv2, BGP): six QEMU guests of one `armsr/armv8` OpenWrt image built from this tree (musl,
`aarch64_generic` packages, fw3, FRR 10.4 and `bmcDynRouting` exactly as the LS1046 profile of this branch,
`config_LS1046ARDB`, ships them; nothing of hardware acceleration is in it). The
image also carries `mwan3` and `bmcMultiWAN` (off, as after a flash) for the
[Cụm ảo Multi-WAN](../multiwan-virtual/README.md), which runs on the same VMs.

```
             ISP-A (AS 64500)                        ISP-B (AS 64501)
             203.0.113.1  | wana                     198.51.100.1 | wanb
                   eth1   |                                 eth1  |
  LAN 192.168.1.0/24 +----------+ eth2 - 10.0.12.0/30 - eth2 +----------+ LAN 192.168.2.0/24
               eth0  |    R1    |            l12             |    R2    |  eth0
                     | 1.1.1.1  |                            | 2.2.2.2  |
                     +----------+                            +----------+
                     eth3 \ 10.0.13.0/30 (l13)     10.0.23.0/30 (l23) / eth3
                           \                                         /
                       eth1 +----------------------------------------+ eth2
                            |               R3 3.3.3.3               |  eth0  LAN 192.168.3.0/24
                            +----------------------------------------+
                                  eth3 | 192.168.50.0/24 (leg)
                                legacy router (ripd only), 192.168.50.254, LAN 192.168.60.1/24 (lan60)
```

- R1, R2, R3 are BMC routers (AS 65001): every port but the WAN starts in `br-lan`, as after a flash, and
  the harness configures them only through the `bmcdynrouting` CLI: `link add` for every Link định tuyến,
  `router-id set`, `ospf set`, `rip set` (R3), `bgp set` (R1, R2). Nothing is written with `vtysh`.
- ISP-A, ISP-B and the legacy router are plain FRR (`bgpd` / `ripd`) with a fixed configuration from the
  bootstrap package `bmc-dynrouting-virtual-bootstrap`; no firewall. Each ISP sends a default route and one
  prefix (100.64.1.0/24, 100.64.2.0/24). R1 takes everything from ISP-A (`receive=all`), R2 only the
  default from ISP-B (`receive=default`).
- The VM ports are named `eth0`–`eth3`, not the LS1046 names (`eth5`–`eth7`): the legacy router sits on
  R3's `eth3` (`link_eth3`), the role of `eth5` in the spec.
- R1 also has `eth4` on ISP-B's network `wanb`, left unconfigured and outside `br-lan`: a free port for
  Multi-WAN tests (`bmcmultiwan wan add --port eth4`). DynRouting never uses it.
- Each network is a software switch (`ha-virtual/ethernet_switch.py`, shared with the Cụm HA ảo). The
  link networks `l12`, `l13`, `l23`, `leg` start **unplugged** (NIC carrier down) and are plugged once both
  ends are Link định tuyến: while those ports are still in `br-lan` the three LANs would form a loop.

## Requirements

- Linux or macOS with `qemu-system-aarch64` and Python 3 (macOS: `brew install qemu python`). Verified
  on Linux only (arm64 docker container, QEMU 4.2); on macOS only `up` was exercised, with a stub QEMU. TCG is
  used, so no KVM, TAP interfaces or root are needed. About 2.5 GB of free RAM (R1–R3 512 MB each, the
  others 256 MB), 1.5 GB of disk in the state directory, and a free TCP port range (default 20000–20090).
- To build: an OpenWrt build environment for this tree (GNU make is `gmake` on macOS).

## Use

```sh
# In the ubuntu20 build container, in this tree, after scripts/hwaccel/build.sh has built the LS1046 image
# (its toolchain and aarch64_generic packages are reused; about 15 minutes and 6 GB the first time).
FORCE_UNSAFE_CONFIGURE=1 scripts/dynrouting-cluster build
scripts/dynrouting-cluster accept      # up, configure through the CLI, every check below
scripts/dynrouting-cluster down
```

`build` puts the virtual profile `config_DYNROUTING_VIRTUAL` in `.config`, builds, and puts the old `.config`
back; `scripts/hwaccel/build.sh` writes its own `.config` at every run, so the LS1046 image can be built
again right after. Do not run the two builds at the same time. `DYNR_BUILD_TREE=<tree>` builds in another
OpenWrt tree of this base instead, which gets this checkout's three packages. The image and kernel land in
`build/dynrouting-virtual` (`DYNR_VIRTUAL_OUTPUT`). The state directory (`DYNR_CLUSTER_STATE`, default
`$TMPDIR/bmc-dynrouting-cluster`) holds the disk copies, sockets and logs; `DYNR_CLUSTER_PORT_BASE` moves
the switch ports.

Other commands, for debugging a run (`accept` leaves the cluster up):

```sh
scripts/dynrouting-cluster up                  # boot only, link cables unplugged
scripts/dynrouting-cluster configure           # link add, router-id, OSPF/RIP/BGP through the CLI
scripts/dynrouting-cluster check               # the checks below, on the configured cluster
scripts/dynrouting-cluster exec r1 'bmcdynrouting status bgp peers'
scripts/dynrouting-cluster exec ispb "vtysh -c 'show bgp ipv4 unicast'"
scripts/dynrouting-cluster cable l12 unplug    # pull the R1-R2 cable (carrier down on both ends)
scripts/dynrouting-cluster set_link r3 leg down
scripts/dynrouting-cluster capture l13 /tmp/l13.pcap
scripts/dynrouting-cluster power r2 off          # `power r2 on` keeps unplugged cables unplugged
```

## What `accept` checks

1. OSPF Full on R1–R2, R1–R3, R2–R3 (`bmcdynrouting status ospf neighbors`).
2. RIP: the legacy router learns LAN R1, LAN R2 and a default route from R3 (redistribute OSPF, default
   originate); R3 learns 192.168.60.0/24 over RIP and R1/R2 over OSPF (R3 redistributes RIP); R1 pings
   192.168.60.1 from its LAN address.
3. BGP: R1–ISP-A and R2–ISP-B Established; ISP-A receives 192.168.1.0/24, ISP-B 192.168.2.0/24; R2
   (`receive=default`) holds only ISP-B's default route although ISP-B advertises 100.64.2.0/24 to it,
   while R1 (`receive=all`) holds 100.64.1.0/24.
4. No transit: with R1 redistributing BGP into OSPF and R2 redistributing OSPF into BGP, ISP-A's prefix
   reaches R2 and R1's LAN reaches ISP-B, but ISP-B never receives 100.64.1.0/24 or a default route.
5. Firewall: TCP 179 to R1 from 203.0.113.9 (not the Peer BGP) is refused by the `wan` zone; a RIP
   response sent by R1 to R3 over R1–R3 (not an Interface RIP) is rejected by the `dynrouting` zone
   (its REJECT counter moves), while RIP from the legacy router is accepted by the bmcDynRouting rule. The
   probe is unicast; ripd itself sends to 224.0.0.9.
6. Restart per daemon: an OSPF change on R1 restarts only `ospfd`; the R1–ISP-A session keeps its
   established time and `bgpd` its PID.
7. Pulling the R1–R2 cable: R1 reaches LAN R2 (and R2 LAN R1) through R3 (route, ping from the LAN
   address, traceroute); plugging it back restores the direct path.

## Limits

- Timing on TCG guests is not representative of LS1046 hardware: boot takes a minute or more, each serial
  command costs about a second, and the waits are generous (up to 3 minutes per step). A full `accept`
  took 5–6 minutes on a 10-core arm64 Linux container (the image build about 15 minutes in a tree that
  already had the toolchain). Do not read convergence times from it.
- The kernel is armsr's, not LS1046's: DPAA/port naming, hardware offload and TCP MD5 on the real board
  are not covered (MD5 peers are not exercised here).
- LAN traffic is generated from the routers' own LAN addresses (`ping -I`, `traceroute -s`); there are no
  LAN client VMs.
