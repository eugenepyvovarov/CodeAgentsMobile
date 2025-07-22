//
//  FolderPickerView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-22.
//
//  Purpose: UI for selecting custom project folders
//  - Shows directory structure
//  - Validates permissions
//  - Provides navigation
//

import SwiftUI

struct FolderPickerView: View {
    let server: Server
    let initialPath: String
    let onSelect: (String) -> Void
    
    @State private var viewModel: FolderPickerViewModel
    @Environment(\.dismiss) private var dismiss
    
    init(server: Server, initialPath: String, onSelect: @escaping (String) -> Void) {
        self.server = server
        self.initialPath = initialPath
        self.onSelect = onSelect
        
        // Create view model with the provided server and path
        self._viewModel = State(initialValue: FolderPickerViewModel(server: server, initialPath: initialPath))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Breadcrumb navigation
                breadcrumbView
                
                Divider()
                
                // Current path display
                currentPathView
                
                Divider()
                
                // Folder list
                if viewModel.isLoading {
                    Spacer()
                    ProgressView("Loading folders...")
                    Spacer()
                } else if let error = viewModel.errorMessage {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            Task {
                                await viewModel.loadFolders()
                            }
                        }
                    }
                    .padding()
                    Spacer()
                } else {
                    folderListView
                }
            }
            .navigationTitle("Select Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select") {
                        onSelect(viewModel.currentPath)
                        dismiss()
                    }
                    .disabled(!viewModel.isCurrentPathWritable)
                }
            }
            .task {
                await viewModel.loadFolders()
            }
        }
    }
    
    @ViewBuilder
    private var breadcrumbView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(viewModel.pathComponents, id: \.path) { component in
                    Button(action: {
                        viewModel.navigateTo(path: component.path)
                    }) {
                        HStack(spacing: 4) {
                            Text(component.name)
                                .font(.caption)
                                .fontDesign(.monospaced)
                            
                            if component.path != viewModel.currentPath {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(component.path == viewModel.currentPath)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
    
    @ViewBuilder
    private var currentPathView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Current Location")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isCurrentPathWritable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(viewModel.isCurrentPathWritable ? .green : .red)
                        .font(.caption)
                    
                    Text(viewModel.currentPath)
                        .font(.footnote)
                        .fontDesign(.monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer()
            
            if viewModel.currentPath != "/" {
                Button(action: {
                    viewModel.navigateUp()
                }) {
                    Label("Up", systemImage: "arrow.up.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color(.systemGray6))
    }
    
    @ViewBuilder
    private var folderListView: some View {
        if viewModel.folders.isEmpty {
            VStack {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No folders found")
                        .foregroundColor(.secondary)
                    
                    if !viewModel.isCurrentPathWritable {
                        Label("This folder is read-only", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                Spacer()
            }
        } else {
            List(viewModel.folders) { folder in
                FolderRow(folder: folder) {
                    viewModel.navigateTo(path: folder.path)
                }
            }
            .listStyle(.plain)
        }
    }
}

struct FolderRow: View {
    let folder: FolderEntry
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(folder.isWritable ? .blue : .gray)
                
                Text(folder.name)
                    .fontDesign(.monospaced)
                    .foregroundColor(folder.isWritable ? .primary : .secondary)
                
                Spacer()
                
                if !folder.isWritable {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Folder Picker") {
    FolderPickerView(
        server: Server(name: "Test Server", host: "example.com", username: "user"),
        initialPath: "/home/user/projects"
    ) { path in
        print("Selected path: \(path)")
    }
}