//
//  E2EProvisioningDebugLog.swift
//  CodeAgentsMobile
//
//  Purpose: UI-test-only provisioning diagnostics written to the simulator container.
//

import Foundation

enum E2EProvisioningDebugLog {
    private static let fileName = "mobilecode-e2e-provisioning.log"

    static var isEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--ui-testing")
            && processInfo.environment["MOBILECODE_E2E_PROVISIONING_DEBUG_LOG"] == "1"
    }

    static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName)
    }

    static func reset() {
        guard isEnabled, let logURL else { return }
        try? FileManager.default.removeItem(at: logURL)
        append("reset provisioning debug log")
    }

    static func append(_ message: @autoclosure () -> String) {
        guard isEnabled, let logURL else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(redact(message()))\n"

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: logURL, options: .atomic)
            }
        } catch {
            print("Failed to write E2E provisioning log: \(error)")
        }
    }

    private static func redact(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: ##"OPENCODE_SERVER_PASSWORD="?[^"\s]+"?"##,
                with: "OPENCODE_SERVER_PASSWORD=<redacted>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"Authorization:\s*Bearer\s+[A-Za-z0-9._\-]+"#,
                with: "Authorization: Bearer <redacted>",
                options: .regularExpression
            )
    }
}
