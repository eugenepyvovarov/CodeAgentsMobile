//
//  SkillLibraryService.swift
//  CodeAgentsMobile
//
//  Purpose: Handles local storage and parsing for agent skills
//

import Foundation

struct SkillFrontMatterSummary: Equatable {
    let name: String?
    let description: String?
}

struct SkillInstallResult {
    let slug: String
    let name: String
    let summary: String?
    let directoryURL: URL
}

enum SkillLibraryError: LocalizedError {
    case emptyContent
    case invalidSkill(String)
    case duplicateSkill(String)

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "Skill content is empty"
        case .invalidSkill(let message):
            return "Invalid skill: \(message)"
        case .duplicateSkill(let message):
            return "Skill already exists: \(message)"
        }
    }
}

struct SkillLibraryService {
    static let shared = SkillLibraryService()

    private let fileManager = FileManager.default

    func libraryRootURL() -> URL {
        if let containerURL = AppGroup.containerURL {
            return containerURL.appendingPathComponent("Skills", isDirectory: true)
        }
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("Skills", isDirectory: true)
    }

    func skillDirectoryURL(for slug: String) -> URL {
        libraryRootURL().appendingPathComponent(slug, isDirectory: true)
    }

    func installSkill(content: String,
                      suggestedName: String?,
                      suggestedSummary: String?,
                      existingSlugs: Set<String>) throws -> SkillInstallResult {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw SkillLibraryError.emptyContent
        }

        let summary = parseFrontMatter(trimmedContent)
        let rawName = summary.name ?? suggestedName ?? "Untitled Skill"
        let resolvedName = SkillNameFormatter.displayName(from: rawName)
        let resolvedSummary = summary.description ?? suggestedSummary
        let resolvedSlug = uniqueSlug(from: resolvedName, existingSlugs: existingSlugs)

        let rootURL = libraryRootURL()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let skillURL = skillDirectoryURL(for: resolvedSlug)
        if fileManager.fileExists(atPath: skillURL.path) {
            throw SkillLibraryError.duplicateSkill(resolvedSlug)
        }
        try fileManager.createDirectory(at: skillURL, withIntermediateDirectories: true)

        let skillFileURL = skillURL.appendingPathComponent("SKILL.md", isDirectory: false)
        try trimmedContent.write(to: skillFileURL, atomically: true, encoding: .utf8)

        return SkillInstallResult(slug: resolvedSlug,
                                  name: resolvedName,
                                  summary: resolvedSummary,
                                  directoryURL: skillURL)
    }

    func installSkill(from directoryURL: URL,
                      suggestedName: String?,
                      suggestedSummary: String?,
                      existingSlugs: Set<String>) throws -> SkillInstallResult {
        let skillFileURL = directoryURL.appendingPathComponent("SKILL.md", isDirectory: false)
        guard fileManager.fileExists(atPath: skillFileURL.path) else {
            throw SkillLibraryError.invalidSkill("Missing SKILL.md in \(directoryURL.lastPathComponent)")
        }

        let content = try String(contentsOf: skillFileURL, encoding: .utf8)
        let summary = parseFrontMatter(content)
        let fallbackName = suggestedName ?? directoryURL.lastPathComponent
        let rawName = summary.name ?? fallbackName
        let resolvedName = SkillNameFormatter.displayName(from: rawName)
        let resolvedSummary = summary.description ?? suggestedSummary
        let resolvedSlug = uniqueSlug(from: resolvedName, existingSlugs: existingSlugs)

        let rootURL = libraryRootURL()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let destinationURL = skillDirectoryURL(for: resolvedSlug)
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw SkillLibraryError.duplicateSkill(resolvedSlug)
        }

        try fileManager.moveItem(at: directoryURL, to: destinationURL)

        return SkillInstallResult(slug: resolvedSlug,
                                  name: resolvedName,
                                  summary: resolvedSummary,
                                  directoryURL: destinationURL)
    }

    func loadSkillMarkdown(for slug: String) throws -> String {
        let skillFileURL = skillDirectoryURL(for: slug).appendingPathComponent("SKILL.md", isDirectory: false)
        guard fileManager.fileExists(atPath: skillFileURL.path) else {
            throw SkillLibraryError.invalidSkill("Missing SKILL.md for \(slug)")
        }
        return try String(contentsOf: skillFileURL, encoding: .utf8)
    }

    func deleteSkillDirectory(for slug: String) throws {
        let directoryURL = skillDirectoryURL(for: slug)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    func parseFrontMatter(_ content: String) -> SkillFrontMatterSummary {
        let lines = content.components(separatedBy: .newlines)
        guard let firstLine = lines.first, firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            return SkillFrontMatterSummary(name: nil, description: nil)
        }

        var name: String?
        var description: String?
        var index = 1

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                break
            }
            if let value = parseFrontMatterValue(line, key: "name") {
                name = value
            } else if let value = parseFrontMatterValue(line, key: "description") {
                description = value
            }
            index += 1
        }

        return SkillFrontMatterSummary(name: name, description: description)
    }

    private func parseFrontMatterValue(_ line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(key):") else { return nil }
        let value = trimmed.dropFirst(key.count + 1)
        let cleaned = value.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func uniqueSlug(from name: String, existingSlugs: Set<String>) -> String {
        var baseSlug = slugify(name)
        if baseSlug.isEmpty {
            baseSlug = "skill"
        }

        if !existingSlugs.contains(baseSlug) {
            return baseSlug
        }

        var suffix = 2
        var candidate = "\(baseSlug)-\(suffix)"
        while existingSlugs.contains(candidate) {
            suffix += 1
            candidate = "\(baseSlug)-\(suffix)"
        }
        return candidate
    }

    private func slugify(_ raw: String) -> String {
        let lowercased = raw.lowercased()
        var result = ""
        var previousWasDash = false

        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.append(Character(scalar))
                previousWasDash = false
            } else if !previousWasDash {
                result.append("-")
                previousWasDash = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed
    }
}
