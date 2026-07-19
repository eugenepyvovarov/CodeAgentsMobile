#!/usr/bin/env python3
"""Create XcodeBuildMCP build-setting overrides for CodeAgents Mobile."""

from __future__ import annotations

import argparse
import json
import re


VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){0,2}$")


def build_settings(version: str, build_number: str) -> dict[str, list[str]]:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(
            "marketing version must contain one to three period-separated integers"
        )
    if not VERSION_PATTERN.fullmatch(build_number):
        raise ValueError(
            "build number must contain one to three period-separated integers"
        )

    return {
        "extraArgs": [
            f"MARKETING_VERSION={version}",
            f"CURRENT_PROJECT_VERSION={build_number}",
        ]
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    args = parser.parse_args()

    try:
        payload = build_settings(args.version, args.build_number)
    except ValueError as error:
        parser.error(str(error))

    print(json.dumps(payload))


if __name__ == "__main__":
    main()
