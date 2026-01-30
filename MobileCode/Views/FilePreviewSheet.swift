//
//  FilePreviewSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Preview files with Quick Look or edit text files with syntax highlighting
//

import SwiftUI
import QuickLook
import CodeEditorView
import LanguageSupport

private typealias EditorMessage = LanguageSupport.Message

struct FilePreviewSheet: View {
    private enum DownloadPurpose {
        case preview
        case share
    }

    private let largeFileThreshold: Int64 = 250 * 1024 * 1024

    let file: FileNode
    let viewModel: FileBrowserViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var content = ""
    @State private var originalContent = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isSharing = false
    @State private var loadErrorMessage: String?
    @State private var alertMessage: String?
    @State private var showErrorAlert = false
    @State private var showLargeFileWarning = false
    @State private var pendingDownloadPurpose: DownloadPurpose?
    @State private var previewURL: URL?

    @State private var cursorPosition = CodeEditor.Position()
    @State private var messages = Set<TextLocated<EditorMessage>>()

    var body: some View {
        NavigationStack {
            Group {
                if file.isTextFile {
                    textEditorContent
                } else {
                    quickLookContent
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

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        shareFile()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(isLoading || loadErrorMessage != nil || isSharing)

                    if file.isTextFile {
                        Button("Save") {
                            Task { await saveTextFile() }
                        }
                        .disabled(!hasUnsavedChanges || isSaving || isLoading)
                    }
                }
            }
        }
        .task {
            if file.isTextFile {
                await loadTextFile()
            } else {
                await preparePreviewDownload()
            }
        }
        .alert("Large File", isPresented: $showLargeFileWarning) {
            Button("Cancel", role: .cancel) {
                let shouldDismiss = pendingDownloadPurpose == .preview
                pendingDownloadPurpose = nil
                if shouldDismiss {
                    dismiss()
                }
            }
            Button("Continue") {
                Task { await continueLargeFileDownload() }
            }
        } message: {
            Text(largeFileWarningMessage)
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage ?? "Something went wrong.")
        }
        .onDisappear {
            if let previewURL {
                try? FileManager.default.removeItem(at: previewURL)
            }
        }
    }

    private var hasUnsavedChanges: Bool {
        content != originalContent
    }

    @ViewBuilder
    private var textEditorContent: some View {
        if isLoading {
            ProgressView("Loading file...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadErrorMessage {
            errorState(message: loadErrorMessage)
        } else {
            CodeEditor(
                text: $content,
                position: $cursorPosition,
                messages: $messages,
                language: editorLanguage
            )
            .environment(\.codeEditorTheme, colorScheme == .dark ? Theme.defaultDark : Theme.defaultLight)
        }
    }

    @ViewBuilder
    private var quickLookContent: some View {
        if isLoading {
            ProgressView("Loading preview...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadErrorMessage {
            errorState(message: loadErrorMessage)
        } else if let previewURL {
            QuickLookPreview(url: previewURL)
        } else {
            errorState(message: "Preview unavailable.")
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("Failed to load file")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var editorLanguage: LanguageConfiguration {
        guard let ext = file.fileExtension else { return .none }
        switch ext {
        case "swift":
            return .swift()
        case "py":
            return .python()
        case "md", "markdown", "mdx":
            return .markdown()
        case "sql":
            return .sqlite()
        default:
            return .none
        }
    }

    private var largeFileWarningMessage: String {
        guard let size = file.fileSize else {
            return "This file is large. Downloading may take a while."
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let formattedSize = formatter.string(fromByteCount: size)
        return "This file is \(formattedSize). Downloading may take a while."
    }

    private func shouldWarnForLargeFile() -> Bool {
        guard let size = file.fileSize else { return false }
        return size >= largeFileThreshold
    }

    private func loadTextFile() async {
        isLoading = true
        loadErrorMessage = nil

        do {
            let loaded = try await viewModel.loadFileContent(path: file.path)
            content = loaded
            originalContent = loaded
            isLoading = false
        } catch {
            loadErrorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func saveTextFile() async {
        isSaving = true
        alertMessage = nil

        do {
            try await viewModel.saveFileContent(path: file.path, content: content)
            originalContent = content
            isSaving = false
        } catch {
            alertMessage = error.localizedDescription
            showErrorAlert = true
            isSaving = false
        }
    }

    private func preparePreviewDownload() async {
        if shouldWarnForLargeFile() {
            pendingDownloadPurpose = .preview
            showLargeFileWarning = true
            return
        }

        await downloadFile(for: .preview)
    }

    private func shareFile() {
        if file.isTextFile {
            Task { await shareTextFile() }
        } else {
            Task { await shareNonTextFile() }
        }
    }

    private func shareTextFile() async {
        isSharing = true
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)_\(file.name)")
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            ShareSheetPresenter.present(urls: [tempURL]) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            alertMessage = error.localizedDescription
            showErrorAlert = true
        }
        isSharing = false
    }

    private func shareNonTextFile() async {
        if let previewURL {
            isSharing = true
            ShareSheetPresenter.present(urls: [previewURL])
            isSharing = false
            return
        }

        if shouldWarnForLargeFile() {
            pendingDownloadPurpose = .share
            showLargeFileWarning = true
            return
        }

        await downloadFile(for: .share)
    }

    private func continueLargeFileDownload() async {
        guard let purpose = pendingDownloadPurpose else { return }
        pendingDownloadPurpose = nil
        await downloadFile(for: purpose)
    }

    private func downloadFile(for purpose: DownloadPurpose) async {
        isLoading = purpose == .preview
        isSharing = purpose == .share
        loadErrorMessage = nil

        do {
            let downloadedURL = try await viewModel.downloadFile(file)
            if previewURL == nil {
                previewURL = downloadedURL
            }

            if purpose == .share {
                ShareSheetPresenter.present(urls: [downloadedURL])
            }
        } catch {
            loadErrorMessage = error.localizedDescription
            showErrorAlert = true
        }

        isLoading = false
        isSharing = false
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
