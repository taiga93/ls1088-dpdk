# Cụm ảo Multi-WAN

`scripts/multiwan-cluster` runs the virtual acceptance topology of Multi-WAN (`bmcMultiWAN` with `mwan3`). It
uses the QEMU guests, switches and serial consoles of the [Cụm ảo DynRouting](../dynrouting-virtual/README.md)
and the same `armsr/armv8` image built from this tree (musl, fw3, FRR 10.4, `bmcDynRouting`, `mwan3` 2.12 and
`bmcMultiWAN` as the LS1046 profile ships them).

```
   "Internet" on ISP-A's loopback              "Internet" on ISP-B's loopback
   1.1.1.1  8.8.8.8  9.9.9.9 (check server)    1.1.1.1  8.8.8.8  9.9.9.9 (check server)
             ISP-A 203.0.113.1                        ISP-B 198.51.100.1
                  | wana                                    | wanb
         wan eth1 | 203.0.113.2          wan2 eth4 198.51.100.3
                  +---------------+  +----------------------+
                                  |  |
                               +--------+ eth3 = Link định tuyến 10.0.13.0/30 (OSPF) +--------+
     br-lan 192.168.1.1/24     |   R1   |--------------------------------------------|   R3   | branch LAN
     br-lan.10 192.168.10.1/24 +--------+                                  l13       +--------+ 10.20.0.0/16
                                  | eth2 (l12, part of br-lan)
                               +--------+
                               |   R2   |  LAN client 192.168.1.100 (default via 192.168.1.1)
                               +--------+  accounting VLAN 10 client 192.168.10.100 (default via 192.168.10.1)
```

- **R1** is the BMC router under test. Its Multi-WAN is configured only through `bmcmultiwan`:
  `wan add --name wan2 --port eth4 --proto static ...`, `wan set --down 2` on both WANs, `set --enabled 1`,
  `apply`, `policy set --name b_first --wan wan2 --wan wan` and `rule set --name acct --policy b_first
  --src-ip 192.168.10.0/24`. The rest is test-network setup with `uci`: ISP-A's gateway on the existing `wan`,
  the accounting VLAN `br-lan.10` in the `lan` zone, and a port forward `wan` TCP 8080 → 192.168.1.100:8000.
  OSPF towards the branch goes through `bmcdynrouting` (`link add eth3`, `ospf set`, with `lan` and `acct` as
  passive interfaces).
- **ISP-A / ISP-B** each carry the fake Internet on their loopback: the ping targets 1.1.1.1 and 8.8.8.8,
  which are also DNS servers, and the check server 9.9.9.9. The check server answers `<isp> <source address it
  sees>`, for example `ispb 198.51.100.3`. The DNS name `isp.bmc-test.net` resolves to 9.9.9.1 on ISP-A and
  to 9.9.9.2 on ISP-B. "Upstream cut" (`upstream ispa cut`) drops everything from R1 to those addresses on
  the ISP. The ISP's own address keeps answering, so the link stays up.
- **R2** plays both LAN clients: the plain client uses 192.168.1.100 on `br-lan`, bridged to R1's `br-lan`
  by cable `l12`, and the accounting client uses 192.168.10.100 on VLAN 10 with a source rule to its own
  gateway. R2 also runs the LAN server behind the port forward.
- **R3** is the branch router with LAN 10.20.0.0/16. It forms an OSPF adjacency with R1 over Link định tuyến.
- The `legacy` VM of the Cụm ảo DynRouting also boots, but nothing uses it.

## Requirements

Same as the Cụm ảo DynRouting: Linux or macOS with `qemu-system-aarch64` and Python 3, TCG (no KVM, TAP or
root), about 2.5 GB of free RAM and 1.5 GB of disk. The port range starts at `MWAN_CLUSTER_PORT_BASE`
(default 20200, so it does not clash with the DynRouting cluster's 20000). Only verified inside the `ubuntu20`
arm64 Linux container (QEMU 4.2).

## Use

```sh
FORCE_UNSAFE_CONFIGURE=1 scripts/multiwan-cluster build   # = scripts/dynrouting-cluster build, see its README
scripts/multiwan-cluster up        # one command: boot and configure the whole topology (~6 min)
scripts/multiwan-cluster check     # the checks below (~3 min)
scripts/multiwan-cluster down      # one command: stop and remove everything
scripts/multiwan-cluster accept    # up + check; leaves the cluster up
```

`MWAN_CLUSTER_STATE` (default `$TMPDIR/bmc-multiwan-cluster`) is the state directory. `DYNR_VIRTUAL_OUTPUT`
(default `build/dynrouting-virtual`) is where the image is. `MWAN_SWITCH_MAX_SECONDS` (default 25) is the
Chuyển WAN budget, and `MWAN_TRACK_DOWN` (default 2) is the value given to `bmcmultiwan wan set --down`.

For debugging:

```sh
scripts/multiwan-cluster exec r1 'bmcmultiwan status'
scripts/multiwan-cluster upstream ispa cut         # ... restore
scripts/multiwan-cluster exec r2 'wget -q -O - http://9.9.9.9/'
scripts/multiwan-cluster exec r2 'nslookup isp.bmc-test.net 8.8.8.8'
scripts/multiwan-cluster capture wanb /tmp/wanb.pcap
```

## What `check` checks

`check` first restores both upstreams and waits for both WANs to be online, so it can run again after a
failed run.

1. Luật chọn WAN: the check server sees the accounting client as `198.51.100.3` (ISP-B), and sees the LAN
   client and the router as `203.0.113.2` (ISP-A). A DNS query to 8.8.8.8, from the LAN client and from the
   router itself, gets ISP-A's answer.
2. Route cụ thể: UDP from the accounting client to 10.20.0.1 reaches R3 over Link định tuyến with its own
   source address (not NATed). No ISP sees it, even though the accounting rule points to ISP-B.
3. Inbound: `198.51.100.3:8080`, reached from 9.9.9.9 behind ISP-B, gets the LAN server through the port
   forward. The answer leaves through `wan2`: ISP-A, which also carries 9.9.9.9, never sees it.
4. `/etc/init.d/firewall reload` on R1: checks 1–3 again, and the first connection after the reload must
   already take the right path. The same after `firewall restart`, which flushes mwan3's chains until
   bmcMultiWAN's firewall include restarts mwan3, so a short gap is allowed there.
5. Chuyển WAN: ISP-A's upstream is cut while its link stays up. Both the LAN client and the router must switch
   to ISP-B within `MWAN_SWITCH_MAX_SECONDS`: `wget` of the check server shows ISP-B, and a DNS query
   to 8.8.8.8 gets ISP-B's answer. `bmcmultiwan status` then shows `wan` `lost` and the default
   policy on `wan2`. Next, a long TCP connection is opened through ISP-B and the upstream is restored. Once
   `wan` is online again, new connections and DNS of the client and the router go through ISP-A, and the
   accounting client stays on ISP-B. The long connection keeps receiving from ISP-B for 10 s, and none of
   its packets reach ISP-A.

## Limits

- **Detection time.** mwan3track pings 1.1.1.1 and then 8.8.8.8, 2 s timeout each, every 5 s. With the product
  default `down 3`, Mất Internet is reported 25–30 s after the cut (tickets 01/02). The cluster sets `down 2`
  through the CLI, which an operator can do too. mwan3track alone then needs up to 5 + 4 + 5 + 4 = 18 s, and
  mwan3's reaction plus the probes add 1–4 s on TCG. Five runs measured 17.2, 17.3, 19.8, 20.3 and 22.3 s (the slower of client and router), so the budget is
  **25 s**, not the 20 s first asked for in ticket 07. Meeting 20 s would need one ping target or a shorter
  `failure_interval`; both were declined. Recovery uses `up 5` and takes about 26–30 s. The measured times
  are printed as `NOTE:` lines.
- **Timing on TCG** is not representative of LS1046 hardware. Each serial command costs about a second, so a
  measured switch time is an upper bound (probes run every ~1–2 s). The pings of mwan3track also run slower
  under load. A busy host, such as a parallel firmware build, can push the switch past the budget. Rerun on an
  idle host before reading it as a regression.
- The fake Internet is local to each ISP (two copies of 9.9.9.9), not one shared network. Only the check
  server's reply and the DNS answer show which ISP was used.
- The product's DNS server on port 53 (bmcfirewall, with its own upstream list) is not in the image; dnsmasq
  there only does DHCP (port 54). The router's DNS is checked with a query from the router to 8.8.8.8,
  which leaves the router like that server's upstream queries (router traffic, default Chính sách WAN).
- The kernel is armsr's, not LS1046's. Real ports, DPAA and hardware offload are covered by ticket 08 on the
  board.
