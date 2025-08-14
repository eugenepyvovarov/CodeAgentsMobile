//
//  ContentView.swift
//  CodeAgentsMobile
//
//  Created by Eugene Pyvovarov on 2025-06-10.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = Tab.chat
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var cloudInitMonitor = CloudInitMonitor.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    
    enum Tab {
        case chat
        case files
        case terminal
    }
    
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
                TabView(selection: $selectedTab) {
                    ChatView()
                        .tabItem {
                            Label("Chat", systemImage: "message")
                        }
                        .tag(Tab.chat)
                    
                    FileBrowserView()
                        .tabItem {
                            Label("Files", systemImage: "doc.text")
                        }
                        .tag(Tab.files)
                    
                    TerminalView()
                        .tabItem {
                            Label("Terminal", systemImage: "terminal")
                        }
                        .tag(Tab.terminal)
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
    }
    
    private func startCloudInitMonitoring() {
        cloudInitMonitor.startMonitoring(modelContext: modelContext)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [RemoteProject.self, Server.self], inMemory: true)
}
