//
//  ChatView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @State private var messageText = ""
    @State private var hasInitiallyLoaded = false
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var claudeService = ClaudeCodeService.shared
    @Environment(\.modelContext) private var modelContext
    @State private var showingMCPServers = false
    
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
                    ScrollViewReader { proxy in
                        VStack(spacing: 0) {
                            // Loading indicator for session recovery
                            if viewModel.isLoadingPreviousSession {
                                HStack {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                    Text("Checking for previous session...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding()
                            }
                            
                            // Messages List
                            ScrollView {
                                VStack(spacing: 12) {  // Changed from LazyVStack to VStack for accurate height calculation
                                    ForEach(viewModel.messages) { message in
                                        MessageBubble(
                                            message: message, 
                                            isStreaming: viewModel.streamingMessage?.id == message.id,
                                            streamingBlocks: viewModel.streamingMessage?.id == message.id ? viewModel.streamingBlocks : []
                                        )
                                        .id(message.id)
                                    }
                                    
                                    // Show streaming indicator if processing and no completed session
                                    if viewModel.isProcessing && viewModel.streamingMessage != nil {
                                        // Double-check that the last message doesn't have a completed session
                                        let lastMessage = viewModel.messages.last
                                        let hasCompletedSession = lastMessage?.structuredMessages?.contains { $0.type == "result" } ?? false
                                        
                                        if !hasCompletedSession {
                                            HStack {
                                                ProgressView()
                                                    .progressViewStyle(CircularProgressViewStyle())
                                                    .scaleEffect(0.8)
                                                Text(viewModel.showActiveSessionIndicator ? 
                                                     "Claude is still processing..." : 
                                                     "Claude is thinking...")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.vertical, 8)
                                            .id("streaming-indicator")
                                        }
                                    }
                                }
                                .padding()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Dismiss keyboard when tapping on the chat area
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            }
                            .onChange(of: viewModel.messages.count) { oldValue, newValue in
                                // Skip scrolling on initial load (when oldValue is 0 and we're loading existing messages)
                                if oldValue == 0 && !hasInitiallyLoaded {
                                    hasInitiallyLoaded = true
                                    if newValue > 1 {
                                        return
                                    }
                                }
                                
                                // Only scroll for new messages (single message additions)
                                if newValue > oldValue {
                                    // Add multiple attempts to ensure content is fully rendered
                                    Task {
                                        // First attempt - quick scroll for immediate feedback
                                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                                        await MainActor.run {
                                            if let lastMessage = viewModel.messages.last {
                                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                            }
                                        }
                                        
                                        // Second attempt - after content should be rendered
                                        try? await Task.sleep(nanoseconds: 400_000_000) // 0.4 seconds more
                                        await MainActor.run {
                                            if let lastMessage = viewModel.messages.last {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            // Re-enable streaming content scroll triggers for Claude's responses
                            .onChange(of: viewModel.streamingBlocks.count) { oldValue, newValue in
                                if newValue > oldValue && viewModel.isProcessing {
                                    Task {
                                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                                        await MainActor.run {
                                            if let lastMessage = viewModel.messages.last {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            // Scroll when streaming message gets final content
                            .onChange(of: viewModel.streamingMessage?.structuredMessages?.count) { oldValue, newValue in
                                if let newValue = newValue, let oldValue = oldValue, newValue > oldValue {
                                    Task {
                                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                                        await MainActor.run {
                                            if let lastMessage = viewModel.messages.last {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            // Also scroll when processing state changes (Claude starts/stops responding)
                            .onChange(of: viewModel.isProcessing) { oldValue, newValue in
                                if newValue {
                                    // Claude started responding, ensure we're scrolled to bottom
                                    Task {
                                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                                        await MainActor.run {
                                            if let lastMessage = viewModel.messages.last {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                                if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                                    // Always scroll to bottom when keyboard appears to keep latest message visible
                                    Task {
                                        // Small delay to let keyboard animation start
                                        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                                        await MainActor.run {
                                            if let lastMessage = viewModel.messages.last {
                                                withAnimation(.easeOut(duration: 0.25)) {
                                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                                
                        
                        Divider()
                        
                        // Input Bar
                        HStack(spacing: 12) {
                            TextField("Ask Claude...", text: $messageText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...5)
                                .autocapitalization(.none)
                                .autocorrectionDisabled(true)
                                .onSubmit {
                                    sendMessage(proxy: proxy)
                                }
                            
                            Button {
                                sendMessage(proxy: proxy)
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.blue)
                            }
                            .disabled(messageText.isEmpty)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        }
                    }
                }
            }
            .navigationTitle("Claude Chat")
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
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
        .task {
            // Configure viewModel with current project
            if let project = projectContext.activeProject {
                viewModel.configure(modelContext: modelContext, projectId: project.id)
            }
        }
        .onAppear {
            // Re-check Claude installation when view appears
            Task {
                if let server = projectContext.activeServer {
                    // Only check if we don't have a cached status or if it was not installed
                    if claudeService.claudeInstallationStatus[server.id] == nil || 
                       claudeService.claudeInstallationStatus[server.id] == false {
                        await claudeService.checkClaudeInstallation(for: server)
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
            // Reset initial load flag when switching projects
            hasInitiallyLoaded = false
            // Update viewModel when project changes
            if let project = newValue {
                viewModel.configure(modelContext: modelContext, projectId: project.id)
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
    }
    
    private func sendMessage(proxy: ScrollViewProxy) {
        guard !messageText.isEmpty else { return }
        
        let text = messageText
        messageText = ""
        
        // Don't dismiss keyboard - user might want to continue typing
        
        Task {
            await viewModel.sendMessage(text)
            // The onChange handler will handle scrolling automatically
        }
    }
    
    private func clearChat() {
        viewModel.clearChat()
    }
}

struct MessageBubble: View {
    let message: Message
    let isStreaming: Bool
    let streamingBlocks: [ContentBlock]
    
    var body: some View {
        // Check if message has visible content
        let hasStructuredContent = (message.structuredMessages?.isEmpty == false) || 
                                 (message.structuredContent != nil)
        let hasVisibleContent = !message.content.isEmpty || 
                              hasStructuredContent || 
                              isStreaming
        
        if hasVisibleContent {
            VStack(spacing: 4) {
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
        }
    }
    
    @ViewBuilder
    private var messageContent: some View {
        // Check if this is the streaming message
        if isStreaming {
            // First check if we have structured messages available
            if let messages = message.structuredMessages, !messages.isEmpty {
                // Use the same rendering as final messages
                // Group messages by type
                let assistantMessages = messages.filter { $0.type == "assistant" }
                let systemMessages = messages.filter { $0.type == "system" }
                let resultMessages = messages.filter { $0.type == "result" }
                let userMessages = messages.filter { $0.type == "user" }
                
                VStack(spacing: 8) {
                    // Show system messages
                    ForEach(Array(systemMessages.enumerated()), id: \.offset) { _, msg in
                        SystemMessageView(message: msg)
                    }
                    
                    // Show user or assistant messages (should be one type per Message object)
                    if !assistantMessages.isEmpty {
                        StructuredMessageBubble(message: message, structuredMessages: assistantMessages)
                    } else if !userMessages.isEmpty {
                        StructuredMessageBubble(message: message, structuredMessages: userMessages)
                    }
                    
                    // Show result messages
                    ForEach(Array(resultMessages.enumerated()), id: \.offset) { _, msg in
                        ResultMessageView(message: msg)
                    }
                }
            } else if !streamingBlocks.isEmpty {
                // Fallback to streaming blocks if no structured messages yet
                VStack(spacing: 8) {
                    ForEach(0..<streamingBlocks.count, id: \.self) { index in
                        let block = streamingBlocks[index]
                        HStack {
                            if message.role == MessageRole.user {
                                Spacer()
                            }
                            
                            // Different styling for different block types
                            switch block {
                            case .text(let textBlock):
                                // Text blocks get the traditional bubble styling
                                TextBlockView(textBlock: textBlock, textColor: message.role == MessageRole.user ? .white : .primary, isStreaming: true)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(message.role == MessageRole.user ? Color.blue : Color(.systemGray5))
                                    .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 20))
                                    .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                                    .transition(.opacity)
                                    .animation(.easeIn(duration: 0.2), value: streamingBlocks.count)
                                
                            case .toolUse(_), .toolResult(_):
                                // Tool use and results get their own special styling
                                ContentBlockView(
                                    block: block, 
                                    textColor: .primary,
                                    isStreaming: true
                                )
                                .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
                                .transition(.opacity)
                                .animation(.easeIn(duration: 0.2), value: streamingBlocks.count)
                            }
                            
                            if message.role == MessageRole.assistant && block.isTextBlock {
                                Spacer()
                            }
                        }
                    }
                }
            }
        } else {
        // Check if we have structured messages array
        if let messages = message.structuredMessages, !messages.isEmpty {
            // Group messages by type
            let assistantMessages = messages.filter { $0.type == "assistant" }
            let systemMessages = messages.filter { $0.type == "system" }
            let resultMessages = messages.filter { $0.type == "result" }
            let userMessages = messages.filter { $0.type == "user" }
            
            VStack(spacing: 8) {
                // Show system messages
                ForEach(Array(systemMessages.enumerated()), id: \.offset) { _, msg in
                    SystemMessageView(message: msg)
                }
                
                // Show user or assistant messages (should be one type per Message object)
                if !assistantMessages.isEmpty {
                    StructuredMessageBubble(message: message, structuredMessages: assistantMessages)
                } else if !userMessages.isEmpty {
                    StructuredMessageBubble(message: message, structuredMessages: userMessages)
                }
                
                // Show result messages
                ForEach(Array(resultMessages.enumerated()), id: \.offset) { _, msg in
                    ResultMessageView(message: msg)
                }
            }
        } else if let structured = message.structuredContent {
            // Legacy single message support
            switch structured.type {
            case "system":
                SystemMessageView(message: structured)
            case "result":
                ResultMessageView(message: structured)
            case "user", "assistant":
                StructuredMessageBubble(message: message, structuredMessages: [structured])
            default:
                // Fallback to plain text
                PlainMessageBubble(message: message)
            }
        } else {
            // Fallback to plain text for messages without structured content
            PlainMessageBubble(message: message)
        }
        }
    }
}

struct PlainMessageBubble: View {
    let message: Message
    @State private var showActionButtons = false
    
    var body: some View {
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
                    Text(message.content)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(message.role == MessageRole.user ? Color.blue : Color(.systemGray5))
                        .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
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
                
                if !allBlocks.isEmpty {
                // Display each block as a separate bubble
                ForEach(Array(allBlocks.enumerated()), id: \.offset) { index, block in
                    HStack {
                        if message.role == MessageRole.user {
                            Spacer()
                        }
                        
                        // Different styling for different block types
                        switch block {
                        case .text(let textBlock):
                            // Text blocks get the traditional bubble styling
                            TextBlockView(textBlock: textBlock, textColor: message.role == MessageRole.user ? .white : .primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(message.role == MessageRole.user ? Color.blue : Color(.systemGray5))
                                .foregroundColor(message.role == MessageRole.user ? .white : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .frame(maxWidth: UIScreen.main.bounds.width * 0.8, alignment: message.role == MessageRole.user ? .trailing : .leading)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showActionButtons.toggle()
                                    }
                                }
                            
                        case .toolUse(_), .toolResult(_):
                            // Tool use and results get their own special styling
                            ContentBlockView(
                                block: block, 
                                textColor: .primary
                            )
                            .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
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
                                let textContent = allBlocks.compactMap { block -> String? in
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
                                let textContent = allBlocks.compactMap { block -> String? in
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
                            .background(message.role == MessageRole.user ? Color.blue : Color(.systemGray5))
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
        default:
            return false
        }
    }
}


#Preview {
    ChatView()
}