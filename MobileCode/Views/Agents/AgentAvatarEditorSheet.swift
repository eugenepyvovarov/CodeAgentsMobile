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
                    HStack {
                        Spacer()
                        AgentAvatarView(project: project, size: 88)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    HStack {
                        TextField("Emoji", text: $emojiDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("agent-avatar-emoji-field")
                        Button("Apply") {
                            Task { await applyEmoji() }
                        }
                        .disabled(isSaving || emojiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("agent-avatar-emoji-apply")
                    }
                } header: {
                    Text("Emoji")
                } footer: {
                    Text("One emoji is used as the avatar.")
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
                    Button("Done") { dismiss() }
                        .disabled(isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                }
                await AgentAvatarService.shared.refresh(for: project, modelContext: modelContext)
            }
        }
        .accessibilityIdentifier("agent-avatar-editor-sheet")
    }

    private func applyEmoji() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await AgentAvatarService.shared.setEmoji(
                emojiDraft,
                for: project,
                modelContext: modelContext
            )
            emojiDraft = project.avatarEmoji ?? AgentAvatarService.normalizeEmoji(emojiDraft)
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
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
