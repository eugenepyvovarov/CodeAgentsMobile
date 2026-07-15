import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "lib" / "testflight_preflight.py"


def payload(*versions: tuple[str, str]) -> str:
    return json.dumps(
        {
            "data": [
                {
                    "attributes": {
                        "versionString": version,
                        "appStoreState": state,
                        "platform": "IOS",
                    }
                }
                for version, state in versions
            ]
        }
    )


class TestFlightPreflightTests(unittest.TestCase):
    def run_preflight(self, version: str, input_payload: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(SCRIPT), "--version", version],
            input=input_payload,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_rejects_approved_version_train_before_build(self) -> None:
        result = self.run_preflight("1.6", payload(("1.6", "READY_FOR_SALE")))

        self.assertEqual(result.returncode, 1)
        self.assertIn("must be greater than approved App Store version 1.6", result.stderr)
        self.assertIn("Update VERSIONS.TXT before building", result.stderr)

    def test_accepts_newer_version_train(self) -> None:
        result = self.run_preflight("1.7", payload(("1.6", "READY_FOR_SALE")))

        self.assertEqual(result.returncode, 0)
        self.assertIn("release version 1.7 is newer", result.stdout)

    def test_uses_numeric_component_ordering(self) -> None:
        result = self.run_preflight("1.10", payload(("1.9", "READY_FOR_SALE")))

        self.assertEqual(result.returncode, 0)

    def test_ignores_editable_draft_and_other_platforms(self) -> None:
        input_payload = json.dumps(
            {
                "data": [
                    {
                        "attributes": {
                            "versionString": "2.0",
                            "appStoreState": "PREPARE_FOR_SUBMISSION",
                            "platform": "IOS",
                        }
                    },
                    {
                        "attributes": {
                            "versionString": "9.0",
                            "appStoreState": "READY_FOR_SALE",
                            "platform": "MAC_OS",
                        }
                    },
                    {
                        "attributes": {
                            "versionString": "1.6",
                            "appStoreState": "READY_FOR_SALE",
                            "platform": "IOS",
                        }
                    },
                ]
            }
        )

        result = self.run_preflight("1.7", input_payload)

        self.assertEqual(result.returncode, 0)

    def test_rejects_invalid_marketing_version(self) -> None:
        result = self.run_preflight("release-1.7", payload(("1.6", "READY_FOR_SALE")))

        self.assertEqual(result.returncode, 1)
        self.assertIn("expected two or three numeric components", result.stderr)


if __name__ == "__main__":
    unittest.main()
