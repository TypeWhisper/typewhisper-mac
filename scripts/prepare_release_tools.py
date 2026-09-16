#!/usr/bin/env python3
"""Prepare hash-locked release tools before any signing credentials are imported."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent
SWIFT_LOCK = Path("TypeWhisper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")


def sparkle_lock(root):
    lock = json.loads((root / ".github/release-tools/sparkle.json").read_text())
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", lock["version"]):
        raise ValueError("Invalid Sparkle version")
    if not re.fullmatch(r"[0-9a-f]{64}", lock["sha256"]):
        raise ValueError("Invalid Sparkle SHA-256")
    pins = json.loads((root / SWIFT_LOCK).read_text())["pins"]
    versions = [pin["state"].get("version") for pin in pins if pin["identity"] == "sparkle"]
    if versions != [lock["version"]]:
        raise ValueError("Sparkle tools must match the app's Package.resolved version")
    return lock


def prepare_sparkle(directory, lock):
    archive = directory / "sparkle.tar.xz"
    url = ("https://github.com/sparkle-project/Sparkle/releases/download/"
           f"{lock['version']}/Sparkle-{lock['version']}.tar.xz")
    subprocess.run([
        "curl", "--fail", "--show-error", "--silent", "--location",
        "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
        "--retry", "3", "--output", str(archive), url,
    ], check=True)
    with archive.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != lock["sha256"]:
        raise ValueError("Sparkle archive SHA-256 mismatch; refusing to extract or execute it")
    destination = directory / "sparkle"
    destination.mkdir()
    subprocess.run(["tar", "-xf", str(archive), "-C", str(destination)], check=True)
    subprocess.run([str(destination / "bin/sign_update"), "--help"], check=True)


def prepare(directory, root=ROOT):
    # Reject lock drift before downloading or executing anything.
    lock = sparkle_lock(root)
    directory.mkdir(parents=True, exist_ok=False)
    prepare_sparkle(directory, lock)
    venv = directory / "dmgbuild-venv"
    subprocess.run(["python3", "-m", "venv", str(venv)], check=True)
    python = str(venv / "bin/python")
    subprocess.run([
        python, "-m", "pip", "--isolated", "--disable-pip-version-check",
        "install", "--no-cache-dir", "--index-url", "https://pypi.org/simple",
        "--require-hashes", "--only-binary=:all:",
        "-r", str(root / ".github/release-tools/requirements.txt"),
    ], check=True)
    subprocess.run([python, "-m", "pip", "--isolated", "--disable-pip-version-check", "check"], check=True)
    subprocess.run([str(venv / "bin/dmgbuild"), "--help"], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.tools_dir.resolve())
