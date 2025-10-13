//
//  CodeAgentsMobileApp.swift
//  CodeAgentsMobile
//
//  Created by Eugene Pyvovarov on 2025-06-10.
//

import SwiftUI
import SwiftData

@main
struct CodeAgentsMobileApp: App {
    var sharedModelContainer: ModelContainer = {
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
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
