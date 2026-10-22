#!/usr/bin/env python3
"""Writes the Jamf Pro custom schemas and the ProfileManifests files in deployment/macos.

Both describe the managed settings of TypeWhisper (docs/mdm/managed-settings.md) for the
direct download and the App Store edition. The keys come from make-typewhisper-profile.py,
which scripts/test_macos_managed_settings.py keeps equal to the app. Run this after adding a
key or changing a description, bump PROFILE_MANIFEST_VERSION, and commit the result.

Usage: scripts/update_macos_mdm_schemas.py [--check]
"""

import argparse
import datetime
import importlib.util
import json
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEPLOYMENT = ROOT / "deployment" / "macos"
DOCUMENTATION_URL = "https://github.com/schneidervvv/dictum/blob/main/docs/mdm/managed-settings.md"
PROFILE_MANIFEST_VERSION = 2
PROFILE_MANIFEST_MODIFIED = datetime.datetime(2026, 10, 23)
EDITIONS = {
    "com.schneidervvv.dictum": "dictum",
    "com.typewhisper.typewhisper-app": "dictum (App Store)",
}
RECOMMENDED_TITLE = "Recommended settings (users can change)"
RECOMMENDED_DESCRIPTION = "Defaults that apply until the user makes a choice."
DESCRIPTIONS = {
    "TranscriptionProviderId": ("Transcription provider", "Plugin ID of the transcription provider, or <plugin ID>:<provider ID> for one engine of a plugin with several. Set together with TranscriptionModelId."),
    "TranscriptionModelId": ("Transcription model", "Model ID as the provider lists it, for example parakeet-tdt-0.6b-v3. Set together with TranscriptionProviderId."),
    "LlmProviderId": ("Language model provider", "Plugin ID of the language model provider, <plugin ID>:<provider ID>, or com.typewhisper.apple-intelligence. Set together with LlmModelId."),
    "LlmModelId": ("Language model", "Model ID as the provider lists it. Set together with LlmProviderId."),
    "AllowedTranscriptionProviders": ("Allowed transcription providers", "Provider IDs that may receive audio. An empty list allows none."),
    "AllowedLlmProviders": ("Allowed language model providers", "Provider IDs that may receive text, including com.typewhisper.apple-intelligence. An empty list allows none."),
    "AllowedPlugins": ("Allowed plugins", "Plugin IDs that may be installed, loaded and enabled. An empty list allows none."),
    "AllowCloudTranscription": ("Allow cloud transcription", "Off keeps audio on the Mac: only plugins whose locality is local transcribe."),
    "AllowCloudTextProcessing": ("Allow cloud text processing", "Off keeps transcripts, prompts, dictionary terms and context on the Mac."),
    "AllowModelDownloads": ("Allow model downloads", "Off refuses model downloads. Installed models keep working."),
    "LaunchAtLogin": ("Launch at login", "Registers or removes dictum's login item and locks the setting."),
    "SkipOnboardingWhenReady": ("Skip setup when ready", "Keeps the setup wizard closed when an engine, the permissions and a dictation shortcut are ready."),
}
ENUMERATION_TITLES = {
}
JSON_TYPES = {"boolean": "boolean", "enumeration": "integer", "list": "array", "text": "string"}


def load_generator():
    spec = importlib.util.spec_from_file_location("make_typewhisper_profile", DEPLOYMENT / "make-typewhisper-profile.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GENERATOR = load_generator()
# Keys the App Store edition ignores, shared with the generator.
APP_STORE_IGNORED = GENERATOR.APP_STORE_IGNORED
# The app trims text and refuses it when it is blank or too long (ManagedPolicyValidator), and an
# invalid enforced value blocks its setting, so the editor refuses such values up front.
# The pattern refuses Unicode control characters (category Cc) and requires one non-blank character.
TEXT_PATTERN = "^[^\\u0000-\\u001F\\u007F-\\u009F]*[^\\s\\u0000-\\u001F\\u007F-\\u009F][^\\u0000-\\u001F\\u007F-\\u009F]*$"
TEXT_CONSTRAINTS = {"type": "string", "minLength": 1, "maxLength": GENERATOR.MAXIMUM_TEXT_LENGTH, "pattern": TEXT_PATTERN}


def load_keys():
    return GENERATOR.KEYS


def keys_for(domain, keys):
    return [
        (name, kind, recommendable, maximum)
        for name, (kind, recommendable, maximum) in keys.items()
        if domain == "com.schneidervvv.dictum" or name not in APP_STORE_IGNORED
    ]


def jamf_property(name, kind, maximum, order):
    title, description = DESCRIPTIONS[name]
    configured = {"title": "Configured", "type": JSON_TYPES[kind]}
    if kind == "enumeration":
        configured["enum"] = list(range(maximum + 1))
        configured["options"] = {"enum_titles": ENUMERATION_TITLES[name]}
    elif kind == "list":
        configured["items"] = {"title": "ID", **TEXT_CONSTRAINTS}
        configured["maxItems"] = GENERATOR.MAXIMUM_LIST_ENTRIES
    elif kind == "text":
        configured.update(TEXT_CONSTRAINTS)
    # "Not Configured" keeps Jamf Pro from writing a value for keys the administrator leaves alone.
    return {
        "title": title,
        "description": description,
        "property_order": order,
        "links": [{"rel": "More information", "href": DOCUMENTATION_URL}],
        "anyOf": [{"type": "null", "title": "Not Configured"}, configured],
    }


def jamf_schema(domain, keys):
    entries = keys_for(domain, keys)
    properties = {
        name: jamf_property(name, kind, maximum, 5 * index)
        for index, (name, kind, _, maximum) in enumerate(entries, start=1)
    }
    recommended = {
        name: jamf_property(name, kind, maximum, 5 * index)
        for index, (name, kind, _, maximum) in enumerate([entry for entry in entries if entry[2]], start=1)
    }
    properties["Recommended"] = {
        "title": RECOMMENDED_TITLE,
        "description": RECOMMENDED_DESCRIPTION,
        "property_order": 5 * (len(properties) + 1),
        "anyOf": [
            {"type": "null", "title": "Not Configured"},
            {"title": "Configured", "type": "object", "properties": recommended},
        ],
    }
    return {
        "title": f"{EDITIONS[domain]} ({domain})",
        "description": f"Managed settings for {EDITIONS[domain]}. Only configure the keys you manage.",
        "__preferencedomain": domain,
        "properties": properties,
    }


def manifest_setting(name, kind, maximum):
    title, description = DESCRIPTIONS[name]
    setting = {
        "pfm_name": name,
        "pfm_title": title,
        "pfm_description": description,
        "pfm_documentation_url": DOCUMENTATION_URL,
        "pfm_type": JSON_TYPES[kind],
    }
    if kind == "enumeration":
        setting["pfm_range_list"] = list(range(maximum + 1))
        setting["pfm_range_list_titles"] = ENUMERATION_TITLES[name]
    elif kind == "list":
        setting["pfm_subkeys"] = [{"pfm_name": "ID", "pfm_type": "string"}]
    return setting


def payload_key(name, value_type, title, default=None, required=True):
    key = {"pfm_name": name, "pfm_type": value_type, "pfm_title": title, "pfm_require": "always" if required else "push"}
    if default is not None:
        key["pfm_default"] = default
    return key


def profile_manifest(domain, keys):
    entries = keys_for(domain, keys)
    settings = [manifest_setting(name, kind, maximum) for name, kind, _, maximum in entries]
    settings.append({
        "pfm_name": "Recommended",
        "pfm_title": RECOMMENDED_TITLE,
        "pfm_description": RECOMMENDED_DESCRIPTION,
        "pfm_type": "dictionary",
        "pfm_subkeys": [manifest_setting(name, kind, maximum) for name, kind, recommendable, maximum in entries if recommendable],
    })
    payload_keys = [
        payload_key("PayloadDescription", "string", "Payload Description", "Managed settings for dictum", required=False),
        payload_key("PayloadDisplayName", "string", "Payload Display Name", EDITIONS[domain]),
        payload_key("PayloadIdentifier", "string", "Payload Identifier", domain),
        payload_key("PayloadType", "string", "Payload Type", domain),
        payload_key("PayloadUUID", "string", "Payload UUID"),
        payload_key("PayloadVersion", "integer", "Payload Version", 1),
        payload_key("PayloadOrganization", "string", "Payload Organization", required=False),
    ]
    return {
        "pfm_app_url": "https://github.com/schneidervvv/dictum",
        "pfm_description": f"Managed settings for {EDITIONS[domain]}.",
        "pfm_documentation_url": DOCUMENTATION_URL,
        "pfm_domain": domain,
        "pfm_format_version": 1,
        "pfm_last_modified": PROFILE_MANIFEST_MODIFIED,
        "pfm_platforms": ["macOS"],
        "pfm_title": EDITIONS[domain],
        "pfm_unique": True,
        "pfm_version": PROFILE_MANIFEST_VERSION,
        "pfm_subkeys": payload_keys + settings,
    }


def rendered_files(keys):
    files = {}
    for domain in EDITIONS:
        files[DEPLOYMENT / "jamf" / f"{domain}.json"] = (json.dumps(jamf_schema(domain, keys), indent=2) + "\n").encode()
        files[DEPLOYMENT / "ProfileManifests" / f"{domain}.plist"] = plistlib.dumps(profile_manifest(domain, keys))
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if a file is out of date instead of writing it")
    args = parser.parse_args(argv)
    keys = load_keys()
    missing = sorted(set(keys) - set(DESCRIPTIONS))
    if missing:
        print(f"error: add a title and description for {', '.join(missing)}", file=sys.stderr)
        return 2
    stale = []
    for path, content in rendered_files(keys).items():
        if path.exists() and path.read_bytes() == content:
            continue
        if args.check:
            stale.append(path.relative_to(ROOT))
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        print(f"Wrote {path.relative_to(ROOT)}")
    if stale:
        print("error: out of date, run scripts/update_macos_mdm_schemas.py: " + ", ".join(map(str, stale)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
