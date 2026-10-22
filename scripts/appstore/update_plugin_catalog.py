#!/usr/bin/env python3
"""从本地插件清单生成 App Store 构建审计目录。"""

import argparse
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = ROOT / "appstore-project.yml"
PLUGINS = ROOT / "TypeWhisperPluginSDK" / "Plugins"
OUTPUT = ROOT / "AppStore" / "Resources" / "AppStorePluginCatalog.json"
METADATA_KEYS = (
    "name", "author", "description", "descriptions", "category", "categories",
    "capabilities", "iconSystemName", "requiresAPIKey", "hosting", "locality",
    "detailsURL", "homepageURL", "iconURL", "iconDarkURL",
)
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


def main():
    parser = argparse.ArgumentParser()
    parser.parse_args()
    catalog = []
    for target in bundled_plugin_targets():
        manifest = json.loads((PLUGINS / target / "manifest.json").read_text())
        entry = {"id": manifest["id"], "bundleName": f"{target}.bundle"}
        for key in METADATA_KEYS:
            value = manifest.get(key)
            if value is not None:
                entry[key] = value
        entry.update(APP_STORE_OVERRIDES.get(manifest["id"], {}))
        entry.setdefault("name", manifest["name"])
        entry.setdefault("author", manifest.get("author") or "TypeWhisper")
        entry.setdefault("description", manifest["name"])
        catalog.append(entry)

    catalog.sort(key=lambda item: item["id"])
    OUTPUT.write_text(json.dumps({"schemaVersion": 1, "plugins": catalog}, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote {len(catalog)} plugins to {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
