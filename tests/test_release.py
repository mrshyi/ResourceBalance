"""Regression checks for the standalone installer; Python stdlib only.

Extract embedded programs without installing services or generating load.
Run: python -m unittest discover -s tests -v
"""

import contextlib
import csv
from datetime import datetime, timezone, timedelta
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "install-resource-balancer.sh").read_text(encoding="utf-8")
BLOCKS = dict(re.findall(
    r'^cat > "(?:\$\{STAGING\})?\$\{?(COLLECTOR|MEMTEST|CPUTEST|BIN)\}?" <<\'PY\'\n(.*?)^PY$',
    SOURCE, re.MULTILINE | re.DOTALL,
))


def load_program(name):
    module = types.ModuleType("rb_" + name.lower())
    with patch("signal.signal"):
        exec(compile(BLOCKS[name], name, "exec"), module.__dict__)
    return module


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.cli = load_program("BIN")
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.cli.SYSTEMD_CONTROL_DIRS = (str(Path(temporary.name) / "persistent"),
                                        str(Path(temporary.name) / "runtime"))

    def test_all_embedded_programs_compile(self):
        self.assertEqual(set(BLOCKS), {"COLLECTOR", "MEMTEST", "CPUTEST", "BIN"})
        for name, source in BLOCKS.items():
            compile(source, name, "exec")

    def test_install_preflight_rejects_untrusted_paths(self):
        start = SOURCE.index("import os\nfrom pathlib import Path")
        code = SOURCE[start:SOURCE.index("\nPY", start)]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lib, data, target = root / "lib", root / "data", root / "cli"
            lib.mkdir()
            data.mkdir()
            target.write_text("test")
            original_lstat = Path.lstat
            for mode, owner, valid in ((stat.S_IFREG | 0o600, 0, True),
                                       (stat.S_IFREG | 0o666, 0, False),
                                       (stat.S_IFREG | 0o600, 1000, False),
                                       (stat.S_IFLNK | 0o777, 0, False)):
                def lstat(path, **kwargs):
                    if path == target:
                        return types.SimpleNamespace(st_mode=mode, st_uid=owner)
                    info = original_lstat(path, **kwargs)
                    return types.SimpleNamespace(st_mode=info.st_mode & ~0o022, st_uid=0)

                with self.subTest(mode=mode, owner=owner), \
                     patch("sys.argv", ["preflight", str(lib), str(data), str(target)]), \
                     patch.object(Path, "lstat", lstat):
                    if valid:
                        exec(compile(code, "preflight", "exec"), {})
                    else:
                        with self.assertRaises(SystemExit):
                            exec(compile(code, "preflight", "exec"), {})

    def test_history_filters_corrupt_and_nonfinite_samples(self):
        for name, field in (("MEMTEST", "memory"), ("CPUTEST", "cpu")):
            worker = load_program(name)
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "history.jsonl"
                rows = [{"ts": 100, field: 25}, {"ts": 101, field: float("nan")},
                        {"ts": float("inf"), field: 25}, {"ts": 999, field: 25},
                        {"ts": 100, field: -1}]
                path.write_text("broken json\n" + "\n".join(json.dumps(row) for row in rows))
                with patch.object(worker, "HISTORY", str(path)):
                    self.assertEqual(worker.load_history(200), [(100.0, 25.0)])

    def test_systemd_units_verify(self):
        verifier = shutil.which("systemd-analyze")
        if not verifier:
            self.skipTest("systemd-analyze unavailable")
        units = re.findall(r'^cat > "\$\{STAGING\}\$\{(\w+_UNIT)\}" <<EOF\n(.*?)^EOF$',
                           SOURCE, re.MULTILINE | re.DOTALL)
        self.assertEqual(len(units), 3)
        replacements = {
            "COLLECTOR": "/usr/local/lib/resource-balancer/collector.py",
            "MEMTEST": "/usr/local/lib/resource-balancer/memory.py",
            "CPUTEST": "/usr/local/lib/resource-balancer/cpu.py",
            "MEMCONF": "/etc/resource-balancer-memory.conf",
            "CPUCONF": "/etc/resource-balancer-cpu.conf",
            "DATADIR": "/var/lib/resource-balancer",
        }
        names = {"COLLECTOR_UNIT": "collector", "MEMTEST_UNIT": "memory", "CPUTEST_UNIT": "cpu"}
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for name, content in units:
                for key, value in replacements.items():
                    content = content.replace("${" + key + "}", value)
                path = Path(directory) / ("resource-balancer-" + names[name] + ".service")
                path.write_text(content)
                paths.append(str(path))
            result = subprocess.run([verifier, "verify", "--man=no", "--generators=no", *paths],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_metrics_retention_and_latest_query(self):
        collector = load_program("COLLECTOR")
        now = datetime.now(timezone.utc)
        header = ["timestamp", "cpu_percent", "memory_percent", "memory_used_kb",
                  "memory_total_kb", "managed_memory_kb", "native_memory_percent"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metrics.csv"
            with path.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(header)
                for age in (31, 29, 1, 0):
                    writer.writerow([(now - timedelta(days=age)).isoformat(), 10, 25, 250, 1000, 0, 25])
            with patch.object(collector, "DATA", str(path)):
                collector.prune_metrics(now, 30)
            with patch.object(self.cli, "DATA", str(path)):
                self.assertEqual(len(self.cli.load()), 3)
                self.assertEqual(len(self.cli.load(24)), 1)
                self.assertEqual(self.cli.load(limit=1)[0]["timestamp"], now)
            self.assertFalse(Path(str(path) + ".prune").exists())

    def test_pruning_failure_preserves_original_data(self):
        collector = load_program("COLLECTOR")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metrics.csv"
            original = "timestamp,cpu_percent\n2026-10-18T00:00:00+00:00,10\n"
            path.write_text(original)
            with patch.object(collector, "DATA", str(path)), \
                 patch.object(collector.os, "replace", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    collector.prune_metrics(datetime.now(timezone.utc), 30)
            self.assertEqual(path.read_text(), original)

    def test_management_lock_contends_and_releases(self):
        if os.name != "posix":
            self.skipTest("requires POSIX flock")
        original_open = os.open
        original_fstat = os.fstat
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "lock")

            def open_lock(*args):
                return original_open(path, *args[1:])

            def root_stat(fd):
                info = original_fstat(fd)
                return types.SimpleNamespace(st_uid=0, st_mode=info.st_mode)

            with patch.object(self.cli.os, "geteuid", return_value=0), \
                 patch.object(self.cli.os, "open", side_effect=open_lock), \
                 patch.object(self.cli.os, "fstat", side_effect=root_stat):
                with self.cli.management_lock():
                    with self.assertRaises(RuntimeError):
                        with self.cli.management_lock():
                            self.fail("concurrent mutation allowed")
                with self.cli.management_lock():
                    pass

    def test_duration_parser(self):
        parser = getattr(self.cli, "parse_duration", None)
        self.assertTrue(callable(parser), "parse_duration must be defined")
        for text, expected in (("10", 10), ("10s", 10), ("10m", 600),
                               ("1h", 3600), ("24h", 86400), ("0", 0)):
            with self.subTest(text=text):
                self.assertEqual(parser(text), expected)
        for text in ("", "-10", "9s", "25h", "1d", "nan", "1.5h", "10mX"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parser(text)

    def test_invalid_targets_do_not_touch_configuration(self):
        for function in (self.cli.cpu_test, self.cli.memory_test):
            for target in ("nan", "inf", "-inf", "4.9", "80.1"):
                with self.subTest(function=function.__name__, target=target):
                    with patch("builtins.open") as opened, self.assertRaises(ValueError):
                        function(["--target", target])
                    opened.assert_not_called()

    def test_workers_reject_invalid_parameters_before_state_writes(self):
        for name in ("MEMTEST", "CPUTEST"):
            for target, duration in ((float("nan"), 0), (25, -1), (25, 9), (25, 86401)):
                worker = load_program(name)
                with self.subTest(name=name, target=target, duration=duration):
                    with contextlib.ExitStack() as stack:
                        stack.enter_context(patch.dict(os.environ, {
                            "TARGET_PERCENT": str(target), "DURATION_SECONDS": str(duration),
                        }))
                        stack.enter_context(patch("sys.argv", ["worker"]))
                        if name == "CPUTEST":
                            stack.enter_context(patch.object(worker, "load_config", return_value=(target, duration)))
                        opened = stack.enter_context(patch("builtins.open"))
                        with self.assertRaises(SystemExit):
                            worker.main()
                        opened.assert_not_called()

    def test_p95_threshold_reachable_at_maximum_target(self):
        for name in ("MEMTEST", "CPUTEST"):
            worker = load_program(name)
            threshold = getattr(worker, "p95_enter_threshold", None)
            self.assertTrue(callable(threshold), name)
            self.assertEqual(threshold(25), 25.5)
            self.assertEqual(threshold(80), 79.5)
            self.assertLessEqual(threshold(79.8), 79.5)
            self.assertLess(worker.p95_resume_threshold(80), threshold(80))

    def test_stop_failure_preserves_state_and_does_not_claim_success(self):
        for function in (self.cli.cpu_stop, self.cli.memory_stop):
            output = io.StringIO()
            with self.subTest(function=function.__name__), contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(self.cli.os, "geteuid", return_value=0, create=True))
                stack.enter_context(patch.object(self.cli.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["systemctl"])))
                opened = stack.enter_context(patch("builtins.open"))
                removed = stack.enter_context(patch.object(self.cli.os, "remove"))
                stack.enter_context(contextlib.redirect_stdout(output))
                with self.assertRaises((subprocess.CalledProcessError, RuntimeError)):
                    function()
                opened.assert_not_called()
                removed.assert_not_called()
                self.assertNotIn("released", output.getvalue())

    def test_stop_checks_service_is_quiescent_before_deleting_state(self):
        for function in (self.cli.cpu_stop, self.cli.memory_stop):
            with self.subTest(function=function.__name__), contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(self.cli.os, "geteuid", return_value=0, create=True))
                stack.enter_context(patch.object(self.cli.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="deactivating\n")))
                removed = stack.enter_context(patch.object(self.cli.os, "remove"))
                with self.assertRaises(RuntimeError):
                    function()
                removed.assert_not_called()

    def test_uninstall_stops_before_removing_anything(self):
        calls = []

        def run(cmd, **kwargs):
            calls.append(cmd)
            if cmd[0] == "systemctl":
                if kwargs.get("check"):
                    raise subprocess.CalledProcessError(1, cmd)
                return subprocess.CompletedProcess(cmd, 1, stdout="")
            return subprocess.CompletedProcess(cmd, 0)

        with patch.object(self.cli.os, "geteuid", return_value=0, create=True), \
             patch.object(self.cli.subprocess, "run", side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises((subprocess.CalledProcessError, RuntimeError)):
                self.cli.uninstall(["--purge"])
        self.assertFalse(any(cmd[0] == "rm" for cmd in calls))

    def test_health_degraded_is_nonzero(self):
        with patch.object(self.cli, "active", return_value=False), \
             patch.object(self.cli, "enabled", return_value=False), \
             patch.object(self.cli, "load", return_value=[]), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.cli.health(), 1)

    def test_invalid_command_returns_usage_error(self):
        with patch("sys.argv", ["resource-balancer", "typo"]), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.cli.main(), 2)

    def test_uninstall_remove_failure_keeps_cli_for_retry(self):
        calls = []

        def run(cmd, **kwargs):
            calls.append(cmd)
            if cmd[0] == "rm":
                raise subprocess.CalledProcessError(1, cmd)
            return subprocess.CompletedProcess(cmd, 0, stdout="inactive\n")

        output = io.StringIO()
        with patch.object(self.cli.os, "geteuid", return_value=0, create=True), \
             patch.object(self.cli.subprocess, "run", side_effect=run), \
             contextlib.redirect_stdout(output):
            with self.assertRaises(subprocess.CalledProcessError):
                self.cli.uninstall([])
        self.assertFalse(any(cmd[0] == "rm" and "/usr/local/bin/resource-balancer" in cmd for cmd in calls))
        self.assertNotIn("program removed", output.getvalue())

    def test_uninstall_can_retry_after_units_were_removed(self):
        removed_units = False
        manager_has_units = True
        fail_reload = True

        def run(cmd, **kwargs):
            nonlocal removed_units, manager_has_units, fail_reload
            if cmd[:2] == ["systemctl", "show"]:
                if "--property=LoadState,ActiveState" in cmd:
                    output = "LoadState=loaded\nActiveState=inactive\n" if manager_has_units else "LoadState=not-found\nActiveState=inactive\n"
                else:
                    output = "inactive\n"
                return subprocess.CompletedProcess(cmd, 0, stdout=output)
            if cmd[0] == "rm" and any(path.endswith(".service") for path in cmd):
                removed_units = True
            if cmd[:2] == ["systemctl", "daemon-reload"]:
                if removed_units and fail_reload:
                    fail_reload = False
                    raise subprocess.CalledProcessError(1, cmd)
                manager_has_units = not removed_units
            if cmd[:2] == ["systemctl", "disable"] and removed_units:
                self.fail("attempted to disable an absent unit")
            return subprocess.CompletedProcess(cmd, 0, stdout="")

        with patch.object(self.cli.os, "geteuid", return_value=0, create=True), \
             patch.object(self.cli.subprocess, "run", side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError):
                self.cli.uninstall([])
            self.cli.uninstall([])

    def test_timed_commands_persist_duration_and_disable_reboot_restore(self):
        from test_startup_recovery import FakeManager

        for name, config in (("cpu_test", "CPUCONF"), ("memory_test", "MEMCONF")):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "controller.conf"
                roots = (Path(directory) / "persistent", Path(directory) / "runtime")
                manager = FakeManager(roots)
                with patch.object(self.cli, config, str(path)), \
                     patch.object(self.cli, "SYSTEMD_CONTROL_DIRS", tuple(map(str, roots))), \
                     patch.object(self.cli.os, "geteuid", return_value=0, create=True), \
                     patch.object(self.cli, "active", return_value=False), \
                     patch.object(self.cli.subprocess, "run", side_effect=manager.run) as run, \
                     contextlib.redirect_stdout(io.StringIO()):
                    getattr(self.cli, name)(["--target", "25", "--duration", "10m"])
                self.assertIn("DURATION_SECONDS=600", path.read_text())
                commands = [call.args[0] for call in run.call_args_list]
                self.assertTrue(any(cmd[1] == "disable" for cmd in commands))
                self.assertFalse(any(cmd[1] == "enable" for cmd in commands))

    def test_installer_stages_before_stop_and_restores_on_restart_failure(self):
        bash = os.environ.get("RB_TEST_BASH") or shutil.which("bash")
        if not bash:
            self.skipTest("Bash unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            posix_root = root.as_posix()
            if os.name == "nt":
                posix_root = subprocess.check_output([bash, "-c", 'cygpath -u "$1"', "probe", str(root)], text=True).strip()
            # Isolate every installer destination; real systemctl is never used.
            source = SOURCE[:SOURCE.index("\n_resource_balancer_installer_launch()")]
            for prefix in ("/usr/local/", "/etc/", "/var/lib/", "/run/", "/tmp/resource-balancer."):
                source = source.replace(prefix, posix_root + prefix)
            source = source.replace('[[ $EUID -eq 0 ]]', '[[ 0 -eq 0 ]]')
            source = source.replace('[[ -x /usr/bin/python3 ]]', '[[ 1 -eq 1 ]]')
            for item in ("usr/local/bin/resource-balancer", "usr/local/lib/resource-balancer/collector.py",
                         "etc/resource-balancer.conf", "etc/systemd/system/resource-balancer-collector.service"):
                path = root / item
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("previous-version\n")
            for name in ("tmp", "run", "var/lib/resource-balancer"):
                (root / name).mkdir(parents=True, exist_ok=True)
            data = root / "var/lib/resource-balancer/metrics.csv"
            original_metrics = ("timestamp,cpu_percent\n" +
                                (datetime.now(timezone.utc) - timedelta(days=45)).isoformat() + ",10\n").encode()
            probe = root / "prune_probe.py"
            probe.write_text(
                "import runpy, sys\nfrom datetime import datetime, timezone\n"
                "module = runpy.run_path(sys.argv[1])\n"
                "module['prune_metrics'].__globals__['DATA'] = sys.argv[2]\n"
                "module['load_retention_days'].__globals__['CONF'] = sys.argv[3]\n"
                "module['prune_metrics'](datetime.now(timezone.utc), module['load_retention_days']())\n"
            )
            # The preflight Python is covered separately; compilation is a failure
            # injection here, so no Linux Python or actual services are needed.
            stubs = r'''
systemctl() {
    printf '%s\n' "$*" >> "$RB_PROBE_LOG"
    case "$1" in
        is-enabled|is-active) return 0 ;;
        restart)
            if [[ "$RB_LATE_FAIL" == 1 ]]; then
                if [[ "$2" == resource-balancer-collector ]]; then
                    "$RB_PROBE_PYTHON" "$RB_PRUNE_PROBE" "$RB_COLLECTOR" "$RB_DATA" "$RB_CONF" || return
                    printf 'COLLECTOR_RAN\n' >> "$RB_PROBE_LOG"
                fi
                return 0
            fi
            return 17 ;;
        *) return 0 ;;
    esac
}
python3() {
    if [[ "$1" == - ]]; then cat >/dev/null; return 0; fi
    printf 'COMPILE\n' >> "$RB_PROBE_LOG"
    return "$RB_COMPILE_RC"
}
flock() { return 0; }
'''
            script = root / "probe.sh"
            script.write_text(stubs + source + "\nresource_balancer_installer_main\n", encoding="utf-8")
            trials = [(19, False, "previous-version\n"), (0, False, "previous-version\n"),
                      (0, True, "previous-version\n")]
            trials.extend((0, True, "METRICS_RETENTION_DAYS=30\nMETRICS_RETENTION_DAYS=" + invalid + "\n")
                          for invalid in ("nan", "999999", "-1", ""))
            for compile_rc, late_failure, original_config in trials:
                log = root / "calls.log"
                log.write_text("")
                data.write_bytes(original_metrics)
                (root / "etc/resource-balancer.conf").write_text(original_config)
                result = subprocess.run([bash, str(script)], capture_output=True, text=True,
                                        env={**os.environ, "RB_PROBE_LOG": posix_root + "/calls.log",
                                             "RB_COMPILE_RC": str(compile_rc), "RB_LATE_FAIL": str(int(late_failure)),
                                             "RB_PROBE_PYTHON": Path(sys.executable).as_posix(),
                                             "RB_PRUNE_PROBE": posix_root + "/prune_probe.py",
                                             "RB_COLLECTOR": posix_root + "/usr/local/lib/resource-balancer/collector.py",
                                             "RB_DATA": posix_root + "/var/lib/resource-balancer/metrics.csv",
                                             "RB_CONF": posix_root + "/etc/resource-balancer.conf"})
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                calls = log.read_text().splitlines()
                self.assertIn("COMPILE", calls, result.stderr)
                if compile_rc:
                    self.assertFalse(any(line.startswith("stop ") for line in calls))
                else:
                    self.assertIn("restoring previous", result.stderr)
                    self.assertLess(calls.index("COMPILE"), next(i for i, line in enumerate(calls) if line.startswith("stop ")))
                self.assertEqual((root / "usr/local/bin/resource-balancer").read_text(), "previous-version\n")
                self.assertEqual((root / "etc/resource-balancer.conf").read_text(), original_config)
                self.assertEqual(data.read_bytes(), original_metrics)
                if late_failure:
                    self.assertIn("COLLECTOR_RAN", calls, result.stderr)

    def test_installer_preserves_failure_status_and_interactive_shell(self):
        bash = os.environ.get("RB_TEST_BASH") or shutil.which("bash")
        if not bash:
            self.skipTest("Bash unavailable")
        # Keep the real cleanup tail while replacing the launch operation.
        index = SOURCE.rfind("\n_resource_balancer_installer_launch\n")
        self.assertNotEqual(index, -1)
        prefix = SOURCE[:index]
        finish = prefix.rfind("\n_resource_balancer_installer_finish()")
        tail = (prefix[finish:] if finish != -1 else "") + SOURCE[index:]
        probe = "_resource_balancer_installer_launch() { return 23; }\n" + tail
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "probe.sh"
            script.write_text(probe, encoding="utf-8")
            result = subprocess.run([bash, str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 23, result.stderr)
            result = subprocess.run([bash, "--noprofile", "--norc", "-ic",
                                     'source "$1"; rc=$?; echo SHELL_ALIVE; exit "$rc"',
                                     "probe", str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertIn("SHELL_ALIVE", result.stdout)


if __name__ == "__main__":
    unittest.main()
