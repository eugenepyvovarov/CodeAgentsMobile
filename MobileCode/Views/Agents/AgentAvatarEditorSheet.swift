//
//  AgentAvatarEditorSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Set agent avatar (emoji, photo, file) or clear it.
//

import PhotosUI
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct AgentAvatarEditorSheet: View {
    let project: RemoteProject

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var emojiDraft = ""
    @State private var emojiKeyboardFocused = false
    @State private var lastAppliedEmoji = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    previewRow
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section {
                    emojiSystemPickerRow
                } header: {
                    Text("Emoji")
                } footer: {
                    Text("Opens the system emoji keyboard — search, skin tones, and recents included.")
                }

                Section {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("agent-avatar-photo-button")

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Choose File", systemImage: "folder")
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("agent-avatar-file-button")
                } header: {
                    Text("Image")
                }

                Section {
                    Button(role: .destructive) {
                        Task { await clearAvatar() }
                    } label: {
                        Label("Clear Avatar", systemImage: "trash")
                    }
                    .disabled(isSaving || project.avatarKind == .none)
                    .accessibilityIdentifier("agent-avatar-clear-button")
                }
            }
            .navigationTitle("Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        emojiKeyboardFocused = false
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        emojiKeyboardFocused = false
                    }
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .padding(16)
                        .modifier(AvatarSavingOverlayChrome())
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await loadFile(url) }
                case .failure(let error):
                    presentError(error.localizedDescription)
                }
            }
            .alert("Avatar", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Something went wrong.")
            }
            .task {
                if project.avatarKind == .emoji {
                    emojiDraft = project.avatarEmoji ?? ""
                    lastAppliedEmoji = emojiDraft
                }
                await AgentAvatarService.shared.refresh(for: project, modelContext: modelContext)
            }
        }
        .accessibilityIdentifier("agent-avatar-editor-sheet")
    }

    // MARK: - Preview

    private var previewRow: some View {
        AgentAvatarView(project: project, size: 96)
            .modifier(AvatarPreviewChrome())
            .animation(.snappy(duration: 0.25), value: project.avatarKind)
            .animation(.snappy(duration: 0.25), value: project.avatarEmoji)
            .frame(maxWidth: .infinity)
    }

    // MARK: - System emoji keyboard

    private var emojiSystemPickerRow: some View {
        HStack(spacing: 12) {
            // Emoji well (left) — hosts the system emoji keyboard.
            ZStack {
                if emojiDraft.isEmpty {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }

                SystemEmojiTextField(
                    text: $emojiDraft,
                    isFocused: $emojiKeyboardFocused
                ) { emoji in
                    Task { await applyEmojiIfNeeded(emoji) }
                }
                .frame(width: 56, height: 44)
                .opacity(emojiDraft.isEmpty ? 0.02 : 1)
            }
            .frame(width: 64, height: 52)
            .contentShape(Rectangle())
            .onTapGesture {
                emojiKeyboardFocused = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .modifier(EmojiKeyboardWellChrome(emphasized: emojiKeyboardFocused))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(emojiDraft.isEmpty ? "Choose emoji" : "Emoji \(emojiDraft)")
            .accessibilityHint("Opens the system emoji keyboard")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("agent-avatar-emoji-well")

            Button {
                emojiKeyboardFocused = true
            } label: {
                Label(
                    emojiDraft.isEmpty ? "Choose Emoji" : "Change Emoji",
                    systemImage: "keyboard"
                )
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            }
            .modifier(EmojiKeyboardButtonChrome())
            .disabled(isSaving)
            .accessibilityIdentifier("agent-avatar-emoji-apply")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func applyEmojiIfNeeded(_ raw: String) async {
        // Prefer last grapheme so a second pick always wins over a stuck first emoji.
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).last.map(String.init)
            ?? AgentAvatarService.normalizeEmoji(raw)
        guard !normalized.isEmpty else { return }
        // Skip only true no-ops (same emoji already applied as emoji avatar).
        if normalized == lastAppliedEmoji, project.avatarKind == .emoji {
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try await AgentAvatarService.shared.setEmoji(
                normalized,
                for: project,
                modelContext: modelContext
            )
            emojiDraft = project.avatarEmoji ?? normalized
            lastAppliedEmoji = emojiDraft
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func clearAvatar() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await AgentAvatarService.shared.clear(for: project, modelContext: modelContext)
            emojiDraft = ""
            lastAppliedEmoji = ""
            emojiKeyboardFocused = false
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        isSaving = true
        defer {
            isSaving = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw AgentAvatarServiceError.invalidImage
            }
            try await AgentAvatarService.shared.setImage(
                data: data,
                for: project,
                modelContext: modelContext
            )
            emojiKeyboardFocused = false
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func loadFile(_ url: URL) async {
        isSaving = true
        defer { isSaving = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            try await AgentAvatarService.shared.setImage(
                data: data,
                for: project,
                modelContext: modelContext
            )
            emojiKeyboardFocused = false
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - Glass chrome

private struct AvatarPreviewChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.14)),
                    in: .circle
                )
        } else {
            content
                .overlay {
                    Circle()
                        .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
                }
        }
    }
}

private struct EmojiKeyboardWellChrome: ViewModifier {
    var emphasized: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular
                        .tint(Color.accentColor.opacity(emphasized ? 0.20 : 0.08))
                        .interactive(),
                    in: .rect(cornerRadius: 20)
                )
        } else {
            content
                .background(
                    Color(.secondarySystemFill),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            emphasized ? Color.accentColor.opacity(0.45) : Color(.separator).opacity(0.25),
                            lineWidth: emphasized ? 1.5 : 0.5
                        )
                }
        }
    }
}

private struct EmojiKeyboardButtonChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct AvatarSavingOverlayChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

#Preview {
    Text("AgentAvatarEditorSheet")
}
