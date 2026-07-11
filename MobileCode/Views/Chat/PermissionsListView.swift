//
//  PermissionsListView.swift
//  CodeAgentsMobile
//
//  Per-agent tool permission list presented from ChatView.
//

import SwiftUI

struct PermissionsListView: View {
    /// When false, embed in a parent `NavigationStack` (Abilities tab).
    var embedsInNavigationStack: Bool = true

    @StateObject private var projectContext = ProjectContext.shared
    @State private var tools: [String] = []

    @ObservedObject private var approvalStore = ToolApprovalStore.shared

    var body: some View {
        Group {
            if embedsInNavigationStack {
                NavigationStack { rootContent }
            } else {
                rootContent
            }
        }
        .onAppear {
            refreshTools()
        }
        .onChange(of: projectContext.activeProject?.id) { _, _ in
            refreshTools()
        }
    }

    private var rootContent: some View {
        List {
            Section {
                GlassInfoCard(
                    title: "Tool Permissions",
                    subtitle: permissionsSubtitle,
                    systemImage: "checkmark.shield"
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if tools.isEmpty {
                ContentUnavailableView(
                    "No Tools Yet",
                    systemImage: "checkmark.shield",
                    description: Text("Tool approvals will appear after they are used or requested.")
                )
            } else {
                ForEach(tools, id: \.self) { tool in
                    ToolPermissionRow(
                        toolName: tool,
                        record: record(for: tool),
                        onDecisionChange: { decision in
                            updateDecision(for: tool, decision: decision)
                        }
                    )
                    // Full-swipe gestures conflict with the horizontal drag gesture on the switch.
                    // Keep swipe-to-reset, but require an explicit tap.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Reset to Ask") {
                            resetDecision(for: tool)
                        }
                        .tint(.gray)
                    }
                }
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refreshTools() {
        guard let agentId = projectContext.activeProject?.id else {
            tools = []
            return
        }
        approvalStore.ensureDefaults(for: agentId)
        tools = approvalStore.knownTools(for: agentId)
    }

    private func decision(for tool: String) -> ToolApprovalDecision? {
        guard let agentId = projectContext.activeProject?.id else { return nil }
        return approvalStore.decision(for: tool, agentId: agentId)?.decision
    }

    private func record(for tool: String) -> ToolApprovalRecord? {
        guard let agentId = projectContext.activeProject?.id else { return nil }
        return approvalStore.decision(for: tool, agentId: agentId)
    }

    private func updateDecision(for tool: String, decision: ToolApprovalDecision) {
        guard let agentId = projectContext.activeProject?.id else { return }
        approvalStore.setDecision(toolName: tool, decision: decision, agentId: agentId)
        refreshTools()
    }

    private func resetDecision(for tool: String) {
        guard let agentId = projectContext.activeProject?.id else { return }
        approvalStore.resetDecision(toolName: tool, agentId: agentId)
        refreshTools()
    }

    private var permissionsSubtitle: String {
        if let agentLabel {
            return "Saved per agent. Current: \(agentLabel). Toggle to allow/deny; swipe to reset to Ask."
        }
        return "Saved per agent. Toggle to allow/deny; swipe to reset to Ask."
    }

    private var agentLabel: String? {
        guard let project = projectContext.activeProject else { return nil }
        if let server = projectContext.activeServer {
            return "\(project.displayTitle)@\(server.name)"
        }
        return project.displayTitle
    }
}

struct ToolPermissionRow: View {
    let toolName: String
    let record: ToolApprovalRecord?
    let onDecisionChange: (ToolApprovalDecision) -> Void

    var body: some View {
        let displayName = ToolPermissionInfo.displayName(for: toolName)
        let summary = ToolPermissionInfo.summary(for: toolName)

        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            PermissionToggle(
                decision: record?.decision,
                onDecisionChange: onDecisionChange
            )
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch record?.decision {
        case .allow:
            switch record?.scope {
            case .global:
                return "Allowed (global)"
            case .agent:
                return "Allowed (this agent)"
            case .once:
                return "Allowed"
            case .none:
                return "Allowed"
            }
        case .deny:
            switch record?.scope {
            case .global:
                return "Denied (global)"
            case .agent:
                return "Denied (this agent)"
            case .once:
                return "Denied"
            case .none:
                return "Denied"
            }
        case .none:
            return "Ask (prompt each time)"
        }
    }
}

struct PermissionToggle: View {
    let decision: ToolApprovalDecision?
    let onDecisionChange: (ToolApprovalDecision) -> Void

    var body: some View {
        Toggle(
            "",
            isOn: Binding(
                get: { decision == .allow },
                set: { isOn in
                    onDecisionChange(isOn ? .allow : .deny)
                }
            )
        )
        .labelsHidden()
        .tint(.accentColor)
    }
}
