//
//  ServiceManager.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Central manager for all services
//  - Provides singleton access to services
//  - Manages service lifecycle
//  - Handles dependency injection
//

import Foundation

/// Central service manager
/// Provides access to all app services
class ServiceManager {
    // MARK: - Singleton
    
    /// Shared instance
    static let shared = ServiceManager()
    
    // MARK: - Services
    
    /// SSH connection service
    let sshService: SSHService
    
    /// Claude Code service (will be implemented next)
    // let claudeService: ClaudeCodeService
    
    // MARK: - Initialization
    
    private init() {
        // Initialize services
        self.sshService = SSHService()
        
        print("🚀 ServiceManager: Initialized")
    }
    
    // MARK: - Methods
    
    /// Reset all services (useful for logout)
    func resetServices() {
        // Disconnect all SSH sessions
        Task {
            // Will implement when we have proper session tracking
            print("🔄 ServiceManager: Services reset")
        }
    }
}