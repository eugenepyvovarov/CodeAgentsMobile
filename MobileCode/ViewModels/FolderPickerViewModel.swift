//
//  FolderPickerViewModel.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-22.
//
//  Purpose: Manages folder selection for custom project paths
//  - Lists directories only (no files)
//  - Validates write permissions
//  - Navigates directory structure
//

import SwiftUI
import Observation

/// Represents a directory entry for folder picking
struct FolderEntry: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isWritable: Bool
    let isHidden: Bool
}

/// ViewModel for folder picker functionality
@MainActor
@Observable
class FolderPickerViewModel {
    // MARK: - Properties
    
    /// Current directory entries (folders only)
    var folders: [FolderEntry] = []
    
    /// Current directory path
    var currentPath: String
    
    /// Initial path when picker was opened
    let initialPath: String
    
    /// Loading state
    var isLoading = false
    
    /// Error message
    var errorMessage: String?
    
    /// Whether current directory is writable
    var isCurrentPathWritable = false
    
    /// SSH Service reference
    private let sshService = ServiceManager.shared.sshService
    
    /// Server to browse
    private let server: Server
    
    // MARK: - Initialization
    
    init(server: Server, initialPath: String) {
        self.server = server
        self.initialPath = initialPath
        self.currentPath = initialPath
    }
    
    // MARK: - Public Methods
    
    /// Load folders for current path
    func loadFolders() async {
        isLoading = true
        errorMessage = nil
        
        do {
            // Get SSH connection
            let session = try await sshService.connect(to: server)
            
            // Check if current path is writable
            let writeCheck = try await session.execute("test -w '\(currentPath)' && echo 'writable' || echo 'not writable'")
            isCurrentPathWritable = writeCheck.trimmingCharacters(in: .whitespaces) == "writable"
            
            // List all entries in current directory
            let remoteFiles = try await session.listDirectory(currentPath)
            
            // Filter to only directories and check permissions
            var folderEntries: [FolderEntry] = []
            
            for file in remoteFiles {
                // Skip non-directories and special entries
                if !file.isDirectory || file.name == "." || file.name == ".." {
                    continue
                }
                
                // Check if folder is writable
                let folderPath = PathUtils.join(currentPath, file.name)
                let folderWriteCheck = try await session.execute("test -w '\(folderPath)' && echo 'writable' || echo 'not writable'")
                let isWritable = folderWriteCheck.trimmingCharacters(in: .whitespaces) == "writable"
                
                let entry = FolderEntry(
                    name: file.name,
                    path: folderPath,
                    isWritable: isWritable,
                    isHidden: file.name.hasPrefix(".")
                )
                
                // Only include non-hidden directories
                if !entry.isHidden {
                    folderEntries.append(entry)
                }
            }
            
            // Sort folders alphabetically
            folders = folderEntries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
        } catch {
            errorMessage = "Failed to load folders: \(error.localizedDescription)"
            SSHLogger.log("Failed to load folders: \(error)", level: .error)
        }
        
        isLoading = false
    }
    
    /// Navigate to a specific folder
    /// - Parameter path: The folder path to navigate to
    func navigateTo(path: String) {
        currentPath = path
        Task {
            await loadFolders()
        }
    }
    
    /// Navigate to parent directory
    func navigateUp() {
        // Don't go above root
        guard currentPath != "/" else { return }
        
        // Get parent directory by removing last component
        let components = currentPath.split(separator: "/").map(String.init)
        let parentPath: String
        if components.count > 1 {
            parentPath = "/" + components.dropLast().joined(separator: "/")
        } else {
            parentPath = "/"
        }
        
        navigateTo(path: parentPath)
    }
    
    /// Get breadcrumb components for current path
    var pathComponents: [(name: String, path: String)] {
        let components = currentPath.split(separator: "/").map(String.init)
        var result: [(name: String, path: String)] = []
        var currentBuildPath = ""
        
        // Add root
        result.append((name: "/", path: "/"))
        
        // Add each component
        for component in components {
            currentBuildPath += "/\(component)"
            result.append((name: component, path: currentBuildPath))
        }
        
        return result
    }
    
    /// Check if a path can be selected
    /// - Parameter path: The path to check
    /// - Returns: true if the path is writable and can be selected
    func canSelectPath(_ path: String) -> Bool {
        return isCurrentPathWritable
    }
}