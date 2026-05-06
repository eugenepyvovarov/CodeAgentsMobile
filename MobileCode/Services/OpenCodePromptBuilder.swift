//
//  OpenCodePromptBuilder.swift
//  CodeAgentsMobile
//
//  Purpose: Converts app-composed prompts into native OpenCode prompt payloads.
//

import Foundation
import UniformTypeIdentifiers

struct OpenCodePromptBuildResult {
    let payload: OpenCodePromptPayload
    let fileReferences: [OpenCodePromptFileReference]
    let skillReference: OpenCodePromptSkillReference?
    let components: ComposedPromptComponents
}

struct OpenCodePromptFileReference: Equatable {
    let originalReference: String
    let absolutePath: String
    let fileURL: String
    let filename: String
    let mime: String
}

struct OpenCodePromptSkillReference: Equatable {
    let slug: String
    let displayName: String?
    let skillFilePaths: [String]
}

enum OpenCodePromptBuildError: LocalizedError, Equatable {
    case invalidFileReference(String)
    case missingAttachment(String)
    case missingSkill(slug: String, checkedPaths: [String])

    var errorDescription: String? {
        switch self {
        case .invalidFileReference(let reference):
            return "Attachment reference is invalid: \(reference)"
        case .missingAttachment(let path):
            return "Attachment does not exist on the server: \(path)"
        case .missingSkill(let slug, let checkedPaths):
            let suffix = checkedPaths.isEmpty ? "" : " Checked: \(checkedPaths.joined(separator: ", "))"
            return "Selected skill is not installed on the server: \(slug).\(suffix)"
        }
    }
}

enum OpenCodePromptBuilder {
    static func build(
        messageID: String?,
        composedPrompt: String,
        projectPath: String,
        model: OpenCodePromptModel? = nil,
        systemRules: String = CodeAgentsUIRules.rulesMarkdown
    ) throws -> OpenCodePromptBuildResult {
        let components = ComposedPromptParser.parse(composedPrompt)
        let fileReferences = try components.fileReferences.map {
            try makeFileReference(from: $0, projectPath: projectPath)
        }
        let skillReference = makeSkillReference(from: components, projectPath: projectPath)

        let payload = OpenCodePromptPayload(
            messageID: openCodeMessageID(from: messageID),
            model: model,
            system: makeSystemPrompt(systemRules: systemRules, skillReference: skillReference),
            tools: skillReference == nil ? nil : ["skill": true],
            parts: makeParts(message: components.message, files: fileReferences, skillReference: skillReference)
        )

        return OpenCodePromptBuildResult(
            payload: payload,
            fileReferences: fileReferences,
            skillReference: skillReference,
            components: components
        )
    }

    // MARK: - Private

    private static func openCodeMessageID(from value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.hasPrefix("msg_") else {
            return nil
        }
        return trimmed
    }

    private static func makeParts(
        message: String,
        files: [OpenCodePromptFileReference],
        skillReference: OpenCodePromptSkillReference?
    ) -> [OpenCodePromptPart] {
        var parts: [OpenCodePromptPart] = []
        let text = promptText(message: message, hasFiles: !files.isEmpty, hasSkill: skillReference != nil)
        parts.append(.text(text))
        parts.append(contentsOf: files.map {
            .file(mime: $0.mime, filename: $0.filename, url: $0.fileURL)
        })
        return parts
    }

    private static func promptText(message: String, hasFiles: Bool, hasSkill: Bool) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if hasSkill, hasFiles {
            return "Use the selected skill with the attached file(s)."
        }
        if hasSkill {
            return "Use the selected skill for this request."
        }
        if hasFiles {
            return "Use the attached file(s) for this request."
        }
        return ""
    }

    private static func makeSystemPrompt(
        systemRules: String,
        skillReference: OpenCodePromptSkillReference?
    ) -> String? {
        var sections = [systemRules.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }

        if let skillReference {
            let label = skillReference.displayName?.nilIfEmpty ?? skillReference.slug
            sections.append("""
OpenCode skill request:
- The user selected the "\(label)" skill with slug "\(skillReference.slug)".
- Use OpenCode's skill mechanism when that skill is available.
- If OpenCode cannot load or apply the selected skill, state that clearly before continuing.
""")
        }

        let system = sections.joined(separator: "\n\n")
        return system.isEmpty ? nil : system
    }

    private static func makeFileReference(
        from reference: String,
        projectPath: String
    ) throws -> OpenCodePromptFileReference {
        let trimmed = reference
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .droppingLeadingAtSign
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty,
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else {
            throw OpenCodePromptBuildError.invalidFileReference(reference)
        }

        let absolutePath = trimmed.hasPrefix("/")
            ? trimmed
            : PathUtils.join(projectPath, trimmed)
        let filename = (absolutePath as NSString).lastPathComponent.nilIfEmpty ?? "attachment"
        let mime = mimeType(for: filename)
        let url = URL(fileURLWithPath: absolutePath).absoluteString

        return OpenCodePromptFileReference(
            originalReference: trimmed,
            absolutePath: absolutePath,
            fileURL: url,
            filename: filename,
            mime: mime
        )
    }

    private static func makeSkillReference(
        from components: ComposedPromptComponents,
        projectPath: String
    ) -> OpenCodePromptSkillReference? {
        let slug = (components.skillSlug ?? components.skillName.map(slugFromSkillName))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).droppingLeadingSlash }
            .flatMap(\.nilIfEmpty)
        guard let slug else { return nil }

        let skillFilePaths = AgentProjectFileLayout.skillLookupRelativePaths.map { root in
            AgentProjectFileLayout.remotePath(
                projectPath: projectPath,
                relativePath: PathUtils.join(root, "\(slug)/SKILL.md")
            )
        }

        return OpenCodePromptSkillReference(
            slug: slug,
            displayName: components.skillName,
            skillFilePaths: skillFilePaths
        )
    }

    private static func mimeType(for filename: String) -> String {
        let pathExtension = (filename as NSString).pathExtension
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
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

    var droppingLeadingAtSign: String {
        hasPrefix("@") ? String(dropFirst()) : self
    }

    var droppingLeadingSlash: String {
        hasPrefix("/") ? String(dropFirst()) : self
    }
}
