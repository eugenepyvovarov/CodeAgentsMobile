//
//  ChatView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var claudeService = ClaudeCodeService.shared
    @Environment(\.modelContext) private var modelContext
    @State private var showingMCPServers = false
    @State private var showingAgentSkills = false
    @State private var showingPermissions = false
    @State private var showingRules = false
    @State private var showingEnvironment = false
    
    var body: some View {
        NavigationStack {
            Group {
                // Check if Claude is installed
                if let server = projectContext.activeServer,
                   let isInstalled = claudeService.claudeInstallationStatus[server.id],
                   !isInstalled {
                    // Replace entire chat UI with installation view
                    ClaudeNotInstalledView(server: server)
                } else {
                    // Normal chat UI
                    ChatDetailView(viewModel: viewModel, assistantLabel: assistantLabel)
                        .refreshable {
                            await viewModel.refreshProxyEvents()
                        }
                }
            }
            .navigationTitle(chatTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusView()
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingMCPServers = true
                        } label: {
                            Label("MCP Servers", systemImage: "server.rack")
                        }

                        Button {
                            showingAgentSkills = true
                        } label: {
                            Label("Agent Skills", systemImage: "sparkles")
                        }

                        Button {
                            showingPermissions = true
                        } label: {
                            Label("Permissions", systemImage: "checkmark.shield")
                        }

                        Button {
                            showingRules = true
                        } label: {
                            Label("Rules", systemImage: "doc.text")
                        }

                        Button {
                            showingEnvironment = true
                        } label: {
                            Label("Environment Variables", systemImage: "terminal")
                        }

                        Divider()
                        
                        Button {
                            clearChat()
                        } label: {
                            Label("Clear Chat", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task(id: projectContext.activeProject?.id) {
            guard let project = projectContext.activeProject else { return }
            do {
                _ = try await ProxyAgentIdentityService.shared.ensureProxyAgentId(for: project, modelContext: modelContext)
            } catch {
                SSHLogger.log("Failed to ensure proxy agent id for chat view configure (projectId=\(project.id)): \(error)", level: .warning)
            }
            viewModel.configure(modelContext: modelContext, projectId: project.id)
        }
        .onAppear {
            viewModel.startProxyPolling()
            Task {
                if let project = projectContext.activeProject,
                   let server = projectContext.activeServer {
                    await PushNotificationsManager.shared.recordChatOpened(
                        project: project,
                        server: server,
                        agentDisplayName: assistantLabel
                    )
                }
            }
            // Re-check Claude installation when view appears
            Task {
                if let server = projectContext.activeServer {
                    // Only check if we don't have a cached status or if it was not installed
                    if claudeService.claudeInstallationStatus[server.id] == nil || 
                       claudeService.claudeInstallationStatus[server.id] == false {
                        _ = await claudeService.checkClaudeInstallation(for: server)
                    }
                }
            }
        }
        .onDisappear {
            // Clear loading state when view disappears to prevent stuck UI
            viewModel.clearLoadingStates()
            // Clean up resources to prevent retain cycles
            viewModel.cleanup()
        }
        .onChange(of: projectContext.activeProject) { oldValue, newValue in
            if let project = newValue {
                if let server = projectContext.activeServer {
                    Task {
                        let agentDisplayName = "\(project.displayTitle)@\(server.name)"
                        await PushNotificationsManager.shared.recordChatOpened(
                            project: project,
                            server: server,
                            agentDisplayName: agentDisplayName
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showingMCPServers) {
            MCPServersListView()
                .onDisappear {
                    // Refresh MCP servers when sheet is dismissed
                    Task {
                        await viewModel.refreshMCPServers()
                    }
                }
        }
        .sheet(isPresented: $showingAgentSkills) {
            AgentSkillsPickerView()
        }
        .sheet(isPresented: $showingPermissions) {
            PermissionsListView()
        }
        .sheet(isPresented: $showingRules) {
            AgentRulesView()
        }
        .sheet(isPresented: $showingEnvironment) {
            AgentEnvironmentVariablesView()
        }
    }
    
    private func clearChat() {
        viewModel.clearChat()
    }

    private var assistantLabel: String {
        guard let project = projectContext.activeProject else { return "Claude" }
        if let server = projectContext.activeServer {
            return "\(project.displayTitle)@\(server.name)"
        }
        return project.displayTitle
    }

    private var chatTitle: String {
        assistantLabel
    }
}

struct MessageBubble: View {
    let message: Message
    let assistantLabel: String
    let userLabel: String
    let isStreaming: Bool
    let streamingBlocks: [ContentBlock]
    
    var body: some View {
        // Check if message has visible content
        let hasStructuredContent = (message.structuredMessages?.isEmpty == false) || 
                                 (message.structuredContent != nil)
        let hasVisibleContent = !message.content.isEmpty || 
                              hasStructuredContent || 
                              isStreaming
        let isUser = message.role == MessageRole.user
        let senderLabel = isUser ? userLabel : assistantLabel
        
        if hasVisibleContent {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    if isUser {
                        Spacer()
                    }
                    Text(senderLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    if !isUser {
                        Spacer()
                    }
                }
                // Message content
                messageContent
                
                // Timestamp
                HStack {
                    if message.role == MessageRole.user {
                        Spacer()
                    }
                    
                    Text(DateFormatter.smartFormat(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                    
                    if message.role == MessageRole.assistant {
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: message.role == MessageRole.user ? .trailing : .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
    }
    
    @ViewBuilder
    private var messageContent: some View {
        let fallbackBlocks = message.fallbackContentBlocks()
        if isStreaming {
            if !streamingBlocks.isEmpty {
                VStack(spacing: 8) {
                    streamingBlocksView
                }
            } else {
                StreamingPlaceholderBubble(isUser: message.role == MessageRole.user)
            }
        } else if let messages = message.structuredMessages, !messages.isEmpty {
            structuredMessageStack(messages)
        } else if let structured = message.structuredContent {
            structuredMessageStack([structured])
        } else if !fallbackBlocks.isEmpty {
            structuredMessageStack([])
        } else {
            PlainMessageBubble(message: message)
        }
    }

    @ViewBuilder
    private var streamingBlocksView: some View {
        VStack(spacing: 8) {
            ForEach(0..<streamingBlocks.count, id: \.self) { index in
                let block = streamingBlocks[index]
                HStack {
                    if message.role == MessageRole.user {
                        Spacer()
                    }
                    
                    switch block {
                    case .text(let textBlock):
                        TextBlockView(
                            textBlock: textBlock,
                            textColor: message.role == MessageRole.user ? .white : .primary,
                            isStreaming: true,
                            isAssistant: message.role == MessageRole.assistant
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(message.role == MessageRole.user ? Color.accentColor : Color(.systemGray5))
                        .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                        .transition(.opacity)
                        .animation(.easeIn(duration: 0.2), value: streamingBlocks.count)
                        
                    case .toolUse(_), .toolResult(_):
                        ContentBlockView(
                            block: block,
                            textColor: .primary,
                            isStreaming: true,
                            isAssistant: message.role == MessageRole.assistant
                        )
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
                        .transition(.opacity)
                        .animation(.easeIn(duration: 0.2), value: streamingBlocks.count)
                    case .unknown:
                        EmptyView()
                    }
                    
                    if message.role == MessageRole.assistant && block.isTextBlock {
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func structuredMessageStack(_ messages: [StructuredMessageContent]) -> some View {
        let systemMessages = messages.filter { $0.type == "system" && !isSessionInfoSystemMessage($0) }
        let contentMessages = messages.filter { shouldRenderContentMessage($0) }
        let fallbackBlocks = message.fallbackContentBlocks()
        
        VStack(spacing: 8) {
            ForEach(Array(systemMessages.enumerated()), id: \.offset) { _, msg in
                SystemMessageView(message: msg)
            }
            
            if !contentMessages.isEmpty || !fallbackBlocks.isEmpty {
                StructuredMessageBubble(message: message, structuredMessages: contentMessages)
            }
        }
    }

    private func shouldRenderContentMessage(_ message: StructuredMessageContent) -> Bool {
        switch message.type {
        case "assistant":
            return hasRenderableContent(message)
        case "user":
            return hasRenderableContent(message)
        default:
            return false
        }
    }

    private func isSessionInfoSystemMessage(_ message: StructuredMessageContent) -> Bool {
        guard message.type == "system" else { return false }
        if let subtype = message.subtype?.lowercased(), subtype.contains("session") {
            return true
        }
        if let data = message.data, !data.isEmpty {
            return true
        }
        return true
    }

    private func hasRenderableContent(_ message: StructuredMessageContent) -> Bool {
        guard let content = message.message else { return false }
        switch content.content {
        case .blocks(let blocks):
            return blocks.contains { block in
                switch block {
                case .text(let textBlock):
                    return !textBlock.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .toolUse(let toolUseBlock):
                    return !BlockFormattingUtils.isBlockedToolName(toolUseBlock.name)
                case .toolResult(let toolResultBlock):
                    return !BlockFormattingUtils.isBlockedToolResultContent(toolResultBlock.content)
                case .unknown:
                    return false
                }
            }
        case .text(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func containsToolResult(_ message: StructuredMessageContent) -> Bool {
        guard let content = message.message else { return false }
        switch content.content {
        case .blocks(let blocks):
            return blocks.contains { block in
                if case .toolResult = block {
                    return true
                }
                return false
            }
        case .text:
            return false
        }
    }
}

struct PermissionsListView: View {
    @StateObject private var projectContext = ProjectContext.shared
    @State private var tools: [String] = []

    @ObservedObject private var approvalStore = ToolApprovalStore.shared

    var body: some View {
        NavigationStack {
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
        .onAppear {
            refreshTools()
        }
        .onChange(of: projectContext.activeProject?.id) { _, _ in
            refreshTools()
        }
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

private struct ToolPermissionRow: View {
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

private struct PermissionToggle: View {
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

private struct StreamingPlaceholderBubble: View {
    let isUser: Bool

    var body: some View {
        let bubbleBackground = isUser ? Color.accentColor : Color(.systemGray6)
        let bubbleTextColor: Color = isUser ? .white : .secondary

        HStack {
            if isUser {
                Spacer()
            }

            Text("...")
                .font(.body.weight(.semibold))
                .foregroundColor(bubbleTextColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: UIScreen.main.bounds.width * 0.5, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer()
            }
        }
    }
}

struct PlainMessageBubble: View {
    let message: Message
    @State private var showActionButtons = false
    
    var body: some View {
        let isUser = message.role == MessageRole.user
        let bubbleBackground = isUser ? Color.accentColor : Color(.systemGray6)
        let bubbleTextColor: Color = isUser ? .white : .primary
        let bubbleBorderColor = Color(.systemGray4).opacity(0.6)

        ZStack {
            // Invisible background to catch taps outside
            if showActionButtons {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showActionButtons = false
                        }
                    }
            }
            
            HStack {
                if message.role == MessageRole.user {
                    Spacer()
                }
                
                VStack(alignment: message.role == MessageRole.user ? .trailing : .leading, spacing: 8) {
                    CodeAgentsUIMessageContentView(
                        text: message.content,
                        textColor: bubbleTextColor,
                        isAssistant: message.role == MessageRole.assistant
                    )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(bubbleBackground)
                        .foregroundColor(bubbleTextColor)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(isUser ? .clear : bubbleBorderColor, lineWidth: 0.5)
                        )
                        .shadow(color: isUser ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.08), radius: 2, y: 1)
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.78, alignment: message.role == MessageRole.user ? .trailing : .leading)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showActionButtons.toggle()
                            }
                        }
                    
                    // Action buttons (same style for both user and assistant)
                    if showActionButtons {
                        HStack(spacing: 12) {
                            Button(action: {
                                UIPasteboard.general.string = message.content
                                // Haptic feedback
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                                
                                // Hide button after copying
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showActionButtons = false
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 14))
                                    Text("Copy")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                            
                            Button(action: {
                                // Share functionality
                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let rootViewController = windowScene.windows.first?.rootViewController {
                                    let activityViewController = UIActivityViewController(
                                        activityItems: [message.content],
                                        applicationActivities: nil
                                    )
                                    rootViewController.present(activityViewController, animated: true)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 14))
                                    Text("Share...")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                        }
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                
                if message.role == MessageRole.assistant {
                    Spacer()
                }
            }
        }
    }
}

struct StructuredMessageBubble: View {
    let message: Message
    let structuredMessages: [StructuredMessageContent]
    @State private var showActionButtons = false
    
    var body: some View {
        let isUser = message.role == MessageRole.user
        let bubbleBackground = isUser ? Color.accentColor : Color(.systemGray6)
        let bubbleTextColor: Color = isUser ? .white : .primary
        let bubbleBorderColor = Color(.systemGray4).opacity(0.6)
        let fallbackBlocks = message.fallbackContentBlocks()

        ZStack {
            // Invisible background to catch taps outside
            if showActionButtons {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showActionButtons = false
                        }
                    }
            }
            
            VStack(spacing: 8) {
                // Collect all content blocks from all messages
                let allBlocks = structuredMessages.compactMap { structured -> [ContentBlock]? in
                    if let messageContent = structured.message {
                        switch messageContent.content {
                        case .text(let text):
                            return [ContentBlock.text(TextBlock(type: "text", text: text))]
                        case .blocks(let blocks):
                            return blocks
                        }
                    }
                    return nil
                }.flatMap { $0 }

                let visibleBlocks = allBlocks.filter { block in
                    if case .unknown = block {
                        return false
                    }
                    return true
                }

                let renderBlocks = visibleBlocks.isEmpty ? fallbackBlocks : visibleBlocks
                
                if !renderBlocks.isEmpty {
                // Display each block as a separate bubble
                ForEach(Array(renderBlocks.enumerated()), id: \.offset) { index, block in
                    HStack {
                        if message.role == MessageRole.user {
                            Spacer()
                        }
                        
                        // Different styling for different block types
                        switch block {
                        case .text(let textBlock):
                            // Text blocks get the traditional bubble styling
                            TextBlockView(
                                textBlock: textBlock,
                                textColor: bubbleTextColor,
                                isAssistant: message.role == MessageRole.assistant
                            )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(bubbleBackground)
                                .foregroundColor(bubbleTextColor)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(isUser ? .clear : bubbleBorderColor, lineWidth: 0.5)
                                )
                                .shadow(color: isUser ? Color.accentColor.opacity(0.15) : Color.black.opacity(0.08), radius: 2, y: 1)
                                .frame(maxWidth: UIScreen.main.bounds.width * 0.78, alignment: message.role == MessageRole.user ? .trailing : .leading)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showActionButtons.toggle()
                                    }
                                }
                            
                        case .toolUse(_), .toolResult(_):
                            // Tool use and results get their own special styling
                            ContentBlockView(
                                block: block, 
                                textColor: .primary,
                                isAssistant: message.role == MessageRole.assistant
                            )
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
                        case .unknown:
                            EmptyView()
                        }
                        
                        if message.role == MessageRole.assistant && block.isTextBlock {
                            Spacer()
                        }
                    }
                }
                
                // Action buttons for the entire message
                if showActionButtons {
                    HStack {
                        if message.role == MessageRole.user {
                            Spacer()
                        }
                        
                        HStack(spacing: 12) {
                            Button(action: {
                                // Extract all text content for copying
                                let textContent = renderBlocks.compactMap { block -> String? in
                                    switch block {
                                    case .text(let textBlock):
                                        return textBlock.text
                                    default:
                                        return nil
                                    }
                                }.joined(separator: "\n")
                                
                                UIPasteboard.general.string = textContent.isEmpty ? message.content : textContent
                                // Haptic feedback
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                                
                                // Hide button after copying
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showActionButtons = false
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 14))
                                    Text("Copy")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                            
                            Button(action: {
                                // Extract all text content for sharing
                                let textContent = renderBlocks.compactMap { block -> String? in
                                    switch block {
                                    case .text(let textBlock):
                                        return textBlock.text
                                    default:
                                        return nil
                                    }
                                }.joined(separator: "\n")
                                
                                let shareContent = textContent.isEmpty ? message.content : textContent
                                
                                // Share functionality
                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let rootViewController = windowScene.windows.first?.rootViewController {
                                    let activityViewController = UIActivityViewController(
                                        activityItems: [shareContent],
                                        applicationActivities: nil
                                    )
                                    rootViewController.present(activityViewController, animated: true)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 14))
                                    Text("Share...")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                        }
                        
                        if message.role == MessageRole.assistant {
                            Spacer()
                        }
                    }
                    .transition(.opacity.combined(with: .scale))
                }
            } else {
                // Fallback to plain text if no blocks
                VStack(alignment: message.role == MessageRole.user ? .trailing : .leading, spacing: 8) {
                    HStack {
                        if message.role == MessageRole.user {
                            Spacer()
                        }
                        
                        Text(message.content)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(message.role == MessageRole.user ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showActionButtons.toggle()
                                }
                            }
                        
                        if message.role == MessageRole.assistant {
                            Spacer()
                        }
                    }
                    
                    // Action buttons for fallback case
                    if showActionButtons {
                        HStack(spacing: 12) {
                            Button(action: {
                                UIPasteboard.general.string = message.content
                                // Haptic feedback
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                                
                                // Hide button after copying
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showActionButtons = false
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 14))
                                    Text("Copy")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                            
                            Button(action: {
                                // Share functionality
                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let rootViewController = windowScene.windows.first?.rootViewController {
                                    let activityViewController = UIActivityViewController(
                                        activityItems: [message.content],
                                        applicationActivities: nil
                                    )
                                    rootViewController.present(activityViewController, animated: true)
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 14))
                                    Text("Share...")
                                        .font(.system(size: 14))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                            }
                        }
                        .transition(.opacity.combined(with: .scale))
                    }
                }
            }
            } // End of VStack
        } // End of ZStack
    }
}

// Helper extension to check block type
extension ContentBlock {
    var isTextBlock: Bool {
        switch self {
        case .text(_):
            return true
        case .unknown:
            return false
        default:
            return false
        }
    }
}


#Preview {
    ChatView()
}
