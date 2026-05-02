//
//  OpenCodeServerSetupSection.swift
//  CodeAgentsMobile
//
//  Purpose: OpenCode runtime setup controls for an existing SSH server.
//

import SwiftUI

struct OpenCodeServerSetupSection: View {
    let server: Server

    @State private var username = OpenCodeServerProvisioning.username
    @State private var password = ""
    @State private var hasStoredCredentials = false
    @State private var status: OpenCodeRuntimeSetupStatus?
    @State private var isChecking = false
    @State private var isInstalling = false
    @State private var outputLines: [String] = []
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        Section {
            HStack {
                Label("Status", systemImage: statusIconName)
                    .foregroundStyle(statusColor)
                Spacer()
                Text(statusLabel)
                    .foregroundColor(.secondary)
            }

            TextField("Server Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("opencode-server-username-field")

            SecureField(hasStoredCredentials ? "New Server Password" : "Server Password", text: $password)
                .accessibilityIdentifier("opencode-server-password-field")

            HStack {
                Button {
                    saveCredentials()
                } label: {
                    Label("Save Auth", systemImage: "key")
                }
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("opencode-server-save-auth-button")

                Spacer()

                Button(role: .destructive) {
                    clearCredentials()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .disabled(!hasStoredCredentials && password.isEmpty)
                .accessibilityIdentifier("opencode-server-clear-auth-button")
            }

            Button {
                Task {
                    await checkStatus()
                }
            } label: {
                HStack {
                    if isChecking {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Label(isChecking ? "Checking..." : "Check OpenCode", systemImage: "stethoscope")
                }
            }
            .disabled(isChecking || isInstalling)
            .accessibilityIdentifier("opencode-server-check-button")

            Button {
                Task {
                    await installOrRepair()
                }
            } label: {
                HStack {
                    if isInstalling {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Label(isInstalling ? "Installing..." : "Install or Repair OpenCode", systemImage: "arrow.down.circle")
                }
            }
            .disabled(isChecking || isInstalling)
            .accessibilityIdentifier("opencode-server-install-button")

            if let status {
                Text(status.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !outputLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outputLines.suffix(5), id: \.self) { line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("OpenCode Runtime")
        } footer: {
            Text("OpenCode runs at 127.0.0.1:4096. The CodeAgents daemon runs at 127.0.0.1:8787 for scheduled tasks and push. Install/repair uses sudo and configures password auth when credentials are available.")
                .font(.caption)
        }
        .task {
            loadStoredCredentials()
        }
        .alert("OpenCode Setup Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }

    private var statusLabel: String {
        guard let status else {
            return hasStoredCredentials ? "Auth Stored" : "Not Checked"
        }

        switch status.state {
        case .available:
            return "Ready"
        case .authRequired:
            return "Auth Required"
        case .notInstalled:
            return "Not Installed"
        case .notRunning:
            return "Not Running"
        case .daemonUnavailable:
            return "Daemon Missing"
        case .unreachable:
            return "Unreachable"
        case .sshUnavailable:
            return "SSH Failed"
        case .unknown:
            return "Unknown"
        }
    }

    private var statusIconName: String {
        switch status?.state {
        case .available:
            return "checkmark.circle.fill"
        case .authRequired:
            return "lock.circle"
        case .notInstalled:
            return "arrow.down.circle"
        case .notRunning:
            return "pause.circle"
        case .daemonUnavailable:
            return "antenna.radiowaves.left.and.right.slash"
        case .unreachable, .sshUnavailable:
            return "xmark.circle"
        case .unknown, nil:
            return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch status?.state {
        case .available:
            return .green
        case .authRequired, .notInstalled, .notRunning, .daemonUnavailable:
            return .orange
        case .unreachable, .sshUnavailable:
            return .red
        case .unknown, nil:
            return .secondary
        }
    }

    private func loadStoredCredentials() {
        username = (try? KeychainManager.shared.retrieveOpenCodeServerUsername(for: server.id))
            ?? OpenCodeServerProvisioning.username
        hasStoredCredentials = KeychainManager.shared.hasOpenCodeServerPassword(for: server.id)
    }

    private func saveCredentials() {
        do {
            let passwordToStore: String
            if password.isEmpty {
                passwordToStore = try KeychainManager.shared.retrieveOpenCodeServerPassword(for: server.id)
            } else {
                passwordToStore = password
            }

            try KeychainManager.shared.storeOpenCodeServerCredentials(
                username: username,
                password: passwordToStore,
                for: server.id
            )
            password = ""
            loadStoredCredentials()
            status = .unknown("OpenCode server authentication was saved. Check runtime status to verify it.")
        } catch {
            errorMessage = password.isEmpty
                ? "Enter an OpenCode server password before saving."
                : error.localizedDescription
            showError = true
        }
    }

    private func clearCredentials() {
        try? KeychainManager.shared.deleteOpenCodeServerCredentials(for: server.id)
        password = ""
        loadStoredCredentials()
        status = .unknown("OpenCode server authentication was cleared.")
    }

    @MainActor
    private func checkStatus() async {
        isChecking = true
        defer {
            isChecking = false
        }

        status = await OpenCodeInstallerService.shared.checkRuntimeStatus(on: server)
    }

    @MainActor
    private func installOrRepair() async {
        isInstalling = true
        outputLines = []
        defer {
            isInstalling = false
        }

        do {
            let installUsername = sanitizedUsername()
            let installPassword = try passwordForInstall()
            try KeychainManager.shared.storeOpenCodeServerCredentials(
                username: installUsername,
                password: installPassword,
                for: server.id
            )
            password = ""
            loadStoredCredentials()

            status = try await OpenCodeInstallerService.shared.installOrRepairRuntime(
                on: server,
                username: installUsername,
                password: installPassword
            ) { line in
                Task { @MainActor in
                    outputLines.append(line)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            status = .unknown(error.localizedDescription)
        }
    }

    private func sanitizedUsername() -> String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? OpenCodeServerProvisioning.username : trimmed
    }

    private func passwordForInstall() throws -> String {
        if !password.isEmpty {
            return password
        }

        if let stored = try? KeychainManager.shared.retrieveOpenCodeServerPassword(for: server.id) {
            return stored
        }

        return try OpenCodeServerPasswordGenerator.generate()
    }
}

#Preview {
    Form {
        OpenCodeServerSetupSection(server: Server(
            name: "Test Server",
            host: "example.com",
            port: 22,
            username: "user",
            authMethodType: "password"
        ))
    }
}
