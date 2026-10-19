#!/usr/bin/env python3

import unittest
from pathlib import Path

from check_app_version_sync import (
    APPSTORE_XCCONFIG,
    PBXPROJ,
    REPO_ROOT,
    VersionSyncError,
    check,
)


def pbxproj(app_versions=("1.8.0", "1.8.0"), first_version=None) -> str:
    """Minimal project shaped like the real one: one-line objects, IDs that are
    not hexadecimal, a TargetAttributes entry keyed by the target ID, uneven
    indentation and a plugin target listed before the app target."""
    debug, release = app_versions
    first = first_version or debug
    return f"""// !$*UTF8*$!
{{
	objects = {{
/* Begin PBXBuildFile section */
		AA0000000000000000000050 /* App.swift in Sources */ = {{isa = PBXBuildFile; fileRef = AA0000000000000000000051; }};
/* End PBXBuildFile section */
/* Begin PBXNativeTarget section */
		AA0000000000000000000001 /* Plugin */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = AA0000000000000000000010 /* list */;
			name = Plugin;
		}};
		DD00000000000000000001 /* TypeWhisper */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = FF00000000000000000030 /* list */;
			name = TypeWhisper;
		}};
/* End PBXNativeTarget section */
/* Begin PBXProject section */
		AA0000000000000000000060 /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				TargetAttributes = {{
					DD00000000000000000001 = {{
						CreatedOnToolsVersion = 16.0;
					}};
				}};
			}};
		}};
/* End PBXProject section */
/* Begin XCBuildConfiguration section */
		AA0000000000000000000099 /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				MARKETING_VERSION = {first};
			}};
			name = Debug;
		}};
			XX00000000000000000003 /* Debug */ = {{
				isa = XCBuildConfiguration;
				buildSettings = {{
					MARKETING_VERSION = {debug};
				}};
				name = Debug;
			}};
		XX00000000000000000004 /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				MARKETING_VERSION = {release};
			}};
			name = Release;
		}};
		AA0000000000000000000011 /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				MARKETING_VERSION = 1.0.3;
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */
/* Begin XCConfigurationList section */
		AA0000000000000000000010 /* list */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				AA0000000000000000000011 /* Release */,
			);
		}};
		FF00000000000000000030 /* list */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				XX00000000000000000003 /* Debug */,
				XX00000000000000000004 /* Release */,
			);
		}};
/* End XCConfigurationList section */
	}};
}}
"""


def xcconfig(version: str = "1.8.0") -> str:
    return f"// App Store\nPRODUCT_NAME = TypeWhisper\nMARKETING_VERSION = {version}\nCURRENT_PROJECT_VERSION = 1\n"


class CheckAppVersionSyncTests(unittest.TestCase):
    def test_matching_versions_pass(self) -> None:
        self.assertEqual(check(pbxproj(), xcconfig()), "1.8.0")

    def test_app_store_version_must_match(self) -> None:
        with self.assertRaisesRegex(VersionSyncError, "App Store edition is 1.8.1"):
            check(pbxproj(), xcconfig("1.8.1"))

    def test_app_target_configurations_must_agree(self) -> None:
        with self.assertRaisesRegex(VersionSyncError, "disagree: 1.8.0, 1.8.1"):
            check(pbxproj(app_versions=("1.8.0", "1.8.1")), xcconfig())

    def test_first_version_must_be_the_app_version(self) -> None:
        with self.assertRaisesRegex(VersionSyncError, "daily tags read the first one"):
            check(pbxproj(first_version="1.7.1"), xcconfig())

    def test_ignores_plugin_target_versions(self) -> None:
        self.assertEqual(check(pbxproj(app_versions=("1.9.0", "1.9.0")), xcconfig("1.9.0")), "1.9.0")

    def test_tags_must_name_the_app_version(self) -> None:
        for tag in ("v1.8.0", "v1.8.0-rc1", "v1.8.0-daily.20261019", "v1.8.0-daily.20261003.1"):
            with self.subTest(tag=tag):
                self.assertEqual(check(pbxproj(), xcconfig(), tag), "1.8.0")
        with self.assertRaisesRegex(VersionSyncError, "names 1.8.1"):
            check(pbxproj(), xcconfig(), "v1.8.1")
        with self.assertRaisesRegex(VersionSyncError, "is not vX.Y.Z"):
            check(pbxproj(), xcconfig(), "1.8.0")

    def test_repository_versions_match(self) -> None:
        check(
            (REPO_ROOT / PBXPROJ).read_text(encoding="utf-8"),
            (REPO_ROOT / APPSTORE_XCCONFIG).read_text(encoding="utf-8"),
        )


if __name__ == "__main__":
    unittest.main()
