//
//  TaskSyncReporter.swift
//  CodeAgentsMobile
//
//  Purpose: Share proxy task sync status across views
//

import SwiftUI

enum TaskSyncState: Equatable {
    case idle
    case syncing
    case error(String)
}

final class TaskSyncReporter: ObservableObject {
    @Published var state: TaskSyncState = .idle
    @Published var lastSuccess: Date?

    func markSyncing() {
        state = .syncing
    }

    func markSuccess() {
        lastSuccess = Date()
        state = .idle
    }

    func markError(_ message: String) {
        state = .error(message)
    }
}
