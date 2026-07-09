//
//  CodeAgentsDaemonUpdateService.swift
//  CodeAgentsMobile
//
//  Purpose: Keep the remote CodeAgents daemon on the latest published GitHub
//  revision without per-customer SSH deploys. Uses healthz.version vs repo HEAD
//  and re-runs the standard install script when behind or unhealthy.
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

/// App-driven daemon auto-upgrade.
///
/// Customers never need a manual `git pull` on each droplet: whenever the app
/// talks to a server (OpenCode health / task ensure), it compares
/// `GET /healthz` → `version` with GitHub HEAD and reinstalls via the same
/// `install.sh` path used for first-time setup when the daemon is behind or down.
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

    /// Ensure the daemon is healthy and not behind GitHub HEAD.
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
        let expected: String?
        do {
            let probe = try await session.execute(CodeAgentsDaemonProvisioning.remoteHeadProbeCommand())
            expected = CodeAgentsDaemonProvisioning.parseRemoteHead(probe)
        } catch {
            // If we cannot learn HEAD, treat a healthy daemon as good enough.
            lastSuccessfulCheckAt[serverID] = Date()
            if repaired {
                return .repaired(version: installedVersion)
            }
            if let installedVersion {
                return .alreadyCurrent(version: installedVersion)
            }
            return .skipped(reason: "Could not probe remote HEAD: \(error.localizedDescription)")
        }

        guard let expected else {
            lastSuccessfulCheckAt[serverID] = Date()
            if repaired {
                return .repaired(version: installedVersion)
            }
            if let installedVersion {
                return .alreadyCurrent(version: installedVersion)
            }
            return .skipped(reason: "Remote HEAD probe returned no SHA")
        }

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
