//
//  FileBrowserViewModel.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Manages file browser state and navigation
//  - Handles file tree structure
//  - Manages current path navigation
//  - Provides basic file operations
//

import SwiftUI
import Observation

/// ViewModel for file browser functionality
@MainActor
@Observable
class FileBrowserViewModel {
    // MARK: - Properties
    
    /// Root nodes of the file tree
    var rootNodes: [FileNode] = []
    
    /// Current directory path
    var currentPath: String = ""
    
    /// Root path of the current project
    var projectRootPath: String = ""
    
    /// Currently selected file for viewing/editing
    var selectedFile: FileNode?
    
    /// Loading state
    var isLoading = false
    
    /// SSH Service reference
    private let sshService = ServiceManager.shared.sshService
    
    /// Current project reference
    private var currentProject: RemoteProject?
    
    // MARK: - Public Methods
    
    /// Initialize file browser for a project
    /// - Parameter project: The project to browse
    func initializeForProject(_ project: RemoteProject) {
        Task { @MainActor in
            currentProject = project
            projectRootPath = project.path
            currentPath = project.path
            await loadRemoteFiles()
        }
    }
    
    /// Navigate to a specific path
    /// - Parameter path: The path to navigate to
    func navigateTo(path: String) {
        // Ensure we don't navigate above project root
        if path.hasPrefix(projectRootPath) || path == projectRootPath {
            currentPath = path
            Task {
                await loadRemoteFiles()
            }
        }
    }
    
    /// Load files from remote server
    func loadRemoteFiles() async {
        guard let project = currentProject else { return }
        
        isLoading = true
        
        do {
            // Get SSH connection for file operations
            let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
            let remoteFiles = try await session.listDirectory(currentPath)
            
            // Convert to FileNode structure
            let nodes = remoteFiles.compactMap { remoteFile -> FileNode? in
                // Skip . and .. entries
                if remoteFile.name == "." || remoteFile.name == ".." {
                    return nil
                }
                
                return FileNode(
                    name: remoteFile.name,
                    path: remoteFile.path,
                    isDirectory: remoteFile.isDirectory,
                    children: remoteFile.isDirectory ? [] : nil,
                    fileSize: remoteFile.size,
                    modificationDate: remoteFile.modificationDate
                )
            }
            .sorted { $0.name < $1.name }
            
            rootNodes = nodes
            
        } catch {
            print("Failed to load remote files: \(error)")
        }
        
        isLoading = false
    }
    
    /// Open a file for viewing
    /// - Parameter file: The file to open
    func openFile(_ file: FileNode) {
        if !file.isDirectory {
            selectedFile = file
        }
    }
    
    /// Create a new folder in current directory
    /// - Parameter name: Name of the folder
    func createFolder(name: String) async {
        let folderPath = currentPath.hasSuffix("/") ? "\(currentPath)\(name)" : "\(currentPath)/\(name)"
        
        do {
            try await executeCommand("mkdir -p '\(folderPath)'")
            await loadRemoteFiles()
        } catch {
            print("Failed to create folder: \(error)")
        }
    }
    
    /// Delete a file or folder
    /// - Parameter node: The file node to delete
    func deleteNode(_ node: FileNode) async {
        let command = node.isDirectory ? "rm -rf '\(node.path)'" : "rm '\(node.path)'"
        
        do {
            try await executeCommand(command)
            await loadRemoteFiles()
        } catch {
            print("Failed to delete node: \(error)")
        }
    }
    
    /// Rename a file or folder
    /// - Parameters:
    ///   - node: The file node to rename
    ///   - newName: The new name
    func renameNode(_ node: FileNode, to newName: String) async {
        let parentPath = (node.path as NSString).deletingLastPathComponent
        let newPath = (parentPath as NSString).appendingPathComponent(newName)
        
        do {
            try await executeCommand("mv '\(node.path)' '\(newPath)'")
            await loadRemoteFiles()
        } catch {
            print("Failed to rename node: \(error)")
        }
    }
    
    /// Setup project path from ProjectContext
    func setupProjectPath() {
        if let project = ProjectContext.shared.activeProject {
            currentProject = project
            projectRootPath = project.path
            currentPath = project.path
        }
    }
    
    /// Get relative path from project root
    func getRelativePath(from path: String) -> String {
        if path.hasPrefix(projectRootPath) {
            return String(path.dropFirst(projectRootPath.count))
        }
        return ""
    }
    
    /// Refresh current directory
    func refresh() async {
        await loadRemoteFiles()
    }
    
    /// Load file content
    func loadFileContent(path: String) async throws -> String {
        guard let project = currentProject else {
            throw FileBrowserError.noProject
        }
        
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        return try await session.readFile(path)
    }
    
    // MARK: - Private Methods
    
    /// Execute SSH command
    private func executeCommand(_ command: String) async throws {
        guard let project = currentProject else {
            throw FileBrowserError.noProject
        }
        
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        _ = try await session.execute(command)
    }
}

// MARK: - Errors

enum FileBrowserError: LocalizedError {
    case noProject
    
    var errorDescription: String? {
        switch self {
        case .noProject:
            return "No active project"
        }
    }
}