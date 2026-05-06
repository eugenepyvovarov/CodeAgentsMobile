# Managed automation files

This repository is bootstrap-managed by the OpenCode Gitea automation controller.

- `.gitea/workflows/` contains the controller-managed validation and review workflow definitions.
- `project/opencode-managed.json` stores the repo-local workflow contract and persona bootstrap metadata.
- `scripts/ci.sh` is the canonical validation entrypoint used by implementation and PR validation.
- `scripts/coverage.sh` is the canonical coverage entrypoint used by the review workflow.
- `scripts/deploy.sh` is the canonical deployment entrypoint when this repo needs deploy automation.

Repositories can also opt into a separate post-merge production-artifact contract through `project/opencode-managed.json`:

- `production_artifact.command` is the explicit final build/publish entrypoint for the merged default-branch result.
- It stays separate from preview artifacts and deployment even when the repo intentionally points it at `./scripts/artifact.sh`.
- Bootstrap setup does not add another production-artifact script; if this repo already uses `scripts/artifact.sh` for final publication, set `production_artifact.command` explicitly and keep that script repo-owned.
- Prefer one mode-aware `scripts/artifact.sh` entrypoint (for example `preview` vs `production`) instead of maintaining a separate `scripts/production_artifact.sh`.

Preview-capable repositories can also opt in through `project/opencode-managed.json` with the repo-owned preview contract:

- `scripts/artifact.sh` produces the runnable artifact the preview flow uses.
- `scripts/preview.sh` creates or refreshes the live preview from that artifact, or builds inline if the repo chooses. It must print JSON with `backend_url`, and can optionally include `health_url` plus `reviewer_notes` for manual testers.
- `scripts/destroy-preview.sh` tears the preview down when the PR closes or merges.
- When the controller sets `OPENCODE_PREVIEW_REF` for baseline capture, the preview scripts must build and run from that exact commit in an isolated detached worktree instead of silently using the active branch checkout, and teardown must remove that temporary worktree.

That preview contract is separate from the normal validation, coverage, production-artifact, and deployment entrypoints. `scripts/ci.sh` remains the fast validation gate, `scripts/coverage.sh` remains the review-time coverage hook, `production_artifact.command` remains the post-merge publish hook when enabled, and `scripts/deploy.sh` remains the deployment hook for default-branch or release automation.

For managed repositories that opt into demo evidence, `.gitea/workflows/demo-evidence.yml` is the dedicated final demo media workflow. It stays separate from validation, review, and visual validation, runs only by controller workflow dispatch after merge or by manual rerun, and posts attachment-backed `demo-media` comments to the linked issue rather than the PR. Web Playwright repos should use `demo.provider: "playwright"` and `demo.platform: "web"`; that path captures every spec-declared `Demo Media` scenario from the retained merged-PR preview, runs inside the controller-published shared Playwright evidence image pinned by the controller-managed template, and keeps the merged preview alive until the matching merged-head issue comments prove every requested output succeeded. Normal web runs should not reinstall Playwright system packages, browsers, headless shell, or ffmpeg inside this repository. Native macOS apps should use `demo.provider: "native-macos"` and `demo.platform: "macos"`; native iOS apps should use `demo.provider: "native-ios-simulator"` and `demo.platform: "ios-simulator"`. Both native paths run directly on `macos-ultramac` without the Playwright image or retained web preview, launch the native app locally, and expect the repo-owned command to write screenshots/video to the `OPENCODE_DEMO_*` artifact paths. There is no CI-local fallback app boot for web preview-capable repos: if the retained preview is missing, stale, or unreachable, the web final demo job fails until preview retention is fixed.

For managed repositories that opt into visual validation, `.gitea/workflows/visual-validation.yml` is the separate review-quality screenshot capture workflow. `visual_validation_worker.py` is the producer only: it runs only when the linked spec includes `Visual Validation`, the repository declares a supported visual validation provider/platform pair, and the workflow checks out the exact latest PR head. Web Playwright repos use `visual_validation.provider: "playwright"` and `visual_validation.platform: "web"`; that path also requires `preview.supported: true`, runs the repo-owned capture command inside the controller-published shared Playwright evidence image, creates a one-shot baseline preview from the frozen `baseline_sha`, tears that baseline preview down immediately, then captures current full-page screenshots from the long-lived current preview. Native macOS apps use `visual_validation.provider: "native-macos"` and `visual_validation.platform: "macos"`; native iOS apps use `visual_validation.provider: "native-ios-simulator"` and `visual_validation.platform: "ios-simulator"`. Native visual validation does not require `preview.supported` and does not use `OPENCODE_PREVIEW_PUBLIC_URL` or `PLAYWRIGHT_BASE_URL`; both native paths run the repo-owned capture command directly on `macos-ultramac`, capture the frozen baseline from a detached baseline checkout, and capture current screenshots from the PR checkout. Later reruns reuse the stored baseline screenshot set unless the spec's capture contract changed, in which case automation regenerates the baseline from the same frozen SHA. If that frozen baseline ref cannot be built, the run stays blocked until an operator records an explicit override SHA in the linked spec. Older PRs without a persisted frozen baseline, and older local-capture visual-validation comments, are non-authoritative until they are rerun under the current provider-specific contract. `review-bot` remains the only reviewer: it consumes only the latest trusted `visual-validation` PR comment for the current head SHA, pairs the baseline/current checkpoint images from that comment, and performs a separate image-based review instead of treating metadata or arbitrary thread attachments as the review signal.

For managed web repositories that already use Playwright, `.gitea/workflows/playwright-smoke.yml` is the reusable/manual controller-managed smoke workflow contract called by `pr-prep` when `playwright_smoke.supported` is enabled. The recommended repo-owned command path is `/bin/bash ./scripts/playwright-smoke.sh`, wired through `project/opencode-managed.json` as `playwright_smoke.command`. When `playwright_smoke.supported` stays `false`, setup PRs and reconcile may still backfill the canonical workflow file and config section without enabling smoke runs. When a repository is compatible and ready, enable that config explicitly and keep the repo-owned command responsible for dependency install, migrations or seed/setup, app startup and shutdown, and the actual smoke assertions.

The shared smoke workflow guarantees only the runtimes already published in the controller-managed `playwright-evidence-runner` image plus the preinstalled Playwright/browser layer. It should not be patched locally to add `actions/setup-node`, `actions/setup-python`, or `npx playwright install --with-deps chromium` back into the normal path. If this repository needs a different Python minor version or another incompatible runtime behavior, leave `playwright_smoke.supported` disabled until the controller publishes a compatible image revision.

Once the canonical managed smoke workflow is enabled here, retire any older repo-local Playwright smoke workflow copies that duplicate the same ownership. Keep the repo-owned smoke script and app-specific setup in this repository, but let the controller-managed `.gitea/workflows/playwright-smoke.yml` remain the reusable workflow source of truth under `pr-prep`.

If your repository starts failing only because the shared image tag changed, do not patch the generated workflow to install browsers locally again. Instead, ask the controller operator to publish or repin the shared image and refresh the managed workflow from the controller template.

Older demo or visual-capture scripts may remain in the repository after a task ships, but they are not reused automatically on later tasks. A later UI task must explicitly point its `Demo Media` or `Visual Validation` scenario at the same command if that scenario should be reused.

The bootstrap-managed `scripts/ci.sh`, `scripts/coverage.sh`, `scripts/deploy.sh`, `scripts/artifact.sh`, `scripts/preview.sh`, and `scripts/destroy-preview.sh` files are placeholders. Replace the scripts your repository uses with the real project-specific commands before you rely on validation, coverage, preview automation, or any explicit `production_artifact.command` reuse.

Persona behavior is controlled from the automation controller repository, not from this managed repository.
Edit the install-level bundle under `agents/<persona>/` in the controller repo when you need to change a persona's instructions, templates, or MCP configuration.

The bootstrap setup PR only sanity-checks the managed workflow contract. Normal implementation PRs run `scripts/ci.sh`, and the review workflow checks out the controller repository to run the real review worker against the PR branch in this repository.

Suggested validation steps after the setup PR merges:

1. Confirm `project/opencode-managed.json`, `project/README.md`, `scripts/ci.sh`, `scripts/coverage.sh`, and `scripts/deploy.sh` are present on the default branch, plus `scripts/artifact.sh`, `scripts/preview.sh`, and `scripts/destroy-preview.sh` if this repo will opt into preview support.
2. Make one small edit to the target persona bundle in the automation controller repository.
3. Deploy or refresh the controller checkout on Ultramac.
4. Trigger the next backlog or implementation task for that same persona.
5. Confirm the next task reflects the updated install-level persona instructions.
