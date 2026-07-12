import XCTest
@testable import CodeAgentsMobile

final class OpenCodeMCPConfigurationTests: XCTestCase {
    func testDecodesOpenCodeLocalAndRemoteMCPServers() throws {
        let json = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "filesystem": {
              "type": "local",
              "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem"],
              "environment": {
                "ROOT": "/workspace"
              },
              "enabled": true
            },
            "remote-api": {
              "type": "remote",
              "url": "https://example.com/mcp",
              "headers": {
                "Authorization": "Bearer token"
              },
              "enabled": false
            }
          }
        }
        """

        let configuration = try JSONDecoder().decode(OpenCodeMCPConfiguration.self, from: Data(json.utf8))
        let servers = Dictionary(uniqueKeysWithValues: configuration.servers.map { ($0.name, $0) })

        XCTAssertEqual(servers["filesystem"]?.command, "npx")
        XCTAssertEqual(servers["filesystem"]?.args, ["-y", "@modelcontextprotocol/server-filesystem"])
        XCTAssertEqual(servers["filesystem"]?.env, ["ROOT": "/workspace"])
        XCTAssertEqual(servers["filesystem"]?.status, .unknown)
        XCTAssertEqual(servers["remote-api"]?.url, "https://example.com/mcp")
        XCTAssertEqual(servers["remote-api"]?.headers, ["Authorization": "Bearer token"])
        XCTAssertEqual(servers["remote-api"]?.status, .disconnected)
    }

    func testEncodesMCPServersToOpenCodeShape() throws {
        let local = MCPServer(
            name: "local",
            command: "node",
            args: ["server.js", "--stdio"],
            env: ["TOKEN": "secret"],
            url: nil,
            headers: nil
        )
        let remote = MCPServer(
            name: "remote",
            command: nil,
            args: nil,
            env: nil,
            url: "https://example.com/mcp",
            headers: ["Authorization": "Bearer token"]
        )

        let configuration = OpenCodeMCPConfiguration(servers: [local, remote])

        XCTAssertEqual(configuration.mcp["local"]?.type, .local)
        XCTAssertEqual(configuration.mcp["local"]?.command, ["node", "server.js", "--stdio"])
        XCTAssertEqual(configuration.mcp["local"]?.environment, ["TOKEN": "secret"])
        XCTAssertEqual(configuration.mcp["local"]?.enabled, true)
        XCTAssertEqual(configuration.mcp["remote"]?.type, .remote)
        XCTAssertEqual(configuration.mcp["remote"]?.url, "https://example.com/mcp")
        XCTAssertEqual(configuration.mcp["remote"]?.headers, ["Authorization": "Bearer token"])
    }

    func testJSONCDocumentPreservesNonMCPKeysAndStripsComments() throws {
        let jsonc = """
        {
          "$schema": "https://opencode.ai/config.json",
          // Preserve other app config.
          "formatter": false,
          "mcp": {
            "remote": {
              "type": "remote",
              "url": "https://example.com/mcp", // Do not strip URL slashes.
              "enabled": true,
            }
          },
        }
        """
        var document = try OpenCodeMCPConfigDocument(jsonString: jsonc)
        let server = MCPServer(
            name: "local",
            command: "echo",
            args: ["ok"],
            env: nil,
            url: nil,
            headers: nil
        )

        try document.setServer(server)
        let output = try document.toJSONString()
        let decoded = try OpenCodeMCPConfigDocument(jsonString: output)

        XCTAssertEqual(decoded.server(named: "remote")?.url, "https://example.com/mcp")
        XCTAssertEqual(decoded.server(named: "local")?.command, "echo")
        XCTAssertEqual(decoded.server(named: "local")?.args, ["ok"])
        XCTAssertEqual(decoded.root["formatter"] as? Bool, false)
    }

    func testClaudeMCPMergeIntoOpenCodeJSONCPreservesKeysAndSkipsExisting() throws {
        let claudeJSON = """
        {
          "mcpServers": {
            "remote": {
              "url": "https://claude-only.example/mcp"
            },
            "new-local": {
              "command": "node",
              "args": ["server.js"]
            }
          }
        }
        """
        let openCodeJSONC = """
        {
          "$schema": "https://opencode.ai/config.json",
          "formatter": false,
          "mcp": {
            "remote": {
              "type": "remote",
              "url": "https://example.com/mcp",
              "enabled": true
            }
          }
        }
        """
        let claudeServers = try MCPClaudeToOpenCodeMigrator.servers(fromClaudeMCPJSON: claudeJSON)
        let document = try OpenCodeMCPConfigDocument(jsonString: openCodeJSONC)
        let result = MCPClaudeToOpenCodeMigrator.merge(servers: claudeServers, into: document)

        XCTAssertEqual(result.report.skippedExisting, ["remote"])
        XCTAssertEqual(result.report.imported, ["new-local"])
        XCTAssertEqual(result.document.server(named: "remote")?.url, "https://example.com/mcp")
        XCTAssertEqual(result.document.server(named: "new-local")?.command, "node")
        XCTAssertEqual(result.document.root["formatter"] as? Bool, false)
    }

    func testOpenCodeStatusMapsToSharedMCPStatus() {
        XCTAssertEqual(OpenCodeMCPStatus(status: "connected", error: nil).mcpStatus, .connected)
        XCTAssertEqual(OpenCodeMCPStatus(status: "disabled", error: nil).mcpStatus, .disconnected)
        XCTAssertEqual(OpenCodeMCPStatus(status: "needs_auth", error: nil).mcpStatus, .disconnected)
        XCTAssertEqual(OpenCodeMCPStatus(status: "future", error: nil).mcpStatus, .unknown)
    }

    @MainActor
    func testManagedSchedulerServerEncodesAsOpenCodeRemoteMCPServer() {
        let project = RemoteProject(name: "demo", serverId: UUID(), basePath: "/home/codeagent/projects")
        project.path = "/home/codeagent/projects/demo"
        project.proxyAgentId = "agent-demo"
        project.proxyConversationId = "session-demo"

        let server = MCPTaskSchedulerProvisionService.shared.managedSchedulerServer(for: project)
        let configuration = OpenCodeMCPServerConfiguration(server: server)

        XCTAssertEqual(configuration?.type, .remote)
        XCTAssertEqual(configuration?.url, "http://127.0.0.1:8787/mcp")
        XCTAssertEqual(configuration?.headers?["x-codeagents-agent-id"], "agent-demo")
        XCTAssertEqual(configuration?.headers?["x-codeagents-project-path"], "/home/codeagent/projects/demo")
        XCTAssertEqual(configuration?.enabled, true)
    }

    func testRemoteMCPAppOAuthConfigurationRoundTrips() throws {
        let json = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "sentry": {
              "type": "remote",
              "url": "https://mcp.sentry.dev/mcp",
              "oauth": {
                "clientId": "{env:SENTRY_CLIENT_ID}",
                "scope": "tools:read tools:execute"
              }
            },
            "context7": {
              "type": "remote",
              "url": "https://mcp.context7.com/mcp",
              "oauth": false,
              "headers": {
                "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}"
              }
            }
          }
        }
        """

        var document = try OpenCodeMCPConfigDocument(jsonString: json)
        let configurations = document.serverConfigurations()

        XCTAssertEqual(configurations["sentry"]?.oauth, .init([
            "clientId": "{env:SENTRY_CLIENT_ID}",
            "scope": "tools:read tools:execute"
        ]))
        XCTAssertEqual(configurations["context7"]?.oauth, .init(false))

        try document.setServer(MCPServer(
            name: "context7",
            command: nil,
            args: nil,
            env: nil,
            url: "https://mcp.context7.com/mcp",
            headers: ["CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}"]
        ))

        let updated = try OpenCodeMCPConfigDocument(jsonString: document.toJSONString())
        XCTAssertEqual(updated.serverConfigurations()["context7"]?.oauth, .init(false))
    }

    /// Duplicate Agent must write full configurations so oauth/timeout survive (no MCPServer round-trip).
    func testSetServerNamedPreservesOAuthAndTimeoutOnNewDocument() throws {
        let sourceJSON = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "sentry": {
              "type": "remote",
              "url": "https://mcp.sentry.dev/mcp",
              "timeout": 120000,
              "oauth": {
                "clientId": "{env:SENTRY_CLIENT_ID}",
                "scope": "tools:read"
              },
              "enabled": true
            }
          }
        }
        """
        let source = try OpenCodeMCPConfigDocument(jsonString: sourceJSON)
        guard let configuration = source.serverConfigurations()["sentry"] else {
            return XCTFail("missing sentry config")
        }

        // Round-trip through MCPServer loses oauth/timeout (the bug path).
        let viaMCPServer = OpenCodeMCPServerConfiguration(
            server: MCPServer(name: "sentry", openCodeConfiguration: configuration)!,
            enabled: configuration.enabled ?? true
        )
        XCTAssertNil(viaMCPServer?.oauth)
        XCTAssertNil(viaMCPServer?.timeout)

        // Full configuration write preserves both.
        var destination = OpenCodeMCPConfigDocument()
        try destination.setServer(named: "sentry", configuration: configuration)
        let written = try OpenCodeMCPConfigDocument(jsonString: destination.toJSONString())
        let restored = written.serverConfigurations()["sentry"]
        XCTAssertEqual(restored?.timeout, 120_000)
        XCTAssertEqual(restored?.oauth, .init([
            "clientId": "{env:SENTRY_CLIENT_ID}",
            "scope": "tools:read"
        ]))
        XCTAssertEqual(restored?.enabled, true)
        XCTAssertEqual(restored?.url, "https://mcp.sentry.dev/mcp")
    }
}
