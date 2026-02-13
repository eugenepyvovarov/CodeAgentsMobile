//
//  AddMCPServerSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Sheet for adding a new MCP server to a project
//

import SwiftUI

struct AddMCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mcpService = MCPService.shared
    
    let project: RemoteProject
    let onAdd: () -> Void
    
    // Form fields
    @State private var serverName = ""
    @State private var serverType: ServerType = .local
    @State private var command = ""
    @State private var url = ""
    @State private var args: [String] = []
    @State private var newArg = ""
    @State private var envVars: [EnvVar] = []
    @State private var headers: [HeaderVar] = []
    @State private var scope: MCPServer.MCPScope
    
    // UI state
    @State private var isAdding = false
    @State private var showError = false
    @State private var errorMessage = ""
    
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
    
    private var isValid: Bool {
        let normalizedName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if serverType == .local {
            return !normalizedName.isEmpty && !command.isEmpty && !managedNameConflict
        } else {
            return !normalizedName.isEmpty && !url.isEmpty && !managedNameConflict
        }
    }

    private var managedNameConflict: Bool {
        MCPServer.isManagedSchedulerServer(serverName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    private var generatedCommand: String {
        let normalizedName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let server: MCPServer
        
        if serverType == .local {
            // Parse command if it contains spaces
            let (parsedCommand, parsedArgs) = parseCommand(command)
            
            // Combine parsed args with manually added args
            var finalArgs = parsedArgs
            finalArgs.append(contentsOf: args)
            
            server = MCPServer(
                name: normalizedName,
                command: parsedCommand,
                args: finalArgs.isEmpty ? nil : finalArgs,
                env: envVars.isEmpty ? nil : Dictionary(uniqueKeysWithValues: envVars.map { ($0.key, $0.value) }),
                url: nil,
                headers: nil
            )
        } else {
            server = MCPServer(
                name: normalizedName,
                command: nil,
                args: nil,
                env: nil,
                url: url,
                headers: headers.isEmpty ? nil : Dictionary(uniqueKeysWithValues: headers.map { ($0.key, $0.value) })
            )
        }
        
        return server.generateAddJsonCommand(scope: scope) ?? "Invalid configuration"
    }
    
    init(project: RemoteProject, initialScope: MCPServer.MCPScope = .local, onAdd: @escaping () -> Void) {
        self.project = project
        self.onAdd = onAdd
        _scope = State(initialValue: initialScope)
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
                    
                    Text(serverType.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Example: npx -y @modelcontextprotocol/server-filesystem")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("Tip: Enter the full command here. It will be parsed automatically.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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
                    // Show parsed command info if command contains spaces
                    if command.contains(" ") {
                        Section("Parsed Command") {
                            let (parsedCmd, parsedArgs) = parseCommand(command)
                            HStack {
                                Text("Command:")
                                    .foregroundColor(.secondary)
                                Text(parsedCmd)
                                    .font(.system(.body, design: .monospaced))
                            }
                            
                            if !parsedArgs.isEmpty {
                                HStack(alignment: .top) {
                                    Text("Arguments:")
                                        .foregroundColor(.secondary)
                                    VStack(alignment: .leading) {
                                        ForEach(parsedArgs, id: \.self) { arg in
                                            Text(arg)
                                                .font(.system(.body, design: .monospaced))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    Section("Additional Arguments") {
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
                
                if isValid {
                    Section("Generated Command") {
                        Text(generatedCommand)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                    }
                }
            }
            .navigationTitle("Add MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addServer()
                    }
                    .disabled(!isValid || isAdding)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private func addServer() {
        guard !managedNameConflict else {
            errorMessage = "This server name is reserved for a managed server and cannot be used."
            showError = true
            return
        }

        isAdding = true
        
        Task {
            do {
                let normalizedName = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
                let server: MCPServer
                
                if serverType == .local {
                    // Clean up environment variables
                    let cleanedEnvVars = envVars.filter { !$0.key.isEmpty && !$0.value.isEmpty }
                    
                    // Parse command if it contains spaces
                    let (parsedCommand, parsedArgs) = parseCommand(command)
                    
                    // Combine parsed args with manually added args
                    var finalArgs = parsedArgs
                    finalArgs.append(contentsOf: args)
                    
                    server = MCPServer(
                        name: normalizedName,
                        command: parsedCommand,
                        args: finalArgs.isEmpty ? nil : finalArgs,
                        env: cleanedEnvVars.isEmpty ? nil : Dictionary(uniqueKeysWithValues: cleanedEnvVars.map { ($0.key, $0.value) }),
                        url: nil,
                        headers: nil
                    )
                } else {
                    // Clean up headers
                    let cleanedHeaders = headers.filter { !$0.key.isEmpty && !$0.value.isEmpty }
                    
                    server = MCPServer(
                        name: normalizedName,
                        command: nil,
                        args: nil,
                        env: nil,
                        url: url,
                        headers: cleanedHeaders.isEmpty ? nil : Dictionary(uniqueKeysWithValues: cleanedHeaders.map { ($0.key, $0.value) })
                    )
                }
                
                try await mcpService.addServer(server, scope: scope, for: project)
                
                await MainActor.run {
                    onAdd()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isAdding = false
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
    AddMCPServerSheet(
        project: RemoteProject(name: "Test Agent", serverId: UUID()),
        onAdd: { }
    )
}
