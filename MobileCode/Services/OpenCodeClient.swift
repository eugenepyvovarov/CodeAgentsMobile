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
}

enum OpenCodeHTTPMethod: String {
    case get = "GET"
    case post = "POST"
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
            throw OpenCodeClientError.decodingFailed(error.localizedDescription)
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

        var responseText = ""
        for try await chunk in handle.outputStream() {
            responseText += chunk
        }

        let response = try OpenCodeHTTPResponseParser.parse(responseText)
        guard (200...299).contains(response.statusCode) else {
            throw OpenCodeClientError.httpError(status: response.statusCode, body: response.body)
        }
        return response
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
            "Accept: application/json",
            "Connection: close"
        ]

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
}

private enum OpenCodeHTTPResponseParser {
    static func parse(_ responseText: String) throws -> OpenCodeHTTPResponse {
        guard let headerRange = responseText.range(of: "\r\n\r\n") ?? responseText.range(of: "\n\n") else {
            throw OpenCodeClientError.invalidResponse("Missing header/body separator")
        }

        let rawHeaders = String(responseText[..<headerRange.lowerBound])
        let rawBody = String(responseText[headerRange.upperBound...])
        let headerLines = rawHeaders
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
