#!/usr/bin/env python3

import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "lib" / "xcode_build_metadata.py"
SPEC = importlib.util.spec_from_file_location("xcode_build_metadata", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class XcodeBuildMetadataTests(unittest.TestCase):
    def test_build_settings_uses_gitea_version_and_build_number(self):
        self.assertEqual(
            MODULE.build_settings("1.7", "4636"),
            {
                "extraArgs": [
                    "MARKETING_VERSION=1.7",
                    "CURRENT_PROJECT_VERSION=4636",
                ]
            },
        )

    def test_build_settings_accepts_apple_period_separated_builds(self):
        self.assertEqual(
            MODULE.build_settings("1.7.1", "4636.1"),
            {
                "extraArgs": [
                    "MARKETING_VERSION=1.7.1",
                    "CURRENT_PROJECT_VERSION=4636.1",
                ]
            },
        )

    def test_build_settings_rejects_non_numeric_values(self):
        with self.assertRaisesRegex(ValueError, "marketing version"):
            MODULE.build_settings("1.7-beta", "4636")
        with self.assertRaisesRegex(ValueError, "build number"):
            MODULE.build_settings("1.7", "run-4636")


if __name__ == "__main__":
    unittest.main()
