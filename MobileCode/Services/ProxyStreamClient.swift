//
//  ProxyStreamClient.swift
//  CodeAgentsMobile
//
//  Purpose: Minimal agent-daemon (:8787) HTTP helpers still needed by tasks.
//           Claude proxy *chat* stream / event replay / tool-permission APIs were removed
//           after OpenCode-only chat migration.
//

import Foundation

enum ProxyStreamError: LocalizedError {
    case invalidResponse(String)
    case httpError(status: Int, body: String)

    var statusCode: Int? {
        if case .httpError(let status, _) = self {
            return status
        }
        return nil
    }

    var proxyErrorPayload: [String: Any]? {
        guard case .httpError(_, let body) = self else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return json
    }

    var proxyErrorCode: String? {
        proxyErrorPayload?["error"] as? String
    }

    var proxyErrorMessage: String? {
        proxyErrorPayload?["message"] as? String
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return "Agent daemon response invalid: \(message)"
        case .httpError(let status, let body):
            return "Agent daemon HTTP \(status): \(body)"
        }
    }
}

/// Thin HTTP client for the agent daemon over SSH direct-TCPIP.
/// Tasks still resolve a canonical conversation id before CRUD on `:8787`.
final class ProxyStreamClient {
    private let host: String
    private let port: Int

    init(host: String = "127.0.0.1", port: Int = 8787) {
        self.host = host
        self.port = port
    }

    /// GET /v1/conversations/canonical?cwd=… — used by `ProxyTaskService` for task payloads.
    func fetchCanonicalConversationId(
        session: SSHSession,
        cwd: String
    ) async throws -> String {
        let handle = try await session.openDirectTCPIP(targetHost: host, targetPort: port)
        defer {
            handle.terminate()
        }

        ProxyStreamDiagnostics.log("canonical resolve cwdLen=\(cwd.count)")
        let requestText = buildGetCanonicalRequest(cwd: cwd)
        try await handle.sendInput(requestText)

        let chunkedDecoder = ChunkedBodyDecoder()
        var state = HTTPParseState.headers
        var statusCode: Int?
        var responseBody = ""
        var isChunked = false
        var contentLength: Int?
        var bodyBytes = 0
        var shouldStop = false
        var rawHeaderBuffer = ""

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

        func headerValue(from line: String) -> String? {
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let value = line[line.index(after: separator)...]
            return value.trimmingCharacters(in: .whitespaces)
        }

        func applyHeaders(from headerText: String) throws {
            let lines = headerText.split(whereSeparator: \.isNewline).map(String.init)
            for line in lines {
                if statusCode == nil {
                    statusCode = parseStatusCode(from: line)
                    if statusCode == nil {
                        throw ProxyStreamError.invalidResponse("Missing HTTP status")
                    }
                    continue
                }
                let lowercased = line.lowercased()
                if lowercased.hasPrefix("transfer-encoding:") && lowercased.contains("chunked") {
                    isChunked = true
                }
                if lowercased.hasPrefix("content-length:") {
                    if let length = Int(headerValue(from: line) ?? "") {
                        contentLength = length
                        if length == 0 {
                            shouldStop = true
                        }
                    }
                }
            }
        }

        func appendBody(_ chunk: String) {
            if isChunked {
                let decodedChunks = chunkedDecoder.addData(chunk)
                for decoded in decodedChunks {
                    responseBody += decoded
                    bodyBytes += decoded.utf8.count
                }
                if chunkedDecoder.isFinished {
                    shouldStop = true
                }
            } else {
                responseBody += chunk
                if contentLength != nil {
                    bodyBytes += chunk.utf8.count
                }
            }
            if let contentLength, !isChunked, bodyBytes >= contentLength {
                shouldStop = true
            }
        }

        for try await chunk in handle.outputStream() {
            if state == .headers {
                rawHeaderBuffer += chunk
                if let parts = splitHeader(from: rawHeaderBuffer) {
                    rawHeaderBuffer = ""
                    try applyHeaders(from: parts.header)
                    state = (statusCode == 200) ? .body : .error
                    if !parts.body.isEmpty {
                        appendBody(parts.body)
                    }
                    if shouldStop {
                        handle.terminate()
                        break
                    }
                }
                continue
            }

            appendBody(chunk)
            if shouldStop {
                handle.terminate()
                break
            }
        }

        if let statusCode, statusCode != 200 {
            throw ProxyStreamError.httpError(
                status: statusCode,
                body: responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        if case .headers = state {
            if rawHeaderBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ProxyStreamError.invalidResponse("No HTTP body received")
            }
        }

        guard let data = responseBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let canonicalId = json["canonical_id"] as? String,
              !canonicalId.isEmpty else {
            throw ProxyStreamError.invalidResponse("Missing canonical_id")
        }

        ProxyStreamDiagnostics.log("canonical resolved conv=...\(canonicalId.suffix(6))")
        return canonicalId
    }

    private func buildGetCanonicalRequest(cwd: String) -> String {
        let encodedCwd = cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cwd
        let path = "/v1/conversations/canonical?cwd=\(encodedCwd)"
        let headers = [
            "GET \(path) HTTP/1.1",
            "Host: \(host):\(port)",
            "Accept: application/json",
            "Connection: close"
        ]
        return headers.joined(separator: "\r\n") + "\r\n\r\n"
    }
}

private enum HTTPParseState {
    case headers
    case body
    case error
}

private final class ChunkedBodyDecoder {
    private var buffer = Data()
    private var expectedSize: Int?
    private var finished = false
    var isFinished: Bool { finished }

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
