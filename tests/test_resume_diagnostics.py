"""Rootless control-flow tests with fake procfs/sysfs/tracefs; no real device access.

Run inside nix-shell -p python3 coreutils findutils gnugrep gawk util-linux bash.
These tests do not validate the real kernel tracing ABI or suspend sequencing.
"""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "modules/resume-diagnostics.sh"


class ResumeDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        code = SOURCE.read_text()
        self.assertEqual(code.count("if (( EUID != 0 )); then"), 1)
        code = code.replace("if (( EUID != 0 )); then", "if false; then")
        # Ownership is deployment policy, not part of the mocked test filesystem.
        code = code.replace(" -g wheel", "")
        for prefix in ("/proc/", "/sys/", "/run/", "/var/lib/"):
            code = code.replace(prefix, str(self.root) + prefix)
        self.script = self.root / "diagnostics.sh"
        self.script.write_text(code)
        self.env = dict(os.environ)
        bindir = self.root / "bin"
        bindir.mkdir()
        for cmd in ("journalctl", "systemctl", "loginctl"):
            mock = bindir / cmd
            mock.write_text("#!/bin/sh\nprintf 'mock service state\\n'\n")
            mock.chmod(0o755)
        self.env["PATH"] = str(bindir) + ":" + self.env["PATH"]
        self.state = self.root / "var/lib/resume-diagnostics"
        self.trace_root = self.root / "sys/kernel/tracing"
        self.instance = self.trace_root / "instances/resume-diagnostics"
        self.put("proc/interrupts", " 207: 12 0 amd_gpio 8 PIXA3854:00\n 7: 20 0 pinctrl_amd\n")

    def put(self, path, text=""):
        path = self.root / path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def tracefs(self):
        self.put("sys/kernel/tracing/available_filter_functions", "\n".join([
            "i2c_hid_core_resume [i2c_hid_core]",
            "i2c_hid_set_power.llvm.123 [i2c_hid_core]",
            "amd_gpio_irq_enable",
            "i2c_hid_get_input [i2c_hid_core]",  # must NOT be traced
            "unrelated_function",
        ]))
        for file, value in {
            "available_tracers": "nop function function_graph\n",
            "events/enable": "0\n",
            "events/power/device_pm_callback_start/enable": "0\n",
            "events/power/device_pm_callback_end/enable": "0\n",
            "events/power/suspend_resume/enable": "0\n",
            "events/irq/irq_handler_entry/enable": "0\n",
            "events/irq/irq_handler_entry/filter": "0\n",
            "events/irq/irq_handler_exit/enable": "0\n",
            "events/irq/irq_handler_exit/filter": "0\n",
            "options/funcgraph-retval": "0\n",
            "options/funcgraph-args": "1\n",
            "per_cpu/cpu0/stats": "overrun: 0\n",
        }.items():
            self.put("sys/kernel/tracing/instances/resume-diagnostics/" + file, value)

    def run_tool(self, *args, success=True):
        result = subprocess.run(
            ["bash", str(self.script), *args], env=self.env,
            text=True, capture_output=True, timeout=15,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_sleep_cycle_and_manual_capture(self):
        self.tracefs()
        report = Path(self.run_tool("prepare").stdout.strip())
        selected = (self.instance / "set_ftrace_filter").read_text()
        self.assertIn("i2c_hid_core_resume", selected)
        self.assertIn("i2c_hid_set_power.llvm.123", selected)
        self.assertNotIn("i2c_hid_get_input", selected)
        self.assertNotIn("unrelated_function", selected)
        self.assertEqual((self.instance / "options/funcgraph-args").read_text().strip(), "0")
        self.assertIn("irq == 207", (self.instance / "events/irq/irq_handler_entry/filter").read_text())
        self.assertEqual((self.instance / "tracing_on").read_text().strip(), "1")
        self.assertTrue((report / "pre/hardware.txt").exists())
        (self.instance / "trace").write_text("test PM callback result=0\n")
        self.run_tool("resume")
        self.assertEqual((self.instance / "tracing_on").read_text().strip(), "0")
        self.assertIn("callback result=0", (report / "trace.txt").read_text())
        self.assertTrue((report / "post/hardware.txt").exists())
        self.run_tool("settled")
        self.assertTrue((report / "settled/session-state.txt").exists())
        broken = Path(self.run_tool("capture", "broken").stdout.strip())
        self.assertEqual((broken / "reason").read_text().strip(), "broken")
        self.assertEqual((broken / "previous-sleep-report.txt").read_text().strip(), str(report))
        self.assertIn("unavailable on this kernel", (broken / "manual/hardware.txt").read_text())

    def test_no_tracefs_still_captures(self):
        report = Path(self.run_tool("prepare").stdout.strip())
        self.assertTrue((report / "tracing-unavailable.txt").exists())
        self.run_tool("resume")
        self.assertTrue((report / "post/kernel.log").exists())

    def test_setup_error_still_captures_and_stops_tracing(self):
        self.tracefs()
        (self.trace_root / "available_filter_functions").unlink()
        report = Path(self.run_tool("prepare").stdout.strip())
        self.assertTrue((report / "pre/hardware.txt").exists())
        self.assertNotEqual((report / "trace-setup.log").read_text(), "")
        self.assertEqual((self.instance / "tracing_on").read_text().strip(), "0")

    def test_no_functions_never_enables_unfiltered_tracing(self):
        self.tracefs()
        (self.trace_root / "available_filter_functions").write_text("unrelated_function\n")
        report = Path(self.run_tool("prepare").stdout.strip())
        self.assertEqual((self.instance / "current_tracer").read_text().strip(), "nop")
        self.assertTrue((report / "functions-unavailable.txt").exists())

    def test_retention_and_invalid_label(self):
        for _ in range(18):
            self.run_tool("capture", "test")
        self.assertEqual(len(list(self.state.glob("capture-*"))), 16)
        self.run_tool("capture", "../bad", success=False)
        self.assertEqual(len(list(self.state.glob("capture-*"))), 16)
        self.run_tool("settled")  # no prior sleep: harmless


if __name__ == "__main__":
    unittest.main()
