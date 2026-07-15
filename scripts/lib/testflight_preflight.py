#!/usr/bin/env python3
"""Reject TestFlight builds that target an approved App Store version train."""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any


VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
APPROVED_OR_CLOSED_STATES = {
    "READY_FOR_SALE",
    "PENDING_DEVELOPER_RELEASE",
    "PENDING_APPLE_RELEASE",
    "PROCESSING_FOR_DISTRIBUTION",
    "DEVELOPER_REMOVED_FROM_SALE",
    "REMOVED_FROM_SALE",
}


def version_key(version: str) -> tuple[int, int, int]:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(
            f"invalid release version {version!r}; expected two or three numeric components"
        )
    parts = [int(part) for part in version.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))  # type: ignore[return-value]


def approved_ios_versions(payload: dict[str, Any]) -> list[tuple[tuple[int, int, int], str, str]]:
    versions: list[tuple[tuple[int, int, int], str, str]] = []
    for item in payload.get("data", []):
        attributes = item.get("attributes", {})
        if attributes.get("platform") != "IOS":
            continue
        state = attributes.get("appStoreState", "")
        version = attributes.get("versionString", "")
        if state not in APPROVED_OR_CLOSED_STATES or not isinstance(version, str):
            continue
        try:
            key = version_key(version)
        except ValueError:
            continue
        versions.append((key, version, state))
    return versions


def validate_version(payload: dict[str, Any], proposed: str) -> str:
    proposed_key = version_key(proposed)
    approved = approved_ios_versions(payload)
    if not approved:
        return f"TestFlight preflight passed: no approved iOS App Store version blocks {proposed}."

    _, latest_version, latest_state = max(approved, key=lambda item: item[0])
    if proposed_key <= version_key(latest_version):
        raise ValueError(
            "TestFlight preflight failed: release version "
            f"{proposed} must be greater than approved App Store version "
            f"{latest_version} ({latest_state}). Update VERSIONS.TXT before building."
        )

    return (
        f"TestFlight preflight passed: release version {proposed} is newer than "
        f"approved App Store version {latest_version} ({latest_state})."
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    args = parser.parse_args()

    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError("App Store version response is not a JSON object")
        print(validate_version(payload, args.version))
    except (json.JSONDecodeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
