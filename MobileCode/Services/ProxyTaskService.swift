//
//  ProxyTaskService.swift
//  CodeAgentsMobile
//
//  Purpose: Sync scheduled tasks with the Claude proxy scheduler
//

import Foundation

struct ProxyTaskSchedule {
    let frequency: TaskFrequency
    let interval: Int
    let weekdayMask: Int
    let monthlyMode: TaskMonthlyMode
    let dayOfMonth: Int
    let ordinalWeek: WeekdayOrdinal
    let ordinalWeekday: Weekday
    let monthOfYear: Int
    let timeOfDayMinutes: Int
}

struct ProxyTaskRecord {
    let id: String
    let title: String?
    let prompt: String?
    let isEnabled: Bool?
    let timeZoneId: String?
    let schedule: ProxyTaskSchedule?
    let nextRunAt: Date?
    let lastRunAt: Date?
}

enum ProxyTaskError: LocalizedError {
    case invalidResponse(String)
    case httpError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return "Proxy response invalid: \(message)"
        case .httpError(let status, let body):
            if status == 404 {
                return "Proxy scheduler not available (404). Update the proxy to enable tasks."
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Proxy HTTP \(status)"
            }
            return "Proxy HTTP \(status): \(trimmed)"
        }
    }
}

@MainActor
final class ProxyTaskService {
    static let shared = ProxyTaskService()

    private let client = ProxyTaskClient()
    private let streamClient = ProxyStreamClient()
    private let sshService = SSHService.shared
    private let iso8601Formatter: ISO8601DateFormatter
    private let iso8601Fallback: ISO8601DateFormatter

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso8601Formatter = formatter

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        iso8601Fallback = fallback
    }

    func fetchTasks(for project: RemoteProject) async throws -> [ProxyTaskRecord] {
        let session = try await sshService.getConnection(for: project, purpose: .claude)
        _ = try await resolveCanonicalConversationId(for: project, session: session)
        let agentId = project.proxyAgentId ?? project.id.uuidString
        let query = buildQuery([
            "agent_id": agentId
        ])
        let path = "/v1/agent/tasks\(query)"
        let response = try await client.request(session: session, method: "GET", path: path, body: nil)
        return try parseTaskList(from: response.body)
    }

    func upsertTask(_ task: AgentScheduledTask, project: RemoteProject) async throws -> ProxyTaskRecord {
        if let remoteId = task.remoteId, !remoteId.isEmpty {
            return try await updateTask(task, remoteId: remoteId, project: project)
        }
        return try await createTask(task, project: project)
    }

    func deleteTask(_ task: AgentScheduledTask, project: RemoteProject) async throws {
        guard let remoteId = task.remoteId, !remoteId.isEmpty else { return }
        let session = try await sshService.getConnection(for: project, purpose: .claude)
        let path = "/v1/agent/tasks/\(remoteId)"
        _ = try await client.request(session: session, method: "DELETE", path: path, body: nil)
    }

    private func createTask(_ task: AgentScheduledTask, project: RemoteProject) async throws -> ProxyTaskRecord {
        let session = try await sshService.getConnection(for: project, purpose: .claude)
        let conversationId = try await resolveCanonicalConversationId(for: project, session: session)
        let body = try buildPayload(for: task, project: project, conversationId: conversationId)
        let response = try await client.request(session: session,
                                                method: "POST",
                                                path: "/v1/agent/tasks",
                                                body: body)
        return try parseTask(from: response.body)
    }

    private func updateTask(_ task: AgentScheduledTask,
                            remoteId: String,
                            project: RemoteProject) async throws -> ProxyTaskRecord {
        let session = try await sshService.getConnection(for: project, purpose: .claude)
        let conversationId = try await resolveCanonicalConversationId(for: project, session: session)
        let body = try buildPayload(for: task, project: project, conversationId: conversationId)
        let path = "/v1/agent/tasks/\(remoteId)"
        let response = try await client.request(session: session,
                                                method: "PATCH",
                                                path: path,
                                                body: body)
        return try parseTask(from: response.body)
    }

    private func buildPayload(
        for task: AgentScheduledTask,
        project: RemoteProject,
        conversationId: String
    ) throws -> String {
        let agentId = project.proxyAgentId ?? project.id.uuidString
        var payload: [String: Any] = [
            "agent_id": agentId,
            "conversation_id": conversationId,
            "cwd": project.path,
            "prompt": task.prompt,
            "enabled": task.isEnabled,
            "time_zone": task.timeZoneId,
            "schedule": schedulePayload(for: task)
        ]

        let trimmedTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            payload["title"] = trimmedTitle
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func schedulePayload(for task: AgentScheduledTask) -> [String: Any] {
        [
            "frequency": task.frequency.rawValue,
            "interval": task.interval,
            "weekday_mask": task.weekdayMask,
            "monthly_mode": remoteMonthlyMode(task.monthlyMode),
            "day_of_month": task.dayOfMonth,
            "weekday_ordinal": task.ordinalWeek.rawValue,
            "weekday": task.ordinalWeekday.rawValue,
            "month": task.monthOfYear,
            "time_minutes": task.timeOfDayMinutes
        ]
    }

    private func remoteMonthlyMode(_ mode: TaskMonthlyMode) -> String {
        switch mode {
        case .dayOfMonth:
            return "day_of_month"
        case .ordinalWeekday:
            return "ordinal_weekday"
        }
    }

    private func resolveCanonicalConversationId(
        for project: RemoteProject,
        session: SSHSession
    ) async throws -> String {
        let canonicalId = try await streamClient.fetchCanonicalConversationId(
            session: session,
            cwd: project.path
        )

        var didUpdate = false
        if project.proxyConversationId != canonicalId {
            project.proxyConversationId = canonicalId
            project.proxyLastEventId = nil
            didUpdate = true
        }
        if didUpdate {
            project.updateLastModified()
        }
        return canonicalId
    }

    private func buildQuery(_ items: [String: String]) -> String {
        let pairs = items.compactMap { key, value -> String? in
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                return nil
            }
            return "\(key)=\(encoded)"
        }

        guard !pairs.isEmpty else { return "" }
        return "?" + pairs.joined(separator: "&")
    }

    private func parseTaskList(from body: String) throws -> [ProxyTaskRecord] {
        let json = try decodeJSON(body)

        if let array = json as? [[String: Any]] {
            return array.compactMap { parseTaskRecord(from: $0) }
        }

        if let dict = json as? [String: Any] {
            if let tasks = dict["tasks"] as? [[String: Any]] {
                return tasks.compactMap { parseTaskRecord(from: $0) }
            }
            if let task = dict["task"] as? [String: Any], let record = parseTaskRecord(from: task) {
                return [record]
            }
        }

        throw ProxyTaskError.invalidResponse("Unexpected task list response")
    }

    private func parseTask(from body: String) throws -> ProxyTaskRecord {
        let json = try decodeJSON(body)

        if let dict = json as? [String: Any] {
            if let task = dict["task"] as? [String: Any], let record = parseTaskRecord(from: task) {
                return record
            }
            if let record = parseTaskRecord(from: dict) {
                return record
            }
        }

        throw ProxyTaskError.invalidResponse("Unexpected task response")
    }

    private func decodeJSON(_ body: String) throws -> Any {
        guard let data = body.data(using: .utf8) else {
            throw ProxyTaskError.invalidResponse("Missing response body")
        }
        return try JSONSerialization.jsonObject(with: data, options: [])
    }

    private func parseTaskRecord(from dict: [String: Any]) -> ProxyTaskRecord? {
        guard let id = stringValue(dict["id"]) ?? stringValue(dict["task_id"]) else {
            return nil
        }

        let scheduleDict = dict["schedule"] as? [String: Any]
        let schedule = scheduleDict.flatMap { parseSchedule(from: $0) }

        let nextRun = parseDate(dict["next_run_at"] ?? dict["nextRunAt"])
        let lastRun = parseDate(dict["last_run_at"] ?? dict["lastRunAt"])

        return ProxyTaskRecord(
            id: id,
            title: stringValue(dict["title"] ?? dict["name"]),
            prompt: stringValue(dict["prompt"] ?? dict["message"]),
            isEnabled: boolValue(dict["enabled"] ?? dict["is_enabled"]),
            timeZoneId: stringValue(dict["time_zone"] ?? dict["timezone"] ?? dict["timeZone"]),
            schedule: schedule,
            nextRunAt: nextRun,
            lastRunAt: lastRun
        )
    }

    private func parseSchedule(from dict: [String: Any]) -> ProxyTaskSchedule? {
        guard let frequency = parseFrequency(dict["frequency"] ?? dict["repeat"]) else {
            return nil
        }

        let interval = max(1, intValue(dict["interval"] ?? dict["every"]) ?? 1)
        let timeMinutes = intValue(dict["time_minutes"] ?? dict["time_of_day_minutes"])
            ?? parseTimeString(dict["time"] ?? dict["time_of_day"])
            ?? AgentScheduledTask.defaultTimeOfDayMinutes()

        let weekdayMask = parseWeekdayMask(dict)
        let monthlyMode = parseMonthlyMode(dict["monthly_mode"] ?? dict["repeat_by"]) ?? .dayOfMonth
        let dayOfMonth = min(max(1, intValue(dict["day_of_month"] ?? dict["day"]) ?? 1), 31)
        let ordinalWeek = parseWeekdayOrdinal(dict["weekday_ordinal"] ?? dict["ordinal"]) ?? .first
        let ordinalWeekday = parseWeekday(dict["weekday"] ?? dict["weekday_value"])
            ?? Weekday.current(in: Calendar.current)
        let monthOfYear = min(max(1, intValue(dict["month"] ?? dict["month_of_year"]) ?? 1), 12)

        return ProxyTaskSchedule(
            frequency: frequency,
            interval: interval,
            weekdayMask: weekdayMask,
            monthlyMode: monthlyMode,
            dayOfMonth: dayOfMonth,
            ordinalWeek: ordinalWeek,
            ordinalWeekday: ordinalWeekday,
            monthOfYear: monthOfYear,
            timeOfDayMinutes: max(0, min(timeMinutes, 1_439))
        )
    }

    private func parseFrequency(_ value: Any?) -> TaskFrequency? {
        guard let string = stringValue(value)?.lowercased() else { return nil }
        return TaskFrequency(rawValue: string)
    }

    private func parseMonthlyMode(_ value: Any?) -> TaskMonthlyMode? {
        guard let string = stringValue(value)?.lowercased() else { return nil }
        switch string {
        case "day_of_month", "dayofmonth", "day":
            return .dayOfMonth
        case "ordinal_weekday", "ordinalweekday", "weekday":
            return .ordinalWeekday
        default:
            return nil
        }
    }

    private func parseWeekdayOrdinal(_ value: Any?) -> WeekdayOrdinal? {
        guard let string = stringValue(value)?.lowercased() else { return nil }
        switch string {
        case "first":
            return .first
        case "second":
            return .second
        case "third":
            return .third
        case "fourth":
            return .fourth
        case "last":
            return .last
        default:
            return nil
        }
    }

    private func parseWeekday(_ value: Any?) -> Weekday? {
        if let number = intValue(value), let weekday = Weekday(rawValue: number) {
            return weekday
        }

        guard let string = stringValue(value)?.lowercased() else { return nil }
        switch string {
        case "sunday", "sun":
            return .sunday
        case "monday", "mon":
            return .monday
        case "tuesday", "tue", "tues":
            return .tuesday
        case "wednesday", "wed":
            return .wednesday
        case "thursday", "thu", "thur", "thurs":
            return .thursday
        case "friday", "fri":
            return .friday
        case "saturday", "sat":
            return .saturday
        default:
            return nil
        }
    }

    private func parseWeekdayMask(_ dict: [String: Any]) -> Int {
        if let mask = intValue(dict["weekday_mask"] ?? dict["weekdayMask"]) {
            return mask
        }
        if let days = dict["weekdays"] as? [Any] {
            var mask = 0
            for item in days {
                if let weekday = parseWeekday(item) {
                    mask |= WeekdayMask.mask(for: weekday)
                } else if let value = intValue(item), let weekday = Weekday(rawValue: value) {
                    mask |= WeekdayMask.mask(for: weekday)
                }
            }
            if mask != 0 {
                return mask
            }
        }
        if let weekday = parseWeekday(dict["weekday"]) {
            return WeekdayMask.mask(for: weekday)
        }
        return WeekdayMask.mask(for: Weekday.current(in: Calendar.current))
    }

    private func parseTimeString(_ value: Any?) -> Int? {
        guard let string = stringValue(value) else { return nil }
        let parts = string.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }
        return max(0, min(hour * 60 + minute, 1_439))
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }

        if let time = value as? TimeInterval {
            return Date(timeIntervalSince1970: time)
        }

        guard let string = stringValue(value) else { return nil }
        if let date = iso8601Formatter.date(from: string) {
            return date
        }
        return iso8601Fallback.date(from: string)
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return (string as NSString).boolValue
        }
        return nil
    }
}

private struct ProxyHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: String
}

private final class ProxyTaskClient {
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
