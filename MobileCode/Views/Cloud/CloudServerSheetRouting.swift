//
//  CloudServerSheetRouting.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2026-05-04.
//

import Foundation

struct CloudServerProviderRoute: Identifiable, Equatable {
    let providerID: UUID

    var id: UUID { providerID }
}

struct CloudProviderSelectionState: Equatable {
    var selectedProviderID: UUID?
    var serverListRoute: CloudServerProviderRoute?

    var canPresentServerList: Bool {
        selectedProviderID != nil
    }

    mutating func selectProvider(id: UUID) {
        selectedProviderID = id
    }

    mutating func presentSelectedProvider() {
        guard let selectedProviderID else { return }
        serverListRoute = CloudServerProviderRoute(providerID: selectedProviderID)
    }

    mutating func dismissServerList() {
        serverListRoute = nil
    }
}

struct CloudServerProjectCreationRoute: Identifiable, Equatable {
    let serverID: UUID

    var id: UUID { serverID }

    static func route(for serverID: UUID?) -> CloudServerProjectCreationRoute? {
        guard let serverID else { return nil }
        return CloudServerProjectCreationRoute(serverID: serverID)
    }
}
