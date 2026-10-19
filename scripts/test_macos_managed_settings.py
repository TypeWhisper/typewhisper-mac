#!/usr/bin/env python3
"""Keeps the macOS deployment files in deployment/macos equal to the managed settings the
app understands (ManagedPolicyKeys.all in TypeWhisper/Models/ManagedPolicy.swift)."""

import contextlib
import importlib.util
import io
import json
import plistlib
import re
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEPLOYMENT = REPO_ROOT / "deployment" / "macos"
POLICY_SOURCE = REPO_ROOT / "TypeWhisper" / "Models" / "ManagedPolicy.swift"
DEFAULTS_SOURCE = REPO_ROOT / "TypeWhisper" / "App" / "UserDefaultsKeys.swift"
SETTINGS_VIEW_SOURCE = REPO_ROOT / "TypeWhisper" / "Views" / "ManagedSettingsView.swift"
DOCUMENTATION = REPO_ROOT / "docs" / "mdm" / "managed-settings.md"
EDITION_DOMAINS = ("com.typewhisper.mac", "com.typewhisper.typewhisper-app")
TEAM_IDENTIFIER = "2D8ALY3LCL"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def swift_constants():
    """Maps the ManagedPolicyKeys constants to their key names."""
    source = POLICY_SOURCE.read_text()
    defaults = dict(re.findall(r'static let (\w+) = "([^"]*)"', DEFAULTS_SOURCE.read_text()))
    constants = {}
    for constant, value in re.findall(r"static let (\w+) = (\"[^\"]*\"|UserDefaultsKeys\.\w+)", source):
        if value.startswith('"'):
            constants[constant] = value.strip('"')
        else:
            constants[constant] = defaults[value.split(".", 1)[1]]
    return constants


def swift_catalog():
    """Returns {name: (kind, recommendable, maximum, paired with)} from ManagedPolicyKeys.all."""
    source = POLICY_SOURCE.read_text()
    constants = swift_constants()
    body = source.split("static let all: [ManagedPolicyDefinition] = [", 1)[1].split("\n    ]", 1)[0] + "\n"
    catalog = {}
    for arguments in re.findall(r"\.init\((.*)\),?\n", body):
        name = constants[re.search(r"name: (\w+)", arguments).group(1)]
        kind = re.search(r"kind: \.(\w+)", arguments).group(1)
        maximum = re.search(r"enumerationMaximum: (\d+)", arguments)
        paired = re.search(r"pairedWith: (\w+)", arguments)
        catalog[name] = (
            kind,
            "allowsRecommendation: true" in arguments,
            int(maximum.group(1)) if maximum else 0,
            constants[paired.group(1)] if paired else None,
        )
    return catalog


def swift_app_store_ignored():
    """Returns the keys ManagedSettingsSection.problems reports as ignored by the App Store edition."""
    source = SETTINGS_VIEW_SOURCE.read_text()
    body = source.split("let notApplicable = [", 1)[1].split("]", 1)[0]
    constants = swift_constants()
    return {constants[constant] for constant in re.findall(r"ManagedPolicyKeys\.(\w+)", body)}


GENERATOR = load_module("make_typewhisper_profile", DEPLOYMENT / "make-typewhisper-profile.py")
SCHEMAS = load_module("update_macos_mdm_schemas", REPO_ROOT / "scripts" / "update_macos_mdm_schemas.py")
CATALOG = swift_catalog()
APP_STORE_IGNORED = swift_app_store_ignored()
RECOMMENDABLE = {name for name, (_, recommendable, _, _) in CATALOG.items() if recommendable}
VALUE_TYPES = {"boolean": "boolean", "enumeration": "integer", "list": "array", "text": "string"}


def edition_keys(domain):
    if domain.startswith("com.typewhisper.typewhisper-app"):
        return set(CATALOG) - APP_STORE_IGNORED
    return set(CATALOG)


def check_value(test, name, value):
    kind, _, maximum, _ = CATALOG[name]
    if kind == "boolean":
        test.assertIsInstance(value, bool, name)
    elif kind == "enumeration":
        test.assertTrue(isinstance(value, int) and not isinstance(value, bool), name)
        test.assertTrue(0 <= value <= maximum, name)
    elif kind == "list":
        test.assertIsInstance(value, list, name)
        test.assertTrue(all(isinstance(item, str) and item.strip() for item in value), name)
    else:
        test.assertIsInstance(value, str, name)
        test.assertTrue(value.strip(), name)


class CatalogTests(unittest.TestCase):
    def test_reads_the_swift_catalog(self):
        self.assertEqual(len(CATALOG), 18)
        self.assertEqual(CATALOG["UpdateMode"], ("enumeration", False, 2, None))
        self.assertEqual(CATALOG["ManagedLicenseKey"], ("text", False, 0, None))
        self.assertEqual(CATALOG["TranscriptionProviderId"][3], "TranscriptionModelId")

    def test_generator_keys_match_the_app(self):
        generator = {name: tuple(spec) for name, spec in GENERATOR.KEYS.items()}
        expected = {name: (kind, recommendable, maximum) for name, (kind, recommendable, maximum, _) in CATALOG.items()}
        self.assertEqual(generator, expected)

    def test_generator_pairs_match_the_app(self):
        expected = {frozenset((name, paired)) for name, (_, _, _, paired) in CATALOG.items() if paired}
        self.assertEqual({frozenset(pair) for pair in GENERATOR.PAIRS}, expected)

    def test_schema_script_matches_the_app(self):
        self.assertEqual(SCHEMAS.APP_STORE_IGNORED, APP_STORE_IGNORED)
        self.assertEqual(len(APP_STORE_IGNORED), 5)
        self.assertEqual(set(SCHEMAS.DESCRIPTIONS), set(CATALOG))
        for name, (kind, _, maximum, _) in CATALOG.items():
            if kind == "enumeration":
                self.assertEqual(len(SCHEMAS.ENUMERATION_TITLES[name]), maximum + 1, name)

    def test_schema_files_are_up_to_date(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            status = SCHEMAS.main(["--check"])
        self.assertEqual(status, 0, stderr.getvalue())

    def test_documentation_names_every_key(self):
        documentation = DOCUMENTATION.read_text()
        for name in CATALOG:
            self.assertIn(f"`{name}`", documentation, name)


class GeneratorTests(unittest.TestCase):
    def generate(self, *arguments):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "profile.mobileconfig"
            stderr = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
                status = GENERATOR.main([*arguments, "--output", str(output)])
            profile = plistlib.loads(output.read_bytes()) if status == 0 else None
            return status, profile, stderr.getvalue()

    def settings(self, profile, domain="com.typewhisper.mac"):
        payload = next(item for item in profile["PayloadContent"] if domain in item["PayloadContent"])
        return payload["PayloadContent"][domain]["Forced"][0]["mcx_preference_settings"]

    def test_writes_enforced_and_recommended_values(self):
        status, profile, _ = self.generate(
            "--set", "AllowCloudTranscription=false",
            "--set", "UpdateMode=check-only",
            "--set", "AllowedUpdateChannels=stable,daily",
            "--set", "AllowedPlugins=",
            "--recommend", "UpdateChannel=release-candidate",
            "--recommend", "LaunchAtLogin=true",
        )
        self.assertEqual(status, 0)
        self.assertEqual(self.settings(profile), {
            "AllowCloudTranscription": False,
            "UpdateMode": 1,
            "AllowedUpdateChannels": ["stable", "daily"],
            "AllowedPlugins": [],
            "Recommended": {"UpdateChannel": 2, "LaunchAtLogin": True},
        })
        self.assertEqual(profile["PayloadContent"][0]["PayloadType"], "com.apple.ManagedClient.preferences")

    def test_writes_one_payload_per_domain_with_stable_identifiers(self):
        arguments = ["--set", "SuppressOptionalPrompts=true", "--domain", EDITION_DOMAINS[0], "--domain", EDITION_DOMAINS[1]]
        _, first, _ = self.generate(*arguments)
        _, second, _ = self.generate(*arguments)
        self.assertEqual(first, second)
        self.assertEqual([next(iter(item["PayloadContent"])) for item in first["PayloadContent"]], list(EDITION_DOMAINS))
        uuids = [first["PayloadUUID"]] + [item["PayloadUUID"] for item in first["PayloadContent"]]
        self.assertEqual(len(set(uuids)), 3)

    def test_writes_a_repeated_domain_once(self):
        _, profile, _ = self.generate(
            "--set", "SuppressOptionalPrompts=true",
            "--domain", EDITION_DOMAINS[0], "--domain", EDITION_DOMAINS[0], "--domain", EDITION_DOMAINS[1],
        )
        self.assertEqual([next(iter(item["PayloadContent"])) for item in profile["PayloadContent"]], list(EDITION_DOMAINS))

    def test_refuses_invalid_input(self):
        cases = [
            (["--set", "updateMode=external"], "did you mean UpdateMode?"),
            (["--set", "AllowCloudTranscription=1"], "true or false"),
            (["--set", "UpdateMode=3"], "UpdateMode must be one of"),
            (["--set", "AllowedUpdateChannels=beta"], "stable, daily, release-candidate or none"),
            (["--recommend", "AllowPluginDownloads=false"], "can only be enforced"),
            (["--set", "TranscriptionProviderId=com.typewhisper.parakeet"], "must be set together"),
            (["--set", "LlmModelId= "], "must not be empty"),
            (["--set", "UpdateMode=0", "--set", "UpdateMode=1"], "set twice"),
            ([], "at least one value"),
        ]
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                status, _, stderr = self.generate(*arguments)
                self.assertEqual(status, 2)
                self.assertIn(message, stderr)


class ProfileTests(unittest.TestCase):
    def test_example_profiles_hold_only_supported_values(self):
        profiles = sorted((DEPLOYMENT / "examples").glob("*.mobileconfig"))
        self.assertGreaterEqual(len(profiles), 6)
        seen_preferences = False
        for path in profiles:
            with self.subTest(profile=path.name):
                profile = plistlib.loads(path.read_bytes())
                self.assertEqual(profile["PayloadType"], "Configuration")
                uuids = [profile["PayloadUUID"]]
                for payload in profile["PayloadContent"]:
                    uuids.append(payload["PayloadUUID"])
                    if payload["PayloadType"] == "com.apple.ManagedClient.preferences":
                        seen_preferences = True
                        for domain, content in payload["PayloadContent"].items():
                            self.assertIn(domain, GENERATOR.DOMAINS)
                            self.check_settings(domain, content["Forced"][0]["mcx_preference_settings"])
                    elif payload["PayloadType"] == "com.apple.servicemanagement":
                        for rule in payload["Rules"]:
                            self.assertIn(rule["RuleValue"], EDITION_DOMAINS)
                            self.assertEqual(rule["TeamIdentifier"], TEAM_IDENTIFIER)
                    elif payload["PayloadType"] == "com.apple.TCC.configuration-profile-policy":
                        for entries in payload["Services"].values():
                            for entry in entries:
                                self.assertIn(entry["Identifier"], EDITION_DOMAINS)
                                self.assertIn(f'identifier "{entry["Identifier"]}"', entry["CodeRequirement"])
                                self.assertIn(f'certificate leaf[subject.OU] = "{TEAM_IDENTIFIER}"', entry["CodeRequirement"])
                    else:
                        self.fail(f"unexpected payload type {payload['PayloadType']}")
                self.assertEqual(len(set(uuids)), len(uuids))
        self.assertTrue(seen_preferences)

    def check_settings(self, domain, settings):
        recommended = settings.get("Recommended", {})
        for name, value in settings.items():
            if name == "Recommended":
                continue
            self.assertIn(name, edition_keys(domain))
            check_value(self, name, value)
        for name, value in recommended.items():
            self.assertIn(name, RECOMMENDABLE & edition_keys(domain))
            check_value(self, name, value)
        for scope in (settings, recommended):
            for name, (_, _, _, paired) in CATALOG.items():
                if paired and name in scope:
                    self.assertIn(paired, scope)


class SchemaTests(unittest.TestCase):
    def configured(self, prop):
        """The value schema of a Jamf property that offers "Not Configured"."""
        unset, configured = prop["anyOf"]
        self.assertEqual(unset, {"type": "null", "title": "Not Configured"})
        return configured

    def check_jamf_property(self, name, prop):
        kind, _, maximum, _ = CATALOG[name]
        configured = self.configured(prop)
        self.assertEqual(configured["type"], VALUE_TYPES[kind], name)
        if kind == "enumeration":
            self.assertEqual(configured["enum"], list(range(maximum + 1)), name)
            self.assertEqual(len(configured["options"]["enum_titles"]), maximum + 1, name)
        if kind == "list":
            self.assertEqual(configured["items"]["type"], "string", name)

    def test_jamf_schemas_describe_the_catalog(self):
        for domain in EDITION_DOMAINS:
            with self.subTest(domain=domain):
                schema = json.loads((DEPLOYMENT / "jamf" / f"{domain}.json").read_text())
                self.assertEqual(schema["__preferencedomain"], domain)
                properties = dict(schema["properties"])
                recommended = self.configured(properties.pop("Recommended"))
                self.assertEqual(set(properties), edition_keys(domain))
                self.assertEqual(recommended["type"], "object")
                self.assertEqual(set(recommended["properties"]), RECOMMENDABLE & edition_keys(domain))
                for scope in (properties, recommended["properties"]):
                    for name, prop in scope.items():
                        self.check_jamf_property(name, prop)

    def test_profile_manifests_describe_the_catalog(self):
        for domain in EDITION_DOMAINS:
            with self.subTest(domain=domain):
                manifest = plistlib.loads((DEPLOYMENT / "ProfileManifests" / f"{domain}.plist").read_bytes())
                self.assertEqual(manifest["pfm_domain"], domain)
                settings = {key["pfm_name"]: key for key in manifest["pfm_subkeys"] if not key["pfm_name"].startswith("Payload")}
                recommended = settings.pop("Recommended")
                self.assertEqual(set(settings), edition_keys(domain))
                self.assertEqual(recommended["pfm_type"], "dictionary")
                nested = {key["pfm_name"]: key for key in recommended["pfm_subkeys"]}
                self.assertEqual(set(nested), RECOMMENDABLE & edition_keys(domain))
                for scope in (settings, nested):
                    for name, key in scope.items():
                        kind, _, maximum, _ = CATALOG[name]
                        self.assertEqual(key["pfm_type"], VALUE_TYPES[kind], name)
                        if kind == "enumeration":
                            self.assertEqual(key["pfm_range_list"], list(range(maximum + 1)), name)
                            self.assertEqual(len(key["pfm_range_list_titles"]), maximum + 1, name)
                if "ManagedLicenseKey" in settings:
                    self.assertTrue(settings["ManagedLicenseKey"].get("pfm_sensitive"))


if __name__ == "__main__":
    unittest.main()
