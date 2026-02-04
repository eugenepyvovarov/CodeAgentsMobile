//
//  CodeAgentsUIBlockExtractor.swift
//  CodeAgentsMobile
//
//  Purpose: Extract `codeagents-ui` fenced blocks from assistant text and
//  return ordered markdown + UI segments for rendering.
//

import Foundation

enum CodeAgentsUIRenderSegment: Identifiable {
    case markdown(String)
    case ui(CodeAgentsUIBlock)

    var id: UUID {
        UUID()
    }
}

enum CodeAgentsUIBlockExtractor {
    static func segments(
        from text: String,
        caps: CodeAgentsUICaps = .default
    ) -> [CodeAgentsUIRenderSegment] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var segments: [CodeAgentsUIRenderSegment] = []
        var markdownBuffer: [String] = []
        var uiBuffer: [String] = []
        enum UIFenceMode {
            case strict
            case lenient
        }

        var inUIBlock = false
        var uiBlockCount = 0
        var fenceMode: UIFenceMode?
        var fenceStartLine: String?

        func flushMarkdownBuffer() {
            guard !markdownBuffer.isEmpty else { return }
            let chunk = markdownBuffer.joined(separator: "\n")
            if !chunk.isEmpty {
                segments.append(.markdown(chunk))
            }
            markdownBuffer.removeAll(keepingCapacity: true)
        }

        func fenceModeForLine(_ line: String) -> UIFenceMode? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("```") else { return nil }
            let label = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if label == "codeagents-ui" || label == "codeagents_ui" {
                return .strict
            }
            if label.hasPrefix("codeagents-ui ") || label.hasPrefix("codeagents_ui ") {
                return .strict
            }
            if label.isEmpty || label == "json" || label.hasPrefix("json ") {
                return .lenient
            }
            return nil
        }

        func appendRawUIBlockToMarkdown(includeClosingFence: Bool) {
            guard let fenceStartLine else { return }
            var rawLines: [String] = []
            rawLines.append(fenceStartLine)
            rawLines.append(contentsOf: uiBuffer)
            if includeClosingFence {
                rawLines.append("```")
            }
            markdownBuffer.append(rawLines.joined(separator: "\n"))
            uiBuffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inUIBlock {
                if trimmed == "```" {
                    let json = uiBuffer.joined(separator: "\n")
                    let shouldRender = uiBlockCount < caps.maxBlocksPerMessage
                    if shouldRender, let block = CodeAgentsUIParser.parseBlock(from: json, caps: caps) {
                        flushMarkdownBuffer()
                        segments.append(.ui(block))
                        uiBlockCount += 1
                    } else if fenceMode == .lenient {
                        appendRawUIBlockToMarkdown(includeClosingFence: true)
                    }
                    uiBuffer.removeAll(keepingCapacity: true)
                    inUIBlock = false
                    fenceMode = nil
                    fenceStartLine = nil
                } else {
                    uiBuffer.append(line)
                }
                continue
            }

            if let mode = fenceModeForLine(line) {
                flushMarkdownBuffer()
                inUIBlock = true
                fenceMode = mode
                fenceStartLine = line
                uiBuffer.removeAll(keepingCapacity: true)
                continue
            }

            markdownBuffer.append(line)
        }

        if inUIBlock {
            uiBuffer.removeAll(keepingCapacity: true)
            inUIBlock = false
            fenceMode = nil
            fenceStartLine = nil
        }

        flushMarkdownBuffer()
        return segments
    }
}
