#!/usr/bin/env python3

import unittest

from check_pr_description import changed_lines, check, has_table, ui_files, visible_text

TEMPLATE = """## Summary

Fixes the thing.

## Screenshots

<!-- Required for visible changes. ![example](https://example.com/x.png) -->

- [ ] No visible UI change

## Test Plan

- [x] Ran `scripts/pr-preflight.sh`
"""

CI_SECTION = """<!-- launch-benchmark:start -->
### Launch performance

| Metric | main | This PR |
| --- | ---: | ---: |
| Time until ready | 800 ms | 810 ms |

![chart](https://github.com/user-attachments/assets/0f6c1d4e-1111-2222-3333-444455556666)
<!-- launch-benchmark:end -->"""

DIFF = """diff --git a/TypeWhisperPluginSDK/Plugins/XAIPlugin/XAIPlugin.swift b/TypeWhisperPluginSDK/Plugins/XAIPlugin/XAIPlugin.swift
index 1111111..2222222 100644
--- a/TypeWhisperPluginSDK/Plugins/XAIPlugin/XAIPlugin.swift
+++ b/TypeWhisperPluginSDK/Plugins/XAIPlugin/XAIPlugin.swift
@@ -10 +10 @@ final class XAIPlugin {
-        let url = URL(string: "https://api.x.ai/v1/old")!
+        let url = URL(string: "https://api.x.ai/v1/new")!
diff --git a/TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift b/TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift
index 3333333..4444444 100644
--- a/TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift
+++ b/TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift
@@ -80,0 +81,2 @@ struct GroqSettingsView: View {
+            Toggle("Use the turbo model", isOn: $turbo)
+            // a comment that mentions Text(
diff --git a/TypeWhisper/Services/OldBadge.swift b/TypeWhisper/Services/OldBadge.swift
deleted file mode 100644
index 5555555..0000000
--- a/TypeWhisper/Services/OldBadge.swift
+++ /dev/null
@@ -1,3 +0,0 @@
-struct OldBadge: View {
---counter
-}
"""


class TitleTests(unittest.TestCase):
    def problems(self, title):
        return [name for name, _ in check(title, TEMPLATE, [], {})[0]]

    def test_categories(self):
        for title in ("(feature) Add a thing", "(bug) Fix a thing", "(perf) Speed up a thing", "(chore) Bump X"):
            self.assertNotIn("Title needs a category", self.problems(title), title)
        for title in ("Add a thing", "(Feature) Add a thing", "(fix) Fix a thing", "(bug)Fix a thing", "feat: thing"):
            self.assertIn("Title needs a category", self.problems(title), title)


class UIFileTests(unittest.TestCase):
    def test_paths(self):
        lines = changed_lines(DIFF)
        paths = [
            "TypeWhisper/Views/SettingsView.swift",
            "TypeWhisperWidgetExtension/TypeWhisperWidget.swift",
            "TypeWhisper/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
            "TypeWhisper/Resources/Localizable.xcstrings",
            "TypeWhisper/Services/HistoryService.swift",
            "TypeWhisperTests/SettingsViewTests.swift",
            "TypeWhisperPluginSDK/Plugins/XAIPlugin/XAIPlugin.swift",
            "TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift",
            "TypeWhisper/Services/OldBadge.swift",
            "docs/screenshots/settings.png",
            "scripts/check_pr_description.py",
        ]
        self.assertEqual(ui_files(paths, lines), [
            "TypeWhisper/Views/SettingsView.swift",
            "TypeWhisperWidgetExtension/TypeWhisperWidget.swift",
            "TypeWhisper/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
            "TypeWhisper/Resources/Localizable.xcstrings",
            "TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift",
            "TypeWhisper/Services/OldBadge.swift",
        ])

    def test_changed_lines_skip_comments_and_keep_deleted_files(self):
        lines = changed_lines(DIFF)
        self.assertEqual(lines["TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift"],
                         ['Toggle("Use the turbo model", isOn: $turbo)'])
        self.assertEqual(lines["TypeWhisper/Services/OldBadge.swift"], ["struct OldBadge: View {", "--counter", "}"])


class DescriptionTests(unittest.TestCase):
    VIEW = ["TypeWhisper/Views/SettingsView.swift"]

    def problems(self, title, body, paths=()):
        return [name for name, _ in check(title, body, list(paths), {})[0]]

    def test_visible_change_needs_media(self):
        self.assertEqual(self.problems("(feature) New settings", TEMPLATE, self.VIEW), ["Screenshots missing"])

    def test_media_kinds(self):
        for media in ("![Settings](https://github.com/user-attachments/assets/0f6c1d4e-aaaa-bbbb-cccc-ddddeeeeffff)",
                      '<img width="600" alt="Settings" src="https://github.com/user-attachments/assets/abc">',
                      "https://github.com/user-attachments/assets/0f6c1d4e-aaaa-bbbb-cccc-ddddeeeeffff",
                      "<video src=\"https://example.com/clip.mp4\"></video>"):
            body = TEMPLATE.replace("Fixes the thing.", f"Fixes the thing.\n\n{media}")
            self.assertEqual(self.problems("(feature) New settings", body, self.VIEW), [], media)

    def test_opt_out(self):
        body = TEMPLATE.replace("- [ ] No visible UI change", "- [x] No visible UI change")
        table = "\n| Metric | main | PR |\n| --- | --- | --- |\n| Rebuilt rows | 300 | 1 |\n"
        self.assertEqual(self.problems("(perf) Faster rows", body + table, self.VIEW), [])

    def test_comments_and_the_ci_section_do_not_count(self):
        body = TEMPLATE + "\n" + CI_SECTION + "\n<!-- - [x] No visible UI change -->\n"
        self.assertNotIn("https://example.com/x.png", visible_text(body))
        self.assertEqual(self.problems("(perf) Faster rows", body, self.VIEW),
                         ["Screenshots missing", "Measurement table missing"])

    def test_no_visible_change_needs_nothing(self):
        self.assertEqual(self.problems("(bug) Fix a race", TEMPLATE, ["TypeWhisper/Services/HistoryService.swift"]), [])

    def test_perf_needs_a_table(self):
        self.assertEqual(self.problems("(perf) Faster launch", TEMPLATE), ["Measurement table missing"])
        body = TEMPLATE + "\n| Metric | main | PR |\n|:---|---:|---:|\n| CPU | 10 ms | 5 ms |\n"
        self.assertEqual(self.problems("(perf) Faster launch", body), [])

    def test_table_detection(self):
        self.assertTrue(has_table("| Metric | main | PR |\n| --- | --- | --- |\n| CPU | 10 ms | 5 ms |"))
        self.assertTrue(has_table("Metric | main\n--- | ---\nCPU | 10 ms"))
        # A row without pipes still belongs to the table; a blank line ends it.
        self.assertTrue(has_table("| Metric | main | PR |\n| --- | --- | --- |\nWarmup\nCPU | 10 ms | 8 ms"))
        self.assertFalse(has_table("| Metric | main | PR |\n| --- | --- | --- |\n\nWe saved 10 ms."))
        # A header without measurements, a single column, or a lone delimiter is no measurement table.
        self.assertFalse(has_table("| Metric | main | PR |\n| --- | --- | --- |"))
        self.assertFalse(has_table("| Metric | main | PR |\n| --- | --- | --- |\n| CPU | faster | slower |"))
        self.assertFalse(has_table("| CPU |\n| --- |\n| 10 ms |"))
        self.assertFalse(has_table("a | b\n\n| --- |"))
        self.assertFalse(has_table("Some text\n---\nMore text"))


if __name__ == "__main__":
    unittest.main()
