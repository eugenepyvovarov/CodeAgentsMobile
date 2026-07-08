//
//  CodingAgentRuntimeRegistry.swift
//  CodeAgentsMobile
//
//  Purpose: Resolve a coding-agent runtime for a project. Production is OpenCode-only.
//

import Foundation

@MainActor
final class CodingAgentRuntimeRegistry {
    private let openCodeRuntime: CodingAgentRuntimeService

    init(openCodeRuntime: CodingAgentRuntimeService? = nil) {
        self.openCodeRuntime = openCodeRuntime ?? OpenCodeRuntimeService()
    }

    /// Returns the runtime implementation for `kind`.
    ///
    /// Legacy `.claudeProxy` markers still decode for migration detection, but always
    /// resolve to OpenCode — Claude proxy chat is no longer a production path.
    func runtime(for kind: CodingAgentRuntimeKind) -> CodingAgentRuntimeService {
        switch kind {
        case .claudeProxy, .openCode:
            return openCodeRuntime
        }
    }
}
