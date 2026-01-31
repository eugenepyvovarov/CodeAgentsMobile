//
//  ChatProjectFilePickerSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Pick a remote file from the active agent's project folder for @file references.
//

import SwiftUI

struct ChatProjectFilePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = FileBrowserViewModel()

    let onSelect: (ChatComposerAttachment) -> Void

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if viewModel.currentPath != viewModel.projectRootPath {
                    Section {
                        Button {
                            navigateUp()
                        } label: {
                            Label("Up", systemImage: "arrow.up.left")
                        }
                    }
                }

                Section {
                    if viewModel.isLoading {
                        HStack {
                            ProgressView()
                            Text("Loading…")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(filteredNodes) { node in
                            if node.isDirectory {
                                Button {
                                    viewModel.navigateTo(path: node.path)
                                } label: {
                                    Label(node.name, systemImage: "folder")
                                }
                            } else {
                                Button {
                                    selectFile(node)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: node.icon)
                                            .foregroundColor(.accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(node.name)
                                                .lineLimit(1)
                                            if let size = node.formattedSize {
                                                Text(size)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                            }
                        }
                    }
                } header: {
                    Text(pathLabel)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Attach File")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            viewModel.setupProjectPath()
            await viewModel.loadRemoteFiles()
        }
    }

    // MARK: - Private

    private var pathLabel: String {
        let relative = ProjectPathResolver.relativePath(
            absolutePath: viewModel.currentPath,
            projectRoot: viewModel.projectRootPath
        )
        if let relative {
            return relative.isEmpty ? "Project Root" : relative
        }
        return viewModel.currentPath.isEmpty ? "Project Root" : viewModel.currentPath
    }

    private var filteredNodes: [FileNode] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return viewModel.rootNodes
        }
        let query = trimmed.lowercased()
        return viewModel.rootNodes.filter { $0.name.lowercased().contains(query) }
    }

    private func navigateUp() {
        let parent = (viewModel.currentPath as NSString).deletingLastPathComponent
        guard parent != viewModel.currentPath else { return }
        viewModel.navigateTo(path: parent)
    }

    private func selectFile(_ node: FileNode) {
        let relativePath = ProjectPathResolver.relativePath(
            absolutePath: node.path,
            projectRoot: viewModel.projectRootPath
        )
        guard let relativePath, !relativePath.isEmpty else { return }

        onSelect(.projectFile(displayName: node.name, relativePath: relativePath))
        dismiss()
    }
}

#Preview {
    ChatProjectFilePickerSheet(onSelect: { _ in })
}

