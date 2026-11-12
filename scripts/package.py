#!/usr/bin/env python3
"""Package only explicit public build inputs; never include projects or source scans."""
import argparse
import hashlib
import json
import plistlib
import shutil
import stat
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--release-dir", type=Path, default=root / "release")
release = parser.parse_args().release_dir.resolve()
app = release / "拾页.app"
version = plistlib.loads((root / "scripts/Info.plist").read_bytes())["CFBundleShortVersionString"]
assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == version


def archive(paths, destination, base):
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in paths:
            files = [path] if path.is_file() else sorted(path.rglob("*"))
            for file in files:
                if not file.is_file() or file.name == ".DS_Store" or file.is_symlink():
                    continue
                z.write(file, file.relative_to(base))


archive([app], release / f"拾页-{version}-macOS-arm64.zip", release)
sources = [root / p for p in ["Package.swift", ".gitignore", "README.md", "LICENSE", "Sources", "Tests", "scripts", "docs", "samples"]]
archive(sources, release / f"拾页-{version}-source.zip", root)
shutil.copyfile(root / "docs/使用说明.txt", release / f"拾页-{version}-使用说明.txt")
validation = root / f"docs/RELEASE-{version}.md"
if not validation.exists():
    validation = root / "docs/VALIDATION.md"
shutil.copyfile(validation, release / f"拾页-{version}-验证记录.md")
sizes = {"app_bytes": sum(p.stat().st_size for p in app.rglob("*") if p.is_file()),
         "app_zip_bytes": (release / f"拾页-{version}-macOS-arm64.zip").stat().st_size,
         "source_zip_bytes": (release / f"拾页-{version}-source.zip").stat().st_size}
assert sizes["app_bytes"] <= 30_000_000 and sizes["app_zip_bytes"] <= 15_000_000, sizes
manifest = []
for file in sorted(release.iterdir()):
    if file.is_file() and file.name.startswith(f"拾页-{version}-") and file.suffix in [".zip", ".txt", ".md"]:
        manifest.append({"file": file.name, "bytes": file.stat().st_size, "sha256": hashlib.sha256(file.read_bytes()).hexdigest()})
(release / "SHA256SUMS.txt").write_text("".join(f"{m['sha256']}  {m['file']}\n" for m in manifest))
(release / "manifest.json").write_text(json.dumps({"version":version, "sizes":sizes, "files":manifest}, ensure_ascii=False, indent=2)+"\n")
with zipfile.ZipFile(release / f"拾页-{version}-macOS-arm64.zip") as z:
    assert all(n.startswith("拾页.app/") for n in z.namelist())
    assert not any(n.endswith((".pdf", ".shiyebook", ".json")) for n in z.namelist())
    binary = z.getinfo("拾页.app/Contents/MacOS/Shiye")
    assert (binary.external_attr >> 16) & stat.S_IXUSR
print(json.dumps(sizes, indent=2))
