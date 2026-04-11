# Managed automation files

This repository is bootstrap-managed by the OpenCode Gitea automation controller.

- `.gitea/workflows/` contains the controller-managed validation and review workflow definitions.
- `project/opencode-managed.json` stores the repo-local workflow contract and persona bootstrap metadata.
- `scripts/ci.sh` is the canonical validation entrypoint used by implementation and PR validation.
- `scripts/coverage.sh` is the canonical coverage entrypoint used by the review workflow.
- `scripts/deploy.sh` is the canonical deployment entrypoint when this repo needs deploy automation.

For managed web repositories that already use Playwright, `.gitea/workflows/demo-evidence.yml` is the dedicated demo workflow for PR evidence. It stays separate from validation and review, records browser video by default, runs only the `Demo Scenario` repo command declared in the linked issue spec for that PR, and uses the standard Linux web runner path rather than requiring a native recording host.

Demo evidence support in v1 is web-only Playwright automation. Older demo scripts may remain in the repository after a task ships, but they are not reused automatically on later tasks. A later UI task must explicitly point its `Demo Scenario` at the same command if that scenario should be reused.

The bootstrap-managed `scripts/ci.sh`, `scripts/coverage.sh`, and `scripts/deploy.sh` files are placeholders. Replace them with the real project-specific commands before you rely on validation, coverage, or deployment automation.

Persona behavior is controlled from the automation controller repository, not from this managed repository.
Edit the install-level bundle under `agents/<persona>/` in the controller repo when you need to change a persona's instructions, templates, or MCP configuration.

The bootstrap setup PR only sanity-checks the managed workflow contract. Normal implementation PRs run `scripts/ci.sh`, and the review workflow checks out the controller repository to run the real review worker against the PR branch in this repository.

Suggested validation steps after the setup PR merges:

1. Confirm `project/opencode-managed.json`, `project/README.md`, `scripts/ci.sh`, `scripts/coverage.sh`, and `scripts/deploy.sh` are present on the default branch.
2. Make one small edit to the target persona bundle in the automation controller repository.
3. Deploy or refresh the controller checkout on Ultramac.
4. Trigger the next backlog or implementation task for that same persona.
5. Confirm the next task reflects the updated install-level persona instructions.
