//
//  ProxyStreamDiagnostics.swift
//  CodeAgentsMobile
//
//  Purpose: Lightweight, opt-in diagnostics for proxy SSE streams
//

import Foundation

enum ProxyStreamDiagnostics {
    static let enabledKey = "ProxyStreamDebug"

    static var isEnabled: Bool {
#if DEBUG
        if UserDefaults.standard.object(forKey: enabledKey) == nil {
            return true
        }
#endif
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        print("[ProxyDebug] \(message)")
    }

    static func summarize(line: String) -> String {
        let lineId = UInt(bitPattern: line.hashValue)
        return "lineBytes=\(line.utf8.count) lineId=\(lineId)"
    }

    static func summarize(data: Data) -> String {
        let dataId = UInt(bitPattern: data.hashValue)
        return "dataBytes=\(data.count) dataId=\(dataId)"
    }

    static func logRaw(_ label: String, _ payload: String) {
        guard isEnabled else { return }
        print("[ProxyDebugRaw] \(label) bytes=\(payload.utf8.count)")
        print("[ProxyDebugRaw] \(label) BEGIN")
        print(payload)
        print("[ProxyDebugRaw] \(label) END")
    }
}

