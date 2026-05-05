//
//  OpenCodeQuestionRequest.swift
//  CodeAgentsMobile
//
//  Purpose: Represents pending OpenCode question-tool requests awaiting user input.
//

import Foundation

struct OpenCodeQuestionRequest: Decodable, Equatable, Identifiable {
    let id: String
    let sessionID: String?
    let questions: [OpenCodeQuestion]
    let tool: OpenCodeQuestionTool?

    enum CodingKeys: String, CodingKey {
        case id
        case requestID
        case sessionID
        case questions
        case tool
    }

    init(id: String, sessionID: String?, questions: [OpenCodeQuestion], tool: OpenCodeQuestionTool? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.questions = questions
        self.tool = tool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .requestID)
            ?? ""
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        questions = try container.decodeIfPresent([OpenCodeQuestion].self, forKey: .questions) ?? []
        tool = try container.decodeIfPresent(OpenCodeQuestionTool.self, forKey: .tool)
    }
}

struct PendingOpenCodeQuestionRequest: Equatable, Identifiable {
    let request: OpenCodeQuestionRequest
    let agentId: UUID

    var id: String { request.id }
}

struct OpenCodeQuestion: Decodable, Equatable, Identifiable {
    let header: String
    let question: String
    let options: [OpenCodeQuestionOption]
    let multiple: Bool
    let custom: Bool

    var id: String { "\(header)\u{0}\(question)" }

    enum CodingKeys: String, CodingKey {
        case header
        case question
        case options
        case multiple
        case custom
    }

    init(
        header: String,
        question: String,
        options: [OpenCodeQuestionOption],
        multiple: Bool = false,
        custom: Bool = true
    ) {
        self.header = header
        self.question = question
        self.options = options
        self.multiple = multiple
        self.custom = custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decodeIfPresent(String.self, forKey: .header) ?? "Question"
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        options = try container.decodeIfPresent([OpenCodeQuestionOption].self, forKey: .options) ?? []
        multiple = try container.decodeIfPresent(Bool.self, forKey: .multiple) ?? false
        custom = try container.decodeIfPresent(Bool.self, forKey: .custom) ?? true
    }
}

struct OpenCodeQuestionOption: Decodable, Equatable, Identifiable {
    let label: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case label
        case description
    }

    var id: String { label }

    init(label: String, description: String = "") {
        self.label = label
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

struct OpenCodeQuestionTool: Decodable, Equatable {
    let messageID: String?
    let callID: String?
}
