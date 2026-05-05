//
//  CloudInitStatus.swift
//  CodeAgentsMobile
//
//  Purpose: Shared cloud-init status commands and parsing.
//

import Foundation

enum CloudInitStatus {
    static let statusCommand = "sudo -n cloud-init status --long 2>&1 || true"

    static let diagnosticsCommand = """
    sudo -n sh -c 'printf "__cloud_init_status__\\n"; cloud-init status --long 2>&1 || true; printf "\\n__cloud_init_output__\\n"; tail -n 160 /var/log/cloud-init-output.log 2>&1 || true'
    """

    static func parse(_ output: String) -> String {
        if output.contains("status: done") {
            return "done"
        }

        if output.contains("status: error") {
            return "error"
        }

        if output.contains("status: disabled") {
            return "done"
        }

        if output.contains("status: running") {
            return "running"
        }

        return "running"
    }

    static func redacted(_ output: String) -> String {
        output
            .replacingOccurrences(
                of: #"OPENCODE_SERVER_PASSWORD=[^[:space:]]+"#,
                with: "OPENCODE_SERVER_PASSWORD=[redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"OPENCODE_SERVER_PASSWORD=\"[^\"]*\""#,
                with: "OPENCODE_SERVER_PASSWORD=\"[redacted]\"",
                options: .regularExpression
            )
    }

    static func clippedDiagnostics(_ output: String, maxCharacters: Int = 4000) -> String {
        let redactedOutput = redacted(output)
        guard redactedOutput.count > maxCharacters else {
            return redactedOutput
        }
        return String(redactedOutput.suffix(maxCharacters))
    }
}
