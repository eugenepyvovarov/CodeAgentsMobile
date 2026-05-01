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
        attempt=1
        while [ "$attempt" -le 30 ]; do
          if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then
            curl -fsS -u "${OPENCODE_SERVER_USERNAME:-opencode}:${OPENCODE_SERVER_PASSWORD}" http://\(host):\(port)/global/health >/tmp/opencode-health.json && exit 0
          else
            curl -fsS http://\(host):\(port)/global/health >/tmp/opencode-health.json && exit 0
          fi
          sleep 2
          attempt=$((attempt + 1))
        done
        journalctl -u opencode --no-pager -n 80
        exit 1
        """
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
            configuration.username = OpenCodeServerProvisioning.username
            configuration.password = password
        }
        return OpenCodeClient(configuration: configuration)
    }
}
