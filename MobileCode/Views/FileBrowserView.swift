//
//  FileBrowserView.swift
//  CodeAgentsMobile
//
//  Purpose: Browse, upload, and manage remote agent project files.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileBrowserView: View {
    // MARK: - Environment / shared

    @StateObject private var projectContext = ProjectContext.shared

    // MARK: - State

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
    @State private var showingCameraPicker = false
    @State private var uploadProgress: UploadProgress?
    @State private var fileActionErrorMessage: String?
    @State private var showFileActionError = false

    private let largeFileThreshold: Int64 = 250 * 1024 * 1024

    private struct UploadProgress: Equatable {
        var current: Int
        var total: Int
        var filename: String
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    pathNavigationBar
                    fileListView
                }

                if isPreparingShare {
                    busyOverlay(title: "Preparing share…")
                } else if let uploadProgress {
                    busyOverlay(
                        title: "Uploading \(uploadProgress.current) of \(uploadProgress.total)",
                        subtitle: uploadProgress.filename,
                        progress: Double(uploadProgress.current) / Double(max(uploadProgress.total, 1))
                    )
                }
            }
            .navigationTitle(viewModel.currentFolderName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusView()
                }
                ToolbarItem(placement: .primaryAction) {
                    fileMenuButton
                }
            }
            // Edge swipe ← → go to parent folder (distinct from agent-list back).
            .simultaneousGesture(folderBackSwipeGesture)
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
            Button("Cancel", role: .cancel) { newItemName = "" }
            Button("Create") {
                Task {
                    await viewModel.createFolder(name: newItemName)
                    newItemName = ""
                }
            }
        }
        .alert("New File", isPresented: $showingNewFileDialog) {
            TextField("File name", text: $newItemName)
            Button("Cancel", role: .cancel) { newItemName = "" }
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
            Button("Cancel", role: .cancel) { selectedNodeForAction = nil }
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
            Button("Cancel", role: .cancel) { shareCandidate = nil }
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
        .sheet(isPresented: $showingPhotoPicker) {
            PhotoLibraryPicker(
                selectionLimit: 0,
                directoryName: "file-browser-uploads",
                mediaFilter: .imagesAndVideos,
                onUploadItems: { items, error in
                    if !items.isEmpty {
                        uploadStagedItems(items)
                    }
                    if let error {
                        fileActionErrorMessage = error.localizedDescription
                        showFileActionError = true
                    }
                    showingPhotoPicker = false
                },
                onCancel: {
                    showingPhotoPicker = false
                }
            )
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

    // MARK: - Path navigation

    /// Primary folder-up affordance lives here (not in the agent-list chevron).
    @ViewBuilder
    private var pathNavigationBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if viewModel.canNavigateUp {
                    folderUpButton
                }

                breadcrumbTrail
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.6)
        }
        .background(Color(.systemBackground).opacity(0.01))
    }

    @ViewBuilder
    private var folderUpButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                viewModel.navigateUp()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text(folderUpLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(FileBrowserGlassChipModifier())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to \(folderUpAccessibilityName)")
        .accessibilityHint("Goes up one folder. The top-left control returns to the agents list.")
        .accessibilityIdentifier("file-browser-folder-up-button")
    }

    private var folderUpLabel: String {
        if let parent = viewModel.parentFolderName {
            return parent
        }
        return projectContext.activeProject?.displayTitle ?? "Files"
    }

    private var folderUpAccessibilityName: String {
        folderUpLabel
    }

    @ViewBuilder
    private var breadcrumbTrail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(pathComponents.enumerated()), id: \.element.path) { index, component in
                        breadcrumbItem(for: component, isLast: index == pathComponents.count - 1)
                            .id(component.path)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: viewModel.currentPath) { _, newPath in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newPath, anchor: .trailing)
                }
            }
            .onAppear {
                proxy.scrollTo(viewModel.currentPath, anchor: .trailing)
            }
        }
    }

    @ViewBuilder
    private func breadcrumbItem(for component: (name: String, path: String), isLast: Bool) -> some View {
        HStack(spacing: 4) {
            if isLast {
                Text(component.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        navigateToPath(component.path)
                    }
                } label: {
                    Text(component.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .modifier(FileBrowserGlassChipModifier(compact: true))
                }
                .buttonStyle(.plain)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Horizontal swipe from the left edge pops one folder (not the agent).
    private var folderBackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard viewModel.canNavigateUp else { return }
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                // Rightward edge-ish swipe: start near leading edge, mostly horizontal.
                let startedNearLeadingEdge = value.startLocation.x < 28
                let isRightSwipe = horizontal > 70 && horizontal > vertical * 1.4
                if startedNearLeadingEdge && isRightSwipe {
                    withAnimation(.snappy(duration: 0.22)) {
                        viewModel.navigateUp()
                    }
                }
            }
    }

    @ViewBuilder
    private var fileListView: some View {
        List {
            ForEach(viewModel.rootNodes) { node in
                FileBrowserFileRow(
                    node: node,
                    project: projectContext.activeProject,
                    onOpen: {
                        if node.isDirectory {
                            viewModel.navigateTo(path: node.path)
                        } else {
                            viewModel.selectedFile = node
                        }
                    },
                    onRename: {
                        selectedNodeForAction = node
                        newItemName = node.name
                        showingRenameDialog = true
                    },
                    onDelete: {
                        selectedNodeForAction = node
                        showingDeleteConfirmation = true
                    },
                    onShare: node.isDirectory ? nil : { requestShare(node) }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
        .overlay {
            if viewModel.rootNodes.isEmpty, projectContext.activeProject != nil {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("Use + to upload photos, videos, or files.")
                )
            }
        }
    }

    @ViewBuilder
    private var fileMenuButton: some View {
        Menu {
            Button {
                showingPhotoPicker = true
            } label: {
                Label("Upload Photos & Videos", systemImage: "photo.on.rectangle.angled")
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

            Button {
                showingUploadFileImporter = true
            } label: {
                Label("Upload Files", systemImage: "arrow.up.doc")
            }

            Divider()

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

            Divider()

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "plus")
        }
        .disabled(projectContext.activeProject == nil || uploadProgress != nil)
        .accessibilityIdentifier("file-browser-add-menu-button")
    }

    @ViewBuilder
    private func busyOverlay(title: String, subtitle: String? = nil, progress: Double? = nil) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .allowsHitTesting(true)

            VStack(spacing: 12) {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200)
                } else {
                    ProgressView()
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 280)
            .modifier(FileBrowserGlassCardModifier())
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: uploadProgress)
    }

    // MARK: - Path

    private var pathComponents: [(name: String, path: String)] {
        let projectName = projectContext.activeProject?.displayTitle ?? "Agent"

        if viewModel.currentPath == viewModel.projectRootPath {
            return [(name: projectName, path: viewModel.projectRootPath)]
        }

        var result = [(name: projectName, path: viewModel.projectRootPath)]
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

    private func navigateToPath(_ path: String) {
        viewModel.navigateTo(path: path)
    }

    // MARK: - Share

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
        return "This file is \(formatter.string(fromByteCount: size)). Downloading may take a while."
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

    // MARK: - Upload

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
                    uploadStagedItems([
                        StagedUploadItem(
                            displayName: staged.displayName,
                            localURL: staged.localURL,
                            kind: .image
                        )
                    ])
                }
            } catch {
                await MainActor.run {
                    fileActionErrorMessage = error.localizedDescription
                    showFileActionError = true
                }
            }
        }
    }

    private func uploadStagedItems(_ items: [StagedUploadItem]) {
        guard let project = projectContext.activeProject else {
            fileActionErrorMessage = FileBrowserError.noProject.localizedDescription
            showFileActionError = true
            return
        }
        guard !items.isEmpty else { return }

        let remoteDirectory = viewModel.currentPath
        let existingNames = Set(viewModel.rootNodes.map(\.name))

        Task {
            var usedNames = existingNames
            let total = items.count

            do {
                for (index, item) in items.enumerated() {
                    let remoteName = UploadFilename.unique(originalName: item.displayName, taken: usedNames)
                    usedNames.insert(remoteName)

                    await MainActor.run {
                        uploadProgress = UploadProgress(
                            current: index + 1,
                            total: total,
                            filename: remoteName
                        )
                    }

                    let remotePath = remoteDirectory.hasSuffix("/")
                        ? "\(remoteDirectory)\(remoteName)"
                        : "\(remoteDirectory)/\(remoteName)"

                    try await RemoteFileUploadService.shared.uploadFile(
                        localURL: item.localURL,
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

            for item in items {
                try? FileManager.default.removeItem(at: item.localURL)
            }

            await MainActor.run {
                uploadProgress = nil
            }
        }
    }

    private func uploadLocalFiles(_ urls: [URL]) {
        guard projectContext.activeProject != nil else {
            fileActionErrorMessage = FileBrowserError.noProject.localizedDescription
            showFileActionError = true
            return
        }

        Task {
            var staged: [StagedUploadItem] = []
            do {
                for url in urls {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    let item = try MediaUploadStager.stageGenericFile(
                        at: url,
                        directoryName: "file-browser-uploads"
                    )
                    staged.append(item)
                }
                await MainActor.run {
                    uploadStagedItems(staged)
                }
            } catch {
                for item in staged {
                    try? FileManager.default.removeItem(at: item.localURL)
                }
                await MainActor.run {
                    fileActionErrorMessage = error.localizedDescription
                    showFileActionError = true
                }
            }
        }
    }
}

// MARK: - Glass chrome

private struct FileBrowserGlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

/// Interactive glass chip for folder-up + breadcrumb segments.
private struct FileBrowserGlassChipModifier: ViewModifier {
    var compact: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(compact ? 0.08 : 0.14)).interactive(),
                    in: .capsule
                )
        } else {
            content
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(compact ? 0.08 : 0.12))
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                }
        }
    }
}

#Preview {
    FileBrowserView()
}
