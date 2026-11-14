#!/usr/bin/env python3
"""Compares the packets of two pcap files: pcapcmp.py EXPECTED GOT

Says nothing and exits 0 when both hold the same frames in the same order;
otherwise prints the first difference, with both frames decoded, and exits 1.
"""
import struct
import sys


def frames(path):
    with open(path, "rb") as f:
        data = f.read()
    out, off = [], 24
    while off < len(data):
        n = struct.unpack_from("<I", data, off + 8)[0]
        out.append(data[off + 16:off + 16 + n])
        off += 16 + n
    return out


def show(p):
    if p is None:
        return "nothing"
    s = "%d bytes %s > %s type %04x" % (len(p), p[6:12].hex(":"), p[0:6].hex(":"),
                                        struct.unpack_from("!H", p, 12)[0])
    l2 = 14
    if p[12:14] == b"\x81\x00":
        s += " vlan %d" % (struct.unpack_from("!H", p, 14)[0] & 0xfff)
        l2 = 18
    ipv4 = p[l2 - 2:l2] == b"\x08\x00"
    if p[l2 - 2:l2] == b"\x88\x64":
        s += " pppoe session %04x length %d" % struct.unpack_from("!HH", p, l2 + 2)
        ipv4 = p[l2 + 6:l2 + 8] == b"\x00\x21"
        l2 += 8
    if ipv4:
        ip = p[l2:]
        ihl = (ip[0] & 15) * 4
        s += " %s > %s ttl %d proto %d ipsum %04x" % (
            ".".join(map(str, ip[12:16])), ".".join(map(str, ip[16:20])), ip[8], ip[9],
            struct.unpack_from("!H", ip, 10)[0])
        if ip[9] in (6, 17):
            sp, dp = struct.unpack_from("!HH", ip, ihl)
            ck = struct.unpack_from("!H", ip, ihl + (16 if ip[9] == 6 else 6))[0]
            s += " ports %d > %d l4sum %04x" % (sp, dp, ck)
    return s


def main(want_path, got_path):
    want, got = frames(want_path), frames(got_path)
    for i in range(max(len(want), len(got))):
        w = want[i] if i < len(want) else None
        g = got[i] if i < len(got) else None
        if w != g:
            print("%s: frame %d differs" % (got_path, i + 1))
            if w and g:
                at = next((k for k in range(min(len(w), len(g))) if w[k] != g[k]),
                          min(len(w), len(g)))
                print("  first at byte %d" % at)
            print("  expected: " + show(w))
            print("  got:      " + show(g))
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
