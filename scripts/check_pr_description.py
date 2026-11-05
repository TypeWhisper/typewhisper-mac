#!/usr/bin/env python3
"""Check a pull request's title and description against the rules in AGENTS.md.

    PR_TITLE=... PR_BODY=... check_pr_description.py [--base HEAD^1] [--summary FILE]

The workflow sets PR_TITLE and PR_BODY from the event and checks out the merge commit, whose
first parent is the base branch, so `git diff --base HEAD` holds the pull request's changes.

- The title starts with its category: (feature), (bug), (perf) or (chore).
- A pull request that changes something visible has a screenshot or a clip in its
  description, unless "- [x] No visible UI change" is ticked. Visible changes are asset
  catalogs, string catalogs, Interface Builder files, files under TypeWhisper/Views/ and the
  widget extension, and changed lines that build views in other Swift files.
- A (perf) pull request has a measurement table in its description.

HTML comments and the launch performance section that CI writes into the description do not
count for any rule.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

CATEGORIES = ("feature", "bug", "perf", "chore")
TITLE = re.compile(r"^\((?:" + "|".join(CATEGORIES) + r")\) \S")

CI_SECTION = re.compile(r"<!-- launch-benchmark:start -->.*?<!-- launch-benchmark:end -->", re.S)
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
MEDIA = (
    re.compile(r"!\[[^\]]*\]\(\s*\S+?\s*\)"),
    re.compile(r"<(?:img|video)\b", re.I),
    re.compile(r"https://github\.com/user-attachments/assets/[0-9A-Za-z-]+"),
    re.compile(r"https://(?:private-)?user-images\.githubusercontent\.com/\S+"),
)
NO_UI_CHANGE = re.compile(r"^\s*[-*]\s*\[[xX]\]\s*No visible UI change\b", re.M)

UI_RESOURCES = re.compile(r"(?:\.xcassets/|\.icon/|\.xcstrings$|\.xib$|\.storyboard$)")
UI_SWIFT_FOLDERS = ("TypeWhisper/Views/", "TypeWhisperWidgetExtension/")
NOT_SHIPPED = re.compile(r"(?:^|/)[^/]*Tests?/|^(?:docs|scripts|fastlane|\.github)/")
VIEW_CODE = re.compile(
    r"\b(?:Text|Button|Toggle|Picker|Label|Image|TextField|SecureField|TextEditor|Slider|Stepper|Menu|"
    r"Section|Form|List|ScrollView|VStack|HStack|ZStack|LazyVStack|LazyHStack|Grid|GridRow|Divider|"
    r"ProgressView|DisclosureGroup|GroupBox|NavigationStack|NavigationSplitView|TabView|Link|"
    r"ContentUnavailableView|NSAlert|NSMenuItem|NSButton|NSTextField|NSWindow|NSPanel)\s*[({]"
    r"|\.(?:font|foregroundStyle|foregroundColor|padding|frame|background|overlay|help|tint|controlSize|"
    r"buttonStyle|toggleStyle|pickerStyle|labelStyle|listStyle|formStyle|navigationTitle|toolbar|sheet|"
    r"alert|confirmationDialog|popover|contextMenu|accessibilityLabel)\s*\("
    r"|\bsome\s+View\b|:\s*View\b"
)


def visible_text(body):
    """The description without HTML comments and without the CI section."""
    return HTML_COMMENT.sub("", CI_SECTION.sub("", body or ""))


def has_media(text):
    return any(pattern.search(text) for pattern in MEDIA)


def has_table(text):
    """A Markdown table with at least two columns and a row that holds a number."""
    lines = text.splitlines()
    for index in range(1, len(lines)):
        delimiter = lines[index].strip()
        if not ("|" in lines[index - 1] and "---" in delimiter and set(delimiter) <= set("|:- \t")):
            continue
        if len([cell for cell in delimiter.strip("|").split("|") if cell.strip()]) < 2:
            continue
        # As in GitHub Markdown, a row needs no pipes; a blank line or a new block ends the table.
        for row in lines[index + 1:]:
            if not row.strip() or row.lstrip().startswith(("#", ">", "```", "~~~")):
                break
            if re.search(r"\d", row):
                return True
    return False


def changed_lines(diff):
    """Added and removed lines per file from `git diff -U0` output, without comment-only lines."""
    result = {}
    current = old = None
    in_header = False
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            current = old = None
            in_header = True
        elif in_header and line.startswith("--- "):
            old = line[6:] if line.startswith("--- a/") else None
        elif in_header and line.startswith("+++ "):
            # A deleted file has no new path; its removed lines still count.
            current = line[6:] if line.startswith("+++ b/") else old
        elif line.startswith("@@"):
            in_header = False
        elif current and not in_header and line[:1] in ("+", "-"):
            code = line[1:].split("//", 1)[0].strip()
            if code:
                result.setdefault(current, []).append(code)
    return result


def ui_files(paths, lines_by_file):
    """The changed paths that show up in the interface."""
    found = []
    for path in paths:
        if NOT_SHIPPED.search(path):
            continue
        if UI_RESOURCES.search(path):
            found.append(path)
        elif path.endswith(".swift"):
            if path.startswith(UI_SWIFT_FOLDERS) or any(VIEW_CODE.search(line) for line in lines_by_file.get(path, ())):
                found.append(path)
    return found


def check(title, body, paths, lines_by_file):
    """Problems as (title, message) pairs, and notes for the summary."""
    problems = []
    notes = []
    text = visible_text(body)

    if not TITLE.match(title or ""):
        problems.append(("Title needs a category", "Start the title with (feature), (bug), (perf) or (chore) and a "
                         "space, for example \"(bug) Keep the indicator on the active screen\"."))

    visible = ui_files(paths, lines_by_file)
    if visible:
        shown = ", ".join(visible[:8]) + (f" and {len(visible) - 8} more" if len(visible) > 8 else "")
        if NO_UI_CHANGE.search(text):
            notes.append(f"Visible files changed ({shown}); the description says there is no visible UI change.")
        elif has_media(text):
            notes.append(f"Visible files changed ({shown}); the description has screenshots or a clip.")
        else:
            problems.append(("Screenshots missing", f"This pull request changes visible files ({shown}). Add "
                             "screenshots of the final interface in English, and a short clip for changes in "
                             "motion, or tick \"- [x] No visible UI change\" in the description."))

    if (title or "").startswith("(perf)"):
        if has_table(text):
            notes.append("The (perf) description has a measurement table.")
        else:
            problems.append(("Measurement table missing", "A (perf) pull request needs a Markdown table with the "
                             "measured metric for main and this pull request, and how it was measured. The "
                             "launch performance section from CI does not count."))
    return problems, notes


def git(*arguments):
    return subprocess.run(["git", *arguments], check=True, capture_output=True, text=True).stdout


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="HEAD^1", help="the base commit to diff against (default: HEAD^1)")
    parser.add_argument("--summary", help="append a Markdown summary to this file")
    args = parser.parse_args(argv)

    paths = [path for path in git("diff", "--name-only", "--no-renames", args.base, "HEAD").splitlines() if path]
    lines_by_file = changed_lines(git("diff", "-U0", "--no-color", "--no-renames", args.base, "HEAD", "--", "*.swift"))
    problems, notes = check(os.environ.get("PR_TITLE", ""), os.environ.get("PR_BODY", ""), paths, lines_by_file)

    for title, message in problems:
        print(f"::error title={title}::{message}")
    for note in notes:
        print(note)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as summary:
            summary.write("### Pull request description\n\n")
            summary.writelines(f"- **{title}:** {message}\n" for title, message in problems)
            summary.writelines(f"- {note}\n" for note in notes)
            if not problems and not notes:
                summary.write("- Title and description follow the rules.\n")
    if not problems:
        print("The title and description follow the rules in AGENTS.md.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
