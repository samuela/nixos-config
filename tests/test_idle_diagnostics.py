"""Exercise the read-only client against a tiny fake Wayland compositor."""
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import unittest

BINARY = sys.argv.pop(1)
SCREEN_OFF = sys.argv.pop(1)


def words(*values):
    return struct.pack("=" + "I" * len(values), *values)


def string(value):
    value = value.encode() + b"\0"
    return words(len(value)) + value + b"\0" * (-len(value) % 4)


class IdleDiagnosticsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(Path(self.directory.name) / "wayland-test"))
        self.server.listen(1)
        self.server.settimeout(5)
        self.process = subprocess.Popen(
            [BINARY],
            env={**os.environ, "XDG_RUNTIME_DIR": self.directory.name,
                 "WAYLAND_DISPLAY": "wayland-test"},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.connection, _ = self.server.accept()
        self.connection.settimeout(5)
        self.output = b""

    def tearDown(self):
        self.connection.close()
        self.server.close()
        if self.process.poll() is None:
            self.process.terminate()
        self.process.communicate(timeout=5)
        self.directory.cleanup()

    def receive_exactly(self, size):
        result = b""
        while len(result) < size:
            chunk = self.connection.recv(size - len(result))
            self.assertTrue(chunk, "client disconnected unexpectedly")
            result += chunk
        return result

    def request(self):
        obj, header = struct.unpack("=II", self.receive_exactly(8))
        return obj, header & 0xFFFF, self.receive_exactly((header >> 16) - 8)

    def send(self, obj, opcode, payload=b""):
        self.connection.sendall(words(obj, ((len(payload) + 8) << 16) | opcode) + payload)

    def advertise(self, version=2):
        obj, opcode, payload = self.request()
        self.assertEqual((obj, opcode), (1, 1))  # wl_display.get_registry
        registry, = struct.unpack("=I", payload)
        obj, opcode, payload = self.request()
        self.assertEqual((obj, opcode), (1, 0))  # wl_display.sync
        callback, = struct.unpack("=I", payload)
        self.send(registry, 0, words(1) + string("wl_seat") + words(9))
        self.send(registry, 0, words(2) + string("ext_idle_notifier_v1") + words(version))
        self.send(callback, 0, words(0))
        self.send(1, 1, words(callback))  # wl_display.delete_id
        return registry

    def start_notifications(self):
        registry = self.advertise()
        bindings = {}
        for _ in range(2):
            obj, opcode, payload = self.request()
            self.assertEqual((obj, opcode), (registry, 0))
            name, length = struct.unpack_from("=II", payload)
            interface = payload[8:8 + length - 1].decode()
            version, new_id = struct.unpack_from("=II", payload, 8 + ((length + 3) & ~3))
            bindings[interface] = new_id
            self.assertEqual(version, 1 if name == 1 else 2)
        notifications = {}
        for opcode in (1, 2):
            obj, actual_opcode, payload = self.request()
            self.assertEqual((obj, actual_opcode), (bindings["ext_idle_notifier_v1"], opcode))
            new_id, timeout, seat = struct.unpack("=III", payload)
            self.assertEqual(timeout, 30000)
            self.assertEqual(seat, bindings["wl_seat"])
            notifications[opcode] = new_id
        return notifications

    def expect_output(self, text):
        while text.encode() not in self.output:
            readable, _, _ = select.select([self.process.stdout], [], [], 5)
            self.assertTrue(readable, f"missing {text!r}; output={self.output!r}")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            self.assertTrue(chunk, f"client exited; output={self.output!r}")
            self.output += chunk

    def test_idle_inhibited_and_resumed(self):
        notifications = self.start_notifications()
        self.expect_output("read-only")
        # The user is idle, but the normal notifier remains active: inhibited.
        self.send(notifications[2], 0)
        self.expect_output("input-only idled")
        self.assertNotIn(b"inhibitor-aware idled", self.output)
        self.send(notifications[1], 0)
        self.expect_output("inhibitor-aware idled")
        self.send(notifications[1], 1)
        self.expect_output("inhibitor-aware resumed")
        self.send(notifications[2], 1)
        self.expect_output("input-only resumed")
        self.expect_output("heartbeat")
        self.expect_output("dpms")
        # No commands, input devices, surfaces, or inhibitor requests were sent.
        self.connection.settimeout(0.1)
        with self.assertRaises(socket.timeout):
            self.connection.recv(1)

    def test_requires_input_only_protocol(self):
        self.advertise(version=1)
        self.expect_output("requires a seat and ext_idle_notifier_v1 version 2")
        self.assertEqual(self.process.wait(timeout=5), 1)

    def test_disconnect_exits_for_systemd_restart(self):
        self.start_notifications()
        self.connection.close()
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.expect_output("Wayland connection failed")


class ScreenOffTest(unittest.TestCase):
    def run_command(self, reply):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "niri-test")
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(path)
                server.listen(1)
                server.settimeout(5)
                process = subprocess.Popen(
                    [SCREEN_OFF], env={**os.environ, "NIRI_SOCKET": path},
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                try:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(5)
                        request = b""
                        while not request.endswith(b"\n"):
                            chunk = connection.recv(4096)
                            self.assertTrue(chunk)
                            request += chunk
                        self.assertEqual(json.loads(request), {"Action": {"PowerOffMonitors": {}}})
                        connection.sendall(json.dumps(reply).encode() + b"\n")
                    # On error the CLI reconnects to query the compositor version.
                    # Refuse that optional diagnostic connection rather than hang.
                    server.close()
                    output, _ = process.communicate(timeout=5)
                    self.assertIn(b"timeout fired", output)
                    return process.returncode, output
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=5)

    def test_success(self):
        status, output = self.run_command({"Ok": "Handled"})
        self.assertEqual(status, 0)
        self.assertIn(b"exit_status=0", output)

    def test_ipc_error_is_logged_and_preserved(self):
        status, output = self.run_command({"Err": "test failure"})
        self.assertNotEqual(status, 0)
        self.assertIn(f"exit_status={status}".encode(), output)
        self.assertIn(b"test failure", output)

    def test_connection_error_is_logged_and_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.run(
                [SCREEN_OFF], env={**os.environ, "NIRI_SOCKET": directory + "/missing"},
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5,
            )
        self.assertNotEqual(process.returncode, 0)
        self.assertIn(f"exit_status={process.returncode}".encode(), process.stdout)


if __name__ == "__main__":
    unittest.main()
