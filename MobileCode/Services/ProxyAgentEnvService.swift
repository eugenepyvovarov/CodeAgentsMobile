//
//  ProxyAgentEnvService.swift
//  CodeAgentsMobile
//
//  Purpose: Sync per-agent environment variables with the Claude proxy
//

import Foundation

struct ProxyAgentEnvItem: Codable, Hashable {
    let key: String
    let value: String
    let enabled: Bool?

    init(key: String, value: String, enabled: Bool? = nil) {
        self.key = key
        self.value = value
        self.enabled = enabled
    }
}

@MainActor
final class ProxyAgentEnvService {
    static let shared = ProxyAgentEnvService()

    private let client = ProxyAgentEnvClient()
    private let sshService = SSHService.shared

    private init() {}

    func fetchEnv(agentId: String, project: RemoteProject) async throws -> [ProxyAgentEnvItem] {
        let session = try await sshService.getConnection(for: project, purpose: .claude)
        let path = "/v1/agent/env?agent_id=\(agentId)"
        let response = try await client.request(session: session, method: "GET", path: path, body: nil)
        return try decodeEnvList(from: response.body)
    }

    func replaceEnv(agentId: String, env: [ProxyAgentEnvItem], project: RemoteProject) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .claude)
        let payload = ProxyAgentEnvReplaceRequest(agentId: agentId, env: env)
        let data = try JSONEncoder().encode(payload)
        let body = String(data: data, encoding: .utf8) ?? "{}"
        _ = try await client.request(session: session, method: "PUT", path: "/v1/agent/env", body: body)
    }

    private func decodeEnvList(from body: String) throws -> [ProxyAgentEnvItem] {
        guard let data = body.data(using: .utf8) else { return [] }
        let decoded = try JSONDecoder().decode(ProxyAgentEnvListResponse.self, from: data)
        return decoded.env
    }
}

private struct ProxyAgentEnvListResponse: Decodable {
    let env: [ProxyAgentEnvItem]
}

private struct ProxyAgentEnvReplaceRequest: Encodable {
    let agentId: String
    let env: [ProxyAgentEnvItem]

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case env
    }
}

private struct ProxyHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: String
}

private final class ProxyAgentEnvClient {
    private let host: String
    private let port: Int

    init(host: String = "127.0.0.1", port: Int = 8787) {
        self.host = host
        self.port = port
    }

    func request(session: SSHSession,
                 method: String,
                 path: String,
                 body: String?) async throws -> ProxyHTTPResponse {
        try await withThrowingTaskGroup(of: ProxyHTTPResponse.self) { group in
            group.addTask {
                try await self.performRequest(session: session, method: method, path: path, body: body)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                throw ProxyTaskError.invalidResponse("Proxy request timed out")
            }
            defer {
                group.cancelAll()
            }
            guard let response = try await group.next() else {
                throw ProxyTaskError.invalidResponse("No response")
            }
            return response
        }
    }

    private func performRequest(session: SSHSession,
                                method: String,
                                path: String,
                                body: String?) async throws -> ProxyHTTPResponse {
        let handle = try await session.openDirectTCPIP(targetHost: host, targetPort: port)
        defer {
            handle.terminate()
        }

        let requestText = buildRequest(method: method, path: path, body: body)
        try await handle.sendInput(requestText)

        var state = ProxyHTTPParseState.headers
        var statusCode: Int? = nil
        var headers: [String: String] = [:]
        var rawHeaderBuffer = ""
        var isChunked = false
        var contentLength: Int? = nil
        var shouldStop = false
        var bodyText = ""
        let chunkedDecoder = ProxyChunkedBodyDecoder()

        func splitHeader(from buffer: String) -> (header: String, body: String)? {
            if let range = buffer.range(of: "\r\n\r\n") {
                let header = String(buffer[..<range.lowerBound])
                let body = String(buffer[range.upperBound...])
                return (header, body)
            }
            if let range = buffer.range(of: "\n\n") {
                let header = String(buffer[..<range.lowerBound])
                let body = String(buffer[range.upperBound...])
                return (header, body)
            }
            return nil
        }

        func parseStatusCode(from line: String) -> Int? {
            guard line.starts(with: "HTTP/") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return Int(parts[1])
        }

        func applyHeaders(from headerText: String) throws {
            let lines = headerText.split(whereSeparator: \.isNewline).map(String.init)
            for line in lines {
                if statusCode == nil {
                    statusCode = parseStatusCode(from: line)
                    if statusCode == nil {
                        throw ProxyTaskError.invalidResponse("Missing HTTP status")
                    }
                    continue
                }

                guard let separator = line.firstIndex(of: ":") else { continue }
                let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
                if key == "transfer-encoding", value.lowercased().contains("chunked") {
                    isChunked = true
                }
                if key == "content-length", let length = Int(value) {
                    contentLength = length
                }
            }
        }

        func appendBody(_ chunk: String) {
            if isChunked {
                let decodedChunks = chunkedDecoder.addData(chunk)
                for decoded in decodedChunks {
                    bodyText += decoded
                }
            } else {
                bodyText += chunk
            }
            if let contentLength, !isChunked, bodyText.utf8.count >= contentLength {
                shouldStop = true
            }
        }

        for try await chunk in handle.outputStream() {
            try Task.checkCancellation()
            if state == .headers {
                rawHeaderBuffer += chunk
                if let parts = splitHeader(from: rawHeaderBuffer) {
                    rawHeaderBuffer = ""
                    try applyHeaders(from: parts.header)
                    state = .body
                    if !parts.body.isEmpty {
                        appendBody(parts.body)
                    }
                    if shouldStop || contentLength == 0 {
                        handle.terminate()
                        break
                    }
                }
                continue
            }

            if state == .body {
                appendBody(chunk)
                if shouldStop {
                    handle.terminate()
                    break
                }
            }
        }

        guard let finalStatus = statusCode else {
            throw ProxyTaskError.invalidResponse("No HTTP status")
        }

        if finalStatus >= 400 {
            throw ProxyTaskError.httpError(status: finalStatus, body: bodyText)
        }

        return ProxyHTTPResponse(statusCode: finalStatus, headers: headers, body: bodyText)
    }

    private func buildRequest(method: String, path: String, body: String?) -> String {
        var headers = [
            "\(method) \(path) HTTP/1.1",
            "Host: \(host):\(port)",
            "Accept: application/json",
            "Connection: close"
        ]

        let bodyText = body ?? ""
        if !bodyText.isEmpty {
            headers.append("Content-Type: application/json")
            headers.append("Content-Length: \(bodyText.utf8.count)")
        }

        return headers.joined(separator: "\r\n") + "\r\n\r\n" + bodyText
    }
}

private enum ProxyHTTPParseState {
    case headers
    case body
}

private final class ProxyChunkedBodyDecoder {
    private var buffer = Data()
    private var expectedSize: Int? = nil
    private var finished = false

    func addData(_ data: String) -> [String] {
        guard !finished, let newData = data.data(using: .utf8) else { return [] }
        buffer.append(newData)
        var output: [String] = []

        while true {
            if expectedSize == nil {
                guard let range = buffer.range(of: Data([0x0d, 0x0a])) else { break }
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                let sizeToken = line.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let size = Int(sizeToken, radix: 16) else { continue }
                if size == 0 {
                    finished = true
                    break
                }
                expectedSize = size
            }

            guard let size = expectedSize else { break }
            if buffer.count < size + 2 { break }

            let chunkData = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + size))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + size + 2))
            expectedSize = nil

            if let chunkString = String(data: chunkData, encoding: .utf8) {
                output.append(chunkString)
            }
        }

        return output
    }
}

