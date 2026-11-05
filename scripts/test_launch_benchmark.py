#!/usr/bin/env python3

import copy
import datetime as dt
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "performance"))

import launch_benchmark as lb  # noqa: E402

NOW = dt.datetime(2026, 11, 4, 12, 0, tzinfo=dt.timezone.utc)


def launches(first_idle, cpu=1000.0, footprint=50.0, peak=60.0):
    return {"first_idle_ms": list(first_idle), "cpu_ms": [cpu] * len(first_idle),
            "footprint_mb": [footprint] * len(first_idle), "peak_footprint_mb": [peak] * len(first_idle)}


def report(verdict="pass", regressions=(), base=None, head=None, passes=1):
    base = base or launches([800.0] * 8)
    head = head or launches([810.0] * 8)
    count = len(base["first_idle_ms"])
    measured = {"base": base, "head": head,
                "phases": {"base": [{"pre_main_ms": 200.0, "Plugin.scan": 120.0}] * count,
                           "head": [{"pre_main_ms": 210.0, "Plugin.scan": 130.0}] * count},
                "counters": {"base": [{"instructions_g": 0.0, "runnable_ms": 300.0, "idle_before_pct": 92.0}] * count,
                             "head": [{"instructions_g": 0.0, "runnable_ms": 320.0, "idle_before_pct": 90.0}] * count}}
    return {
        "schema": lb.SCHEMA,
        "schema_version": lb.SCHEMA_VERSION,
        "base": {"sha": "6013a388c0ffee6013a388c0ffee6013a388c0ff"},
        "head": {"sha": "abc1234def5678abc1234def5678abc1234def56"},
        "pull_request": 1871,
        "fixture": dict(lb.FIXTURE),
        "rounds": count,
        "settle_seconds": 6.0,
        "runner": {"macos": "27.0.1", "cpus": 3},
        "limits": {metric.key: {"pct": metric.limit_pct, "abs": metric.limit_abs} for metric in lb.METRICS},
        "verdict": verdict,
        "regressions": list(regressions),
        "passes": [copy.deepcopy(measured) for _ in range(passes)],
        "app_size_mb": {"base": 101.5, "head": 101.6},
        "error": None,
    }


class EvaluateTests(unittest.TestCase):
    def test_regression_needs_both_limits(self):
        metric = lb.METRIC_BY_KEY["first_idle_ms"]
        # +15 ms is +15 %, but below the absolute limit of 100 ms.
        self.assertFalse(lb.evaluate(metric, [100.0] * 8, [115.0] * 8)["exceeded"])
        # +120 ms is only +6 %.
        self.assertFalse(lb.evaluate(metric, [2000.0] * 8, [2120.0] * 8)["exceeded"])
        result = lb.evaluate(metric, [1000.0] * 8, [1120.0] * 8)
        self.assertTrue(result["exceeded"])
        self.assertAlmostEqual(result["pct"], 12.0)
        self.assertEqual((result["worse"], result["rounds"]), (8, 8))

    def test_regression_needs_most_rounds_to_be_worse(self):
        metric = lb.METRIC_BY_KEY["first_idle_ms"]
        base = [1000.0] * 10
        # Noise: the median change is +180 ms, but only 7 of 10 rounds got worse.
        noisy = [1150.0, 1400.0, 1300.0, 1200.0, 1600.0, 1160.0, 1500.0, 700.0, 600.0, 900.0]
        result = lb.evaluate(metric, base, noisy)
        self.assertEqual((result["delta"], result["worse"]), (180.0, 7))
        self.assertFalse(result["exceeded"])
        # Eight of ten rounds are enough.
        noisy[8] = 1150.0
        self.assertTrue(lb.evaluate(metric, base, noisy)["exceeded"])

    def test_paired_differences_cancel_runner_drift(self):
        metric = lb.METRIC_BY_KEY["first_idle_ms"]
        # The runner gets slower over time; within each round the PR is 10 ms slower.
        base = [800.0, 900.0, 1000.0, 1100.0, 1200.0, 1300.0, 1400.0, 1500.0]
        head = [value + 10 for value in base]
        result = lb.evaluate(metric, base, head)
        self.assertEqual(result["delta"], 10.0)
        self.assertFalse(result["exceeded"])

    def test_improvements_never_regress(self):
        metric = lb.METRIC_BY_KEY["footprint_mb"]
        self.assertFalse(lb.evaluate(metric, [60.0] * 8, [40.0] * 8)["exceeded"])

    def test_uneven_samples_are_rejected(self):
        with self.assertRaises(ValueError):
            lb.evaluate(lb.METRIC_BY_KEY["cpu_ms"], [1.0, 2.0], [1.0])

    def test_a_regression_must_show_in_every_pass(self):
        slow = {"base": launches([1000.0] * 8), "head": launches([1200.0] * 8)}
        even = {"base": launches([1000.0] * 8), "head": launches([1000.0] * 8)}
        self.assertEqual(lb.exceeded_metrics([slow]), ["first_idle_ms"])
        self.assertEqual(lb.exceeded_metrics([slow, slow]), ["first_idle_ms"])
        self.assertEqual(lb.exceeded_metrics([slow, even]), [])
        self.assertEqual(lb.exceeded_metrics([]), [])


class FixtureTests(unittest.TestCase):
    def test_backup_has_the_requested_content(self):
        backup = lb.build_fixture(NOW)
        self.assertEqual(backup["schemaVersion"], 1)
        self.assertEqual(len(backup["history"]), lb.FIXTURE["history"])
        self.assertEqual(len(backup["dictionaryEntries"]), lb.FIXTURE["dictionary"])
        self.assertEqual(len(backup["snippets"]), lb.FIXTURE["snippets"])
        originals = [entry["original"] for entry in backup["dictionaryEntries"]]
        self.assertEqual(len(originals), len(set(originals)))
        self.assertEqual(len({snippet["trigger"] for snippet in backup["snippets"]}), lb.FIXTURE["snippets"])
        json.dumps(backup)

    def test_backup_matches_the_app_format(self):
        backup = lb.build_fixture(NOW)
        for key in ("schemaVersion", "exportedAt", "appVersion", "workflows", "dictionaryEntries", "snippets",
                    "promptActions", "profiles", "hotkeys", "plugins", "history", "preferences"):
            self.assertIn(key, backup)
        entry = backup["history"][0]
        for key in ("timestamp", "rawText", "finalText", "durationSeconds", "engineUsed", "pipelineSteps"):
            self.assertIn(key, entry)
        # The app decodes dates as ISO 8601 without fractional seconds.
        dt.datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
        self.assertTrue(entry["rawText"].strip() and entry["finalText"].strip())
        self.assertEqual({entry["type"] for entry in backup["dictionaryEntries"]}, {"term", "correction"})

    def test_history_stays_inside_the_last_120_days(self):
        for entry in lb.build_fixture(NOW)["history"]:
            timestamp = dt.datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
            self.assertLess(timestamp, NOW)
            self.assertGreaterEqual(timestamp, NOW - dt.timedelta(days=120))

    def test_backup_is_reproducible(self):
        self.assertEqual(lb.build_fixture(NOW), lb.build_fixture(NOW))

    def test_profile_marks_the_promotion_of_the_build_as_seen(self):
        source = 'enum IOSCompanion {\n    static let promoCampaignIdentifier = "ios-app-store-launch-2026-09"\n}'
        values = lb.profile_defaults(source)
        self.assertEqual(values["iOSCompanionPromoCampaign"], "ios-app-store-launch-2026-09")
        self.assertTrue(values["setupWizardCompleted"])
        self.assertFalse(values["SUEnableAutomaticChecks"])
        self.assertNotIn("iOSCompanionPromoCampaign", lb.profile_defaults(None))


class SignpostTests(unittest.TestCase):
    def test_log_timestamps_keep_microseconds_and_offset(self):
        seconds = lb.parse_log_timestamp("2026-11-04 22:41:10.087151+0100")
        self.assertAlmostEqual(seconds, dt.datetime(2026, 11, 4, 21, 41, 10, 87151, tzinfo=dt.timezone.utc).timestamp())

    def test_phase_durations(self):
        events = [
            {"name": "Launch", "type": "begin", "id": 1, "wall": 100.25, "mach": 0},
            {"name": "Launch.serviceContainer", "type": "begin", "id": 1, "wall": 100.3, "mach": 1000},
            {"name": "Launch.serviceContainer", "type": "end", "id": 1, "wall": 100.4, "mach": 4000},
            {"name": "Plugin.load", "type": "begin", "id": 7, "wall": 100.5, "mach": 5000},
            {"name": "Plugin.load", "type": "end", "id": 7, "wall": 100.6, "mach": 9000},
            {"name": "Launch.firstIdle", "type": "event", "id": 1, "wall": 101.0, "mach": 20000},
        ]
        self.assertEqual(lb.phase_durations(events, started=100.0, tick=0.01),
                         {"pre_main_ms": 250.0, "Launch.serviceContainer": 30.0})


class ValidationTests(unittest.TestCase):
    def assertInvalid(self, change):
        broken = report()
        change(broken)
        with self.assertRaises(ValueError):
            lb.validate(broken)

    def test_valid_report(self):
        lb.validate(report())

    def test_rejects_untrusted_shapes(self):
        self.assertInvalid(lambda r: r.update(schema="other"))
        self.assertInvalid(lambda r: r.update(schema_version=2))
        self.assertInvalid(lambda r: r["head"].update(sha="abc1234`; echo"))
        self.assertInvalid(lambda r: r.update(pull_request="1871"))
        self.assertInvalid(lambda r: r.update(pull_request=True))
        self.assertInvalid(lambda r: r.update(verdict="fine"))
        self.assertInvalid(lambda r: r.update(regressions=["<b>"]))
        self.assertInvalid(lambda r: r["passes"][0]["head"].update(cpu_ms=["1"] * 8))
        self.assertInvalid(lambda r: r["passes"][0]["head"].update(cpu_ms=[float("nan")] * 8))
        self.assertInvalid(lambda r: r["passes"][0]["head"].update(cpu_ms=[True] * 8))
        self.assertInvalid(lambda r: r["passes"][0]["head"].update(cpu_ms=[1.0] * 7))
        self.assertInvalid(lambda r: r["passes"][0]["phases"].update(head=[{"<img>": 1.0}]))
        self.assertInvalid(lambda r: r["passes"][0]["counters"].update(head=[{"runnable_ms": "slow"}]))
        self.assertInvalid(lambda r: r["passes"][0]["counters"].update(head=[{"<b>": 1.0}]))
        self.assertInvalid(lambda r: r["passes"].extend([r["passes"][0]] * 2))
        self.assertInvalid(lambda r: r["limits"]["cpu_ms"].update(pct="10"))
        self.assertInvalid(lambda r: r.update(passes=[]))

    def test_an_error_report_needs_no_measurements(self):
        broken = report(verdict="error")
        broken["passes"] = []
        broken["error"] = "the local API did not answer"
        lb.validate(broken)


class RenderTests(unittest.TestCase):
    def test_table_and_result(self):
        text = lb.render(report())
        self.assertIn("main `6013a38` and this pull request `abc1234`", text)
        self.assertIn("8 alternating launches each", text)
        self.assertIn("<summary>Launch phases and runner conditions (medians)</summary>", text)
        self.assertIn("| Time until ready | 800 ms | 810 ms | +10 ms (+1.2%) | 8 of 8 rounds | +10% and +100 ms |", text)
        self.assertIn("| App size | 101.5 MB | 101.6 MB | +0.1 MB (+0.1%) | | |", text)
        self.assertIn("| Plugin scan | 120 ms | 130 ms | +10 ms |", text)
        self.assertIn("| Time waiting for a processor | 300 ms | 320 ms | +20 ms |", text)
        self.assertIn("| Idle processors before the launch | 92% | 90% | -2% |", text)
        # A virtual machine without performance counters reports no instructions.
        self.assertNotIn("Instructions", text)
        self.assertIn("**Result:** no launch regression.", text)

    def test_instruction_counts_when_the_runner_has_them(self):
        counted = report()
        for side, value in (("base", 1.25), ("head", 1.5)):
            counted["passes"][0]["counters"][side] = [{"instructions_g": value}] * 8
        self.assertIn("| Instructions | 1.25 billion | 1.50 billion | +0.25 billion |", lb.render(counted))

    def test_reports_without_counters_still_render(self):
        older = report()
        del older["passes"][0]["counters"]
        self.assertIn("| Plugin scan |", lb.render(older))

    def test_regression_names_the_metric_and_the_way_out(self):
        slow = launches([1000.0] * 8, footprint=60.0)
        text = lb.render(report("regression", ["footprint_mb"], head=slow, passes=2))
        self.assertIn("16 alternating launches each", text)
        self.assertIn("+10.0 MB (+20.0%) **(regression)**", text)
        self.assertIn("regression in memory after launch in both passes", text)
        self.assertIn(f"`{lb.ACCEPT_LABEL}` label and re-run the `release-build` job", text)

    def test_accepted_regression(self):
        text = lb.render(report("accepted", ["cpu_ms"]))
        self.assertIn(f"regression in cpu time, accepted with the `{lb.ACCEPT_LABEL}` label", text)

    def test_failed_benchmark_shows_no_untrusted_text(self):
        failed = report(verdict="error")
        failed["passes"] = []
        failed["error"] = "<img src=x onerror=alert(1)> [click](https://example.com)"
        text = lb.render(failed)
        self.assertIn("failed before it measured anything", text)
        self.assertNotIn("<img", text)
        self.assertNotIn("example.com", text)


class DescriptionTests(unittest.TestCase):
    def test_section_is_appended_then_replaced(self):
        body = "## Summary\n\nFaster launch.\n"
        first = lb.merge_section(body, "### Launch performance\n\nold")
        self.assertTrue(first.startswith("## Summary\n\nFaster launch.\n\n" + lb.SECTION_START))
        second = lb.merge_section(first + "\nTrailing note.\n", "### Launch performance\n\nnew")
        self.assertIn("new", second)
        self.assertNotIn("old", second)
        self.assertEqual(second.count(lb.SECTION_START), 1)
        self.assertTrue(second.rstrip().endswith("Trailing note."))
        self.assertEqual(lb.merge_section(second, "### Launch performance\n\nnew"), second)

    def test_empty_body(self):
        self.assertEqual(lb.merge_section("", "table"), f"{lb.SECTION_START}\n{lb.SECTION_NOTE}\ntable\n{lb.SECTION_END}\n")

    def test_update_description_writes_a_payload_only_on_change(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "report.json").write_text(json.dumps(report()))
            (folder / "body.md").write_text("## Summary\n")
            arguments = ["update-description", str(folder / "report.json"), "--body", str(folder / "body.md"),
                         "--output", str(folder / "payload.json")]
            with redirect_stdout(io.StringIO()) as output:
                self.assertEqual(lb.main(arguments), 0)
            self.assertEqual(output.getvalue().strip(), "changed")
            updated = json.loads((folder / "payload.json").read_text())["body"]
            self.assertIn("**Result:** no launch regression.", updated)

            (folder / "body.md").write_text(updated)
            (folder / "payload.json").unlink()
            with redirect_stdout(io.StringIO()) as output:
                self.assertEqual(lb.main(arguments), 0)
            self.assertEqual(output.getvalue().strip(), "unchanged")
            self.assertFalse((folder / "payload.json").exists())


class CheckTests(unittest.TestCase):
    def check(self, verdict, accepted, regressions=()):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            data = report(verdict, regressions)
            if verdict == "error":
                data["passes"] = []
                data["error"] = "no Launch.firstIdle signpost"
            path.write_text(json.dumps(data))
            with redirect_stdout(io.StringIO()):
                status = lb.main(["check", str(path), "--accepted", accepted])
            return status, json.loads(path.read_text())["verdict"]

    def test_outcomes(self):
        self.assertEqual(self.check("pass", "false"), (0, "pass"))
        self.assertEqual(self.check("pass", "true"), (0, "pass"))
        self.assertEqual(self.check("regression", "false", ["cpu_ms"]), (1, "regression"))
        self.assertEqual(self.check("regression", "true", ["cpu_ms"]), (0, "accepted"))
        self.assertEqual(self.check("error", "true"), (1, "error"))

    def test_run_refuses_without_a_disposable_mac(self):
        with tempfile.TemporaryDirectory() as directory:
            arguments = ["run", "--base", "a.app", "--head", "b.app", "--work", directory,
                         "--output", str(Path(directory) / "report.json")]
            with redirect_stderr(io.StringIO()):
                self.assertEqual(lb.main(arguments), 2)
            self.assertFalse((Path(directory) / "report.json").exists())


if __name__ == "__main__":
    unittest.main()
