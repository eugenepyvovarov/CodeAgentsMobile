//
//  EditMCPServerSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Sheet for editing an existing MCP server
//

import SwiftUI

struct EditMCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mcpService = MCPService.shared
    
    let project: RemoteProject
    let server: MCPServer
    let onEdit: () -> Void
    
    // Form fields
    @State private var serverName: String
    @State private var serverType: ServerType
    @State private var command: String
    @State private var url: String
    @State private var args: [String]
    @State private var newArg = ""
    @State private var envVars: [EnvVar] = []
    @State private var headers: [HeaderVar] = []
    @State private var scope: MCPServer.MCPScope = .project
    
    // UI state
    @State private var isEditing = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isLoadingDetails = true
    @State private var originalScope: MCPServer.MCPScope = .project
    
    // Store original name for edit operation
    private let originalName: String
    
    enum ServerType: String, CaseIterable {
        case local = "Local Server"
        case remote = "Remote Server"
        
        var icon: String {
            switch self {
            case .local:
                return "terminal"
            case .remote:
                return "network"
            }
        }
        
        var description: String {
            switch self {
            case .local:
                return "Run a command on the server"
            case .remote:
                return "Connect to a remote MCP endpoint"
            }
        }
    }
    
    struct EnvVar: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }
    
    struct HeaderVar: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }
    
    init(project: RemoteProject, server: MCPServer, onEdit: @escaping () -> Void) {
        self.project = project
        self.server = server
        self.onEdit = onEdit
        self.originalName = server.name
        
        // Initialize state from server
        self._serverName = State(initialValue: server.name)
        self._serverType = State(initialValue: server.isRemote ? .remote : .local)
        self._command = State(initialValue: server.command ?? "")
        self._url = State(initialValue: server.url ?? "")
        self._args = State(initialValue: server.args ?? [])
        
        // Convert env dict to array
        if let env = server.env {
            self._envVars = State(initialValue: env.map { EnvVar(key: $0.key, value: $0.value) })
        }
        
        // Convert headers dict to array
        if let headers = server.headers {
            self._headers = State(initialValue: headers.map { HeaderVar(key: $0.key, value: $0.value) })
        }
    }
    
    private var isValid: Bool {
        if serverType == .local {
            return !serverName.isEmpty && !command.isEmpty
        } else {
            return !serverName.isEmpty && !url.isEmpty
        }
    }
    
    private var hasChanges: Bool {
        // Check if any values have changed
        if serverName != originalName { return true }
        if serverType != (server.isRemote ? .remote : .local) { return true }
        if serverType == .local {
            if command != (server.command ?? "") { return true }
            if args != (server.args ?? []) { return true }
            if envVarsDict != (server.env ?? [:]) { return true }
        } else {
            if url != (server.url ?? "") { return true }
            if headersDict != (server.headers ?? [:]) { return true }
        }
        return false
    }
    
    private var envVarsDict: [String: String] {
        Dictionary(uniqueKeysWithValues: envVars.filter { !$0.key.isEmpty && !$0.value.isEmpty }.map { ($0.key, $0.value) })
    }
    
    private var headersDict: [String: String] {
        Dictionary(uniqueKeysWithValues: headers.filter { !$0.key.isEmpty && !$0.value.isEmpty }.map { ($0.key, $0.value) })
    }
    
    private var generatedCommand: String {
        let editedServer: MCPServer
        
        if serverType == .local {
            // Parse command if it contains spaces
            let (parsedCommand, parsedArgs) = parseCommand(command)
            
            // Combine parsed args with manually added args
            var finalArgs = parsedArgs
            finalArgs.append(contentsOf: args)
            
            editedServer = MCPServer(
                name: serverName,
                command: parsedCommand,
                args: finalArgs.isEmpty ? nil : finalArgs,
                env: envVars.isEmpty ? nil : envVarsDict,
                url: nil,
                headers: nil
            )
        } else {
            editedServer = MCPServer(
                name: serverName,
                command: nil,
                args: nil,
                env: nil,
                url: url,
                headers: headers.isEmpty ? nil : headersDict
            )
        }
        
        return editedServer.generateAddJsonCommand(scope: scope) ?? "Invalid configuration"
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Server Type") {
                    Picker("Type", selection: $serverType) {
                        ForEach(ServerType.allCases, id: \.self) { type in
                            Label(type.rawValue, systemImage: type.icon)
                                .tag(type)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .disabled(true) // Can't change type when editing
                    
                    if serverType != (server.isRemote ? .remote : .local) {
                        Text("Server type cannot be changed")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                
                Section("Server Configuration") {
                    TextField("Server Name", text: $serverName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    if serverType == .local {
                        TextField("Command", text: $command)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                        
                        Text("Example: npx -y @modelcontextprotocol/server-filesystem")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        TextField("Server URL", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        
                        Text("Example: https://api.example.com/mcp")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if serverType == .local {
                    Section("Arguments") {
                        ForEach(args.indices, id: \.self) { index in
                            HStack {
                                TextField("Argument \(index + 1)", text: $args[index])
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.system(.body, design: .monospaced))
                                
                                Button {
                                    args.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        
                        HStack {
                            TextField("New argument", text: $newArg)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.body, design: .monospaced))
                            
                            Button {
                                if !newArg.isEmpty {
                                    args.append(newArg)
                                    newArg = ""
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                            }
                            .disabled(newArg.isEmpty)
                        }
                    }
                    
                    Section("Environment Variables") {
                        ForEach($envVars) { $envVar in
                            HStack {
                                TextField("Key", text: $envVar.key)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.system(.body, design: .monospaced))
                                
                                Text("=")
                                
                                TextField("Value", text: $envVar.value)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.system(.body, design: .monospaced))
                                
                                Button {
                                    envVars.removeAll { $0.id == envVar.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        
                        Button {
                            envVars.append(EnvVar(key: "", value: ""))
                        } label: {
                            Label("Add Environment Variable", systemImage: "plus.circle")
                        }
                    }
                } else {
                    // Remote server headers section
                    Section("Headers") {
                        ForEach($headers) { $header in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("Header Name", text: $header.key)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .font(.system(.caption, design: .monospaced))
                                    
                                    Spacer()
                                    
                                    Button {
                                        headers.removeAll { $0.id == header.id }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red)
                                    }
                                }
                                
                                TextField("Value", text: $header.value)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(3)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                            .padding(.vertical, 4)
                        }
                        
                        Button {
                            headers.append(HeaderVar(key: "", value: ""))
                        } label: {
                            Label("Add Header", systemImage: "plus.circle")
                        }
                        
                        Text("Example: Authorization: Bearer YOUR_TOKEN")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if isValid && hasChanges {
                    Section("Preview") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The server will be removed and re-added with new configuration:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text(generatedCommand)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                        }
                    }
                }
            }
            .navigationTitle("Edit MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        editServer()
                    }
                    .disabled(!isValid || !hasChanges || isEditing)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
            .task {
                await loadServerDetails()
            }
            .overlay {
                if isLoadingDetails {
                    ZStack {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                        
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Loading server details...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(radius: 10)
                    }
                }
            }
        }
    }
    
    private func loadServerDetails() async {
        isLoadingDetails = true
        
        do {
            if let details = try await mcpService.getServerDetails(named: originalName, for: project) {
                let (detailedServer, serverScope) = details
                
                // Update all fields with the detailed information
                await MainActor.run {
                    serverName = detailedServer.name
                    serverType = detailedServer.isRemote ? .remote : .local
                    originalScope = serverScope
                    scope = serverScope
                    
                    if detailedServer.isRemote {
                        url = detailedServer.url ?? ""
                        if let serverHeaders = detailedServer.headers {
                            headers = serverHeaders.map { HeaderVar(key: $0.key, value: $0.value) }
                        }
                    } else {
                        command = detailedServer.command ?? ""
                        args = detailedServer.args ?? []
                        if let serverEnv = detailedServer.env {
                            envVars = serverEnv.map { EnvVar(key: $0.key, value: $0.value) }
                        }
                    }
                    
                    isLoadingDetails = false
                }
            } else {
                // Server not found or error getting details
                await MainActor.run {
                    errorMessage = "Could not load server details. Using basic information."
                    showError = true
                    isLoadingDetails = false
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load server details: \(error.localizedDescription)"
                showError = true
                isLoadingDetails = false
            }
        }
    }
    
    private func editServer() {
        isEditing = true
        
        Task {
            do {
                let editedServer: MCPServer
                
                if serverType == .local {
                    // Parse command if it contains spaces
                    let (parsedCommand, parsedArgs) = parseCommand(command)
                    
                    // Combine parsed args with manually added args
                    var finalArgs = parsedArgs
                    finalArgs.append(contentsOf: args)
                    
                    editedServer = MCPServer(
                        name: serverName,
                        command: parsedCommand,
                        args: finalArgs.isEmpty ? nil : finalArgs,
                        env: envVars.isEmpty ? nil : envVarsDict,
                        url: nil,
                        headers: nil
                    )
                } else {
                    editedServer = MCPServer(
                        name: serverName,
                        command: nil,
                        args: nil,
                        env: nil,
                        url: url,
                        headers: headers.isEmpty ? nil : headersDict
                    )
                }
                
                try await mcpService.editServer(
                    oldName: originalName,
                    newServer: editedServer,
                    scope: scope,  // Use the scope selected by user (which defaults to originalScope)
                    for: project
                )
                
                await MainActor.run {
                    onEdit()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isEditing = false
                }
            }
        }
    }
    
    /// Parse a command string into command and arguments
    /// Example: "npx -y firecrawl-mcp" -> ("npx", ["-y", "firecrawl-mcp"])
    private func parseCommand(_ commandString: String) -> (command: String, args: [String]) {
        let trimmed = commandString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", []) }
        
        // Simple parsing - split by spaces
        // TODO: Handle quoted arguments properly
        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        guard !parts.isEmpty else { return ("", []) }
        
        let command = parts[0]
        let args = Array(parts.dropFirst())
        
        return (command, args)
    }
}

#Preview {
    EditMCPServerSheet(
        project: RemoteProject(name: "Test Project", serverId: UUID()),
        server: MCPServer(
            name: "test-server",
            command: "npx",
            args: [],
            env: ["API_KEY": "test"],
            url: nil,
            headers: nil
        ),
        onEdit: { }
    )
}