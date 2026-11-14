#!/usr/bin/env python3
"""A small FTP server for the ftp item of scripts/ls1088/acceptance.sh, run
on PC2 (bench.md): the FTP helper of the firewall follows the commands of the
control connection, and the item downloads through the board in passive and
in active mode. Standard library only.

    sudo python3 scripts/ls1088/ftp-server.py [--port 21] [--mb 64]

Any user and password are accepted. The one file, /hwaccel-ftp.bin, holds
--mb megabytes of zeros. Commands: USER PASS SYST FEAT PWD CWD TYPE MODE STRU
SIZE PASV EPSV PORT EPRT RETR NOOP QUIT.
"""
import argparse
import socket
import socketserver
import threading

FILE = "hwaccel-ftp.bin"


class Session(socketserver.StreamRequestHandler):
    def reply(self, line):
        self.wfile.write((line + "\r\n").encode())

    def data_socket(self):
        """The data connection of the last PASV/EPSV or PORT/EPRT."""
        if self.passive is not None:
            self.passive.settimeout(30)
            conn, _ = self.passive.accept()
            self.passive.close()
            self.passive = None
            return conn
        if self.active is not None:
            conn = socket.create_connection(self.active, timeout=30)
            self.active = None
            return conn
        return None

    def handle(self):
        self.passive = None
        self.active = None
        size = self.server.size
        self.reply("220 hwaccel ftp")
        for raw in self.rfile:
            line = raw.decode(errors="replace").strip()
            cmd, _, arg = line.partition(" ")
            cmd = cmd.upper()
            if cmd == "USER":
                self.reply("331 any password")
            elif cmd == "PASS":
                self.reply("230 logged in")
            elif cmd == "SYST":
                self.reply("215 UNIX Type: L8")
            elif cmd == "FEAT":
                self.reply("211-Features:")
                self.reply(" EPSV")
                self.reply(" EPRT")
                self.reply(" SIZE")
                self.reply("211 end")
            elif cmd == "PWD":
                self.reply('257 "/"')
            elif cmd in ("CWD", "TYPE", "MODE", "STRU", "NOOP"):
                self.reply("200 ok")
            elif cmd == "SIZE":
                if arg.lstrip("/") == FILE:
                    self.reply("213 %d" % size)
                else:
                    self.reply("550 no such file")
            elif cmd in ("PASV", "EPSV"):
                s = socket.socket()
                s.bind((self.connection.getsockname()[0], 0))
                s.listen(1)
                self.passive = s
                port = s.getsockname()[1]
                if cmd == "EPSV":
                    self.reply("229 Entering Extended Passive Mode (|||%d|)" % port)
                else:
                    a = s.getsockname()[0].replace(".", ",")
                    self.reply("227 Entering Passive Mode (%s,%d,%d)" % (a, port >> 8, port & 255))
            elif cmd == "PORT":
                n = [int(x) for x in arg.split(",")]
                self.active = (".".join(map(str, n[:4])), n[4] * 256 + n[5])
                self.reply("200 PORT ok")
            elif cmd == "EPRT":
                f = arg.split(arg[0])
                self.active = (f[2], int(f[3]))
                self.reply("200 EPRT ok")
            elif cmd == "RETR":
                if arg.lstrip("/") != FILE:
                    self.reply("550 no such file")
                    continue
                self.reply("150 sending %d bytes" % size)
                conn = self.data_socket()
                if conn is None:
                    self.reply("425 no data connection")
                    continue
                chunk = bytes(65536)
                left = size
                try:
                    while left > 0:
                        n = min(left, len(chunk))
                        conn.sendall(chunk[:n])
                        left -= n
                    conn.close()
                    self.reply("226 done")
                except OSError as e:
                    self.reply("426 %s" % e)
            elif cmd == "QUIT":
                self.reply("221 bye")
                return
            else:
                self.reply("502 not implemented")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--port", type=int, default=21)
    p.add_argument("--mb", type=int, default=64)
    a = p.parse_args()
    srv = Server(("0.0.0.0", a.port), Session)
    srv.size = a.mb << 20
    print("serving /%s (%d MB) on port %d" % (FILE, a.mb, a.port), flush=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
