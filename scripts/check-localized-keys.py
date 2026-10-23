#!/usr/bin/env python3
"""List Swift String(localized:) and Text literal keys missing from their catalog."""

import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
CALL = re.compile(r'\b(?:String\s*\(\s*localized\s*:|Text\s*\()\s*"')
FORMAT = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|z)?[@diufgeGs]')


def literal(source, start):
    parts = [""]
    index = start
    while index < len(source):
        char = source[index]
        if char == '"':
            return parts, index + 1
        if source.startswith('\\(', index):
            index += 2
            depth = 1
            while index < len(source) and depth:
                if source[index] == '"':
                    _, index = literal(source, index + 1)
                    continue
                if source[index] == '(':
                    depth += 1
                elif source[index] == ')':
                    depth -= 1
                index += 1
            parts.append("")
            continue
        if char == '\\':
            index += 1
            if source.startswith('u{', index):
                end = source.index('}', index)
                parts[-1] += chr(int(source[index + 2:end], 16))
                index = end + 1
                continue
            char = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0'}.get(source[index], source[index])
        parts[-1] += char
        index += 1
    raise ValueError("Unterminated Swift string")


def main():
    missing = []
    checked = 0
    for folder in [ROOT / "TypeWhisper", ROOT / "TypeWhisperPluginSDK"]:
        for path in sorted(folder.rglob("*.swift")):
            if any(part in {".build", "Tests"} for part in path.relative_to(folder).parts):
                continue
            catalogs = list(path.parent.glob("*.xcstrings"))
            if not catalogs:
                for parent in path.parents:
                    if parent == ROOT:
                        break
                    catalogs = list((parent / "Resources").glob("*.xcstrings"))
                    if catalogs:
                        break
            if not catalogs:
                continue
            keys = set()
            for catalog in catalogs:
                keys.update(json.loads(catalog.read_text())["strings"])
            source = path.read_text()
            for match in CALL.finditer(source):
                if source[match.end():].startswith('""'):
                    continue
                parts, _ = literal(source, match.end())
                checked += 1
                if len(parts) == 1:
                    found = parts[0] in keys
                else:
                    found = any([part.replace('%%', '%') for part in FORMAT.split(key)] == parts for key in keys)
                if not found:
                    line = source.count('\n', 0, match.start()) + 1
                    missing.append(f"{path.relative_to(ROOT)}:{line}: {'<interpolation>'.join(parts)}")
    print('\n'.join(missing))
    print(f"检查 {checked} 个本地化调用，缺失 {len(missing)} 个键。")
    return bool(missing)


if __name__ == "__main__":
    sys.exit(main())
