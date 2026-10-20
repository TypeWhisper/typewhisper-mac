#!/usr/bin/env python3
"""Fail when a unit-test run changed the app's own preferences.

The tests run inside the app, which has the bundle identifier of the installed copy.
TestHostIsolation gives every run its own preferences domain; this check proves that
no write reached the app's domains anyway.

    check_test_host_preferences.py snapshot STATE_FILE   # before the tests
    check_test_host_preferences.py verify STATE_FILE     # after the tests

Only key names and value digests are stored and printed, never values.
"""

import hashlib
import json
import plistlib
import subprocess
import sys

DOMAINS = ("com.typewhisper.mac.dev", "com.typewhisper.mac")


def digests(domain: str) -> dict[str, str]:
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


def snapshot() -> dict[str, dict[str, str]]:
    return {domain: digests(domain) for domain in DOMAINS}


def changes(before: dict[str, dict[str, str]], after: dict[str, dict[str, str]]) -> list[str]:
    lines = []
    for domain in DOMAINS:
        old, new = before.get(domain, {}), after.get(domain, {})
        for key in sorted(old.keys() | new.keys()):
            if key not in old:
                lines.append(f"{domain}: added {key}")
            elif key not in new:
                lines.append(f"{domain}: removed {key}")
            elif old[key] != new[key]:
                lines.append(f"{domain}: changed {key}")
    return lines


def main(arguments: list[str]) -> int:
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
