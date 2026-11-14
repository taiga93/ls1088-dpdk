#!/usr/bin/env python3
"""Run a shell command through OpenWrt's root serial console."""

import select
import re
import socket
import sys
import time


path, command = sys.argv[1:]
marker = "__HA_CLUSTER_DONE__"
marker_escaped = "".join(f"\\{ord(char):03o}" for char in marker)
root_password = "VirtualQemuRoot1!"
deadline = time.monotonic() + 30
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(path)
    client.setblocking(False)
    # React to the console prompt, rather than spending four seconds sending
    # login credentials even when this console already has a shell.
    client.sendall(b"\n")
    prompt = bytearray()
    while time.monotonic() < deadline:
        readable, _, _ = select.select([client], [], [], 0.1)
        if not readable:
            continue
        chunk = client.recv(4096)
        if not chunk:
            raise SystemExit("serial console disconnected")
        prompt.extend(chunk)
        if re.search(rb"(?:^|[\r\n])[^\r\n]*# ?$", prompt):
            break
        if prompt.rstrip().endswith(b"login:"):
            client.sendall(b"root\n")
            prompt.clear()
        elif prompt.rstrip().endswith(b"Password:"):
            client.sendall((root_password + "\n").encode())
            prompt.clear()
    else:
        raise SystemExit("serial login timed out")
    # The serial console echoes input, so construct the marker at runtime to
    # avoid mistaking that echo for the command-completion marker.
    client.sendall(("\n" + command + "; printf '\\n" + marker_escaped + " %s\\n' $?\n").encode())
    output = bytearray()
    completion = re.compile(marker.encode() + rb" ([0-9]+)\r?\n")
    while not completion.search(output) and time.monotonic() < deadline:
        readable, _, _ = select.select([client], [], [], 0.25)
        if readable:
            chunk = client.recv(4096)
            if not chunk:
                break
            output.extend(chunk)
text = output.decode(errors="replace")
if not completion.search(output):
    raise SystemExit("serial command timed out")
before, result = text.rsplit(marker, 1)
print(before, end="")
raise SystemExit(int(result.strip().split()[0]))
