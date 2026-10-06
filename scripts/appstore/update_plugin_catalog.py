#!/usr/bin/env python3
"""Writes AppStore/Resources/AppStorePluginCatalog.json.

The Mac App Store edition cannot download plugins. Its marketplace lists the
first-party plugins that are signed into the app bundle instead. This script
takes the plugin targets from appstore-project.yml and copies their store
metadata (descriptions, categories, links) from the public registry feed, so
the marketplace reads the same as in the direct-distribution app.

Usage: scripts/appstore/update_plugin_catalog.py [--feed path-or-url]
"""

import argparse
import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = ROOT / "appstore-project.yml"
PLUGINS = ROOT / "TypeWhisperPluginSDK" / "Plugins"
OUTPUT = ROOT / "AppStore" / "Resources" / "AppStorePluginCatalog.json"
DEFAULT_FEED = "https://typewhisper.github.io/typewhisper-mac/plugins-community-v1.json"
METADATA_KEYS = (
    "name", "author", "description", "descriptions", "category", "categories",
    "capabilities", "iconSystemName", "requiresAPIKey", "hosting",
    "detailsURL", "homepageURL", "iconURL", "iconDarkURL",
)
# Metadata for plugins whose App Store build drops features that the registry
# feed describes.
APP_STORE_OVERRIDES = {
    "com.typewhisper.openai": {
        "name": "OpenAI",
        "description": "Cloud transcription, prompt processing, and text-to-speech with your OpenAI API key.",
        "descriptions": {
            "de": "Cloud-Transkription, Prompt-Verarbeitung und Text-to-Speech mit deinem OpenAI-API-Key.",
            "ja": "OpenAI APIキーで、クラウド文字起こし、プロンプト処理、音声合成を利用できます。",
        },
        "requiresAPIKey": True,
    },
    "com.typewhisper.mcp-client": {
        "description": "Connect TypeWhisper workflows to remote MCP tools over Streamable HTTP.",
        "descriptions": {
            "de": "TypeWhisper-Workflows über Streamable HTTP mit entfernten MCP-Tools verbinden.",
            "ja": "TypeWhisperのワークフローをStreamable HTTP経由でリモートのMCPツールに接続します。",
            "zh-Hans": "通过 Streamable HTTP 将 TypeWhisper 工作流连接到远程 MCP 工具。",
        },
    },
}


def bundled_plugin_targets():
    targets = []
    current = None
    for line in SPEC.read_text().splitlines():
        match = re.match(r"^  (\w+):\s*$", line)
        if match:
            current = match.group(1)
            continue
        if current and re.match(r"^    templates: \[AppStorePlugin\]\s*$", line):
            targets.append(current)
    return targets


def load_feed(location):
    if re.match(r"^https?://", location):
        with urllib.request.urlopen(location, timeout=30) as response:
            return json.load(response)
    return json.loads(pathlib.Path(location).read_text())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--feed", default=DEFAULT_FEED)
    args = parser.parse_args()

    feed = {entry["id"]: entry for entry in load_feed(args.feed)["plugins"]}
    catalog = []
    for target in bundled_plugin_targets():
        manifest = json.loads((PLUGINS / target / "manifest.json").read_text())
        entry = {"id": manifest["id"], "bundleName": f"{target}.bundle"}
        source = feed.get(manifest["id"], {})
        for key in METADATA_KEYS:
            value = source.get(key, manifest.get(key))
            if value is not None:
                entry[key] = value
        entry.update(APP_STORE_OVERRIDES.get(manifest["id"], {}))
        entry.setdefault("name", manifest["name"])
        entry.setdefault("author", manifest.get("author") or "TypeWhisper")
        entry.setdefault("description", manifest["name"])
        if manifest["id"] not in feed:
            print(f"warning: {manifest['id']} is not in the registry feed", file=sys.stderr)
        catalog.append(entry)

    catalog.sort(key=lambda item: item["id"])
    OUTPUT.write_text(json.dumps({"schemaVersion": 1, "plugins": catalog}, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote {len(catalog)} plugins to {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
