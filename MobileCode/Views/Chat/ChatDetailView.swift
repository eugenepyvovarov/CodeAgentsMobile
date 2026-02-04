//
//  ChatDetailView.swift
//  CodeAgentsMobile
//
//  Purpose: ExyteChat-based chat detail UI.
//

import SwiftUI
import Observation
import ExyteChat
import UIKit
import UniformTypeIdentifiers

struct ChatDetailView: View {
    @Bindable var viewModel: ChatViewModel
    let assistantLabel: String
    let userLabel: String = "You"
    @StateObject private var projectContext = ProjectContext.shared
    @AppStorage(ClaudeProviderConfigurationStore.configurationKey) private var claudeProviderConfigurationData = Data()
    @State private var scrollToBottomWorkItem: DispatchWorkItem?
    @State private var followUpScrollWorkItem: DispatchWorkItem?
    @State private var isVisible = false
    @FocusState private var isInputFocused: Bool
    @State private var selectedSkill: AgentSkill?
    @State private var showingSkillPicker = false
    @State private var showingProviderSettings = false
    @State private var attachments: [ChatComposerAttachment] = []
    @State private var showingProjectFilePicker = false
    @State private var showingLocalFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var showingCameraPicker = false
    @State private var isUploadingAttachments = false
    @State private var showAttachmentError = false
    @State private var attachmentErrorMessage = ""
    @State private var isBottomMessageVisible = false
    @State private var shouldAutoScrollToUnreadBottom = false

    var body: some View {
        let _ = viewModel.messagesRevision
        let adapter = ChatMessageAdapter(
            messages: viewModel.messages,
            streamingMessageId: viewModel.streamingMessage?.id,
            streamingRedrawToken: viewModel.streamingRedrawToken,
            currentUserName: userLabel,
            assistantName: assistantLabel
        )
        let lastRenderedMessageId = adapter.exyteMessages.last?.id

        let baseChat = ExyteChat.ChatView<AnyView, ExyteChatInputComposer, DefaultMessageMenuAction>(
            messages: adapter.exyteMessages,
            chatType: .conversation,
            replyMode: .quote,
            reactionDelegate: nil,
            messageBuilder: { message, _, _, _, _, _, _ in
                let sourceMessage: Message = {
                    guard let id = UUID(uuidString: message.id),
                          let existing = viewModel.messages.first(where: { $0.id == id }) else {
                        let role: MessageRole = message.user.type == .current ? .user : .assistant
                        let fallback = Message(content: message.text, role: role)
                        fallback.timestamp = message.createdAt
                        if let id = UUID(uuidString: message.id) {
                            fallback.id = id
                        }
                        return fallback
                    }
                    return existing
                }()
                let bubble = MessageBubble(
                    message: sourceMessage,
                    assistantLabel: assistantLabel,
                    userLabel: userLabel,
                    isStreaming: viewModel.streamingMessage?.id == sourceMessage.id,
                    streamingBlocks: viewModel.streamingMessage?.id == sourceMessage.id ? viewModel.streamingBlocks : []
                )

                if message.id == lastRenderedMessageId {
                    return AnyView(bubble
                        .onAppear {
                            isBottomMessageVisible = true
                            attemptMarkAsRead()
                        }
                        .onDisappear {
                            isBottomMessageVisible = false
                        }
                    )
                }

                return AnyView(bubble)
            },
            inputViewBuilder: { (text: Binding<String>, _: InputViewAttachments, state: InputViewState, _: InputViewStyle, action: @escaping (InputViewAction) -> Void, _: () -> Void) in
                ExyteChatInputComposer(
                    text: text,
                    state: state,
                    isFocused: $isInputFocused,
                    selectedSkillName: selectedSkill.map { SkillNameFormatter.displayName(from: $0.name) },
                    attachments: attachments,
                    isAddEnabled: projectContext.activeProject != nil && !isUploadingAttachments,
                    onAddSkill: {
                        guard projectContext.activeProject != nil else { return }
                        showingSkillPicker = true
                    },
                    onAddProjectFile: {
                        guard projectContext.activeProject != nil else { return }
                        showingProjectFilePicker = true
                    },
                    onAddLocalFile: {
                        guard projectContext.activeProject != nil else { return }
                        showingLocalFileImporter = true
                    },
                    onAddPhotoLibrary: {
                        guard projectContext.activeProject != nil else { return }
                        showingPhotoPicker = true
                    },
                    onAddCamera: {
                        guard projectContext.activeProject != nil else { return }
                        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                            attachmentErrorMessage = "Camera not available on this device."
                            showAttachmentError = true
                            return
                        }
                        showingCameraPicker = true
                    },
                    onClearSkill: {
                        selectedSkill = nil
                    },
                    onRemoveAttachment: { attachmentId in
                        attachments.removeAll(where: { $0.id == attachmentId })
                    },
                    onSend: {
                        action(.send)
                    }
                )
            },
            messageMenuAction: nil,
            localization: chatLocalization,
            didUpdateAttachmentStatus: nil,
            didSendMessage: { draft in
                Task {
                    let attachmentsSnapshot = attachments
                    let selectedSkillSnapshot = selectedSkill

                    await MainActor.run {
                        selectedSkill = nil
                        attachments = []
                    }

                    guard let project = projectContext.activeProject else {
                        await viewModel.sendMessage(draft.text)
                        return
                    }

                    let skillSlug = selectedSkillSnapshot?.slug
                    let hasLocalFiles = attachmentsSnapshot.contains { attachment in
                        if case .localFile = attachment { return true }
                        return false
                    }

                    do {
                        var references = attachmentsSnapshot.compactMap { $0.relativeReferencePath }

                        if hasLocalFiles {
                            await MainActor.run {
                                isUploadingAttachments = true
                            }
                            references = try await ChatAttachmentUploadService.shared.resolveFileReferences(
                                for: attachmentsSnapshot,
                                in: project
                            )
                            await MainActor.run {
                                isUploadingAttachments = false
                            }
                        }

                        let prompt = ChatSkillPromptBuilder.build(
                            message: draft.text,
                            skillName: selectedSkillSnapshot.map { SkillNameFormatter.displayName(from: $0.name) },
                            skillSlug: skillSlug,
                            fileReferences: references
                        )

                        await viewModel.sendMessage(prompt)
                    } catch {
                        await MainActor.run {
                            attachmentErrorMessage = error.localizedDescription
                            showAttachmentError = true
                            isUploadingAttachments = false
                        }
                    }
                }
            }
        )
        let chat = AnyView(
            baseChat
                .setAvailableInputs([.text])
                .showDateHeaders(false)
                .showMessageTimeView(false)
                .showMessageMenuOnLongPress(false)
                .chatTheme(chatTheme)
        )

        let chatLifecycle = AnyView(
            chat
                .onAppear {
                    isVisible = true
                    viewModel.refreshProviderMismatch(for: projectContext.activeProject)
                    shouldAutoScrollToUnreadBottom = (projectContext.activeProject?.unreadCount ?? 0) > 0
                    maybeAutoScrollToBottomForUnread()
                    attemptMarkAsRead()
                }
                .onDisappear {
                    isVisible = false
                    scrollToBottomWorkItem?.cancel()
                    scrollToBottomWorkItem = nil
                    followUpScrollWorkItem?.cancel()
                    followUpScrollWorkItem = nil
                    isBottomMessageVisible = false
                    shouldAutoScrollToUnreadBottom = false
                }
        )

        let chatSyncing = AnyView(
            chatLifecycle
                .onChange(of: viewModel.messages.count) { _, _ in
                    maybeAutoScrollToBottomForUnread()
                    attemptMarkAsRead()
                }
                .onChange(of: viewModel.isProcessing) { _, isProcessing in
                    if !isProcessing {
                        requestScrollToBottom(force: true)
                    }
                    attemptMarkAsRead()
                }
                .onChange(of: viewModel.isLoadingPreviousSession) { _, _ in
                    attemptMarkAsRead()
                }
                .onChange(of: viewModel.showActiveSessionIndicator) { _, _ in
                    attemptMarkAsRead()
                }
                .onChange(of: projectContext.activeProject?.lastKnownUnreadCursor ?? 0) { _, _ in
                    attemptMarkAsRead()
                }
                .onChange(of: isInputFocused) { _, focused in
                    if focused {
                        requestScrollToBottom(force: true, followUpDelay: 0.3)
                    }
                }
                .onChange(of: projectContext.activeProject?.id) { _, _ in
                    selectedSkill = nil
                    attachments = []
                    isBottomMessageVisible = false
                    viewModel.refreshProviderMismatch(for: projectContext.activeProject)
                    attemptMarkAsRead()
                }
                .onChange(of: claudeProviderConfigurationData) { _, _ in
                    viewModel.refreshProviderMismatch(for: projectContext.activeProject)
                }
        )

        let chatAlerts = AnyView(
            chatSyncing
                .alert(
                    "Tool Permission",
                    isPresented: Binding(
                        get: { viewModel.activeToolApproval != nil },
                        set: { _ in }
                    ),
                    presenting: viewModel.activeToolApproval,
                    actions: { request in
                        Button("Allow") {
                            viewModel.respondToToolApproval(request, decision: .allow, scope: .agent)
                        }
                        Button("Deny", role: .destructive) {
                            viewModel.respondToToolApproval(request, decision: .deny, scope: .agent)
                        }
                    },
                    message: { request in
                        let displayName = ToolPermissionInfo.displayName(for: request.toolName)
                        let summary = ToolPermissionInfo.summary(for: request.toolName)

                        var parts: [String] = []
                        parts.append("\(assistantLabel) wants to use “\(displayName)”")
                        if displayName != request.toolName {
                            parts.append("Tool: \(request.toolName)")
                        }
                        parts.append(summary)
                        if let blockedPath = request.blockedPath, !blockedPath.isEmpty {
                            parts.append("Requested path: \(blockedPath)")
                        }
                        parts.append("This decision is saved for \(assistantLabel) and can be changed in Permissions.")

                        return Text(parts.joined(separator: "\n\n"))
                    }
                )
                .alert("Attachment Error", isPresented: $showAttachmentError) {
                    Button("OK") { }
                } message: {
                    Text(attachmentErrorMessage)
                }
        )

        return chatAlerts
            .modifier(
                ChatTopOverlayModifier(
                    providerMismatch: viewModel.providerMismatch,
                    statusLines: statusPillLines,
                    showStatusPill: shouldShowStatusPill,
                    onClearChat: { viewModel.clearChat() },
                    onChangeProvider: { showingProviderSettings = true }
                )
            )
            .sheet(isPresented: $showingProviderSettings) {
                NavigationStack {
                    ClaudeProviderSettingsView()
                        .navigationTitle("Claude Provider")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .sheet(isPresented: $showingSkillPicker) {
                if let projectId = projectContext.activeProject?.id {
                    ChatSkillPickerSheet(
                        projectId: projectId,
                        selectedSkillSlug: selectedSkill?.slug,
                        onSelect: { skill in
                            selectedSkill = skill
                        }
                    )
                } else {
                    NavigationStack {
                        ContentUnavailableView {
                            Label("No Active Agent", systemImage: "person.crop.circle.badge.xmark")
                        } description: {
                            Text("Select an agent before choosing skills.")
                        }
                        .navigationTitle("Select Skill")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingSkillPicker = false }
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingProjectFilePicker) {
                ChatProjectFilePickerSheet(onSelect: { attachment in
                    addAttachment(attachment)
                })
            }
            .sheet(isPresented: $showingPhotoPicker) {
                PhotoLibraryPicker(
                    selectionLimit: 0,
                    directoryName: "chat-attachments",
                    onComplete: { staged, error in
                        for item in staged {
                            addAttachment(.localFile(displayName: item.displayName, localURL: item.localURL))
                        }
                        if let error {
                            attachmentErrorMessage = error.localizedDescription
                            showAttachmentError = true
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
                        attachmentErrorMessage = error.localizedDescription
                        showAttachmentError = true
                    }
                )
            }
            .fileImporter(
                isPresented: $showingLocalFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    importLocalFiles(urls)
                case .failure(let error):
                    attachmentErrorMessage = error.localizedDescription
                    showAttachmentError = true
                }
            }
    }

    private var canMarkAsRead: Bool {
        isVisible
    }

    private func attemptMarkAsRead() {
        guard canMarkAsRead else { return }
        guard let project = projectContext.activeProject else { return }
        viewModel.markUnreadAsRead(for: project)
    }

    private func maybeAutoScrollToBottomForUnread() {
        guard shouldAutoScrollToUnreadBottom else { return }
        guard isVisible else { return }
        guard !viewModel.messages.isEmpty else { return }

        requestScrollToBottom(force: true, followUpDelay: 0.35)
        shouldAutoScrollToUnreadBottom = false
    }

    private var shouldShowThinkingIndicator: Bool {
        guard viewModel.isProcessing else { return false }
        if viewModel.isAwaitingToolApproval {
            return false
        }
        let hasCompletedSession = viewModel.messages.last?.structuredMessages?.contains { $0.type == "result" } ?? false
        return !hasCompletedSession
    }

    private var statusPillLines: [String] {
        var lines: [String] = []
        if isUploadingAttachments {
            lines.append("Uploading attachments...")
        }
        if viewModel.isLoadingPreviousSession {
            lines.append("Checking for previous session...")
        }
        if viewModel.isAwaitingToolApproval {
            lines.append("Tool approval required")
        }
        if viewModel.showSyncRetryIndicator {
            lines.append("Reconnecting...")
        }
        if shouldShowThinkingIndicator {
            lines.append(viewModel.showActiveSessionIndicator ? "Claude is still processing..." : "Claude is thinking...")
        }
        return lines
    }

    private var shouldShowStatusPill: Bool {
        !statusPillLines.isEmpty
    }

    private func requestScrollToBottom(force: Bool, followUpDelay: TimeInterval? = nil) {
        guard force || viewModel.isProcessing else { return }
        guard isVisible else { return }
        guard !viewModel.messages.isEmpty else { return }

        scrollToBottomWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak viewModel] in
            guard let viewModel, !viewModel.messages.isEmpty else { return }
            NotificationCenter.default.post(name: .onScrollToBottom, object: nil)
        }
        scrollToBottomWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)

        if let followUpDelay = followUpDelay {
            followUpScrollWorkItem?.cancel()
            let followUpItem = DispatchWorkItem { [weak viewModel] in
                guard let viewModel, !viewModel.messages.isEmpty else { return }
                NotificationCenter.default.post(name: .onScrollToBottom, object: nil)
            }
            followUpScrollWorkItem = followUpItem
            DispatchQueue.main.asyncAfter(deadline: .now() + followUpDelay, execute: followUpItem)
        }
    }

    private func addAttachment(_ attachment: ChatComposerAttachment) {
        switch attachment {
        case .projectFile(_, _, let relativePath):
            if attachments.contains(where: { $0.relativeReferencePath == relativePath }) {
                return
            }
        case .localFile(_, let displayName, _):
            if attachments.contains(where: { $0.displayName == displayName }) {
                return
            }
        }

        attachments.append(attachment)
    }

    private func importLocalFiles(_ urls: [URL]) {
        do {
            for url in urls {
                let stagedURL = try stageLocalFile(url)
                addAttachment(.localFile(displayName: url.lastPathComponent, localURL: stagedURL))
            }
        } catch {
            attachmentErrorMessage = error.localizedDescription
            showAttachmentError = true
        }
    }

    private func handleCameraImage(_ image: UIImage) {
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try ImageAttachmentStager.stageImage(
                        from: image,
                        preferredName: nil,
                        directoryName: "chat-attachments"
                    )
                }.value

                await MainActor.run {
                    addAttachment(.localFile(displayName: staged.displayName, localURL: staged.localURL))
                }
            } catch {
                await MainActor.run {
                    attachmentErrorMessage = error.localizedDescription
                    showAttachmentError = true
                }
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
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("chat-attachments", isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let destination = stagingDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    private var chatLocalization: ChatLocalization {
        ChatLocalization(
            inputPlaceholder: "Type a message...",
            signatureText: "Add signature...",
            cancelButtonText: "Cancel",
            recentToggleText: "Recents",
            waitingForNetwork: "Waiting for network",
            recordingText: "Recording...",
            replyToText: "Reply to"
        )
    }

    private var chatTheme: ChatTheme {
        let colors = ChatTheme.Colors(
            mainBG: Color(.systemBackground),
            mainTint: Color.accentColor,
            mainText: Color(.label),
            mainCaptionText: Color(.secondaryLabel),
            messageMyBG: Color.accentColor,
            messageMyText: Color.white,
            messageMyTimeText: Color.white.opacity(0.7),
            messageFriendBG: Color(.secondarySystemBackground),
            messageFriendText: Color(.label),
            messageFriendTimeText: Color(.secondaryLabel),
            messageSystemBG: Color(.tertiarySystemBackground),
            messageSystemText: Color(.secondaryLabel),
            messageSystemTimeText: Color(.secondaryLabel),
            inputBG: Color(.secondarySystemBackground),
            inputText: Color(.label),
            inputPlaceholderText: Color(.secondaryLabel),
            inputSignatureBG: Color(.secondarySystemBackground),
            inputSignatureText: Color(.label),
            inputSignaturePlaceholderText: Color(.secondaryLabel),
            menuBG: Color(.systemBackground),
            menuText: Color(.label),
            menuTextDelete: Color(.systemRed),
            statusError: Color(.systemRed),
            statusGray: Color(.systemGray3),
            sendButtonBackground: Color.accentColor,
            recordDot: Color(.systemRed)
        )
        return ChatTheme(colors: colors)
    }
}

private struct ExyteChatInputComposer: View {
    @Binding var text: String
    let state: InputViewState
    let isFocused: FocusState<Bool>.Binding
    let selectedSkillName: String?
    let attachments: [ChatComposerAttachment]
    let isAddEnabled: Bool
    let onAddSkill: () -> Void
    let onAddProjectFile: () -> Void
    let onAddLocalFile: () -> Void
    let onAddPhotoLibrary: () -> Void
    let onAddCamera: () -> Void
    let onClearSkill: () -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onSend: () -> Void
    private var canSend: Bool {
        if selectedSkillName != nil || !attachments.isEmpty {
            return true
        }
        switch state {
        case .hasTextOrMedia, .hasRecording, .isRecordingTap, .playingRecording, .pausedRecording:
            return true
        default:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if selectedSkillName != nil || !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let selectedSkillName {
                            ChatComposerChip(
                                systemImage: "sparkles",
                                title: selectedSkillName,
                                onRemove: onClearSkill
                            )
                        }

                        ForEach(attachments) { attachment in
                            ChatComposerChip(
                                systemImage: attachment.systemImageName,
                                title: attachment.displayName,
                                onRemove: {
                                    onRemoveAttachment(attachment.id)
                                }
                            )
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Menu {
                    Button(action: onAddSkill) {
                        Label("Skill", systemImage: "sparkles")
                    }
                    Button(action: onAddProjectFile) {
                        Label("Project File", systemImage: "folder")
                    }
                    Button(action: onAddLocalFile) {
                        Label("Local File", systemImage: "doc")
                    }
                    Button(action: onAddPhotoLibrary) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    Button(action: onAddCamera) {
                        Label("Take Photo", systemImage: "camera")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundColor(isAddEnabled ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isAddEnabled)
                .accessibilityLabel("Add")

                TextField("Ask Claude...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .autocapitalization(.none)
                    .autocorrectionDisabled(true)
                    .focused(isFocused)
                    .onSubmit {
                        if canSend {
                            onSend()
                        }
                    }

                Button {
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(canSend ? .accentColor : .secondary)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ChatComposerChip: View {
    let systemImage: String
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }
}

private struct ChatStatusPillView: View {
    let lines: [String]

    var body: some View {
        let content = HStack(alignment: .center, spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.85)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)), in: .capsule)
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
                    )
            }
        }
    }
}

private struct ChatTopOverlayModifier: ViewModifier {
    let providerMismatch: ClaudeProviderMismatch?
    let statusLines: [String]
    let showStatusPill: Bool
    let onClearChat: () -> Void
    let onChangeProvider: () -> Void

    private var isVisible: Bool {
        providerMismatch != nil || showStatusPill
    }

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                content
                    .safeAreaBar(edge: .top) {
                        overlayContent
                    }
            } else {
                if isVisible {
                    content
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .safeAreaInset(edge: .top, spacing: 0) {
                            overlayInset
                        }
                } else {
                    content
                }
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        if isVisible {
            VStack(spacing: 6) {
                if let providerMismatch {
                    ClaudeProviderResetBannerView(
                        mismatch: providerMismatch,
                        onClearChat: onClearChat,
                        onChangeProvider: onChangeProvider
                    )
                }
                if showStatusPill {
                    ChatStatusPillView(lines: statusLines)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var overlayInset: some View {
        if isVisible {
            VStack(spacing: 6) {
                if let providerMismatch {
                    ClaudeProviderResetBannerView(
                        mismatch: providerMismatch,
                        onClearChat: onClearChat,
                        onChangeProvider: onChangeProvider
                    )
                }
                if showStatusPill {
                    ChatStatusPillView(lines: statusLines)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
    }
}
