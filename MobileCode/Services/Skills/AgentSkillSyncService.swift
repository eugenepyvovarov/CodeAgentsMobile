//
//  AgentSkillSyncService.swift
//  CodeAgentsMobile
//
//  Purpose: Copies skills from the local library to a remote agent folder,
//  and discovers skills already present on the remote project.
//

import Foundation
import SwiftData

struct RemoteDiscoveredSkill: Equatable, Identifiable {
    var id: String { slug }
    let slug: String
    let name: String
    let summary: String?
    let relativePath: String
}

struct RemoteSkillImportResult: Equatable {
    let discovered: [RemoteDiscoveredSkill]
    let createdSkills: Int
    let createdAssignments: Int
    let updatedSkills: Int
}

@MainActor
final class AgentSkillSyncService {
    static let shared = AgentSkillSyncService()

    private let sshService = ServiceManager.shared.sshService
    private let libraryService = SkillLibraryService.shared
    private let fileManager = FileManager.default

    private init() { }

    func installSkill(_ skill: AgentSkill, to project: RemoteProject) async throws {
        let localURL = libraryService.skillDirectoryURL(for: skill.slug)
        guard fileManager.fileExists(atPath: localURL.path) else {
            // Remote-discovered skills already live on the host; assignment is enough.
            if skill.source == .remote {
                return
            }
            throw SkillLibraryError.invalidSkill("Missing local skill folder for \(skill.slug)")
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let remoteRoot = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.skillsInstallRelativePath
        )
        let remoteSkillPath = "\(remoteRoot)/\(skill.slug)"

        try await ensureRemoteDirectory(remoteRoot, session: session)
        try await ensureRemoteDirectory(remoteSkillPath, session: session)

        try await uploadDirectory(localURL: localURL, remotePath: remoteSkillPath, session: session)
    }

    func removeSkill(_ skill: AgentSkill, from project: RemoteProject) async throws {
        // Keep agent-installed remote folders; only drop marketplace/github uploads.
        if skill.source == .remote {
            return
        }
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let remoteSkillPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: "\(AgentProjectFileLayout.skillsInstallRelativePath)/\(skill.slug)"
        )
        let escaped = shellEscaped(remoteSkillPath)
        _ = try await session.execute("rm -rf \(escaped)")
    }

    func remoteSkillLookupRoots(for project: RemoteProject) -> [String] {
        AgentProjectFileLayout.skillLookupRelativePaths.map {
            AgentProjectFileLayout.remotePath(projectPath: project.path, relativePath: $0)
        }
    }

    /// List skill directories that contain `SKILL.md` under known project skill roots.
    func listRemoteSkills(on project: RemoteProject) async throws -> [RemoteDiscoveredSkill] {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let projectPath = shellEscaped(project.path)
        let roots = AgentProjectFileLayout.skillLookupRelativePaths
            .map { shellEscaped($0) }
            .joined(separator: " ")

        // Emit one block per skill: slug, relative path, then front-matter head of SKILL.md.
        let script = """
        set -e
        PROJECT=\(projectPath)
        for ROOT in \(roots); do
          DIR="$PROJECT/$ROOT"
          [ -d "$DIR" ] || continue
          for SKILL_DIR in "$DIR"/*; do
            [ -d "$SKILL_DIR" ] || continue
            SKILL_MD="$SKILL_DIR/SKILL.md"
            [ -f "$SKILL_MD" ] || continue
            SLUG=$(basename "$SKILL_DIR")
            REL="$ROOT/$SLUG"
            printf '___SKILL_BEGIN___\\n'
            printf '%s\\n' "$SLUG"
            printf '%s\\n' "$REL"
            head -c 8000 "$SKILL_MD" 2>/dev/null || true
            printf '\\n___SKILL_END___\\n'
          done
        done
        """

        let output = try await session.execute(script)
        return parseRemoteSkillScanOutput(output)
    }

    /// Upsert local `AgentSkill` + per-project assignment from remote skill folders.
    @discardableResult
    func importRemoteSkills(
        for project: RemoteProject,
        into modelContext: ModelContext
    ) async throws -> RemoteSkillImportResult {
        let discovered = try await listRemoteSkills(on: project)

        let skillDescriptor = FetchDescriptor<AgentSkill>()
        let existingSkills = (try? modelContext.fetch(skillDescriptor)) ?? []
        var skillsBySlug: [String: AgentSkill] = [:]
        for skill in existingSkills {
            skillsBySlug[skill.slug] = skill
        }

        let projectId = project.id
        let assignmentDescriptor = FetchDescriptor<AgentSkillAssignment>(
            predicate: #Predicate { $0.projectId == projectId }
        )
        let existingAssignments = (try? modelContext.fetch(assignmentDescriptor)) ?? []
        var assignedSlugs = Set(existingAssignments.map(\.skillSlug))

        var createdSkills = 0
        var createdAssignments = 0
        var updatedSkills = 0

        for remote in discovered {
            if let skill = skillsBySlug[remote.slug] {
                var changed = false
                if skill.name != remote.name {
                    skill.name = remote.name
                    changed = true
                }
                if skill.summary != remote.summary {
                    skill.summary = remote.summary
                    changed = true
                }
                if skill.source == .unknown {
                    skill.source = .remote
                    skill.sourceReference = remote.relativePath
                    changed = true
                }
                if changed {
                    skill.markUpdated()
                    updatedSkills += 1
                }
            } else {
                let skill = AgentSkill(
                    slug: remote.slug,
                    name: remote.name,
                    summary: remote.summary,
                    author: nil,
                    source: .remote,
                    sourceReference: remote.relativePath
                )
                modelContext.insert(skill)
                skillsBySlug[remote.slug] = skill
                createdSkills += 1
            }

            if !assignedSlugs.contains(remote.slug) {
                modelContext.insert(AgentSkillAssignment(projectId: project.id, skillSlug: remote.slug))
                assignedSlugs.insert(remote.slug)
                createdAssignments += 1
            }
        }

        return RemoteSkillImportResult(
            discovered: discovered,
            createdSkills: createdSkills,
            createdAssignments: createdAssignments,
            updatedSkills: updatedSkills
        )
    }

    func parseRemoteSkillScanOutput(_ output: String) -> [RemoteDiscoveredSkill] {
        var results: [RemoteDiscoveredSkill] = []
        var seen = Set<String>()
        let blocks = output.components(separatedBy: "___SKILL_BEGIN___")
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let body = trimmed.components(separatedBy: "___SKILL_END___").first ?? trimmed
            var lines = body.components(separatedBy: .newlines)
            while let first = lines.first, first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.removeFirst()
            }
            guard lines.count >= 2 else { continue }
            let slug = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let relativePath = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slug.isEmpty, !seen.contains(slug) else { continue }
            let markdown = lines.dropFirst(2).joined(separator: "\n")
            let frontMatter = libraryService.parseFrontMatter(markdown)
            let name = SkillNameFormatter.displayName(from: frontMatter.name ?? slug)
            results.append(
                RemoteDiscoveredSkill(
                    slug: slug,
                    name: name,
                    summary: frontMatter.description,
                    relativePath: relativePath
                )
            )
            seen.insert(slug)
        }
        return results
    }

    // MARK: - Private

    private func ensureRemoteDirectory(_ path: String, session: SSHSession) async throws {
        let escaped = shellEscaped(path)
        _ = try await session.execute("mkdir -p \(escaped)")
    }

    private func uploadDirectory(localURL: URL, remotePath: String, session: SSHSession) async throws {
        let contents = try fileManager.contentsOfDirectory(at: localURL,
                                                           includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [])
        for item in contents {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            let remoteItemPath = "\(remotePath)/\(item.lastPathComponent)"
            if values.isDirectory == true {
                try await ensureRemoteDirectory(remoteItemPath, session: session)
                try await uploadDirectory(localURL: item, remotePath: remoteItemPath, session: session)
            } else {
                try await session.uploadFile(localPath: item, remotePath: remoteItemPath)
            }
        }
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
