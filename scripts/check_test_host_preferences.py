#!/usr/bin/env python3
"""Fail when a unit-test run or a screenshot run changed the app's own preferences.

The tests run inside the app, which has the bundle identifier of the installed copy.
TestHostIsolation gives every test run its own preferences domain, and screenshot runs use
com.schneidervvv.dictum.screenshots (ScreenshotPreferencesIsolation); these checks prove that
no write reached the app's domains anyway.

    check_test_host_preferences.py snapshot STATE_FILE   # before the tests
    check_test_host_preferences.py verify STATE_FILE     # after the tests
    check_test_host_preferences.py screenshot-run APP [STATE]

screenshot-run starts APP (a Debug build) with --store-screenshots in a throwaway home,
waits until the Settings window is ready, quits it and compares the app's domains before
and after. It also watches the domain of APP's bundle identifier, so a copy with its own
identifier can be checked while other copies of the Dev app run.

Only key names and value digests are stored and printed, never values.
"""

import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time

DOMAINS = ("com.schneidervvv.dictum.dev", "com.schneidervvv.dictum")
SCREENSHOT_DOMAIN = "com.schneidervvv.dictum.screenshots"
SCREENSHOT_READY_TIMEOUT = 180


def digests(domain: str) -> dict:
    exported = subprocess.run(
        ["/usr/bin/defaults", "export", domain, "-"],
        check=True,
        capture_output=True,
    ).stdout
    values = plistlib.loads(exported)
    return {
        key: hashlib.sha256(plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True)).hexdigest()
        for key, value in values.items()
    }


def snapshot(domains=DOMAINS) -> dict:
    return {domain: digests(domain) for domain in domains}


def changes(before: dict, after: dict) -> list:
    lines = []
    for domain in sorted(before.keys() | after.keys()):
        old, new = before.get(domain, {}), after.get(domain, {})
        for key in sorted(old.keys() | new.keys()):
            if key not in old:
                lines.append(f"{domain}: added {key}")
            elif key not in new:
                lines.append(f"{domain}: removed {key}")
            elif old[key] != new[key]:
                lines.append(f"{domain}: changed {key}")
    return lines


def wait_for_window(process: subprocess.Popen, ready_file: str) -> None:
    deadline = time.monotonic() + SCREENSHOT_READY_TIMEOUT
    while time.monotonic() < deadline:
        if os.path.isfile(ready_file):
            with open(ready_file, encoding="utf-8") as handle:
                if handle.read().strip().isdigit():
                    return
        if process.poll() is not None:
            raise RuntimeError(f"the app exited with status {process.returncode} before its window was ready")
        time.sleep(0.2)
    raise RuntimeError("timed out waiting for the screenshot window")


def screenshot_run(app_path: str, state: str) -> int:
    with open(os.path.join(app_path, "Contents", "Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    executable = os.path.join(app_path, "Contents", "MacOS", info["CFBundleExecutable"])
    domains = tuple(sorted((set(DOMAINS) | {info["CFBundleIdentifier"]}) - {SCREENSHOT_DOMAIN}))

    # The throwaway home only moves NSHomeDirectory(): UserDefaults still writes through
    # cfprefsd to ~/Library/Preferences of the real home, so the snapshots read that.
    # A main build fails this check that way (see #1665).
    before = snapshot(domains)
    with tempfile.TemporaryDirectory(prefix="typewhisper-screenshot-check-") as run_directory:
        home = os.path.join(run_directory, "home")
        os.makedirs(home)
        ready_file = os.path.join(run_directory, "window-ready.txt")
        log_path = os.path.join(run_directory, "application.log")
        with open(log_path, "w", encoding="utf-8") as log:
            process = subprocess.Popen(
                [
                    executable,
                    "--store-screenshots",
                    "--screenshot-state", state,
                    "--screenshot-ready-file", ready_file,
                    "-setupWizardCompleted", "YES",
                    "-ApplePersistenceIgnoreState", "YES",
                ],
                env=dict(os.environ, CFFIXED_USER_HOME=home),
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            try:
                wait_for_window(process, ready_file)
                # Settings that are written after the window appeared count as well.
                time.sleep(3)
            except RuntimeError as error:
                with open(log_path, encoding="utf-8", errors="replace") as handle:
                    tail = handle.readlines()[-40:]
                print(f"Screenshot run failed: {error}", file=sys.stderr)
                print("".join(tail), file=sys.stderr)
                return 1
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

    found = changes(before, snapshot(domains))
    if found:
        print("The screenshot run changed the app's own preferences:", file=sys.stderr)
        print("\n".join(found), file=sys.stderr)
        return 1
    print(f"The screenshot run left {', '.join(domains)} unchanged.")
    return 0


def main(arguments: list) -> int:
    if len(arguments) in (2, 3) and arguments[0] == "screenshot-run":
        return screenshot_run(arguments[1], arguments[2] if len(arguments) == 3 else "general")

    if len(arguments) != 2 or arguments[0] not in ("snapshot", "verify"):
        print(__doc__.strip(), file=sys.stderr)
        return 2

    command, state_file = arguments
    if command == "snapshot":
        with open(state_file, "w", encoding="utf-8") as handle:
            json.dump(snapshot(), handle)
        return 0

    with open(state_file, encoding="utf-8") as handle:
        before = json.load(handle)
    found = changes(before, snapshot())
    if found:
        print("The test run changed the app's own preferences:", file=sys.stderr)
        print("\n".join(found), file=sys.stderr)
        return 1
    print("The test run left the app's own preferences unchanged.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
