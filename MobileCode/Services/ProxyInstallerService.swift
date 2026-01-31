//
//  ProxyInstallerService.swift
//  CodeAgentsMobile
//
//  Purpose: Install and manage the Claude proxy on a remote server.
//

import Foundation
import Security

final class ProxyInstallerService {
    static let shared = ProxyInstallerService()

    private let installScriptURL = "https://raw.githubusercontent.com/eugenepyvovarov/codeagents-server-cc-proxy/HEAD/install.sh"
    private let proxyEnvPath = "/etc/claude-proxy.env"
    private let managedHeader = "# Managed by CodeAgentsMobile"

    private init() {}

    func installProxy(on server: Server, onOutput: @escaping (String) -> Void) async throws {
        let session = try await SSHService.shared.connect(to: server, purpose: .proxyInstall)
        defer {
            session.disconnect()
        }

        let command = "set -o pipefail; curl -fsSL \(installScriptURL) | sudo -n bash"
        let process = try await session.startProcess(command)
        let lineBuffer = LineBuffer()
        var lastErrorLine: String?

        do {
            for try await chunk in process.outputStream() {
                let lines = lineBuffer.addData(chunk)
                for line in lines {
                    if line.contains("status=error") {
                        lastErrorLine = line
                    }
                    onOutput(line)
                }
            }
        } catch {
            throw ProxyInstallerError.processFailed(error.localizedDescription)
        }

        if let trailing = lineBuffer.flush() {
            if trailing.contains("status=error") {
                lastErrorLine = trailing
            }
            onOutput(trailing)
        }

        if let lastErrorLine = lastErrorLine {
            throw ProxyInstallerError.installFailed(lastErrorLine)
        }

        do {
            _ = try await session.execute("curl -fsS http://127.0.0.1:8787/healthz")
        } catch {
            throw ProxyInstallerError.healthCheckFailed(error.localizedDescription)
        }

        let providerConfiguration = ClaudeProviderConfigurationStore.load()
        let provider = providerConfiguration.selectedProvider
        let authMethod = await activeAuthMethod(for: provider)
        if hasCredentials(for: provider, authMethod: authMethod) {
            onOutput("Configuring proxy settings...")
            do {
                try await configureProxyConfiguration(on: server, session: session)
                onOutput("Proxy settings configured.")
            } catch {
                throw ProxyInstallerError.credentialSyncFailed(error.localizedDescription)
            }
        }
    }

    func syncProxyCredentials(on servers: [Server]) async {
        await syncProxyConfiguration(on: servers)
    }

    func syncProxyConfiguration(on servers: [Server]) async {
        let providerConfiguration = ClaudeProviderConfigurationStore.load()
        let provider = providerConfiguration.selectedProvider
        let authMethod = await activeAuthMethod(for: provider)
        guard hasCredentials(for: provider, authMethod: authMethod) else {
            SSHLogger.log("Skipping proxy configuration sync: missing credentials", level: .warning)
            return
        }

        for server in servers {
            do {
                try await configureProxyConfiguration(on: server, authMethod: authMethod)
                SSHLogger.log("Proxy configuration synced for \(server.name)", level: .info)
            } catch {
                SSHLogger.log("Failed to sync proxy configuration for \(server.name): \(error)", level: .warning)
            }
        }
    }

    private func activeAuthMethod(for provider: ClaudeModelProvider) async -> ClaudeAuthMethod {
        if provider == .anthropic {
            return await ClaudeCodeService.shared.getCurrentAuthMethod()
        }
        return .apiKey
    }

    private func hasCredentials(for provider: ClaudeModelProvider, authMethod: ClaudeAuthMethod) -> Bool {
        if provider == .anthropic {
            switch authMethod {
            case .apiKey:
                return KeychainManager.shared.hasAPIKey(provider: .anthropic)
            case .token:
                return KeychainManager.shared.hasAuthToken()
            }
        }

        return KeychainManager.shared.hasAPIKey(provider: provider)
    }

    private func configureProxyConfiguration(
        on server: Server,
        session: SSHSession? = nil,
        authMethod: ClaudeAuthMethod? = nil
    ) async throws {
        let providerConfiguration = ClaudeProviderConfigurationStore.load()
        let provider = providerConfiguration.selectedProvider

        let method: ClaudeAuthMethod
        if provider == .anthropic {
            if let authMethod {
                method = authMethod
            } else {
                method = await ClaudeCodeService.shared.getCurrentAuthMethod()
            }
        } else {
            method = .apiKey
        }

        let delta = try buildProxyEnvDelta(
            provider: provider,
            overrides: ClaudeProviderOverrides.defaults(for: provider),
            authMethod: method
        )

        let run = { (activeSession: SSHSession) async throws in
            let existing = try await self.fetchProxyEnvFile(using: activeSession)
            let merged = self.mergeEnvFile(existing: existing, upserts: delta.upserts, removals: delta.removals)
            try await self.writeProxyEnvFile(merged, verifyKeys: delta.verifyKeys, using: activeSession)
        }

        if let session {
            try await run(session)
        } else {
            let session = try await SSHService.shared.connect(to: server, purpose: .proxyInstall)
            defer { session.disconnect() }
            try await run(session)
        }
    }

    func enablePushNotifications(on server: Server) async throws -> String {
        let session = try await SSHService.shared.connect(to: server, purpose: .proxyInstall)
        defer { session.disconnect() }

        let existing = try await fetchProxyEnvFile(using: session)
        let parsed = parseEnvValues(from: existing)

        let existingSecret = parsed["CODEAGENTS_PUSH_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pushSecret = (existingSecret?.isEmpty == false) ? existingSecret! : try generatePushSecret()

        let gatewayBaseURL = try PushGatewayClient.functionsBaseURL().absoluteString

        let merged = mergeEnvFile(
            existing: existing,
            upserts: [
                "CODEAGENTS_PUSH_SECRET": pushSecret,
                "CODEAGENTS_PUSH_GATEWAY_BASE_URL": gatewayBaseURL
            ],
            removals: []
        )
        try await writeProxyEnvFile(
            merged,
            verifyKeys: ["CODEAGENTS_PUSH_SECRET", "CODEAGENTS_PUSH_GATEWAY_BASE_URL"],
            using: session
        )
        return pushSecret
    }

    private struct ProxyEnvDelta {
        let upserts: [String: String]
        let removals: [String]
        let verifyKeys: [String]
    }

    private func buildProxyEnvDelta(
        provider: ClaudeModelProvider,
        overrides: ClaudeProviderOverrides,
        authMethod: ClaudeAuthMethod
    ) throws -> ProxyEnvDelta {
        let (credentialKey, credentialValue) = try credentialEnv(provider: provider, authMethod: authMethod)

        var upserts: [String: String] = [
            credentialKey: credentialValue
        ]

        if !overrides.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            upserts["ANTHROPIC_BASE_URL"] = overrides.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if overrides.apiTimeoutMs > 0 {
            upserts["API_TIMEOUT_MS"] = String(overrides.apiTimeoutMs)
        }

        if !overrides.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            upserts["ANTHROPIC_MODEL"] = overrides.model.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !overrides.smallFastModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            upserts["ANTHROPIC_SMALL_FAST_MODEL"] = overrides.smallFastModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !overrides.defaultOpusModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            upserts["ANTHROPIC_DEFAULT_OPUS_MODEL"] = overrides.defaultOpusModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !overrides.defaultSonnetModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            upserts["ANTHROPIC_DEFAULT_SONNET_MODEL"] = overrides.defaultSonnetModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !overrides.defaultHaikuModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            upserts["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = overrides.defaultHaikuModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let managedKeys: [String] = [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "API_TIMEOUT_MS",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        ]

        let removals = managedKeys.filter { upserts[$0] == nil }

        var verifyKeys: [String] = [credentialKey]
        if upserts["ANTHROPIC_BASE_URL"] != nil {
            verifyKeys.append("ANTHROPIC_BASE_URL")
        }
        return ProxyEnvDelta(upserts: upserts, removals: removals, verifyKeys: Array(Set(verifyKeys)).sorted())
    }

    private func credentialEnv(
        provider: ClaudeModelProvider,
        authMethod: ClaudeAuthMethod
    ) throws -> (key: String, value: String) {
        if provider == .anthropic {
            switch authMethod {
            case .apiKey:
                let apiKey = try KeychainManager.shared.retrieveAPIKey(provider: .anthropic)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !apiKey.isEmpty else { throw ProxyInstallerError.missingCredentials }
                return (key: "ANTHROPIC_API_KEY", value: apiKey)
            case .token:
                let token = try KeychainManager.shared.retrieveAuthToken()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { throw ProxyInstallerError.missingCredentials }
                return (key: "CLAUDE_CODE_OAUTH_TOKEN", value: token)
            }
        }

        let token = try KeychainManager.shared.retrieveAPIKey(provider: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ProxyInstallerError.missingCredentials }
        return (key: "ANTHROPIC_AUTH_TOKEN", value: token)
    }

    private func fetchProxyEnvFile(using session: SSHSession) async throws -> String {
        let command = """
        set -e
        as_root() {
          if [ "$(id -u)" -eq 0 ]; then
            "$@"
          elif command -v sudo >/dev/null 2>&1; then
            sudo -n "$@"
          else
            echo "sudo not available for privileged proxy update" >&2
            exit 127
          fi
        }
        if as_root test -f \(proxyEnvPath); then
          as_root cat \(proxyEnvPath)
        fi
        """
        return try await runSensitiveCommandReturningOutput(command, using: session)
    }

    private func parseEnvValues(from content: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = String(trimmed[trimmed.index(after: eqIndex)...])
            values[String(key)] = value
        }
        return values
    }

    private func mergeEnvFile(existing: String, upserts: [String: String], removals: [String]) -> String {
        let removalSet = Set(removals)
        let existingLines = existing.trimmingCharacters(in: .newlines).isEmpty
            ? []
            : existing.components(separatedBy: CharacterSet.newlines)

        var outputLines: [String] = []
        var usedUpserts = Set<String>()
        var hasHeader = false

        for (index, rawLine) in existingLines.enumerated() {
            if index == 0 && rawLine.trimmingCharacters(in: .whitespacesAndNewlines) == managedHeader {
                hasHeader = true
            }

            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eqIndex = trimmed.firstIndex(of: "=") else {
                outputLines.append(rawLine)
                continue
            }

            let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                outputLines.append(rawLine)
                continue
            }

            if removalSet.contains(key) {
                continue
            }

            if let newValue = upserts[key] {
                outputLines.append("\(key)=\(newValue)")
                usedUpserts.insert(key)
                continue
            }

            outputLines.append(rawLine)
        }

        for key in upserts.keys.sorted() where !usedUpserts.contains(key) && !removalSet.contains(key) {
            if outputLines.last?.isEmpty == false {
                outputLines.append("")
            }
            outputLines.append("\(key)=\(upserts[key] ?? "")")
        }

        if !hasHeader {
            outputLines.insert(managedHeader, at: 0)
        }

        let normalized = outputLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return normalized + "\n"
    }

    private func writeProxyEnvFile(_ content: String, verifyKeys: [String], using session: SSHSession) async throws {
        let payload = Data(content.utf8).base64EncodedString()
        let verifySnippet = verifyKeys.map { "as_root grep -q '^" + $0 + "=' " + proxyEnvPath }.joined(separator: "\n")
        let fullCommand = """
        set -e
        as_root() {
          if [ "$(id -u)" -eq 0 ]; then
            "$@"
          elif command -v sudo >/dev/null 2>&1; then
            sudo -n "$@"
          else
            echo "sudo not available for privileged proxy update" >&2
            exit 127
          fi
        }
        decode_base64() {
          if base64 -d </dev/null >/dev/null 2>&1; then
            base64 -d
          else
            base64 -D
          fi
        }
        echo '\(payload)' | decode_base64 | as_root tee \(proxyEnvPath) >/dev/null
        as_root chmod 600 \(proxyEnvPath)
        as_root test -s \(proxyEnvPath)
        \(verifySnippet)
        if command -v supervisorctl >/dev/null 2>&1 && as_root supervisorctl status claude-proxy >/dev/null 2>&1; then
          as_root supervisorctl restart claude-proxy
        elif command -v systemctl >/dev/null 2>&1 && as_root systemctl list-unit-files | grep -q '^claude-agent-proxy\\.service'; then
          as_root systemctl restart claude-agent-proxy
        elif command -v launchctl >/dev/null 2>&1; then
          as_root launchctl kickstart -k system/com.codeagents.claude-proxy
        else
          echo "No service manager found for claude-proxy" >&2
          exit 1
        fi
        curl -fsS http://127.0.0.1:8787/healthz >/dev/null
        """

        try await runSensitiveCommand(fullCommand, using: session)
    }

    private func generatePushSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ProxyInstallerError.pushConfigFailed("Failed to generate random secret")
        }
        return Data(bytes).base64EncodedString()
    }

    private func runSensitiveCommand(_ command: String, using session: SSHSession) async throws {
        let previousLogLevel = SSHLogger.logLevel
        SSHLogger.logLevel = .warning
        defer { SSHLogger.logLevel = previousLogLevel }

        do {
            _ = try await session.execute(command)
        } catch {
            throw ProxyInstallerError.proxyEnvUpdateFailed(error.localizedDescription)
        }
    }

    private func runSensitiveCommandReturningOutput(_ command: String, using session: SSHSession) async throws -> String {
        let previousLogLevel = SSHLogger.logLevel
        SSHLogger.logLevel = .warning
        defer { SSHLogger.logLevel = previousLogLevel }

        do {
            return try await session.execute(command)
        } catch {
            throw ProxyInstallerError.proxyEnvUpdateFailed(error.localizedDescription)
        }
    }
}

enum ProxyInstallerError: LocalizedError {
    case installFailed(String)
    case healthCheckFailed(String)
    case processFailed(String)
    case credentialSyncFailed(String)
    case proxyEnvUpdateFailed(String)
    case pushConfigFailed(String)
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .installFailed(let line):
            return "Installer reported an error: \(line)"
        case .healthCheckFailed(let reason):
            return "Proxy health check failed: \(reason)"
        case .processFailed(let reason):
            return "Installer process failed: \(reason)"
        case .credentialSyncFailed(let reason):
            return "Proxy credential sync failed: \(reason)"
        case .proxyEnvUpdateFailed(let reason):
            return "Proxy environment update failed: \(reason)"
        case .pushConfigFailed(let reason):
            return "Proxy push configuration failed: \(reason)"
        case .missingCredentials:
            return "Claude credentials are missing in the app."
        }
    }
}
