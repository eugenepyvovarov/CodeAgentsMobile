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
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @StateObject private var deepLinkManager = DeepLinkManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deepLinkManager)
        }
        .modelContainer(sharedModelContainer)
        .onOpenURL { url in
            deepLinkManager.handle(url: url)
        }
    }
}
