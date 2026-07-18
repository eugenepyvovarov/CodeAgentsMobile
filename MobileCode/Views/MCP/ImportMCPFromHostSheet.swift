//
//  ImportMCPFromHostSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Cross-host MCP server import. Reads raw OpenCodeMCPServerConfiguration
//  entries from a source host's global config and copies selected entries to the
//  target host's global config, preserving `oauth`/`timeout` via the raw-config
//  copy helper (not the MCPServer round-trip).
//

import SwiftUI
import SwiftData

struct ImportMCPFromHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Server.name) private var servers: [Server]
    @StateObject private var mcpService = CodingAgentMCPService.shared

    let targetHost: Server
    let onComplete: () -> Void

    @State private var sourceHost: Server?
    @State private var sourceConfigurations: [String: OpenCodeMCPServerConfiguration] = [:]
    @State private var targetNames: Set<String> = []
    @State private var selectedForCopy: Set<String> = []
    @State private var replaceConflicts: Set<String> = []
    @State private var isLoadingSource = false
    @State private var isCopying = false
    @State private var showError = false
    @State private var errorMessage: String?
    @State private var copySummary: String?
    @State private var hasLoadedTargetNames = false
    @State private var activeSourceLoadRequest: MCPSelectionLoadRequest?
    @State private var loadedSourceID: UUID?

    private var sortedSourceNames: [String] {
        sourceConfigurations.keys.sorted()
    }

    private var selectableHosts: [Server] {
        servers.filter { $0.id != targetHost.id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source Host") {
                    Picker("Import from", selection: $sourceHost) {
                        Text("Select a host…").tag(nil as Server?)
                        ForEach(selectableHosts) { host in
                            Text(host.name).tag(host as Server?)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("mcp-import-source-picker")
                    .disabled(isCopying || !hasLoadedTargetNames)
                }

                if sourceHost == nil {
                    EmptyView()
                } else if !MCPSelectionLoadRequest.canPresent(
                    loadedSelectionID: loadedSourceID,
                    selectedID: sourceHost?.id
                ) {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Reading source MCP servers...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                } else if isLoadingSource {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Reading source MCP servers...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                } else if sourceConfigurations.isEmpty {
                    if sourceHost != nil {
                        Section {
                            Text("No MCP servers on this host.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Section("MCP Servers on \(sourceHost?.name ?? "Source")") {
                        ForEach(sortedSourceNames, id: \.self) { name in
                            sourceRow(for: name)
                        }
                    }

                    Section {
                        Button {
                            Task { await copySelected() }
                        } label: {
                            Label(copyButtonTitle, systemImage: "square.and.arrow.down.on.square")
                        }
                        .disabled(selectedForCopy.isEmpty || isCopying)
                        .accessibilityIdentifier("mcp-import-copy-button")
                    } footer: {
                        if let summary = copySummary {
                            Text(summary)
                                .foregroundColor(.green)
                        } else if isCopying {
                            Text("Copying…")
                        } else {
                            Text("Selected servers are copied to \(targetHost.name)'s global OpenCode config. Existing names are skipped unless Replace is enabled.")
                        }
                    }
                }
            }
            .navigationTitle("Import MCP Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
        }
        .task {
            guard await loadTargetNames() else { return }
            hasLoadedTargetNames = true
            if sourceHost == nil {
                sourceHost = selectableHosts.first
            }
        }
        .task(id: sourceHost?.id) {
            guard hasLoadedTargetNames else { return }
            await loadSourceServers()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func sourceRow(for name: String) -> some View {
        let isMatch = targetNames.contains(name)
        let isManaged = MCPServer.isManagedServer(name)
        let isSelected = selectedForCopy.contains(name)
        let replaceEnabled = isMatch && isSelected

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isManaged {
                    Text("Managed")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.2))
                        .clipShape(Capsule())
                } else if isMatch {
                    Text("Matches")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                } else {
                    Text("New")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isManaged else { return }
                if isSelected {
                    selectedForCopy.remove(name)
                    replaceConflicts.remove(name)
                } else {
                    selectedForCopy.insert(name)
                    // `New` rows default selected; `Matches` rows default unselected.
                    // User must explicitly opt-in to Replace via the toggle below.
                }
            }

            if replaceEnabled {
                Toggle("Replace existing on \(targetHost.name)", isOn: Binding(
                    get: { replaceConflicts.contains(name) },
                    set: { newValue in
                        if newValue {
                            replaceConflicts.insert(name)
                        } else {
                            replaceConflicts.remove(name)
                        }
                    }
                ))
                .font(.caption)
                .toggleStyle(.switch)
            }
        }
        .padding(.vertical, 4)
    }

    private var copyButtonTitle: String {
        let count = selectedForCopy.count
        return count == 0
            ? "Copy"
            : "Copy \(count) to \(targetHost.name)"
    }

    // MARK: - Actions

    @discardableResult
    private func loadTargetNames() async -> Bool {
        do {
            let targetConfigurations = try await mcpService.globalServerConfigurations(for: targetHost)
            targetNames = Set(targetConfigurations.keys)
            return true
        } catch {
            errorMessage = "Could not read target host's MCP servers: \(error.localizedDescription)"
            showError = true
            return false
        }
    }

    private func loadSourceServers() async {
        guard let source = sourceHost else {
            activeSourceLoadRequest = nil
            loadedSourceID = nil
            sourceConfigurations = [:]
            selectedForCopy = []
            replaceConflicts = []
            isLoadingSource = false
            return
        }

        let request = MCPSelectionLoadRequest(selectionID: source.id)
        activeSourceLoadRequest = request
        isLoadingSource = true

        do {
            let configurations = try await mcpService.globalServerConfigurations(for: source)
            guard request.canApply(
                activeRequest: activeSourceLoadRequest,
                selectedID: sourceHost?.id,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            sourceConfigurations = configurations
            loadedSourceID = source.id
            // Default-selection: `New` on, `Matches` off, `Managed` never selectable.
            let managed = Set(configurations.keys.filter { MCPServer.isManagedServer($0) })
            let matches = Set(configurations.keys.filter { targetNames.contains($0) })
            let newNames = Set(configurations.keys).subtracting(managed).subtracting(matches)
            selectedForCopy = newNames
            replaceConflicts = []
        } catch {
            guard request.canApply(
                activeRequest: activeSourceLoadRequest,
                selectedID: sourceHost?.id,
                isCancelled: Task.isCancelled
            ) else {
                return
            }
            errorMessage = "Could not read source host's MCP servers: \(error.localizedDescription)"
            showError = true
            sourceConfigurations = [:]
            selectedForCopy = []
            replaceConflicts = []
            loadedSourceID = source.id
        }

        guard request.canApply(
            activeRequest: activeSourceLoadRequest,
            selectedID: sourceHost?.id,
            isCancelled: Task.isCancelled
        ) else {
            return
        }
        isLoadingSource = false
        activeSourceLoadRequest = nil
    }

    private func copySelected() async {
        guard MCPSelectionLoadRequest.canPresent(
            loadedSelectionID: loadedSourceID,
            selectedID: sourceHost?.id
        ) else {
            errorMessage = "The source host changed before its MCP servers finished loading."
            showError = true
            return
        }
        isCopying = true
        copySummary = nil

        var copied = 0
        var copiedNames: Set<String> = []
        var skipped = 0
        var failed = 0
        var firstError: String?

        let configurationsToCopy = sourceConfigurations
        let targetNamesAtStart = targetNames
        let replaceConflictsAtStart = replaceConflicts
        let namesToCopy = selectedForCopy.sorted()
        for name in namesToCopy {
            guard let configuration = configurationsToCopy[name] else {
                skipped += 1
                continue
            }
            let isMatch = targetNamesAtStart.contains(name)
            if isMatch && !replaceConflictsAtStart.contains(name) {
                // User kept "Skip" for a conflict.
                skipped += 1
                continue
            }

            do {
                _ = try await mcpService.addServerConfiguration(
                    configuration,
                    named: name,
                    to: targetHost,
                    enabled: configuration.enabled ?? true
                )
                copied += 1
                copiedNames.insert(name)
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        isCopying = false

        var summaryParts: [String] = ["\(copied) copied", "\(skipped) skipped"]
        if failed > 0 {
            summaryParts.append("\(failed) failed")
        }
        copySummary = summaryParts.joined(separator: ", ")
        if let firstError, failed > 0 {
            errorMessage = "Some copies failed. First error: \(firstError)"
            showError = true
        }

        // Refresh target name set so subsequent imports see the new entries.
        targetNames.formUnion(copiedNames)
        _ = await loadTargetNames()

        if copied > 0 {
            // Allow the host view to reload its list and notify chat of the change.
            onComplete()
        }
    }
}

#Preview {
    ImportMCPFromHostSheet(targetHost: Server(name: "production", host: "prod.example", username: "ep")) {
        // no-op
    }
    .modelContainer(for: [Server.self, RemoteProject.self, SSHKey.self, ServerProvider.self])
}
