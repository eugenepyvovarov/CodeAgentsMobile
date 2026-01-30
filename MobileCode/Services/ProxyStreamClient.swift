//
//  ProxyStreamClient.swift
//  CodeAgentsMobile
//
//  Purpose: Stream Claude proxy SSE responses over SSH direct TCP/IP
//

import Foundation

struct ProxyStreamRequest {
    let agentId: String?
    let conversationId: String
    let conversationGroup: String?
    let text: String?
    let cwd: String
    let allowedTools: [String]
    let systemPrompt: String?
    let maxTurns: Int?
    let toolApprovals: ToolApprovalsPayload?

    func jsonBody() throws -> String {
        var payload: [String: Any] = [
            "conversation_id": conversationId,
            "cwd": cwd,
            "allowed_tools": allowedTools
        ]

        if let agentId = agentId, !agentId.isEmpty {
            payload["agent_id"] = agentId
        }
        if let conversationGroup = conversationGroup, !conversationGroup.isEmpty {
            payload["conversation_group"] = conversationGroup
        }
        if let text = text, !text.isEmpty {
            payload["text"] = text
        }
        if let systemPrompt = systemPrompt {
            payload["system_prompt"] = systemPrompt
        }
        if let maxTurns = maxTurns {
            payload["max_turns"] = maxTurns
        }
        if let toolApprovals = toolApprovals {
            payload["tool_approvals"] = toolApprovals.jsonPayload()
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

struct ToolApprovalsPayload {
    let allow: [String]
    let deny: [String]

    func jsonPayload() -> [String: Any] {
        [
            "allow": allow,
            "deny": deny
        ]
    }
}

struct ProxyStreamEvent {
    let eventId: Int?
    let jsonLine: String
}

enum ProxyStreamError: LocalizedError {
    case invalidResponse(String)
    case httpError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return "Proxy response invalid: \(message)"
        case .httpError(let status, let body):
            return "Proxy HTTP \(status): \(body)"
        }
    }
}

struct ProxyResponseInfo {
    let version: String?
    let startedAt: String?
}

final class ProxyStreamClient {
    private let host: String
    private let port: Int

    init(host: String = "127.0.0.1", port: Int = 8787) {
        self.host = host
        self.port = port
    }

    func stream(
        session: SSHSession,
        request: ProxyStreamRequest,
        lastEventId: Int?
    ) -> AsyncThrowingStream<ProxyStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var handle: ProcessHandle?

                defer {
                    handle?.terminate()
                }

                do {
                    handle = try await session.openDirectTCPIP(targetHost: host, targetPort: port)
                    let body = try request.jsonBody()
                    let conversationSuffix = request.conversationId.suffix(6)
                    ProxyStreamDiagnostics.log(
                        "stream start conv=...\(conversationSuffix) lastEventId=\(lastEventId?.description ?? "nil") textLen=\(request.text?.count ?? 0) cwdLen=\(request.cwd.count) tools=\(request.allowedTools.count) bodyBytes=\(body.utf8.count)"
                    )
                    let requestText = buildPostRequest(body: body, lastEventId: lastEventId)
                    try await handle?.sendInput(requestText)

                    let bodyLineBuffer = StreamingLineBuffer()
                    let chunkedDecoder = ChunkedBodyDecoder()
                    let sseParser = SSEParser()
                    var state = HTTPParseState.headers
                    var statusCode: Int? = nil
                    var errorBody = ""
                    var isChunked = false
                    var responseInfo = ProxyResponseInfo(version: nil, startedAt: nil)
                    var rawHeaderBuffer = ""

                    func headerValue(from line: String) -> String? {
                        guard let separator = line.firstIndex(of: ":") else { return nil }
                        let value = line[line.index(after: separator)...]
                        return value.trimmingCharacters(in: .whitespaces)
                    }
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
                    func applyHeaders(from headerText: String) throws {
                        let lines = headerText.split(whereSeparator: \.isNewline).map(String.init)
                        for line in lines {
                            if statusCode == nil {
                                statusCode = parseStatusCode(from: line)
                                if statusCode == nil {
                                    throw ProxyStreamError.invalidResponse("Missing HTTP status")
                                }
                                ProxyStreamDiagnostics.log("stream status=\(statusCode ?? -1)")
                                continue
                            }
                            let lowercased = line.lowercased()
                            if lowercased.hasPrefix("x-proxy-version:") {
                                responseInfo = ProxyResponseInfo(
                                    version: headerValue(from: line),
                                    startedAt: responseInfo.startedAt
                                )
                            }
                            if lowercased.hasPrefix("x-proxy-started-at:") {
                                responseInfo = ProxyResponseInfo(
                                    version: responseInfo.version,
                                    startedAt: headerValue(from: line)
                                )
                            }
                            if lowercased.hasPrefix("transfer-encoding:") && lowercased.contains("chunked") {
                                isChunked = true
                                ProxyStreamDiagnostics.log("stream transfer-encoding=chunked")
                            }
                        }
                    }

                    func handleSSELine(_ rawLine: String) {
                        let sanitized = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                        let events = sseParser.consume(line: sanitized)
                        for event in events {
                            ProxyStreamDiagnostics.log(
                                "stream event id=\(event.eventId?.description ?? "nil") \(ProxyStreamDiagnostics.summarize(line: event.jsonLine))"
                            )
                            continuation.yield(event)
                        }
                    }

                    func handleBodyChunk(_ chunk: String) {
                        if isChunked {
                            let decodedChunks = chunkedDecoder.addData(chunk)
                            for decoded in decodedChunks {
                                ProxyStreamDiagnostics.logRaw("body chunk", decoded)
                                let lines = bodyLineBuffer.addData(decoded)
                                for rawLine in lines {
                                    handleSSELine(rawLine)
                                }
                            }
                        } else {
                            ProxyStreamDiagnostics.logRaw("body chunk", chunk)
                            let lines = bodyLineBuffer.addData(chunk)
                            for rawLine in lines {
                                handleSSELine(rawLine)
                            }
                        }
                    }

                    if let handle = handle {
                        for try await chunk in handle.outputStream() {
                            ProxyStreamDiagnostics.logRaw("tcp chunk", chunk)
                            if state == .headers {
                                rawHeaderBuffer += chunk
                                if let parts = splitHeader(from: rawHeaderBuffer) {
                                    rawHeaderBuffer = ""
                                    try applyHeaders(from: parts.header)
                                    state = (statusCode == 200) ? .sse : .error
                                    if !parts.body.isEmpty {
                                        if state == .sse {
                                            handleBodyChunk(parts.body)
                                        } else {
                                            errorBody += parts.body
                                        }
                                    }
                                }
                                continue
                            }

                            if state == .error {
                                errorBody += chunk
                                continue
                            }

                            if state == .sse {
                                handleBodyChunk(chunk)
                            }
                        }
                    }

                    if case .sse = state, let remaining = bodyLineBuffer.flush() {
                        handleSSELine(remaining)
                    } else if case .error = state, !rawHeaderBuffer.isEmpty {
                        errorBody += rawHeaderBuffer
                    }

                    if let statusCode = statusCode, statusCode != 200 {
                        throw ProxyStreamError.httpError(status: statusCode, body: errorBody.trimmingCharacters(in: .whitespacesAndNewlines))
                    }

                    if case .headers = state {
                        throw ProxyStreamError.invalidResponse("No HTTP body received")
                    }

                    for event in sseParser.flush() {
                        ProxyStreamDiagnostics.log(
                            "stream event id=\(event.eventId?.description ?? "nil") \(ProxyStreamDiagnostics.summarize(line: event.jsonLine))"
                        )
                        continuation.yield(event)
                    }

                    if responseInfo.version != nil || responseInfo.startedAt != nil {
                        ProxyStreamDiagnostics.log(
                            "stream proxy version=\(responseInfo.version ?? "nil") startedAt=\(responseInfo.startedAt ?? "nil")"
                        )
                    }

                    continuation.finish()
                } catch {
                    ProxyStreamDiagnostics.log("stream error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func fetchEvents(
        session: SSHSession,
        conversationId: String,
        since: Int,
        cwd: String?,
        conversationGroup: String?
    ) async throws -> ([ProxyStreamEvent], ProxyResponseInfo) {
        let handle = try await session.openDirectTCPIP(targetHost: host, targetPort: port)
        defer {
            handle.terminate()
        }

        let conversationSuffix = conversationId.suffix(6)
        ProxyStreamDiagnostics.log("fetch events conv=...\(conversationSuffix) since=\(since)")
        let requestText = buildGetEventsRequest(
            conversationId: conversationId,
            since: since,
            cwd: cwd,
            conversationGroup: conversationGroup
        )
        try await handle.sendInput(requestText)

        let bodyLineBuffer = StreamingLineBuffer()
        let chunkedDecoder = ChunkedBodyDecoder()
        var state = HTTPParseState.headers
        var statusCode: Int? = nil
        var errorBody = ""
        var lines: [String] = []
        var isChunked = false
        var contentLength: Int? = nil
        var bodyBytes = 0
        var shouldStop = false
        var responseInfo = ProxyResponseInfo(version: nil, startedAt: nil)
        var rawHeaderBuffer = ""
        func headerValue(from line: String) -> String? {
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let value = line[line.index(after: separator)...]
            return value.trimmingCharacters(in: .whitespaces)
        }
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
                if lowercased.hasPrefix("x-proxy-version:") {
                    responseInfo = ProxyResponseInfo(
                        version: headerValue(from: line),
                        startedAt: responseInfo.startedAt
                    )
                }
                if lowercased.hasPrefix("x-proxy-started-at:") {
                    responseInfo = ProxyResponseInfo(
                        version: responseInfo.version,
                        startedAt: headerValue(from: line)
                    )
                }
                if lowercased.hasPrefix("content-length:") {
                    if let length = Int(headerValue(from: line) ?? "") {
                        contentLength = length
                        if length == 0 {
                            shouldStop = true
                        }
                    }
                }
                if lowercased.hasPrefix("transfer-encoding:") && lowercased.contains("chunked") {
                    isChunked = true
                    ProxyStreamDiagnostics.log("fetch transfer-encoding=chunked")
                }
            }
        }
        func appendBodyLines(from chunk: String) {
            let bodyLines = bodyLineBuffer.addData(chunk)
            for rawLine in bodyLines {
                let sanitized = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                if !sanitized.isEmpty {
                    lines.append(sanitized)
                }
            }
            if let contentLength, !isChunked {
                bodyBytes += chunk.utf8.count
                if bodyBytes >= contentLength {
                    shouldStop = true
                }
            }
        }
        func handleBodyChunk(_ chunk: String) {
            if isChunked {
                let decodedChunks = chunkedDecoder.addData(chunk)
                for decoded in decodedChunks {
                    ProxyStreamDiagnostics.logRaw("fetch body chunk", decoded)
                    appendBodyLines(from: decoded)
                }
                if chunkedDecoder.isFinished {
                    shouldStop = true
                }
            } else {
                ProxyStreamDiagnostics.logRaw("fetch body chunk", chunk)
                appendBodyLines(from: chunk)
            }
        }
        func handleErrorChunk(_ chunk: String) {
            if isChunked {
                let decodedChunks = chunkedDecoder.addData(chunk)
                for decoded in decodedChunks {
                    errorBody += decoded
                }
            } else {
                errorBody += chunk
            }
        }

        for try await chunk in handle.outputStream() {
            if state == .headers {
                rawHeaderBuffer += chunk
                if let parts = splitHeader(from: rawHeaderBuffer) {
                    rawHeaderBuffer = ""
                    try applyHeaders(from: parts.header)
                    state = (statusCode == 200) ? .ndjson : .error
                    if !parts.body.isEmpty {
                        if state == .ndjson {
                            handleBodyChunk(parts.body)
                        } else {
                            handleErrorChunk(parts.body)
                        }
                    }
                    if shouldStop {
                        handle.terminate()
                        break
                    }
                }
                continue
            }

            if state == .error {
                handleErrorChunk(chunk)
                continue
            }

            if state == .ndjson {
                handleBodyChunk(chunk)
                if shouldStop {
                    handle.terminate()
                    break
                }
            }
        }

        if case .ndjson = state, let remaining = bodyLineBuffer.flush() {
            let sanitized = remaining.hasSuffix("\r") ? String(remaining.dropLast()) : remaining
            if !sanitized.isEmpty {
                lines.append(sanitized)
            }
        }

        if let statusCode = statusCode, statusCode != 200 {
            throw ProxyStreamError.httpError(status: statusCode, body: errorBody.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if case .headers = state {
            if rawHeaderBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ProxyStreamError.invalidResponse("No HTTP body received")
            }
            if statusCode == nil {
                let statusLine = rawHeaderBuffer.split(whereSeparator: \.isNewline).map(String.init).first
                statusCode = statusLine.flatMap { parseStatusCode(from: $0) }
            }
            if let statusCode = statusCode, statusCode != 200 {
                throw ProxyStreamError.httpError(status: statusCode, body: errorBody.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        var events: [ProxyStreamEvent] = []
        var nextId = since
        for line in lines {
            nextId += 1
            events.append(ProxyStreamEvent(eventId: nextId, jsonLine: line))
        }
        ProxyStreamDiagnostics.log("fetch events received=\(events.count)")
        return (events, responseInfo)
    }

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
        var statusCode: Int? = nil
        var responseBody = ""
        var isChunked = false
        var contentLength: Int? = nil
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
                    state = (statusCode == 200) ? .ndjson : .error
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

        if let statusCode = statusCode, statusCode != 200 {
            throw ProxyStreamError.httpError(status: statusCode, body: responseBody.trimmingCharacters(in: .whitespacesAndNewlines))
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

    func activateConversation(
        session: SSHSession,
        conversationId: String,
        cwd: String,
        conversationGroup: String?
    ) async throws -> ProxyResponseInfo {
        let handle = try await session.openDirectTCPIP(targetHost: host, targetPort: port)
        defer {
            handle.terminate()
        }

        var payload: [String: Any] = [
            "conversation_id": conversationId,
            "cwd": cwd
        ]
        if let conversationGroup = conversationGroup, !conversationGroup.isEmpty {
            payload["conversation_group"] = conversationGroup
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let body = String(data: data, encoding: .utf8) ?? "{}"
        let requestText = buildPostActivateRequest(body: body)
        try await handle.sendInput(requestText)

        let chunkedDecoder = ChunkedBodyDecoder()
        var state = HTTPParseState.headers
        var statusCode: Int? = nil
        var responseBody = ""
        var isChunked = false
        var contentLength: Int? = nil
        var bodyBytes = 0
        var shouldStop = false
        var responseInfo = ProxyResponseInfo(version: nil, startedAt: nil)
        var rawHeaderBuffer = ""

        func headerValue(from line: String) -> String? {
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let value = line[line.index(after: separator)...]
            return value.trimmingCharacters(in: .whitespaces)
        }
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
                if lowercased.hasPrefix("x-proxy-version:") {
                    responseInfo = ProxyResponseInfo(
                        version: headerValue(from: line),
                        startedAt: responseInfo.startedAt
                    )
                }
                if lowercased.hasPrefix("x-proxy-started-at:") {
                    responseInfo = ProxyResponseInfo(
                        version: responseInfo.version,
                        startedAt: headerValue(from: line)
                    )
                }
                if lowercased.hasPrefix("content-length:") {
                    if let length = Int(headerValue(from: line) ?? "") {
                        contentLength = length
                        if length == 0 {
                            shouldStop = true
                        }
                    }
                }
                if lowercased.hasPrefix("transfer-encoding:") && lowercased.contains("chunked") {
                    isChunked = true
                    ProxyStreamDiagnostics.log("activate transfer-encoding=chunked")
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
                    state = (statusCode == 200) ? .ndjson : .error
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

        if let statusCode = statusCode, statusCode != 200 {
            throw ProxyStreamError.httpError(status: statusCode, body: responseBody.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if case .headers = state {
            if rawHeaderBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ProxyStreamError.invalidResponse("No HTTP body received")
            }
        }

        let trimmedBody = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty,
           let data = trimmedBody.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            let canonicalId = (json["canonical_id"] as? String) ?? ""
            let previousId = (json["previous_id"] as? String) ?? ""
            let canonicalSuffix = canonicalId.isEmpty ? "nil" : String(canonicalId.suffix(6))
            let previousSuffix = previousId.isEmpty ? "nil" : String(previousId.suffix(6))
            ProxyStreamDiagnostics.log("activate conv=...\(conversationId.suffix(6)) canonical=...\(canonicalSuffix) previous=...\(previousSuffix)")
        } else {
            ProxyStreamDiagnostics.log("activate conv=...\(conversationId.suffix(6)) bodyBytes=\(responseBody.utf8.count)")
        }

        return responseInfo
    }

    func sendToolPermission(
        session: SSHSession,
        conversationId: String,
        cwd: String,
        permissionId: String,
        decision: ToolApprovalDecision,
        message: String?
    ) async throws -> ProxyResponseInfo {
        let handle = try await session.openDirectTCPIP(targetHost: host, targetPort: port)
        defer {
            handle.terminate()
        }

        var payload: [String: Any] = [
            "conversation_id": conversationId,
            "cwd": cwd,
            "permission_id": permissionId,
            "behavior": decision.rawValue
        ]
        if let message = message, !message.isEmpty {
            payload["message"] = message
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let body = String(data: data, encoding: .utf8) ?? "{}"
        let requestText = buildPostToolPermissionRequest(body: body)
        try await handle.sendInput(requestText)

        let chunkedDecoder = ChunkedBodyDecoder()
        var state = HTTPParseState.headers
        var statusCode: Int? = nil
        var responseBody = ""
        var isChunked = false
        var contentLength: Int? = nil
        var bodyBytes = 0
        var shouldStop = false
        var responseInfo = ProxyResponseInfo(version: nil, startedAt: nil)
        var rawHeaderBuffer = ""

        func headerValue(from line: String) -> String? {
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let value = line[line.index(after: separator)...]
            return value.trimmingCharacters(in: .whitespaces)
        }
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
                if lowercased.hasPrefix("x-proxy-version:") {
                    responseInfo = ProxyResponseInfo(
                        version: headerValue(from: line),
                        startedAt: responseInfo.startedAt
                    )
                }
                if lowercased.hasPrefix("x-proxy-started-at:") {
                    responseInfo = ProxyResponseInfo(
                        version: responseInfo.version,
                        startedAt: headerValue(from: line)
                    )
                }
                if lowercased.hasPrefix("content-length:") {
                    if let length = Int(headerValue(from: line) ?? "") {
                        contentLength = length
                        if length == 0 {
                            shouldStop = true
                        }
                    }
                }
                if lowercased.hasPrefix("transfer-encoding:") && lowercased.contains("chunked") {
                    isChunked = true
                    ProxyStreamDiagnostics.log("tool permission transfer-encoding=chunked")
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
                    state = (statusCode == 200) ? .ndjson : .error
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

        if let statusCode = statusCode, statusCode != 200 {
            throw ProxyStreamError.httpError(status: statusCode, body: responseBody.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if case .headers = state {
            if rawHeaderBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ProxyStreamError.invalidResponse("No HTTP body received")
            }
        }

        return responseInfo
    }

    private func buildPostRequest(body: String, lastEventId: Int?) -> String {
        var headers = [
            "POST /v1/agent/stream HTTP/1.1",
            "Host: \(host):\(port)",
            "Accept: text/event-stream",
            "Content-Type: application/json",
            "Connection: keep-alive",
            "Content-Length: \(body.utf8.count)"
        ]
        if let lastEventId = lastEventId {
            headers.append("Last-Event-ID: \(lastEventId)")
        }
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private func buildPostActivateRequest(body: String) -> String {
        let headers = [
            "POST /v1/conversations/activate HTTP/1.1",
            "Host: \(host):\(port)",
            "Accept: application/json",
            "Content-Type: application/json",
            "Connection: close",
            "Content-Length: \(body.utf8.count)"
        ]
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private func buildPostToolPermissionRequest(body: String) -> String {
        let headers = [
            "POST /v1/agent/tool_permission HTTP/1.1",
            "Host: \(host):\(port)",
            "Accept: application/json",
            "Content-Type: application/json",
            "Connection: close",
            "Content-Length: \(body.utf8.count)"
        ]
        return headers.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    private func buildGetEventsRequest(
        conversationId: String,
        since: Int,
        cwd: String?,
        conversationGroup: String?
    ) -> String {
        var path = "/v1/conversations/\(conversationId)/events?since=\(since)"
        if let cwd = cwd?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&cwd=\(cwd)"
        }
        if let conversationGroup = conversationGroup?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&conversation_group=\(conversationGroup)"
        }
        let headers = [
            "GET \(path) HTTP/1.1",
            "Host: \(host):\(port)",
            "Accept: application/x-ndjson",
            "Connection: close"
        ]
        return headers.joined(separator: "\r\n") + "\r\n\r\n"
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

    private func parseStatusCode(from line: String) -> Int? {
        guard line.starts(with: "HTTP/") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }
}

private enum HTTPParseState {
    case headers
    case sse
    case ndjson
    case error
}

private final class StreamingLineBuffer {
    private var buffer = ""

    func addData(_ data: String) -> [String] {
        buffer += data
        var lines: [String] = []

        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            lines.append(line)
        }

        return lines
    }

    func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let remaining = buffer
        buffer = ""
        return remaining
    }
}

private final class SSEParser {
    private var currentDataLines: [String] = []
    private var currentEventId: Int? = nil

    func consume(line: String) -> [ProxyStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return flush()
        }

        if trimmed.hasPrefix(":") {
            return []
        }

        if trimmed.hasPrefix("id:") {
            let idValue = trimmed.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
            currentEventId = Int(idValue)
            return []
        }

        if trimmed.hasPrefix("data:") {
            let dataValue = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            currentDataLines.append(dataValue)
        }

        return []
    }

    func flush() -> [ProxyStreamEvent] {
        guard !currentDataLines.isEmpty else { return [] }
        let jsonLine = currentDataLines.joined(separator: "\n")
        let event = ProxyStreamEvent(eventId: currentEventId, jsonLine: jsonLine)
        currentDataLines = []
        currentEventId = nil
        return [event]
    }
}

private final class ChunkedBodyDecoder {
    private var buffer = Data()
    private var expectedSize: Int? = nil
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
