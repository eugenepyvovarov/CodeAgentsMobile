#!/usr/bin/env python3
"""Resolve shared OpenCode managed workflow context.

This helper is rendered into managed repositories and intentionally uses only the
Python standard library so workflow preflight jobs can run it before checking out
the controller repository.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


DEFAULT_CONFIG_PATH = Path("project") / "opencode-managed.json"

VALIDATION_WORKFLOW = ".gitea/workflows/pr-tests.yml"
PR_PREP_WORKFLOW = ".gitea/workflows/pr-prep.yml"
DEMO_WORKFLOW = ".gitea/workflows/demo-evidence.yml"
VISUAL_VALIDATION_WORKFLOW = ".gitea/workflows/visual-validation.yml"
PRODUCTION_ARTIFACT_WORKFLOW = ".gitea/workflows/production-artifact.yml"
PLAYWRIGHT_SMOKE_WORKFLOW = ".gitea/workflows/playwright-smoke.yml"

PLAYWRIGHT_PROVIDER = "playwright"
WEB_PLATFORM = "web"
EXPECTED_PLAYWRIGHT_EVIDENCE_RUNNER_IMAGE = "git.ultramac.work/eugene/opencode-gitea-automation/playwright-evidence-runner:1.54.0-r4"
EXPECTED_PLAYWRIGHT_EVIDENCE_RUNNER_CONTRACT_VERSION = "1"
NATIVE_MACOS_PROVIDER = "native-macos"
NATIVE_MACOS_PLATFORM = "macos"
NATIVE_MACOS_PROVIDER_ALIASES = {NATIVE_MACOS_PROVIDER, "native", "macos"}
NATIVE_MACOS_PLATFORM_ALIASES = {NATIVE_MACOS_PLATFORM, "native-macos"}
NATIVE_IOS_SIMULATOR_PROVIDER = "native-ios-simulator"
NATIVE_IOS_SIMULATOR_PLATFORM = "ios-simulator"
NATIVE_IOS_SIMULATOR_PROVIDER_ALIASES = {
    NATIVE_IOS_SIMULATOR_PROVIDER,
    "ios-simulator",
    "native-ios",
    "ios",
}
NATIVE_IOS_SIMULATOR_PLATFORM_ALIASES = {NATIVE_IOS_SIMULATOR_PLATFORM, "ios", "simulator"}

IGNORED_REVIEW_TRIGGER_LOGINS = {"backlog-bot", "opencode-bot", "review-bot"}


class ConfigError(ValueError):
    """Raised when the managed workflow context cannot be resolved."""


def bool_text(value: bool) -> str:
    return "true" if value else "false"


def as_object(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError(f"{path} must be an object")
    return value


def as_bool(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        raise ConfigError(f"{path} must be a boolean")
    return value


def require_text(value: Any, path: str) -> str:
    text = str(value or "").strip()
    if not text:
        raise ConfigError(f"{path} is required")
    return text


def optional_text(value: Any, default: str = "") -> str:
    return str(value if value is not None else default).strip()


def normalized_event_state(value: Any) -> str:
    return optional_text(value).casefold().replace("-", "_").replace(" ", "_")


def reject_multiline(name: str, value: str) -> None:
    if "\n" in value or "\r" in value:
        raise ConfigError(f"Refusing to emit newline-bearing value for {name}")


def load_config(path: Path) -> dict[str, Any]:
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ConfigError(f"Managed config not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"Managed config is not valid JSON: {exc}") from exc
    if not isinstance(config, dict):
        raise ConfigError("Managed config root must be an object")
    if config.get("schema_version") != 1:
        raise ConfigError("Managed config schema_version must be 1")
    if config.get("managed_by") not in {None, "opencode-gitea-automation"}:
        raise ConfigError("Managed config managed_by must be opencode-gitea-automation")
    return config


def derive_project_key() -> str:
    owner = require_text(os.environ.get("OPENCODE_REPO_OWNER"), "OPENCODE_REPO_OWNER")
    repo = require_text(os.environ.get("OPENCODE_REPO_NAME"), "OPENCODE_REPO_NAME")
    raw = f"{owner}-{repo}".lower()
    project_key = re.sub(r"[^a-z0-9]+", "-", raw).strip("-")
    project_key = re.sub(r"-{2,}", "-", project_key)
    if not project_key:
        raise ConfigError("Unable to derive project key from repository owner/name")
    return project_key


def controller_config(config: dict[str, Any]) -> dict[str, str]:
    controller = as_object(config.get("controller"), "controller")
    return {
        "repository": require_text(controller.get("repository"), "controller.repository"),
        "setup_branch": require_text(controller.get("setup_branch"), "controller.setup_branch"),
    }


def activity_context() -> dict[str, str]:
    return {
        "OPENCODE_ACTIVITY_INGEST_URL": require_text(
            os.environ.get("OPENCODE_ACTIVITY_INGEST_URL"),
            "OPENCODE_ACTIVITY_INGEST_URL",
        ),
        "OPENCODE_ACTIVITY_INGEST_TOKEN": require_text(
            os.environ.get("OPENCODE_ACTIVITY_INGEST_TOKEN"),
            "OPENCODE_ACTIVITY_INGEST_TOKEN",
        ),
    }


def validate_review_config(config: dict[str, Any]) -> None:
    review = as_object(config.get("review"), "review")
    require_text(review.get("persona"), "review.persona")
    secret = require_text(review.get("persona_token_secret"), "review.persona_token_secret")
    if not secret.startswith("OPENCODE_PERSONA_"):
        raise ConfigError("review.persona_token_secret must start with OPENCODE_PERSONA_")


def validate_validation_config(config: dict[str, Any]) -> dict[str, Any]:
    validation = as_object(config.get("validation"), "validation")
    workflow = require_text(validation.get("workflow"), "validation.workflow")
    if workflow != VALIDATION_WORKFLOW:
        raise ConfigError(f"validation.workflow must be {VALIDATION_WORKFLOW}")
    require_text(validation.get("command"), "validation.command")
    return validation


def validate_workflow(section: dict[str, Any], path: str, expected: str) -> None:
    workflow = require_text(section.get("workflow"), f"{path}.workflow")
    if workflow != expected:
        raise ConfigError(f"{path}.workflow must be {expected}")


def require_shared_playwright_runner_contract(enabled: bool, path: str) -> None:
    if not enabled:
        return
    image = require_text(
        os.environ.get("OPENCODE_PLAYWRIGHT_EVIDENCE_RUNNER_IMAGE"),
        "OPENCODE_PLAYWRIGHT_EVIDENCE_RUNNER_IMAGE",
    )
    if image != EXPECTED_PLAYWRIGHT_EVIDENCE_RUNNER_IMAGE:
        raise ConfigError(
            f"{path} web evidence must use shared Playwright evidence runner "
            f"{EXPECTED_PLAYWRIGHT_EVIDENCE_RUNNER_IMAGE}; got {image}. "
            "Host Playwright/node_modules fallback is not supported."
        )
    contract_version = require_text(
        os.environ.get("OPENCODE_PLAYWRIGHT_EVIDENCE_RUNNER_CONTRACT_VERSION"),
        "OPENCODE_PLAYWRIGHT_EVIDENCE_RUNNER_CONTRACT_VERSION",
    )
    if contract_version != EXPECTED_PLAYWRIGHT_EVIDENCE_RUNNER_CONTRACT_VERSION:
        raise ConfigError(
            f"{path} web evidence must use Playwright evidence runner contract "
            f"{EXPECTED_PLAYWRIGHT_EVIDENCE_RUNNER_CONTRACT_VERSION}; got {contract_version}"
        )


def provider_summary(section: dict[str, Any], path: str) -> dict[str, Any]:
    provider = require_text(section.get("provider"), f"{path}.provider")
    platform = require_text(section.get("platform"), f"{path}.platform")
    playwright_web = provider == PLAYWRIGHT_PROVIDER and platform == WEB_PLATFORM
    native_macos = provider in NATIVE_MACOS_PROVIDER_ALIASES and platform in NATIVE_MACOS_PLATFORM_ALIASES
    native_ios_simulator = (
        provider in NATIVE_IOS_SIMULATOR_PROVIDER_ALIASES
        and platform in NATIVE_IOS_SIMULATOR_PLATFORM_ALIASES
    )
    return {
        "provider": provider,
        "platform": platform,
        "playwright_web": playwright_web,
        "native_macos": native_macos,
        "native_ios_simulator": native_ios_simulator,
        "evidence_supported": playwright_web or native_macos or native_ios_simulator,
    }


def demo_context(config: dict[str, Any]) -> dict[str, str]:
    controller = controller_config(config)
    validate_review_config(config)
    validate_validation_config(config)
    preview = as_object(config.get("preview"), "preview")
    preview_supported = as_bool(preview.get("supported"), "preview.supported")
    demo = as_object(config.get("demo"), "demo")
    validate_workflow(demo, "demo", DEMO_WORKFLOW)
    demo_supported = as_bool(demo.get("supported"), "demo.supported")
    if demo.get("record_video") is not True:
        raise ConfigError("demo.record_video must be true")
    summary = provider_summary(demo, "demo")
    evidence_supported = demo_supported and summary["evidence_supported"]
    require_shared_playwright_runner_contract(demo_supported and summary["playwright_web"], "demo")
    if not evidence_supported:
        print("Managed repository does not declare supported demo evidence capture; skipping.")
    return {
        "controller_repository": controller["repository"],
        "setup_branch": controller["setup_branch"],
        "project_key": derive_project_key(),
        "preview_supported": bool_text(preview_supported),
        "demo_supported": bool_text(demo_supported),
        "demo_provider": summary["provider"],
        "demo_platform": summary["platform"],
        "demo_evidence_supported": bool_text(evidence_supported),
        "demo_playwright_web_supported": bool_text(demo_supported and summary["playwright_web"]),
        "demo_native_macos_supported": bool_text(demo_supported and summary["native_macos"]),
        "demo_native_ios_simulator_supported": bool_text(demo_supported and summary["native_ios_simulator"]),
    }


def visual_validation_context(config: dict[str, Any]) -> dict[str, str]:
    controller = controller_config(config)
    validate_review_config(config)
    validate_validation_config(config)
    preview = as_object(config.get("preview"), "preview")
    preview_supported = as_bool(preview.get("supported"), "preview.supported")
    visual = as_object(config.get("visual_validation"), "visual_validation")
    validate_workflow(visual, "visual_validation", VISUAL_VALIDATION_WORKFLOW)
    visual_supported = as_bool(visual.get("supported"), "visual_validation.supported")
    if visual.get("full_page") is not True:
        raise ConfigError("visual_validation.full_page must be true")
    summary = provider_summary(visual, "visual_validation")
    evidence_supported = visual_supported and summary["evidence_supported"]
    require_shared_playwright_runner_contract(
        visual_supported and preview_supported and summary["playwright_web"],
        "visual_validation",
    )
    if not evidence_supported:
        print("Managed repository does not declare supported visual validation capture; skipping.")
    return {
        "OPENCODE_CONTROLLER_REPOSITORY": controller["repository"],
        "OPENCODE_SETUP_BRANCH": controller["setup_branch"],
        "OPENCODE_PROJECT_KEY": derive_project_key(),
        "OPENCODE_PREVIEW_SUPPORTED": bool_text(preview_supported),
        "OPENCODE_VISUAL_VALIDATION_SUPPORTED": bool_text(visual_supported),
        "OPENCODE_VISUAL_VALIDATION_PROVIDER": summary["provider"],
        "OPENCODE_VISUAL_VALIDATION_PLATFORM": summary["platform"],
        "OPENCODE_VISUAL_VALIDATION_EVIDENCE_SUPPORTED": bool_text(evidence_supported),
        "OPENCODE_VISUAL_VALIDATION_PLAYWRIGHT_WEB": bool_text(visual_supported and summary["playwright_web"]),
        "OPENCODE_VISUAL_VALIDATION_NATIVE_MACOS": bool_text(visual_supported and summary["native_macos"]),
        "OPENCODE_VISUAL_VALIDATION_NATIVE_IOS_SIMULATOR": bool_text(
            visual_supported and summary["native_ios_simulator"]
        ),
        **activity_context(),
    }


def production_artifact_context(config: dict[str, Any]) -> dict[str, str]:
    controller = controller_config(config)
    validate_review_config(config)
    validate_validation_config(config)
    production = as_object(config.get("production_artifact"), "production_artifact")
    validate_workflow(production, "production_artifact", PRODUCTION_ARTIFACT_WORKFLOW)
    supported = as_bool(production.get("supported"), "production_artifact.supported")
    result = as_object(production.get("result"), "production_artifact.result")
    if result.get("format") != "json" or result.get("transport") != "stdout":
        raise ConfigError("production_artifact.result must use json/stdout")
    phase = production.get("phase") or {}
    phase = as_object(phase, "production_artifact.phase")
    phase_enabled = phase.get("enabled") is True
    phase_app_id = optional_text(phase.get("app_id"))
    phase_env = optional_text(phase.get("env"), "prod")
    phase_path = optional_text(phase.get("path"), "/")
    if phase_enabled and not phase_app_id:
        raise ConfigError("production_artifact.phase.app_id is required when phase.enabled is true")
    if phase_enabled and not phase_env:
        raise ConfigError("production_artifact.phase.env is required when phase.enabled is true")
    if phase_enabled and not phase_path:
        raise ConfigError("production_artifact.phase.path is required when phase.enabled is true")
    if not supported:
        print("Managed repository does not declare supported production-artifact finalization; skipping.")
    return {
        "OPENCODE_CONTROLLER_REPOSITORY": controller["repository"],
        "OPENCODE_SETUP_BRANCH": controller["setup_branch"],
        "OPENCODE_PROJECT_KEY": derive_project_key(),
        "OPENCODE_PRODUCTION_ARTIFACT_SUPPORTED": bool_text(supported),
        "OPENCODE_PRODUCTION_ARTIFACT_PHASE_ENABLED": bool_text(phase_enabled),
        "OPENCODE_PRODUCTION_ARTIFACT_PHASE_APP_ID": phase_app_id,
        "OPENCODE_PRODUCTION_ARTIFACT_PHASE_ENV": phase_env,
        "OPENCODE_PRODUCTION_ARTIFACT_PHASE_PATH": phase_path,
        **activity_context(),
    }


def playwright_smoke_context(config: dict[str, Any]) -> dict[str, str]:
    controller = controller_config(config)
    validate_review_config(config)
    validate_validation_config(config)
    smoke = as_object(config.get("playwright_smoke"), "playwright_smoke")
    validate_workflow(smoke, "playwright_smoke", PLAYWRIGHT_SMOKE_WORKFLOW)
    supported = as_bool(smoke.get("supported"), "playwright_smoke.supported")
    provider = require_text(smoke.get("provider"), "playwright_smoke.provider")
    platform = require_text(smoke.get("platform"), "playwright_smoke.platform")
    command = require_text(smoke.get("command"), "playwright_smoke.command")
    if not (supported and provider == PLAYWRIGHT_PROVIDER and platform == WEB_PLATFORM):
        print("Managed repository does not declare supported web Playwright smoke coverage; skipping.")
    require_shared_playwright_runner_contract(
        supported and provider == PLAYWRIGHT_PROVIDER and platform == WEB_PLATFORM,
        "playwright_smoke",
    )
    return {
        "OPENCODE_SETUP_BRANCH": controller["setup_branch"],
        "OPENCODE_PLAYWRIGHT_SMOKE_SUPPORTED": bool_text(supported),
        "OPENCODE_PLAYWRIGHT_SMOKE_PROVIDER": provider,
        "OPENCODE_PLAYWRIGHT_SMOKE_PLATFORM": platform,
        "OPENCODE_PLAYWRIGHT_SMOKE_COMMAND": command,
    }


def validation_context(config: dict[str, Any]) -> dict[str, str]:
    controller = controller_config(config)
    validate_review_config(config)
    validation = validate_validation_config(config)
    return {
        "OPENCODE_SETUP_BRANCH": controller["setup_branch"],
        "OPENCODE_VALIDATION_COMMAND": require_text(validation.get("command"), "validation.command"),
    }


def review_trigger_context() -> dict[str, str]:
    event_name = optional_text(os.environ.get("GITHUB_EVENT_NAME"))
    should_run = True
    if event_name in {"issue_comment", "pull_request_comment"}:
        payload = read_event_payload()
        comment = payload.get("comment") if isinstance(payload.get("comment"), dict) else {}
        user = comment.get("user") if isinstance(comment.get("user"), dict) else {}
        login = optional_text(user.get("login") or comment.get("user_name")).casefold()
        body = optional_text(comment.get("body"))
        should_run = body == "/review-bot" and login not in IGNORED_REVIEW_TRIGGER_LOGINS
        if should_run:
            print("Matched trusted /review-bot comment trigger.")
        else:
            print("Skipping review workflow for non-command or bot-authored comment trigger.")
    if event_name == "pull_request":
        payload = read_event_payload()
        pull_request = payload.get("pull_request") if isinstance(payload.get("pull_request"), dict) else {}
        head = pull_request.get("head") if isinstance(pull_request.get("head"), dict) else {}
        author = pull_request.get("user") if isinstance(pull_request.get("user"), dict) else {}
        head_ref = optional_text(head.get("ref"))
        author_login = optional_text(author.get("login") or pull_request.get("user_name")).casefold()
        if head_ref.startswith("automation/") or author_login in {"opencode-bot", "backlog-bot"}:
            should_run = False
            print("Skipping raw pull_request review for bot-managed PR; waiting for explicit PR-prep handoff.")
    if event_name == "pull_request_review":
        payload = read_event_payload()
        review = payload.get("review") if isinstance(payload.get("review"), dict) else {}
        review_user = review.get("user") if isinstance(review.get("user"), dict) else {}
        review_login = optional_text(review_user.get("login") or review.get("user_name")).casefold()
        sender = payload.get("sender") if isinstance(payload.get("sender"), dict) else {}
        sender_login = optional_text(sender.get("login")).casefold()
        state = normalized_event_state(review.get("state"))
        if state != "request_review" and (
            review_login in IGNORED_REVIEW_TRIGGER_LOGINS or sender_login in IGNORED_REVIEW_TRIGGER_LOGINS
        ):
            should_run = False
            print("Skipping review workflow for bot-authored pull_request_review trigger.")
    return {"OPENCODE_REVIEW_TRIGGER_MATCHED": "1" if should_run else "0"}


def review_settings_context(config: dict[str, Any]) -> dict[str, str]:
    controller = controller_config(config)
    validate_review_config(config)
    validation = validate_validation_config(config)
    coverage = as_object(config.get("coverage"), "coverage")
    deployment = as_object(config.get("deployment"), "deployment")
    return {
        "OPENCODE_CONTROLLER_REPOSITORY": controller["repository"],
        "OPENCODE_SETUP_BRANCH": controller["setup_branch"],
        "OPENCODE_PROJECT_KEY": derive_project_key(),
        "OPENCODE_VALIDATION_COMMAND": require_text(validation.get("command"), "validation.command"),
        "OPENCODE_COVERAGE_COMMAND": require_text(coverage.get("command"), "coverage.command"),
        "OPENCODE_DEPLOYMENT_COMMAND": require_text(deployment.get("command"), "deployment.command"),
        **activity_context(),
    }


def pr_prep_preflight_context(config: dict[str, Any]) -> dict[str, str]:
    controller = controller_config(config)
    pr_prep = as_object(config.get("pr_prep"), "pr_prep")
    validate_workflow(pr_prep, "pr_prep", PR_PREP_WORKFLOW)
    if pr_prep.get("authoritative") is not True:
        raise ConfigError("pr_prep.authoritative must be true")
    stages = pr_prep.get("stages")
    if not isinstance(stages, list) or "validation" not in stages:
        raise ConfigError("pr_prep.stages must include validation")
    validate_validation_config(config)
    smoke = as_object(config.get("playwright_smoke"), "playwright_smoke")
    validate_workflow(smoke, "playwright_smoke", PLAYWRIGHT_SMOKE_WORKFLOW)
    smoke_stage = (
        "playwright-smoke" in stages
        and smoke.get("supported") is True
        and smoke.get("provider") == PLAYWRIGHT_PROVIDER
        and smoke.get("platform") == WEB_PLATFORM
        and bool(require_text(smoke.get("command"), "playwright_smoke.command"))
    )
    preview = as_object(config.get("preview"), "preview")
    preview_supported = as_bool(preview.get("supported"), "preview.supported")
    visual = as_object(config.get("visual_validation"), "visual_validation")
    validate_workflow(visual, "visual_validation", VISUAL_VALIDATION_WORKFLOW)
    visual_supported = as_bool(visual.get("supported"), "visual_validation.supported")
    visual_summary = provider_summary(visual, "visual_validation")
    visual_stage = (
        "visual-validation" in stages
        and visual_supported
        and (
            (visual_summary["playwright_web"] and preview_supported)
            or visual_summary["native_macos"]
            or visual_summary["native_ios_simulator"]
        )
    )
    require_shared_playwright_runner_contract(smoke_stage, "playwright_smoke")
    require_shared_playwright_runner_contract(
        visual_stage and visual_summary["playwright_web"],
        "visual_validation",
    )
    return {
        "validation_supported": "true",
        "playwright_smoke_supported": bool_text(smoke_stage),
        "visual_validation_supported": bool_text(visual_stage),
        "controller_repository": controller["repository"],
        "setup_branch": controller["setup_branch"],
        "project_key": derive_project_key(),
    }


def read_event_payload() -> dict[str, Any]:
    event_path = require_text(os.environ.get("GITHUB_EVENT_PATH"), "GITHUB_EVENT_PATH")
    payload = json.loads(Path(event_path).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ConfigError("GITHUB_EVENT_PATH payload must be a JSON object")
    return payload


CONTEXTS = {
    "validation": validation_context,
    "review-trigger": lambda config: review_trigger_context(),
    "review-settings": review_settings_context,
    "pr-prep-preflight": pr_prep_preflight_context,
    "visual-validation": visual_validation_context,
    "demo-evidence-preflight": demo_context,
    "production-artifact": production_artifact_context,
    "playwright-smoke": playwright_smoke_context,
}


def emit_values(values: dict[str, str], target: str) -> None:
    env_var = "GITHUB_ENV" if target == "env" else "GITHUB_OUTPUT"
    target_path = require_text(os.environ.get(env_var), env_var)
    with open(target_path, "a", encoding="utf-8") as handle:
        for name, raw_value in values.items():
            value = str(raw_value)
            reject_multiline(name, value)
            handle.write(f"{name}={value}\n")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True, choices=sorted(CONTEXTS))
    parser.add_argument("--emit", required=True, choices=("env", "output"))
    parser.add_argument(
        "--config",
        default=os.environ.get("OPENCODE_MANAGED_CONFIG") or str(DEFAULT_CONFIG_PATH),
        help="Path to project/opencode-managed.json (default: OPENCODE_MANAGED_CONFIG or project/opencode-managed.json)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        config = {} if args.context == "review-trigger" else load_config(Path(args.config))
        values = CONTEXTS[args.context](config)
        emit_values(values, args.emit)
    except (ConfigError, OSError, json.JSONDecodeError) as exc:
        print(f"opencode managed workflow context error: {exc}", file=sys.stderr)
        return 1
    print(f"managed {args.context} context ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
