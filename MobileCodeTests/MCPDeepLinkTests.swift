//
//  MCPDeepLinkTests.swift
//  MobileCodeTests
//
//  Created by Code Agent on 2025-02-15.
//

import Testing
@testable import CodeAgentsMobile
import Foundation

@MainActor
struct MCPDeepLinkTests {
    private let parser = DeepLinkParser()

    @Test func parseServerDeepLink() throws {
        let serverJSON = """
        {
            "name": "firecrawl",
            "type": "stdio",
            "command": "npx",
            "args": ["-y", "firecrawl-mcp"],
            "env": {
                "FIRECRAWL_API_KEY": "test"
            },
            "scope": "project"
        }
        """

        let encoded = serverJSON.data(using: .utf8)!.base64EncodedString()
        let url = URL(string: "codeagents://mcp/server?payload=\(encoded)")!

        let payload = try parser.parse(url: url)

        switch payload {
        case .server(let server):
            #expect(server.name == "firecrawl")
            #expect(server.command == "npx")
            #expect(server.args == ["-y", "firecrawl-mcp"])
            #expect(server.env?["FIRECRAWL_API_KEY"] == "test")
            #expect(server.scope == .project)
            #expect(server.type == "stdio")
        default:
            Issue.record("Expected server payload")
        }
    }

    @Test func parseBundleDeepLink() throws {
        let bundleJSON = """
        {
            "bundleName": "Starter",
            "servers": {
                "search": {
                    "type": "http",
                    "url": "https://example.com/mcp"
                },
                "playwright": {
                    "command": "npx",
                    "args": ["@playwright/mcp@latest"]
                }
            }
        }
        """

        let encoded = bundleJSON.data(using: .utf8)!.base64EncodedString()
        let url = URL(string: "https://example.com/mcp/bundle?payload=\(encoded)")!

        let payload = try parser.parse(url: url)

        switch payload {
        case .bundle(let bundle):
            #expect(bundle.name == "Starter")
            #expect(bundle.servers.count == 2)
            #expect(bundle.servers.contains(where: { $0.name == "search" && $0.url == "https://example.com/mcp" && $0.type == "http" }))
            #expect(bundle.servers.contains(where: { $0.name == "playwright" && $0.command == "npx" }))
        default:
            Issue.record("Expected bundle payload")
        }
    }

    @Test func importerRenamesDuplicateServers() async throws {
        let project = RemoteProject(name: "Demo", serverId: UUID())
        let existing = [
            MCPServer(name: "firecrawl", command: "npx", args: ["-y", "firecrawl-mcp"], env: nil, url: nil, headers: nil)
        ]
        let mockService = MockMCPService(existing: existing)
        let importer = MCPDeepLinkImporter(service: mockService)

        let payload = DeepLinkServerPayload(
            name: "firecrawl",
            command: "uv",
            args: ["run", "server"],
            env: nil,
            url: nil,
            headers: nil,
            scope: .project
        )

        let summary = try await importer.importServer(payload, into: project)

        #expect(summary.addedServers.count == 1)
        #expect(summary.addedServers.first?.finalName == "firecrawl-2")
        #expect(mockService.addedServers.first?.server.name == "firecrawl-2")
    }

    @Test func importerHandlesBundles() async throws {
        let project = RemoteProject(name: "Bundle", serverId: UUID())
        let mockService = MockMCPService(existing: [])
        let importer = MCPDeepLinkImporter(service: mockService)

        let bundle = DeepLinkBundlePayload(
            name: "Utilities",
            servers: [
                DeepLinkServerPayload(name: "search", url: "https://example.com/mcp", headers: nil, scope: .project),
                DeepLinkServerPayload(name: "search", command: "npx", args: ["-y", "firecrawl"], env: nil, headers: nil, scope: .project)
            ]
        )

        let summary = try await importer.importBundle(bundle, into: project)

        #expect(summary.addedServers.count == 2)
        let finalNames = summary.addedServers.map { $0.finalName }
        #expect(finalNames.contains("search"))
        #expect(finalNames.contains("search-2"))
    }

    @Test func importerPreservesRemoteType() async throws {
        let project = RemoteProject(name: "Type", serverId: UUID())
        let mockService = MockMCPService(existing: [])
        let importer = MCPDeepLinkImporter(service: mockService)

        let payload = DeepLinkServerPayload(
            name: "realtime",
            type: "sse",
            command: nil,
            args: nil,
            env: nil,
            url: "https://example.com/mcp",
            headers: nil,
            scope: .project
        )

        let summary = try await importer.importServer(payload, into: project)

        #expect(summary.addedServers.count == 1)
        #expect(mockService.addedServers.first?.server.type == "sse")
        #expect(mockService.addedServers.first?.server.generateAddJsonCommand()?.contains("\"type\":\"sse\"") == true)
    }
}

@MainActor
private final class MockMCPService: MCPServerManaging {
    var existingServers: [MCPServer]
    var addedServers: [(server: MCPServer, scope: MCPServer.MCPScope, project: RemoteProject)] = []

    init(existing: [MCPServer]) {
        self.existingServers = existing
    }

    func fetchServers(for project: RemoteProject) async throws -> [MCPServer] {
        existingServers
    }

    func addServer(_ server: MCPServer, scope: MCPServer.MCPScope, for project: RemoteProject) async throws {
        addedServers.append((server: server, scope: scope, project: project))
        existingServers.append(server)
    }
}
