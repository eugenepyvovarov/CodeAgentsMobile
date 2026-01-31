//
//  CodeAgentsMobileApp.swift
//  CodeAgentsMobile
//
//  Created by Eugene Pyvovarov on 2025-06-10.
//

import SwiftUI
import SwiftData
import FirebaseCore

@main
struct CodeAgentsMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer = {
        let schema = CodeAgentsSwiftDataSchema.schema
        SwiftDataStoreMigrator.migrateIfNeeded(schema: schema, destinationURL: AppGroup.storeURL)
        let configuration = ModelConfiguration(schema: schema, url: AppGroup.storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        if FirebaseApp.app() == nil {
            if let options = FirebaseOptions.defaultOptions() {
                FirebaseApp.configure(options: options)
            } else {
                NSLog("Firebase not configured: missing GoogleService-Info.plist")
            }
        }
        PushNotificationsManager.shared.configure(modelContainer: sharedModelContainer)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
