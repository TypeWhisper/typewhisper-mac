#!/usr/bin/env python3
"""Builds a configuration profile with dictum managed settings.

Values are checked against the keys dictum understands (docs/mdm/managed-settings.md)
before the profile is written, so a typo fails here instead of on the Macs. Each payload sets the
managed preferences of one domain, so System Settings lists every setting with its value.

Examples:

  # Keep audio and text on the Mac and require Parakeet v3 for transcription.
  make-typewhisper-profile.py \\
      --set AllowCloudTranscription=false --set AllowCloudTextProcessing=false \\
      --set TranscriptionProviderId=com.typewhisper.parakeet \\
      --set TranscriptionModelId=parakeet-tdt-0.6b-v3 \\
      --output dictum-LocalOnly.mobileconfig

Lists are comma-separated; an empty value denies everything. Booleans accept true or false.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import sys
import tempfile
import unicodedata
import uuid
from pathlib import Path

# Mirrors ManagedPolicyKeys.all in dictum/Models/ManagedPolicy.swift; a test keeps them equal.
# name: (kind, may be recommended, largest enumeration value)
KEYS = {
    "TranscriptionProviderId": ("text", True, 0),
    "TranscriptionModelId": ("text", True, 0),
    "LlmProviderId": ("text", True, 0),
    "LlmModelId": ("text", True, 0),
    "AllowedTranscriptionProviders": ("list", False, 0),
    "AllowedLlmProviders": ("list", False, 0),
    "AllowedPlugins": ("list", False, 0),
    "AllowCloudTranscription": ("boolean", False, 0),
    "AllowCloudTextProcessing": ("boolean", False, 0),
    "AllowModelDownloads": ("boolean", False, 0),
    "LaunchAtLogin": ("boolean", True, 0),
    "SkipOnboardingWhenReady": ("boolean", False, 0),
}
PAIRS = [("TranscriptionProviderId", "TranscriptionModelId"), ("LlmProviderId", "LlmModelId")]
ENUMERATION_NAMES = {
}
DOMAINS = (
    "com.schneidervvv.dictum",
    "com.typewhisper.typewhisper-app",
    "com.schneidervvv.dictum.dev",
    "com.typewhisper.typewhisper-app.dev",
)
APP_STORE_DOMAINS = ("com.typewhisper.typewhisper-app", "com.typewhisper.typewhisper-app.dev")
# Keys the App Store edition ignores (notApplicable in ManagedSettingsView.swift); a test keeps
# them equal. They are left out of App Store payloads, where they would only be reported.
APP_STORE_IGNORED = frozenset()
MAXIMUM_TEXT_LENGTH = 1024
MAXIMUM_LIST_ENTRIES = 256
# Reverse-DNS style, as configuration profiles require for PayloadIdentifier.
IDENTIFIER_PATTERN = re.compile(r"[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+")


class ProfileError(ValueError):
    pass


def parse_text(name: str, raw: str) -> str:
    text = raw.strip()
    if not text:
        raise ProfileError(f"{name} must not be empty")
    if len(text) > MAXIMUM_TEXT_LENGTH:
        raise ProfileError(f"{name} must not exceed {MAXIMUM_TEXT_LENGTH} characters")
    # The app rejects every scalar in Unicode's control category, not only ASCII controls.
    if any(unicodedata.category(character) == "Cc" for character in text):
        raise ProfileError(f"{name} must not contain control characters")
    return text


def parse_value(name: str, raw: str):
    if name not in KEYS:
        close = [key for key in KEYS if key.lower() == name.lower()]
        hint = f" (did you mean {close[0]}?)" if close else ""
        raise ProfileError(f"unknown key {name}{hint}")
    kind, _, maximum = KEYS[name]
    if kind == "boolean":
        lowered = raw.strip().lower()
        if lowered not in ("true", "false"):
            raise ProfileError(f"{name} must be true or false")
        return lowered == "true"
    if kind == "enumeration":
        lowered = raw.strip().lower()
        named = ENUMERATION_NAMES.get(name, {})
        if lowered in named:
            return named[lowered]
        if lowered.isdigit() and 0 <= int(lowered) <= maximum:
            return int(lowered)
        names = ", ".join(named) or "numbers"
        raise ProfileError(f"{name} must be one of {names} or 0 to {maximum}")
    if kind == "list":
        items = []
        for entry in raw.split(",") if raw.strip() else []:
            item = parse_text(name, entry)
            if item not in items:
                items.append(item)
        if len(items) > MAXIMUM_LIST_ENTRIES:
            raise ProfileError(f"{name} must not exceed {MAXIMUM_LIST_ENTRIES} entries")
        return items
    return parse_text(name, raw)


def parse_assignments(assignments: list[str], recommended: bool) -> dict:
    values = {}
    for assignment in assignments:
        name, separator, raw = assignment.partition("=")
        name = name.strip()
        if not separator:
            raise ProfileError(f"expected KEY=VALUE, got {assignment!r}")
        if recommended and name in KEYS and not KEYS[name][1]:
            raise ProfileError(f"{name} can only be enforced, not recommended")
        if name in values:
            raise ProfileError(f"{name} is set twice")
        values[name] = parse_value(name, raw)
    for first, second in PAIRS:
        if (first in values) != (second in values):
            raise ProfileError(f"{first} and {second} must be set together")
    return values


def stable_uuid(*parts: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "/".join(parts))).upper()


def settings_for(domain: str, enforced: dict, recommended: dict) -> dict:
    ignored = APP_STORE_IGNORED if domain in APP_STORE_DOMAINS else frozenset()
    settings = {key: value for key, value in enforced.items() if key not in ignored}
    kept = {key: value for key, value in recommended.items() if key not in ignored}
    if kept:
        settings["Recommended"] = kept
    return settings


def build_profile(
    enforced: dict,
    recommended: dict,
    *,
    domains: list[str],
    identifier: str,
    name: str,
    organization: str | None,
    scope: str,
    notes: list[str] | None = None,
) -> dict:
    if not enforced and not recommended:
        raise ProfileError("set at least one value with --set or --recommend")
    if not IDENTIFIER_PATTERN.fullmatch(identifier):
        raise ProfileError(f"--identifier must be reverse-DNS style, for example com.example.typewhisper, got {identifier!r}")
    payloads = []
    # A repeated domain would add a second payload with the same identifier and UUID.
    for domain in dict.fromkeys(domains):
        settings = settings_for(domain, enforced, recommended)
        left_out = sorted(APP_STORE_IGNORED.intersection(enforced) | APP_STORE_IGNORED.intersection(recommended)) \
            if domain in APP_STORE_DOMAINS else []
        if left_out and notes is not None:
            notes.append(f"{domain}: left out {', '.join(left_out)}, which the App Store edition ignores")
        if not settings:
            continue
        # A payload whose type is the domain forces its other keys, like the custom settings
        # payload, and System Settings shows them as a list of settings instead of a property list.
        payloads.append({
            "PayloadType": domain,
            "PayloadVersion": 1,
            "PayloadIdentifier": f"{identifier}.{domain}",
            "PayloadUUID": stable_uuid(identifier, domain),
            "PayloadDisplayName": f"dictum managed settings ({domain})",
            **settings,
        })
    if not payloads:
        raise ProfileError("none of the values apply to the App Store edition; add --domain com.schneidervvv.dictum")
    profile = {
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadIdentifier": identifier,
        "PayloadUUID": stable_uuid(identifier),
        "PayloadDisplayName": name,
        "PayloadDescription": "Managed settings for dictum. See docs/mdm/managed-settings.md.",
        "PayloadScope": scope,
        "PayloadContent": payloads,
    }
    if organization:
        profile["PayloadOrganization"] = organization
    return profile


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--set", action="append", default=[], metavar="KEY=VALUE", help="enforced value")
    parser.add_argument("--recommend", action="append", default=[], metavar="KEY=VALUE", help="recommended value users may change")
    parser.add_argument("--domain", action="append", choices=DOMAINS, help="preference domain; repeat for both editions (default: com.schneidervvv.dictum)")
    parser.add_argument("--identifier", default="com.typewhisper.mdm.settings", help="profile identifier; keep it to replace a deployed profile")
    parser.add_argument("--name", default="dictum Managed Settings", help="profile display name")
    parser.add_argument("--organization", help="PayloadOrganization")
    parser.add_argument("--scope", choices=("System", "User"), default="System")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    notes: list[str] = []
    try:
        profile = build_profile(
            parse_assignments(args.set, recommended=False),
            parse_assignments(args.recommend, recommended=True),
            domains=args.domain or ["com.schneidervvv.dictum"],
            identifier=args.identifier,
            name=parse_text("--name", args.name),
            organization=parse_text("--organization", args.organization) if args.organization is not None else None,
            scope=args.scope,
            notes=notes,
        )
    except ProfileError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    for note in notes:
        print(f"note: {note}", file=sys.stderr)
    # Serialized first and written next to the output, which it then replaces in one step, so a
    # failure cannot leave a partly written profile behind.
    data = plistlib.dumps(profile)
    directory = args.output.resolve().parent
    with tempfile.NamedTemporaryFile(dir=directory, prefix=f".{args.output.name}.", delete=False) as file:
        file.write(data)
        temporary = Path(file.name)
    try:
        # Temporary files are private; give the profile the permissions a plain write would.
        umask = os.umask(0)
        os.umask(umask)
        os.chmod(temporary, 0o666 & ~umask)
        os.replace(temporary, args.output)
    except OSError:
        temporary.unlink(missing_ok=True)
        raise
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
