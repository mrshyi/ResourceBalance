"""Failure recovery and non-destructive retention checks; stdlib only."""

import contextlib
from datetime import datetime, timezone, timedelta
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_release import load_program


class FakeManager:
    """Emulate only systemctl's observable states and generated quota files."""

    def __init__(self, roots, enabled="disabled", fail=None, rollback_fail=False):
        self.roots = roots
        self.enabled = enabled
        self.state = "inactive"
        self.fail = fail
        self.failed = False
        self.rollback_fail = rollback_fail
        self.calls = []

    def run(self, cmd, **kwargs):
        self.calls.append(cmd)
        action = cmd[1]
        service = cmd[2] if len(cmd) > 2 else ""
        if action == "show":
            if self.fail == "verify" and self.state == "active" and not self.failed:
                self.failed = True
                self.state = "failed"
            return subprocess.CompletedProcess(cmd, 0, stdout=self.state + "\n")
        if action == "is-enabled":
            return subprocess.CompletedProcess(cmd, 0 if self.enabled != "disabled" else 1,
                                               stdout=self.enabled + "\n")
        if action == "set-property":
            path = self.roots[0] / (service + ".service.d") / "50-CPUQuota.conf"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("[Service]\n" + cmd[-1] + "\n")
        if action == "enable":
            self.enabled = "enabled-runtime" if "--runtime" in cmd else "enabled"
        if action == "disable":
            self.enabled = "disabled"
        if action == "start":
            # A failed start may have spawned a process before reporting failure.
            self.state = "active"
        if self.fail == action and not self.failed:
            self.failed = True
            if kwargs.get("check"):
                raise subprocess.CalledProcessError(1, cmd)
            return subprocess.CompletedProcess(cmd, 1)
        if action == "stop":
            if self.rollback_fail:
                raise subprocess.CalledProcessError(1, cmd)
            self.state = "inactive"
        return subprocess.CompletedProcess(cmd, 0, stdout="")


class StartupRecoveryTests(unittest.TestCase):
    def test_default_retention_keeps_old_and_malformed_rows_byte_for_byte(self):
        collector = load_program("COLLECTOR")
        now = datetime.now(timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory) / "metrics.csv"
            original = ("timestamp,cpu_percent\n" + (now - timedelta(days=365)).isoformat()
                        + ",10\nmalformed,20\n").encode()
            data.write_bytes(original)
            with patch.object(collector, "DATA", str(data)):
                collector.prune_metrics(now)
            self.assertEqual(data.read_bytes(), original)

    def test_retention_requires_valid_explicit_opt_in(self):
        collector = load_program("COLLECTOR")
        parser = getattr(collector, "load_retention_days", None)
        self.assertTrue(callable(parser), "retention must be explicit configuration")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "collector.conf"
            for content, expected in (("SAMPLE_INTERVAL=60\n", 0),
                                      ("METRICS_RETENTION_DAYS=30\n", 30),
                                      ("METRICS_RETENTION_DAYS=0\n", 0),
                                      ("METRICS_RETENTION_DAYS=-1\n", 0),
                                      ("METRICS_RETENTION_DAYS=nan\n", 0),
                                      ("METRICS_RETENTION_DAYS=999999\n", 0),
                                      ("METRICS_RETENTION_DAYS=30\nMETRICS_RETENTION_DAYS=nan\n", 0),
                                      ("METRICS_RETENTION_DAYS=30\nMETRICS_RETENTION_DAYS=\n", 0)):
                with self.subTest(content=content):
                    path.write_text(content)
                    with patch.object(collector, "CONF", str(path)):
                        self.assertEqual(parser(), expected)

    def test_start_failure_restores_files_enabled_state_and_quota(self):
        for name, config in (("cpu_test", "CPUCONF"), ("memory_test", "MEMCONF")):
            stages = ("set-property", "enable", "disable", "start", "verify") if name == "cpu_test" else ("enable", "disable", "start", "verify")
            for stage in stages:
                for old_enabled in ("disabled", "enabled", "enabled-runtime"):
                    for old_exists in (False, True):
                        with self.subTest(name=name, stage=stage, enabled=old_enabled, exists=old_exists), tempfile.TemporaryDirectory() as directory:
                            root = Path(directory)
                            conf = root / "controller.conf"
                            if old_exists:
                                conf.write_bytes(b"OLD=original\n")
                                os.chmod(conf, 0o640)
                            roots = (root / "persistent", root / "runtime")
                            service = "resource-balancer-cpu" if name == "cpu_test" else "resource-balancer-memory"
                            quota = roots[0] / (service + ".service.d") / "50-CPUQuota.conf"
                            runtime = roots[1] / (service + ".service.d") / "50-CPUQuota.conf"
                            other = quota.parent / "80-Unrelated.conf"
                            for path, data in ((quota, b"[Service]\nCPUQuota=33%\n"),
                                               (runtime, b"[Service]\nCPUQuota=22%\n"),
                                               (other, b"[Service]\nCPUWeight=5\n")):
                                path.parent.mkdir(parents=True, exist_ok=True)
                                path.write_bytes(data)
                            manager = FakeManager(roots, old_enabled, stage)
                            cli = load_program("BIN")
                            args = ["--target", "25"] + (["--duration", "10m"] if stage == "disable" else [])
                            with contextlib.ExitStack() as stack:
                                stack.enter_context(patch.object(cli, config, str(conf)))
                                stack.enter_context(patch.object(cli, "SYSTEMD_CONTROL_DIRS", tuple(map(str, roots)), create=True))
                                stack.enter_context(patch.object(cli.os, "geteuid", return_value=0, create=True))
                                stack.enter_context(patch.object(cli, "active", return_value=False))
                                stack.enter_context(patch.object(cli.subprocess, "run", side_effect=manager.run))
                                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                                with self.assertRaises((subprocess.CalledProcessError, RuntimeError, SystemExit)):
                                    getattr(cli, name)(args)
                            self.assertEqual(conf.read_bytes() if conf.exists() else None,
                                             b"OLD=original\n" if old_exists else None)
                            self.assertEqual(manager.enabled, old_enabled)
                            self.assertEqual(manager.state, "inactive")
                            self.assertEqual(quota.read_bytes(), b"[Service]\nCPUQuota=33%\n")
                            self.assertEqual(runtime.read_bytes(), b"[Service]\nCPUQuota=22%\n")
                            self.assertEqual(other.read_bytes(), b"[Service]\nCPUWeight=5\n")
                            if old_exists and os.name == "posix":
                                self.assertEqual(conf.stat().st_mode & 0o777, 0o640)

    def test_collector_startup_keeps_existing_history_by_default(self):
        collector = load_program("COLLECTOR")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "metrics.csv"
            original = ("timestamp,cpu_percent,memory_percent,memory_used_kb,memory_total_kb,"
                        "managed_memory_kb,native_memory_percent\n"
                        "2000-01-01T00:00:00+00:00,10,25,250,1000,0,25\n"
                        "bad-timestamp,20,25,250,1000,0,25\n").encode()
            data.write_bytes(original)
            with patch.object(collector, "DATA", str(data)), \
                 patch.object(collector, "CONF", str(root / "missing.conf")), \
                 patch.object(collector, "running", False), \
                 patch.object(collector, "read_cpu", return_value=(0, 0)):
                collector.main()
            self.assertEqual(data.read_bytes(), original)

    def test_config_write_failure_restores_previous_state(self):
        cli = load_program("BIN")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            conf = root / "memory.conf"
            conf.write_bytes(b"OLD=keep\n")
            manager = FakeManager((root / "persistent", root / "runtime"), enabled="enabled-runtime")
            original_write = cli.atomic_write
            failed = False

            def write(path, data, mode=0o600):
                nonlocal failed
                if path == str(conf) and not failed:
                    failed = True
                    raise OSError("injected config write failure")
                return original_write(path, data, mode)

            with patch.object(cli, "MEMCONF", str(conf)), \
                 patch.object(cli.os, "geteuid", return_value=0, create=True), \
                 patch.object(cli, "active", return_value=False), \
                 patch.object(cli, "atomic_write", side_effect=write), \
                 patch.object(cli.subprocess, "run", side_effect=manager.run):
                with self.assertRaisesRegex(OSError, "injected"):
                    cli.memory_test(["--target", "25"])
            self.assertEqual(conf.read_bytes(), b"OLD=keep\n")
            self.assertEqual(manager.enabled, "enabled-runtime")
            self.assertEqual(manager.state, "inactive")

    def test_new_quota_file_removed_after_failed_first_start(self):
        cli = load_program("BIN")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            roots = (root / "persistent", root / "runtime")
            manager = FakeManager(roots, fail="start")
            with patch.object(cli, "CPUCONF", str(root / "cpu.conf")), \
                 patch.object(cli, "SYSTEMD_CONTROL_DIRS", tuple(map(str, roots)), create=True), \
                 patch.object(cli.os, "geteuid", return_value=0, create=True), \
                 patch.object(cli, "active", return_value=False), \
                 patch.object(cli.subprocess, "run", side_effect=manager.run):
                with self.assertRaises((subprocess.CalledProcessError, RuntimeError)):
                    cli.cpu_test(["--target", "25"])
            self.assertFalse(list(roots[0].rglob("*.conf")))
            self.assertFalse((root / "cpu.conf").exists())
            self.assertEqual(manager.enabled, "disabled")

    def test_failed_rollback_retains_backup_and_reports_location(self):
        cli = load_program("BIN")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            conf = root / "memory.conf"
            conf.write_bytes(b"OLD=keep\n")
            manager = FakeManager((root / "persistent", root / "runtime"), fail="start", rollback_fail=True)
            with patch.object(cli, "MEMCONF", str(conf)), \
                 patch.object(cli.os, "geteuid", return_value=0, create=True), \
                 patch.object(cli, "active", return_value=False), \
                 patch.object(cli.subprocess, "run", side_effect=manager.run):
                with self.assertRaisesRegex(RuntimeError, "backup"):
                    cli.memory_test(["--target", "25"])
            backups = list(root.glob("resource-balancer-start-*"))
            self.assertTrue(backups)
            self.assertTrue(any(p.read_bytes() == b"OLD=keep\n" for p in backups[0].iterdir() if p.is_file()))

    def test_startup_signals_roll_back_in_subprocess(self):
        if os.name != "posix":
            self.skipTest("requires POSIX startup signals")
        code = r'''
import contextlib, io, os, signal, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, sys.argv[2])
from test_release import load_program
from test_startup_recovery import FakeManager
root = Path(sys.argv[1])
conf = root / "controller.conf"
conf.write_bytes(b"OLD=original\n")
roots = (root / "persistent", root / "runtime")
manager = FakeManager(roots)
cli = load_program("BIN")
function, key = ("cpu_test", "CPUCONF") if sys.argv[4] == "cpu" else ("memory_test", "MEMCONF")
signum = getattr(signal, sys.argv[3])
handlers = {n: signal.getsignal(n) for n in cli.STARTUP_SIGNALS}
interrupted = False
def run(cmd, **kwargs):
    global interrupted
    result = manager.run(cmd, **kwargs)
    if cmd[1] == "enable" and not interrupted:
        interrupted = True
        os.kill(os.getpid(), signum)
    return result
with patch.object(cli, key, str(conf)), patch.object(cli, "SYSTEMD_CONTROL_DIRS", tuple(map(str, roots))), patch.object(cli, "active", return_value=False), patch.object(cli.os, "geteuid", return_value=0), patch.object(cli.subprocess, "run", side_effect=run):
    try:
        getattr(cli, function)(["--target", "25"])
    except cli.StartupInterrupted as error:
        assert conf.read_bytes() == b"OLD=original\n"
        assert manager.enabled == "disabled" and manager.state == "inactive"
        assert not list(roots[0].rglob("*.conf"))
        assert all(signal.getsignal(n) == h for n, h in handlers.items())
        print("RECOVERY_OK")
        raise SystemExit(128 + error.signum)
raise AssertionError("signal did not interrupt startup")
'''
        import signal
        for name in ("SIGINT", "SIGTERM", "SIGHUP"):
            for controller in ("cpu", "memory"):
                with self.subTest(signal=name, controller=controller), tempfile.TemporaryDirectory() as directory:
                    result = subprocess.run([sys.executable, "-c", code, directory,
                                             str(Path(__file__).parent), name, controller],
                                            capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 128 + getattr(signal, name), result.stderr)
                    self.assertIn("RECOVERY_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
