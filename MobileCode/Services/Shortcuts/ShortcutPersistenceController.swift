//
//  ShortcutPersistenceController.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2025-10-11.
//

import Foundation
import SwiftData

/// Provides a shared SwiftData model container for App Intents / Shortcuts usage.
final class ShortcutPersistenceController {
    static let shared = ShortcutPersistenceController()
    
    let container: ModelContainer
    
    private init() {
        let schema = Schema([
            RemoteProject.self,
            Server.self,
            Message.self,
            SSHKey.self,
            ServerProvider.self
        ])
        SwiftDataStoreMigrator.migrateIfNeeded(schema: schema, destinationURL: AppGroup.storeURL)
        let configuration = ModelConfiguration(schema: schema, url: AppGroup.storeURL)

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create shared model container: \(error)")
        }
    }
    
    /// Creates a fresh model context scoped to the shared container.
    @MainActor
    func makeContext() -> ModelContext {
        ModelContext(container)
    }
}
