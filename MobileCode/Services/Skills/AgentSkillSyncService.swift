//
//  AgentSkillSyncService.swift
//  CodeAgentsMobile
//
//  Purpose: Copies skills from the local library to a remote agent folder
//

import Foundation

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
            throw SkillLibraryError.invalidSkill("Missing local skill folder for \(skill.slug)")
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let remoteRoot = "\(project.path)/.claude/skills"
        let remoteSkillPath = "\(remoteRoot)/\(skill.slug)"

        try await ensureRemoteDirectory(remoteRoot, session: session)
        try await ensureRemoteDirectory(remoteSkillPath, session: session)

        try await uploadDirectory(localURL: localURL, remotePath: remoteSkillPath, session: session)
    }

    func removeSkill(_ skill: AgentSkill, from project: RemoteProject) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let remoteSkillPath = "\(project.path)/.claude/skills/\(skill.slug)"
        let escaped = shellEscaped(remoteSkillPath)
        _ = try await session.execute("rm -rf \(escaped)")
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
