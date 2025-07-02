//
//  FileBrowserViewModel.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Manages file browser state and navigation
//  - Handles file tree structure
//  - Manages current path navigation
//  - Will integrate with SSH service for real file access
//

import SwiftUI
import Observation

/// ViewModel for file browser functionality
/// Integrates with SSH for real file access
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
    
    /// Recent files for quick access
    var recentFiles: [FileNode] = []
    
    /// SSH Service reference
    private let sshService = ServiceManager.shared.sshService
    
    // MARK: - Initialization
    
    init() {
        // Project path will be set when view appears
    }
    
    /// Setup project path from active project
    func setupProjectPath() {
        Task { @MainActor in
            if let projectPath = ProjectContext.shared.activeProjectPath {
                projectRootPath = projectPath
                currentPath = projectPath
            }
        }
    }
    
    // MARK: - Methods
    
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
    
    /// Refresh current directory
    func refresh() async {
        await loadRemoteFiles()
    }
    
    /// Load files from remote server
    func loadRemoteFiles() async {
        // Ensure project path is set
        if projectRootPath.isEmpty {
            await MainActor.run {
                if let projectPath = ProjectContext.shared.activeProjectPath {
                    projectRootPath = projectPath
                    currentPath = projectPath
                }
            }
        }
        
        let server = await ConnectionManager.shared.activeServer
        guard let server = server else {
            // Not connected, clear data
            await MainActor.run {
                rootNodes = []
                isLoading = false
            }
            return
        }
        
        await MainActor.run {
            isLoading = true
        }
        
        do {
            // Get or create SSH session
            let session = try await sshService.connect(to: server)
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
            
            await MainActor.run {
                self.rootNodes = nodes
                self.isLoading = false
            }
            
        } catch {
            print("Failed to load remote files: \(error)")
            await MainActor.run {
                // Show error but keep existing data
                self.isLoading = false
            }
        }
    }
    
    /// Create a new file in current directory
    /// - Parameter name: Name of the file
    func createFile(name: String) async {
        guard let server = await ConnectionManager.shared.activeServer else { return }
        
        do {
            let session = try await sshService.connect(to: server)
            let filePath = currentPath.hasSuffix("/") ? "\(currentPath)\(name)" : "\(currentPath)/\(name)"
            
            // Create empty file using touch command
            _ = try await session.execute("touch \(filePath)")
            
            // Refresh file list
            await loadRemoteFiles()
        } catch {
            print("Failed to create file: \(error)")
        }
    }
    
    /// Create a new folder in current directory
    /// - Parameter name: Name of the folder
    func createFolder(name: String) async {
        guard let server = await ConnectionManager.shared.activeServer else { return }
        
        do {
            let session = try await sshService.connect(to: server)
            let folderPath = currentPath.hasSuffix("/") ? "\(currentPath)\(name)" : "\(currentPath)/\(name)"
            
            // Create directory
            _ = try await session.execute("mkdir -p \(folderPath)")
            
            // Refresh file list
            await loadRemoteFiles()
        } catch {
            print("Failed to create folder: \(error)")
        }
    }
    
    /// Delete a file or folder
    /// - Parameter node: The file node to delete
    func deleteNode(_ node: FileNode) async {
        guard let server = await ConnectionManager.shared.activeServer else { return }
        
        do {
            let session = try await sshService.connect(to: server)
            
            // Use rm -rf for directories, rm for files
            let command = node.isDirectory ? "rm -rf \(node.path)" : "rm \(node.path)"
            _ = try await session.execute(command)
            
            // Refresh file list
            await loadRemoteFiles()
        } catch {
            print("Failed to delete node: \(error)")
        }
    }
    
    /// Open a file for viewing/editing
    /// - Parameter file: The file to open
    func openFile(_ file: FileNode) {
        if !file.isDirectory {
            selectedFile = file
            
            // Add to recent files
            recentFiles.removeAll { $0.id == file.id }
            recentFiles.insert(file, at: 0)
            
            // Keep only last 10 recent files
            if recentFiles.count > 10 {
                recentFiles = Array(recentFiles.prefix(10))
            }
        }
    }
    
    /// Rename a file or folder
    /// - Parameters:
    ///   - node: The file node to rename
    ///   - newName: The new name
    func renameNode(_ node: FileNode, to newName: String) async {
        guard let server = await ConnectionManager.shared.activeServer else { return }
        
        do {
            let session = try await sshService.connect(to: server)
            
            // Get parent directory path
            let parentPath = (node.path as NSString).deletingLastPathComponent
            let newPath = (parentPath as NSString).appendingPathComponent(newName)
            
            // Use mv command to rename
            _ = try await session.execute("mv '\(node.path)' '\(newPath)'")
            
            // Refresh file list
            await loadRemoteFiles()
        } catch {
            print("Failed to rename node: \(error)")
        }
    }
    
    /// Upload file content to server
    /// - Parameters:
    ///   - fileName: Name for the new file
    ///   - content: File content data
    func uploadFile(name fileName: String, content: Data) async {
        guard let server = await ConnectionManager.shared.activeServer else { return }
        
        do {
            let session = try await sshService.connect(to: server)
            let filePath = currentPath.hasSuffix("/") ? "\(currentPath)\(fileName)" : "\(currentPath)/\(fileName)"
            
            // Write file content using echo and base64 encoding for binary safety
            if let contentString = String(data: content, encoding: .utf8) {
                // For text files, write directly
                let escapedContent = contentString.replacingOccurrences(of: "'", with: "'\"'\"'")
                _ = try await session.execute("echo '\(escapedContent)' > '\(filePath)'")
            } else {
                // For binary files, use base64 encoding
                let base64Content = content.base64EncodedString()
                _ = try await session.execute("echo '\(base64Content)' | base64 -d > '\(filePath)'")
            }
            
            // Refresh file list
            await loadRemoteFiles()
        } catch {
            print("Failed to upload file: \(error)")
        }
    }
    
    /// Get relative path from project root
    /// - Parameter fullPath: The full path
    /// - Returns: Path relative to project root
    func getRelativePath(from fullPath: String) -> String {
        if fullPath == projectRootPath {
            return "/"
        } else if fullPath.hasPrefix(projectRootPath + "/") {
            let relativePath = String(fullPath.dropFirst(projectRootPath.count))
            return relativePath
        }
        return fullPath
    }
    
}