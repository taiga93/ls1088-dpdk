"""Regression tests for the serial transport used by the failover timer."""

import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


class SerialExecTests(unittest.TestCase):
    def run_console(self, fresh, status):
        with tempfile.TemporaryDirectory() as directory:
            path = str(pathlib.Path(directory) / "console.sock")
            received = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path)
                server.listen(1)

                def serve():
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(3)
                        stream = connection.makefile("rb")
                        received.append(stream.readline())
                        if fresh:
                            connection.sendall(b"bmc login: ")
                            received.append(stream.readline())
                            connection.sendall(b"Password: ")
                            received.append(stream.readline())
                        connection.sendall(b"\r\nroot@bmc:~# ")
                        command = stream.readline()
                        while not command.strip():
                            command = stream.readline()
                        received.append(command)
                        # Echoing the command must not satisfy completion.
                        connection.sendall(command + b"\r\nprobe-output\r\n__HA_CLUSTER_DONE__ ")
                        time.sleep(0.15)
                        connection.sendall(str(status).encode() + b"\r\n")

                thread = threading.Thread(target=serve)
                thread.start()
                started = time.monotonic()
                result = subprocess.run(
                    [sys.executable, str(pathlib.Path(__file__).with_name("serial_exec.py")), path, "echo probe-output"],
                    capture_output=True, text=True, timeout=3,
                )
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
                self.assertLess(time.monotonic() - started, 3)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn("probe-output", result.stdout)
                if fresh:
                    self.assertEqual(received[1], b"root\n")
                    self.assertNotIn(received[2].decode().strip(), result.stdout)
                else:
                    self.assertEqual(len(received), 2)

    def test_existing_shell_has_no_login_delay(self):
        self.run_console(False, 0)

    def test_fresh_login_and_fragmented_failure_status(self):
        self.run_console(True, 7)


if __name__ == "__main__":
    unittest.main()
