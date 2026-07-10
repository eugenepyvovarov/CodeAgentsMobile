# MobileCode Project Security and Reliability Review

Date: 2026-07-10  
Repository: MobileCode / CodeAgentsMobile  
Branch reviewed: main  
Review type: read-only source, configuration, dependency, and test review

## Executive summary

The project passes its current automated checks, but it should not yet be considered security-ready. The review found two critical trust-boundary flaws and several high-priority security, privacy, chat-integrity, and deployment issues.

The first remediation phase should address:

1. SSH host-key verification.
2. Authentication and least privilege for the agent daemon.
3. Remote shell injection and mutable root installation/update paths.
4. CI TLS verification.
5. Chat send, cancellation, and hydration ownership.
6. Privacy disclosures and Apple privacy configuration.
7. Firebase dependency upgrades.

No tracked raw API tokens, passwords, private-key blocks, service-account credentials, ATS arbitrary-load exceptions, or custom HTTPS trust bypasses were found.

## Critical findings

### SEC-01: SSH server identity is never verified

Severity: Critical

[SSHChannelHandlers.swift](../MobileCode/Services/SSHChannelHandlers.swift#L44) defines AcceptAllHostKeysDelegate and unconditionally accepts every host key. [SwiftSHService.swift](../MobileCode/Services/SwiftSHService.swift#L312) installs that delegate for SSH connections.

Impact:

- A network attacker can impersonate any configured SSH host.
- Password authentication can be disclosed directly to the attacker.
- Key-authenticated sessions can be proxied while commands, files, and responses are modified.
- The app cannot detect an unexpected server-key rotation or server replacement.

Recommended remediation:

- Implement known-host verification keyed by hostname/IP and port.
- On first use, show the fingerprint and require explicit confirmation.
- Persist the accepted key securely.
- Block changed keys with a clear warning and explicit rotation/reset flow.
- Add tests for first use, match, mismatch, and intentional rotation.

### SEC-02: Agent daemon exposes secrets and privileged operations without authentication

Severity: Critical

The daemon exposes scheduled task data at [app.py](../server/claude-proxy/app.py#L1340), task creation/execution at [app.py](../server/claude-proxy/app.py#L1472), and plaintext environment-variable values at [app.py](../server/claude-proxy/app.py#L1567). The macOS LaunchDaemon explicitly runs as root in [com.codeagents.claude-proxy.plist](../server/claude-proxy/deploy/launchd/com.codeagents.claude-proxy.plist#L24).

Binding to 127.0.0.1 reduces direct network exposure, but it is not an authentication boundary. Any local process, local user, or SSH user able to access or forward port 8787 can call these routes.

Impact:

- Disclosure of task prompts and plaintext environment values.
- Modification or deletion of task and environment state.
- Creation and execution of agent runs.
- Elevated impact where the daemon runs as root.

Recommended remediation:

- Require a random per-install bearer credential for every non-health endpoint.
- Store the client credential in iOS Keychain and the server credential in a root-readable configuration file.
- Prefer a mode-0600 Unix socket where the transport permits it.
- Run the daemon under a dedicated unprivileged user.
- Enforce allowed project roots and filesystem boundaries.
- Stop returning existing secret values after creation; return masked metadata instead.

## High-priority findings

### SEC-03: Remote shell injection through project paths and filenames

Severity: High

Dynamic values are inserted into shell commands in [ProjectService.swift](../MobileCode/Services/ProjectService.swift#L53) and [FileBrowserViewModel.swift](../MobileCode/ViewModels/FileBrowserViewModel.swift#L114). A name containing an apostrophe can terminate the caller's single-quoted argument and append another command.

This also applies to malicious filenames already present on a remote server. Provider-created servers increase the potential impact because [cloud_init_codeagent.yaml](../MobileCode/Services/SSH/Resources/cloud_init_codeagent.yaml#L3) grants the codeagent account unrestricted passwordless sudo.

Recommended remediation:

- Prefer SFTP or argv-based APIs for filesystem operations.
- Create one centralized and tested POSIX shell-argument quoting helper for unavoidable shell calls.
- Validate newly entered names as one safe path component.
- Reject control characters, slash, empty names, dot, and dot-dot.
- Use end-of-options markers for destructive commands.
- Remove unrestricted passwordless sudo.

### SEC-04: Mutable remote code is installed and automatically executed with elevated privileges

Severity: High

[ProxyInstallerService.swift](../MobileCode/Services/ProxyInstallerService.swift#L39) pipes a mutable GitHub script directly into sudo bash. [OpenCodeServerProvisioning.swift](../MobileCode/Services/OpenCodeServerProvisioning.swift#L269) points to the repository HEAD version of the installer. The daemon checks for upstream updates every 600 seconds in [app.py](../server/claude-proxy/app.py#L49).

Impact:

- Compromise of the upstream repository or account becomes automatic root-level execution across installed servers.
- A bad branch update can be deployed broadly without a controlled rollout.
- Installations are not reproducible because HEAD changes over time.

Recommended remediation:

- Publish versioned release artifacts.
- Pin an immutable commit or artifact digest.
- Verify SHA-256 and preferably a release signature before execution.
- Disable automatic branch-following updates.
- Use explicit, staged, rollback-capable upgrades under least privilege.

### SEC-05: Managed CI globally disables TLS verification

Severity: High

[pr-tests.yml](../.gitea/workflows/pr-tests.yml#L19) sets GIT_SSL_NO_VERIFY=1 and NODE_TLS_REJECT_UNAUTHORIZED=0. It also changes global Git configuration to disable certificate verification. The pattern is repeated across seven managed workflows.

Because macos-ultramac is a persistent runner, the global Git setting can survive the job and affect later Git, Swift Package Manager, npm, or controller operations.

Recommended remediation:

- Fix the automation controller's workflow template rather than patching generated workflows independently.
- Install and trust the internal certificate authority.
- Use GIT_SSL_CAINFO and NODE_EXTRA_CA_CERTS.
- Do not disable TLS globally.
- If a temporary host-specific exception is unavoidable, scope it to the exact internal hostname and remove it in unconditional cleanup.

### SEC-06: Read and Skill permission requests are silently approved persistently

Severity: High

[ToolApprovalStore.swift](../MobileCode/Services/ToolApprovalStore.swift#L42) default allow-lists Read and Skill. [ChatViewModel+ToolApproval.swift](../MobileCode/ViewModels/ChatViewModel+ToolApproval.swift#L21) immediately replies using the stored decision, and [OpenCodeRuntimeService.swift](../MobileCode/Services/OpenCodeRuntimeService.swift#L642) converts agent-scoped approval into OpenCode's always response.

If OpenCode emits a permission request because it reached a path or policy boundary, the app silently bypasses that boundary without showing it to the user.

Recommended remediation:

- Default boundary prompts to Ask/once.
- Make approval decisions path- and pattern-aware.
- Do not persist broad Read approval from a restricted-path request.
- Display the requested path and reason before approval.

### REL-01: In-flight chat sends can cross project and session boundaries

Severity: High

The shared chat view model is reconfigured when the active project changes at [ChatView.swift](../MobileCode/Views/Chat/ChatView.swift#L171). Meanwhile, [ChatViewModel+OpenCodeSend.swift](../MobileCode/ViewModels/ChatViewModel+OpenCodeSend.swift#L54) can be awaiting migration, uploads, setup, or stream events.

Consequences:

- Later chunks from the old project can mutate the new project's message array.
- Two near-simultaneous sends can both pass the active-stream check.
- Stop aborts the server operation but does not reliably terminate the local event consumer.
- A later event in the same session can be consumed into a stopped message.

Recommended remediation:

- Own and retain one send task per project/session.
- Reserve the send synchronously before the first await.
- Capture a project ID, session ID, and generation token.
- Revalidate the token after every await and stream event.
- Cancel and invalidate send work on project switch, session replacement, clear, and cleanup.
- Propagate outer stream termination to the producer and inner event stream.

### REL-02: Hydration can lose final content or restore cleared sessions

Severity: High

[OpenCodeSessionAPI.swift](../MobileCode/Services/OpenCodeSessionAPI.swift#L497) compares only message and part IDs. Updated or finalized content under an existing part ID is therefore treated as unchanged. [OpenCodeRuntimeService.swift](../MobileCode/Services/OpenCodeRuntimeService.swift#L269) advances hydration anchors before messages are merged and durably saved. [ChatViewModel.swift](../MobileCode/ViewModels/ChatViewModel.swift#L326) does not cancel full hydration when chat is cleared.

Consequences:

- Partial content can remain partial permanently.
- A crash between anchor update and local persistence can make missing messages unrecoverable.
- An old full-hydration task can repopulate a cleared or replaced session.

Recommended remediation:

- Track a content hash, revision, or updated timestamp in hydration state.
- Apply message changes and anchors transactionally.
- Advance anchors only after a successful merge and save.
- Scope hydration to project ID, session ID, and generation.
- Cancel all hydration tasks on clear or session replacement.

### SEC-07: Production SSH logging can disclose commands and file contents

Severity: High

[SwiftSHService.swift](../MobileCode/Services/SwiftSHService.swift#L32) enables verbose logging unconditionally. [SSHChannelHandlers.swift](../MobileCode/Services/SSHChannelHandlers.swift#L165) logs command content and output, while [ChatAttachmentUploadService.swift](../MobileCode/Services/Chat/ChatAttachmentUploadService.swift#L114) embeds base64 file contents in executed command strings.

Device console captures, sysdiagnostics, and support logs can therefore contain commands, project paths, configuration data, environment values, and reconstructible file contents.

Recommended remediation:

- Compile payload logging out of Release builds.
- Default production logging to warning/error.
- Never log command bodies, stdin, stdout, or base64 payloads.
- Use structured metadata-only logging with privacy redaction.

### DEP-01: Firebase Functions use a vulnerable production dependency graph

Severity: High

The current npm audit reports 19 production findings: 2 critical, 4 high, 12 moderate, and 1 low. Locked examples in [package-lock.json](../server/firebase-functions/functions/package-lock.json#L3508) include:

- protobufjs 7.5.4
- fast-xml-parser 4.5.3
- @grpc/grpc-js 1.14.3
- node-forge 1.3.3

Relevant advisories:

- [protobufjs advisory](https://github.com/advisories/GHSA-xq3m-2v4x-88gg)
- [fast-xml-parser advisory](https://github.com/advisories/GHSA-m7jm-9gc2-mpf2)
- [grpc-js advisory](https://github.com/advisories/GHSA-5375-pq7m-f5r2)

Exploitability was not established for every transitive path, but the deployed graph is demonstrably affected.

Recommended remediation:

- Upgrade Firebase Admin and Firebase Functions to a supported patched stack.
- Regenerate the lockfile.
- Run build, lint, tests, and Firebase emulator validation.
- Add production npm audit or dependency scanning to CI after establishing a clean baseline.

### PRIV-01: Published privacy claims do not match actual data flow

Severity: High

[PRIVACY_POLICY.md](../PRIVACY_POLICY.md#L7) says data remains on-device and describes only Claude/Anthropic processing. In practice, [PushGatewayClient.swift](../MobileCode/Services/PushGatewayClient.swift#L68) sends project working directories, installation IDs, FCM tokens, and agent display names to Firebase. [index.ts](../server/firebase-functions/functions/src/index.ts#L176) handles assistant-message previews that are sent through FCM/APNs.

Additional gaps:

- The policy still describes Claude chat although OpenCode is now the supported chat runtime.
- There is no complete user-driven unregister/deletion path for remotely stored push registrations.
- No general retention or TTL policy is implemented.
- Notification previews can expose assistant output, code, or secrets on a lock screen.

Recommended remediation:

- Update the privacy policy and App Store privacy disclosures.
- Document Firebase/Google/APNs processors, identifiers, project metadata, message previews, purpose, retention, and deletion.
- Default notifications to a generic Reply ready body.
- Make content previews explicit opt-in.
- Add authenticated unregister/delete APIs and retention/TTL cleanup.
- Update the public Selfhosted Ninja project page when public copy changes.

### PRIV-02: Apple privacy and local-network configuration is incomplete

Severity: High

No PrivacyInfo.xcprivacy file is tracked or included in the app target despite first-party UserDefaults usage. Apple requires accurate approved-reason declarations for required-reason APIs:

- [Apple required-reason API guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)

NSLocalNetworkUsageDescription exists only in the UI-test target at [project.pbxproj](../CodeAgentsMobile.xcodeproj/project.pbxproj#L578), even though the app can make direct TCP/SSH connections to local hosts:

- [Apple local-network usage requirement](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)

Recommended remediation:

- Add PrivacyInfo.xcprivacy to the main app target.
- Declare the accurate UserDefaults approved reason and collected-data behavior.
- Add a clear NSLocalNetworkUsageDescription to the main target.
- Generate and inspect the archive privacy report before release.

## Medium-priority findings

### API-01: Public Firebase functions accept any non-empty bearer value

[index.ts](../server/firebase-functions/functions/src/index.ts#L41) only checks that the bearer string is non-empty, then hashes it into a namespace. An attacker can create arbitrary namespaces and consume Firestore storage, function invocations, logs, and platform quota.

Recommended remediation:

- Add authenticated server enrollment or an allow-listed server-secret registry.
- Add App Check where appropriate.
- Enforce request and field-size limits.
- Add per-secret/IP rate limits, quotas, and abuse alerts.

### REL-03: Scheduled-task creation retries a non-idempotent POST

[ProxyTaskService.swift](../MobileCode/Services/ProxyTaskService.swift#L201) retries task upsert after transport errors. For new tasks, both attempts use POST. If the first request commits but its response is lost, the retry creates a duplicate.

Recommended remediation:

- Use a stable client-generated UUID/idempotency key.
- Enforce uniqueness server-side.
- Prefer idempotent PUT semantics for known client IDs.
- Do not automatically retry unkeyed creates.

### REL-04: Attachment upload and cleanup can consume excessive memory and retain sensitive data

Attachment upload reads the complete file and creates a second complete base64 representation in memory at [ChatAttachmentUploadService.swift](../MobileCode/Services/Chat/ChatAttachmentUploadService.swift#L114). Durable copies in Application Support do not have a complete clear-chat/project-deletion cleanup lifecycle.

Recommended remediation:

- Add file-size and attachment-count limits.
- Stream uploads through SFTP or bounded chunks.
- Clean up files on removal, clear, project deletion, and retention expiry.
- Exclude cache-like data from backup or store it in a cache location.

### TEST-01: Streamed-response E2E can pass without an assistant response

The user prompt contains the word confirming at [OpenCodeCloudMutationE2ETests.swift](../MobileCodeUITests/OpenCodeCloudMutationE2ETests.swift#L561). The fallback assertion searches all static labels for confirm, so the user's own prompt can satisfy the assistant-response assertion.

Recommended remediation:

- Add a stable assistant-role accessibility identifier.
- Scope assertions to an assistant bubble or assistant-role descendant.
- Remove global text heuristics for response verification.

### TEST-02: E2E cleanup can delete resources from concurrent runs

[run-opencode-cloud-ux.sh](../scripts/e2e/run-opencode-cloud-ux.sh#L256) treats every resource matching the shared prefix as eligible for deletion. One run can therefore delete resources belonging to another run.

Recommended remediation:

- Namespace resources by run ID.
- Clean up exact captured provider IDs during normal runs.
- Move stale prefix cleanup into a separate maintenance command with age and label checks.

### TEST-03: Production app code still contains test-only behavior

Repository policy prohibits adding test-only product behavior, but production sources still include UI-test seeding, in-memory/reset paths, environment-controlled form population, SSH private-key injection, and auto-dismiss behavior.

Recommended remediation:

- Move fixture preparation into MobileCodeUITests and scripts/e2e.
- Drive real product controls.
- Improve product accessibility where tests need stable interaction.
- Remove legacy test-only branches incrementally when touching those areas.

### QA-01: Backend validation and coverage are missing from canonical CI

[scripts/ci.sh](../scripts/ci.sh#L34) runs the iOS unit path but not Firebase Functions lint, tests, build, or audit. [coverage.sh](../scripts/coverage.sh#L4) remains a hard-failing placeholder even though the managed project contract advertises it.

Recommended remediation:

- Add npm ci, build, lint, test, and dependency scanning to canonical validation.
- Implement xccov-based application coverage.
- Keep external live SSH suites explicitly separate.

## Runtime improvements

The following were also found during the chat/runtime review:

- Stop does not reliably terminate the local stream producer.
- Pending permissions and OpenCode questions can be discarded on navigation or project switch without replying.
- Migration promotes the runtime before all migration steps finish and stamps some failed work as complete.
- Session status is fetched before hydration and then applied destructively after hydration, creating a stale-snapshot race.
- Attachment retry rebuilds the prompt without the originally selected skill.
- Some post-placeholder stream failures leave partial messages without a terminal error state.

These should be covered with focused ownership, cancellation, restartability, and failure-injection tests.

## Validation performed

- Canonical ./scripts/ci.sh: passed.
- Focused chat/runtime validation: 72 tests passed.
- Firebase Functions lint: passed.
- Firebase Functions tests: 6 of 6 passed.
- Proxy tests: 34 passed using the virtual environment's Python module invocation.
- Production npm audit: failed with 19 findings.
- Shell script syntax checks: passed.
- Plist and entitlement linting: passed.
- No live cloud/UI E2E run was performed because it creates external resources.

Passing tests do not invalidate the findings above: most concern trust boundaries, concurrency timing, partial network failures, stale async work, platform disclosures, or production deployment configuration that the existing suites do not exercise.

## Prior-review recheck

The following older concerns appear resolved:

- The CloudProvidersView secret/autofill test branch is gone.
- Full-field UI replacement now deletes the complete current value.
- XCTest teardown uses exact resource names.
- The repository ignores .codex state.
- Current test configuration uses an installed app path rather than DerivedData.

The following remain partially or fully unresolved:

- Shell-level E2E cleanup is still prefix-wide.
- Stream verification changed but can still false-positive on user text.
- Provisional task identity and non-idempotent create retry remain.

## Recommended remediation sequence

### Phase 1: Trust boundaries

1. Implement SSH host-key verification.
2. Authenticate the daemon and remove root execution.
3. Eliminate shell interpolation and unrestricted sudo.
4. Pin and verify server installation/update artifacts.
5. Restore TLS verification in managed CI.

### Phase 2: Chat correctness

1. Add project/session/generation ownership to sends and hydration.
2. Make Stop cancel the local and remote operation.
3. Commit hydration content and anchors transactionally.
4. Make migration restartable and version-correct.
5. Preserve or explicitly reject outstanding permission/question requests.

### Phase 3: Release compliance and dependencies

1. Correct privacy policy and public product copy.
2. Add remote unregister/deletion and notification-preview controls.
3. Add PrivacyInfo.xcprivacy and main-target local-network usage text.
4. Upgrade Firebase dependencies and Node runtime.
5. Add backend security validation to canonical CI.

### Phase 4: Reliability and test integrity

1. Add idempotency for task creation.
2. Stream and clean up attachments.
3. Fix assistant-response accessibility assertions.
4. Isolate E2E resources by run ID.
5. Remove remaining production test harness branches.

## Review state

This report documents findings only. No remediation changes were made as part of the review.
