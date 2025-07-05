//
//  FileBrowserView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI

struct FileBrowserView: View {
    @State private var viewModel = FileBrowserViewModel()
    @State private var showingNewFolderDialog = false
    @State private var newItemName = ""
    @State private var selectedNodeForAction: FileNode?
    @State private var showingRenameDialog = false
    @State private var showingDeleteConfirmation = false
    @StateObject private var projectContext = ProjectContext.shared
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                breadcrumbView
                
                Divider()
                
                fileListView
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusView()
                }
                ToolbarItem(placement: .primaryAction) {
                    fileMenuButton
                }
            }
            .task {
                viewModel.setupProjectPath()
                await viewModel.loadRemoteFiles()
            }
        }
        .sheet(item: $viewModel.selectedFile) { file in
            if !file.isDirectory {
                CodeViewerSheet(file: file, viewModel: viewModel)
            }
        }
        .alert("New Folder", isPresented: $showingNewFolderDialog) {
            TextField("Folder name", text: $newItemName)
            Button("Cancel", role: .cancel) {
                newItemName = ""
            }
            Button("Create") {
                Task {
                    await viewModel.createFolder(name: newItemName)
                    newItemName = ""
                }
            }
        }
        .alert("Rename", isPresented: $showingRenameDialog) {
            TextField("New name", text: $newItemName)
            Button("Cancel", role: .cancel) {
                newItemName = ""
                selectedNodeForAction = nil
            }
            Button("Rename") {
                if let node = selectedNodeForAction {
                    Task {
                        await viewModel.renameNode(node, to: newItemName)
                        newItemName = ""
                        selectedNodeForAction = nil
                    }
                }
            }
        }
        .alert("Delete \(selectedNodeForAction?.name ?? "")?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                selectedNodeForAction = nil
            }
            Button("Delete", role: .destructive) {
                if let node = selectedNodeForAction {
                    Task {
                        await viewModel.deleteNode(node)
                        selectedNodeForAction = nil
                    }
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }
    
    @ViewBuilder
    private var breadcrumbView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(pathComponents, id: \.path) { component in
                    breadcrumbItem(for: component)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGray6))
    }
    
    @ViewBuilder
    private func breadcrumbItem(for component: (name: String, path: String)) -> some View {
        HStack(spacing: 4) {
            Button {
                navigateToPath(component.path)
            } label: {
                Text(component.name)
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            if component.path != pathComponents.last?.path {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private var fileListView: some View {
        List {
            ForEach(filteredNodes) { node in
                FileRow(
                    node: node,
                    selectedFile: $viewModel.selectedFile,
                    onRename: { fileNode in
                        selectedNodeForAction = fileNode
                        newItemName = fileNode.name
                        showingRenameDialog = true
                    },
                    onDelete: { fileNode in
                        selectedNodeForAction = fileNode
                        showingDeleteConfirmation = true
                    },
                    onNavigate: { path in
                        viewModel.navigateTo(path: path)
                    }
                )
            }
        }
        .listStyle(.plain)
    }
    
    @ViewBuilder
    private var fileMenuButton: some View {
        Menu {
            Button {
                showingNewFolderDialog = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            
            Divider()
            
            Button {
                Task {
                    await viewModel.refresh()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "plus")
        }
    }
    
    private var pathComponents: [(name: String, path: String)] {
        // Get project name from active project
        let projectName = projectContext.activeProject?.name ?? "Project"
        
        // If we're at project root
        if viewModel.currentPath == viewModel.projectRootPath {
            return [(name: projectName, path: viewModel.projectRootPath)]
        }
        
        // Build path components from project root
        var result = [(name: projectName, path: viewModel.projectRootPath)]
        
        // Get relative path from project root
        let relativePath = viewModel.getRelativePath(from: viewModel.currentPath)
        if relativePath.hasPrefix("/") {
            let trimmedPath = String(relativePath.dropFirst())
            if !trimmedPath.isEmpty {
                let components = trimmedPath.split(separator: "/").map(String.init)
                var currentPath = viewModel.projectRootPath
                
                for component in components {
                    currentPath = (currentPath as NSString).appendingPathComponent(component)
                    result.append((name: component, path: currentPath))
                }
            }
        }
        
        return result
    }
    
    private var filteredNodes: [FileNode] {
        return viewModel.rootNodes
    }
    
    private func navigateToPath(_ path: String) {
        viewModel.navigateTo(path: path)
    }
}

struct FileRow: View {
    let node: FileNode
    @Binding var selectedFile: FileNode?
    let onRename: (FileNode) -> Void
    let onDelete: (FileNode) -> Void
    let onNavigate: (String) -> Void
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if node.isDirectory {
                    onNavigate(node.path)
                } else {
                    selectedFile = node
                }
            } label: {
                HStack {
                    Image(systemName: node.icon)
                        .font(.title3)
                        .foregroundColor(node.isDirectory ? .blue : .secondary)
                        .frame(width: 24)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                        
                        if let size = node.formattedSize, let date = node.modificationDate {
                            Text("\(size) • Modified \(date, style: .relative) ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    if node.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    onRename(node)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                
                Divider()
                
                Button(role: .destructive) {
                    onDelete(node)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

struct CodeViewerSheet: View {
    let file: FileNode
    let viewModel: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var content = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading file...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Failed to load file")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    ScrollView {
                        Text(content)
                            .font(.custom("SF Mono", size: 14))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(.systemGray6))
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                    
                    if !isLoading && errorMessage == nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                isEditing.toggle()
                            } label: {
                                Image(systemName: isEditing ? "checkmark" : "pencil")
                            }
                        }
                    }
                }
        }
        .task {
            await loadFileContent()
        }
    }
    
    private func loadFileContent() async {
        isLoading = true
        errorMessage = nil
        
        do {
            content = try await viewModel.loadFileContent(path: file.path)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

#Preview {
    FileBrowserView()
}