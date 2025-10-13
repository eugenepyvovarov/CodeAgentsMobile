//
//  CodeAgentsShortcutsProvider.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2025-07-06.
//

import AppIntents

struct CodeAgentsShortcutsProvider: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue
    
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunCodeAgentsTaskIntent(),
            phrases: [
                "Run CodeAgents task in \(.applicationName)"
            ],
            shortTitle: "Run Task",
            systemImageName: "bolt.fill"
        )
        
        AppShortcut(
            intent: RunCodeAgentsTaskIntent(prompt: "Summarize yesterday's deploys and blockers."),
            phrases: [
                "Daily CodeAgents update in \(.applicationName)"
            ],
            shortTitle: "Daily Update",
            systemImageName: "sun.max"
        )
        
        AppShortcut(
            intent: ListCodeAgentsProjectsIntent(),
            phrases: [
                "List CodeAgents projects in \(.applicationName)",
                "Show CodeAgents projects in \(.applicationName)"
            ],
            shortTitle: "List Projects",
            systemImageName: "list.bullet.rectangle"
        )
    }
}
