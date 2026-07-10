//
//  OpenCodeServerProvisioning.swift
//  CodeAgentsMobile
//
//  Purpose: Shared OpenCode server provisioning constants and helpers.
//

import Foundation
import Security

enum OpenCodeServerProvisioning {
    static let host = "127.0.0.1"
    static let port = 4096
    static let username = "opencode"
    static let environmentFilePath = "/etc/opencode-server.env"
    static let serviceFilePath = "/etc/systemd/system/opencode.service"
    static let binaryPath = "/home/codeagent/.opencode/bin/opencode"

    static func serviceFile(host: String = Self.host, port: Int = Self.port) -> String {
        """
        [Unit]
        Description=OpenCode Server
        Wants=network-online.target
        After=network-online.target

        [Service]
        Type=simple
        User=codeagent
        Group=codeagent
        WorkingDirectory=/home/codeagent
        Environment=HOME=/home/codeagent
        Environment=XDG_CONFIG_HOME=/home/codeagent/.config
        EnvironmentFile=-\(environmentFilePath)
        ExecStart=\(binaryPath) serve --hostname \(host) --port \(port)
        Restart=always
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
        """
    }

    static func environmentFile(password: String?) -> String {
        var lines = [
            "# Managed by CodeAgentsMobile",
            "OPENCODE_SERVER_USERNAME=\(systemdEnvironmentValue(username))"
        ]

        if let password, !password.isEmpty {
            lines.append("OPENCODE_SERVER_PASSWORD=\(systemdEnvironmentValue(password))")
        }

        return lines.joined(separator: "\n")
    }

    /// Shared shell fragment: 2G swapfile + mild swappiness (OpenCode needs headroom on 1GB droplets).
    static var ensureSwapScript: String {
        """
        echo "Ensuring 2G swapfile for OpenCode headroom..."
        if ! swapon --show 2>/dev/null | grep -q .; then
          if [ ! -f /swapfile ]; then
            if command -v fallocate >/dev/null 2>&1; then
              fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            else
              dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            fi
            chmod 600 /swapfile
            mkswap /swapfile
          fi
          swapon /swapfile || true
          grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        if ! grep -q '^vm.swappiness=' /etc/sysctl.conf 2>/dev/null; then
          echo 'vm.swappiness=10' >> /etc/sysctl.conf
        fi
        sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
        """
    }

    /// Shared shell fragment: drop idle SSH clients so leaked mobile sessions do not pile up.
    /// Uses printf (not a heredoc) so cloud-init YAML indentation cannot break the terminator.
    static var ensureSSHClientAliveScript: String {
        """
        echo "Configuring sshd ClientAlive to prune dead mobile sessions..."
        mkdir -p /etc/ssh/sshd_config.d
        printf '%s\\n' 'ClientAliveInterval 30' 'ClientAliveCountMax 10' > /etc/ssh/sshd_config.d/99-codeagents-keepalive.conf
        if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
          echo "sshd reloaded with ClientAlive settings."
        else
          echo "WARNING: could not reload sshd; ClientAlive will apply on next sshd restart."
        fi
        """
    }

    static func runcmdScript(host: String = Self.host, port: Int = Self.port) -> String {
        """
        set -eu
        export DEBIAN_FRONTEND=noninteractive
        \(ensureSwapScript)
        \(ensureSSHClientAliveScript)
        echo "Refreshing apt package metadata..."
        if ! timeout --kill-after=10 180 apt-get -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 -o Acquire::Retries=2 update; then
          echo "WARNING: apt-get update did not complete; continuing with existing package indexes."
        fi
        echo "Ensuring provisioning dependencies..."
        if ! timeout --kill-after=10 180 apt-get -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 -o Acquire::Retries=2 install -y --no-install-recommends curl ca-certificates tar git; then
          echo "WARNING: dependency install did not complete; validating existing tools."
          command -v curl >/dev/null
          command -v tar >/dev/null
        fi
        mkdir -p /home/codeagent/projects
        chown -R codeagent:codeagent /home/codeagent
        echo "Installing OpenCode..."
        su - codeagent -c "bash -lc 'set -euo pipefail; curl --connect-timeout 20 --retry 3 --retry-delay 2 -fsSL https://opencode.ai/install | bash -s -- --no-modify-path'"
        systemctl daemon-reload
        systemctl enable --now opencode
        set -a
        . \(environmentFilePath)
        set +a
        opencode_ready=0
        attempt=1
        while [ "$attempt" -le 30 ]; do
          if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then
            if curl -fsS -u "${OPENCODE_SERVER_USERNAME:-opencode}:${OPENCODE_SERVER_PASSWORD}" http://\(host):\(port)/global/health >/tmp/opencode-health.json; then
              opencode_ready=1
              break
            fi
          else
            if curl -fsS http://\(host):\(port)/global/health >/tmp/opencode-health.json; then
              opencode_ready=1
              break
            fi
          fi
          sleep 2
          attempt=$((attempt + 1))
        done
        if [ "$opencode_ready" -ne 1 ]; then
          journalctl -u opencode --no-pager -n 80
          exit 1
        fi

        echo "Installing CodeAgents daemon..."
        if (
          timeout --kill-after=15 \(CodeAgentsDaemonProvisioning.installTimeoutSeconds) \(CodeAgentsDaemonProvisioning.installCommand())
          echo "Waiting for CodeAgents daemon health..."
          \(CodeAgentsDaemonProvisioning.waitForHealthScript(maxAttempts: 15))
        ); then
          echo "CodeAgents daemon is healthy."
        else
          echo "WARNING: CodeAgents daemon setup did not complete; foreground OpenCode chat is still available." >&2
          systemctl status \(CodeAgentsDaemonProvisioning.serviceName) --no-pager -l || true
          journalctl -u \(CodeAgentsDaemonProvisioning.serviceName) --no-pager -n 80 || true
        fi
        """
    }

    static func manualInstallScript(
        username: String = Self.username,
        password: String?,
        host: String = Self.host,
        port: Int = Self.port
    ) -> String {
        """
        set -euo pipefail
        \(ensureSwapScript)
        \(ensureSSHClientAliveScript)
        echo "Ensuring codeagent user..."
        if ! id -u codeagent >/dev/null 2>&1; then
          useradd -m -s /bin/bash codeagent
        fi
        mkdir -p /home/codeagent/projects
        chown -R codeagent:codeagent /home/codeagent

        echo "Writing OpenCode server environment..."
        cat > \(environmentFilePath) <<'OPENCODE_ENV'
        \(environmentFile(username: username, password: password))
        OPENCODE_ENV
        chmod 600 \(environmentFilePath)
        chown root:root \(environmentFilePath)

        echo "Installing or updating OpenCode..."
        su - codeagent -c "bash -lc 'set -euo pipefail; curl --connect-timeout 20 --retry 3 --retry-delay 2 -fsSL https://opencode.ai/install | bash -s -- --no-modify-path'"

        echo "Writing OpenCode systemd service..."
        cat > \(serviceFilePath) <<'OPENCODE_SERVICE'
        \(serviceFile(host: host, port: port))
        OPENCODE_SERVICE
        chmod 644 \(serviceFilePath)

        echo "Starting OpenCode service..."
        systemctl daemon-reload
        systemctl enable --now opencode
        systemctl restart opencode

        echo "Waiting for OpenCode health..."
        set -a
        . \(environmentFilePath)
        set +a
        opencode_ready=0
        attempt=1
        while [ "$attempt" -le 30 ]; do
          if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then
            if curl -fsS -u "${OPENCODE_SERVER_USERNAME:-opencode}:${OPENCODE_SERVER_PASSWORD}" http://\(host):\(port)/global/health >/tmp/opencode-health.json; then
              opencode_ready=1
              break
            fi
          else
            if curl -fsS http://\(host):\(port)/global/health >/tmp/opencode-health.json; then
              opencode_ready=1
              break
            fi
          fi
          sleep 2
          attempt=$((attempt + 1))
        done

        if [ "$opencode_ready" -ne 1 ]; then
          journalctl -u opencode --no-pager -n 80
          exit 1
        fi

        echo "Installing or updating CodeAgents daemon..."
        if ! (
          \(CodeAgentsDaemonProvisioning.installCommand())
          echo "Waiting for CodeAgents daemon health..."
          \(CodeAgentsDaemonProvisioning.waitForHealthScript(maxAttempts: 15))
        ); then
          echo "CodeAgents daemon setup failed; foreground OpenCode chat is still available." >&2
        fi
        """
    }

    static func environmentFile(username: String, password: String?) -> String {
        var lines = [
            "# Managed by CodeAgentsMobile",
            "OPENCODE_SERVER_USERNAME=\(systemdEnvironmentValue(username))"
        ]

        if let password, !password.isEmpty {
            lines.append("OPENCODE_SERVER_PASSWORD=\(systemdEnvironmentValue(password))")
        }

        return lines.joined(separator: "\n")
    }

    static func yamlBlock(_ content: String, indentation: Int) -> String {
        let prefix = String(repeating: " ", count: indentation)
        return content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(prefix)\($0)" }
            .joined(separator: "\n")
    }

    private static func systemdEnvironmentValue(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum CodeAgentsDaemonProvisioning {
    static let host = "127.0.0.1"
    static let port = 8787
    static let installTimeoutSeconds = 300
    static let repositoryOwner = "eugenepyvovarov"
    static let repositoryName = "codeagents-server-cc-proxy"
    static let repositoryURL = "https://github.com/\(repositoryOwner)/\(repositoryName).git"
    /// Immutable pin — bump intentionally when promoting a known-good daemon revision.
    static let pinnedInstallCommit = "2b6108daa8bac40dc205b332e10b9bb1c3ff2c24"
    static let installScriptURL = "https://raw.githubusercontent.com/\(repositoryOwner)/\(repositoryName)/\(pinnedInstallCommit)/install.sh"
    static let remoteHeadAPIURL = "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/commits/\(pinnedInstallCommit)"
    static let serviceName = "codeagents-daemon"
    static let installDirectory = "/opt/codeagents-daemon"
    static let dataDirectory = "/opt/codeagents-daemon/data"
    static let logDirectory = "/var/log/codeagents-daemon"
    static let environmentFilePath = "/etc/codeagents-daemon.env"
    static let legacyEnvironmentFilePath = "/etc/claude-proxy.env"
    /// Env key for the daemon HTTP bearer (shared with iOS Keychain per server).
    static let daemonTokenEnvKey = "CODEAGENTS_DAEMON_TOKEN"

    /// Parsed `/healthz` payload from the CodeAgents daemon.
    struct HealthSnapshot: Equatable {
        let status: String?
        let version: String?
        let startedAt: String?

        var isHealthy: Bool {
            let normalized = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "ok" || normalized == "healthy" || normalized == "up"
        }
    }

    static var healthURL: String {
        "http://\(host):\(port)/healthz"
    }

    /// Install/upgrade command. Cloud-init runs as root (`useSudo: false`);
    /// app SSH sessions use passwordless sudo (`useSudo: true`).
    static func installCommand(useSudo: Bool = false) -> String {
        let environment = [
            "INSTALL_DIR=\(installDirectory)",
            "DATA_DIR=\(dataDirectory)",
            "LOG_DIR=\(logDirectory)",
            "SERVICE_NAME=\(serviceName)",
            "INSTALL_CLAUDE_CLI=0"
        ].joined(separator: " ")
        let runner = useSudo
            ? "sudo -n env \(environment) bash"
            : "\(environment) bash"
        return "bash -lc 'set -euo pipefail; curl --connect-timeout 20 --retry 3 --retry-delay 2 -fsSL \(installScriptURL) | \(runner)'"
    }

    static func healthCheckCommand() -> String {
        "curl -fsS \(healthURL)"
    }

    /// Expected daemon revision for this app build (pinned; not live HEAD).
    static var expectedDaemonVersion: String { pinnedInstallCommit }

    /// Probe is retained for diagnostics; preferred path uses `expectedDaemonVersion`.
    /// Still targets the pinned commit object, never mutable HEAD.
    static func remoteHeadProbeCommand() -> String {
        """
        bash -lc 'set -euo pipefail
        printf "%s" "\(pinnedInstallCommit)"'
        """
    }

    static func restartCommand() -> String {
        """
        if command -v systemctl >/dev/null 2>&1; then
          sudo -n systemctl restart \(serviceName) 2>/dev/null \
            || sudo -n systemctl restart claude-proxy 2>/dev/null \
            || true
        fi
        if command -v supervisorctl >/dev/null 2>&1; then
          sudo -n supervisorctl restart \(serviceName) 2>/dev/null \
            || sudo -n supervisorctl restart claude-proxy 2>/dev/null \
            || true
        fi
        if command -v service >/dev/null 2>&1; then
          sudo -n service \(serviceName) restart 2>/dev/null || true
        fi
        """
    }

    static func waitForHealthScript(maxAttempts: Int = 30) -> String {
        """
        daemon_ready=0
        attempt=1
        while [ "$attempt" -le \(maxAttempts) ]; do
          if \(healthCheckCommand()) >/tmp/codeagents-daemon-health.json; then
            daemon_ready=1
            break
          fi
          sleep 2
          attempt=$((attempt + 1))
        done
        if [ "$daemon_ready" -ne 1 ]; then
          echo "CodeAgents daemon did not become healthy" >&2
          exit 1
        fi
        """
    }

    /// Parse daemon `/healthz` JSON for status/version.
    static func parseHealthz(_ raw: String) -> HealthSnapshot? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let status = stringValue(object["status"])
        let version = stringValue(object["version"])
        let startedAt = stringValue(object["started_at"]) ?? stringValue(object["startedAt"])
        if status == nil && version == nil && startedAt == nil {
            return nil
        }
        return HealthSnapshot(status: status, version: version, startedAt: startedAt)
    }

    /// Normalize a git SHA / version token for comparison.
    static func normalizeVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty, trimmed != "unknown" else { return nil }
        // Accept only hex-ish git SHAs (short or full).
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return trimmed
        }
        return trimmed
    }

    /// Match short/full SHAs (`7ce9caf` vs `7ce9cafabc...`).
    static func versionsMatch(installed: String?, expected: String?) -> Bool {
        guard let installed = normalizeVersion(installed),
              let expected = normalizeVersion(expected) else {
            return false
        }
        if installed == expected { return true }
        return installed.hasPrefix(expected) || expected.hasPrefix(installed)
    }

    /// First git SHA token found in probe output (ls-remote / GitHub API JSON).
    static func parseRemoteHead(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sha = stringValue(object["sha"]),
           let normalized = normalizeVersion(sha),
           isHexSHA(normalized) {
            return normalized
        }

        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        // Prefer a bare SHA line; also accept `sha\trefs/heads/main`.
        for line in trimmed.split(whereSeparator: \.isNewline) {
            guard let first = line.split(whereSeparator: { $0.isWhitespace }).first else { continue }
            let token = String(first)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !token.isEmpty else { continue }
            if let normalized = normalizeVersion(token),
               normalized.unicodeScalars.allSatisfy({ hex.contains($0) }),
               normalized.count >= 7 {
                return normalized
            }
        }
        return nil
    }

    private static func isHexSHA(_ value: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return value.count >= 7 && value.unicodeScalars.allSatisfy { hex.contains($0) }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

enum OpenCodeServerPasswordGenerator {
    static func generate(byteCount: Int = 32) throws -> String {
        precondition(byteCount > 0)

        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainManager.KeychainError.unknown(status)
        }

        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OpenCodeClientFactory {
    static func client(for serverID: UUID) -> OpenCodeClient {
        var configuration = OpenCodeClientConfiguration()
        if let password = try? KeychainManager.shared.retrieveOpenCodeServerPassword(for: serverID) {
            configuration.username = (try? KeychainManager.shared.retrieveOpenCodeServerUsername(for: serverID))
                ?? OpenCodeServerProvisioning.username
            configuration.password = password
        }
        return OpenCodeClient(configuration: configuration)
    }
}
