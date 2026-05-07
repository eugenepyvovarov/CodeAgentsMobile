//
//  OpenCodeClient.swift
//  CodeAgentsMobile
//
//  Purpose: Low-level OpenCode HTTP client over SSH direct TCP/IP
//

import Foundation

struct OpenCodeClientConfiguration: Equatable {
    var host: String = "127.0.0.1"
    var port: Int = 4096
    var username: String = "opencode"
    var password: String?
    var requestTimeoutSeconds: TimeInterval = 30
}

enum OpenCodeHTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

struct OpenCodeHTTPResponse: Equatable {
    let statusCode: Int
    let headers: [String: String]
    let body: String
}

struct OpenCodeHealth: Decodable, Equatable {
    let healthy: Bool
    let version: String
}

enum OpenCodeClientError: LocalizedError, Equatable {
    case invalidRequest(String)
    case invalidResponse(String)
    case httpError(status: Int, body: String)
    case decodingFailed(String)
    case requestTimedOut(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return "OpenCode request invalid: \(message)"
        case .invalidResponse(let message):
            return "OpenCode response invalid: \(message)"
        case .httpError(let status, let body):
            return "OpenCode HTTP \(status): \(body)"
        case .decodingFailed(let message):
            return "OpenCode response decoding failed: \(message)"
        case .requestTimedOut(let seconds):
            return "OpenCode request timed out after \(seconds) seconds"
        }
    }
}

final class OpenCodeClient {
    private let configuration: OpenCodeClientConfiguration
    private let decoder: JSONDecoder

    init(configuration: OpenCodeClientConfiguration = OpenCodeClientConfiguration()) {
        self.configuration = configuration
        self.decoder = JSONDecoder()
    }

    func health(session: SSHSession) async throws -> OpenCodeHealth {
        try await jsonRequest(
            session: session,
            method: .get,
            path: "/global/health",
            responseType: OpenCodeHealth.self
        )
    }

    func jsonRequest<Response: Decodable>(
        session: SSHSession,
        method: OpenCodeHTTPMethod,
        path: String,
        body: String? = nil,
        responseType: Response.Type
    ) async throws -> Response {
        let response = try await request(session: session, method: method, path: path, body: body)
        guard let data = response.body.data(using: .utf8) else {
            throw OpenCodeClientError.decodingFailed("Response body is not UTF-8")
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw OpenCodeClientError.decodingFailed(
                decodingFailureMessage(
                    error: error,
                    method: method,
                    path: path,
                    statusCode: response.statusCode,
                    responseType: Response.self,
                    body: response.body
                )
            )
        }
    }

    func request(
        session: SSHSession,
        method: OpenCodeHTTPMethod,
        path: String,
        body: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> OpenCodeHTTPResponse {
        let handle = try await session.openDirectTCPIP(
            targetHost: configuration.host,
            targetPort: configuration.port
        )
        defer {
            handle.terminate()
        }

        let requestText = try buildHTTPRequest(method: method, path: path, body: body, headers: headers)
        try await handle.sendInput(requestText)

        let responseText = try await withRequestTimeout(
            seconds: configuration.requestTimeoutSeconds,
            onTimeout: { handle.terminate() },
            operation: { try await self.readResponseText(from: handle) }
        )

        let response = try OpenCodeHTTPResponseParser.parse(responseText)
        guard (200...299).contains(response.statusCode) else {
            throw OpenCodeClientError.httpError(status: response.statusCode, body: response.body)
        }
        return response
    }

    func streamEvents(
        session: SSHSession,
        path: String = "/event"
    ) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { continuation in
            let lifetime = OpenCodeStreamLifetime()
            lifetime.task = Task {
                do {
                    let handle = try await session.openDirectTCPIP(
                        targetHost: configuration.host,
                        targetPort: configuration.port
                    )
                    lifetime.handle = handle
                    defer {
                        handle.terminate()
                    }

                    let requestText = try buildHTTPRequest(
                        method: .get,
                        path: path,
                        body: nil,
                        headers: ["Accept": "text/event-stream"]
                    )
                    try await handle.sendInput(requestText)

                    let chunkedDecoder = OpenCodeChunkedBodyStreamDecoder()
                    let sseParser = OpenCodeSSEStreamParser()
                    var state = OpenCodeHTTPStreamState.headers
                    var rawHeaderBuffer = ""
                    var statusCode: Int?
                    var errorBody = ""
                    var isChunked = false

                    func splitHeader(from buffer: String) -> (header: String, body: String)? {
                        if let range = buffer.range(of: "\r\n\r\n") {
                            return (String(buffer[..<range.lowerBound]), String(buffer[range.upperBound...]))
                        }
                        if let range = buffer.range(of: "\n\n") {
                            return (String(buffer[..<range.lowerBound]), String(buffer[range.upperBound...]))
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
                        guard let statusLine = lines.first,
                              let parsedStatusCode = parseStatusCode(from: statusLine) else {
                            throw OpenCodeClientError.invalidResponse("Missing HTTP status")
                        }
                        statusCode = parsedStatusCode

                        for line in lines.dropFirst() {
                            let lowercased = line.lowercased()
                            if lowercased.hasPrefix("transfer-encoding:") && lowercased.contains("chunked") {
                                isChunked = true
                            }
                        }
                    }

                    func yieldEvents(from bodyChunk: String) throws {
                        let decodedChunks = isChunked ? chunkedDecoder.addData(bodyChunk) : [bodyChunk]
                        for decoded in decodedChunks {
                            let serverSentEvents = sseParser.consume(decoded)
                            for serverSentEvent in serverSentEvents {
                                continuation.yield(try OpenCodeEventMapper.decode(serverSentEvent))
                            }
                        }
                    }

                    for try await chunk in handle.outputStream() {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        switch state {
                        case .headers:
                            rawHeaderBuffer += chunk
                            guard let parts = splitHeader(from: rawHeaderBuffer) else { continue }
                            rawHeaderBuffer = ""
                            try applyHeaders(from: parts.header)
                            state = statusCode == 200 ? .sse : .error
                            if !parts.body.isEmpty {
                                if state == .sse {
                                    try yieldEvents(from: parts.body)
                                } else {
                                    errorBody += parts.body
                                }
                            }
                        case .sse:
                            try yieldEvents(from: chunk)
                        case .error:
                            errorBody += chunk
                        }
                    }

                    if let statusCode, statusCode != 200 {
                        throw OpenCodeClientError.httpError(status: statusCode, body: errorBody)
                    }
                    if state == .headers {
                        throw OpenCodeClientError.invalidResponse("No HTTP event stream received")
                    }

                    for serverSentEvent in sseParser.finish() {
                        continuation.yield(try OpenCodeEventMapper.decode(serverSentEvent))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                lifetime.cancel()
            }
        }
    }

    private func buildHTTPRequest(
        method: OpenCodeHTTPMethod,
        path: String,
        body: String?,
        headers: [String: String]
    ) throws -> String {
        guard path.hasPrefix("/") else {
            throw OpenCodeClientError.invalidRequest("Path must start with /")
        }

        let bodyData = body?.data(using: .utf8)
        if body != nil && bodyData == nil {
            throw OpenCodeClientError.invalidRequest("Body is not UTF-8")
        }

        var requestHeaders: [String] = [
            "\(method.rawValue) \(path) HTTP/1.1",
            "Host: \(configuration.host):\(configuration.port)",
            "Connection: close"
        ]

        if headers.keys.contains(where: { $0.lowercased() == "accept" }) == false {
            requestHeaders.append("Accept: application/json")
        }

        if let password = configuration.password {
            let credentials = "\(configuration.username):\(password)"
            let encoded = Data(credentials.utf8).base64EncodedString()
            requestHeaders.append("Authorization: Basic \(encoded)")
        }

        for (key, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            requestHeaders.append("\(key): \(value)")
        }

        if let bodyData {
            requestHeaders.append("Content-Type: application/json")
            requestHeaders.append("Content-Length: \(bodyData.count)")
        }

        return requestHeaders.joined(separator: "\r\n") + "\r\n\r\n" + (body ?? "")
    }

    private func readResponseText(from handle: ProcessHandle) async throws -> String {
        var responseText = ""
        for try await chunk in handle.outputStream() {
            responseText += chunk
            if OpenCodeHTTPResponseParser.isComplete(responseText) {
                return responseText
            }
        }
        return responseText
    }

    private func withRequestTimeout<T>(
        seconds: TimeInterval,
        onTimeout: @escaping () -> Void,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        guard seconds > 0 else {
            return try await operation()
        }

        let timeoutNanoseconds = UInt64(max(1, (seconds * 1_000_000_000).rounded()))
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                onTimeout()
                throw OpenCodeClientError.requestTimedOut(seconds: seconds)
            }

            guard let result = try await group.next() else {
                onTimeout()
                throw OpenCodeClientError.requestTimedOut(seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }

    private func decodingFailureMessage<Response>(
        error: Error,
        method: OpenCodeHTTPMethod,
        path: String,
        statusCode: Int,
        responseType: Response.Type,
        body: String
    ) -> String {
        let context = decodingContext(from: error) ?? error.localizedDescription
        return "\(method.rawValue) \(path) returned HTTP \(statusCode) but could not decode \(responseType): \(context). Body preview: \(responsePreview(body))"
    }

    private func decodingContext(from error: Error) -> String? {
        switch error {
        case let DecodingError.typeMismatch(type, context):
            return "type mismatch for \(type) at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case let DecodingError.valueNotFound(type, context):
            return "missing value for \(type) at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case let DecodingError.keyNotFound(key, context):
            return "missing key '\(key.stringValue)' at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        case let DecodingError.dataCorrupted(context):
            return "data corrupted at \(codingPathDescription(context.codingPath)): \(context.debugDescription)"
        default:
            return nil
        }
    }

    private func codingPathDescription(_ path: [CodingKey]) -> String {
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "<root>" : value
    }

    private func responsePreview(_ body: String, limit: Int = 500) -> String {
        let normalized = body
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        if normalized.count <= limit {
            return normalized.isEmpty ? "<empty>" : normalized
        }
        return String(normalized.prefix(limit)) + "...<truncated>"
    }
}

private enum OpenCodeHTTPStreamState {
    case headers
    case sse
    case error
}

private final class OpenCodeStreamLifetime: @unchecked Sendable {
    var handle: ProcessHandle?
    var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        handle?.terminate()
    }
}

private enum OpenCodeHTTPResponseParser {
    static func isComplete(_ responseText: String) -> Bool {
        guard let parts = splitHeaderAndBody(responseText) else { return false }
        let headers = parseHeaders(from: parts.header)

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return hasCompleteChunkedBody(parts.body)
        }

        if let lengthValue = headers["content-length"],
           let length = Int(lengthValue) {
            return parts.body.utf8.count >= length
        }

        return false
    }

    static func parse(_ responseText: String) throws -> OpenCodeHTTPResponse {
        guard let parts = splitHeaderAndBody(responseText) else {
            throw OpenCodeClientError.invalidResponse("Missing header/body separator")
        }

        let rawBody = parts.body
        let headerLines = parts.header
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard let statusLine = headerLines.first else {
            throw OpenCodeClientError.invalidResponse("Missing status line")
        }

        let statusParts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw OpenCodeClientError.invalidResponse("Invalid status line: \(statusLine)")
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let body: String
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunkedBody(rawBody)
        } else if let lengthValue = headers["content-length"],
                  let length = Int(lengthValue),
                  let truncated = rawBody.data(using: .utf8).flatMap({ data -> String? in
                      guard data.count >= length else { return nil }
                      return String(data: data.prefix(length), encoding: .utf8)
                  }) {
            body = truncated
        } else {
            body = rawBody
        }

        return OpenCodeHTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }

    private static func splitHeaderAndBody(_ responseText: String) -> (header: String, body: String)? {
        if let headerRange = responseText.range(of: "\r\n\r\n") {
            return (String(responseText[..<headerRange.lowerBound]), String(responseText[headerRange.upperBound...]))
        }
        if let headerRange = responseText.range(of: "\n\n") {
            return (String(responseText[..<headerRange.lowerBound]), String(responseText[headerRange.upperBound...]))
        }
        return nil
    }

    private static func parseHeaders(from headerText: String) -> [String: String] {
        let headerLines = headerText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private static func hasCompleteChunkedBody(_ rawBody: String) -> Bool {
        let bytes = Array(rawBody.utf8)
        var index = 0

        while true {
            while index < bytes.count {
                if bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                } else if bytes[index] == 10 {
                    index += 1
                } else {
                    break
                }
            }

            guard let lineEnd = lineEnd(in: bytes, startingAt: index) else {
                return false
            }

            let sizeLine = String(decoding: bytes[index..<lineEnd.contentEnd], as: UTF8.self)
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard let size = Int(sizeLine, radix: 16) else {
                return false
            }

            index = lineEnd.afterLineBreak
            if size == 0 {
                return true
            }

            guard index + size <= bytes.count else {
                return false
            }
            index += size

            if index + 1 < bytes.count, bytes[index] == 13, bytes[index + 1] == 10 {
                index += 2
            } else if index < bytes.count, bytes[index] == 10 {
                index += 1
            } else {
                return false
            }
        }
    }

    private static func decodeChunkedBody(_ rawBody: String) throws -> String {
        let bytes = Array(rawBody.utf8)
        var index = 0
        var decoded: [UInt8] = []

        while true {
            while index < bytes.count {
                if bytes[index] == 13, index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                } else if bytes[index] == 10 {
                    index += 1
                } else {
                    break
                }
            }

            guard let lineEnd = lineEnd(in: bytes, startingAt: index) else {
                throw OpenCodeClientError.invalidResponse("Incomplete chunk size")
            }

            let sizeLine = String(decoding: bytes[index..<lineEnd.contentEnd], as: UTF8.self)
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard let size = Int(sizeLine, radix: 16) else {
                throw OpenCodeClientError.invalidResponse("Invalid chunk size: \(sizeLine)")
            }

            index = lineEnd.afterLineBreak
            if size == 0 {
                guard let body = String(data: Data(decoded), encoding: .utf8) else {
                    throw OpenCodeClientError.invalidResponse("Chunked body is not UTF-8")
                }
                return body
            }

            guard index + size <= bytes.count else {
                throw OpenCodeClientError.invalidResponse("Incomplete chunk body")
            }

            decoded.append(contentsOf: bytes[index..<index + size])
            index += size

            if index + 1 < bytes.count, bytes[index] == 13, bytes[index + 1] == 10 {
                index += 2
            } else if index < bytes.count, bytes[index] == 10 {
                index += 1
            } else {
                throw OpenCodeClientError.invalidResponse("Missing chunk terminator")
            }
        }
    }

    private static func lineEnd(in bytes: [UInt8], startingAt startIndex: Int) -> (contentEnd: Int, afterLineBreak: Int)? {
        guard startIndex < bytes.count else { return nil }

        for index in startIndex..<bytes.count where bytes[index] == 10 {
            let contentEnd = index > startIndex && bytes[index - 1] == 13 ? index - 1 : index
            return (contentEnd: contentEnd, afterLineBreak: index + 1)
        }

        return nil
    }
}

private final class OpenCodeChunkedBodyStreamDecoder {
    private var buffer = Data()
    private var expectedSize: Int?
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
            guard buffer.count >= size + 2 else { break }

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
