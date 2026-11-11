#!/usr/bin/env python3
"""Run the app's isolated native integration check and inspect its result."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--root", type=Path, required=True)
args = parser.parse_args()
app, root = args.app.resolve(), args.root.resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
root.mkdir(parents=True, exist_ok=True)
result_file = root / "results/ui-results.json"
if result_file.exists():
    raise SystemExit("Use a fresh check directory to avoid reading a stale report.")
with (root / "launch.log").open("wb") as log:
    process = subprocess.Popen([
        str(app / "Contents/MacOS" / info["CFBundleExecutable"]),
        "--qa", "--data-root", str(root / "projects"),
        "--ui-check", str(root / "results"),
    ], stdout=log, stderr=log)
    timed_out = False
    try:
        process.wait(timeout=40)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
if not result_file.exists():
    raise SystemExit("The app did not write an integration report; inspect launch.log.")
result = json.loads(result_file.read_text())
print(json.dumps(result, ensure_ascii=False, indent=2))
raise SystemExit(0 if result.get("passed") and process.returncode == 0 and not timed_out else 1)
