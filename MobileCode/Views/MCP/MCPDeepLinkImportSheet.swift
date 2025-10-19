//
//  MCPDeepLinkImportSheet.swift
//  CodeAgentsMobile
//
//  Created by Code Agent on 2025-02-15.
//

import SwiftUI
import SwiftData

struct MCPDeepLinkImportSheet: View {
    let request: DeepLinkManager.Request

    @Environment(\.dismiss) private var dismiss

    @Query(sort: \RemoteProject.name) private var projects: [RemoteProject]

    @State private var selectedProjectId: UUID?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var importSummary: MCPDeepLinkImportSummary?

    private let importer = MCPDeepLinkImporter()

    var body: some View {
        NavigationStack {
            Form {
                projectSection

                detailsSection

                Section(footer: footerText) {
                    EmptyView()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isImporting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: importPayload) {
                        if isImporting {
                            ProgressView()
                        } else {
                            Text(actionButtonTitle)
                        }
                    }
                    .disabled(!canImport)
                }
            }
            .alert("Error", isPresented: $showError, actions: {
                Button("OK", role: .cancel) { }
            }, message: {
                Text(errorMessage ?? "An error occurred")
            })
            .onAppear(perform: prepareSelection)
            .onDisappear { DeepLinkManager.shared.clear(request: request) }
        }
        .interactiveDismissDisabled(isImporting)
    }

    private var projectSection: some View {
        Section("Project") {
            if projects.isEmpty {
                Text("No projects available. Create a project first in the Projects tab.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Picker("Add to", selection: Binding(
                    get: { selectedProjectId },
                    set: { selectedProjectId = $0 }
                )) {
                    ForEach(projects) { project in
                        Text(project.name)
                            .tag(project.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        switch request.payload {
        case .server(let server):
            Section("Server") {
                LabeledContent("Name") { Text(server.name) }

                if server.isRemote {
                    if let url = server.url {
                        LabeledContent("URL") { Text(url).textSelection(.enabled) }
                    }
                    if let headers = server.headers, !headers.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Headers")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                HStack {
                                    Text(key)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(value)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                } else {
                    if let command = server.command {
                        LabeledContent("Command") {
                            Text(command)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    if let args = server.args, !args.isEmpty {
                        LabeledContent("Arguments") {
                            Text(args.joined(separator: " "))
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    if let env = server.env, !env.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Environment")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            ForEach(env.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                HStack {
                                    Text(key)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(value)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                LabeledContent("Scope") {
                    Text(server.scope.displayName)
                        .foregroundColor(.secondary)
                }

                if let summary = server.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

        case .bundle(let bundle):
            Section("Bundle") {
                LabeledContent("Name") { Text(bundle.name) }
                if let description = bundle.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                LabeledContent("Servers") {
                    Text("\(bundle.servers.count)")
                        .foregroundColor(.secondary)
                }

                ForEach(Array(bundle.servers.enumerated()), id: \.offset) { _, server in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name)
                            .font(.subheadline)
                        Text(server.isRemote ? "Remote" : "Local")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var footerText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Existing MCP servers with the same name will be renamed automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
            if let summary = importSummary {
                let renamed = summary.renamedServers
                if !renamed.isEmpty {
                    Text("Renamed: \(renamed.map { "\($0.originalName) → \($0.finalName)" }.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var title: String {
        switch request.payload {
        case .server:
            return "Add MCP Server"
        case .bundle:
            return "Install MCP Bundle"
        }
    }

    private var actionButtonTitle: String {
        switch request.payload {
        case .server:
            return "Add"
        case .bundle:
            return "Install"
        }
    }

    private var canImport: Bool {
        !isImporting && selectedProjectId != nil && !projects.isEmpty
    }

    private func prepareSelection() {
        if let suggested = request.suggestedProjectId, projects.contains(where: { $0.id == suggested }) {
            selectedProjectId = suggested
        } else if selectedProjectId == nil {
            selectedProjectId = projects.first?.id
        }
    }

    private func importPayload() {
        guard let projectId = selectedProjectId, let project = projects.first(where: { $0.id == projectId }) else {
            return
        }

        isImporting = true
        errorMessage = nil

        Task {
            do {
                switch request.payload {
                case .server(let server):
                    importSummary = try await importer.importServer(server, into: project)
                case .bundle(let bundle):
                    importSummary = try await importer.importBundle(bundle, into: project)
                }

                NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }

            isImporting = false
        }
    }
}
