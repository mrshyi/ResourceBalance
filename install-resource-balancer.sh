#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Resource Balancer contributors
#
# Resource Balancer installer v2.8.4
#
# Supported:
#   - Paste this ENTIRE script directly into an interactive Bash SSH session
#   - bash install-resource-balancer.sh
#   - sudo bash install-resource-balancer.sh
#   - cat install-resource-balancer.sh | bash
#
# The installer body runs in an isolated subshell/root Bash process.
# Therefore `set -euo pipefail` and `exit` cannot terminate the SSH login shell.

resource_balancer_installer_main() (
set -euo pipefail

VERSION="2.8.4"

BIN="/usr/local/bin/resource-balancer"
SHORT_BIN="/usr/local/bin/rb"
LIBDIR="/usr/local/lib/resource-balancer"
COLLECTOR="${LIBDIR}/collector.py"
MEMTEST="${LIBDIR}/memory.py"
CPUTEST="${LIBDIR}/cpu.py"

DATADIR="/var/lib/resource-balancer"
DATA="${DATADIR}/metrics.csv"
STATE="${DATADIR}/memory-managed-kb"

CONF="/etc/resource-balancer.conf"
MEMCONF="/etc/resource-balancer-memory.conf"
CPUCONF="/etc/resource-balancer-cpu.conf"

COLLECTOR_UNIT="/etc/systemd/system/resource-balancer-collector.service"
MEMTEST_UNIT="/etc/systemd/system/resource-balancer-memory.service"
CPUTEST_UNIT="/etc/systemd/system/resource-balancer-cpu.service"


die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "Installer privilege escalation failed."

command -v python3 >/dev/null 2>&1 || die "python3 is required."
command -v systemctl >/dev/null 2>&1 || die "systemd is required."
command -v flock >/dev/null 2>&1 || die "flock (util-linux) is required."
[[ -x /usr/bin/python3 ]] || die "/usr/bin/python3 is required by the services."
systemctl show-environment >/dev/null || die "cannot connect to the systemd manager"

# Reject symlinks, unexpected types and writable/non-root-owned ancestors before
# opening root-managed files, including fixed temporary paths used by workers.
python3 - "$LIBDIR" "$DATADIR" "$BIN" "$SHORT_BIN" "$CONF" "$MEMCONF" "$CPUCONF" \
    "$COLLECTOR_UNIT" "$MEMTEST_UNIT" "$CPUTEST_UNIT" \
    /run/resource-balancer.lock <<'PY'
import os
from pathlib import Path
import stat
import sys

if sys.version_info < (3, 8):
    raise SystemExit("Python 3.8 or newer is required")

paths = set()
directories = {Path(value) for value in sys.argv[1:3]}
for value in sys.argv[1:]:
    path = Path(value)
    if path.exists() and not path.is_symlink():
        if path.is_dir() != (path in directories):
            raise SystemExit(f"unexpected installation path type: {path}")
    paths.update((path, *path.parents))
    if path.is_dir() and not path.is_symlink():
        paths.update(path.rglob("*"))
for path in sorted(paths):
    try:
        info = path.lstat()
    except FileNotFoundError:
        continue
    if (info.st_uid != 0 or info.st_mode & 0o022
            or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode))):
        raise SystemExit(f"unsafe installation path: {path}")
PY

# The CLI takes this same lock for root-only mutations.
exec 9>/run/resource-balancer.lock
flock -n 9 || die "another Resource Balancer management operation is running"

STAGING="$(mktemp -d /tmp/resource-balancer.XXXXXXXX)"
chmod 700 "$STAGING"
TRANSACTION_STARTED=0
INSTALL_COMPLETE=0
TARGETS=("$CONF" "$COLLECTOR" "$MEMTEST" "$CPUTEST" "$BIN" "$SHORT_BIN"
    "$COLLECTOR_UNIT" "$MEMTEST_UNIT" "$CPUTEST_UNIT")
SERVICES=(resource-balancer-collector resource-balancer-memory resource-balancer-cpu)
declare -a WAS_ENABLED WAS_ACTIVE
for i in "${!SERVICES[@]}"; do
    WAS_ENABLED[i]=0
    WAS_ACTIVE[i]=0
    if systemctl is-enabled --quiet "${SERVICES[i]}" 2>/dev/null; then
        WAS_ENABLED[i]=1
    fi
    if systemctl is-active --quiet "${SERVICES[i]}" 2>/dev/null; then
        WAS_ACTIVE[i]=1
    fi
done

finish_install() {
    local rc=$1 target i failed=0
    trap - EXIT INT TERM
    if [[ "$TRANSACTION_STARTED" -eq 1 && "$INSTALL_COMPLETE" -eq 0 ]]; then
        echo "ERROR: installation failed; restoring previous files and services" >&2
        for i in "${!SERVICES[@]}"; do
            if [[ "${WAS_ACTIVE[i]}" -eq 1 || -f "/etc/systemd/system/${SERVICES[i]}.service" ]]; then
                systemctl stop "${SERVICES[i]}" || failed=1
            fi
        done
        # If stopping fails, overwriting files beneath a live service is unsafe.
        if [[ "$failed" -eq 0 ]]; then
            for target in "${TARGETS[@]}"; do
                if [[ -f "${STAGING}/backup${target}" ]]; then
                    cp -p "${STAGING}/backup${target}" "$target" || failed=1
                else
                    rm -f "$target" || failed=1
                fi
                rm -f "${target}.install-tmp" || failed=1
            done
            systemctl daemon-reload || failed=1
            for i in "${!SERVICES[@]}"; do
                [[ "$failed" -eq 0 ]] || break
                if [[ "${WAS_ENABLED[i]}" -eq 1 ]]; then
                    systemctl enable "${SERVICES[i]}" || failed=1
                elif [[ -f "/etc/systemd/system/${SERVICES[i]}.service" ]]; then
                    systemctl disable "${SERVICES[i]}" || failed=1
                fi
                if [[ "${WAS_ACTIVE[i]}" -eq 1 ]]; then
                    systemctl start "${SERVICES[i]}" || failed=1
                fi
            done
        fi
        if [[ "$failed" -ne 0 ]]; then
            echo "ERROR: automatic restore incomplete; backups retained at $STAGING" >&2
            exit 1
        fi
        [[ "$rc" -ne 0 ]] || rc=1
    fi
    rm -rf -- "$STAGING"
    exit "$rc"
}
trap 'finish_install "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for target in "${TARGETS[@]}"; do
    mkdir -p "${STAGING}$(dirname "$target")"
done

echo "============================================================"
echo " Resource Balancer v${VERSION}"
echo "============================================================"
echo
echo "Collector:    continuous real-resource monitoring"
echo "Memory Test:  dynamic capacity/stress controller (timed or persistent)"
echo "CPU Test:     7-day rolling P95 controller; synthetic load only when needed"
echo

# ============================================================
# 1. Baseline preflight / preserve runtime state
# ============================================================

echo "[1/10] Preparing v2.8.4 installation/reinstall..."

# v2.8.0 is the clean baseline. Supported paths are intentionally limited to:
#   1) fresh installation
#   2) reinstall/repair of an existing canonical v2.8.x installation
# Historical migration belongs to the archived upgrade installer, not this baseline.
LEGACY_PATHS=(
    /etc/resource-balancer-memory-test.conf
    /etc/resource-balancer-cpu-test.conf
    "${LIBDIR}/memory-test.py"
    "${LIBDIR}/cpu-test.py"
    "${DATADIR}/memory-test-state"
    "${DATADIR}/cpu-test-state"
    /etc/systemd/system/resource-balancer.service
    /etc/systemd/system/resource-balancer-memory-test.service
    /etc/systemd/system/resource-balancer-cpu-test.service
)
for legacy in "${LEGACY_PATHS[@]}"; do
    [[ ! -e "$legacy" ]] || die "legacy installation detected at $legacy; use the archived upgrade path before the v2.8.0 baseline installer."
done

# ============================================================
# 2. Clean configuration
# ============================================================

echo "[2/10] Installing canonical configuration..."

# Preserve SAMPLE_INTERVAL if a valid value already exists.
SAMPLE_INTERVAL=60
METRICS_RETENTION_DAYS=0

if [[ -f "$CONF" ]]; then
    OLD_INTERVAL="$(
        grep -E '^SAMPLE_INTERVAL=[0-9]+$' "$CONF" 2>/dev/null \
        | tail -1 \
        | cut -d= -f2 || true
    )"

    if [[ -n "${OLD_INTERVAL:-}" ]]; then
        SAMPLE_INTERVAL="$OLD_INTERVAL"
    fi
    OLD_RETENTION="$(sed -n 's/^[[:space:]]*METRICS_RETENTION_DAYS=//p' "$CONF" | tail -1 | sed 's/[[:space:]]*$//' || true)"
    if [[ "$OLD_RETENTION" =~ ^[0-9]{1,5}$ ]] && (( 10#$OLD_RETENTION <= 36500 )); then
        METRICS_RETENTION_DAYS=$((10#$OLD_RETENTION))
    fi
fi

cat > "${STAGING}${CONF}" <<EOF
# Resource Balancer v${VERSION}
#
# Collector configuration only.
#
# Memory tests are configured per invocation:
#
#   resource-balancer memory test --target 25
#   resource-balancer memory test --target 25 --duration 10m
#
# Omitting --duration runs permanently until the corresponding stop command.
# Permanent CPU/memory controller configuration is persisted in dedicated
# /etc/resource-balancer-{cpu,memory}.conf files and restored across reboot/reinstalls.

SAMPLE_INTERVAL=${SAMPLE_INTERVAL}
# 0 preserves all samples. Set 1..36500 explicitly to opt into deletion.
METRICS_RETENTION_DAYS=${METRICS_RETENTION_DAYS}
EOF

chmod 644 "${STAGING}${CONF}"

# ============================================================
# 3. Collector
# ============================================================

echo "[3/10] Installing collector..."

cat > "${STAGING}${COLLECTOR}" <<'PY'
#!/usr/bin/env python3

import csv
import json
import os
import signal
import time
from datetime import datetime, timezone, timedelta

DATA = "/var/lib/resource-balancer/metrics.csv"
STATE = "/var/lib/resource-balancer/memory-managed-kb"
TESTSTATE = "/var/lib/resource-balancer/memory-state"
CONF = "/etc/resource-balancer.conf"

DEFAULT_INTERVAL = 60

running = True


def stop(signum=None, frame=None):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def load_interval():
    interval = DEFAULT_INTERVAL

    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()

                if not line or line.startswith("#"):
                    continue

                if line.startswith("SAMPLE_INTERVAL="):
                    try:
                        interval = int(line.split("=", 1)[1])
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass

    return max(10, interval)


def read_cpu():
    with open("/proc/stat") as f:
        fields = f.readline().split()

    values = list(map(int, fields[1:]))

    idle = values[3]

    if len(values) > 4:
        idle += values[4]

    return sum(values), idle


def read_memory():
    info = {}

    with open("/proc/meminfo") as f:
        for line in f:
            key, value = line.split(":", 1)
            info[key] = int(value.strip().split()[0])

    total = info["MemTotal"]
    available = info["MemAvailable"]
    used = total - available

    pct = used / total * 100

    return total, used, pct


def managed_memory():
    # Never trust a stale state file after OOM/SIGKILL/crash.
    try:
        with open(TESTSTATE) as f:
            state = json.load(f)
        pid = int(state.get("pid", 0))
        if pid <= 0:
            return 0
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmdline = f.read().replace(b"\0", b" ")
        if b"memory.py" not in cmdline:
            return 0
        with open(STATE) as f:
            value = int(f.read().strip())
        return max(0, value)
    except Exception:
        try:
            with open(STATE, "w") as f:
                f.write("0")
        except Exception:
            pass
        return 0


def ensure_file():
    header = [
        "timestamp",
        "cpu_percent",
        "memory_percent",
        "memory_used_kb",
        "memory_total_kb",
        "managed_memory_kb",
        "native_memory_percent",
    ]

    if not os.path.exists(DATA) or os.path.getsize(DATA) == 0:
        with open(DATA, "w", newline="") as f:
            csv.writer(f).writerow(header)

        return

    # Preserve existing v2/v2.1 CSV.
    #
    # Older files without managed/native columns are still readable
    # by the CLI. New rows use the current schema only if the existing
    # header already supports it.
    with open(DATA, newline="") as f:
        reader = csv.reader(f)
        existing = next(reader, [])

    if existing == header:
        return

    # Migrate existing CSV atomically.
    tmp = DATA + ".migrate"

    with open(DATA, newline="") as src, \
         open(tmp, "w", newline="") as dst:

        reader = csv.DictReader(src)
        writer = csv.DictWriter(dst, fieldnames=header)

        writer.writeheader()

        for row in reader:
            mem_pct = row.get("memory_percent", "0")

            writer.writerow({
                "timestamp":
                    row.get("timestamp", ""),

                "cpu_percent":
                    row.get("cpu_percent", "0"),

                "memory_percent":
                    mem_pct,

                "memory_used_kb":
                    row.get("memory_used_kb", "0"),

                "memory_total_kb":
                    row.get("memory_total_kb", "0"),

                "managed_memory_kb":
                    row.get("managed_memory_kb", "0") or "0",

                "native_memory_percent":
                    row.get("native_memory_percent", "") or mem_pct,
            })

    os.replace(tmp, DATA)


def append_sample(timestamp, cpu, mem_pct,
                  mem_used, mem_total, managed):

    native_used = max(0, mem_used - managed)
    native_pct = native_used / mem_total * 100

    with open(DATA, "a", newline="") as f:
        writer = csv.writer(f)

        writer.writerow([
            timestamp,
            f"{cpu:.2f}",
            f"{mem_pct:.2f}",
            mem_used,
            mem_total,
            managed,
            f"{native_pct:.2f}",
        ])


def load_retention_days():
    """Missing or invalid opt-in must never cause deletion."""
    value = "0"
    try:
        with open(CONF) as stream:
            for line in stream:
                if line.strip().startswith("METRICS_RETENTION_DAYS="):
                    value = line.strip().split("=", 1)[1]
    except FileNotFoundError:
        return 0
    if not value.isascii() or not value.isdigit() or len(value) > 5:
        return 0
    days = int(value)
    return days if 0 <= days <= 36500 else 0


def prune_metrics(now, retention_days=0):
    """Stream old samples out once a day; replace only after a complete write."""
    if retention_days <= 0:
        return
    cutoff = now - timedelta(days=retention_days)
    tmp = DATA + ".prune"
    try:
        with open(DATA, newline="") as src, open(tmp, "w", newline="") as dst:
            reader = csv.DictReader(src)
            writer = csv.DictWriter(dst, fieldnames=reader.fieldnames)
            writer.writeheader()
            for row in reader:
                try:
                    timestamp = datetime.fromisoformat(row["timestamp"])
                    keep = timestamp >= cutoff
                except (ValueError, KeyError, TypeError):
                    keep = False
                if keep:
                    writer.writerow(row)
        os.replace(tmp, DATA)
    finally:
        try:
            os.remove(tmp)
        except FileNotFoundError:
            pass


def main():
    interval = load_interval()

    ensure_file()
    retention_days = load_retention_days()
    prune_metrics(datetime.now(timezone.utc), retention_days)
    next_prune = time.monotonic() + 86400

    previous_total, previous_idle = read_cpu()

    while running:
        remaining = interval

        while running and remaining > 0:
            step = min(1, remaining)
            time.sleep(step)
            remaining -= step

        if not running:
            break

        total, idle = read_cpu()

        delta_total = total - previous_total
        delta_idle = idle - previous_idle

        if delta_total > 0:
            cpu = (1 - delta_idle / delta_total) * 100
        else:
            cpu = 0.0

        previous_total = total
        previous_idle = idle

        mem_total, mem_used, mem_pct = read_memory()
        managed = managed_memory()

        append_sample(
            datetime.now(timezone.utc).isoformat(),
            cpu,
            mem_pct,
            mem_used,
            mem_total,
            managed,
        )
        if time.monotonic() >= next_prune:
            prune_metrics(datetime.now(timezone.utc), retention_days)
            next_prune = time.monotonic() + 86400


if __name__ == "__main__":
    main()
PY

chmod 755 "${STAGING}${COLLECTOR}"

# ============================================================
# 4. Memory Test
# ============================================================

echo "[4/10] Installing bounded memory controller..."

cat > "${STAGING}${MEMTEST}" <<'PY'
#!/usr/bin/env python3

import gc
import json
import math
import os
import signal
import sys
import time
from datetime import datetime, timezone

STATE = "/var/lib/resource-balancer/memory-managed-kb"
TESTSTATE = "/var/lib/resource-balancer/memory-state"
HISTORY = "/var/lib/resource-balancer/memory-p95-history.jsonl"
WINDOW_SECONDS = 7 * 24 * 3600
HISTORY_SAMPLE_SECONDS = 60
P95_HYSTERESIS = 0.50
BOOST_MARGIN = 5.0
MAX_P95_TARGET = 80.0

running = True
chunks = []


def p95_enter_threshold(target):
    # Keep headroom below the realtime boost's upper deadband; otherwise an
    # 80% target can settle at 79.6% and never satisfy an 80% threshold.
    return min(MAX_P95_TARGET - P95_HYSTERESIS, target + P95_HYSTERESIS)


def p95_resume_threshold(target):
    return min(target - P95_HYSTERESIS, p95_enter_threshold(target) - P95_HYSTERESIS)


def stop(signum=None, frame=None):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def meminfo():
    info = {}

    with open("/proc/meminfo") as f:
        for line in f:
            key, value = line.split(":", 1)
            info[key] = int(value.strip().split()[0])

    total = info["MemTotal"]
    available = info["MemAvailable"]
    used = total - available

    return total, used


def managed_kb():
    return sum(len(x) for x in chunks) // 1024


def write_managed():
    tmp = STATE + ".tmp"

    with open(tmp, "w") as f:
        f.write(str(managed_kb()))

    os.replace(tmp, STATE)


def write_test_state(target, duration, started, ends, mode="balance", p95=None,
                     sample_count=0, coverage_seconds=0, control=None,
                     boost_target=None):
    tmp = TESTSTATE + ".tmp"

    state = {
        "target_percent": target,
        "duration_seconds": duration,
        "started_at": started.isoformat(),
        "ends_at": ends.isoformat() if ends else None,
        "pid": os.getpid(),
        "mode": mode,
        "p95_percent": p95,
        "p95_target_percent": target if mode == "p95" else None,
        "p95_window_seconds": WINDOW_SECONDS if mode == "p95" else None,
        "p95_sample_interval_seconds": HISTORY_SAMPLE_SECONDS if mode == "p95" else None,
        "p95_sample_count": sample_count,
        "p95_coverage_seconds": int(max(0, coverage_seconds)),
        "control": control,
        "boost_target_percent": boost_target if mode == "p95" else None,
    }

    with open(tmp, "w") as f:
        json.dump(state, f)

    os.replace(tmp, TESTSTATE)


CHUNK_SIZE = 8 * 1024 * 1024


def allocate_bytes(size):
    # Fixed-size chunks avoid large temporary copies during release.
    remaining = max(0, size)
    page = 4096
    while remaining > 0:
        this_size = min(CHUNK_SIZE, remaining)
        block = bytearray(this_size)
        for offset in range(0, this_size, page):
            block[offset] = 1
        chunks.append(block)
        remaining -= this_size


def release_bytes(size):
    if size <= 0:
        return

    remaining = size

    while chunks and remaining > 0:
        block = chunks[-1]

        if len(block) <= remaining:
            remaining -= len(block)
            chunks.pop()

        else:
            # Drop the whole small chunk instead of slicing/copying it.
            remaining = 0
            chunks.pop()

    gc.collect()


def cleanup():
    chunks.clear()
    gc.collect()

    try:
        with open(STATE, "w") as f:
            f.write("0")
    except Exception:
        pass

    try:
        os.remove(TESTSTATE)
    except FileNotFoundError:
        pass


def human_mb(value):
    return value / 1024 / 1024



def percentile(values, p):
    if not values:
        return 0.0
    xs = sorted(values)
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * p
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return xs[lo]
    frac = pos - lo
    return xs[lo] * (1.0 - frac) + xs[hi] * frac


def load_history(now_epoch):
    cutoff = now_epoch - WINDOW_SECONDS
    rows = []
    try:
        with open(HISTORY) as f:
            for line in f:
                try:
                    item = json.loads(line)
                    ts = float(item["ts"])
                    value = float(item["memory"])
                    if math.isfinite(ts) and math.isfinite(value) and cutoff <= ts <= now_epoch and 0 <= value <= 100:
                        rows.append((ts, value))
                except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                    continue
    except FileNotFoundError:
        pass
    rows.sort(key=lambda x: x[0])
    return rows


def save_history(rows):
    tmp = HISTORY + ".tmp"
    with open(tmp, "w") as f:
        for ts, value in rows:
            f.write(json.dumps({"ts": round(ts, 3), "memory": round(value, 3)}) + "\n")
    os.replace(tmp, HISTORY)


def append_history(rows, ts, value):
    cutoff = ts - WINDOW_SECONDS
    rows = [(t, v) for t, v in rows if t >= cutoff]
    rows.append((ts, value))
    save_history(rows)
    return rows


def main():
    if len(sys.argv) in (2, 3, 4):
        target = float(sys.argv[1])
        duration = int(sys.argv[2]) if len(sys.argv) >= 3 else 0
        mode = sys.argv[3].lower() if len(sys.argv) == 4 else "balance"
    elif len(sys.argv) == 1:
        try:
            target = float(os.environ["TARGET_PERCENT"])
            duration = int(os.environ.get("DURATION_SECONDS", "0"))
            mode = os.environ.get("MEMORY_MODE", "balance").lower()
        except (KeyError, ValueError):
            raise SystemExit(
                "TARGET_PERCENT/DURATION_SECONDS/MEMORY_MODE environment is invalid"
            )
    else:
        raise SystemExit(
            "usage: memory.py TARGET_PERCENT [DURATION_SECONDS] [balance|p95]"
        )

    if mode not in ("balance", "p95"):
        raise SystemExit("memory mode must be balance or p95")

    if not math.isfinite(target) or target < 5 or target > 80:
        raise SystemExit("target must be between 5 and 80")

    if duration != 0 and (duration < 10 or duration > 86400):
        raise SystemExit(
            "duration must be 0 (permanent) or between 10 seconds and 24 hours"
        )

    started = datetime.now(timezone.utc)

    ends = (
        datetime.fromtimestamp(
            started.timestamp() + duration,
            tz=timezone.utc,
        )
        if duration > 0
        else None
    )

    write_test_state(
        target,
        duration,
        started,
        ends,
        mode=mode,
        control="WARMING_UP" if mode == "p95" else "BALANCED",
    )

    history = load_history(time.time()) if mode == "p95" else []
    p95_control = "BOOSTING"
    # P95 is a statistical target, not an instantaneous ceiling. During
    # BOOSTING, deliberately create samples above the enter threshold so the
    # rolling P95 can actually cross target+hysteresis. This also works on a
    # mature 7-day window: when old high samples age out and P95 falls below
    # the resume threshold, replenishment resumes with clearly high samples.
    boost_target = min(MAX_P95_TARGET, target + BOOST_MARGIN)
    bucket_started = time.monotonic()
    bucket_sum = 0.0
    bucket_count = 0

    # Target control parameters.
    #
    # We do NOT add a fixed 16 MiB every interval.
    # Instead we calculate the deficit and converge rapidly.
    #
    # Coarse stage:
    #   allocate up to 60% of current deficit
    #
    # Fine stage:
    #   smaller increments near target
    #
    # Hysteresis:
    #   +/- 0.5 percentage points

    hysteresis = 0.50

    min_step = 8 * 1024 * 1024
    max_step = 512 * 1024 * 1024

    try:
        while running and (ends is None or time.time() < ends.timestamp()):

            total_kb, used_kb = meminfo()

            managed = managed_kb()

            native_used = max(0, used_kb - managed)

            current_pct = used_kb / total_kb * 100
            native_pct = native_used / total_kb * 100
            managed_pct = managed / total_kb * 100

            p95 = None
            sample_count = 0
            coverage = 0
            if mode == "p95":
                now_epoch = time.time()
                now_mono = time.monotonic()
                bucket_sum += current_pct
                bucket_count += 1

                if now_mono - bucket_started >= HISTORY_SAMPLE_SECONDS:
                    minute_value = bucket_sum / max(1, bucket_count)
                    history = append_history(history, now_epoch, minute_value)
                    bucket_started = now_mono
                    bucket_sum = 0.0
                    bucket_count = 0
                else:
                    cutoff = now_epoch - WINDOW_SECONDS
                    history = [(t, v) for t, v in history if t >= cutoff]

                p95_values = [v for _, v in history]
                if bucket_count:
                    p95_values.append(bucket_sum / bucket_count)
                p95 = percentile(p95_values, 0.95)

                if p95_control == "SATISFIED":
                    if p95 < p95_resume_threshold(target):
                        p95_control = "BOOSTING"
                elif p95 >= p95_enter_threshold(target):
                    p95_control = "SATISFIED"

                sample_count = len(history)
                if history:
                    coverage = min(WINDOW_SECONDS, max(0, now_epoch - history[0][0]))

            effective_target = boost_target if mode == "p95" and p95_control == "BOOSTING" else target
            target_used_kb = int(
                total_kb * effective_target / 100
            )

            desired_managed_kb = max(
                0,
                target_used_kb - native_used,
            )

            if mode == "p95" and (p95_control == "SATISFIED" or native_pct >= target + P95_HYSTERESIS):
                desired_managed_kb = 0

            difference_kb = desired_managed_kb - managed

            realtime_target = effective_target if mode == "p95" else target
            lower = realtime_target - hysteresis
            upper = realtime_target + hysteresis

            if current_pct < lower and difference_kb > 0:

                deficit_bytes = difference_kb * 1024

                # Rapid but staged convergence.
                step = int(deficit_bytes * 0.60)

                step = max(min_step, step)
                step = min(max_step, step)
                step = min(step, deficit_bytes)

                allocate_bytes(step)

            elif (
                (mode == "p95" and difference_kb < 0)
                or (mode == "balance" and current_pct > upper and difference_kb < 0)
            ):

                excess_bytes = abs(difference_kb) * 1024

                step = int(excess_bytes * 0.60)

                step = max(min_step, step)
                step = min(max_step, step)
                step = min(step, managed * 1024)

                release_bytes(step)

            write_managed()

            total_kb, used_kb = meminfo()
            managed = managed_kb()

            native_used = max(
                0,
                used_kb - managed,
            )

            current_pct = used_kb / total_kb * 100
            native_pct = native_used / total_kb * 100
            managed_pct = managed / total_kb * 100

            remaining = (
                max(0, int(ends.timestamp() - time.time()))
                if ends is not None
                else None
            )

            write_test_state(
                target,
                duration,
                started,
                ends,
                mode=mode,
                p95=p95,
                sample_count=sample_count,
                coverage_seconds=coverage,
                control=p95_control if mode == "p95" else (
                    "BOOSTING" if current_pct < lower else
                    "YIELDING" if current_pct > upper else
                    "BALANCED"
                ),
                boost_target=boost_target if mode == "p95" else None,
            )

            print(
                f"usage={current_pct:.2f}% "
                f"native={native_pct:.2f}% "
                f"managed={managed_pct:.2f}% "
                + (
                    f"p95={p95:.2f}% target_p95={target:.2f}% boost_target={boost_target:.2f}% control={p95_control} "
                    if mode == "p95"
                    else f"target={target:.2f}% "
                )
                + (
                    f"remaining={remaining}s"
                    if remaining is not None
                    else "remaining=PERMANENT"
                ),
                flush=True,
            )

            # Faster convergence during ramp-up.
            control_target = boost_target if mode == "p95" and p95_control == "BOOSTING" else target
            if abs(current_pct - control_target) > 3:
                sleep_for = 2
            elif abs(current_pct - control_target) > 1:
                sleep_for = 3
            else:
                sleep_for = 5

            end_sleep = time.time() + sleep_for

            while running and time.time() < end_sleep:
                time.sleep(0.25)

    finally:
        cleanup()

        print(
            "memory test finished; managed memory released",
            flush=True,
        )


if __name__ == "__main__":
    main()
PY

chmod 755 "${STAGING}${MEMTEST}"

# ============================================================
# 5. CPU Test
# ============================================================

echo "[5/10] Installing CPU capacity/stress controller..."

cat > "${STAGING}${CPUTEST}" <<'PY'
#!/usr/bin/env python3
import json
import math
import multiprocessing as mp
import os
import signal
import time
from datetime import datetime, timezone

CONF = "/etc/resource-balancer-cpu.conf"
STATE = "/var/lib/resource-balancer/cpu-state"
HISTORY = "/var/lib/resource-balancer/cpu-p95-history.jsonl"

WINDOW_SECONDS = 7 * 24 * 3600
HISTORY_SAMPLE_SECONDS = 60
P95_HYSTERESIS = 0.50
BOOST_MARGIN = 5.0

running = True

def p95_enter_threshold(target):
    return min(80.0 - P95_HYSTERESIS, target + P95_HYSTERESIS)


def p95_resume_threshold(target):
    return min(target - P95_HYSTERESIS, p95_enter_threshold(target) - P95_HYSTERESIS)


def stop(*_):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

def load_config():
    data = {}
    with open(CONF) as f:
        for line in f:
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.strip().split("=", 1)
                data[k] = v
    return float(data["TARGET_PERCENT"]), int(data.get("DURATION_SECONDS", "0"))

def host_cpu_stat():
    values = list(map(int, open("/proc/stat").readline().split()[1:]))
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return sum(values), idle

def process_ticks(pid):
    try:
        text = open(f"/proc/{pid}/stat").read()
        fields = text[text.rfind(")") + 2:].split()
        return int(fields[11]) + int(fields[12])
    except (FileNotFoundError, ProcessLookupError, ValueError, IndexError):
        return 0

def burner(duty, alive):
    period = 0.10
    while alive.value:
        d = max(0.0, min(1.0, duty.value))
        start = time.perf_counter()
        busy_until = start + period * d
        x = 0
        while alive.value and time.perf_counter() < busy_until:
            x = (x * 1664525 + 1013904223) & 0xffffffff
        remaining = period - (time.perf_counter() - start)
        if remaining > 0:
            time.sleep(remaining)

def percentile(values, p):
    if not values:
        return 0.0
    xs = sorted(values)
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * p
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return xs[lo]
    frac = pos - lo
    return xs[lo] * (1.0 - frac) + xs[hi] * frac

def load_history(now_epoch):
    cutoff = now_epoch - WINDOW_SECONDS
    rows = []
    try:
        with open(HISTORY) as f:
            for line in f:
                try:
                    item = json.loads(line)
                    ts = float(item["ts"])
                    cpu = float(item["cpu"])
                    if math.isfinite(ts) and math.isfinite(cpu) and cutoff <= ts <= now_epoch and 0 <= cpu <= 100:
                        rows.append((ts, cpu))
                except (ValueError, KeyError, TypeError, json.JSONDecodeError):
                    continue
    except FileNotFoundError:
        pass
    rows.sort(key=lambda x: x[0])
    return rows

def save_history(rows):
    tmp = HISTORY + ".tmp"
    with open(tmp, "w") as f:
        for ts, cpu in rows:
            f.write(json.dumps({"ts": round(ts, 3), "cpu": round(cpu, 3)}) + "\n")
    os.replace(tmp, HISTORY)

def append_history(rows, ts, cpu):
    cutoff = ts - WINDOW_SECONDS
    rows = [(t, v) for t, v in rows if t >= cutoff]
    rows.append((ts, cpu))
    save_history(rows)
    return rows

def write_state(target, duration, started, ends, observed, native, managed,
                desired, duty, ncpu, p95, sample_count, coverage_seconds,
                control, boost_target):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({
            "target_percent": target,
            "duration_seconds": duration,
            "started_at": started.isoformat(),
            "ends_at": ends.isoformat() if ends else None,
            "pid": os.getpid(),
            "system_cpu_percent": round(observed, 2),
            "native_cpu_percent": round(native, 2),
            "managed_cpu_percent": round(managed, 2),
            "desired_managed_cpu_percent": round(desired, 2),
            "duty_per_core_percent": round(duty * 100, 2),
            "logical_cpus": ncpu,
            "p95_percent": round(p95, 2),
            "p95_target_percent": target,
            "p95_window_seconds": WINDOW_SECONDS,
            "p95_sample_interval_seconds": HISTORY_SAMPLE_SECONDS,
            "p95_sample_count": sample_count,
            "p95_coverage_seconds": int(max(0, coverage_seconds)),
            "control": control,
            "boost_target_percent": round(boost_target, 2),
        }, f)
    os.replace(tmp, STATE)

def main():
    global running
    target, duration = load_config()
    if not math.isfinite(target) or target < 5 or target > 80:
        raise SystemExit("target must be between 5 and 80")
    if duration != 0 and not 10 <= duration <= 86400:
        raise SystemExit("duration must be 0 (permanent) or between 10 seconds and 24 hours")

    started = datetime.now(timezone.utc)
    end_ts = time.time() + duration if duration else None
    ends = datetime.fromtimestamp(end_ts, tz=timezone.utc) if end_ts else None
    ncpu = max(1, os.cpu_count() or 1)
    clk = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
    boost_target = min(80.0, target + BOOST_MARGIN)

    history = load_history(time.time())
    control = "BOOSTING"

    ctx = mp.get_context("fork")
    alive = ctx.Value("b", 1)
    duty = ctx.Value("d", 0.0)
    workers = [ctx.Process(target=burner, args=(duty, alive), daemon=True) for _ in range(ncpu)]
    for worker in workers:
        worker.start()

    previous_total, previous_idle = host_cpu_stat()
    pids = [os.getpid()] + [w.pid for w in workers]
    previous_ticks = sum(process_ticks(pid) for pid in pids if pid)
    previous_wall = time.monotonic()

    bucket_started = time.monotonic()
    bucket_sum = 0.0
    bucket_count = 0

    try:
        while running and (end_ts is None or time.time() < end_ts):
            time.sleep(1.0)
            now_mono = time.monotonic()
            now_epoch = time.time()
            total, idle = host_cpu_stat()
            ticks = sum(process_ticks(pid) for pid in pids if pid)

            delta_total = total - previous_total
            delta_idle = idle - previous_idle
            elapsed = max(0.001, now_mono - previous_wall)
            observed = (1.0 - delta_idle / delta_total) * 100.0 if delta_total > 0 else 0.0
            managed = max(0.0, ((ticks - previous_ticks) / clk) / elapsed / ncpu * 100.0)
            native = max(0.0, observed - managed)

            bucket_sum += observed
            bucket_count += 1
            if now_mono - bucket_started >= HISTORY_SAMPLE_SECONDS:
                minute_cpu = bucket_sum / max(1, bucket_count)
                history = append_history(history, now_epoch, minute_cpu)
                bucket_started = now_mono
                bucket_sum = 0.0
                bucket_count = 0
            else:
                cutoff = now_epoch - WINDOW_SECONDS
                history = [(t, v) for t, v in history if t >= cutoff]

            # Include the current partial minute in the local estimate so a new
            # installation can react immediately instead of waiting seven days.
            p95_values = [v for _, v in history]
            if bucket_count:
                p95_values.append(bucket_sum / bucket_count)
            p95 = percentile(p95_values, 0.95)

            if control == "SATISFIED":
                if p95 < p95_resume_threshold(target):
                    control = "BOOSTING"
            else:
                if p95 >= p95_enter_threshold(target):
                    control = "SATISFIED"

            if control == "SATISFIED" or native >= target:
                desired = 0.0
                next_duty = 0.0
            else:
                desired = max(0.0, min(boost_target - native, boost_target))
                desired_duty = desired / 100.0
                error = boost_target - observed
                correction = max(-0.08, min(0.08, error * 0.012))
                commanded = max(0.0, min(boost_target / 100.0, desired_duty + correction))
                if abs(error) <= 1.0:
                    next_duty = 0.75 * duty.value + 0.25 * desired_duty
                else:
                    next_duty = 0.55 * duty.value + 0.45 * commanded

            duty.value = max(0.0, min(boost_target / 100.0, next_duty))

            if history:
                coverage = min(WINDOW_SECONDS, max(0.0, now_epoch - history[0][0]))
            else:
                coverage = 0.0

            write_state(
                target, duration, started, ends, observed, native, managed,
                desired, duty.value, ncpu, p95, len(history),
                coverage, control, boost_target,
            )

            print(
                f"usage={observed:.2f}% native={native:.2f}% managed={managed:.2f}% "
                f"p95={p95:.2f}% target_p95={target:.2f}% control={control} "
                f"duty/core={duty.value * 100:.2f}%",
                flush=True,
            )

            previous_total, previous_idle = total, idle
            previous_ticks = ticks
            previous_wall = now_mono
    finally:
        alive.value = 0
        duty.value = 0.0
        for worker in workers:
            worker.join(timeout=1)
        for worker in workers:
            if worker.is_alive():
                worker.terminate()
        try:
            os.remove(STATE)
        except FileNotFoundError:
            pass
        print("cpu P95 controller stopped; managed CPU released", flush=True)

if __name__ == "__main__":
    main()
PY

chmod 755 "${STAGING}${CPUTEST}"

# ============================================================
# 6. CLI
# ============================================================

echo "[6/10] Installing CLI..."

cat > "${STAGING}${BIN}" <<'PY'
#!/usr/bin/env python3

import csv
import json
import math
import os
import platform
import re
import shutil
import signal
import stat
import statistics
import subprocess
import sys
import tempfile
from collections import deque
from contextlib import contextmanager
from pathlib import Path
from datetime import datetime, timezone, timedelta

VERSION = "2.8.4"

DATA = "/var/lib/resource-balancer/metrics.csv"
STATE = "/var/lib/resource-balancer/memory-managed-kb"
TESTSTATE = "/var/lib/resource-balancer/memory-state"
MEMCONF = "/etc/resource-balancer-memory.conf"
CPUSTATE = "/var/lib/resource-balancer/cpu-state"
CPUHISTORY = "/var/lib/resource-balancer/cpu-p95-history.jsonl"
MEMHISTORY = "/var/lib/resource-balancer/memory-p95-history.jsonl"
CPUCONF = "/etc/resource-balancer-cpu.conf"
CONF = "/etc/resource-balancer.conf"

COLLECTOR_SERVICE = "resource-balancer-collector"
MEMTEST_SERVICE = "resource-balancer-memory"
CPUTEST_SERVICE = "resource-balancer-cpu"
SYSTEMD_CONTROL_DIRS = ("/etc/systemd/system.control", "/run/systemd/system.control")
STARTUP_SIGNALS = tuple(getattr(signal, name) for name in ("SIGINT", "SIGTERM", "SIGHUP") if hasattr(signal, name))


def execute(cmd, check=True):
    try:
        return subprocess.run(cmd, check=check)
    except KeyboardInterrupt:
        raise SystemExit(130) from None


def sudo_cmd(cmd):
    if os.geteuid() == 0:
        return cmd

    return ["sudo"] + cmd


def parse_duration(text):
    """Accept integer seconds or an s/m/h suffix; zero means permanent."""
    match = re.fullmatch(r"([0-9]{1,8})([smh]?)", text)
    if not match:
        raise ValueError("duration must be integer seconds or use s/m/h")
    value = int(match[1]) * {"": 1, "s": 1, "m": 60, "h": 3600}[match[2]]
    if value != 0 and not 10 <= value <= 86400:
        raise ValueError("duration must be 0 or between 10 seconds and 24 hours")
    return value


def p95_enter_threshold(target):
    return min(79.5, target + 0.50)


def p95_resume_threshold(target):
    return min(target - 0.50, p95_enter_threshold(target) - 0.50)


@contextmanager
def management_lock():
    """Serialize installation and CLI mutations without adding dependencies."""
    import fcntl
    import stat

    if os.geteuid() != 0:
        raise ValueError("management commands must be run with sudo")
    fd = os.open("/run/resource-balancer.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != 0 or info.st_mode & 0o022 or not stat.S_ISREG(info.st_mode):
            raise RuntimeError("unsafe management lock file")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("another Resource Balancer management operation is running") from None
        yield
    finally:
        os.close(fd)


def stop_service(service):
    """Never delete state while the service might still own live resources."""
    state = subprocess.run(
        ["systemctl", "show", service, "--property=LoadState,ActiveState"],
        capture_output=True, text=True, check=False,
    )
    properties = dict(line.split("=", 1) for line in state.stdout.splitlines() if "=" in line)
    if properties.get("LoadState") == "not-found" and properties.get("ActiveState") == "inactive":
        # A previous uninstall may already have removed the unit before failing.
        return
    state.check_returncode()
    subprocess.run(["systemctl", "disable", "--now", service], check=True)
    result = subprocess.run(
        ["systemctl", "show", service, "--property=ActiveState", "--value"],
        check=True, capture_output=True, text=True,
    )
    if result.stdout.strip() not in ("inactive", "failed"):
        raise RuntimeError(f"{service} has not stopped; state and configuration preserved")


def active(service):
    return subprocess.run(
        ["systemctl", "is-active", "--quiet", service],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


def atomic_write(path, data, mode=0o600):
    fd, temporary = tempfile.mkstemp(prefix=".resource-balancer-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.remove(temporary)
        except FileNotFoundError:
            pass


def file_snapshot(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise RuntimeError(f"expected regular configuration file: {path}")
    return Path(path).read_bytes(), stat.S_IMODE(info.st_mode)


class StartupInterrupted(KeyboardInterrupt):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"controller startup interrupted by signal {signum}")


def start_controller(service, config, settings, duration, quota=None):
    previous_handlers = {number: signal.getsignal(number) for number in STARTUP_SIGNALS}

    def interrupt(signum, frame):
        raise StartupInterrupted(signum)

    try:
        for number in STARTUP_SIGNALS:
            signal.signal(number, interrupt)
        return _start_controller(service, config, settings, duration, quota)
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)


def _start_controller(service, config, settings, duration, quota=None):
    """Restore persistent intent if any startup step fails, including interrupt."""
    previous = subprocess.run(["systemctl", "is-enabled", service], capture_output=True, text=True)
    enabled_state = previous.stdout.strip()
    if enabled_state not in ("enabled", "enabled-runtime", "disabled"):
        raise RuntimeError(f"cannot safely snapshot {service} enable state: {enabled_state}")
    if previous.returncode != (1 if enabled_state == "disabled" else 0):
        previous.check_returncode()
        raise RuntimeError(f"inconsistent enable state for {service}")
    state = subprocess.run(["systemctl", "show", service, "--property=ActiveState", "--value"],
                           check=True, capture_output=True, text=True)
    if state.stdout.strip() not in ("inactive", "failed"):
        raise RuntimeError(f"{service} is not stopped; configuration preserved")

    # D-Bus property writes use system.control. Preserve both layers exactly,
    # including absent files, instead of persisting a runtime quota by mistake.
    snapshots = {config: file_snapshot(config)}
    quota_directories = [Path(root) / (service + ".service.d") for root in SYSTEMD_CONTROL_DIRS] if quota is not None else []
    for directory in quota_directories:
        if directory.is_symlink():
            raise RuntimeError(f"unsafe quota directory: {directory}")
        for path in directory.glob("*.conf"):
            snapshots[str(path)] = file_snapshot(path)

    backup = tempfile.mkdtemp(prefix="resource-balancer-start-", dir=os.path.dirname(config))
    try:
        manifest = {"service": service, "enable_state": enabled_state, "files": []}
        for index, (path, snapshot) in enumerate(snapshots.items()):
            entry = {"path": path, "backup": None}
            if snapshot is not None:
                data, mode = snapshot
                filename = str(index)
                atomic_write(os.path.join(backup, filename), data, mode)
                entry.update(backup=filename, mode=mode)
            manifest["files"].append(entry)
        atomic_write(os.path.join(backup, "manifest.json"), json.dumps(manifest).encode("utf-8"))
    except BaseException:
        shutil.rmtree(backup)
        raise

    try:
        atomic_write(config, settings.encode("utf-8"))
        if quota is not None:
            subprocess.run(["systemctl", "set-property", service, f"CPUQuota={quota}%"], check=True)
        subprocess.run(["systemctl", "enable" if duration == 0 else "disable", service], check=True)
        subprocess.run(["systemctl", "start", service], check=True)
        state = subprocess.run(["systemctl", "show", service, "--property=ActiveState", "--value"],
                               check=True, capture_output=True, text=True)
        if state.stdout.strip() != "active":
            raise RuntimeError(f"{service} did not become active")
        # Startup is committed. Finish backup cleanup without turning a late
        # termination request into an apparent failure of a committed start.
        for number in STARTUP_SIGNALS:
            signal.signal(number, signal.SIG_IGN)
    except BaseException as start_error:
        # Let the first polite termination request finish recovery; repeated
        # INT/TERM/HUP must not interrupt restoration halfway through.
        for number in STARTUP_SIGNALS:
            signal.signal(number, signal.SIG_IGN)
        try:
            # A failed start can leave a process alive. Stop it before changing
            # the configuration beneath it; retain backups if stopping fails.
            subprocess.run(["systemctl", "stop", service], check=True)
            state = subprocess.run(["systemctl", "show", service, "--property=ActiveState", "--value"],
                                   check=True, capture_output=True, text=True)
            if state.stdout.strip() not in ("inactive", "failed"):
                raise RuntimeError(f"{service} has not stopped")
            subprocess.run(["systemctl", "disable", service], check=True)
            for directory in quota_directories:
                for path in directory.glob("*.conf"):
                    if str(path) not in snapshots:
                        path.unlink()
            for path, snapshot in snapshots.items():
                if snapshot is None:
                    try:
                        os.remove(path)
                    except FileNotFoundError:
                        pass
                else:
                    data, mode = snapshot
                    atomic_write(path, data, mode)
            if quota is not None:
                subprocess.run(["systemctl", "daemon-reload"], check=True)
            if enabled_state != "disabled":
                command = ["systemctl", "enable", service]
                if enabled_state == "enabled-runtime":
                    command.append("--runtime")
                subprocess.run(command, check=True)
        except BaseException as restore_error:
            raise RuntimeError(
                f"{service} startup failed; rollback incomplete: {restore_error}; backup retained at {backup}"
            ) from start_error
        else:
            try:
                shutil.rmtree(backup)
            except OSError as error:
                print(f"WARNING: state restored; backup cleanup failed at {backup}: {error}", file=sys.stderr)
        raise
    else:
        try:
            shutil.rmtree(backup)
        except OSError as error:
            print(f"WARNING: controller started; could not remove backup {backup}: {error}", file=sys.stderr)


def enabled(service):
    return subprocess.run(
        ["systemctl", "is-enabled", "--quiet", service],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


def sample_interval():
    value = 60
    try:
        with open(CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("SAMPLE_INTERVAL="):
                    candidate = int(line.split("=", 1)[1])
                    if candidate > 0:
                        value = candidate
    except Exception:
        pass
    return value


def boot_time():
    try:
        uptime = float(open("/proc/uptime").read().split()[0])
        return datetime.now(timezone.utc) - timedelta(seconds=uptime)
    except Exception:
        return None


def control_state(system, target, managed, tolerance):
    if target is None:
        return "IDLE"
    native = max(0.0, system - managed)
    if native > target + tolerance:
        return "YIELDING"
    deviation = system - target
    if abs(deviation) <= tolerance:
        return "BALANCED"
    if deviation < -tolerance:
        return "BOOSTING"
    return "YIELDING"


def percentile(values, p):
    if not values:
        return None

    values = sorted(values)

    k = (len(values) - 1) * p

    low = math.floor(k)
    high = math.ceil(k)

    if low == high:
        return values[low]

    return (
        values[low] * (high - k)
        + values[high] * (k - low)
    )


def load(hours=None, limit=None):
    if not os.path.exists(DATA):
        return []

    cutoff = None

    if hours is not None:
        cutoff = (
            datetime.now(timezone.utc)
            - timedelta(hours=hours)
        )

    rows = deque(maxlen=limit)

    try:
        with open(DATA, newline="") as f:
            reader = csv.DictReader(f)

            for row in reader:
                try:
                    ts = datetime.fromisoformat(
                        row["timestamp"]
                    )
                    if ts.tzinfo is None:
                        continue

                    if cutoff and ts < cutoff:
                        continue

                    memory = float(
                        row["memory_percent"]
                    )

                    native_raw = row.get(
                        "native_memory_percent",
                        "",
                    )

                    native = (
                        float(native_raw)
                        if native_raw
                        else memory
                    )

                    managed_raw = row.get(
                        "managed_memory_kb",
                        "0",
                    )

                    rows.append({
                        "timestamp": ts,
                        "cpu":
                            float(row["cpu_percent"]),
                        "memory":
                            memory,
                        "native":
                            native,
                        "managed_kb":
                            int(float(managed_raw or 0)),
                    })

                except Exception:
                    continue

    except OSError:
        raise

    return list(rows)


def memory_now():
    info = {}

    with open("/proc/meminfo") as f:
        for line in f:
            key, value = line.split(":", 1)
            info[key] = int(
                value.strip().split()[0]
            )

    total = info["MemTotal"]
    available = info["MemAvailable"]

    used = total - available

    return total, used, used / total * 100


def managed_now():
    if not active(MEMTEST_SERVICE):
        return 0
    try:
        with open(STATE) as f:
            return max(0, int(f.read().strip()))
    except Exception:
        return 0


def human_kb(kb):
    gib = kb / 1024 / 1024

    if gib >= 1:
        return f"{gib:.2f} GiB"

    return f"{kb / 1024:.0f} MiB"


def cpu_description():
    try:
        output = subprocess.check_output(
            ["lscpu"],
            text=True,
            stderr=subprocess.DEVNULL,
        )

        model = None
        vendor = None

        for line in output.splitlines():
            if line.startswith("Model name:"):
                model = line.split(
                    ":",
                    1,
                )[1].strip()

            elif line.startswith("Vendor ID:"):
                vendor = line.split(
                    ":",
                    1,
                )[1].strip()

        if model:
            return model

        if vendor:
            return vendor

    except Exception:
        pass

    if platform.machine() in (
        "aarch64",
        "arm64",
    ):
        return "ARM"

    return "Unknown"



def status():
    rows = load(limit=1)
    total, used, memory_pct = memory_now()
    managed_kb = managed_now()
    managed_pct = (managed_kb / total * 100) if total else 0.0
    native_pct = max(0.0, memory_pct - managed_pct)

    print("===== RESOURCE BALANCER =====")
    print(f"Version:         {VERSION}")
    print(f"Hostname:        {platform.node()}")
    print(f"Collector:       {'RUNNING' if active(COLLECTOR_SERVICE) else 'STOPPED'}")

    if rows:
        latest = rows[-1]
        age = max(0, (datetime.now(timezone.utc) - latest["timestamp"]).total_seconds())
        print(f"Sample age:      {int(age)} sec")
        print(f"Current CPU:     {latest['cpu']:.2f}%")
    else:
        print("Sample age:      NO DATA")
        print("Current CPU:     NO DATA")

    print(f"Memory usage:    {memory_pct:.2f}%")
    print(f"Managed memory:  {managed_pct:.2f}% ({human_kb(managed_kb)})")
    print(f"Native estimate: {native_pct:.2f}%")

    print()
    print("===== CONTROLLERS =====")
    print(
        "CPU:             "
        + ("RUNNING" if active(CPUTEST_SERVICE) else "IDLE")
        + (" / REBOOT ENABLED" if enabled(CPUTEST_SERVICE) else " / REBOOT DISABLED")
    )
    print(
        "Memory:          "
        + ("RUNNING" if active(MEMTEST_SERVICE) else "IDLE")
        + (" / REBOOT ENABLED" if enabled(MEMTEST_SERVICE) else " / REBOOT DISABLED")
    )

    print()
    print("Details:")
    print("  resource-balancer cpu status")
    print("  resource-balancer memory status")
    print("  resource-balancer health")

def inspect():
    total, used, pct = memory_now()

    print("===== SYSTEM =====")
    print(f"Version:         {VERSION}")
    print(f"Hostname:        {platform.node()}")
    print(f"Architecture:    {platform.machine()}")
    print(f"CPU:             {cpu_description()}")
    print(f"Logical CPUs:    {os.cpu_count()}")
    print(f"Kernel:          {platform.release()}")
    print(f"Memory total:    {human_kb(total)}")
    print(f"Memory used:     {human_kb(used)}")
    print(f"Memory usage:    {pct:.2f}%")

    try:
        virt = subprocess.check_output(
            ["systemd-detect-virt"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()

        print(f"Virtualization:  {virt}")

    except Exception:
        pass


def stats(rows):
    if not rows:
        return None

    cpu = [x["cpu"] for x in rows]
    memory = [x["memory"] for x in rows]
    native = [x["native"] for x in rows]

    return {
        "cpu_avg":
            statistics.fmean(cpu),
        "cpu_p95":
            percentile(cpu, .95),
        "cpu_max":
            max(cpu),

        "memory_avg":
            statistics.fmean(memory),
        "memory_p95":
            percentile(memory, .95),
        "memory_max":
            max(memory),

        "native_avg":
            statistics.fmean(native),
        "native_p95":
            percentile(native, .95),
        "native_max":
            max(native),
    }


def sample_interval():
    interval = 60
    try:
        with open(CONF) as f:
            for line in f:
                if line.startswith("SAMPLE_INTERVAL="):
                    interval = int(line.split("=", 1)[1].strip())
    except Exception:
        pass
    return max(10, interval)


def data_health(rows, hours):
    expected = max(1, int(hours * 3600 / sample_interval()))
    actual = len(rows)

    largest_gap = 0

    previous = None

    for row in rows:
        current = row["timestamp"]

        if previous is not None:
            gap = (
                current - previous
            ).total_seconds()

            largest_gap = max(
                largest_gap,
                gap,
            )

        previous = current

    completeness = (
        actual / expected * 100
        if expected
        else 0
    )

    if completeness >= 95:
        state = "COMPLETE"

    elif completeness >= 80:
        state = "PARTIAL"

    else:
        state = "WARMING UP"

    return (
        expected,
        actual,
        completeness,
        largest_gap,
        state,
    )


def print_stats(title, rows, hours):
    print()
    print(f"===== {title} =====")

    if not rows:
        print("No data.")
        return

    s = stats(rows)

    (
        expected,
        actual,
        completeness,
        largest_gap,
        state,
    ) = data_health(rows, hours)

    print(
        f"Samples:         "
        f"{actual} / {expected}"
    )

    print(
        f"Completeness:    "
        f"{min(completeness, 100):.2f}%"
    )

    print(f"Data status:     {state}")

    if largest_gap:
        print(
            f"Largest gap:     "
            f"{largest_gap / 60:.1f} min"
        )

    print()
    print("CPU:")
    print(f"  Avg:           {s['cpu_avg']:.2f}%")
    print(f"  P95:           {s['cpu_p95']:.2f}%")
    print(f"  Max:           {s['cpu_max']:.2f}%")

    print()
    print("Memory observed:")
    print(
        f"  Avg:           "
        f"{s['memory_avg']:.2f}%"
    )
    print(
        f"  P95:           "
        f"{s['memory_p95']:.2f}%"
    )
    print(
        f"  Max:           "
        f"{s['memory_max']:.2f}%"
    )

    print()
    print("Memory native estimate:")
    print(
        f"  Avg:           "
        f"{s['native_avg']:.2f}%"
    )
    print(
        f"  P95:           "
        f"{s['native_p95']:.2f}%"
    )
    print(
        f"  Max:           "
        f"{s['native_max']:.2f}%"
    )


def test_state():
    try:
        with open(TESTSTATE) as f:
            return json.load(f)
    except Exception:
        return None


def memory_status():
    total, used, usage = memory_now()
    managed = managed_now()
    native = max(0, used - managed)
    state = test_state()
    is_running = active(MEMTEST_SERVICE)

    print("===== MEMORY CONTROLLER =====")
    print("Status:          " + ("RUNNING" if is_running else "IDLE"))
    print("Reboot restore:  " + ("ENABLED" if enabled(MEMTEST_SERVICE) else "DISABLED"))
    print(f"System usage:    {usage:.2f}%")
    print(f"Managed memory:  {managed / total * 100:.2f}% ({human_kb(managed)})")
    print(f"Native estimate: {native / total * 100:.2f}% ({human_kb(native)})")

    if state:
        target = float(state.get("target_percent", 0))
        duration = int(state.get("duration_seconds", 0) or 0)
        permanent = duration == 0
        memory_mode = state.get("mode", "balance")

        print(f"Memory strategy: {memory_mode.upper()}")

        if memory_mode == "p95":
            p95 = float(state.get("p95_percent", 0) or 0)
            window = int(state.get("p95_window_seconds", 7 * 86400) or 7 * 86400)
            coverage = int(state.get("p95_coverage_seconds", 0) or 0)
            samples = int(state.get("p95_sample_count", 0) or 0)
            coverage_pct = min(100.0, coverage / window * 100.0) if window else 0.0
            control = state.get("control", "UNKNOWN")
            hold = " (hysteresis hold)" if control == "SATISFIED" and p95 < target else ""

            print(f"Target P95:      {target:.2f}%")
            print(f"Local P95 est.:  {p95:.2f}%")
            print(f"P95 deviation:   {p95 - target:+.2f} pp")
            print(f"Enter threshold:  {p95_enter_threshold(target):.2f}%")
            print(f"Resume threshold: {p95_resume_threshold(target):.2f}%")
            boost_target = float(state.get("boost_target_percent", min(80.0, target + 5.0)) or min(80.0, target + 5.0))
            print(f"Boost target:     {boost_target:.2f}%")
            print(f"Window:          {window // 86400} days rolling")
            print(f"Window coverage: {coverage_pct:.2f}% ({samples} completed 60s samples)")
            print(f"Control:         {control}{hold}")
            if coverage < window:
                print("Notice:          P95 window is still warming up; local estimate uses available samples.")
            print("OCI note:        Local estimate only; OCI performs the authoritative evaluation.")
        else:
            deviation = usage - target
            state_name = control_state(usage, target, managed / total * 100, 1.0)
            print(f"Target:          {target:.2f}%")
            print(f"Deviation:       {deviation:+.2f} pp")
            print(f"Control:         {state_name}")
            if native / total * 100 > target + 1.0:
                print("Notice:          TARGET BELOW NATIVE BASELINE; managed workload yields to zero.")

        print(f"Started:         {state.get('started_at')}")
        print("Mode:            " + ("PERMANENT" if permanent else "TIMED"))
        print("Duration:        " + ("PERMANENT" if permanent else f"{duration} sec"))
        print("Ends:            " + ("NEVER" if permanent else str(state.get("ends_at"))))


def memory_test(args):
    target = None
    duration = None
    memory_mode = "p95"
    i = 0
    while i < len(args):
        if args[i] == "--target" and i + 1 < len(args):
            target = float(args[i + 1])
            i += 2
        elif args[i] == "--duration" and i + 1 < len(args):
            duration = parse_duration(args[i + 1])
            i += 2
        elif args[i] == "--mode" and i + 1 < len(args):
            memory_mode = args[i + 1].lower()
            i += 2
        else:
            raise ValueError(f"unknown argument: {args[i]}")

    if target is None:
        raise ValueError("--target is required")
    if duration is None:
        duration = 0
    if not math.isfinite(target) or target < 5 or target > 80:
        raise ValueError("target must be between 5 and 80")
    if memory_mode not in ("p95", "balance"):
        raise ValueError("--mode must be p95 or balance")
    if os.geteuid() != 0:
        raise ValueError("memory test must be started with sudo")
    if active(MEMTEST_SERVICE):
        print("A memory test is already running.")
        return

    settings = f"TARGET_PERCENT={target}\nDURATION_SECONDS={duration}\nMEMORY_MODE={memory_mode}\n"
    start_controller(MEMTEST_SERVICE, MEMCONF, settings, duration)

    print()
    print("Memory controller started.")
    print(f"Strategy:        {memory_mode.upper()}")
    if memory_mode == "p95":
        print(f"Target P95:      {target:.1f}% (7-day rolling local estimate)")
        print("Load policy:     BOOST uses target+5pp samples; managed memory is released once P95 target is satisfied")
    else:
        print(f"Target:          {target:.1f}% (real-time dynamic balance)")
        print("Load policy:     managed memory continuously fills the gap to target")
    print("Mode:            " + ("PERMANENT" if duration == 0 else "TIMED"))
    print("Duration:        " + ("PERMANENT" if duration == 0 else f"{duration} sec"))
    print("Reboot restore:  " + ("ENABLED" if duration == 0 else "DISABLED"))
    print()
    print("Check: resource-balancer memory status")
    print("Logs:  sudo resource-balancer logs memory")
    print("Balance: sudo resource-balancer memory test --target 50 --mode balance")
    print("Stop:    sudo resource-balancer memory stop")


def memory_stop():
    if os.geteuid() != 0:
        raise ValueError("memory stop must be run with sudo")
    stop_service(MEMTEST_SERVICE)

    # Defensive state reset.
    if os.geteuid() == 0:
        with open(STATE, "w") as f:
            f.write("0")

    if os.geteuid() == 0:
        try:
            os.remove(MEMCONF)
        except FileNotFoundError:
            pass
        try:
            os.remove(TESTSTATE)
        except FileNotFoundError:
            pass

    print("Memory test stopped.")
    print("Managed memory released.")
    print("Reboot restore disabled.")


def memory_command(args):
    if not args:
        memory_status()
        return

    action = args[0]

    if action == "status":
        memory_status()

    elif action == "test":
        memory_test(args[1:])

    elif action == "stop":
        memory_stop()

    else:
        raise ValueError("Usage: resource-balancer memory status|test|stop")


def cpu_state():
    try:
        with open(CPUSTATE) as f:
            return json.load(f)
    except Exception:
        return None

def cpu_status():
    print("===== CPU P95 CONTROLLER =====")
    is_running = active(CPUTEST_SERVICE)
    print("Status:          " + ("RUNNING" if is_running else "IDLE"))
    print("Reboot restore:  " + ("ENABLED" if enabled(CPUTEST_SERVICE) else "DISABLED"))
    state = cpu_state()
    if state:
        duration = int(state.get("duration_seconds", 0) or 0)
        target = float(state.get("p95_target_percent", state.get("target_percent", 0)))
        p95 = float(state.get("p95_percent", 0))
        system = float(state.get("system_cpu_percent", 0))
        managed = float(state.get("managed_cpu_percent", 0))
        native = float(state.get("native_cpu_percent", 0))
        desired = float(state.get("desired_managed_cpu_percent", 0))
        coverage = int(state.get("p95_coverage_seconds", 0) or 0)
        samples = int(state.get("p95_sample_count", 0) or 0)
        window = int(state.get("p95_window_seconds", 7 * 86400) or 7 * 86400)
        coverage_pct = min(100.0, coverage / window * 100.0) if window else 0.0
        print(f"Target P95:      {target:.2f}%")
        print(f"Local P95 est.:  {p95:.2f}%")
        print(f"P95 deviation:   {p95 - target:+.2f} pp")
        print(f"Enter threshold:  {p95_enter_threshold(target):.2f}%")
        print(f"Resume threshold: {p95_resume_threshold(target):.2f}%")
        print(f"Window:          {window // 86400} days rolling")
        print(f"Window coverage: {coverage_pct:.2f}% ({samples} completed 60s samples)")
        print(f"Current CPU:     {system:.2f}%")
        print(f"Managed actual:  {managed:.2f}%")
        print(f"Native estimate: {native:.2f}%")
        print(f"Managed desired: {desired:.2f}%")
        control = state.get("control", "UNKNOWN")
        hold = " (hysteresis hold)" if control == "SATISFIED" and p95 < target else ""
        print(f"Control:         {control}{hold}")
        print(f"Duty/core:       {state.get('duty_per_core_percent', 0):.2f}%")
        print(f"Logical CPUs:    {state.get('logical_cpus')}")
        print("Mode:            " + ("PERMANENT" if duration == 0 else "TIMED"))
        print("Duration:        " + ("PERMANENT" if duration == 0 else f"{duration} sec"))
        print("Ends:            " + ("NEVER" if duration == 0 else str(state.get("ends_at"))))
        if coverage < window:
            print("Notice:          P95 window is still warming up; local estimate uses available samples.")
        print("OCI note:        Local estimate only; OCI performs the authoritative 7-day evaluation.")

def cpu_test(args):
    target = None
    duration = 0
    i = 0
    while i < len(args):
        if args[i] == "--target" and i + 1 < len(args):
            target = float(args[i + 1]); i += 2
        elif args[i] == "--duration" and i + 1 < len(args):
            duration = parse_duration(args[i + 1]); i += 2
        else:
            raise ValueError(f"unknown argument: {args[i]}")

    if target is None:
        raise ValueError("--target is required")
    if not math.isfinite(target) or target < 5 or target > 80:
        raise ValueError("target must be between 5 and 80")
    if os.geteuid() != 0:
        raise ValueError("cpu test must be started with sudo")
    if active(CPUTEST_SERVICE):
        print("A CPU test is already running.")
        return

    # CPUQuota uses 100% == one logical CPU. Convert whole-host percentage
    # into systemd quota and keep a 10-point safety margin, capped at 85%.
    ncpu = max(1, os.cpu_count() or 1)
    ceiling = min(85.0, target + 10.0)
    quota = max(1, int(ncpu * ceiling))
    settings = f"TARGET_PERCENT={target}\nDURATION_SECONDS={duration}\n"
    start_controller(CPUTEST_SERVICE, CPUCONF, settings, duration, quota)
    print("CPU P95 controller started.")
    print(f"Target P95:      {target:.1f}% (7-day rolling local estimate)")
    print("Mode:            " + ("PERMANENT" if duration == 0 else "TIMED"))
    print(f"CPU hard ceiling: {ceiling:.1f}% of whole host")
    print("Load policy:     synthetic CPU stops when P95 target is satisfied")
    print("Reboot restore:  " + ("ENABLED" if duration == 0 else "DISABLED"))

def cpu_stop():
    if os.geteuid() != 0:
        raise ValueError("cpu stop must be run with sudo")
    stop_service(CPUTEST_SERVICE)
    if os.geteuid() == 0:
        for path in (CPUCONF, CPUSTATE):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
    print("CPU P95 controller stopped.")
    print("Managed CPU released.")
    print("Reboot restore disabled.")

def cpu_command(args):
    if not args:
        cpu_status()
        return
    if args[0] == "status":
        cpu_status()
    elif args[0] == "test":
        cpu_test(args[1:])
    elif args[0] == "stop":
        cpu_stop()
    else:
        raise ValueError("Usage: resource-balancer cpu status|test|stop")

def health():
    issues = []
    warnings = []

    if not active(COLLECTOR_SERVICE):
        issues.append("collector service is not running")

    rows = load(limit=1)
    if rows:
        last = rows[-1]["timestamp"]
        age = max(0, (datetime.now(timezone.utc) - last).total_seconds())
        bt = boot_time()
        if bt and last < bt:
            warnings.append("collector has not written a post-boot sample yet")
        elif age > max(180, sample_interval() * 3):
            issues.append(f"collector sample is stale ({int(age)} sec)")
    else:
        warnings.append("no collector samples yet")

    for service, state_path, label in (
        (CPUTEST_SERVICE, CPUSTATE, "cpu"),
        (MEMTEST_SERVICE, TESTSTATE, "memory"),
    ):
        is_enabled = enabled(service)
        is_active = active(service)
        if is_enabled and not is_active:
            issues.append(f"{label} controller is enabled but stopped")
        if is_active and not os.path.exists(state_path):
            warnings.append(f"{label} controller is starting or state is missing")

    print("===== HEALTH =====")
    if issues:
        print("Overall:         DEGRADED")
    elif warnings:
        print("Overall:         WARMING UP")
    else:
        print("Overall:         OK")

    for item in issues:
        print("ERROR:           " + item)
    for item in warnings:
        print("NOTICE:          " + item)

    if not issues and not warnings:
        print("Collector:       OK")
        print("CPU controller:  " + ("RUNNING" if active(CPUTEST_SERVICE) else "IDLE"))
        print("Memory control:  " + ("RUNNING" if active(MEMTEST_SERVICE) else "IDLE"))
    return 1 if issues else 0


def logs(args):
    service = COLLECTOR_SERVICE
    if args not in ([], ["cpu"], ["memory"]):
        raise ValueError("logs accepts only cpu or memory")

    if args and args[0] == "memory":
        service = MEMTEST_SERVICE
    elif args and args[0] == "cpu":
        service = CPUTEST_SERVICE

    cmd = [
        "journalctl",
        "-u",
        service,
        "-f",
    ]

    # journal access commonly requires root.
    if os.geteuid() != 0:
        cmd = ["sudo"] + cmd

    try:
        subprocess.run(cmd, check=True)
    except KeyboardInterrupt:
        raise SystemExit(130) from None


def service_command(args):
    if not args:
        raise ValueError("service requires status|start|stop|restart")

    action = args[0]

    if action not in (
        "status",
        "start",
        "stop",
        "restart",
    ):
        raise ValueError("Invalid service action")

    cmd = [
        "systemctl",
        action,
        COLLECTOR_SERVICE,
    ]

    if action != "status":
        cmd = sudo_cmd(cmd)

    execute(cmd)


def history(period):
    if period == "1h":
        print_stats(
            "LAST 1 HOUR",
            load(1),
            1,
        )

    elif period == "24h":
        print_stats(
            "LAST 24 HOURS",
            load(24),
            24,
        )

    elif period == "7d":
        print_stats(
            "LAST 7 DAYS",
            load(168),
            168,
        )

    else:
        raise ValueError("history requires 1h|24h|7d")


def usage(topic=None):
    if topic == "cpu":
        print(f"""
Resource Balancer v{VERSION} - CPU P95 controller

  resource-balancer cpu status
      Show CPU P95 target, local estimate, native/managed CPU and controller state.

  sudo resource-balancer cpu test --target 25 [--duration 10m]
      Start the CPU P95 controller. --target is whole-host 7-day rolling CPU P95.
      Without --duration the controller is PERMANENT and restores after reboot.

  sudo resource-balancer cpu stop
      Stop the CPU controller and release synthetic CPU load.

Note: CPU has one strategy only (P95); there is no --mode option.
""")
        return

    if topic == "memory":
        print(f"""
Resource Balancer v{VERSION} - Memory controller

  resource-balancer memory status
      Show memory target, native/managed memory and controller state.

  sudo resource-balancer memory test --target 25 [--duration 10m]
      Start the default P95 memory controller.

  sudo resource-balancer memory test --target 50 --mode balance [--duration 10m]
      Start balance mode and dynamically fill toward the requested memory target.

  sudo resource-balancer memory stop
      Stop the memory controller and release managed memory.

Modes:
  p95      7-day rolling local P95 strategy (default).
  balance  Realtime target/fill capacity and memory-pressure strategy.
""")
        return

    if topic == "uninstall":
        print(f"""
Resource Balancer v{VERSION} - Uninstall

  sudo resource-balancer uninstall
      Stop/disable Resource Balancer services and remove the CLI, workers and
      systemd units. Preserve configuration, metrics, P95 history and state in:
        /etc/resource-balancer*.conf
        /var/lib/resource-balancer/

  sudo resource-balancer uninstall --purge
      Completely remove Resource Balancer, including configuration, metrics,
      P95 history and controller state. This data removal is irreversible.
""")
        return

    print(f"""
Resource Balancer v{VERSION}

Usage:
  resource-balancer [command]
  resource-balancer help [cpu|memory|uninstall]
  rb [command]  (short name for resource-balancer; same arguments)

Monitoring:
  resource-balancer status
      Current host summary and CPU/Memory controller state.
  resource-balancer inspect
      Detailed current resource and collector inspection.
  resource-balancer health
      Health check for collector and controllers.

History:
  resource-balancer history 1h
  resource-balancer history 24h
  resource-balancer history 7d
      Summarize collected resource history for the selected window.

CPU P95 controller:
  resource-balancer cpu status
  sudo resource-balancer cpu test --target 25 [--duration 10m]
  sudo resource-balancer cpu stop
      CPU target is whole-host 7-day rolling P95. CPU supports P95 only.

Memory controller:
  resource-balancer memory status
  sudo resource-balancer memory test --target 25 [--duration 10m]
  sudo resource-balancer memory test --target 50 --mode balance [--duration 10m]
  sudo resource-balancer memory stop
      Memory defaults to P95; --mode balance enables realtime target/fill mode.

Logs:
  resource-balancer logs
  resource-balancer logs cpu
  resource-balancer logs memory
      Follow collector/CPU/Memory systemd journal output.

Collector service:
  resource-balancer service status
  sudo resource-balancer service start
  sudo resource-balancer service stop
  sudo resource-balancer service restart

Version/help:
  resource-balancer version
  resource-balancer --version
  resource-balancer help
  resource-balancer --help
  resource-balancer help cpu
  resource-balancer help memory
  resource-balancer help uninstall

Uninstall:
  sudo resource-balancer uninstall
      Remove program/services; PRESERVE config, metrics, history and state.
  sudo resource-balancer uninstall --purge
      Remove program/services AND all Resource Balancer config/data/history.

Notes:
  - Local P95 is an estimate; OCI performs the authoritative evaluation.
  - Permanent CPU/Memory controllers restore after reboot while enabled.
""")


def remove_cpu_quota():
    """Remove our canonical property without deleting administrator drop-ins."""
    for root in SYSTEMD_CONTROL_DIRS:
        directory = Path(root) / (CPUTEST_SERVICE + ".service.d")
        if Path(root).is_symlink() or directory.is_symlink():
            raise RuntimeError(f"unsafe quota directory: {directory}")
        path = directory / "50-CPUQuota.conf"
        snapshot = file_snapshot(str(path))
        if snapshot is None:
            continue
        data, mode = snapshot
        try:
            lines = data.decode("utf-8").splitlines(keepends=True)
        except UnicodeDecodeError as error:
            raise RuntimeError(f"cannot safely read quota configuration: {path}") from error
        section = None
        kept = []
        removed = False
        has_other_settings = False
        for index, line in enumerate(lines):
            text = line.strip()
            if index == 0:
                text = text.lstrip("\ufeff")
            if not text or text.startswith(("#", ";")):
                kept.append(line)
                continue
            # Generated property files are single-line assignments. Refuse
            # edited continuations rather than risk changing their meaning.
            if text.endswith("\\"):
                raise RuntimeError(f"multiline quota configuration preserved; review manually: {path}")
            header = re.fullmatch(r"\[([^\]]+)\]", text)
            if header:
                section = header[1]
            elif section == "Service" and re.match(r"CPUQuota\s*=", text):
                removed = True
                continue
            else:
                has_other_settings = True
            kept.append(line)
        if not removed:
            continue
        if has_other_settings:
            atomic_write(str(path), "".join(kept).encode("utf-8"), mode)
        else:
            path.unlink()


def uninstall(args):
    purge = False
    if args:
        if args == ["--purge"]:
            purge = True
        else:
            raise ValueError("Usage: sudo resource-balancer uninstall [--purge]")

    if os.geteuid() != 0:
        raise ValueError("uninstall requires sudo")

    services = [
        CPUTEST_SERVICE,
        MEMTEST_SERVICE,
        COLLECTOR_SERVICE,
    ]
    units = [
        "/etc/systemd/system/resource-balancer-cpu.service",
        "/etc/systemd/system/resource-balancer-memory.service",
        "/etc/systemd/system/resource-balancer-collector.service",
    ]

    # Refresh cached LoadState before a retry after partially removed units.
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    print("Stopping and disabling Resource Balancer services...")
    for service in services:
        stop_service(service)

    # Finish quota cleanup before removing the CLI or units, so a partial
    # failure is visible and the same uninstall command can safely be retried.
    remove_cpu_quota()
    print("Removing CLI, workers and systemd units...")
    subprocess.run(["rm", "-rf", "/usr/local/lib/resource-balancer"], check=True)
    subprocess.run(["rm", "-f", *units], check=True)
    subprocess.run(["systemctl", "daemon-reload"], check=True)

    if purge:
        print("Purging Resource Balancer configuration and persistent data...")
        subprocess.run([
            "rm", "-f",
            "/etc/resource-balancer.conf",
            "/etc/resource-balancer-cpu.conf",
            "/etc/resource-balancer-memory.conf",
        ], check=True)
        subprocess.run(["rm", "-rf", "/var/lib/resource-balancer"], check=True)
    # Only remove our shortcut; preserve an unrelated command installed later.
    shortcut = Path("/usr/local/bin/rb")
    if (not shortcut.is_symlink() and shortcut.is_file()
            and shortcut.read_bytes() == b'#!/bin/sh\nexec /usr/local/bin/resource-balancer "$@"\n'):
        subprocess.run(["rm", "-f", str(shortcut)], check=True)
    # Keep the CLI available for retry until all other removals succeed.
    subprocess.run(["rm", "-f", "/usr/local/bin/resource-balancer"], check=True)
    if purge:
        print("Resource Balancer completely removed (PURGE).")
    else:
        print("Resource Balancer program removed.")
        print("Preserved:")
        print("  /etc/resource-balancer*.conf")
        print("  /var/lib/resource-balancer/")
        print("To remove preserved data later:")
        print("  sudo rm -f /etc/resource-balancer*.conf")
        print("  sudo rm -rf /var/lib/resource-balancer")

def main():
    if len(sys.argv) == 1:
        status()
        return

    cmd = sys.argv[1]
    if cmd in ("status", "inspect", "health", "version", "--version") and len(sys.argv) != 2:
        raise ValueError(f"{cmd} takes no arguments")

    if cmd in ("help", "--help", "-h"):
        usage(sys.argv[2] if len(sys.argv) > 2 else None)

    elif cmd == "status":
        status()

    elif cmd == "inspect":
        inspect()

    elif cmd == "health":
        return health()

    elif cmd == "history":
        if len(sys.argv) < 3:
            raise ValueError("history requires 1h|24h|7d")
        else:
            history(sys.argv[2])

    elif cmd == "memory":
        memory_command(sys.argv[2:])

    elif cmd == "cpu":
        cpu_command(sys.argv[2:])

    elif cmd == "logs":
        logs(sys.argv[2:])

    elif cmd == "service":
        service_command(sys.argv[2:])

    elif cmd == "uninstall":
        uninstall(sys.argv[2:])

    elif cmd in (
        "--version",
        "version",
    ):
        print(VERSION)

    else:
        usage()
        return 2
    return 0


def run():
    args = sys.argv[1:]
    mutating = bool(args) and (
        args[0] == "uninstall"
        or (len(args) >= 2 and args[0] in ("cpu", "memory") and args[1] in ("test", "stop"))
        or (len(args) >= 2 and args[0] == "service" and args[1] in ("start", "stop", "restart"))
    )
    if mutating:
        with management_lock():
            return main()
    return main()


if __name__ == "__main__":
    try:
        sys.exit(run())
    except (ValueError, IndexError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(2)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
    except StartupInterrupted as error:
        sys.exit(128 + error.signum)
    except KeyboardInterrupt:
        sys.exit(130)
PY

chmod 755 "${STAGING}${BIN}"

# A real executable works in sudo and non-interactive shells without shell aliases.
cat > "${STAGING}${SHORT_BIN}" <<'SH'
#!/bin/sh
exec /usr/local/bin/resource-balancer "$@"
SH
chmod 755 "${STAGING}${SHORT_BIN}"
if [[ -e "$SHORT_BIN" ]] && ! cmp -s "$SHORT_BIN" "${STAGING}${SHORT_BIN}"; then
    die "$SHORT_BIN is already used by another command; refusing to overwrite it"
fi

# ============================================================
# 6. Collector systemd
# ============================================================

echo "[7/10] Installing services..."

cat > "${STAGING}${COLLECTOR_UNIT}" <<EOF
[Unit]
Description=Resource Balancer Metrics Collector

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${COLLECTOR}

Restart=on-failure
RestartSec=10

Nice=15
OOMScoreAdjust=500

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

ReadWritePaths=${DATADIR}

[Install]
WantedBy=multi-user.target
EOF

cat > "${STAGING}${MEMTEST_UNIT}" <<EOF
[Unit]
Description=Resource Balancer Memory P95/Balance Controller
After=resource-balancer-collector.service
ConditionPathExists=${MEMCONF}

[Service]
Type=simple
EnvironmentFile=${MEMCONF}
ExecStart=/usr/bin/python3 ${MEMTEST}
Restart=on-failure
RestartSec=5
Nice=19
OOMScoreAdjust=900
MemoryHigh=82%
MemoryMax=85%
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${DATADIR}

[Install]
WantedBy=multi-user.target
EOF

cat > "${STAGING}${CPUTEST_UNIT}" <<EOF
[Unit]
Description=Resource Balancer CPU 7-Day P95 Controller
After=resource-balancer-collector.service
ConditionPathExists=${CPUCONF}

[Service]
Type=simple
EnvironmentFile=${CPUCONF}
ExecStart=/usr/bin/python3 ${CPUTEST}
Restart=on-failure
RestartSec=5
Nice=19
CPUWeight=1
OOMScoreAdjust=500
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${DATADIR}

[Install]
WantedBy=multi-user.target
EOF

# ============================================================
# 7. Reload / restart
# ============================================================

echo "[8/10] Restarting collector..."

# Validate all generated Python before stopping any existing service.
python3 -m py_compile "${STAGING}${COLLECTOR}" "${STAGING}${MEMTEST}" \
    "${STAGING}${CPUTEST}" "${STAGING}${BIN}"
for target in "${TARGETS[@]}"; do
    mkdir -p "${STAGING}/backup$(dirname "$target")"
    if [[ -f "$target" ]]; then
        cp -p "$target" "${STAGING}/backup${target}"
    fi
done
TRANSACTION_STARTED=1
for i in "${!SERVICES[@]}"; do
    if [[ "${WAS_ACTIVE[i]}" -eq 1 ]]; then
        systemctl stop "${SERVICES[i]}"
    fi
done
[[ -d "$LIBDIR" ]] || install -d -m 755 "$LIBDIR"
[[ -d "$DATADIR" ]] || install -d -m 755 "$DATADIR"
for target in "${TARGETS[@]}"; do
    # Rename from the destination filesystem so each file replacement is atomic.
    install -m "$(stat -c '%a' "${STAGING}${target}")" \
        "${STAGING}${target}" "${target}.install-tmp"
    mv -f "${target}.install-tmp" "$target"
done
if [[ ! -f "$STATE" ]]; then
    printf '0\n' > "$STATE"
fi

systemctl daemon-reload

systemctl enable resource-balancer-collector >/dev/null
systemctl restart resource-balancer-collector

# Restore the exact controller enable/active intent from a canonical v2.8.0
# reinstall. Fresh installs leave both optional controllers disabled and stopped.
if [[ "${WAS_ENABLED[2]}" -eq 1 && -f "$CPUCONF" ]]; then
    systemctl enable resource-balancer-cpu >/dev/null
else
    systemctl disable resource-balancer-cpu >/dev/null
fi
if [[ "${WAS_ACTIVE[2]}" -eq 1 && -f "$CPUCONF" ]]; then
    systemctl restart resource-balancer-cpu
fi

if [[ "${WAS_ENABLED[1]}" -eq 1 && -f "$MEMCONF" ]]; then
    systemctl enable resource-balancer-memory >/dev/null
else
    systemctl disable resource-balancer-memory >/dev/null
fi
if [[ "${WAS_ACTIVE[1]}" -eq 1 && -f "$MEMCONF" ]]; then
    systemctl restart resource-balancer-memory
fi

# ============================================================
# 8. Verify
# ============================================================

echo "[9/10] Verifying installation..."

sleep 2

PID="$(
    systemctl show resource-balancer-collector \
    -p MainPID \
    --value
)"

[[ -n "$PID" && "$PID" != "0" ]] \
    || die "collector failed to start"

CMDLINE="$(
    tr '\0' ' ' < "/proc/${PID}/cmdline"
)"

[[ "$CMDLINE" == *"$COLLECTOR"* ]] \
    || die "unexpected collector process: $CMDLINE"

for i in 1 2; do
    if [[ "${WAS_ACTIVE[i]}" -eq 1 ]]; then
        systemctl is-active --quiet "${SERVICES[i]}" \
            || die "controller failed to resume: ${SERVICES[i]}"
    fi
done
INSTALL_COMPLETE=1

# ============================================================
# 9. Finish
# ============================================================

echo "[10/10] Complete."
echo
echo "============================================================"
echo " Resource Balancer v${VERSION} installed"
echo "============================================================"
echo
echo "Collector PID:"
echo "  $PID"
echo
echo "Collector CMD:"
echo "  $CMDLINE"
echo
echo "Persistent data preserved/initialized:"
echo "  $DATA"
echo
echo "Memory controller:"
systemctl is-active resource-balancer-memory 2>/dev/null || true
echo
echo "CPU controller:"
systemctl is-active resource-balancer-cpu 2>/dev/null || true
echo
echo "Status:"
echo "  resource-balancer status"
echo "  resource-balancer health"
echo
echo "Permanent 25% memory P95 mode:"
echo
echo "  sudo resource-balancer memory test --target 25"
echo
echo "10-minute 25% memory P95 test:"
echo
echo "  sudo resource-balancer memory test \\"
echo "      --target 25 --duration 10m"
echo
echo "Stop early:"
echo "  sudo resource-balancer memory stop"
echo

finish_install 0
)

_resource_balancer_installer_launch() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        resource_balancer_installer_main
        return $?
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        printf 'ERROR: sudo is required when installing as a non-root user.\n' >&2
        return 1
    fi

    local _rb_func
    _rb_func="$(declare -f resource_balancer_installer_main)"
    sudo bash -c "${_rb_func}"$'\nresource_balancer_installer_main'
}

_resource_balancer_installer_finish() {
    local rc=$1
    unset -f resource_balancer_installer_main _resource_balancer_installer_launch \
        _resource_balancer_installer_finish 2>/dev/null || true
    # A function return preserves failure for scripts/pipes without exiting SSH.
    return "$rc"
}

_resource_balancer_installer_launch
_resource_balancer_installer_finish "$?"
