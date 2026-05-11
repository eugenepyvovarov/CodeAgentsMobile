import Foundation

/// Developer-only timing helper for chat reopen/recovery instrumentation.
///
/// The API intentionally accepts only a small set of scalar metadata value types so callers cannot
/// accidentally log prompts, message bodies, raw payloads, credentials, paths, or URLs.
enum ChatRecoveryTiming {
    static let prefix = "[ChatRecoveryTiming]"

    enum MetadataValue: Equatable {
        case count(Int)
        case flag(Bool)
        case status(Status)
    }

    enum Status: String {
        case active
        case cancelled
        case complete
        case failed
        case inactive
        case skipped
        case started
        case success
        case unavailable
        case unknown
    }

    @discardableResult
    static func measure<T>(
        runtime: String,
        projectID: String?,
        operation: String,
        metadata: [String: MetadataValue] = [:],
        _ body: () throws -> T
    ) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds

        do {
            let result = try body()
            log(
                runtime: runtime,
                projectID: projectID,
                operation: operation,
                elapsedNanoseconds: elapsedNanoseconds(since: start),
                metadata: metadata
            )
            return result
        } catch {
            var failureMetadata = metadata
            failureMetadata["status"] = .status(.failed)
            log(
                runtime: runtime,
                projectID: projectID,
                operation: operation,
                elapsedNanoseconds: elapsedNanoseconds(since: start),
                metadata: failureMetadata
            )
            throw error
        }
    }

    @discardableResult
    static func measure<T>(
        runtime: String,
        projectID: String?,
        operation: String,
        metadata: [String: MetadataValue] = [:],
        _ body: () async throws -> T
    ) async rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds

        do {
            let result = try await body()
            log(
                runtime: runtime,
                projectID: projectID,
                operation: operation,
                elapsedNanoseconds: elapsedNanoseconds(since: start),
                metadata: metadata
            )
            return result
        } catch {
            var failureMetadata = metadata
            failureMetadata["status"] = .status(.failed)
            log(
                runtime: runtime,
                projectID: projectID,
                operation: operation,
                elapsedNanoseconds: elapsedNanoseconds(since: start),
                metadata: failureMetadata
            )
            throw error
        }
    }

    static func log(
        runtime: String,
        projectID: String?,
        operation: String,
        elapsedNanoseconds: UInt64,
        metadata: [String: MetadataValue] = [:]
    ) {
        let line = formattedLine(
            runtime: runtime,
            projectID: projectID,
            operation: operation,
            elapsedNanoseconds: elapsedNanoseconds,
            metadata: metadata
        )

        #if DEBUG
        print(line)
        #endif
    }

    static func formattedLine(
        runtime: String,
        projectID: String?,
        operation: String,
        elapsedNanoseconds: UInt64,
        metadata: [String: MetadataValue] = [:]
    ) -> String {
        var fields = [
            "runtime=\(safeToken(runtime))",
            "project=\(safeOptionalToken(projectID))",
            "operation=\(safeToken(operation))",
            "elapsedMs=\(elapsedMilliseconds(fromNanoseconds: elapsedNanoseconds))"
        ]

        fields.append(contentsOf: formattedMetadata(metadata))
        return "\(prefix) \(fields.joined(separator: " "))"
    }
}

private extension ChatRecoveryTiming {
    static func elapsedNanoseconds(since start: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds - start
    }

    static func elapsedMilliseconds(fromNanoseconds nanoseconds: UInt64) -> UInt64 {
        nanoseconds / 1_000_000
    }

    static func formattedMetadata(_ metadata: [String: MetadataValue]) -> [String] {
        metadata.keys.sorted().compactMap { key in
            guard let value = metadata[key] else { return nil }
            return "\(safeMetadataKey(key))=\(formattedValue(value))"
        }
    }

    static func formattedValue(_ value: MetadataValue) -> String {
        switch value {
        case .count(let count):
            return String(max(0, count))
        case .flag(let flag):
            return flag ? "true" : "false"
        case .status(let status):
            return status.rawValue
        }
    }

    static func safeOptionalToken(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        return safeToken(value)
    }

    static func safeMetadataKey(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? "metadata" : sanitized
    }

    static func safeToken(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "redacted"
        }
        return value
    }
}
