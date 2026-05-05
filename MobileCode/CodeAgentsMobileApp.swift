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
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer = {
        let schema = CodeAgentsSwiftDataSchema.schema
        if CodeAgentsMobileApp.isRunningUITests {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Could not create UI test ModelContainer: \(error)")
            }
        }

        SwiftDataStoreMigrator.migrateIfNeeded(schema: schema, destinationURL: AppGroup.storeURL)
        let configuration = ModelConfiguration(schema: schema, url: AppGroup.storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        FirebaseBootstrap.configureIfNeeded()

        if Self.shouldResetUITestDefaults,
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }

        PushNotificationsManager.shared.configure(modelContainer: sharedModelContainer)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }

    private static var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    private static var shouldResetUITestDefaults: Bool {
        ProcessInfo.processInfo.arguments.contains("--reset-ui-test-defaults")
    }
}
