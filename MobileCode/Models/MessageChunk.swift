//
//  MessageChunk.swift
//  CodeAgentsMobile
//
//  Purpose: Streaming message chunk for OpenCode chat (send/hydrate/tool approval).
//

import Foundation

/// Message chunk for streaming responses
struct MessageChunk {
    let content: String
    let isComplete: Bool
    let isError: Bool
    let metadata: [String: Any]?
}
