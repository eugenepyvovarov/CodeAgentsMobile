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

    func testOpenCodeStatusMapsToSharedMCPStatus() {
        XCTAssertEqual(OpenCodeMCPStatus(status: "connected", error: nil).mcpStatus, .connected)
        XCTAssertEqual(OpenCodeMCPStatus(status: "disabled", error: nil).mcpStatus, .disconnected)
        XCTAssertEqual(OpenCodeMCPStatus(status: "needs_auth", error: nil).mcpStatus, .disconnected)
        XCTAssertEqual(OpenCodeMCPStatus(status: "future", error: nil).mcpStatus, .unknown)
    }
}
