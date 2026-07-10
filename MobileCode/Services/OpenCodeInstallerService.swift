//
//  OpenCodeInstallerService.swift
//  CodeAgentsMobile
//
//  Purpose: Verify OpenCode runtime setup on managed servers.
//

import Foundation

struct OpenCodeRuntimeSetupStatus: Equatable {
    enum State: Equatable {
        case available
        case authRequired
        case notInstalled
        case notRunning
        case daemonUnavailable
        case unreachable
        case sshUnavailable
        case unknown
    }

    let state: State
    let version: String?
    let message: String

    var isReady: Bool {
        state == .available
    }

    var blocksForegroundChat: Bool {
        switch state {
        case .available, .daemonUnavailable:
            return false
        case .authRequired, .notInstalled, .notRunning, .unreachable, .sshUnavailable, .unknown:
            return true
        }
    }

    static func available(version: String) -> Self {
        OpenCodeRuntimeSetupStatus(
            state: .available,
            version: version,
            message: "OpenCode \(version) is healthy."
        )
    }

    static func authRequired() -> Self {
        OpenCodeRuntimeSetupStatus(
            state: .authRequired,
            version: nil,
            message: "OpenCode requires server authentication. Enter the server username and password."
        )
    }

    static func notInstalled() -> Self {
        OpenCodeRuntimeSetupStatus(
            state: .notInstalled,
            version: nil,
            message: "OpenCode is not installed on this server."
        )
    }

    static func notRunning(_ serviceState: String?) -> Self {
        let suffix = serviceState.map { " Service state: \($0)." } ?? ""
        return OpenCodeRuntimeSetupStatus(
            state: .notRunning,
            version: nil,
            message: "OpenCode is installed but the server service is not running.\(suffix)"
        )
    }

    static func unreachable(_ reason: String) -> Self {
        OpenCodeRuntimeSetupStatus(
            state: .unreachable,
            version: nil,
            message: "OpenCode is not reachable on 127.0.0.1:4096. \(reason)"
        )
    }

    static func daemonUnavailable(version: String, reason: String) -> Self {
        OpenCodeRuntimeSetupStatus(
            state: .daemonUnavailable,
            version: version,
            message: "OpenCode \(version) is healthy, but the CodeAgents daemon is not reachable on 127.0.0.1:8787. Scheduled tasks and push notifications need the daemon. \(reason)"
        )
    }

    static func sshUnavailable(_ reason: String) -> Self {
        OpenCodeRuntimeSetupStatus(
            state: .sshUnavailable,
            version: nil,
            message: "Could not connect over SSH. \(reason)"
        )
    }

    static func unknown(_ reason: String) -> Self {
        OpenCodeRuntimeSetupStatus(
            state: .unknown,
            version: nil,
            message: reason
        )
    }
}

/// Shared OpenCode runtime health probe used by Chat and Edit Server.
///
/// Caches results per server so concurrent tabs don't thrash SSH tunnels, and
/// soft-retries transient NIOSSH / direct-TCP blips before reporting Unreachable.
///
/// Chat-open probes use the **pooled** `.opencode` SSH session (no connect/disconnect)
/// and skip daemon install/upgrade work so hydrate/send can reuse the same login.
@MainActor
final class OpenCodeInstallerService {
    static let shared = OpenCodeInstallerService()

    /// How long a healthy / non-blocking result can be reused across views.
    /// Longer than a typical notification→reopen gap so soft opens skip full probes.
    var healthyCacheTTL: TimeInterval = 180
    /// Keep blocking failures short-lived so recovery is quick after a blip.
    var failureCacheTTL: TimeInterval = 5
    /// Extra health attempts after the first failure (total = 1 + this).
    var healthRetryCount: Int = 1
    /// Brief pause between soft retries.
    var healthRetryDelayNanoseconds: UInt64 = 400_000_000

    private struct CachedStatus {
        let status: OpenCodeRuntimeSetupStatus
        let checkedAt: Date
    }

    private var statusCache: [UUID: CachedStatus] = [:]
    private var inFlightChecks: [UUID: Task<OpenCodeRuntimeSetupStatus, Never>] = [:]
    private var inFlightDaemonEnsures: Set<UUID> = []
    private var inFlightWarms: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// Drop cached health for one server (or all) after install/repair or manual force-check.
    func invalidateRuntimeStatusCache(for serverID: UUID? = nil) {
        if let serverID {
            statusCache.removeValue(forKey: serverID)
        } else {
            statusCache.removeAll()
        }
    }

    func verifyRuntime(on server: Server, onOutput: @escaping (String) -> Void) async throws -> OpenCodeRuntimeSetupStatus {
        invalidateRuntimeStatusCache(for: server.id)
        let status = await probeRuntimeStatus(
            on: server,
            onOutput: onOutput,
            includeDaemon: true,
            allowDaemonInstall: true
        )
        cache(status, for: server.id)
        guard status.isReady || !status.blocksForegroundChat else {
            throw OpenCodeInstallerError.setupFailed(status.message)
        }
        if case .unknown = status.state, status.message.contains("unhealthy") {
            throw OpenCodeInstallerError.unhealthy
        }
        return status
    }

    /// Shared health entrypoint for Chat, Edit Server, and install verification.
    /// - Parameters:
    ///   - force: Bypass cache (manual "Check again" / connect-loop retries).
    ///   - includeDaemon: When true (Edit Server / verify), also runs daemon ensure.
    ///     Chat open keeps this false so daemon work never blocks the Connecting pill.
    func checkRuntimeStatus(
        on server: Server,
        force: Bool = false,
        includeDaemon: Bool = false
    ) async -> OpenCodeRuntimeSetupStatus {
        if !force, let cached = statusCache[server.id] {
            let ttl = cached.status.blocksForegroundChat ? failureCacheTTL : healthyCacheTTL
            if Date().timeIntervalSince(cached.checkedAt) < ttl {
                return cached.status
            }
        }

        // Coalesce concurrent probes for the same server so chat + warm share one SSH login.
        if let existing = inFlightChecks[server.id] {
            return await existing.value
        }

        let includeDaemonCapture = includeDaemon
        let task = Task { @MainActor in
            await self.probeRuntimeStatus(
                on: server,
                onOutput: nil,
                includeDaemon: includeDaemonCapture,
                allowDaemonInstall: includeDaemonCapture
            )
        }
        inFlightChecks[server.id] = task
        let status = await task.value
        inFlightChecks[server.id] = nil
        cache(status, for: server.id)
        return status
    }

    /// Pre-open the pooled OpenCode SSH session (and optionally probe health) so chat open
    /// reuses an already-warm login after notification / foreground.
    func warmConnection(for server: Server, probeHealth: Bool = true) async {
        if let existing = inFlightWarms[server.id] {
            await existing.value
            return
        }

        let task = Task { @MainActor in
            let timingStart = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try await SSHService.shared.getConnection(for: server, purpose: .opencode)
                if probeHealth {
                    _ = await self.checkRuntimeStatus(on: server, force: false, includeDaemon: false)
                }
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: server.id.uuidString,
                    operation: "opencode.warmConnection",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                    metadata: [
                        "probeHealth": .flag(probeHealth),
                        "status": .status(.complete)
                    ]
                )
            } catch {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: server.id.uuidString,
                    operation: "opencode.warmConnection",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                    metadata: [
                        "probeHealth": .flag(probeHealth),
                        "status": .status(.failed)
                    ]
                )
                SSHLogger.log(
                    "OpenCode warm failed for \(server.name): \(error.localizedDescription)",
                    level: .warning
                )
            }
        }
        inFlightWarms[server.id] = task
        await task.value
        inFlightWarms[server.id] = nil
    }

    /// Warm the currently active project's OpenCode connection (foreground / scene active).
    func warmActiveProjectConnectionIfNeeded() async {
        guard let server = ProjectContext.shared.activeServer else { return }
        await warmConnection(for: server, probeHealth: true)
    }

    /// After chat is ready, keep the CodeAgents daemon healthy without blocking the UI.
    func scheduleBackgroundDaemonEnsure(for server: Server) {
        let serverID = server.id
        guard !inFlightDaemonEnsures.contains(serverID) else { return }
        inFlightDaemonEnsures.insert(serverID)

        Task { @MainActor in
            defer { self.inFlightDaemonEnsures.remove(serverID) }
            let timingStart = DispatchTime.now().uptimeNanoseconds
            do {
                let session = try await SSHService.shared.getConnection(for: server, purpose: .opencode)
                let outcome = await CodeAgentsDaemonUpdateService.shared.ensureUpToDate(
                    session: session,
                    serverID: serverID,
                    force: false,
                    allowInstall: true,
                    onOutput: nil
                )
                let statusLabel: ChatRecoveryTiming.Status
                switch outcome {
                case .failed:
                    statusLabel = .failed
                case .skipped, .alreadyCurrent, .repaired, .upgraded:
                    statusLabel = .complete
                }
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: serverID.uuidString,
                    operation: "opencode.daemonEnsure.background",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                    metadata: ["status": .status(statusLabel)]
                )
                if case .failed(let reason) = outcome {
                    SSHLogger.log(
                        "Background daemon ensure failed for \(server.name): \(reason)",
                        level: .warning
                    )
                }
            } catch {
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: serverID.uuidString,
                    operation: "opencode.daemonEnsure.background",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                    metadata: ["status": .status(.failed)]
                )
                SSHLogger.log(
                    "Background daemon ensure SSH failed for \(server.name): \(error.localizedDescription)",
                    level: .warning
                )
            }
        }
    }

    func installOrRepairRuntime(
        on server: Server,
        username: String,
        password: String?,
        onOutput: @escaping (String) -> Void
    ) async throws -> OpenCodeRuntimeSetupStatus {
        invalidateRuntimeStatusCache(for: server.id)

        // Install uses a dedicated non-pooled session so long-running sudo work does not
        // block or risk the chat `.opencode` pool entry.
        let session = try await SSHService.shared.connect(to: server, purpose: .opencode)
        defer {
            session.disconnect()
        }

        let script = OpenCodeServerProvisioning.manualInstallScript(
            username: username,
            password: password
        )
        let encodedScript = Data(script.utf8).base64EncodedString()
        let command = "printf '%s' '\(encodedScript)' | base64 -d | sudo -n bash"

        onOutput("Installing OpenCode on \(OpenCodeServerProvisioning.host):\(OpenCodeServerProvisioning.port)...")

        let previousLogLevel = SSHLogger.logLevel
        SSHLogger.logLevel = .warning
        defer {
            SSHLogger.logLevel = previousLogLevel
        }

        let process = try await session.startProcess(command)
        let lineBuffer = LineBuffer()

        do {
            for try await chunk in process.outputStream() {
                for line in lineBuffer.addData(chunk) {
                    onOutput(line)
                }
            }
        } catch {
            throw OpenCodeInstallerError.processFailed(error.localizedDescription)
        }

        if let trailing = lineBuffer.flush() {
            onOutput(trailing)
        }

        let status = await checkRuntimeStatus(
            session: session,
            serverID: server.id,
            includeDaemon: true,
            allowDaemonInstall: true,
            onOutput: onOutput
        )
        cache(status, for: server.id)
        guard status.isReady || !status.blocksForegroundChat else {
            throw OpenCodeInstallerError.setupFailed(status.message)
        }
        return status
    }

    nonisolated static func status(from diagnostics: String, healthError: Error) -> OpenCodeRuntimeSetupStatus {
        if let clientError = healthError as? OpenCodeClientError {
            switch clientError {
            case .httpError(let status, _):
                if status == 401 || status == 403 {
                    return .authRequired()
                }
            default:
                break
            }
        }

        let values = diagnosticValues(from: diagnostics)
        if values["binary"] == "missing" {
            return .notInstalled()
        }

        if let service = values["service"],
           service != "active",
           service != "unknown" {
            return .notRunning(service)
        }

        return .unreachable(healthError.localizedDescription)
    }

    /// True when the failure looks like a transient tunnel / TCP blip worth soft-retrying.
    nonisolated static func isTransientHealthFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let clientError = error as? OpenCodeClientError {
            switch clientError {
            case .requestTimedOut, .invalidResponse:
                return true
            case .httpError(let status, _):
                // Auth / permanent HTTP codes should not soft-retry.
                return status >= 500 || status == 408 || status == 429
            case .invalidRequest, .decodingFailed:
                return false
            }
        }

        let nsError = error as NSError
        // POSIX / network blips (connection reset, broken pipe, timed out).
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(ECONNRESET), Int(EPIPE), Int(ETIMEDOUT), Int(ECONNABORTED), Int(ENOTCONN):
                return true
            default:
                break
            }
        }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost:
                return true
            default:
                break
            }
        }

        let message = error.localizedDescription.lowercased()
        let transientTokens = [
            "connection reset",
            "broken pipe",
            "timed out",
            "timeout",
            "temporarily unavailable",
            "channel closed",
            "nio",
            "eof"
        ]
        return transientTokens.contains { message.contains($0) }
    }

    // MARK: - Internals

    private func cache(_ status: OpenCodeRuntimeSetupStatus, for serverID: UUID) {
        statusCache[serverID] = CachedStatus(status: status, checkedAt: Date())
    }

    private func probeRuntimeStatus(
        on server: Server,
        onOutput: ((String) -> Void)?,
        includeDaemon: Bool,
        allowDaemonInstall: Bool
    ) async -> OpenCodeRuntimeSetupStatus {
        onOutput?("Checking OpenCode health at \(OpenCodeServerProvisioning.host):\(OpenCodeServerProvisioning.port)...")

        var lastStatus: OpenCodeRuntimeSetupStatus?
        let attempts = 1 + max(0, healthRetryCount)
        let probeStart = DispatchTime.now().uptimeNanoseconds

        for attempt in 1...attempts {
            do {
                let sshStart = DispatchTime.now().uptimeNanoseconds
                let session = try await SSHService.shared.getConnection(for: server, purpose: .opencode)
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: server.id.uuidString,
                    operation: "opencode.probe.ssh",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - sshStart,
                    metadata: [
                        "attempt": .count(attempt),
                        "status": .status(.complete)
                    ]
                )

                let healthStart = DispatchTime.now().uptimeNanoseconds
                let status = await checkRuntimeStatus(
                    session: session,
                    serverID: server.id,
                    includeDaemon: includeDaemon,
                    allowDaemonInstall: allowDaemonInstall,
                    onOutput: onOutput
                )
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: server.id.uuidString,
                    operation: "opencode.probe.health",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - healthStart,
                    metadata: [
                        "attempt": .count(attempt),
                        "includeDaemon": .flag(includeDaemon),
                        "status": .status(status.blocksForegroundChat ? .failed : .complete)
                    ]
                )

                // Soft-retry only transient unreachable / unknown blips, not auth/missing install.
                if status.blocksForegroundChat,
                   attempt < attempts,
                   shouldSoftRetry(status: status) {
                    lastStatus = status
                    SSHLogger.log(
                        "OpenCode health soft-retry \(attempt)/\(attempts) for server \(server.id): \(status.state)",
                        level: .warning
                    )
                    // Drop the pooled login so the next attempt opens a fresh session.
                    SSHService.shared.closeConnections(serverId: server.id, purpose: .opencode)
                    try? await Task.sleep(nanoseconds: healthRetryDelayNanoseconds)
                    continue
                }

                if status.isReady {
                    onOutput?("OpenCode \(status.version ?? "") is healthy.")
                } else {
                    onOutput?(status.message)
                }
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: server.id.uuidString,
                    operation: "opencode.probe.total",
                    elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - probeStart,
                    metadata: [
                        "attempt": .count(attempt),
                        "includeDaemon": .flag(includeDaemon),
                        "status": .status(status.blocksForegroundChat ? .failed : .complete)
                    ]
                )
                return status
            } catch {
                let status = OpenCodeRuntimeSetupStatus.sshUnavailable(error.localizedDescription)
                lastStatus = status
                ChatRecoveryTiming.log(
                    runtime: CodingAgentRuntimeKind.openCode.rawValue,
                    projectID: server.id.uuidString,
                    operation: "opencode.probe.ssh",
                    elapsedNanoseconds: 0,
                    metadata: [
                        "attempt": .count(attempt),
                        "status": .status(.failed)
                    ]
                )
                if attempt < attempts, Self.isTransientHealthFailure(error) {
                    SSHLogger.log(
                        "OpenCode SSH soft-retry \(attempt)/\(attempts) for server \(server.id): \(error.localizedDescription)",
                        level: .warning
                    )
                    SSHService.shared.closeConnections(serverId: server.id, purpose: .opencode)
                    try? await Task.sleep(nanoseconds: healthRetryDelayNanoseconds)
                    continue
                }
                onOutput?(status.message)
                return status
            }
        }

        let fallback = lastStatus ?? .unknown("OpenCode health check failed.")
        onOutput?(fallback.message)
        return fallback
    }

    private func shouldSoftRetry(status: OpenCodeRuntimeSetupStatus) -> Bool {
        switch status.state {
        case .unreachable, .unknown, .sshUnavailable:
            return true
        case .available, .authRequired, .notInstalled, .notRunning, .daemonUnavailable:
            return false
        }
    }

    private func checkRuntimeStatus(
        session: SSHSession,
        serverID: UUID,
        includeDaemon: Bool,
        allowDaemonInstall: Bool,
        onOutput: ((String) -> Void)? = nil
    ) async -> OpenCodeRuntimeSetupStatus {
        do {
            let health = try await OpenCodeClientFactory.client(for: serverID).health(session: session)
            guard health.healthy else {
                return .unknown("OpenCode server reported unhealthy.")
            }

            guard includeDaemon else {
                // Chat-ready path: OpenCode alone is enough. Daemon ensure runs in background.
                return .available(version: health.version)
            }

            onOutput?("Checking CodeAgents daemon health at \(CodeAgentsDaemonProvisioning.host):\(CodeAgentsDaemonProvisioning.port)...")
            let daemonOutcome = await CodeAgentsDaemonUpdateService.shared.ensureUpToDate(
                session: session,
                serverID: serverID,
                force: false,
                allowInstall: allowDaemonInstall,
                onOutput: onOutput
            )
            if case .failed(let reason) = daemonOutcome {
                return .daemonUnavailable(version: health.version, reason: reason)
            }
            if onOutput != nil {
                onOutput?("CodeAgents daemon is ready.")
            }
            return .available(version: health.version)
        } catch {
            // One in-session retry for transient direct-TCP blips before diagnostics.
            if Self.isTransientHealthFailure(error) {
                SSHLogger.log(
                    "OpenCode health probe transient failure; retrying on same session: \(error.localizedDescription)",
                    level: .warning
                )
                try? await Task.sleep(nanoseconds: healthRetryDelayNanoseconds)
                do {
                    let health = try await OpenCodeClientFactory.client(for: serverID).health(session: session)
                    guard health.healthy else {
                        return .unknown("OpenCode server reported unhealthy.")
                    }
                    guard includeDaemon else {
                        return .available(version: health.version)
                    }
                    let daemonOutcome = await CodeAgentsDaemonUpdateService.shared.ensureUpToDate(
                        session: session,
                        serverID: serverID,
                        force: false,
                        allowInstall: allowDaemonInstall,
                        onOutput: onOutput
                    )
                    if case .failed(let reason) = daemonOutcome {
                        return .daemonUnavailable(version: health.version, reason: reason)
                    }
                    return .available(version: health.version)
                } catch {
                    let diagnostics = (try? await session.execute(Self.diagnosticsCommand)) ?? ""
                    return Self.status(from: diagnostics, healthError: error)
                }
            }

            let diagnostics = (try? await session.execute(Self.diagnosticsCommand)) ?? ""
            return Self.status(from: diagnostics, healthError: error)
        }
    }

    private nonisolated static var diagnosticsCommand: String {
        """
        if [ -x \(OpenCodeServerProvisioning.binaryPath) ] || command -v opencode >/dev/null 2>&1; then echo binary=present; else echo binary=missing; fi
        if command -v systemctl >/dev/null 2>&1; then echo service=$(systemctl is-active opencode 2>/dev/null || true); else echo service=unknown; fi
        """
    }

    private nonisolated static func diagnosticValues(from diagnostics: String) -> [String: String] {
        diagnostics
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { values, line in
                let line = String(line)
                guard let separator = line.firstIndex(of: "=") else { return }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                values[key] = value
            }
    }
}

enum OpenCodeInstallerError: LocalizedError {
    case unhealthy
    case processFailed(String)
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unhealthy:
            return "OpenCode server reported unhealthy."
        case .processFailed(let reason):
            return "OpenCode installer process failed: \(reason)"
        case .setupFailed(let reason):
            return "OpenCode setup did not finish cleanly: \(reason)"
        }
    }
}
