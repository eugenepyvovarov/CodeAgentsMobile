//
//  AgentEnvironmentVariablesView.swift
//  CodeAgentsMobile
//
//  Purpose: Per-agent environment variable editor (proxy-only)
//

import SwiftUI
import SwiftData

struct AgentEnvironmentVariablesView: View {
    @StateObject private var projectContext = ProjectContext.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\AgentEnvironmentVariable.key, order: .forward)])
    private var allVariables: [AgentEnvironmentVariable]

    @State private var showingAdd = false
    @State private var editingVariable: AgentEnvironmentVariable?
    @State private var isRefreshing = false
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                if projectContext.activeProject == nil {
                    ContentUnavailableView {
                        Label("No Active Agent", systemImage: "person.crop.circle.badge.xmark")
                    } description: {
                        Text("Select an agent to edit environment variables.")
                    }
                } else {
                    List {
                        statusSection
                        variablesSection
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await refreshFromServer()
                    }
                }
            }
            .navigationTitle("Environment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(projectContext.activeProject == nil)
                }
            }
            .sheet(isPresented: $showingAdd) {
                AgentEnvironmentVariableEditorView(
                    projectId: projectContext.activeProject?.id,
                    existingKeys: Set(variables.map { $0.key }),
                    variable: nil
                ) {
                    Task { await syncToServer() }
                }
            }
            .sheet(item: $editingVariable) { variable in
                AgentEnvironmentVariableEditorView(
                    projectId: projectContext.activeProject?.id,
                    existingKeys: Set(variables.filter { $0.id != variable.id }.map { $0.key }),
                    variable: variable
                ) {
                    Task { await syncToServer() }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
            .task(id: projectContext.activeProject?.id) {
                await refreshFromServer()
            }
        }
    }

    private var variables: [AgentEnvironmentVariable] {
        guard let project = projectContext.activeProject else { return [] }
        return allVariables.filter { $0.projectId == project.id }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let project = projectContext.activeProject {
            Section("Status") {
                EnvVarsSyncStatusRow(
                    isSyncing: isSyncing,
                    isRefreshing: isRefreshing,
                    pendingSync: project.envVarsPendingSync,
                    lastSyncedAt: project.envVarsLastSyncedAt,
                    error: project.envVarsLastSyncError
                ) {
                    Task { await syncToServer() }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
        }
    }

    @ViewBuilder
    private var variablesSection: some View {
        Section("Variables") {
            if variables.isEmpty {
                Text("No environment variables.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(variables) { variable in
                    Button {
                        editingVariable = variable
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(variable.key)
                                    .font(.headline)
                                    .fontDesign(.monospaced)
                                if !variable.value.isEmpty {
                                    Text(variable.value)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 8)

                            Toggle("", isOn: binding(for: variable))
                                .labelsHidden()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteVariables)
            }
        }
    }

    private func binding(for variable: AgentEnvironmentVariable) -> Binding<Bool> {
        Binding(
            get: { variable.isEnabled },
            set: { newValue in
                variable.isEnabled = newValue
                variable.markUpdated()
                Task { await syncToServer() }
            }
        )
    }

    private func deleteVariables(at offsets: IndexSet) {
        let toDelete = offsets.map { variables[$0] }
        for variable in toDelete {
            modelContext.delete(variable)
        }
        try? modelContext.save()
        Task { await syncToServer() }
    }

    private func refreshFromServer() async {
        guard let project = projectContext.activeProject else { return }
        guard !project.envVarsPendingSync else { return }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let agentId = try await ProxyAgentIdentityService.shared.ensureProxyAgentId(for: project, modelContext: modelContext)
            let remote = try await ProxyAgentEnvService.shared.fetchEnv(agentId: agentId, project: project)
            applyRemote(remote, project: project)
            project.envVarsLastSyncError = nil
            project.envVarsLastSyncedAt = Date()
            try modelContext.save()
        } catch {
            project.envVarsLastSyncError = error.localizedDescription
            try? modelContext.save()
        }
    }

    private func applyRemote(_ remote: [ProxyAgentEnvItem], project: RemoteProject) {
        var localByKey: [String: AgentEnvironmentVariable] = [:]
        for variable in variables {
            localByKey[variable.key] = variable
        }

        for item in remote {
            let enabled = item.enabled ?? true
            if let existing = localByKey[item.key] {
                existing.value = item.value
                existing.isEnabled = enabled
                existing.markUpdated()
                localByKey.removeValue(forKey: item.key)
            } else {
                modelContext.insert(
                    AgentEnvironmentVariable(
                        projectId: project.id,
                        key: item.key,
                        value: item.value,
                        isEnabled: enabled
                    )
                )
            }
        }

        for (_, orphan) in localByKey {
            modelContext.delete(orphan)
        }
    }

    private func syncToServer() async {
        guard let project = projectContext.activeProject else { return }
        guard !isSyncing else { return }

        isSyncing = true
        defer { isSyncing = false }

        project.envVarsPendingSync = true
        project.envVarsLastSyncError = nil
        try? modelContext.save()

        do {
            let agentId = try await ProxyAgentIdentityService.shared.ensureProxyAgentId(for: project, modelContext: modelContext)
            let payload = variables.map { ProxyAgentEnvItem(key: $0.key, value: $0.value, enabled: $0.isEnabled) }
            try await ProxyAgentEnvService.shared.replaceEnv(agentId: agentId, env: payload, project: project)
            project.envVarsPendingSync = false
            project.envVarsLastSyncedAt = Date()
            project.envVarsLastSyncError = nil
            try modelContext.save()
        } catch {
            project.envVarsPendingSync = true
            project.envVarsLastSyncError = error.localizedDescription
            try? modelContext.save()
        }
    }
}

private struct EnvVarsSyncStatusRow: View {
    let isSyncing: Bool
    let isRefreshing: Bool
    let pendingSync: Bool
    let lastSyncedAt: Date?
    let error: String?
    let onSync: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 18) {
                    rowContent
                }
            } else {
                rowContent
            }
        }
        .contentShape(Rectangle())
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    statusChip
                    lastSyncText
                }

                if let trimmedError, !trimmedError.isEmpty {
                    Text(trimmedError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            syncButton
        }
    }

    private var trimmedError: String? {
        let trimmed = (error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var statusText: String {
        if isSyncing {
            return "Syncing"
        }
        if pendingSync {
            return "Pending"
        }
        return "Synced"
    }

    private var statusSymbol: String {
        if isSyncing {
            return "arrow.triangle.2.circlepath"
        }
        if pendingSync {
            return "exclamationmark.arrow.triangle.2.circlepath"
        }
        return "checkmark.circle"
    }

    private var statusTint: Color {
        if isSyncing {
            return .blue
        }
        if pendingSync {
            return .orange
        }
        return .green
    }

    @ViewBuilder
    private var statusChip: some View {
        let content = HStack(spacing: 6) {
            if isSyncing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: statusSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(statusTint)
                    .imageScale(.small)
            }

            Text(statusText)
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)

        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(statusTint))
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(statusTint.opacity(0.25), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private var lastSyncText: some View {
        if let lastSyncedAt {
            Text(lastSyncedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("Not synced yet")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var syncButton: some View {
        let label = ZStack {
            if isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .symbolRenderingMode(.hierarchical)
                    .imageScale(.medium)
            }
        }
        .frame(width: 34, height: 34)

        let button = Button(action: onSync) {
            label
        }
        .disabled(isSyncing || isRefreshing)
        .accessibilityLabel(Text(pendingSync ? "Sync Now" : "Sync"))

        if #available(iOS 26, *) {
            button
                .buttonStyle(.glass)
                .controlSize(.small)
        } else {
            button
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        }
    }
}

private struct AgentEnvironmentVariableEditorView: View {
    let projectId: UUID?
    let existingKeys: Set<String>
    let variable: AgentEnvironmentVariable?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var key = ""
    @State private var value = ""
    @State private var isEnabled = true
    @State private var errorMessage: String?
    @State private var showError = false

    init(projectId: UUID?,
         existingKeys: Set<String>,
         variable: AgentEnvironmentVariable?,
         onSave: @escaping () -> Void) {
        self.projectId = projectId
        self.existingKeys = existingKeys
        self.variable = variable
        self.onSave = onSave

        _key = State(initialValue: Self.sanitizeKeyInput(variable?.key ?? ""))
        _value = State(initialValue: variable?.value ?? "")
        _isEnabled = State(initialValue: variable?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    TextField("NAME", text: keyBinding)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("Value") {
                    TextField("Value", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                }
            }
            .navigationTitle(variable == nil ? "Add Variable" : "Edit Variable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(projectId == nil)
                }
            }
            .alert("Invalid Variable", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "Invalid environment variable.")
            }
        }
    }

    private func save() {
        guard let projectId else { return }

        let normalizedKey = normalizeKey(key)
        guard isValidKey(normalizedKey) else {
            errorMessage = "Key must match [A-Z_][A-Z0-9_]*."
            showError = true
            return
        }
        guard !existingKeys.contains(normalizedKey) else {
            errorMessage = "A variable with this key already exists."
            showError = true
            return
        }

        if let variable {
            variable.key = normalizedKey
            variable.value = value
            variable.isEnabled = isEnabled
            variable.markUpdated()
        } else {
            modelContext.insert(
                AgentEnvironmentVariable(
                    projectId: projectId,
                    key: normalizedKey,
                    value: value,
                    isEnabled: isEnabled
                )
            )
        }

        do {
            try modelContext.save()
            dismiss()
            onSave()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private var keyBinding: Binding<String> {
        Binding(
            get: { key },
            set: { newValue in
                key = Self.sanitizeKeyInput(newValue)
            }
        )
    }

    private func normalizeKey(_ value: String) -> String {
        Self.sanitizeKeyInput(value)
    }

    private static func sanitizeKeyInput(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 65...90, 48...57, 95:
                result.unicodeScalars.append(scalar)
            case 97...122:
                result.unicodeScalars.append(UnicodeScalar(scalar.value - 32)!)
            case 9, 10, 13, 32:
                result.append("_")
            default:
                continue
            }
        }

        return result
    }

    private func isValidKey(_ value: String) -> Bool {
        guard let first = value.first else { return false }
        let firstIsValid = (first == "_") || ("A"..."Z").contains(first)
        guard firstIsValid else { return false }

        for scalar in value.unicodeScalars {
            if ("A"..."Z").contains(Character(scalar)) { continue }
            if ("0"..."9").contains(Character(scalar)) { continue }
            if scalar == "_" { continue }
            return false
        }

        return true
    }
}

#Preview {
    AgentEnvironmentVariablesView()
        .modelContainer(for: [RemoteProject.self, AgentEnvironmentVariable.self], inMemory: true)
}
