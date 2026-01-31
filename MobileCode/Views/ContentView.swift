//
//  ContentView.swift
//  CodeAgentsMobile
//
//  Created by Eugene Pyvovarov on 2025-06-10.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var navigationState = AppNavigationState.shared
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var cloudInitMonitor = CloudInitMonitor.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        Group {
            if projectContext.activeProject == nil {
                // Show projects list when no project is active
                ProjectsView()
                    .onAppear {
                        configureManagers()
                    }
            } else {
                // Show tabs when a project is active
                TabView(selection: $navigationState.selectedTab) {
                    ChatView()
                        .tabItem {
                            Label("Chat", systemImage: "message")
                        }
                        .tag(AppTab.chat)
                    
                    FileBrowserView()
                        .tabItem {
                            Label("Files", systemImage: "doc.text")
                        }
                        .tag(AppTab.files)
                    
                    RegularTasksView()
                        .tabItem {
                            Label("Regular Tasks", systemImage: "clock.badge.checkmark")
                        }
                        .tag(AppTab.tasks)
                }
                .onAppear {
                    configureManagers()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // App became active - start monitoring
                startCloudInitMonitoring()
                Task { await PushNotificationsManager.shared.syncDeliveredReplyFinishedNotifications() }
            case .inactive, .background:
                // App went to background - stop monitoring to save resources
                cloudInitMonitor.stopAllMonitoring()
            @unknown default:
                break
            }
        }
    }
    
    private func configureManagers() {
        // Load servers for ServerManager
        serverManager.loadServers(from: modelContext)
        // Start cloud-init monitoring for servers that need it
        startCloudInitMonitoring()
        ShortcutSyncService.shared.sync(using: modelContext)
    }
    
    private func startCloudInitMonitoring() {
        cloudInitMonitor.startMonitoring(modelContext: modelContext)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [RemoteProject.self, Server.self], inMemory: true)
}
