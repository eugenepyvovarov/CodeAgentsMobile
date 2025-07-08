//
//  PathUtils.swift
//  CodeAgentsMobile
//
//  Purpose: Utility functions for path manipulation
//  - Tilde expansion
//  - Path normalization
//

import Foundation

/// Utility functions for path manipulation
struct PathUtils {
    
    /// Expand tilde (~) in a path to the full home directory path
    /// - Parameters:
    ///   - path: Path that may contain ~
    ///   - homeDirectory: The user's home directory path
    /// - Returns: Expanded path with ~ replaced by home directory
    static func expandTilde(_ path: String, homeDirectory: String) -> String {
        guard path.hasPrefix("~") else {
            return path
        }
        
        // Handle just "~"
        if path == "~" {
            return homeDirectory
        }
        
        // Handle "~/..."
        if path.hasPrefix("~/") {
            let relativePath = String(path.dropFirst(2))
            return homeDirectory + "/" + relativePath
        }
        
        // For other cases like "~username", just return as-is
        // (not commonly used on mobile app servers)
        return path
    }
    
    /// Normalize a path by removing redundant slashes and resolving . and ..
    /// - Parameter path: Path to normalize
    /// - Returns: Normalized path
    static func normalize(_ path: String) -> String {
        // Split by "/" and filter out empty components
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        
        // Handle absolute paths
        let isAbsolute = path.hasPrefix("/")
        
        // Process . and ..
        var normalizedComponents: [String] = []
        for component in components {
            if component == "." {
                // Skip current directory references
                continue
            } else if component == ".." {
                // Go up one directory if possible
                if !normalizedComponents.isEmpty && normalizedComponents.last != ".." {
                    normalizedComponents.removeLast()
                } else if !isAbsolute {
                    // For relative paths, keep the ..
                    normalizedComponents.append(component)
                }
            } else {
                normalizedComponents.append(component)
            }
        }
        
        // Reconstruct the path
        var result = normalizedComponents.joined(separator: "/")
        if isAbsolute {
            result = "/" + result
        }
        
        // Ensure we don't return an empty string
        if result.isEmpty {
            result = isAbsolute ? "/" : "."
        }
        
        return result
    }
    
    /// Join path components safely
    /// - Parameter components: Path components to join
    /// - Returns: Joined path
    static func join(_ components: String...) -> String {
        return components.reduce("") { result, component in
            if result.isEmpty {
                return component
            }
            
            let resultEndsWithSlash = result.hasSuffix("/")
            let componentStartsWithSlash = component.hasPrefix("/")
            
            if resultEndsWithSlash && componentStartsWithSlash {
                // Remove duplicate slash
                return result + String(component.dropFirst())
            } else if !resultEndsWithSlash && !componentStartsWithSlash {
                // Add missing slash
                return result + "/" + component
            } else {
                // One slash present, just concatenate
                return result + component
            }
        }
    }
}