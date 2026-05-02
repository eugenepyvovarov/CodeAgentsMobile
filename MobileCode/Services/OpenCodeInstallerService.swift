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

final class OpenCodeInstallerService {
    static let shared = OpenCodeInstallerService()

    private init() {}

    func verifyRuntime(on server: Server, onOutput: @escaping (String) -> Void) async throws {
        let session = try await SSHService.shared.connect(to: server, purpose: .opencode)
        defer {
            session.disconnect()
        }

        onOutput("Checking OpenCode health at \(OpenCodeServerProvisioning.host):\(OpenCodeServerProvisioning.port)...")
        let health = try await OpenCodeClientFactory.client(for: server.id).health(session: session)

        guard health.healthy else {
            throw OpenCodeInstallerError.unhealthy
        }

        onOutput("OpenCode \(health.version) is healthy.")
    }

    func checkRuntimeStatus(on server: Server) async -> OpenCodeRuntimeSetupStatus {
        do {
            let session = try await SSHService.shared.connect(to: server, purpose: .opencode)
            defer {
                session.disconnect()
            }

            return await checkRuntimeStatus(session: session, serverID: server.id)
        } catch {
            return .sshUnavailable(error.localizedDescription)
        }
    }

    func installOrRepairRuntime(
        on server: Server,
        username: String,
        password: String?,
        onOutput: @escaping (String) -> Void
    ) async throws -> OpenCodeRuntimeSetupStatus {
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

        let status = await checkRuntimeStatus(session: session, serverID: server.id)
        guard status.isReady else {
            throw OpenCodeInstallerError.setupFailed(status.message)
        }
        return status
    }

    static func status(from diagnostics: String, healthError: Error) -> OpenCodeRuntimeSetupStatus {
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

    private func checkRuntimeStatus(session: SSHSession, serverID: UUID) async -> OpenCodeRuntimeSetupStatus {
        do {
            let health = try await OpenCodeClientFactory.client(for: serverID).health(session: session)
            guard health.healthy else {
                return .unknown("OpenCode server reported unhealthy.")
            }
            return .available(version: health.version)
        } catch {
            let diagnostics = (try? await session.execute(Self.diagnosticsCommand)) ?? ""
            return Self.status(from: diagnostics, healthError: error)
        }
    }

    private static var diagnosticsCommand: String {
        """
        if [ -x \(OpenCodeServerProvisioning.binaryPath) ] || command -v opencode >/dev/null 2>&1; then echo binary=present; else echo binary=missing; fi
        if command -v systemctl >/dev/null 2>&1; then echo service=$(systemctl is-active opencode 2>/dev/null || true); else echo service=unknown; fi
        """
    }

    private static func diagnosticValues(from diagnostics: String) -> [String: String] {
        diagnostics
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { values, line in
                let line = String(line)
                guard let separator = line.firstIndex(of: "=") else { return }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
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
