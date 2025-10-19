//
//  DeepLinkManager.swift
//  CodeAgentsMobile
//
//  Created by Code Agent on 2025-02-15.
//

import Foundation

/// Parse incoming URLs for MCP server or bundle payloads.
struct DeepLinkParser {
    private let payloadKeys = ["payload", "data", "config", "json"]

    func parse(url: URL) throws -> DeepLinkPayload {
        let lowercasedScheme = url.scheme?.lowercased()

        // Supported patterns:
        // 1. codeagents://mcp/server?payload=...
        // 2. https://<host>/mcp/server?payload=...
        // 3. codeagents://add?type=server&payload=...

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let host = url.host?.lowercased()

        let (category, action): (String?, String?)

        if host == "mcp" {
            category = "mcp"
            action = pathComponents.first
        } else if pathComponents.first?.lowercased() == "mcp" {
            category = "mcp"
            action = pathComponents.dropFirst().first
        } else if host == "add" || pathComponents.first?.lowercased() == "add" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let type = components?.queryItems?.first { $0.name.lowercased() == "type" }?.value?.lowercased()
            category = "mcp"
            action = type
        } else if lowercasedScheme == "mcp", let schemeAction = host ?? pathComponents.first {
            category = "mcp"
            action = schemeAction.lowercased()
        } else {
            throw DeepLinkError("Unsupported deep link: \(url.absoluteString)")
        }

        guard category == "mcp" else {
            throw DeepLinkError("Unsupported deep link category")
        }

        guard let action else {
            throw DeepLinkError("Deep link is missing an action")
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        guard let payloadValue = queryItems.first(where: { payloadKeys.contains($0.name.lowercased()) })?.value else {
            throw DeepLinkError("Deep link is missing payload data")
        }

        guard let data = decodePayload(payloadValue) else {
            throw DeepLinkError("Unable to decode payload data")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys

        switch action.lowercased() {
        case "server", "mcp-server", "add-server":
            let payload = try decoder.decode(DeepLinkServerPayload.self, from: data)
            return .server(payload)
        case "bundle", "mcp-bundle", "bundle-install":
            let payload = try decoder.decode(DeepLinkBundlePayload.self, from: data)
            return .bundle(payload)
        default:
            throw DeepLinkError("Unsupported deep link action: \(action)")
        }
    }

    private func decodePayload(_ value: String) -> Data? {
        // Try direct Base64 decoding first.
        if let data = Data(base64Encoded: value) {
            return data
        }

        // Try URL-safe Base64.
        var sanitized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = sanitized.count % 4
        if padding != 0 {
            sanitized.append(String(repeating: "=", count: 4 - padding))
        }

        if let data = Data(base64Encoded: sanitized) {
            return data
        }

        // Fall back to treating the payload as raw JSON text.
        if let jsonData = value.removingPercentEncoding?.data(using: .utf8) {
            return jsonData
        }

        return value.data(using: .utf8)
    }
}

/// Manages pending deep link requests and surfaces them to SwiftUI views.
@MainActor
final class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let sourceURL: URL
        let payload: DeepLinkPayload
        let suggestedProjectId: UUID?
    }

    @Published var pendingRequest: Request?
    @Published var error: DeepLinkError?

    private let parser = DeepLinkParser()

    private init() {}

    func handle(url: URL) {
        Task {
            do {
                let payload = try parser.parse(url: url)
                let suggestedProject = ProjectContext.shared.activeProject?.id
                let request = Request(sourceURL: url, payload: payload, suggestedProjectId: suggestedProject)
                self.pendingRequest = request
            } catch let error as DeepLinkError {
                self.error = error
            } catch {
                self.error = DeepLinkError(error.localizedDescription)
            }
        }
    }

    func clear(request: Request) {
        if pendingRequest?.id == request.id {
            pendingRequest = nil
        }
    }

    func clearError() {
        error = nil
    }
}
