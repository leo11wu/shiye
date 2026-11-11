#!/usr/bin/env python3
"""Check the real app's production settings path, without --qa or UI test arguments."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--report", type=Path, required=True)
parser.add_argument("--seconds", type=float, default=8)
args = parser.parse_args()
app = args.app.resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
results = []
for attempt in range(2):
    env = dict(os.environ, SHIYE_STARTUP_CHECK="1")
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen([str(binary)], stdout=output, stderr=output, env=env)
        started = time.monotonic()
        while time.monotonic() - started < args.seconds and process.poll() is None:
            time.sleep(0.1)
        running = process.poll() is None
        if running:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        output.seek(0)
        log = output.read().decode("utf-8", errors="replace")
        results.append({
            "attempt": attempt + 1,
            "main_window_ready": "SHIYE_MAIN_WINDOW_READY" in log,
            "remained_running": running,
            "observed_seconds": round(time.monotonic() - started, 2),
            "crash_exit_code": None if running else process.returncode,
            "own_bundle_suite_warning": "own bundle identifier as an NSUserDefaults suite" in log,
        })
report = {
    "version": info["CFBundleShortVersionString"],
    "bundle_id": info["CFBundleIdentifier"],
    "method": "actual app launch and relaunch; no --qa or --ui-check; standard settings",
    "checks": results,
    "passed": all(r["main_window_ready"] and r["remained_running"] and not r["own_bundle_suite_warning"] for r in results),
}
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(0 if report["passed"] else 1)
