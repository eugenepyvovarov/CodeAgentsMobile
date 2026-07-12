//
//  DuplicateAgentSheet.swift
//  CodeAgentsMobile
//
//  Purpose: UI to duplicate an agent into a new workspace with selected setup copy.
//

import SwiftUI
import SwiftData

/// Result of a successful duplicate flow for the presenting list/abilities screen.
struct DuplicateAgentFinish: Equatable {
    let projectId: UUID
    let shouldOpen: Bool
}

struct DuplicateAgentSheet: View {
    let source: RemoteProject

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var servers: [Server]
    @Query private var allProjects: [RemoteProject]

    @State private var displayName: String
    @State private var folderName: String
    @State private var copyRules = true
    @State private var copySkills = true
    @State private var copyProjectMCP = true
    @State private var copyPermissions = true
    @State private var copyEnv = false
    @State private var envIncludeValues = false
    @State private var copyTasks = false
    @State private var copyAvatar = true
    @State private var isDuplicating = false
    @State private var progressPhase: DuplicateAgentProgress?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var warnings: [String] = []
    @State private var showSuccess = false
    @State private var completedCloneId: UUID?

    private let onFinished: ((DuplicateAgentFinish) -> Void)?

    init(source: RemoteProject, onFinished: ((DuplicateAgentFinish) -> Void)? = nil) {
        self.source = source
        self.onFinished = onFinished
        let defaultName = AgentDuplicationPath.defaultDisplayName(from: source.displayTitle)
        _displayName = State(initialValue: defaultName)
        let suggested = AgentDuplicationPath.suggestedFolderName(from: defaultName) ?? "\(source.name)-copy"
        _folderName = State(initialValue: suggested)
    }

    private var server: Server? {
        servers.first { $0.id == source.serverId }
            ?? ServerManager.shared.server(withId: source.serverId)
    }

    private var parentPath: String {
        AgentDuplicationPath.parentDirectory(of: source.path)
            ?? server?.defaultProjectsPath
            ?? "/root/projects"
    }

    private var pathPreview: String {
        let folder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = folder.isEmpty ? "[folder]" : folder
        return AgentDuplicationPath.join(parent: parentPath, folderName: name)
    }

    /// True when another agent already owns the intended path in SwiftData.
    /// Ignores the clone we just created (`completedCloneId`) so a successful
    /// insert does not flag the form against itself while the sheet is still open.
    private var localFolderCollision: Bool {
        guard let server,
              let safe = SSHShellQuoting.sanitizedPathComponent(folderName) else {
            return false
        }
        let intended = PathUtils.normalize(
            AgentDuplicationPath.join(parent: parentPath, folderName: safe)
        )
        let ignoreId = completedCloneId
        return allProjects.contains {
            $0.serverId == server.id
                && PathUtils.normalize($0.path) == intended
                && $0.id != ignoreId
        }
    }

    /// Collision caption for the form only — not while create is running or success is shown.
    /// Mid-duplicate, the service inserts the clone before finishing setup; `@Query` would
    /// otherwise treat that path as already taken and flash a false error.
    private var showsLocalFolderCollision: Bool {
        !isDuplicating && !showSuccess && localFolderCollision
    }

    private var canDuplicate: Bool {
        !isDuplicating
            && !showSuccess
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && SSHShellQuoting.sanitizedPathComponent(folderName) != nil
            && server != nil
            && !localFolderCollision
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("duplicate-agent-display-name-field")

                    TextField("Folder name", text: $folderName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                        .accessibilityIdentifier("duplicate-agent-folder-name-field")

                    if showsLocalFolderCollision {
                        Text("An agent already uses this folder path. Try a suffix like -2.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("duplicate-agent-folder-collision-label")
                    }
                } header: {
                    Text("New Agent")
                } footer: {
                    Text("Creates a new folder and empty chat. Does not copy messages or session.")
                }

                if isDuplicating, let phase = progressPhase {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(phase.userLabel)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("duplicate-agent-progress")
                    }
                }

                Section("Location") {
                    LabeledContent("Server") {
                        Text(server?.name ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Path") {
                        Text(pathPreview)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    Toggle("Copy personality (AGENTS.md)", isOn: $copyRules)
                    Toggle("Copy skill enables", isOn: $copySkills)
                    Toggle("Copy project MCP servers", isOn: $copyProjectMCP)
                    Toggle("Copy tool permissions", isOn: $copyPermissions)
                    Toggle("Copy avatar", isOn: $copyAvatar)
                } header: {
                    Text("Toolbox")
                } footer: {
                    Text("Global skills and global MCP are already shared on the server. Avatar lives in the agent identity file.")
                }

                Section {
                    Toggle("Copy environment variables", isOn: $copyEnv)
                    if copyEnv {
                        Toggle("Include values (secrets)", isOn: $envIncludeValues)
                    }
                    Toggle("Copy scheduled tasks (disabled)", isOn: $copyTasks)
                    Toggle("Copy project files", isOn: .constant(false))
                        .disabled(true)
                } header: {
                    Text("Optional")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if copyEnv && !envIncludeValues {
                            Text("Keys only — values stay empty until you fill them. Syncs to the daemon for the new agent only.")
                        }
                        if copyEnv && envIncludeValues {
                            Text("Secrets will exist on both agents until you change them.")
                        }
                        if copyTasks {
                            Text("Tasks start disabled. Review prompts (they may still mention the source project).")
                        }
                        Text("Copying project files is not available yet.")
                    }
                    .font(.caption)
                }
            }
            .navigationTitle("Duplicate Agent")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("duplicate-agent-sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isDuplicating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isDuplicating {
                        ProgressView()
                    } else {
                        Button("Duplicate") {
                            Task { await performDuplicate() }
                        }
                        .disabled(!canDuplicate)
                        .accessibilityIdentifier("duplicate-agent-confirm-button")
                    }
                }
            }
            .interactiveDismissDisabled(isDuplicating || showSuccess)
            .alert("Could Not Duplicate", isPresented: $showError) {
                Button("OK", role: .cancel) {}
                if suggestsFolderSuffix {
                    Button("Use \(suggestedCollisionFolder)") {
                        folderName = suggestedCollisionFolder
                    }
                }
            } message: {
                Text(errorMessage ?? "An error occurred.")
            }
            .alert("Agent Created", isPresented: $showSuccess) {
                Button("Open Agent") {
                    finish(shouldOpen: true)
                }
                .accessibilityIdentifier("duplicate-agent-open-button")
                Button("Done", role: .cancel) {
                    finish(shouldOpen: false)
                }
                .accessibilityIdentifier("duplicate-agent-done-button")
            } message: {
                Text(successMessage)
            }
            .onAppear {
                ensureUniqueDefaultFolderName()
            }
        }
    }

    private var suggestsFolderSuffix: Bool {
        guard let message = errorMessage?.lowercased() else { return false }
        return message.contains("already exists") || message.contains("folder path")
    }

    private var suggestedCollisionFolder: String {
        let base = SSHShellQuoting.sanitizedPathComponent(folderName)
            ?? folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentDuplicationPath.nextFolderNameCandidate(base: base, attempt: 2) ?? "\(base)-2"
    }

    private var successMessage: String {
        if warnings.isEmpty {
            return "The new agent is ready with an empty chat."
        }
        return "Agent created; some setup needs attention:\n\n" + warnings.joined(separator: "\n")
    }

    private func ensureUniqueDefaultFolderName() {
        guard let server else { return }
        let originalBase = folderName
        var attempt = 1
        while attempt < 20 {
            guard let candidate = AgentDuplicationPath.nextFolderNameCandidate(
                base: originalBase,
                attempt: attempt
            ) else { return }
            let intended = PathUtils.normalize(
                AgentDuplicationPath.join(parent: parentPath, folderName: candidate)
            )
            let taken = allProjects.contains {
                $0.serverId == server.id && PathUtils.normalize($0.path) == intended
            }
            if !taken {
                folderName = candidate
                return
            }
            attempt += 1
        }
    }

    private func performDuplicate() async {
        guard !isDuplicating else { return }
        isDuplicating = true
        progressPhase = .preparing
        defer {
            isDuplicating = false
            progressPhase = nil
        }

        let envMode: AgentEnvCopyMode
        if !copyEnv {
            envMode = .off
        } else if envIncludeValues {
            envMode = .keysAndValues
        } else {
            envMode = .keysOnly
        }

        let request = DuplicateAgentRequest(
            sourceProjectId: source.id,
            displayName: displayName,
            folderName: folderName,
            copyRules: copyRules,
            copySkills: copySkills,
            copyProjectMCP: copyProjectMCP,
            copyPermissions: copyPermissions,
            envMode: envMode,
            copyTasks: copyTasks,
            copyAvatar: copyAvatar
        )

        do {
            let result = try await AgentDuplicationService.shared.duplicate(
                source: source,
                request: request,
                modelContext: modelContext,
                onProgress: { phase in
                    progressPhase = phase
                }
            )
            completedCloneId = result.projectId
            warnings = result.warnings
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func finish(shouldOpen: Bool) {
        if let id = completedCloneId {
            onFinished?(DuplicateAgentFinish(projectId: id, shouldOpen: shouldOpen))
        }
        dismiss()
    }
}
