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
    @State private var showInstallLog = false

    private var isBusy: Bool {
        isChecking || isInstalling
    }

    var body: some View {
        Section {
            statusRow

            if let status, !status.message.isEmpty {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            authFields
            authActions
            installButton

            if !outputLines.isEmpty {
                installLog
            }
        } header: {
            Text("OpenCode")
        } footer: {
            Text("OpenCode runs at 127.0.0.1:4096. Install/repair uses sudo and configures password auth when credentials are available.")
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

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 12) {
            statusChip

            Spacer(minLength: 0)

            Button {
                Task { await checkStatus() }
            } label: {
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Check", systemImage: "stethoscope")
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
            .accessibilityIdentifier("opencode-server-check-button")
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusChip: some View {
        let content = HStack(spacing: 6) {
            Image(systemName: statusIconName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .imageScale(.small)

            Text(statusLabel)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)

        if #available(iOS 26, *) {
            content
                .glassEffect(.regular.tint(statusColor.opacity(0.18)), in: .capsule)
        } else {
            content
                .background(statusColor.opacity(0.14), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(statusColor.opacity(0.28), lineWidth: 1)
                }
        }
    }

    // MARK: - Auth

    private var authFields: some View {
        Group {
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.username)
                .accessibilityIdentifier("opencode-server-username-field")

            SecureField(
                hasStoredCredentials ? "New Password (optional)" : "Password",
                text: $password
            )
            .textContentType(.password)
            .accessibilityIdentifier("opencode-server-password-field")

            if hasStoredCredentials && password.isEmpty {
                Label("Password stored on this device", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var authActions: some View {
        HStack(spacing: 12) {
            Button {
                saveCredentials()
            } label: {
                Label("Save Auth", systemImage: "key.fill")
            }
            .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            .accessibilityIdentifier("opencode-server-save-auth-button")

            Spacer(minLength: 0)

            Button(role: .destructive) {
                clearCredentials()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled((!hasStoredCredentials && password.isEmpty) || isBusy)
            .accessibilityIdentifier("opencode-server-clear-auth-button")
        }
    }

    // MARK: - Install

    private var installButton: some View {
        Button {
            Task { await installOrRepair() }
        } label: {
            HStack {
                if isInstalling {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                } else {
                    Label("Install or Repair", systemImage: "arrow.down.circle")
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(isBusy)
        .accessibilityIdentifier("opencode-server-install-button")
    }

    private var installLog: some View {
        DisclosureGroup(isExpanded: $showInstallLog) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(outputLines.suffix(8), id: \.self) { line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Install log", systemImage: "doc.text")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status helpers

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
            return "lock.circle.fill"
        case .notInstalled:
            return "arrow.down.circle.fill"
        case .notRunning:
            return "pause.circle.fill"
        case .daemonUnavailable:
            return "antenna.radiowaves.left.and.right.slash"
        case .unreachable, .sshUnavailable:
            return "xmark.circle.fill"
        case .unknown, nil:
            return "questionmark.circle.fill"
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

    // MARK: - Actions

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
        defer { isChecking = false }
        status = await OpenCodeInstallerService.shared.checkRuntimeStatus(on: server)
    }

    @MainActor
    private func installOrRepair() async {
        isInstalling = true
        outputLines = []
        showInstallLog = true
        defer { isInstalling = false }

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
