#!/usr/bin/env python3
"""A small framed-Ethernet switch for QEMU's socket netdev backend."""

import argparse
import asyncio
import json
import os
import socket
import struct
import time

# ARP watcher (ticket 22): a host that exists only inside the switch.
WATCH_MAC = bytes.fromhex("024841000099")
WATCH_IP = socket.inet_aton("192.168.50.250")


class Switch:
    def __init__(self, ports):
        self.ports = {name: {"writer": None, "up": True} for name in ports}
        self.learned = {}
        self.capture = None
        # One "<time> <ingress port> <source MAC>" line per captured frame: the
        # two Members share the Virtual MAC, so only the port tells them apart.
        self.port_log = None
        self.watch = None
        self.replay = None

    def write_pcap(self, frame, port):
        if self.capture is None:
            return
        now = time.time()
        self.capture.write(struct.pack("<IIII", int(now), int((now % 1) * 1_000_000), len(frame), len(frame)))
        self.capture.write(frame)
        self.capture.flush()
        self.port_log.write("%.6f %s %s\n" % (now, port, frame[6:12].hex(":")))
        self.port_log.flush()

    async def arp_watch(self, target_ip, interval_s):
        """Broadcast an ARP request for target_ip every interval_s: every
        Member whose fence is open answers, whatever the MAC tables say."""
        request = (b"\xff" * 6 + WATCH_MAC + b"\x08\x06" + b"\x00\x01\x08\x00\x06\x04\x00\x01" +
                   WATCH_MAC + WATCH_IP + b"\x00" * 6 + target_ip)
        while True:
            for peer in self.ports.values():
                if peer["up"] and peer["writer"]:
                    peer["writer"].write(struct.pack("!I", len(request)) + request)
            await asyncio.sleep(interval_s)

    async def replay_frames(self, frames, port, interval_s):
        """Send recorded frames again, in order and round and round, as if
        they entered on port (ticket 28: a replayed heartbeat)."""
        while True:
            for frame in frames:
                await self.forward(port, frame)
                await asyncio.sleep(interval_s)

    async def forward(self, name, frame):
        self.learned[frame[6:12]] = name
        self.write_pcap(frame, name)
        if frame[:6] == WATCH_MAC:
            return
        destination = self.learned.get(frame[:6])
        targets = [destination] if destination else list(self.ports)
        for target in targets:
            peer = self.ports.get(target)
            if target != name and peer and peer["up"] and peer["writer"]:
                peer["writer"].write(struct.pack("!I", len(frame)) + frame)
                await peer["writer"].drain()

    async def port(self, name, reader, writer):
        state = self.ports[name]
        if state["writer"] is not None:
            state["writer"].close()
        state["writer"] = writer
        try:
            while True:
                size = struct.unpack("!I", await reader.readexactly(4))[0]
                if size < 14 or size > 65536:
                    raise ValueError("invalid Ethernet frame size")
                frame = await reader.readexactly(size)
                if not state["up"]:
                    continue
                await self.forward(name, frame)
        except (asyncio.IncompleteReadError, ConnectionError, ValueError):
            pass
        finally:
            if state["writer"] is writer:
                state["writer"] = None
            writer.close()

    async def control(self, reader, writer):
        try:
            request = json.loads((await reader.readline()).decode())
            action = request["action"]
            if action == "link":
                self.ports[request["port"]]["up"] = bool(request["up"])
                reply = {"ok": True}
            elif action == "capture":
                if self.capture:
                    self.capture.close()
                    self.port_log.close()
                path = request["path"]
                self.capture = open(path, "wb")
                self.port_log = open(path + ".ports", "w")
                self.capture.write(struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
                reply = {"ok": True, "path": path}
            elif action == "arp_watch":
                if self.watch:
                    self.watch.cancel()
                    self.watch = None
                if request.get("ip"):
                    self.watch = asyncio.ensure_future(self.arp_watch(
                        socket.inet_aton(request["ip"]), int(request.get("interval_ms", 20)) / 1000))
                reply = {"ok": True}
            elif action == "replay":
                # {"path": pcap, "port": ingress, "udp_port": N}: replay that
                # port's UDP frames to N from an earlier capture; no path stops.
                if self.replay:
                    self.replay.cancel()
                    self.replay = None
                if request.get("path"):
                    frames = read_udp_frames(request["path"], request["path"] + ".ports",
                                             request["port"], int(request["udp_port"]))
                    if not frames:
                        raise ValueError("no matching frames to replay")
                    self.replay = asyncio.ensure_future(self.replay_frames(
                        frames, request["port"], int(request.get("interval_ms", 200)) / 1000))
                    reply = {"ok": True, "frames": len(frames)}
                else:
                    reply = {"ok": True}
            elif action == "status":
                reply = {"ok": True, "ports": {p: v["up"] for p, v in self.ports.items()}}
            else:
                raise ValueError("unknown action")
        except (KeyError, ValueError, json.JSONDecodeError) as error:
            reply = {"ok": False, "error": str(error)}
        writer.write((json.dumps(reply) + "\n").encode())
        await writer.drain()
        writer.close()


def read_udp_frames(pcap, port_log, port, udp_port):
    """IPv4 UDP frames to udp_port that entered on port, from a capture made
    by this switch (its port log has one line per frame)."""
    with open(port_log) as log:
        ports = [line.split()[1] for line in log]
    frames = []
    with open(pcap, "rb") as capture:
        capture.read(24)
        index = 0
        while True:
            header = capture.read(16)
            if len(header) < 16:
                break
            frame = capture.read(struct.unpack("<IIII", header)[2])
            ingress = ports[index] if index < len(ports) else None
            index += 1
            if ingress != port or len(frame) < 42 or frame[12:14] != b"\x08\x00" or frame[23] != 17:
                continue
            ihl = (frame[14] & 0x0F) * 4
            if struct.unpack("!H", frame[14 + ihl + 2:14 + ihl + 4])[0] == udp_port:
                frames.append(frame)
    return frames


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--control", required=True)
    parser.add_argument("--port", action="append", required=True, metavar="NAME:PORT")
    args = parser.parse_args()
    try:
        os.unlink(args.control)
    except FileNotFoundError:
        pass
    ports = dict(item.rsplit(":", 1) for item in args.port)
    switch = Switch(ports)
    servers = [await asyncio.start_server(lambda r, w, n=name: switch.port(n, r, w), "127.0.0.1", int(port))
               for name, port in ports.items()]
    servers.append(await asyncio.start_unix_server(switch.control, args.control))
    await asyncio.gather(*(server.serve_forever() for server in servers))


asyncio.run(main())
