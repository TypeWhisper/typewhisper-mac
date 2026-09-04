#!/usr/bin/env python3
"""Run normally and with python -O to verify comparison checks stay enabled."""
import copy
import unittest

from run import compare_reports


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.report = {
            "source_sha256": {"scripts/performance/Benchmark.swift": "harness"},
            "results": [{"case": "wav-app-10s", "digest": "output"}],
        }
        self.baseline = copy.deepcopy(self.report)

    def test_matching_reports_pass(self):
        compare_reports(self.baseline, self.report)

    def test_changed_harness_fails(self):
        self.baseline["source_sha256"]["scripts/performance/Benchmark.swift"] = "old-harness"
        with self.assertRaisesRegex(SystemExit, "harness hash changed"):
            compare_reports(self.baseline, self.report)

    def test_missing_harness_fails(self):
        self.baseline.pop("source_sha256")
        with self.assertRaisesRegex(SystemExit, "harness hash changed or is missing"):
            compare_reports(self.baseline, self.report)

    def test_missing_case_fails(self):
        self.baseline["results"] = []
        with self.assertRaisesRegex(SystemExit, "missing benchmark case: wav-app-10s"):
            compare_reports(self.baseline, self.report)

    def test_changed_output_fails(self):
        self.baseline["results"][0]["digest"] = "old-output"
        with self.assertRaisesRegex(SystemExit, "Output digest changed.*wav-app-10s"):
            compare_reports(self.baseline, self.report)

    def test_missing_output_digest_fails(self):
        self.baseline["results"][0].pop("digest")
        with self.assertRaisesRegex(SystemExit, "Output digest changed or is missing.*wav-app-10s"):
            compare_reports(self.baseline, self.report)


if __name__ == "__main__":
    unittest.main()
