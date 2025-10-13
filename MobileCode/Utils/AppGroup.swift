//
//  AppGroup.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2025-07-06.
//

import Foundation

/// Central place to manage identifiers shared with extensions and Shortcuts
enum AppGroup {
    /// Update this identifier when configuring the App Group capability
    static let identifier = "group.com.codeagents.mobile"
    
    /// User defaults scoped to the shared app group when available.
    static var sharedDefaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: identifier) else {
            assertionFailure("Failed to access app group defaults – falling back to standard defaults.")
            return UserDefaults.standard
        }
        return defaults
    }
    
    /// Convenience accessor for the shared container URL if App Group is configured.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
    
    /// Shared SwiftData store URL used by the main app and extensions.
    static var storeURL: URL {
        if let containerURL {
            return containerURL.appendingPathComponent("CodeAgents.sqlite")
        } else {
            // Fallback to application documents directory if app group is misconfigured.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            return documents.appendingPathComponent("CodeAgents.sqlite")
        }
    }
}
