import XCTest
@testable import CodeAgentsMobile

@MainActor
final class OpenCodeMCPServiceHostScopeTests: XCTestCase {

    func testFetchGlobalServers_DecodesHostGlobalConfig() async throws {
        let configJSON = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "filesystem": {
              "type": "local",
              "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem"],
              "environment": { "ROOT": "/workspace" },
              "enabled": true
            },
            "remote-api": {
              "type": "remote",
              "url": "https://example.com/mcp",
              "enabled": false
            }
          }
        }
        """

        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = ["/home/test/.config/opencode/opencode.json": configJSON]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)

        let host = Server(name: "test-host", host: "test.example", username: "u")
        let servers = try await service.fetchGlobalServers(for: host)

        // Sorted by name.
        XCTAssertEqual(servers.map(\.name), ["filesystem", "remote-api"])
        XCTAssertEqual(servers.first { $0.name == "filesystem" }?.command, "npx")
        XCTAssertEqual(servers.first { $0.name == "filesystem" }?.env, ["ROOT": "/workspace"])
        XCTAssertEqual(servers.first { $0.name == "remote-api" }?.url, "https://example.com/mcp")
        // Live status is best-effort; fetch returns unknown when the fake session provides none.
        XCTAssertEqual(servers.first { $0.name == "remote-api" }?.status, .disconnected)
    }

    func testAddServer_WritesToHostGlobalConfig() async throws {
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = [
            "/home/test/.config/opencode/opencode.json": "{\"$schema\":\"https://opencode.ai/config.json\",\"mcp\":{}}"
        ]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "test-host", host: "test.example", username: "u")

        let newServer = MCPServer(
            name: "github",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-github"],
            env: ["GITHUB_TOKEN": "secret"],
            url: nil,
            headers: nil
        )
        try await service.addServer(newServer, to: host)

        let written = try XCTUnwrap(ssh.session.lastWrittenFileContents)
        let document = try OpenCodeMCPConfigDocument(jsonString: written)
        let saved = try XCTUnwrap(document.server(named: "github"))
        XCTAssertEqual(saved.command, "npx")
        XCTAssertEqual(saved.args, ["-y", "@modelcontextprotocol/server-github"])
        XCTAssertEqual(saved.env, ["GITHUB_TOKEN": "secret"])
        XCTAssertEqual(saved.status, .unknown)
    }

    func testAddServerConfiguration_PreservesOauthAndTimeoutThroughCopy() async throws {
        // Key correctness property for cross-host copy: a raw
        // OpenCodeMCPServerConfiguration carries `oauth` and `timeout` which the
        // MCPServer round-trip would drop. Copying via addServerConfiguration
        // must preserve them byte-for-byte.
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = [
            "/home/test/.config/opencode/opencode.json": "{\"$schema\":\"https://opencode.ai/config.json\",\"mcp\":{}}"
        ]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "test-host", host: "test.example", username: "u")

        var oauthConfig = OpenCodeMCPServerConfiguration(
            type: .remote,
            enabled: true,
            timeout: 30000,
            url: "https://example.com/mcp",
            headers: ["Authorization": "Bearer token"]
        )
        oauthConfig.oauth = .init([
            "provider": "github",
            "scopes": ["repo", "gist"]
        ])

        let didWrite = try await service.addServerConfiguration(
            oauthConfig,
            named: "github",
            to: host,
            enabled: true
        )
        XCTAssertTrue(didWrite)

        let written = try XCTUnwrap(ssh.session.lastWrittenFileContents)
        let document = try OpenCodeMCPConfigDocument(jsonString: written)
        let saved = try XCTUnwrap(document.serverConfigurations()["github"])
        XCTAssertEqual(saved.timeout, 30000)
        XCTAssertEqual(saved.url, "https://example.com/mcp")
        XCTAssertEqual(saved.headers, ["Authorization": "Bearer token"])
        XCTAssertEqual(saved.oauth, .init([
            "provider": "github",
            "scopes": ["repo", "gist"]
        ]))
    }

    func testAddServerConfiguration_ReplacesDestinationOAuthExactly() async throws {
        let initialJSON = """
        {
          "mcp": {
            "context7": {
              "type": "remote",
              "url": "https://mcp.context7.com/mcp",
              "oauth": false,
              "enabled": true
            }
          }
        }
        """
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = [
            "/home/test/.config/opencode/opencode.json": initialJSON
        ]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "target", host: "target.example", username: "u")
        let sourceConfiguration = OpenCodeMCPServerConfiguration(
            type: .remote,
            enabled: true,
            url: "https://mcp.context7.com/mcp",
            oauth: nil
        )

        _ = try await service.addServerConfiguration(
            sourceConfiguration,
            named: "context7",
            to: host
        )

        let written = try XCTUnwrap(ssh.session.lastWrittenFileContents)
        let restored = try OpenCodeMCPConfigDocument(jsonString: written)
        XCTAssertNil(restored.serverConfigurations()["context7"]?.oauth)
    }

    func testRemoveServer_DeletesFromHostGlobal() async throws {
        let initialJSON = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "keep": { "type": "local", "command": ["npx", "keep-mcp"], "enabled": true },
            "delete-me": { "type": "local", "command": ["npx", "delete-me"], "enabled": true }
          }
        }
        """
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = ["/home/test/.config/opencode/opencode.json": initialJSON]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "test-host", host: "test.example", username: "u")

        try await service.removeServer(named: "delete-me", from: host)

        let written = try XCTUnwrap(ssh.session.lastWrittenFileContents)
        let document = try OpenCodeMCPConfigDocument(jsonString: written)
        XCTAssertNotNil(document.server(named: "keep"))
        XCTAssertNil(document.server(named: "delete-me"))
    }

    func testEditServer_RenamesInHostGlobal() async throws {
        let initialJSON = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "old-name": { "type": "local", "command": ["npx", "old-mcp"], "enabled": true }
          }
        }
        """
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = ["/home/test/.config/opencode/opencode.json": initialJSON]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "test-host", host: "test.example", username: "u")

        let renamed = MCPServer(name: "new-name", command: "npx", args: ["new-mcp"], env: nil, url: nil, headers: nil)
        try await service.editServer(oldName: "old-name", newServer: renamed, on: host)

        let written = try XCTUnwrap(ssh.session.lastWrittenFileContents)
        let document = try OpenCodeMCPConfigDocument(jsonString: written)
        XCTAssertNil(document.server(named: "old-name"))
        let new = try XCTUnwrap(document.server(named: "new-name"))
        XCTAssertEqual(new.command, "npx")
        XCTAssertEqual(new.args, ["new-mcp"])
    }

    func testEditServer_RenamePreservesAdvancedRemoteFields() async throws {
        let initialJSON = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "old-name": {
              "type": "remote",
              "url": "https://example.com/mcp",
              "headers": { "Old": "header" },
              "timeout": 60000,
              "oauth": { "provider": "example" },
              "future": { "transport": "http2" },
              "enabled": false
            }
          }
        }
        """
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = ["/home/test/.config/opencode/opencode.json": initialJSON]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "test-host", host: "test.example", username: "u")
        let renamed = MCPServer(
            name: "new-name",
            command: nil,
            args: nil,
            env: nil,
            url: "https://example.com/mcp",
            headers: ["New": "header"]
        )

        try await service.editServer(oldName: "old-name", newServer: renamed, on: host)

        let written = try XCTUnwrap(ssh.session.lastWrittenFileContents)
        let document = try OpenCodeMCPConfigDocument(jsonString: written)
        XCTAssertNil(document.serverConfigurations()["old-name"])
        let saved = try XCTUnwrap(document.serverConfigurations()["new-name"])
        XCTAssertEqual(saved.headers, ["New": "header"])
        XCTAssertEqual(saved.enabled, false)
        XCTAssertEqual(saved.timeout, 60_000)
        XCTAssertEqual(saved.oauth, .init(["provider": "example"]))
        let future = try XCTUnwrap(saved.additionalProperties["future"]?.value as? [String: Any])
        XCTAssertEqual(future["transport"] as? String, "http2")
    }

    func testEditServer_PreservesAdvancedLocalFields() async throws {
        let initialJSON = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "local": {
              "type": "local",
              "command": ["node", "old.js"],
              "environment": { "OLD": "1" },
              "cwd": "/workspace/tools",
              "timeout": 45000,
              "future": { "sandbox": true },
              "enabled": true
            }
          }
        }
        """
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = ["/home/test/.config/opencode/opencode.json": initialJSON]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "test-host", host: "test.example", username: "u")
        let edited = MCPServer(
            name: "local",
            command: "node",
            args: ["new.js"],
            env: ["NEW": "2"],
            url: nil,
            headers: nil
        )

        try await service.editServer(oldName: "local", newServer: edited, on: host)

        let written = try XCTUnwrap(ssh.session.lastWrittenFileContents)
        let document = try OpenCodeMCPConfigDocument(jsonString: written)
        let saved = try XCTUnwrap(document.serverConfigurations()["local"])
        XCTAssertEqual(saved.command, ["node", "new.js"])
        XCTAssertEqual(saved.environment, ["NEW": "2"])
        XCTAssertEqual(saved.cwd, "/workspace/tools")
        XCTAssertEqual(saved.timeout, 45_000)
        let future = try XCTUnwrap(saved.additionalProperties["future"]?.value as? [String: Any])
        XCTAssertEqual(future["sandbox"] as? Bool, true)
    }

    func testAddServer_RejectsManagedSchedulerName() async {
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = [
            "/home/test/.config/opencode/opencode.json": "{\"$schema\":\"https://opencode.ai/config.json\",\"mcp\":{}}"
        ]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "test-host", host: "test.example", username: "u")

        let managed = MCPServer(
            name: MCPServer.managedSchedulerServerName,
            command: "npx",
            args: [],
            env: nil,
            url: nil,
            headers: nil
        )
        do {
            try await service.addServer(managed, to: host)
            XCTFail("Expected managed-name rejection")
        } catch MCPServiceError.managedServerNotModifiable {
            // OK — managed server names must not be writable from the host-scoped API.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(ssh.session.lastWrittenFileContents, "No file should be written for a rejected managed name.")
    }

    func testAddServerConfiguration_RejectsManagedAvatarName() async {
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = [
            "/home/test/.config/opencode/opencode.json": "{\"$schema\":\"https://opencode.ai/config.json\",\"mcp\":{}}"
        ]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "test-host", host: "test.example", username: "u")

        let config = OpenCodeMCPServerConfiguration(
            type: .local,
            enabled: true,
            url: nil,
            headers: nil
        )
        do {
            _ = try await service.addServerConfiguration(
                config,
                named: MCPServer.managedAvatarServerName,
                to: host
            )
            XCTFail("Expected managed-name rejection")
        } catch MCPServiceError.managedServerNotModifiable {
            // OK
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(ssh.session.lastWrittenFileContents, "No file should be written for a rejected managed name.")
    }

    func testGlobalServerConfigurations_PreservesOauthAndTimeout() async throws {
        let initialJSON = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "sentry": {
              "type": "remote",
              "url": "https://sentry.example/mcp",
              "timeout": 30000,
              "oauth": { "provider": "sentry" },
              "enabled": true
            }
          }
        }
        """
        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = ["/home/test/.config/opencode/opencode.json": initialJSON]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "test-host", host: "test.example", username: "u")

        let configs = try await service.globalServerConfigurations(for: host)
        let sentry = try XCTUnwrap(configs["sentry"])
        XCTAssertEqual(sentry.timeout, 30000)
        XCTAssertEqual(sentry.oauth, .init(["provider": "sentry"]))
        XCTAssertEqual(sentry.url, "https://sentry.example/mcp")
    }

    func testAddServerConfiguration_PreservesCWDAndUnknownFields() async throws {
        let sourceJSON = """
        {
          "mcp": {
            "filesystem": {
              "type": "local",
              "command": ["node", "server.js"],
              "cwd": "/workspace/tools",
              "future": { "sandbox": true },
              "enabled": true
            }
          }
        }
        """
        let source = try OpenCodeMCPConfigDocument(jsonString: sourceJSON)
        let configuration = try XCTUnwrap(source.serverConfigurations()["filesystem"])

        let ssh = HostScopeFakeSSHService()
        ssh.session.fileContentsByPath = [
            "/home/test/.config/opencode/opencode.json": "{\"$schema\":\"https://opencode.ai/config.json\",\"mcp\":{}}"
        ]
        let service = OpenCodeMCPService(sshService: ssh, client: nil)
        let host = Server(name: "target", host: "target.example", username: "u")

        _ = try await service.addServerConfiguration(
            configuration,
            named: "filesystem",
            to: host
        )

        let written = try XCTUnwrap(ssh.session.lastWrittenFileContents)
        let restored = try OpenCodeMCPConfigDocument(jsonString: written)
        let saved = try XCTUnwrap(restored.serverConfigurations()["filesystem"])
        XCTAssertEqual(saved.cwd, "/workspace/tools")
        let future = try XCTUnwrap(saved.additionalProperties["future"]?.value as? [String: Any])
        XCTAssertEqual(future["sandbox"] as? Bool, true)
    }

    func testDisabledProjectStubIsAppliedToLiveOpenCode() async throws {
        let ssh = HostScopeFakeSSHService()
        let project = RemoteProject(name: "project", serverId: UUID(), basePath: "/workspace")
        project.path = "/workspace/project"
        ssh.session.fileContentsByPath = [
            "/workspace/project/opencode.json": "{\"$schema\":\"https://opencode.ai/config.json\",\"mcp\":{}}"
        ]
        ssh.session.httpResponseBody = "{\"disabled\":{\"status\":\"disabled\"}}"
        let service = OpenCodeMCPService(sshService: ssh, client: OpenCodeClient())
        let hostConfiguration = OpenCodeMCPServerConfiguration(
            type: .remote,
            enabled: true,
            url: "https://example.com/mcp"
        )

        _ = try await service.disableHostServerForProject(
            named: "disabled",
            hostConfiguration: hostConfiguration,
            for: project
        )

        let request = try XCTUnwrap(ssh.session.lastSentHTTPInput)
        XCTAssertTrue(request.contains("POST /mcp?directory=/workspace/project HTTP/1.1"))
        let body = try ssh.session.lastSentJSONObject()
        let config = try XCTUnwrap(body["config"] as? [String: Any])
        XCTAssertEqual(config["enabled"] as? Bool, false)
    }

    func testDisableLogicalFailureRestoresDiskAndLiveHostConfiguration() async throws {
        let ssh = HostScopeFakeSSHService()
        let project = RemoteProject(name: "project", serverId: UUID(), basePath: "/workspace")
        project.path = "/workspace/project"
        let projectPath = "/workspace/project/opencode.json"
        ssh.session.fileContentsByPath = [
            projectPath: "{\"$schema\":\"https://opencode.ai/config.json\",\"mcp\":{}}"
        ]
        ssh.session.httpOutcomes = [
            .response("{\"disabled\":{\"status\":\"connected\"}}"),
            .response("{\"disabled\":{\"status\":\"connected\"}}")
        ]
        let service = OpenCodeMCPService(sshService: ssh, client: OpenCodeClient())
        let hostConfiguration = OpenCodeMCPServerConfiguration(
            type: .remote,
            enabled: true,
            url: "https://example.com/mcp"
        )

        do {
            _ = try await service.disableHostServerForProject(
                named: "disabled",
                hostConfiguration: hostConfiguration,
                for: project
            )
            XCTFail("Expected the strict live update to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("instead of disabled"))
        }

        let restoredJSON = try XCTUnwrap(ssh.session.fileContentsByPath[projectPath])
        let restored = try OpenCodeMCPConfigDocument(jsonString: restoredJSON)
        XCTAssertNil(restored.serverConfigurations()["disabled"])

        let requests = try ssh.session.sentJSONObjects()
        XCTAssertEqual(requests.count, 2)
        let disabledConfig = try XCTUnwrap(requests[0]["config"] as? [String: Any])
        let restoredHostConfig = try XCTUnwrap(requests[1]["config"] as? [String: Any])
        XCTAssertEqual(disabledConfig["enabled"] as? Bool, false)
        XCTAssertEqual(restoredHostConfig["enabled"] as? Bool, true)
    }

    func testDisableTransportAndCompensationFailureReportsRollbackError() async throws {
        let ssh = HostScopeFakeSSHService()
        let project = RemoteProject(name: "project", serverId: UUID(), basePath: "/workspace")
        project.path = "/workspace/project"
        let projectPath = "/workspace/project/opencode.json"
        ssh.session.fileContentsByPath = [
            projectPath: "{\"$schema\":\"https://opencode.ai/config.json\",\"mcp\":{}}"
        ]
        ssh.session.httpOutcomes = [.transportFailure, .transportFailure]
        let service = OpenCodeMCPService(sshService: ssh, client: OpenCodeClient())
        let hostConfiguration = OpenCodeMCPServerConfiguration(
            type: .remote,
            enabled: true,
            url: "https://example.com/mcp"
        )

        do {
            _ = try await service.disableHostServerForProject(
                named: "disabled",
                hostConfiguration: hostConfiguration,
                for: project
            )
            XCTFail("Expected both live operations to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Rollback also failed"))
        }

        let restoredJSON = try XCTUnwrap(ssh.session.fileContentsByPath[projectPath])
        let restored = try OpenCodeMCPConfigDocument(jsonString: restoredJSON)
        XCTAssertNil(restored.serverConfigurations()["disabled"])
    }

    func testRevertProjectOverrideRemovesEntryAndAppliesHostConfigurationLive() async throws {
        let ssh = HostScopeFakeSSHService()
        let project = RemoteProject(name: "project", serverId: UUID(), basePath: "/workspace")
        project.path = "/workspace/project"
        ssh.session.fileContentsByPath = [
            "/workspace/project/opencode.json": """
            {
              "$schema": "https://opencode.ai/config.json",
              "mcp": {
                "shared": {
                  "type": "remote",
                  "url": "https://project.example/mcp",
                  "enabled": true
                }
              }
            }
            """
        ]
        ssh.session.httpResponseBody = "{\"shared\":{\"status\":\"connected\"}}"
        let service = OpenCodeMCPService(sshService: ssh, client: OpenCodeClient())
        let hostConfiguration = OpenCodeMCPServerConfiguration(
            type: .remote,
            enabled: true,
            timeout: 30_000,
            url: "https://host.example/mcp",
            headers: ["Host": "value"]
        )

        try await service.revertProjectServerOverride(
            named: "shared",
            restoring: hostConfiguration,
            for: project
        )

        let written = try XCTUnwrap(ssh.session.lastWrittenFileContents)
        let document = try OpenCodeMCPConfigDocument(jsonString: written)
        XCTAssertNil(document.serverConfigurations()["shared"])

        let request = try XCTUnwrap(ssh.session.lastSentHTTPInput)
        XCTAssertTrue(request.contains("POST /mcp?directory=/workspace/project HTTP/1.1"))
        XCTAssertFalse(request.contains("/disconnect"))
        let body = try ssh.session.lastSentJSONObject()
        let config = try XCTUnwrap(body["config"] as? [String: Any])
        XCTAssertEqual(config["url"] as? String, "https://host.example/mcp")
        XCTAssertEqual(config["timeout"] as? Int, 30_000)
        XCTAssertEqual(config["headers"] as? [String: String], ["Host": "value"])
    }

    func testRevertLogicalFailureRestoresDiskAndLiveProjectOverride() async throws {
        let ssh = HostScopeFakeSSHService()
        let project = RemoteProject(name: "project", serverId: UUID(), basePath: "/workspace")
        project.path = "/workspace/project"
        let projectPath = "/workspace/project/opencode.json"
        ssh.session.fileContentsByPath = [
            projectPath: """
            {
              "$schema": "https://opencode.ai/config.json",
              "mcp": {
                "shared": {
                  "type": "remote",
                  "url": "https://project.example/mcp",
                  "timeout": 15000,
                  "enabled": true
                }
              }
            }
            """
        ]
        ssh.session.httpOutcomes = [
            .response("{\"shared\":{\"status\":\"failed\",\"error\":\"host unavailable\"}}"),
            .response("{\"shared\":{\"status\":\"connected\"}}")
        ]
        let service = OpenCodeMCPService(sshService: ssh, client: OpenCodeClient())
        let hostConfiguration = OpenCodeMCPServerConfiguration(
            type: .remote,
            enabled: true,
            url: "https://host.example/mcp"
        )

        do {
            try await service.revertProjectServerOverride(
                named: "shared",
                restoring: hostConfiguration,
                for: project
            )
            XCTFail("Expected the strict live update to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("returned failed"))
        }

        let restoredJSON = try XCTUnwrap(ssh.session.fileContentsByPath[projectPath])
        let restored = try OpenCodeMCPConfigDocument(jsonString: restoredJSON)
        let projectConfiguration = try XCTUnwrap(restored.serverConfigurations()["shared"])
        XCTAssertEqual(projectConfiguration.url, "https://project.example/mcp")
        XCTAssertEqual(projectConfiguration.timeout, 15_000)

        let requests = try ssh.session.sentJSONObjects()
        XCTAssertEqual(requests.count, 2)
        let attemptedHostConfig = try XCTUnwrap(requests[0]["config"] as? [String: Any])
        let restoredProjectConfig = try XCTUnwrap(requests[1]["config"] as? [String: Any])
        XCTAssertEqual(attemptedHostConfig["url"] as? String, "https://host.example/mcp")
        XCTAssertEqual(restoredProjectConfig["url"] as? String, "https://project.example/mcp")
        XCTAssertEqual(restoredProjectConfig["timeout"] as? Int, 15_000)
    }
}

// MARK: - Fakes

@MainActor
private final class HostScopeFakeSSHService: SSHService {
    let session = HostScopeFakeSSHSession()
    override func getConnection(for server: Server, purpose: ConnectionPurpose) async throws -> SSHSession {
        session
    }
    override func getConnection(for project: RemoteProject, purpose: ConnectionPurpose) async throws -> SSHSession {
        session
    }
}

private enum HostScopeHTTPOutcome {
    case response(String)
    case transportFailure
}

private final class HostScopeFakeSSHSession: SSHSession {
    /// Canned file contents keyed by absolute path.
    var fileContentsByPath: [String: String] = [:]
    /// The most recently written file contents (for assertions).
    var lastWrittenFileContents: String?
    /// The most recent write path.
    var lastWrittenPath: String?
    var httpResponseBody: String?
    var httpOutcomes: [HostScopeHTTPOutcome] = []
    private var httpHandles: [HostScopeFakeProcessHandle] = []

    var lastSentHTTPInput: String? {
        httpHandles.last?.sentInput
    }

    func lastSentJSONObject() throws -> [String: Any] {
        let input = try XCTUnwrap(lastSentHTTPInput)
        return try jsonObject(from: input)
    }

    func sentJSONObjects() throws -> [[String: Any]] {
        try httpHandles.map { try jsonObject(from: $0.sentInput) }
    }

    private func jsonObject(from input: String) throws -> [String: Any] {
        let body = input.components(separatedBy: "\r\n\r\n").last ?? ""
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body.utf8), options: []) as? [String: Any]
        )
    }

    func execute(_ command: String) async throws -> String {
        // OpenCodeMCPService.globalConfigurationPath runs:
        //   printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
        if command.contains("opencode/opencode.json"), !command.contains("base64") {
            return "/home/test/.config/opencode/opencode.json"
        }

        // OpenCodeMCPService writes via:
        //   mkdir -p "$(dirname "<path>")" && printf '%s' '<base64>' | base64 -d > "<path>"
        if command.contains("base64 -d >") {
            captureWriteCommand(command)
            return ""
        }

        return ""
    }

    /// Decode the base64 payload + path from a write command for assertions.
    private func captureWriteCommand(_ command: String) {
        guard
            let printfRange = command.range(of: "printf '%s' '"),
            let pipeRange = command.range(of: "' | base64 -d > \"", range: printfRange.upperBound..<command.endIndex),
            let closingQuoteRange = command.range(of: "\"", range: pipeRange.upperBound..<command.endIndex)
        else { return }

        let base64 = String(command[printfRange.upperBound..<pipeRange.lowerBound])
        let path = String(command[pipeRange.upperBound..<closingQuoteRange.lowerBound])

        guard
            let data = Data(base64Encoded: base64),
            let contents = String(data: data, encoding: .utf8)
        else { return }

        lastWrittenFileContents = contents
        lastWrittenPath = path
        fileContentsByPath[path] = contents
    }

    func executeRaw(_ command: String) async throws -> String {
        try await execute(command)
    }

    func startProcess(_ command: String) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not used")
    }

    func startProcessRaw(_ command: String) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not used")
    }

    func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> ProcessHandle {
        let responseBody: String
        if !httpOutcomes.isEmpty {
            switch httpOutcomes.removeFirst() {
            case .response(let body):
                responseBody = body
            case .transportFailure:
                throw SSHError.commandFailed("Simulated HTTP transport failure")
            }
        } else {
            guard let httpResponseBody else {
                throw SSHError.commandFailed("Not used")
            }
            responseBody = httpResponseBody
        }
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(responseBody.utf8.count)\r
        Connection: close\r
        \r
        \(responseBody)
        """
        let handle = HostScopeFakeProcessHandle(response: response)
        httpHandles.append(handle)
        return handle
    }

    func uploadFile(localPath: URL, remotePath: String) async throws {
        throw SSHError.commandFailed("Not used")
    }

    func downloadFile(remotePath: String, localPath: URL) async throws {
        throw SSHError.commandFailed("Not used")
    }

    func readFile(_ remotePath: String) async throws -> String {
        if let contents = fileContentsByPath[remotePath] {
            return contents
        }
        throw SSHError.commandFailed("No such file: \(remotePath)")
    }

    func listDirectory(_ path: String) async throws -> [RemoteFile] {
        throw SSHError.commandFailed("Not used")
    }

    func disconnect() {}
}

private final class HostScopeFakeProcessHandle: ProcessHandle {
    let response: String
    private(set) var sentInput = ""
    private(set) var terminated = false

    var isRunning: Bool {
        !terminated
    }

    init(response: String) {
        self.response = response
    }

    func sendInput(_ text: String) async throws {
        sentInput += text
    }

    func readOutput() async throws -> String {
        response
    }

    func outputStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }

    func terminate() {
        terminated = true
    }
}
