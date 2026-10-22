#!/usr/bin/env python3
"""Reject new test failures and incomplete test runs."""

import json
from pathlib import Path
import re
import sys


def main():
    receipts = Path(sys.argv[1])
    xcode_status, sdk_status, summary_status = map(int, sys.argv[2:])
    known_path = Path(__file__).with_name("known-test-failures.txt")
    known = {line.split(" # ", 1)[0].strip() for line in known_path.read_text().splitlines()
             if line.strip() and not line.startswith("#")}
    failures = set()
    errors = []
    try:
        summary = json.loads((receipts / "test-summary.json").read_text())
        failures.update("xcode:" + item["testIdentifierString"] for item in summary.get("testFailures", []))
        if not summary.get("totalTestCount") or summary_status or summary.get("result") not in {"Passed", "Failed"}:
            errors.append("Xcode 测试结果不完整。")
        if summary.get("failedTests", 0) != len(failures):
            errors.append("Xcode 失败数量与失败集合不一致。")
        if xcode_status not in {0, 65} or (xcode_status and not failures):
            errors.append("Xcode 构建或测试执行失败。")
    except (OSError, ValueError, KeyError) as error:
        errors.append(f"无法读取 Xcode 测试结果。{error}")
    sdk_log = (receipts / "sdk-test.log").read_text()
    sdk_failures = set(re.findall(r"Test Case '-\[([\w.]+) (\w+)\]' failed", sdk_log))
    failures.update(f"sdk:{suite.rsplit('.', 1)[-1]}/{test}()" for suite, test in sdk_failures)
    counts = re.findall(r"Test Suite 'All tests' (?:passed|failed)[^\n]*\n\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\)", sdk_log)
    if not counts:
        errors.append("SDK 测试结果不完整。")
    elif sum(int(count[2]) for count in counts) != len(sdk_failures):
        errors.append("SDK 失败数量与失败集合不一致。")
    if counts:
        total = sum(int(count[0]) for count in counts)
        skipped = sum(int(count[1] or 0) for count in counts)
        failed = sum(int(count[2]) for count in counts)
        print(f"SDK 总数={total}，通过={total - skipped - failed}，失败={failed}，跳过={skipped}。")
    if sdk_status not in {0, 1} or (sdk_status and not sdk_failures):
        errors.append("SDK 构建或测试执行失败。")
    for title, items in [("当前失败集合", failures), ("已知失败", failures & known),
                         ("已消失失败", known - failures), ("新增失败", failures - known)]:
        print(f"{title}（{len(items)}）")
        for item in sorted(items):
            print(f"  {item}")
    for error in errors:
        print(error, file=sys.stderr)
    (receipts / "test-failures.txt").write_text("\n".join(sorted(failures)) + "\n")
    return int(bool(errors or failures - known))


if __name__ == "__main__":
    sys.exit(main())
