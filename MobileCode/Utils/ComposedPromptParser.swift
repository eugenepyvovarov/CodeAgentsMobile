//
//  ComposedPromptParser.swift
//  CodeAgentsMobile
//
//  Purpose: Parse prompts that include optional skill hint and @file references.
//

import Foundation

struct ComposedPromptComponents: Equatable {
    let message: String
    let skillName: String?
    let skillSlug: String?
    let fileReferences: [String]
}

enum ComposedPromptParser {
    static func parse(_ prompt: String) -> ComposedPromptComponents {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ComposedPromptComponents(message: "", skillName: nil, skillSlug: nil, fileReferences: [])
        }

        if let slashParsed = parseSlashCommandPrompt(trimmed) {
            return slashParsed
        }

        let sections = trimmed.components(separatedBy: "\n\n")
        var index = 0

        var skillName: String?
        var skillSlug: String?
        var fileReferences: [String] = []

        if index < sections.count, let skill = parseSkillHeader(sections[index]) {
            skillName = skill.name
            skillSlug = skill.slug
            index += 1
        }

        if index < sections.count, let refs = parseFileReferencesSection(sections[index]) {
            fileReferences = refs
            index += 1
        }

        let remainingSections = sections[index...]
        let message = remainingSections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return ComposedPromptComponents(
            message: message,
            skillName: skillName,
            skillSlug: skillSlug,
            fileReferences: fileReferences
        )
    }

    // MARK: - Private

    private static func parseSlashCommandPrompt(_ prompt: String) -> ComposedPromptComponents? {
        guard prompt.hasPrefix("/") else { return nil }

        let lines = prompt.components(separatedBy: .newlines)
        guard let firstLine = lines.first else { return nil }

        let firstTrimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstTrimmed.hasPrefix("/") else { return nil }

        let withoutSlash = String(firstTrimmed.dropFirst())
        let firstSpaceIndex = withoutSlash.firstIndex(where: { $0.isWhitespace }) ?? withoutSlash.endIndex
        guard firstSpaceIndex > withoutSlash.startIndex else { return nil }

        let slug = String(withoutSlash[..<firstSpaceIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return nil }

        let remainder = String(withoutSlash[firstSpaceIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

        var messageLines: [String] = []
        if !remainder.isEmpty {
            messageLines.append(remainder)
        }
        if lines.count > 1 {
            messageLines.append(contentsOf: lines.dropFirst())
        }

        var fileReferences: [String] = []
        var filteredLines: [String] = []
        for line in messageLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reference = parseFileReferenceLine(trimmedLine) {
                fileReferences.append(reference)
                continue
            }
            filteredLines.append(line)
        }

        let message = filteredLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ComposedPromptComponents(
            message: message,
            skillName: nil,
            skillSlug: slug,
            fileReferences: uniqueReferences(fileReferences)
        )
    }

    private static func parseFileReferencesSection(_ section: String) -> [String]? {
        let lines = section
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        guard lines.allSatisfy({ $0.hasPrefix("@") }) else { return nil }

        let references = lines.map { String($0.dropFirst()) }.filter { !$0.isEmpty }
        return references.isEmpty ? nil : references
    }

    private static func parseFileReferenceLine(_ line: String) -> String? {
        guard line.hasPrefix("@") else { return nil }
        let trimmed = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return trimmed
    }

    private static func parseSkillHeader(_ section: String) -> (name: String?, slug: String?)? {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)

        // Matches:
        // - Use the “Name” skill.
        // - Use the “Name” skill (slug: slug).
        if trimmed.hasPrefix("Use the “"),
           let nameEndRange = trimmed.range(of: "” skill") {
            let nameStartIndex = trimmed.index(trimmed.startIndex, offsetBy: "Use the “".count)
            let name = String(trimmed[nameStartIndex..<nameEndRange.lowerBound]).nilIfEmpty

            let remainder = String(trimmed[nameEndRange.upperBound...])
            if remainder == "." {
                return (name: name, slug: nil)
            }
            if remainder.hasPrefix(" (slug: "), remainder.hasSuffix(").") {
                let slugStartIndex = remainder.index(remainder.startIndex, offsetBy: " (slug: ".count)
                let slugEndIndex = remainder.index(remainder.endIndex, offsetBy: -").".count)
                let slug = String(remainder[slugStartIndex..<slugEndIndex]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                return (name: name, slug: slug)
            }
            return (name: name, slug: nil)
        }

        // Matches:
        // - Use the skill with slug “slug”.
        if trimmed.hasPrefix("Use the skill with slug “"),
           trimmed.hasSuffix("”.") {
            let prefixCount = "Use the skill with slug “".count
            let slugStartIndex = trimmed.index(trimmed.startIndex, offsetBy: prefixCount)
            let slugEndIndex = trimmed.index(trimmed.endIndex, offsetBy: -"”.".count)
            let slug = String(trimmed[slugStartIndex..<slugEndIndex]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let slug {
                return (name: nil, slug: slug)
            }
            return nil
        }

        return nil
    }

    private static func uniqueReferences(_ references: [String]) -> [String] {
        var unique: [String] = []
        var seen: Set<String> = []
        for reference in references where seen.insert(reference).inserted {
            unique.append(reference)
        }
        return unique
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
