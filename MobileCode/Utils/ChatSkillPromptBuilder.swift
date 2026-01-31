//
//  ChatSkillPromptBuilder.swift
//  CodeAgentsMobile
//
//  Purpose: Compose prompts that optionally invoke a Claude Code skill via /<skill> and include @file references.
//

import Foundation

struct ChatSkillPromptBuilder {
    static func build(
        message: String,
        skillName: String? = nil,
        skillSlug: String? = nil,
        fileReferences: [String] = []
    ) -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedSkillSlug = skillSlug?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            .map { raw in
                raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
            }

        let normalizedSkillName = skillName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let resolvedSkillCommand: String? = {
            if let normalizedSkillSlug {
                return normalizedSkillSlug
            }
            if let normalizedSkillName {
                return slugFromSkillName(normalizedSkillName)
            }
            return nil
        }()

        let normalizedReferences: [String] = fileReferences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("@") ? $0 : "@\($0)" }

        if let resolvedSkillCommand {
            var sections: [String] = []
            var firstLine = "/\(resolvedSkillCommand)"
            if !trimmedMessage.isEmpty {
                firstLine += " \(trimmedMessage)"
            }
            sections.append(firstLine)
            if !normalizedReferences.isEmpty {
                sections.append(normalizedReferences.joined(separator: "\n"))
            }
            return sections.joined(separator: "\n\n")
        }

        var sections: [String] = []
        if !normalizedReferences.isEmpty {
            sections.append(normalizedReferences.joined(separator: "\n"))
        }
        if !trimmedMessage.isEmpty {
            sections.append(trimmedMessage)
        }
        return sections.joined(separator: "\n\n")
    }

    private static func slugFromSkillName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }

        var result = ""
        var didWriteDash = false

        for scalar in trimmed.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.append(Character(scalar))
                didWriteDash = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" || scalar == "_" {
                if !result.isEmpty, !didWriteDash {
                    result.append("-")
                    didWriteDash = true
                }
            }
        }

        let collapsed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? trimmed : collapsed
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
