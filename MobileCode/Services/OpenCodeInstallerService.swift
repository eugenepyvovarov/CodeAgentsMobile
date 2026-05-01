//
//  OpenCodeInstallerService.swift
//  CodeAgentsMobile
//
//  Purpose: Verify OpenCode runtime setup on managed servers.
//

import Foundation

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
}

enum OpenCodeInstallerError: LocalizedError {
    case unhealthy

    var errorDescription: String? {
        switch self {
        case .unhealthy:
            return "OpenCode server reported unhealthy."
        }
    }
}
