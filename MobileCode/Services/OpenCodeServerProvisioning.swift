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

    static func runcmdScript(host: String = Self.host, port: Int = Self.port) -> String {
        """
        set -eux
        mkdir -p /home/codeagent/projects
        chown -R codeagent:codeagent /home/codeagent
        su - codeagent -c "curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path"
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

        \(CodeAgentsDaemonProvisioning.installCommand())
        \(CodeAgentsDaemonProvisioning.waitForHealthScript())
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
        su - codeagent -c "curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path"

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
        \(CodeAgentsDaemonProvisioning.installCommand())
        echo "Waiting for CodeAgents daemon health..."
        \(CodeAgentsDaemonProvisioning.waitForHealthScript())
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
    static let installScriptURL = "https://raw.githubusercontent.com/eugenepyvovarov/codeagents-server-cc-proxy/HEAD/install.sh"
    static let serviceName = "codeagents-daemon"
    static let installDirectory = "/opt/codeagents-daemon"
    static let dataDirectory = "/opt/codeagents-daemon/data"
    static let logDirectory = "/var/log/codeagents-daemon"
    static let environmentFilePath = "/etc/codeagents-daemon.env"
    static let legacyEnvironmentFilePath = "/etc/claude-proxy.env"

    static var healthURL: String {
        "http://\(host):\(port)/healthz"
    }

    static func installCommand() -> String {
        let environment = [
            "INSTALL_DIR=\(installDirectory)",
            "DATA_DIR=\(dataDirectory)",
            "LOG_DIR=\(logDirectory)",
            "SERVICE_NAME=\(serviceName)",
            "INSTALL_CLAUDE_CLI=0"
        ].joined(separator: " ")
        return "curl -fsSL \(installScriptURL) | \(environment) bash"
    }

    static func healthCheckCommand() -> String {
        "curl -fsS \(healthURL)"
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
