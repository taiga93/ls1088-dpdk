#!/usr/bin/env python3
"""Seam 2 scenarios: what goes into a running bmchwaccel-engine and what must
come out, for the feeder (feeder.c).

    scenario.py --list
    scenario.py NAME DIR

writes into DIR: in/NN-STREAM.pcap (what is sent), script (for the feeder),
expect/STREAM.pcap (what the engine must send on each stream),
expect/transcript (the control requests and the replies they must get),
for a scenario that wants the engine started with more options,
engine-args, and for one that wants lines in the engine's log, engine-log
(each line must be in it).

The example of the spec: eth0 is the WAN (port 0), eth1 the LAN (port 1).
A stream is a side of a port: eth1-wire is the cable of eth1, eth1-kernel
the kernel. Expected packets are built here from scratch, checksums
included; nothing comes from the engine.
"""
import hashlib
import hmac
import os
import struct
import subprocess
import sys

# addresses of the example
HOST_MAC = "02:00:00:00:00:0a"   # PC 192.168.5.10 on the LAN
SRV_MAC = "02:00:00:00:00:14"    # server 192.168.5.20 on the LAN
RLAN_MAC = "02:00:00:00:00:01"   # the router on the LAN
RWAN_MAC = "02:00:00:00:00:02"   # the router on the WAN
GW_MAC = "02:00:00:00:00:fe"     # the gateway of the ISP
HOST, SRV = "192.168.5.10", "192.168.5.20"
RWAN = "198.51.100.2"            # the router's WAN address
WEB, CLIENT = "203.0.113.5", "203.0.113.9"

STREAMS = ["eth0-wire", "eth0-kernel", "eth1-wire", "eth1-kernel"]
SYN, FIN, RST, PSH, ACK = 0x02, 0x01, 0x04, 0x08, 0x10


def mac(s):
    return bytes(int(x, 16) for x in s.split(":"))


def ip(s):
    return bytes(int(x) for x in s.split("."))


def csum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return ~s & 0xffff


def ipv4(src, dst, proto, l4, ttl=64, frag=0x4000, options=b"", ident=0x1234, length=None):
    ihl = 5 + len(options) // 4
    n = ihl * 4 + len(l4) if length is None else length
    h = struct.pack("!BBHHHBBH4s4s", 0x40 | ihl, 0, n, ident, frag, ttl,
                    proto, 0, ip(src), ip(dst)) + options
    return h[:10] + struct.pack("!H", csum(h)) + h[12:] + l4


def pseudo(src, dst, proto, n):
    return ip(src) + ip(dst) + struct.pack("!BBH", 0, proto, n)


def payload(n, seed=0):
    return bytes((i * 7 + 1 + seed) & 0xff for i in range(n))


def tcp(src, sport, dst, dport, flags=ACK, data=b"", ttl=64, **kw):
    h = struct.pack("!HHIIBBHHH", sport, dport, 1000, 2000, 5 << 4, flags, 64240, 0, 0)
    c = csum(pseudo(src, dst, 6, len(h) + len(data)) + h + data)
    return ipv4(src, dst, 6, h[:16] + struct.pack("!H", c) + h[18:] + data, ttl, **kw)


def udp(src, sport, dst, dport, data=b"", ttl=64, nocsum=False, **kw):
    h = struct.pack("!HHHH", sport, dport, 8 + len(data), 0)
    c = 0 if nocsum else csum(pseudo(src, dst, 17, len(h) + len(data)) + h + data) or 0xffff
    return ipv4(src, dst, 17, h[:6] + struct.pack("!H", c) + data, ttl, **kw)


def eth(dst, src, l3, ethertype=0x0800, vlan=None, pppoe=None, pad=True):
    """A frame, padded to 60 bytes as it comes off a cable unless pad is
    False: the engine sends a frame whose header it changed without the
    padding it came in with."""
    tag = b""
    if vlan is not None:
        tag += struct.pack("!HH", 0x8100, vlan)
    if pppoe is not None:
        tag += struct.pack("!H", 0x8864)
        ethertype = None
        l3 = struct.pack("!BBHHH", 0x11, 0, pppoe, 2 + len(l3), 0x0021) + l3
    if ethertype is not None:
        tag += struct.pack("!H", ethertype)
    frame = mac(dst) + mac(src) + tag + l3
    return frame + b"\0" * max(0, 60 - len(frame)) if pad else frame


def write_pcap(path, frames):
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
        for p in frames:
            f.write(struct.pack("<IIII", 0, 0, len(p), len(p)) + p)


class Scenario:
    def __init__(self, d):
        self.d = d
        self.n = 0
        self.script = []
        self.expect = {s: [] for s in STREAMS}
        self.transcript = []
        self.sent = {s: [] for s in STREAMS}
        self.engine_args = ""
        self.engine_log = []
        os.makedirs(os.path.join(d, "in"), exist_ok=True)
        os.makedirs(os.path.join(d, "expect"), exist_ok=True)

    def send(self, stream, frames, **expect):
        """Sends frames on stream; expect: stream (eth1_kernel) -> frames out."""
        self.n += 1
        path = os.path.join(self.d, "in", "%02d-%s.pcap" % (self.n, stream))
        write_pcap(path, frames)
        self.script += ["send %s %s" % (stream, path), "quiet"]
        self.sent[stream] += frames
        for s, out in expect.items():
            self.expect[s.replace("_", "-")] += out

    def ctl(self, request, *reply):
        self.script.append("ctl " + request)
        self.transcript += ["> " + request] + ["< " + r for r in reply]

    def reconnect(self):
        """Closes the control session and opens a new one."""
        self.script.append("reconnect")
        self.transcript.append("-- reconnect")

    def ports(self):
        """The ports request: up at the speed net_memif reports, and what
        crossed the cable of each port so far, kernel traffic and accelerated
        alike; the kernel sides do not count."""
        lines = []
        for p in ("eth0", "eth1"):
            rx, tx = self.sent[p + "-wire"], self.expect[p + "-wire"]
            lines.append("port %s link=up speed=100000 rx_bytes=%d tx_bytes=%d"
                         " rx_packets=%d tx_packets=%d"
                         % (p, sum(map(len, rx)), sum(map(len, tx)), len(rx), len(tx)))
        self.ctl("ports", *lines, "ok")

    def write(self):
        with open(os.path.join(self.d, "script"), "w") as f:
            f.write("\n".join(self.script) + "\n")
        with open(os.path.join(self.d, "expect", "transcript"), "w") as f:
            f.write("\n".join(self.transcript) + "\n")
        for s in STREAMS:
            write_pcap(os.path.join(self.d, "expect", s + ".pcap"), self.expect[s])
        if self.engine_args:
            with open(os.path.join(self.d, "engine-args"), "w") as f:
                f.write(self.engine_args + "\n")
        if self.engine_log:
            with open(os.path.join(self.d, "engine-log"), "w") as f:
                f.write("\n".join(self.engine_log) + "\n")


# Frames of the masqueraded connection of the PC to the web server, TCP
# 192.168.5.10:40000 -> 203.0.113.5:443 seen as 198.51.100.2:40000 outside.
def m_out(flags=ACK, data=b"", ttl=64, **kw):
    return eth(RLAN_MAC, HOST_MAC, tcp(HOST, 40000, WEB, 443, flags, data, ttl), **kw)


def m_out_nat(flags=ACK, data=b"", ttl=63, **kw):
    return eth(GW_MAC, RWAN_MAC, tcp(RWAN, 40000, WEB, 443, flags, data, ttl), **kw)


def m_back(flags=ACK, data=b"", ttl=50, **kw):
    return eth(RWAN_MAC, GW_MAC, tcp(WEB, 443, RWAN, 40000, flags, data, ttl), **kw)


def m_back_nat(flags=ACK, data=b"", ttl=49, **kw):
    return eth(HOST_MAC, RLAN_MAC, tcp(WEB, 443, HOST, 40000, flags, data, ttl), **kw)


MASQ_BIND = "bind tcp 192.168.5.10 40000 203.0.113.5 443 203.0.113.5 443 198.51.100.2 40000"


def masq_handshake(s, lan={}, wan={}):
    """SYN, SYN-ACK and ACK through the kernel, learned on the way; lan and
    wan: the VLAN and PPPoE session of each end (eth()), none by default."""
    for f in (SYN, ACK):
        s.send("eth1-wire", [m_out(f, **lan)], eth1_kernel=[m_out(f, **lan)])
        s.send("eth0-kernel", [m_out_nat(f, **wan)], eth0_wire=[m_out_nat(f, **wan)])
        if f == SYN:
            s.send("eth0-wire", [m_back(SYN | ACK, **wan)],
                   eth0_kernel=[m_back(SYN | ACK, **wan)])
            s.send("eth1-kernel", [m_back_nat(SYN | ACK, **lan)],
                   eth1_wire=[m_back_nat(SYN | ACK, **lan)])


def masquerade(s):
    masq_handshake(s)
    s.ctl("count", "ok 0")
    s.ctl(MASQ_BIND, "ok")
    s.ctl("count", "ok 1")
    s.ctl(MASQ_BIND, "err exists")
    sizes = [1000, 1460, 1, 0]
    s.send("eth1-wire", [m_out(PSH | ACK, payload(n, n)) for n in sizes],
           eth0_wire=[m_out_nat(PSH | ACK, payload(n, n)) for n in sizes])
    s.send("eth0-wire", [m_back(ACK, payload(n, 3)) for n in (1460, 77)],
           eth1_wire=[m_back_nat(ACK, payload(n, 3), ttl=49) for n in (1460, 77)])
    s.ctl("list", "conn tcp 192.168.5.10 40000 203.0.113.5 443 203.0.113.5 443 198.51.100.2 40000"
          " orig_in=eth1 orig_out=eth0 orig_pkts=4 orig_bytes=%d orig_idle=*"
          " reply_in=eth0 reply_out=eth1 reply_pkts=2 reply_bytes=%d reply_idle=*"
          % (sum(max(60, 54 + n) for n in sizes), (54 + 1460) + (54 + 77)), "ok 1")
    # FIN goes to the kernel, which closes the connection
    s.send("eth1-wire", [m_out(FIN | ACK)], eth1_kernel=[m_out(FIN | ACK)])
    s.ctl("unbind tcp 192.168.5.10 40000 203.0.113.5 443", "ok")
    s.ctl("unbind tcp 192.168.5.10 40000 203.0.113.5 443", "err unknown")
    s.ctl("count", "ok 0")
    s.send("eth1-wire", [m_out(ACK, payload(10))], eth1_kernel=[m_out(ACK, payload(10))])

    # UDP to a DNS server through the masquerade, with and without checksum
    def u_out(n, nocsum=False, src_mac=HOST_MAC, dst_mac=RLAN_MAC, src=HOST, ttl=64):
        return eth(dst_mac, src_mac, udp(src, 50000, WEB, 53, payload(n), ttl, nocsum))

    def u_back(n, dst_mac=RWAN_MAC, src_mac=GW_MAC, dst=RWAN, ttl=64):
        return eth(dst_mac, src_mac, udp(WEB, 53, dst, 50000, payload(n, 9), ttl))

    s.send("eth1-wire", [u_out(40)], eth1_kernel=[u_out(40)])
    s.send("eth0-kernel", [u_out(40, False, RWAN_MAC, GW_MAC, RWAN, 63)],
           eth0_wire=[u_out(40, False, RWAN_MAC, GW_MAC, RWAN, 63)])
    s.send("eth0-wire", [u_back(100)], eth0_kernel=[u_back(100)])
    s.send("eth1-kernel", [u_back(100, HOST_MAC, RLAN_MAC, HOST, 63)],
           eth1_wire=[u_back(100, HOST_MAC, RLAN_MAC, HOST, 63)])
    s.ctl("bind udp 192.168.5.10 50000 203.0.113.5 53 203.0.113.5 53 198.51.100.2 50000", "ok")
    s.send("eth1-wire", [u_out(33), u_out(34, nocsum=True)],
           eth0_wire=[u_out(33, False, RWAN_MAC, GW_MAC, RWAN, 63),
                      u_out(34, True, RWAN_MAC, GW_MAC, RWAN, 63)])
    s.send("eth0-wire", [u_back(512)], eth1_wire=[u_back(512, HOST_MAC, RLAN_MAC, HOST, 63)])
    s.ctl("flush", "ok 1")
    s.send("eth0-wire", [u_back(512)], eth0_kernel=[u_back(512)])


def port_forward(s):
    """203.0.113.9 opens 198.51.100.2:8080, forwarded to 192.168.5.20:80."""
    def c_in(f=ACK, data=b"", ttl=64):
        return eth(RWAN_MAC, GW_MAC, tcp(CLIENT, 5555, RWAN, 8080, f, data, ttl))

    def c_in_nat(f=ACK, data=b"", ttl=63):
        return eth(SRV_MAC, RLAN_MAC, tcp(CLIENT, 5555, SRV, 80, f, data, ttl))

    def s_back(f=ACK, data=b"", ttl=64):
        return eth(RLAN_MAC, SRV_MAC, tcp(SRV, 80, CLIENT, 5555, f, data, ttl))

    def s_back_nat(f=ACK, data=b"", ttl=63):
        return eth(GW_MAC, RWAN_MAC, tcp(RWAN, 8080, CLIENT, 5555, f, data, ttl))

    s.send("eth0-wire", [c_in(SYN)], eth0_kernel=[c_in(SYN)])
    s.send("eth1-kernel", [c_in_nat(SYN)], eth1_wire=[c_in_nat(SYN)])
    s.send("eth1-wire", [s_back(SYN | ACK)], eth1_kernel=[s_back(SYN | ACK)])
    s.send("eth0-kernel", [s_back_nat(SYN | ACK)], eth0_wire=[s_back_nat(SYN | ACK)])
    s.ctl("bind tcp 203.0.113.9 5555 198.51.100.2 8080 192.168.5.20 80 203.0.113.9 5555", "ok")
    s.send("eth0-wire", [c_in(PSH | ACK, payload(300)), c_in(ACK, payload(1460, 1))],
           eth1_wire=[c_in_nat(PSH | ACK, payload(300)), c_in_nat(ACK, payload(1460, 1))])
    s.send("eth1-wire", [s_back(ACK, payload(1200, 2))],
           eth0_wire=[s_back_nat(ACK, payload(1200, 2))])
    s.ctl("flush-port eth1", "conn tcp 203.0.113.9 5555 198.51.100.2 8080", "ok 1")
    s.send("eth1-wire", [s_back(ACK, payload(5))], eth1_kernel=[s_back(ACK, payload(5))])


def kernel(s):
    """What always goes to the kernel, even of an accelerated connection."""
    masq_handshake(s)
    s.ctl(MASQ_BIND, "ok")
    arp = eth("ff:ff:ff:ff:ff:ff", HOST_MAC, bytes(28), 0x0806)
    ip6 = eth(RLAN_MAC, HOST_MAC, struct.pack("!IHBB", 6 << 28, 20, 6, 64) + bytes(32)
              + struct.pack("!HH", 40000, 443) + bytes(16), 0x86dd)
    icmp = eth(RLAN_MAC, HOST_MAC, ipv4(HOST, WEB, 1, b"\x08\0\0\0" + payload(56)))
    up = [
        arp, ip6, icmp,
        m_out(ACK, payload(20), vlan=30),                     # a VLAN it is not on
        m_back(ACK, payload(20), pppoe=0x1234),                # a session it is not in
        eth("01:00:5e:01:01:01", HOST_MAC, tcp(HOST, 40000, WEB, 443)),  # multicast MAC
        m_out(ACK, ttl=1),
        eth(RLAN_MAC, HOST_MAC, tcp(HOST, 40000, WEB, 443, frag=0x2000)),  # more fragments
        eth(RLAN_MAC, HOST_MAC, tcp(HOST, 40000, WEB, 443, options=b"\x01" * 4)),
        m_out(ACK, payload(1461)),                             # 1501 > MTU 1500 of eth0
        m_out(SYN), m_out(RST),
    ]
    lan = [f for f in up if f[:6] != mac(RWAN_MAC)]
    wan = [f for f in up if f[:6] == mac(RWAN_MAC)]
    s.send("eth1-wire", lan, eth1_kernel=lan)
    s.send("eth0-wire", wan, eth0_kernel=wan)
    # and what the kernel sends goes out as it is
    s.send("eth1-kernel", [arp, ip6, m_back_nat(ACK, payload(9), ttl=1)],
           eth1_wire=[arp, ip6, m_back_nat(ACK, payload(9), ttl=1)])
    s.ctl("count", "ok 1")


def refused(s):
    """A PC on a 1G port the kernel keeps: only the WAN half passes the engine."""
    s.send("eth0-kernel", [m_out_nat(SYN)], eth0_wire=[m_out_nat(SYN)])
    s.send("eth0-wire", [m_back(SYN | ACK)], eth0_kernel=[m_back(SYN | ACK)])
    s.ctl(MASQ_BIND, "err unlearned orig-in,reply-out")
    s.ctl("count", "ok 0")
    s.ctl("flush-port eth0", "ok 0")
    s.ctl("flush-port eth9", "err unknown-port")
    s.ctl("bind tcp 192.168.5.10 40000", "err usage")
    s.ctl("bind icmp 192.168.5.10 40000 203.0.113.5 443 203.0.113.5 443 198.51.100.2 40000",
          "err usage")
    s.ctl("stats please", "err usage")
    s.ctl("hello", "err unknown-command")
    s.send("eth0-wire", [m_back(ACK, payload(100))], eth0_kernel=[m_back(ACK, payload(100))])


def ports(s):
    """Link, speed and the counters of the cable side of each port."""
    s.ports()
    masq_handshake(s)
    s.ports()
    s.ctl(MASQ_BIND, "ok")
    sizes = [1000, 1460, 7]
    s.send("eth1-wire", [m_out(PSH | ACK, payload(n, n)) for n in sizes],
           eth0_wire=[m_out_nat(PSH | ACK, payload(n, n)) for n in sizes])
    s.send("eth0-wire", [m_back(ACK, payload(1460, 3))],
           eth1_wire=[m_back_nat(ACK, payload(1460, 3), ttl=49)])
    s.ports()
    s.ctl("ports now", "err usage")


def reroute(s):
    """What bmchwaccel-syncd asks when a route or a neighbour changes: the
    connections sent that way go through the kernel again, the others stay."""
    masq_handshake(s)
    s.ctl(MASQ_BIND, "ok")
    s.ctl("flush-route 198.18.0.0/15", "ok 0")
    s.ctl("flush-route 203.0.113.0/24", "conn tcp 192.168.5.10 40000 203.0.113.5 443", "ok 1")
    s.send("eth1-wire", [m_out(PSH | ACK, payload(50))], eth1_kernel=[m_out(PSH | ACK, payload(50))])
    # learned again from what the kernel sends now, and bound again
    masq_handshake(s)
    s.ctl(MASQ_BIND, "ok")
    s.ctl("flush-mac 02:00:00:00:00:77", "ok 0")
    s.ctl("flush-mac " + GW_MAC, "conn tcp 192.168.5.10 40000 203.0.113.5 443", "ok 1")
    s.send("eth1-wire", [m_out(PSH | ACK, payload(60))], eth1_kernel=[m_out(PSH | ACK, payload(60))])
    masq_handshake(s)
    s.ctl(MASQ_BIND, "ok")
    s.ctl("flush-route 0.0.0.0/0", "conn tcp 192.168.5.10 40000 203.0.113.5 443", "ok 1")
    s.ctl("flush-route 203.0.113.0", "err usage")
    s.ctl("flush-route 203.0.113.0/33", "err usage")
    s.ctl("flush-route 203.0.113.0/", "err usage")
    s.ctl("flush-route web/24", "err usage")
    s.ctl("flush-mac 02:00:00:00:00", "err usage")
    s.ctl("flush-mac", "err usage")
    s.ctl("count", "ok 0")


MASQ_UNBIND = "unbind tcp 192.168.5.10 40000 203.0.113.5 443"


def vlan_pppoe(s):
    """The LAN on VLAN 30 (eth1.30) to a plain WAN, a plain LAN to PPPoE
    (session 0x1234), VLAN to PPPoE, and PPPoE on VLAN 35 of the WAN: the
    engine sends each packet with the header the kernel sent, VLAN tag and
    PPPoE header with its length, and keeps 8 bytes of the MTU for PPPoE."""
    ways = [({"vlan": 30}, {}), ({}, {"pppoe": 0x1234}), ({"vlan": 30}, {"pppoe": 0x1234}),
            ({"vlan": 30}, {"vlan": 35, "pppoe": 0x1234})]
    for lan, wan in ways:
        masq_handshake(s, lan, wan)
        s.ctl(MASQ_BIND, "ok")
        # 1452: the largest packet in PPPoE, 20 + 20 + 1452 = 1492
        sizes = [1000, 1452, 0]
        s.send("eth1-wire", [m_out(PSH | ACK, payload(n, n), **lan) for n in sizes],
               eth0_wire=[m_out_nat(PSH | ACK, payload(n, n), pad=False, **wan) for n in sizes])
        s.send("eth0-wire", [m_back(ACK, payload(n, 3), **wan) for n in sizes],
               eth1_wire=[m_back_nat(ACK, payload(n, 3), pad=False, **lan) for n in sizes])
        big = m_out(PSH | ACK, payload(1453), **lan)
        if "pppoe" in wan:
            s.send("eth1-wire", [big], eth1_kernel=[big])
        else:
            s.send("eth1-wire", [big], eth0_wire=[m_out_nat(PSH | ACK, payload(1453), **wan)])
        # another VLAN, another session: another connection
        s.send("eth1-wire", [m_out(ACK, payload(7), vlan=31)],
               eth1_kernel=[m_out(ACK, payload(7), vlan=31)])
        s.send("eth0-wire", [m_back(ACK, payload(7), pppoe=0x4321)],
               eth0_kernel=[m_back(ACK, payload(7), pppoe=0x4321)])
        s.ctl(MASQ_UNBIND, "ok")


def pppoe_redial(s):
    """PPPoE dials again: pppoe-wan goes away and bmchwaccel-syncd flushes
    the engine. Packets still in the old session go to the kernel; the
    connections of the new session are learned and accelerated in it."""
    old, new = {"pppoe": 0x1234}, {"pppoe": 0x2345}
    masq_handshake(s, {}, old)
    s.ctl(MASQ_BIND, "ok")
    s.send("eth1-wire", [m_out(PSH | ACK, payload(100))],
           eth0_wire=[m_out_nat(PSH | ACK, payload(100), **old)])
    s.ctl("flush", "ok 1")
    s.send("eth0-wire", [m_back(ACK, payload(20), **old)],
           eth0_kernel=[m_back(ACK, payload(20), **old)])
    masq_handshake(s, {}, new)
    s.ctl(MASQ_BIND, "ok")
    s.send("eth1-wire", [m_out(PSH | ACK, payload(200))],
           eth0_wire=[m_out_nat(PSH | ACK, payload(200), **new)])
    s.send("eth0-wire", [m_back(ACK, payload(30), **old), m_back(ACK, payload(30), **new)],
           eth0_kernel=[m_back(ACK, payload(30), **old)],
           eth1_wire=[m_back_nat(ACK, payload(30), pad=False)])
    s.ctl("count", "ok 1")


def daemon(s):
    """The session of the daemon: it claims the engine, reads which connections
    still forward packets, and the engine lets go of every connection when the
    session closes."""
    masq_handshake(s)
    s.ctl("claimed", "ok no")
    s.ctl("claim", "ok")
    s.ctl("claim", "ok")
    s.ctl("claimed", "ok yes")
    s.ctl(MASQ_BIND, "ok")
    # bound, but nothing forwarded yet
    s.ctl("active 60000", "ok 0")
    s.send("eth1-wire", [m_out(PSH | ACK, payload(100))],
           eth0_wire=[m_out_nat(PSH | ACK, payload(100))])
    s.ctl("active 60000", "conn tcp 192.168.5.10 40000 203.0.113.5 443 idle=*", "ok 1")
    s.ctl("active 0", "ok 0")
    s.ctl("active", "err usage")
    s.ctl("active soon", "err usage")
    s.ctl("claimed now", "err usage")
    s.reconnect()
    s.ctl("claimed", "ok no")
    s.ctl("count", "ok 0")
    s.send("eth1-wire", [m_out(PSH | ACK, payload(5))], eth1_kernel=[m_out(PSH | ACK, payload(5))])
    # a session that never claimed leaves the connections alone
    masq_handshake(s)
    s.ctl(MASQ_BIND, "ok")
    s.reconnect()
    s.ctl("count", "ok 1")


# Tunnel IPsec: the router (RWAN) and its peer PEER on the WAN, ESP in UDP
# 4500 as the VPN page makes it, aes256-cbc + hmac-sha256-128, the keys of
# tests/esp/linux-esp.sh. The test engine does ESP with OpenSSL: IV of the
# SPI and the number twice, padding 1, 2, 3..., outer header TTL 64 with
# the DF of the inner packet, IP id of each SA from 0, UDP checksum 0.
PEER = "203.0.113.1"
SPI_OUT, SPI_IN = 0xc0010001, 0xc0010002
KEY = bytes(range(0x10, 0x30))
AUTH = bytes(range(0x40, 0x60))
FIRST = (1 << 24) + 1   # oseq 1 of the kernel + 2^24
SA_OUT = ("sa-add out 0x%08x %s %s 4500 4500 7 cbc %s sha256 %s 0 %d"
          % (SPI_OUT, RWAN, PEER, KEY.hex(), AUTH.hex(), FIRST))
SA_IN = ("sa-add in 0x%08x %s %s 4500 4500 7 cbc %s sha256 %s 32 0"
         % (SPI_IN, PEER, RWAN, KEY.hex(), AUTH.hex()))


def aes256_cbc(iv, data):
    return subprocess.run(["openssl", "enc", "-aes-256-cbc", "-K", KEY.hex(), "-iv", iv.hex(),
                           "-nopad"], input=data, stdout=subprocess.PIPE, check=True).stdout


def esp(inner, seq, ident, iv=None, spi=SPI_OUT, src=RWAN, dst=PEER):
    """The inner packet in ESP in UDP from the router to the peer; iv None: the engine's."""
    pad = -(len(inner) + 2) % 16
    hdr = struct.pack("!II", spi, seq)
    iv = iv or hdr + hdr
    ct = aes256_cbc(iv, inner + bytes(range(1, pad + 1)) + bytes([pad, 4]))
    e = hdr + iv + ct + hmac.new(AUTH, hdr + iv + ct, hashlib.sha256).digest()[:16]
    return ipv4(src, dst, 17, struct.pack("!HHHH", 4500, 4500, 8 + len(e), 0) + e, 64,
                frag=inner[6] << 8 & 0x4000, ident=ident)


def kernel_esp(inner, seq):
    """What the kernel sends: its own IV and IP ids, its own numbers."""
    return esp(inner, seq, 0x5000 + seq, iv=bytes([0xa0 + seq]) * 16)


def fragments(pkt, mtu=1500):
    """The IPv4 packet in fragments of at most mtu, as Linux makes them."""
    h, data, step, out = pkt[:20], pkt[20:], (mtu - 20) & ~7, []
    for off in range(0, len(data), step):
        part = data[off:off + step]
        f = (off // 8) | (0x2000 if off + len(part) < len(data) else 0)
        g = h[:2] + struct.pack("!HHH", 20 + len(part), struct.unpack_from("!H", h, 4)[0], f) + \
            h[8:10] + b"\0\0" + h[12:20]
        out.append(g[:10] + struct.pack("!H", csum(g)) + g[12:] + part)
    return out


def to_peer(l3, pad=False):
    return eth(GW_MAC, RWAN_MAC, l3, pad=pad)


def ipsec(s):
    """The kernel's ESP on an outbound SA the engine holds goes out with the
    engine's numbers; what is not ESP of it goes out as the kernel sent it;
    an SA let go of leaves the kernel's ESP alone; the daemon's session
    closing lets go of every SA."""
    a = udp(HOST, 40000, "10.20.0.10", 5201, payload(100))
    b = tcp(HOST, 40001, "10.20.0.10", 5201, PSH | ACK, payload(300, 1))
    s.ctl("claim", "ok")
    s.ctl("sa", "ok 0")
    s.ctl(SA_OUT, "ok")
    s.ctl(SA_OUT, "err exists")
    s.ctl(SA_IN, "ok")
    s.ctl(SA_OUT.replace("cbc", "ctr"), "err usage")
    s.ctl("sa-add out 0x1 %s %s 0 0 7 cbc %s sha256 %s 0 0" % (RWAN, PEER, KEY.hex()[:30],
                                                                 AUTH.hex()), "err unsupported")
    s.ctl("sa",
          "sa spi=0x%08x dir=out reqid=7 src=%s dst=%s bytes=0 packets=0 seq=%d failed=0 dropped=0"
          % (SPI_OUT, RWAN, PEER, FIRST - 1),
          "sa spi=0x%08x dir=in reqid=7 src=%s dst=%s bytes=0 packets=0 failed=0 dropped=0"
          % (SPI_IN, PEER, RWAN), "ok 2")
    # numbered again: the kernel's numbers 1 and 2 leave as the engine's
    s.send("eth0-kernel", [to_peer(kernel_esp(a, 1)), to_peer(kernel_esp(b, 2))],
           eth0_wire=[to_peer(esp(a, FIRST, 0)), to_peer(esp(b, FIRST + 1, 1))])
    # IKE (the non-ESP marker), a keepalive, ESP of an SPI not held, from
    # another address of the router, plain UDP: as they are
    ike = udp(RWAN, 4500, PEER, 4500, b"\0\0\0\0" + payload(60), nocsum=True)
    keepalive = udp(RWAN, 4500, PEER, 4500, b"\xff", nocsum=True)
    other = esp(a, 9, 3, spi=0xc0099999)
    moved = kernel_esp(a, 3)
    moved = ipv4("198.51.100.3", PEER, 17, moved[20:], 64, ident=0x5003)
    plain = udp(RWAN, 33000, PEER, 53, payload(40))
    passed = [to_peer(p, pad=True) for p in (ike, keepalive, other, moved, plain)]
    s.send("eth0-kernel", passed, eth0_wire=passed)
    # a large packet without DF: the kernel's ESP in fragments, put together,
    # numbered again and fragmented again; the last fragment first
    big = udp(HOST, 40002, "10.20.0.10", 5201, payload(1472, 2), frag=0)
    frags = [to_peer(f) for f in fragments(kernel_esp(big, 3))]
    # with the kernel's IP id: the SEC gives every packet 0
    s.send("eth0-kernel", frags[::-1],
           eth0_wire=[to_peer(f) for f in fragments(esp(big, FIRST + 2, 0x5003))])
    # one whose ESP is longer than a packet of the engine's pool
    huge = udp(HOST, 40003, "10.20.0.10", 5201, payload(3972, 5), frag=0)
    s.send("eth0-kernel", [to_peer(f) for f in fragments(kernel_esp(huge, 5))],
           eth0_wire=[to_peer(f) for f in fragments(esp(huge, FIRST + 3, 0x5005))])
    # stopped: its last number, and the kernel's ESP on it dropped until it is deleted
    s.ctl("sa-stop 0x%08x %s" % (SPI_OUT, PEER),
          "sa spi=0x%08x dir=out reqid=7 src=%s dst=%s bytes=0 packets=0 seq=%d failed=0 dropped=0"
          % (SPI_OUT, RWAN, PEER, FIRST + 3), "ok")
    s.send("eth0-kernel", [to_peer(kernel_esp(a, 4))])
    s.ctl("sa-del 0x%08x %s" % (SPI_OUT, PEER),
          "sa spi=0x%08x dir=out reqid=7 src=%s dst=%s bytes=0 packets=0 seq=%d failed=0 dropped=1"
          % (SPI_OUT, RWAN, PEER, FIRST + 3), "ok")
    s.ctl("sa-del 0x%08x %s" % (SPI_OUT, PEER), "err unknown")
    s.ctl("sa-del 0x%08x nowhere" % SPI_OUT, "err usage")
    # let go of: the kernel numbers it from then on
    s.send("eth0-kernel", [to_peer(kernel_esp(a, 4))], eth0_wire=[to_peer(kernel_esp(a, 4))])
    # the daemon's session closing lets go of the rest
    s.ctl("sa", "sa spi=0x%08x dir=in reqid=7 src=%s dst=%s bytes=0 packets=0 failed=0 dropped=0"
          % (SPI_IN, PEER, RWAN), "ok 1")
    s.reconnect()
    s.ctl("sa", "ok 0")
    s.ctl("sa-flush", "ok 0")


FAR = "10.20.0.10"              # behind the peer
SPI_OTHER = 0xc0010003          # an inbound SA of another tunnel


def peer_esp(inner, seq, spi=SPI_IN):
    """What the peer sends to the router: its own IV and IP ids."""
    return eth(RWAN_MAC, GW_MAC, esp(inner, seq, 0x7000 + seq, iv=bytes([0xc0 + seq]) * 16,
                                     spi=spi, src=PEER, dst=RWAN))


def t_out(flags=ACK, data=b"", ttl=64, **kw):
    return tcp(HOST, 40010, FAR, 5201, flags, data, ttl, **kw)


def t_back(flags=ACK, data=b"", ttl=64, **kw):
    return tcp(FAR, 5201, HOST, 40010, flags, data, ttl, **kw)


T_BIND = "bind tcp 192.168.5.10 40010 10.20.0.10 5201 10.20.0.10 5201 192.168.5.10 40010"
T_CONN = "conn tcp 192.168.5.10 40010 10.20.0.10 5201"   # as the engine tells it let go of it


def ipsec_accel(s):
    """A connection through the tunnel (spec-ipsec: Đường gói ①–④): its
    first packets through the kernel, which the engine learns from; once
    bound, the engine encrypts PC1's packets and decrypts the peer's on its
    own. What another tunnel decrypted, what the kernel must see and what is
    too large for the tunnel go to the kernel."""
    s.ctl("claim", "ok")
    s.ctl(SA_OUT, "ok")
    s.ctl(SA_IN, "ok")
    s.ctl("sa-add in 0x%08x %s %s 4500 4500 8 cbc %s sha256 %s 32 0"
          % (SPI_OTHER, PEER, RWAN, KEY.hex(), AUTH.hex()), "ok")
    lan_out = lambda l3: eth(RLAN_MAC, HOST_MAC, l3)
    lan_back = lambda l3: eth(HOST_MAC, RLAN_MAC, l3, pad=False)
    # ① and ②: the handshake through the kernel, numbered again, its ESP up as it came
    seq = {"kernel": 0, "engine": 0, "peer": 0}

    def out_kernel(flags, data=b""):
        s.send("eth1-wire", [lan_out(t_out(flags, data))], eth1_kernel=[lan_out(t_out(flags, data))])
        seq["kernel"] += 1
        inner = t_out(flags, data, ttl=63)
        s.send("eth0-kernel", [to_peer(kernel_esp(inner, seq["kernel"]))],
               eth0_wire=[to_peer(esp(inner, FIRST + seq["engine"], seq["engine"]))])
        seq["engine"] += 1

    def back_kernel(flags, data=b"", spi=SPI_IN):
        seq["peer"] += 1
        f = peer_esp(t_back(flags, data), seq["peer"], spi)
        s.send("eth0-wire", [f], eth0_kernel=[f])

    out_kernel(SYN)
    back_kernel(SYN | ACK)
    s.send("eth1-kernel", [lan_back(t_back(SYN | ACK, ttl=63))],
           eth1_wire=[lan_back(t_back(SYN | ACK, ttl=63))])
    out_kernel(ACK)
    s.ctl("count", "ok 0")
    s.ctl(T_BIND, "ok")
    s.ctl("count", "ok 1")
    # ③ PC1 -> the tunnel, encrypted by the engine with its next number
    data = payload(1000, 4)
    inner = t_out(PSH | ACK, data, ttl=63)
    s.send("eth1-wire", [lan_out(t_out(PSH | ACK, data))],
           eth0_wire=[to_peer(esp(inner, FIRST + seq["engine"], seq["engine"]))])
    out_len = len(inner)
    seq["engine"] += 1
    # ④ the tunnel -> PC1, decrypted by the engine
    seq["peer"] += 1
    back = payload(1200, 5)
    s.send("eth0-wire", [peer_esp(t_back(PSH | ACK, back), seq["peer"])],
           eth1_wire=[lan_back(t_back(PSH | ACK, back, ttl=63))])
    back_len = len(t_back(PSH | ACK, back))
    s.ctl("sa",
          "sa spi=0x%08x dir=out reqid=7 src=%s dst=%s bytes=%d packets=1 seq=%d failed=0 dropped=0"
          % (SPI_OUT, RWAN, PEER, out_len, FIRST + seq["engine"] - 1),
          "sa spi=0x%08x dir=in reqid=7 src=%s dst=%s bytes=%d packets=1 failed=0 dropped=0"
          % (SPI_IN, PEER, RWAN, back_len),
          "sa spi=0x%08x dir=in reqid=8 src=%s dst=%s bytes=0 packets=0 failed=0 dropped=0"
          % (SPI_OTHER, PEER, RWAN), "ok 3")
    s.ctl("list", "conn tcp 192.168.5.10 40010 10.20.0.10 5201 10.20.0.10 5201 192.168.5.10 40010"
          " orig_in=eth1 orig_out=eth0 orig_pkts=1 orig_bytes=%d orig_idle=*"
          " reply_in=eth0 reply_out=eth1 reply_pkts=1 reply_bytes=%d reply_idle=*"
          % (14 + out_len, back_len), "ok 1")
    # the same tuple out of another tunnel: its ESP up as it came
    f = peer_esp(t_back(PSH | ACK, back), 1, SPI_OTHER)
    s.send("eth0-wire", [f], eth0_kernel=[f])
    # what the kernel must see: a FIN, and a packet of no connection
    back_kernel(FIN | ACK)
    seq["peer"] += 1
    f = peer_esp(tcp(FAR, 5202, HOST, 40010, PSH | ACK, back), seq["peer"])
    s.send("eth0-wire", [f], eth0_kernel=[f])
    # 1423 bytes of inner packet do not fit the tunnel's 1422: up in the clear
    big = lan_out(t_out(PSH | ACK, payload(1423 - 40, 6)))
    s.send("eth1-wire", [big], eth1_kernel=[big])
    # the tunnel's only outbound SA stops: the connection goes back to the kernel
    s.ctl("sa-stop 0x%08x %s" % (SPI_OUT, PEER),
          "sa spi=0x%08x dir=out reqid=7 src=%s dst=%s bytes=%d packets=1 seq=%d failed=0 dropped=0"
          % (SPI_OUT, RWAN, PEER, out_len, FIRST + seq["engine"] - 1),
          T_CONN, "ok")
    s.ctl("count", "ok 0")
    s.send("eth1-wire", [lan_out(t_out(PSH | ACK, data))],
           eth1_kernel=[lan_out(t_out(PSH | ACK, data))])
    s.reconnect()
    s.ctl("sa", "ok 0")


def sa_line(spi, out, seq=None, reqid=7, b=0, p=0, failed=0, dropped=0):
    """The line of an SA in the answer of sa, sa-stop, sa-del."""
    src, dst = (RWAN, PEER) if out else (PEER, RWAN)
    return ("sa spi=0x%08x dir=%s reqid=%d src=%s dst=%s bytes=%d packets=%d%s failed=%d dropped=%d"
            % (spi, "out" if out else "in", reqid, src, dst, b, p,
               " seq=%d" % seq if out else "", failed, dropped))


def sa_add(spi, out, first=FIRST, reqid=7):
    return ("sa-add %s 0x%08x %s %s 4500 4500 %d cbc %s sha256 %s %d %d"
            % ("out" if out else "in", spi, RWAN if out else PEER, PEER if out else RWAN, reqid,
               KEY.hex(), AUTH.hex(), 0 if out else 32, first if out else 0))


SPI_OUT2, SPI_IN2 = 0xc0010011, 0xc0010012   # the SAs of the rekey
FIRST2 = (5 << 24) + 1


def ipsec_rekey(s):
    """Q9: a rekey of the tunnel while its connection is accelerated. The new
    SAs go through the kernel until they are handed over; then the
    connection goes out on the new outbound SA and comes in on the new
    inbound one, still bound; the old SAs deleted let go of nothing. The
    tunnel losing its last outbound SA tells the connection it lets go of."""
    s.ctl("claim", "ok")
    s.ctl(SA_OUT, "ok")
    s.ctl(SA_IN, "ok")
    lan_out = lambda l3: eth(RLAN_MAC, HOST_MAC, l3)
    lan_back = lambda l3: eth(HOST_MAC, RLAN_MAC, l3, pad=False)
    # the handshake through the kernel, as in ipsec-accel
    s.send("eth1-wire", [lan_out(t_out(SYN))], eth1_kernel=[lan_out(t_out(SYN))])
    s.send("eth0-kernel", [to_peer(kernel_esp(t_out(SYN, ttl=63), 1))],
           eth0_wire=[to_peer(esp(t_out(SYN, ttl=63), FIRST, 0))])
    f = peer_esp(t_back(SYN | ACK), 1)
    s.send("eth0-wire", [f], eth0_kernel=[f])
    s.send("eth1-kernel", [lan_back(t_back(SYN | ACK, ttl=63))],
           eth1_wire=[lan_back(t_back(SYN | ACK, ttl=63))])
    s.send("eth1-wire", [lan_out(t_out(ACK))], eth1_kernel=[lan_out(t_out(ACK))])
    s.send("eth0-kernel", [to_peer(kernel_esp(t_out(ACK, ttl=63), 2))],
           eth0_wire=[to_peer(esp(t_out(ACK, ttl=63), FIRST + 1, 1))])
    s.ctl(T_BIND, "ok")
    data, back = payload(1000, 4), payload(1200, 5)
    out_pkt = lambda: lan_out(t_out(PSH | ACK, data))
    inner = t_out(PSH | ACK, data, ttl=63)
    reply = lambda seq, spi: peer_esp(t_back(PSH | ACK, back), seq, spi)
    to_pc1 = [lan_back(t_back(PSH | ACK, back, ttl=63))]
    s.send("eth1-wire", [out_pkt()], eth0_wire=[to_peer(esp(inner, FIRST + 2, 2))])
    # strongSwan made the new SAs: not handed over yet, the kernel numbers its ESP on the new
    # outbound one, and the peer's on the new inbound one goes up as it came
    k = to_peer(esp(t_out(ACK, ttl=63), 1, 0x5101, iv=b"\xb1" * 16, spi=SPI_OUT2))
    s.send("eth0-kernel", [k], eth0_wire=[k])
    f = reply(1, SPI_IN2)
    s.send("eth0-wire", [f], eth0_kernel=[f])
    # handed over: the connection goes out on the new outbound SA from its first number
    s.ctl(sa_add(SPI_OUT2, True, FIRST2), "ok")
    s.ctl(sa_add(SPI_IN2, False), "ok")
    s.ctl("count", "ok 1")
    s.send("eth1-wire", [out_pkt()], eth0_wire=[to_peer(esp(inner, FIRST2, 0, spi=SPI_OUT2))])
    s.send("eth0-wire", [reply(2, SPI_IN2)], eth1_wire=to_pc1)
    # the peer still sends on the old inbound one for a while
    s.send("eth0-wire", [reply(2, SPI_IN)], eth1_wire=to_pc1)
    # the old ones deleted: the connection stays
    blen = len(t_back(PSH | ACK, back))
    s.ctl("sa-del 0x%08x %s" % (SPI_OUT, PEER), sa_line(SPI_OUT, True, FIRST + 2, b=len(inner), p=1),
          "ok")
    s.ctl("sa-del 0x%08x %s" % (SPI_IN, RWAN), sa_line(SPI_IN, False, b=blen, p=1), "ok")
    s.ctl("count", "ok 1")
    s.send("eth1-wire", [out_pkt()], eth0_wire=[to_peer(esp(inner, FIRST2 + 1, 1, spi=SPI_OUT2))])
    s.send("eth0-wire", [reply(3, SPI_IN2)], eth1_wire=to_pc1)
    s.ctl("sa", sa_line(SPI_OUT2, True, FIRST2 + 1, b=2 * len(inner), p=2),
          sa_line(SPI_IN2, False, b=2 * blen, p=2), "ok 2")
    # the last outbound SA goes: the connection with it, told
    s.ctl("sa-del 0x%08x %s" % (SPI_OUT2, PEER),
          sa_line(SPI_OUT2, True, FIRST2 + 1, b=2 * len(inner), p=2), T_CONN, "ok")
    s.ctl("count", "ok 0")
    s.send("eth1-wire", [out_pkt()], eth1_kernel=[out_pkt()])


def ipsec_reroute(s):
    """Q14: what bmchwaccel-syncd asks when the way to the peer changes (a
    route to it, the MAC of its gateway, the cable of the WAN): the
    connections through the tunnel go through the kernel again, and what was
    learned of the tunnel's outer L2 header with them; the SAs stay, so the
    kernel's ESP is still numbered by the engine, and the connection is
    learned and bound again from it. A route that is neither the peer's nor
    the far network's leaves the connection alone."""
    s.ctl("claim", "ok")
    s.ctl(SA_OUT, "ok")
    s.ctl(SA_IN, "ok")
    lan_out = lambda l3: eth(RLAN_MAC, HOST_MAC, l3)
    lan_back = lambda l3: eth(HOST_MAC, RLAN_MAC, l3, pad=False)
    seq = {"kernel": 0, "engine": 0, "peer": 0, "accel": 0}
    data = payload(1000, 4)
    inner = t_out(PSH | ACK, data, ttl=63)

    def learned():
        """What the kernel sends of both directions, learned, and bound."""
        s.send("eth1-wire", [lan_out(t_out(ACK))], eth1_kernel=[lan_out(t_out(ACK))])
        seq["kernel"] += 1
        i = t_out(ACK, ttl=63)
        s.send("eth0-kernel", [to_peer(kernel_esp(i, seq["kernel"]))],
               eth0_wire=[to_peer(esp(i, FIRST + seq["engine"], seq["engine"]))])
        seq["engine"] += 1
        seq["peer"] += 1
        f = peer_esp(t_back(ACK), seq["peer"])
        s.send("eth0-wire", [f], eth0_kernel=[f])
        s.send("eth1-kernel", [lan_back(t_back(ACK, ttl=63))],
               eth1_wire=[lan_back(t_back(ACK, ttl=63))])
        s.ctl(T_BIND, "ok")

    def accelerated():
        s.send("eth1-wire", [lan_out(t_out(PSH | ACK, data))],
               eth0_wire=[to_peer(esp(inner, FIRST + seq["engine"], seq["engine"]))])
        seq["engine"] += 1
        seq["accel"] += 1

    def let_go(request):
        s.ctl(request, T_CONN, "ok 1")
        s.ctl("count", "ok 0")
        # the next packet goes through the kernel
        s.send("eth1-wire", [lan_out(t_out(PSH | ACK, data))],
               eth1_kernel=[lan_out(t_out(PSH | ACK, data))])

    learned()
    accelerated()
    # neither the peer's network nor the far one's
    s.ctl("flush-route 198.18.0.0/15", "ok 0")
    s.ctl("flush-route 203.0.113.4/30", "ok 0")
    accelerated()
    # the route to the peer
    let_go("flush-route 203.0.113.1/32")
    learned()
    accelerated()
    # a route to a network with the peer in it
    let_go("flush-route 203.0.113.0/24")
    learned()
    # the far network, as for any connection
    let_go("flush-route 10.20.0.0/24")
    learned()
    # the gateway towards the peer took another MAC
    let_go("flush-mac " + GW_MAC)
    learned()
    # the cable of the WAN
    let_go("flush-port eth0")
    learned()
    accelerated()
    s.ctl("sa", sa_line(SPI_OUT, True, FIRST + seq["engine"] - 1, b=seq["accel"] * len(inner),
                        p=seq["accel"]),
          sa_line(SPI_IN, False), "ok 2")


SEQ_MAX = (1 << 32) - (1 << 26)   # IPSEC_SEQ_MAX of the engine (Q12)


def ipsec_limit(s):
    """Q12: the engine numbers nothing past 2^32 - 2^26. An outbound SA handed
    over near it numbers the kernel's ESP up to it, then drops it and counts
    it, and says it used the last number; deleted, the kernel's ESP goes out
    as it is. An SA that would start past it is refused."""
    a = udp(HOST, 40000, "10.20.0.10", 5201, payload(100))
    s.ctl("claim", "ok")
    s.ctl(sa_add(SPI_OUT, True, SEQ_MAX - 1), "ok")
    s.ctl(sa_add(SPI_OUT2, True, SEQ_MAX + 1), "err unsupported")
    s.send("eth0-kernel", [to_peer(kernel_esp(a, n)) for n in (1, 2, 3)],
           eth0_wire=[to_peer(esp(a, SEQ_MAX - 1, 0)), to_peer(esp(a, SEQ_MAX, 1))])
    s.ctl("sa", sa_line(SPI_OUT, True, SEQ_MAX, dropped=1), "ok 1")
    s.ctl("sa-stop 0x%08x %s" % (SPI_OUT, PEER), sa_line(SPI_OUT, True, SEQ_MAX, dropped=1), "ok")
    s.ctl("sa-del 0x%08x %s" % (SPI_OUT, PEER), sa_line(SPI_OUT, True, SEQ_MAX, dropped=1), "ok")
    s.send("eth0-kernel", [to_peer(kernel_esp(a, 4))], eth0_wire=[to_peer(kernel_esp(a, 4))])


def ipsec_tunnels(s):
    """The most tunnels (Q16), 2 here (--tunnels 2): an SA of a third tunnel
    is refused, and its ESP goes on as the kernel numbered it; a tunnel whose
    SAs all went leaves room for another."""
    s.engine_args = "--tunnels 2"
    a = udp(HOST, 40000, "10.20.0.10", 5201, payload(100))
    s.ctl("claim", "ok")
    s.ctl(sa_add(SPI_OUT, True, reqid=1), "ok")
    s.ctl(sa_add(SPI_IN, False, reqid=1), "ok")
    s.ctl(sa_add(SPI_OUT2, True, reqid=2), "ok")
    s.ctl(sa_add(0xc0010021, True, reqid=3), "err full")
    k = to_peer(esp(a, 1, 0x5001, iv=b"\xa1" * 16, spi=0xc0010021))
    # (what goes on as it is leaves before what the SEC numbers)
    s.send("eth0-kernel", [to_peer(kernel_esp(a, 1)), k],
           eth0_wire=[k, to_peer(esp(a, FIRST, 0))])
    # tunnel 2 goes: room for tunnel 3
    s.ctl("sa-del 0x%08x %s" % (SPI_OUT2, PEER), sa_line(SPI_OUT2, True, FIRST - 1, reqid=2), "ok")
    s.ctl(sa_add(0xc0010021, True, reqid=3), "ok")
    s.send("eth0-kernel", [k], eth0_wire=[to_peer(esp(a, FIRST, 0, spi=0xc0010021))])


def tx_limit(s):
    """The limit of what a port sends (ticket 21): net_memif has no traffic
    manager, so eth0 sends without it, says so, and both ports go on."""
    s.engine_args = "--tx-limit eth0,980"
    s.engine_log = ["eth0 sends without its limit of 980 Mbps"]
    arp = eth("ff:ff:ff:ff:ff:ff", RWAN_MAC, bytes(28), 0x0806)
    s.send("eth0-kernel", [arp], eth0_wire=[arp])
    arp = eth("ff:ff:ff:ff:ff:ff", RLAN_MAC, bytes(28), 0x0806)
    s.send("eth1-kernel", [arp], eth1_wire=[arp])
    s.ctl("count", "ok 0")


SCENARIOS = {
    "masquerade": masquerade,
    "port-forward": port_forward,
    "kernel": kernel,
    "refused": refused,
    "ports": ports,
    "daemon": daemon,
    "reroute": reroute,
    "vlan-pppoe": vlan_pppoe,
    "pppoe-redial": pppoe_redial,
    "ipsec": ipsec,
    "ipsec-accel": ipsec_accel,
    "ipsec-rekey": ipsec_rekey,
    "ipsec-reroute": ipsec_reroute,
    "ipsec-limit": ipsec_limit,
    "ipsec-tunnels": ipsec_tunnels,
    "tx-limit": tx_limit,
}

if __name__ == "__main__":
    if sys.argv[1:] == ["--list"]:
        print("\n".join(SCENARIOS))
    elif len(sys.argv) == 3 and sys.argv[1] in SCENARIOS:
        sc = Scenario(sys.argv[2])
        SCENARIOS[sys.argv[1]](sc)
        sc.write()
    else:
        sys.exit("usage: scenario.py --list | NAME DIR")
