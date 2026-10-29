#!/usr/bin/env python3
"""Verify that every text passed to localizedAppText(_:de:ja:zh:zhHant:es:) has Spanish
and Traditional Chinese.

localizedAppText returns the German argument directly and looks up Japanese, Chinese
and Spanish in the app's string catalog by the English text. That lookup only works for
plain English literals: a literal with interpolated values, like "More Models (\\(count))",
is looked up after interpolation and never matches. So, for Spanish (`es:`, catalog "es")
and Traditional Chinese (`zhHant:`, catalog "zh-Hant"):

- a plain English literal needs a value in TypeWhisper/Resources/Localizable.xcstrings
  under the English text, or an inline argument;
- an interpolated English literal needs an inline literal that interpolates the same
  expressions.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIRECTORIES = ("TypeWhisper", "AppStore/Sources")
APP_CATALOG = "TypeWhisper/Resources/Localizable.xcstrings"
FUNCTION_NAME = "localizedAppText"
LANGUAGE = "es"
# Argument label of localizedAppText -> locale in the string catalog.
LANGUAGES = {"es": "es", "zhHant": "zh-Hant"}


class SwiftParseError(ValueError):
    pass


@dataclass
class StringLiteral:
    """A Swift string literal split into text and interpolated expressions."""

    parts: list[tuple[str, str]] = field(default_factory=list)  # ("text" | "interpolation", value)

    @property
    def is_interpolated(self) -> bool:
        return any(kind == "interpolation" for kind, _ in self.parts)

    @property
    def text(self) -> str:
        return "".join(value for kind, value in self.parts if kind == "text")

    @property
    def interpolations(self) -> list[str]:
        return sorted(" ".join(value.split()) for kind, value in self.parts if kind == "interpolation")


@dataclass
class Call:
    path: Path
    line: int
    english: StringLiteral | None
    arguments: dict[str, StringLiteral | None]


_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def _skip_comment(source: str, index: int) -> int | None:
    """Returns the index after a comment starting at index, or None if there is none."""
    if source.startswith("//", index):
        end = source.find("\n", index)
        return len(source) if end == -1 else end
    if source.startswith("/*", index):
        depth, index = 1, index + 2
        while depth:
            if index >= len(source):
                raise SwiftParseError("unterminated block comment")
            if source.startswith("/*", index):
                depth, index = depth + 1, index + 2
            elif source.startswith("*/", index):
                depth, index = depth - 1, index + 2
            else:
                index += 1
        return index
    return None


def _literal_start(source: str, index: int) -> bool:
    if source[index] == '"':
        return True
    return source[index] == "#" and re.match(r'#+"', source[index:]) is not None


def parse_string_literal(source: str, index: int) -> tuple[StringLiteral, int]:
    """Parses the literal starting at index ('"', '"""' or raw '#"'); returns it and the end index."""
    hashes = 0
    while source[index] == "#":
        hashes += 1
        index += 1
    multiline = source.startswith('"""', index)
    index += 3 if multiline else 1
    closing = ('"""' if multiline else '"') + "#" * hashes
    escape = "\\" + "#" * hashes

    literal = StringLiteral()
    text: list[str] = []

    def flush() -> None:
        if text:
            literal.parts.append(("text", "".join(text)))
            text.clear()

    while True:
        if index >= len(source):
            raise SwiftParseError("unterminated string literal")
        if source.startswith(closing, index):
            index += len(closing)
            break
        if not multiline and source[index] == "\n":
            raise SwiftParseError("line break in single-line string literal")
        if source.startswith(escape, index):
            marker = index + len(escape)
            character = source[marker]
            if character == "(":
                end = skip_code(source, marker + 1, closing=")")
                flush()
                literal.parts.append(("interpolation", source[marker + 1 : end - 1].strip()))
                index = end
                continue
            if character == "u":
                match = re.match(r"u\{([0-9a-fA-F]{1,8})\}", source[marker:])
                if not match:
                    raise SwiftParseError("invalid unicode escape")
                text.append(chr(int(match.group(1), 16)))
                index = marker + len(match.group(0))
                continue
            if multiline and character == "\n":
                index = marker + 1
                continue
            if character not in _ESCAPES:
                raise SwiftParseError(f"unknown escape \\{character}")
            text.append(_ESCAPES[character])
            index = marker + 1
            continue
        text.append(source[index])
        index += 1
    flush()

    if multiline:
        literal = _strip_multiline_indentation(literal, source[:index])
    return literal, index


def _strip_multiline_indentation(literal: StringLiteral, source_up_to_end: str) -> StringLiteral:
    closing_line = source_up_to_end.rsplit("\n", 1)[-1]
    indentation = closing_line[: len(closing_line) - len(closing_line.lstrip(" \t"))]
    parts: list[tuple[str, str]] = []
    for position, (kind, value) in enumerate(literal.parts):
        if kind == "text":
            if position == 0 and value.startswith("\n"):
                value = value[1:]
            if position == 0 and value.startswith(indentation):
                value = value[len(indentation):]
            value = value.replace("\n" + indentation, "\n")
            if position == len(literal.parts) - 1 and value.endswith("\n"):
                value = value[:-1]
        parts.append((kind, value))
    return StringLiteral(parts)


def skip_code(source: str, index: int, closing: str | None = None) -> int:
    """Skips code up to the unmatched `closing` bracket (returns the index after it) or the end."""
    depth = 0
    while index < len(source):
        comment_end = _skip_comment(source, index)
        if comment_end is not None:
            index = comment_end
            continue
        if _literal_start(source, index):
            _, index = parse_string_literal(source, index)
            continue
        character = source[index]
        if character in "([{":
            depth += 1
        elif character in ")]}":
            if depth == 0:
                if closing is not None and character == closing:
                    return index + 1
                raise SwiftParseError(f"unbalanced {character!r}")
            depth -= 1
        index += 1
    if closing is not None:
        raise SwiftParseError(f"missing {closing!r}")
    return index


def code_positions(source: str) -> list[bool]:
    """Marks which characters are code, as opposed to comments and string literal text."""
    is_code = [False] * len(source)

    def mark(start: int, end: int) -> None:
        for position in range(start, end):
            is_code[position] = True

    def walk(index: int, closing: str | None) -> int:
        depth = 0
        while index < len(source):
            comment_end = _skip_comment(source, index)
            if comment_end is not None:
                index = comment_end
                continue
            if _literal_start(source, index):
                index = walk_literal(index)
                continue
            character = source[index]
            is_code[index] = True
            if character in "([{":
                depth += 1
            elif character in ")]}":
                if depth == 0 and closing is not None and character == closing:
                    return index + 1
                depth -= 1
            index += 1
        return index

    def walk_literal(index: int) -> int:
        hashes = 0
        while source[index] == "#":
            hashes += 1
            index += 1
        multiline = source.startswith('"""', index)
        index += 3 if multiline else 1
        closing = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        while index < len(source):
            if source.startswith(closing, index):
                return index + len(closing)
            if source.startswith(escape + "(", index):
                index = walk(index + len(escape) + 1, ")")
                continue
            if source.startswith(escape, index):
                index += len(escape) + 1
                continue
            index += 1
        return index

    walk(0, None)
    return is_code


def _parse_argument(source: str, index: int) -> tuple[str | None, StringLiteral | None, int]:
    """Parses one call argument; returns (label, literal or None, index after the argument)."""
    while True:
        while index < len(source) and source[index].isspace():
            index += 1
        comment_end = _skip_comment(source, index)
        if comment_end is None:
            break
        index = comment_end
    label = None
    match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)", source[index:])
    if match:
        label = match.group(1)
        index += match.end()
        while source[index].isspace():
            index += 1

    literal = None
    start = index
    if _literal_start(source, index):
        candidate, end = parse_string_literal(source, index)
        rest = end
        while rest < len(source) and source[rest].isspace():
            rest += 1
        if source[rest] in ",)":
            literal = candidate
    # Skip the full argument expression either way.
    index = start
    depth = 0
    while True:
        comment_end = _skip_comment(source, index)
        if comment_end is not None:
            index = comment_end
            continue
        if _literal_start(source, index):
            _, index = parse_string_literal(source, index)
            continue
        character = source[index]
        if character in "([{":
            depth += 1
        elif character in ")]}":
            if depth == 0:
                return label, literal, index
            depth -= 1
        elif character == "," and depth == 0:
            return label, literal, index
        index += 1


def find_calls(path: Path, source: str | None = None) -> list[Call]:
    if source is None:
        source = path.read_text(encoding="utf-8")
    is_code = code_positions(source)
    calls: list[Call] = []
    for match in re.finditer(rf"(?<![\w.]){FUNCTION_NAME}\s*\(", source):
        if not is_code[match.start()]:
            continue
        line_start = source.rfind("\n", 0, match.start()) + 1
        if re.search(r"\bfunc\s+$", source[line_start : match.start()]):
            continue
        index = match.end()
        english: StringLiteral | None = None
        arguments: dict[str, StringLiteral | None] = {}
        first = True
        while True:
            label, literal, index = _parse_argument(source, index)
            if first:
                english = literal if label is None else None
                first = False
            elif label is not None:
                arguments[label] = literal
            if source[index] == ",":
                index += 1
                continue
            break
        calls.append(Call(path, source.count("\n", 0, match.start()) + 1, english, arguments))
    return calls


def catalog_keys(catalog: dict, locale: str) -> set[str]:
    keys = set()
    for key, entry in catalog.get("strings", {}).items():
        node = entry.get("localizations", {}).get(locale, {})
        unit = node.get("stringUnit", {}) if isinstance(node, dict) else {}
        if isinstance(unit.get("value"), str) and unit["value"]:
            keys.add(key)
        elif isinstance(node, dict) and node.get("variations"):
            keys.add(key)
    return keys


def catalog_spanish_keys(catalog: dict) -> set[str]:
    return catalog_keys(catalog, LANGUAGE)


def check_calls(
    calls: list[Call], translated_keys: set[str], label: str = LANGUAGE, locale: str = LANGUAGE
) -> list[str]:
    problems = []
    for call in calls:
        location = f"{call.path}:{call.line}"
        english = call.english
        inline = call.arguments.get(label)
        has_inline = label in call.arguments
        if english is None:
            problems.append(f"{location}: the English text must be a string literal")
            continue
        if has_inline:
            if inline is None:
                problems.append(f"{location}: `{label}:` must be a string literal")
            elif inline.interpolations != english.interpolations:
                problems.append(
                    f"{location}: `{label}:` interpolates {inline.interpolations}, "
                    f"English interpolates {english.interpolations}"
                )
            elif not inline.text.strip() and english.text.strip():
                problems.append(f"{location}: `{label}:` is empty")
            continue
        if english.is_interpolated:
            problems.append(
                f"{location}: English text with interpolation needs an inline `{label}:` translation: "
                f"{english.text!r}"
            )
        elif english.text not in translated_keys:
            problems.append(
                f"{location}: no {locale} value in {APP_CATALOG} for {english.text!r}"
            )
    return problems


def swift_files(repo_root: Path = REPO_ROOT) -> list[Path]:
    files: list[Path] = []
    for directory in SOURCE_DIRECTORIES:
        files.extend(sorted((repo_root / directory).rglob("*.swift")))
    return files


def main() -> int:
    catalog = json.loads((REPO_ROOT / APP_CATALOG).read_text(encoding="utf-8"))
    calls: list[Call] = []
    for path in swift_files():
        try:
            calls.extend(find_calls(path))
        except SwiftParseError as error:
            print(f"error: could not parse {path.relative_to(REPO_ROOT)}: {error}")
            return 1
    for call in calls:
        call.path = call.path.relative_to(REPO_ROOT)

    failed = False
    for label, locale in LANGUAGES.items():
        problems = check_calls(calls, catalog_keys(catalog, locale), label, locale)
        if problems:
            print(f"error: {len(problems)} {FUNCTION_NAME} calls have no {locale} translation")
            for problem in problems:
                print(f"  {problem}")
            failed = True
        else:
            print(f"verified {locale} translations for {len(calls)} {FUNCTION_NAME} calls")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
