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
    @Environment(\.modelContext) private var modelContext
    
    enum Tab {
        case chat
        case files
        case terminal
    }
    
    var body: some View {
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
    
    private func configureManagers() {
        // Load servers for ServerManager
        serverManager.loadServers(from: modelContext)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [RemoteProject.self, Server.self], inMemory: true)
}
