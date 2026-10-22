"""Exercise tmux's terminal decoder through a private attached-client PTY.

Run: python3 tests/test_tmux_csi_u.py /absolute/path/to/tmux
Every tmux command uses a temporary socket and -f config; no existing server,
user configuration, or real terminal is accessed. Input never uses send-keys.
"""

import fcntl
import os
from pathlib import Path
import pty
import select
import shlex
import struct
import subprocess
import sys
import tempfile
import termios
import time
import tty


def capture(directory):
    """Pane application: request extended keys and record their actual bytes."""
    tty.setraw(0)
    os.write(1, b"\x1b[>4;2m")
    (directory / "ready").touch()
    with (directory / "input").open("ab", buffering=0) as output:
        while True:
            data = os.read(0, 4096)
            if not data:
                return
            output.write(data)


def check(binary):
    binary = str(Path(binary).resolve(strict=True))
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
    env["TERM"] = "alacritty"
    with tempfile.TemporaryDirectory(prefix="tmux-csi-u-") as temporary:
        directory = Path(temporary)
        config = directory / "tmux.conf"
        config.write_text(
            "set -g status off\n"
            "set -s escape-time 30\n"
            "set -s extended-keys on\n"
            "set -s extended-keys-format csi-u\n"
            "set -as terminal-overrides ',alacritty:Eneks=\\E[=1u:Dseks=\\E[=0u'\n"
        )
        command = [binary, "-S", str(directory / "socket"), "-f", str(config)]

        def tmux(*args, **kwargs):
            return subprocess.run(
                [*command, *args], env=env, check=True, timeout=5,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs,
            )

        master, slave = pty.openpty()
        client = None
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            pane = shlex.join([sys.executable, str(Path(__file__).resolve()),
                               "--capture", temporary])
            tmux("new-session", "-d", "-s", "decoder", pane)
            client = subprocess.Popen(
                [*command, "attach-session", "-t", "decoder"], env=env,
                stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
            )
            os.close(slave)
            slave = None
            terminal_output = b""
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    terminal_output += os.read(master, 65536)
                if ((directory / "ready").exists()
                        and b"\x1b[=1u" in terminal_output):
                    break
                if client.poll() is not None:
                    raise AssertionError(f"Client exited: {terminal_output!r}")
            else:
                raise AssertionError(f"Pane/Kitty flag-1 negotiation not ready: {terminal_output!r}")
            # Allow the pane's application-facing request to reach the server.
            time.sleep(0.1)
            failures = []
            cases = [
                ("raw Escape", b"\x1b", b"\x1b"),
                ("CSI 27u", b"\x1b[27u", b"\x1b"),
                ("CSI 27;1u", b"\x1b[27;1u", b"\x1b"),
                ("Shift+Enter", b"\x1b[13;2u", b"\x1b[13;2u"),
                ("ordinary Enter", b"\r", b"\r"),
                ("CSI 13u", b"\x1b[13u", b"\r"),
                ("Ctrl+Enter", b"\x1b[13;5u", b"\x1b[13;5u"),
                ("modifyOtherKeys Shift+Enter", b"\x1b[27;2;13~", b"\x1b[13;2u"),
                ("bare printable key", b"\x1b[97u", b"a"),
            ]
            # Rejected sequences fall back to Alt-[ followed by literal bytes.
            # Explicit forms with extra numeric fields were already tolerated
            # upstream; this narrow patch intentionally leaves those unchanged.
            malformed = [b"u", b";u", b"27;u", b"27;;1u", b";1u",
                         b"-27u", b"+27u", b"27:1u", b"27xu",
                         b"4294967323u", b"18446744073709551616u"]
            cases += [(f"reject {suffix!r}", b"\x1b[" + suffix,
                       b"\x1b[91;3u" + suffix) for suffix in malformed]
            recorded = directory / "input"
            offset = 0
            for name, payload, expected in cases:
                os.write(master, payload)
                # Wait for pane input, then for it to settle beyond escape-time.
                # A deadline permits slow builders without fixed per-key sleeps.
                deadline = time.monotonic() + 5
                actual, changed = b"", None
                while time.monotonic() < deadline:
                    data = recorded.read_bytes()[offset:]
                    if data != actual:
                        actual, changed = data, time.monotonic()
                    if changed is not None and time.monotonic() - changed > 0.1:
                        break
                    time.sleep(0.01)
                offset += len(actual)
                if actual == expected:
                    print(f"PASS {name}: {actual.hex()}")
                else:
                    failures.append(name)
                    print(f"FAIL {name}: expected={expected.hex()} actual={actual.hex()}")
            if failures:
                raise AssertionError(f"{len(failures)} failures: {', '.join(failures)}")
            print(f"PASS {len(cases)} decoder cases; Kitty flag-1 negotiation observed")
        finally:
            # Only this test's explicitly named private server is terminated.
            subprocess.run([*command, "kill-server"], env=env, timeout=5,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if client is not None:
                try:
                    client.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait(timeout=5)
            os.close(master)
            if slave is not None:
                os.close(slave)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--capture":
        capture(Path(sys.argv[2]))
    elif len(sys.argv) == 2:
        check(sys.argv[1])
    else:
        sys.exit(__doc__)
