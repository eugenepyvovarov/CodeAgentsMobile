//
//  LineBuffer.swift
//  CodeAgentsMobile
//
//  Purpose: Buffer partial stdout/SSE data into complete lines.
//

import Foundation

/// Buffers partial lines and yields complete lines.
class LineBuffer {
    private var buffer = ""
    
    func addData(_ data: String) -> [String] {
        buffer += data
        var lines: [String] = []
        
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if !line.isEmpty {
                lines.append(line)
            }
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
