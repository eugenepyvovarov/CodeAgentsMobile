//
//  TerminalView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI



struct TerminalView: View {
    @State private var viewModel = TerminalViewModel()
    @State private var command = ""
    @State private var historyIndex = -1
    @FocusState private var isInputFocused: Bool
    @State private var showingSettings = false
    @StateObject private var projectContext = ProjectContext.shared
    
    var body: some View {
        NavigationStack {
            ConnectionRequiredView(
                title: "Terminal Requires Connection",
                message: "Connect to a server to use the terminal"
            ) {
                VStack(spacing: 0) {
                    // Terminal Output
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(viewModel.outputLines) { line in
                                    HStack(alignment: .top, spacing: 0) {
                                        Text(line.content)
                                            .font(.custom("SF Mono", size: 13))
                                            .foregroundColor(line.color)
                                            .textSelection(.enabled)
                                        
                                        Spacer(minLength: 0)
                                    }
                                    .id(line.id)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(Color(.systemBackground))
                        .onChange(of: viewModel.outputLines.count) { oldValue, newValue in
                            withAnimation {
                                if let lastLine = viewModel.outputLines.last {
                                    proxy.scrollTo(lastLine.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                    
                    Divider()
                        .background(Color.gray)
                    
                    // Command Input
                    HStack(spacing: 0) {
                        Text(viewModel.prompt)
                            .font(.custom("SF Mono", size: 13))
                            .foregroundColor(.green)
                        
                        TextField("", text: $command)
                            .font(.custom("SF Mono", size: 13))
                            .foregroundColor(.primary)
                            .textFieldStyle(.plain)
                            .focused($isInputFocused)
                            .onSubmit {
                                executeCommand()
                            }
                    }
                    .padding()
                    .background(Color(.systemBackground))
                }
                .background(Color(.systemBackground))
                .navigationTitle("Terminal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ConnectionStatusView()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 16) {
                            Menu {
                                Button {
                                    projectContext.clearActiveProject()
                                } label: {
                                    Label("Back to Projects", systemImage: "arrow.backward")
                                }
                                
                                Divider()
                                
                                Button {
                                    clearTerminal()
                                } label: {
                                    Label("Clear", systemImage: "clear")
                                }
                                
                                Button {
                                    killProcess()
                                } label: {
                                    Label("Kill Process", systemImage: "xmark.octagon")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            
                            Button {
                                showingSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                }
                .task {
                    await setupTerminal()
                }
            }
        }
        .onAppear {
            isInputFocused = true
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
            }
        }
    }
    
    private func setupTerminal() async {
        // Initialize terminal with connection info
        if let server = ConnectionManager.shared.activeServer {
            await viewModel.initializeForServer(server)
        }
    }
    
    private func executeCommand() {
        guard !command.isEmpty else { return }
        
        Task {
            await viewModel.execute(command)
        }
        
        // Update history navigation
        historyIndex = -1
        
        // Clear input
        command = ""
    }
    
    private func clearTerminal() {
        viewModel.clear()
    }
    
    private func killProcess() {
        viewModel.killProcess()
    }
    
    private func navigateHistory(direction: HistoryDirection) {
        guard !viewModel.commandHistory.isEmpty else { return }
        
        switch direction {
        case .up:
            if historyIndex == -1 {
                historyIndex = viewModel.commandHistory.count - 1
            } else if historyIndex > 0 {
                historyIndex -= 1
            }
            
        case .down:
            if historyIndex < viewModel.commandHistory.count - 1 {
                historyIndex += 1
            } else {
                historyIndex = -1
                command = ""
                return
            }
        }
        
        if historyIndex >= 0 && historyIndex < viewModel.commandHistory.count {
            command = viewModel.commandHistory[historyIndex]
        }
    }
    
    enum HistoryDirection {
        case up, down
    }
}

#Preview {
    TerminalView()
}