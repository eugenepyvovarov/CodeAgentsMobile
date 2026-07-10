//
//  CodeAgentsDaemonUpdateService.swift
//  CodeAgentsMobile
//
//  Purpose: Keep the remote CodeAgents daemon on the app-pinned GitHub revision
//  without per-customer SSH deploys. Uses healthz.version vs pinnedInstallCommit
//  and re-runs the pinned install script when behind or unhealthy.
//

import Foundation

enum CodeAgentsDaemonUpdateOutcome: Equatable {
    case alreadyCurrent(version: String)
    case upgraded(from: String?, to: String)
    case repaired(version: String?)
    case skipped(reason: String)
    case failed(reason: String)

    var didMutateDaemon: Bool {
        switch self {
        case .upgraded, .repaired:
            return true
        case .alreadyCurrent, .skipped, .failed:
            return false
        }
    }
}

/// App-driven daemon auto-upgrade to the **pinned** revision shipped with the app.
///
/// Customers never need a manual `git pull` on each droplet: whenever the app
/// talks to a server (Agents list soft check / OpenCode health / task ensure),
/// it compares `GET /healthz` → `version` with `CodeAgentsDaemonProvisioning.pinnedInstallCommit`
/// and reinstalls via the pinned `install.sh` when the daemon is behind or down.
/// Does **not** follow mutable GitHub HEAD.
///
/// Also auto-provisions `CODEAGENTS_DAEMON_TOKEN` (Keychain + remote env) once the
/// daemon is healthy — no install sheet or settings action required.
///
/// Independent of push notifications: push only wakes the app for chat
/// delivery; upgrade still runs from the Agents list even when push is off.
@MainActor
final class CodeAgentsDaemonUpdateService {
    static let shared = CodeAgentsDaemonUpdateService()

    /// Skip redundant HEAD probes within this window per server.
    var checkCooldown: TimeInterval = 15 * 60
    /// Avoid hammering install.sh if a previous upgrade just ran.
    var upgradeCooldown: TimeInterval = 30 * 60

    private var lastSuccessfulCheckAt: [UUID: Date] = [:]
    private var lastUpgradeAttemptAt: [UUID: Date] = [:]
    private var inFlightServers: Set<UUID> = []

    private init() {}

    /// Best-effort background check for servers that own agents in the list.
    /// Does not block UI, does not require push, and respects per-server cooldowns
    /// so opening Agents repeatedly is cheap.
    /// Also auto-provisions the daemon HTTP bearer when missing (no user action).
    func softEnsureUpToDate(servers: [Server]) async {
        var seen = Set<UUID>()
        for server in servers {
            guard seen.insert(server.id).inserted else { continue }

            let needsDaemonToken = !ProxyInstallerService.shared.hasLocalDaemonToken(for: server.id)

            // Skip SSH entirely when this server was checked recently — unless we still
            // need a local daemon bearer (Keychain empty after auth rollout / new device).
            if !needsDaemonToken,
               let last = lastSuccessfulCheckAt[server.id],
               Date().timeIntervalSince(last) < checkCooldown {
                continue
            }
            if inFlightServers.contains(server.id) {
                continue
            }

            do {
                let session = try await SSHService.shared.connect(to: server, purpose: .fileOperations)
                defer { session.disconnect() }

                let outcome = await ensureUpToDate(
                    session: session,
                    serverID: server.id,
                    force: false,
                    allowInstall: true
                )
                switch outcome {
                case .upgraded(let from, let to):
                    SSHLogger.log(
                        "Agents-list soft upgrade \(server.name): \(from ?? "unknown") → \(to)",
                        level: .info
                    )
                case .repaired(let version):
                    SSHLogger.log(
                        "Agents-list soft repair \(server.name) (version=\(version ?? "unknown"))",
                        level: .info
                    )
                case .failed(let reason):
                    SSHLogger.log(
                        "Agents-list soft daemon check failed \(server.name): \(reason)",
                        level: .warning
                    )
                case .alreadyCurrent, .skipped:
                    break
                }
            } catch {
                SSHLogger.log(
                    "Agents-list soft daemon check SSH failed \(server.name): \(error.localizedDescription)",
                    level: .warning
                )
            }
        }
    }

    /// Ensure the daemon is healthy and not behind the app-pinned revision.
    /// - Parameters:
    ///   - session: Open SSH session (file ops / opencode / proxy install).
    ///   - serverID: Used for per-server throttling.
    ///   - force: Ignore check cooldown (still respects in-flight + upgrade cooldown unless forced hard).
    ///   - allowInstall: When false, only restarts if unhealthy (no install.sh).
    ///   - onOutput: Optional progress lines for UI install flows.
    @discardableResult
    func ensureUpToDate(
        session: SSHSession,
        serverID: UUID,
        force: Bool = false,
        allowInstall: Bool = true,
        onOutput: ((String) -> Void)? = nil
    ) async -> CodeAgentsDaemonUpdateOutcome {
        if inFlightServers.contains(serverID) {
            return .skipped(reason: "Daemon update already in progress")
        }

        inFlightServers.insert(serverID)
        defer { inFlightServers.remove(serverID) }

        let log: (String) -> Void = { message in
            onOutput?(message)
            SSHLogger.log(message, level: .info)
        }

        // Always health-probe (cooldown only skips the GitHub HEAD / install path).
        let healthRaw = try? await session.execute(CodeAgentsDaemonProvisioning.healthCheckCommand())
        let health = healthRaw.flatMap { CodeAgentsDaemonProvisioning.parseHealthz($0) }
        let installedVersion = CodeAgentsDaemonProvisioning.normalizeVersion(health?.version)

        if health == nil || health?.isHealthy != true {
            log("CodeAgents daemon unhealthy; attempting restart")
            _ = try? await session.execute(CodeAgentsDaemonProvisioning.restartCommand())
            _ = try? await session.execute(CodeAgentsDaemonProvisioning.waitForHealthScript(maxAttempts: 15))

            let afterRestartRaw = try? await session.execute(CodeAgentsDaemonProvisioning.healthCheckCommand())
            let afterRestart = afterRestartRaw.flatMap { CodeAgentsDaemonProvisioning.parseHealthz($0) }
            if let afterRestart, afterRestart.isHealthy {
                await ensureDaemonAuthToken(serverID: serverID, session: session)
                return await finishVersionCheck(
                    session: session,
                    serverID: serverID,
                    installedVersion: CodeAgentsDaemonProvisioning.normalizeVersion(afterRestart.version),
                    allowInstall: allowInstall,
                    force: force,
                    repaired: true,
                    log: log
                )
            }

            guard allowInstall else {
                let reason = "Daemon unhealthy and install not allowed"
                SSHLogger.log(reason, level: .warning)
                return .failed(reason: reason)
            }

            if !force,
               let lastUpgrade = lastUpgradeAttemptAt[serverID],
               Date().timeIntervalSince(lastUpgrade) < upgradeCooldown {
                return .skipped(reason: "Upgrade attempted recently while unhealthy")
            }

            return await runInstall(
                session: session,
                serverID: serverID,
                previousVersion: installedVersion,
                log: log
            )
        }

        // Healthy daemon: keep Keychain ↔ remote bearer in sync without user action.
        await ensureDaemonAuthToken(serverID: serverID, session: session)

        // Healthy: throttle expensive HEAD probe / potential install.
        if !force,
           let last = lastSuccessfulCheckAt[serverID],
           Date().timeIntervalSince(last) < checkCooldown {
            return .skipped(reason: "Checked recently")
        }

        return await finishVersionCheck(
            session: session,
            serverID: serverID,
            installedVersion: installedVersion,
            allowInstall: allowInstall,
            force: force,
            repaired: false,
            log: log
        )
    }

    /// Provision or adopt `CODEAGENTS_DAEMON_TOKEN` after the daemon is reachable.
    private func ensureDaemonAuthToken(serverID: UUID, session: SSHSession) async {
        await ProxyInstallerService.shared.ensureDaemonTokenIfNeeded(for: serverID, using: session)
    }

    // MARK: - Internals

    private func finishVersionCheck(
        session: SSHSession,
        serverID: UUID,
        installedVersion: String?,
        allowInstall: Bool,
        force: Bool,
        repaired: Bool,
        log: (String) -> Void
    ) async -> CodeAgentsDaemonUpdateOutcome {
        let expected = CodeAgentsDaemonProvisioning.expectedDaemonVersion

        if CodeAgentsDaemonProvisioning.versionsMatch(installed: installedVersion, expected: expected) {
            lastSuccessfulCheckAt[serverID] = Date()
            let version = installedVersion ?? expected
            if repaired {
                log("CodeAgents daemon repaired and current (\(version))")
                return .repaired(version: version)
            }
            log("CodeAgents daemon is up to date (\(version))")
            return .alreadyCurrent(version: version)
        }

        guard allowInstall else {
            lastSuccessfulCheckAt[serverID] = Date()
            let reason = "Daemon behind (\(installedVersion ?? "unknown") < \(expected)); install not allowed"
            SSHLogger.log(reason, level: .warning)
            if repaired {
                return .repaired(version: installedVersion)
            }
            return .skipped(reason: reason)
        }

        if !force,
           let lastUpgrade = lastUpgradeAttemptAt[serverID],
           Date().timeIntervalSince(lastUpgrade) < upgradeCooldown {
            return .skipped(reason: "Upgrade attempted recently")
        }

        log(
            "CodeAgents daemon behind (installed=\(installedVersion ?? "unknown"), expected=\(prefix(expected))); upgrading..."
        )
        return await runInstall(
            session: session,
            serverID: serverID,
            previousVersion: installedVersion,
            log: log
        )
    }

    private func runInstall(
        session: SSHSession,
        serverID: UUID,
        previousVersion: String?,
        log: (String) -> Void
    ) async -> CodeAgentsDaemonUpdateOutcome {
        lastUpgradeAttemptAt[serverID] = Date()

        let previousLogLevel = SSHLogger.logLevel
        SSHLogger.logLevel = .warning
        defer { SSHLogger.logLevel = previousLogLevel }

        do {
            let command = """
            set -euo pipefail
            \(CodeAgentsDaemonProvisioning.installCommand(useSudo: true))
            \(CodeAgentsDaemonProvisioning.waitForHealthScript(maxAttempts: 30))
            \(CodeAgentsDaemonProvisioning.healthCheckCommand())
            """
            let output = try await session.execute(command)
            let health = CodeAgentsDaemonProvisioning.parseHealthz(output)
                ?? output
                    .split(whereSeparator: \.isNewline)
                    .reversed()
                    .lazy
                    .compactMap { CodeAgentsDaemonProvisioning.parseHealthz(String($0)) }
                    .first
            let newVersion = CodeAgentsDaemonProvisioning.normalizeVersion(health?.version)
                ?? previousVersion
                ?? "unknown"

            lastSuccessfulCheckAt[serverID] = Date()
            // Auto-install path does not go through ProxyInstallerService.installProxy;
            // still provision the bearer so task/env HTTP is authenticated without UI.
            await ensureDaemonAuthToken(serverID: serverID, session: session)
            log("CodeAgents daemon upgraded to \(newVersion)")
            return .upgraded(from: previousVersion, to: newVersion)
        } catch {
            let reason = "Daemon install/upgrade failed: \(error.localizedDescription)"
            SSHLogger.log(reason, level: .error)
            return .failed(reason: reason)
        }
    }

    private func prefix(_ sha: String, length: Int = 7) -> String {
        String(sha.prefix(length))
    }

    #if DEBUG
    /// Test seam: reset throttles.
    func resetThrottlesForTesting() {
        lastSuccessfulCheckAt.removeAll()
        lastUpgradeAttemptAt.removeAll()
        inFlightServers.removeAll()
    }
    #endif
}
