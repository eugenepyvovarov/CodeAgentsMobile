//
//  FileBrowserView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @State private var viewModel = FileBrowserViewModel()
    @State private var showingNewFolderDialog = false
    @State private var showingNewFileDialog = false
    @State private var newItemName = ""
    @State private var selectedNodeForAction: FileNode?
    @State private var showingRenameDialog = false
    @State private var showingDeleteConfirmation = false
    @State private var isPreparingShare = false
    @State private var shareCandidate: FileNode?
    @State private var showLargeFileShareWarning = false
    @State private var shareErrorMessage: String?
    @State private var showShareError = false
    @State private var showingUploadFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showingCameraPicker = false
    @State private var isUploadingFiles = false
    @State private var fileActionErrorMessage: String?
    @State private var showFileActionError = false
    @StateObject private var projectContext = ProjectContext.shared

    private let largeFileThreshold: Int64 = 250 * 1024 * 1024
    
    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    breadcrumbView
                    
                    Divider()
                    
                    fileListView
                }
                
                if isPreparingShare {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing share...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 10)
                } else if isUploadingFiles {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Uploading files...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 10)
                }
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
                FilePreviewSheet(file: file, viewModel: viewModel)
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
        .alert("New File", isPresented: $showingNewFileDialog) {
            TextField("File name", text: $newItemName)
            Button("Cancel", role: .cancel) {
                newItemName = ""
            }
            Button("Create") {
                Task {
                    do {
                        try await viewModel.createFile(name: newItemName)
                        newItemName = ""
                    } catch {
                        fileActionErrorMessage = error.localizedDescription
                        showFileActionError = true
                    }
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
        .alert("Large File", isPresented: $showLargeFileShareWarning) {
            Button("Cancel", role: .cancel) {
                shareCandidate = nil
            }
            Button("Continue") {
                if let candidate = shareCandidate {
                    Task { await shareFile(candidate) }
                }
            }
        } message: {
            Text(largeFileWarningMessage)
        }
        .alert("Share Failed", isPresented: $showShareError) {
            Button("OK") { }
        } message: {
            Text(shareErrorMessage ?? "Unable to share the file.")
        }
        .alert("Error", isPresented: $showFileActionError) {
            Button("OK") { }
        } message: {
            Text(fileActionErrorMessage ?? "Something went wrong.")
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $photoPickerItems,
            maxSelectionCount: 0,
            matching: .images
        )
        .onChange(of: photoPickerItems) { _, items in
            handlePhotoPickerSelection(items)
        }
        .sheet(isPresented: $showingCameraPicker) {
            CameraPicker(
                onImage: { image in
                    showingCameraPicker = false
                    handleCameraImage(image)
                },
                onCancel: {
                    showingCameraPicker = false
                },
                onError: { error in
                    showingCameraPicker = false
                    fileActionErrorMessage = error.localizedDescription
                    showFileActionError = true
                }
            )
        }
        .fileImporter(
            isPresented: $showingUploadFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                uploadLocalFiles(urls)
            case .failure(let error):
                fileActionErrorMessage = error.localizedDescription
                showFileActionError = true
            }
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
                    onShare: { fileNode in
                        requestShare(fileNode)
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

            Button {
                showingNewFileDialog = true
            } label: {
                Label("New File", systemImage: "doc.badge.plus")
            }

            Button {
                showingUploadFileImporter = true
            } label: {
                Label("Upload File", systemImage: "arrow.up.doc")
            }

            Button {
                showingPhotoPicker = true
            } label: {
                Label("Upload Photo", systemImage: "photo.on.rectangle")
            }

            Button {
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    fileActionErrorMessage = "Camera not available on this device."
                    showFileActionError = true
                    return
                }
                showingCameraPicker = true
            } label: {
                Label("Take Photo", systemImage: "camera")
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
        .disabled(projectContext.activeProject == nil || isUploadingFiles)
    }
    
    private var pathComponents: [(name: String, path: String)] {
        // Get project name from active project
        let projectName = projectContext.activeProject?.displayTitle ?? "Agent"
        
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

    private func requestShare(_ node: FileNode) {
        guard !node.isDirectory else { return }
        if shouldWarnForLargeFile(node) {
            shareCandidate = node
            showLargeFileShareWarning = true
        } else {
            Task { await shareFile(node) }
        }
    }

    private func shouldWarnForLargeFile(_ node: FileNode) -> Bool {
        guard let size = node.fileSize else { return false }
        return size >= largeFileThreshold
    }

    private var largeFileWarningMessage: String {
        guard let size = shareCandidate?.fileSize else {
            return "This file is large. Downloading may take a while."
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let formattedSize = formatter.string(fromByteCount: size)
        return "This file is \(formattedSize). Downloading may take a while."
    }

    private func shareFile(_ node: FileNode) async {
        isPreparingShare = true
        shareErrorMessage = nil

        do {
            let localURL = try await viewModel.downloadFile(node)
            ShareSheetPresenter.present(urls: [localURL]) {
                try? FileManager.default.removeItem(at: localURL)
            }
        } catch {
            shareErrorMessage = error.localizedDescription
            showShareError = true
        }

        isPreparingShare = false
        shareCandidate = nil
    }

    private func handlePhotoPickerSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        Task {
            var staged: [StagedImageAttachment] = []
            var firstError: Error?

            for item in items {
                do {
                    let result = try await ImageAttachmentStager.stagePhotoPickerItem(
                        item,
                        directoryName: "file-browser-uploads"
                    )
                    staged.append(result)
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            await MainActor.run {
                photoPickerItems = []
            }

            if !staged.isEmpty {
                await MainActor.run {
                    uploadStagedImages(staged)
                }
            }

            if let firstError {
                await MainActor.run {
                    fileActionErrorMessage = firstError.localizedDescription
                    showFileActionError = true
                }
            }
        }
    }

    private func handleCameraImage(_ image: UIImage) {
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try ImageAttachmentStager.stageImage(
                        from: image,
                        preferredName: nil,
                        directoryName: "file-browser-uploads"
                    )
                }.value

                await MainActor.run {
                    uploadStagedImages([staged])
                }
            } catch {
                await MainActor.run {
                    fileActionErrorMessage = error.localizedDescription
                    showFileActionError = true
                }
            }
        }
    }

    private func uploadStagedImages(_ staged: [StagedImageAttachment]) {
        guard let project = projectContext.activeProject else {
            fileActionErrorMessage = FileBrowserError.noProject.localizedDescription
            showFileActionError = true
            return
        }

        let remoteDirectory = viewModel.currentPath
        let existingNames = Set(viewModel.rootNodes.map(\.name))

        Task {
            await MainActor.run {
                isUploadingFiles = true
            }

            var usedNames = existingNames
            do {
                for image in staged {
                    let remoteName = uniqueFilename(originalName: image.displayName, taken: usedNames)
                    usedNames.insert(remoteName)

                    let remotePath = remoteDirectory.hasSuffix("/")
                        ? "\(remoteDirectory)\(remoteName)"
                        : "\(remoteDirectory)/\(remoteName)"

                    try await RemoteFileUploadService.shared.uploadFile(
                        localURL: image.localURL,
                        remotePath: remotePath,
                        in: project
                    )
                }

                await viewModel.loadRemoteFiles()
            } catch {
                await MainActor.run {
                    fileActionErrorMessage = error.localizedDescription
                    showFileActionError = true
                }
            }

            for image in staged {
                try? FileManager.default.removeItem(at: image.localURL)
            }

            await MainActor.run {
                isUploadingFiles = false
            }
        }
    }

    private func uploadLocalFiles(_ urls: [URL]) {
        guard let project = projectContext.activeProject else {
            fileActionErrorMessage = FileBrowserError.noProject.localizedDescription
            showFileActionError = true
            return
        }

        let remoteDirectory = viewModel.currentPath
        let existingNames = Set(viewModel.rootNodes.map(\.name))

        Task {
            await MainActor.run {
                isUploadingFiles = true
            }

            var stagedURLs: [URL] = []
            var usedNames = existingNames

            do {
                for url in urls {
                    let stagedURL = try stageLocalFile(url)
                    stagedURLs.append(stagedURL)

                    let remoteName = uniqueFilename(originalName: url.lastPathComponent, taken: usedNames)
                    usedNames.insert(remoteName)

                    let remotePath = remoteDirectory.hasSuffix("/")
                        ? "\(remoteDirectory)\(remoteName)"
                        : "\(remoteDirectory)/\(remoteName)"

                    try await RemoteFileUploadService.shared.uploadFile(
                        localURL: stagedURL,
                        remotePath: remotePath,
                        in: project
                    )
                }

                await viewModel.loadRemoteFiles()
            } catch {
                await MainActor.run {
                    fileActionErrorMessage = error.localizedDescription
                    showFileActionError = true
                }
            }

            for staged in stagedURLs {
                try? FileManager.default.removeItem(at: staged)
            }

            await MainActor.run {
                isUploadingFiles = false
            }
        }
    }

    private func stageLocalFile(_ url: URL) throws -> URL {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("file-browser-uploads", isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let destination = stagingDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    private func uniqueFilename(originalName: String, taken: Set<String>) -> String {
        guard taken.contains(originalName) else { return originalName }

        let nsName = originalName as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"

        var suffix = 2
        while true {
            let candidate = "\(base)-\(suffix)\(extSuffix)"
            if !taken.contains(candidate) {
                return candidate
            }
            suffix += 1
        }
    }
}

struct FileRow: View {
    let node: FileNode
    @Binding var selectedFile: FileNode?
    let onRename: (FileNode) -> Void
    let onDelete: (FileNode) -> Void
    let onShare: (FileNode) -> Void
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
                if !node.isDirectory {
                    Button {
                        onShare(node)
                    } label: {
                        Label("Share...", systemImage: "square.and.arrow.up")
                    }

                    Divider()
                }

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

#Preview {
    FileBrowserView()
}
