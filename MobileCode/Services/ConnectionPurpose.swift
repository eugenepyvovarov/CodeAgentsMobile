//
//  ConnectionPurpose.swift
//  CodeAgentsMobile
//
//  Purpose: Defines the different purposes for SSH connections
//

import Foundation

/// Defines the purpose of an SSH connection to enable connection pooling
enum ConnectionPurpose: String, CaseIterable {
    case claude = "claude"
    case terminal = "terminal"
    case fileOperations = "files"
    
    var description: String {
        switch self {
        case .claude:
            return "Claude Code"
        case .terminal:
            return "Terminal"
        case .fileOperations:
            return "File Operations"
        }
    }
}