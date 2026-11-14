#!/usr/bin/env python3
"""Send one QMP command to a Unix-domain QEMU monitor."""

import json
import socket
import sys


path, command, *arguments = sys.argv[1:]
request = {"execute": command}
if arguments:
    request["arguments"] = json.loads(arguments[0])
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(path)
    client.recv(4096)
    client.sendall(b'{"execute":"qmp_capabilities"}\r\n')
    client.recv(4096)
    client.sendall((json.dumps(request) + "\r\n").encode())
    response = json.loads(client.recv(4096).decode())
if "error" in response:
    raise SystemExit(response["error"])
print(json.dumps(response.get("return", {})))
