//
//  Message.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import Foundation

struct Message: Identifiable {
    let id = UUID()
    var content: String
    let role: Role
    let timestamp: Date = Date()
    var codeBlock: CodeBlock?
    var actions: [Action] = []
    
    enum Role {
        case user
        case assistant
    }
    
    struct CodeBlock {
        let language: String
        let content: String
    }
    
    struct Action {
        let title: String
        let icon: String
        let action: () -> Void
    }
}