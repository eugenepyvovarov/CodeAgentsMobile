//
//  CloudServerAttachmentConfiguration.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2026-05-04.
//

import Foundation

struct OpenCodeServerAuthConfiguration: Equatable {
    var isEnabled = false
    var username = OpenCodeServerProvisioning.username
    var password = ""

    var sanitizedUsername: String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? OpenCodeServerProvisioning.username : trimmed
    }

    var canSave: Bool {
        !isEnabled || !password.isEmpty
    }

    var credentials: OpenCodeServerCredentials? {
        guard isEnabled, !password.isEmpty else { return nil }
        return OpenCodeServerCredentials(username: sanitizedUsername, password: password)
    }
}

struct OpenCodeServerCredentials: Equatable {
    let username: String
    let password: String
}

enum CloudServerAttachmentConfiguration {
    static func makeAttachedServer(
        cloudServer: CloudServer,
        provider: ServerProvider,
        displayName: String,
        username: String,
        authMethodType: String,
        sshKeyId: UUID?,
        now: Date = Date()
    ) -> Server {
        let server = Server(
            name: displayName.isEmpty ? cloudServer.name : displayName,
            host: cloudServer.publicIP ?? "",
            port: 22,
            username: username,
            authMethodType: authMethodType
        )

        server.sshKeyId = sshKeyId
        server.providerId = provider.id
        server.providerServerId = cloudServer.id
        server.cloudInitComplete = true
        server.cloudInitStatus = "done"
        server.cloudInitLastChecked = now

        return server
    }
}
