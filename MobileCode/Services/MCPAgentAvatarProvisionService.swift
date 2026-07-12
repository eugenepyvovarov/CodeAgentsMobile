//
//  MCPAgentAvatarProvisionService.swift
//  CodeAgentsMobile
//
//  Purpose: Deploy avatar MCP script and register managed codeagents-avatar server.
//

import Foundation

@MainActor
final class MCPAgentAvatarProvisionService {
    static let shared = MCPAgentAvatarProvisionService()

    /// Must match `SCRIPT_VERSION` in Resources/MCP/codeagents_avatar_mcp.py.
    /// Bump when remote hosts need a forced re-deploy (e.g. protocol fix).
    static let scriptVersion = "2"

    private let sshService = ServiceManager.shared.sshService

    private init() {}

    /// Upload script (if needed) and ensure OpenCode project MCP entry exists.
    /// Re-deploys when the remote script version is stale (protocol fixes).
    func ensureManagedAvatarServer(for project: RemoteProject) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)

        let scriptPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.avatarMCPScriptRelativePath
        )

        let scriptState = try await remoteScriptState(session: session, scriptPath: scriptPath)
        let hasConfig = (try? await CodingAgentMCPService.shared.projectHasServer(
            named: MCPServer.managedAvatarServerName,
            for: project
        )) ?? false

        // Fully current: skip live OpenCode calls.
        if scriptState == .current, hasConfig {
            return
        }

        if scriptState != .current {
            try await deployScript(for: project, session: session)
        }

        let configuration = try await managedAvatarServerConfiguration(for: project, session: session)
        let didWrite = try await CodingAgentMCPService.shared.addServerConfiguration(
            named: MCPServer.managedAvatarServerName,
            configuration: configuration,
            scope: .project,
            for: project,
            allowManaged: true,
            activateLive: true
        )
        // Connect after first provision, config rewrite, or script repair (stale NDJSON fix).
        if didWrite || scriptState != .current {
            await CodingAgentMCPService.shared.connectServerIfNeeded(
                named: MCPServer.managedAvatarServerName,
                for: project
            )
        }
    }

    /// Force re-deploy script + reconnect (used when live status is failed/timeout).
    func repairManagedAvatarServer(for project: RemoteProject) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        try await deployScript(for: project, session: session)

        let configuration = try await managedAvatarServerConfiguration(for: project, session: session)
        _ = try await CodingAgentMCPService.shared.addServerConfiguration(
            named: MCPServer.managedAvatarServerName,
            configuration: configuration,
            scope: .project,
            for: project,
            allowManaged: true,
            activateLive: true
        )
        await CodingAgentMCPService.shared.connectServerIfNeeded(
            named: MCPServer.managedAvatarServerName,
            for: project
        )
    }

    /// Deploy the managed avatar MCP Python script without touching OpenCode config.
    func deployManagedAvatarScript(for project: RemoteProject) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        try await deployScript(for: project, session: session)
    }

    func managedAvatarServer(for project: RemoteProject) -> MCPServer {
        let scriptPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.avatarMCPScriptRelativePath
        )
        return MCPServer(
            name: MCPServer.managedAvatarServerName,
            command: "python3",
            // `-u` keeps stdio unbuffered so OpenCode's MCP handshake is reliable.
            args: ["-u", scriptPath],
            env: [
                "CODEAGENTS_PROJECT_PATH": project.path,
                "PYTHONUNBUFFERED": "1",
            ],
            url: nil,
            headers: nil
        )
    }

    func managedAvatarServerConfiguration(for project: RemoteProject) -> OpenCodeMCPServerConfiguration {
        let scriptPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.avatarMCPScriptRelativePath
        )
        return OpenCodeMCPServerConfiguration(
            type: .local,
            command: ["python3", "-u", scriptPath],
            environment: [
                "CODEAGENTS_PROJECT_PATH": project.path,
                "PYTHONUNBUFFERED": "1",
            ],
            enabled: true,
            // Handshake is fast with NDJSON; keep headroom for cold python on small VMs.
            timeout: 15_000
        )
    }

    // MARK: - Script version / deploy

    private enum RemoteScriptState {
        case missing
        case stale
        case current
    }

    private func remoteScriptState(session: SSHSession, scriptPath: String) async throws -> RemoteScriptState {
        let qScript = shellEscaped(scriptPath)
        let marker = shellEscaped("SCRIPT_VERSION = \"\(Self.scriptVersion)\"")
        // Missing → MISSING; present but wrong version → STALE; matching → CURRENT.
        let command = """
        if [ ! -f \(qScript) ]; then echo MISSING; \
        elif grep -q \(marker) \(qScript) 2>/dev/null; then echo CURRENT; \
        else echo STALE; fi
        """
        let output = try await session.execute(command)
        if output.contains("CURRENT") { return .current }
        if output.contains("STALE") { return .stale }
        return .missing
    }

    /// Prefer absolute `python3` when available so OpenCode's restricted PATH still finds it.
    private func managedAvatarServerConfiguration(
        for project: RemoteProject,
        session: SSHSession
    ) async throws -> OpenCodeMCPServerConfiguration {
        var configuration = managedAvatarServerConfiguration(for: project)
        if let python = try? await resolvePython3(session: session),
           var command = configuration.command,
           !command.isEmpty {
            command[0] = python
            configuration.command = command
        }
        return configuration
    }

    private func resolvePython3(session: SSHSession) async throws -> String? {
        let output = try await session.execute(
            "command -v python3 2>/dev/null || which python3 2>/dev/null || true"
        )
        let path = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.hasPrefix("/") }
        return path.map { String($0) }
    }

    private func deployScript(for project: RemoteProject, session: SSHSession) async throws {
        guard let sourceURL = Bundle.main.url(
            forResource: "codeagents_avatar_mcp",
            withExtension: "py",
            subdirectory: "MCP"
        ) ?? Bundle.main.url(forResource: "codeagents_avatar_mcp", withExtension: "py") else {
            try await writeScript(Self.fallbackScriptUTF8, for: project, session: session)
            return
        }
        let data = try Data(contentsOf: sourceURL)
        try await writeScript(data, for: project, session: session)
    }

    private func writeScript(_ data: Data, for project: RemoteProject, session: SSHSession) async throws {
        let remotePath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.avatarMCPScriptRelativePath
        )
        let dir = (remotePath as NSString).deletingLastPathComponent
        let base64 = data.base64EncodedString()
        let command = """
        mkdir -p \(shellEscaped(dir)) && printf '%s' \(shellEscaped(base64)) | (base64 -d 2>/dev/null || base64 --decode) > \(shellEscaped(remotePath)) && chmod +x \(shellEscaped(remotePath))
        """
        _ = try await session.execute(command)
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    /// Kept in-sync with Resources/MCP/codeagents_avatar_mcp.py for resource-less builds.
    /// NDJSON framing (OpenCode / official MCP SDK) — not Content-Length.
    private static var fallbackScriptUTF8: Data {
        Data(Self.embeddedScript.utf8)
    }

    private static let embeddedScript: String = {
        """
        #!/usr/bin/env python3
        # SCRIPT_VERSION = "2"
        import json,os,sys,shutil
        from pathlib import Path
        from datetime import datetime,timezone
        SCRIPT_VERSION='2'
        ROOT=Path(os.environ.get('CODEAGENTS_PROJECT_PATH') or os.getcwd()).expanduser().resolve()
        ID=ROOT/'.codeagents'/'codeagents.json'
        IMG=ROOT/'.codeagents'/'avatar.png'
        def load():
          if not ID.is_file(): return {'schema_version':2,'agent_id':'','avatar':{'kind':'none'}}
          try: return json.loads(ID.read_text())
          except Exception: return {'schema_version':2,'agent_id':'','avatar':{'kind':'none'}}
        def save(d):
          ID.parent.mkdir(parents=True,exist_ok=True); d['schema_version']=max(int(d.get('schema_version') or 1),2)
          ID.write_text(json.dumps(d,indent=2,sort_keys=True)+'\\n')
        def now(): return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')
        def ok(t,err=False): return {'content':[{'type':'text','text':t}],'isError':err}
        def rel_ok(p):
          t=(p or '').strip()
          if not t or t.startswith('/') or t.startswith('~'): return None
          parts=Path(t).parts
          if not parts or any(x in ('','.','..') for x in parts): return None
          r=Path(*parts); c=(ROOT/r).resolve()
          try: c.relative_to(ROOT); return r
          except ValueError: return None
        def handle(name,args):
          if name=='get_agent_avatar': return ok(json.dumps({'avatar':load().get('avatar') or {'kind':'none'}},indent=2))
          if name=='set_agent_avatar_emoji':
            e=list(str(args.get('emoji') or '').strip())
            if not e: return ok('emoji required',True)
            d=load(); prev=d.get('avatar') if isinstance(d.get('avatar'),dict) else {}
            d['avatar']={'kind':'emoji','emoji':e[0],'image':prev.get('image'),'updated_at':now(),'updated_by':'mcp'}; save(d); return ok(json.dumps(d['avatar']))
          if name=='set_agent_avatar_image':
            r=rel_ok(str(args.get('path') or ''))
            if r is None: return ok('bad path',True)
            src=(ROOT/r).resolve()
            if not src.is_file(): return ok('missing',True)
            IMG.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,IMG)
            d=load(); d['avatar']={'kind':'image','emoji':None,'image':'.codeagents/avatar.png','updated_at':now(),'updated_by':'mcp'}; save(d); return ok(json.dumps(d['avatar']))
          if name=='clear_agent_avatar':
            d=load(); d['avatar']={'kind':'none','emoji':None,'image':None,'updated_at':now(),'updated_by':'mcp'}; save(d)
            if IMG.is_file():
              try: IMG.unlink()
              except OSError: pass
            return ok(json.dumps(d['avatar']))
          return ok('unknown',True)
        def send(m):
          sys.stdout.buffer.write((json.dumps(m,separators=(',',':'),ensure_ascii=False)+'\\n').encode()); sys.stdout.buffer.flush()
        def read():
          line=sys.stdin.buffer.readline()
          if not line: return None
          if line.lower().startswith(b'content-length:'):
            h={'content-length':line.decode('ascii','replace').split(':',1)[1].strip()}
            while True:
              hl=sys.stdin.buffer.readline()
              if not hl or hl in (b'\\r\\n',b'\\n'): break
              t=hl.decode('ascii','replace').strip()
              if ':' in t:
                k,v=t.split(':',1); h[k.strip().lower()]=v.strip()
            n=int(h.get('content-length') or 0)
            if n<=0: return None
            return json.loads(sys.stdin.buffer.read(n).decode())
          t=line.decode('utf-8','replace').strip()
          if not t: return read()
          return json.loads(t)
        while True:
          m=read()
          if m is None: break
          method=m.get('method'); mid=m.get('id'); params=m.get('params') or {}
          if method=='initialize':
            send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'codeagents-avatar','version':'1.0.1'},'instructions':'Use set_agent_avatar_emoji/set_agent_avatar_image/clear_agent_avatar; do not edit codeagents.json by hand.'}}); continue
          if method in ('notifications/initialized',): continue
          if method=='ping': send({'jsonrpc':'2.0','id':mid,'result':{}}); continue
          if method=='tools/list':
            tools=[{'name':'get_agent_avatar','description':'Get avatar','inputSchema':{'type':'object','properties':{}}},{'name':'set_agent_avatar_emoji','description':'Set emoji avatar via MCP','inputSchema':{'type':'object','properties':{'emoji':{'type':'string'}},'required':['emoji']}},{'name':'set_agent_avatar_image','description':'Set image avatar from project path','inputSchema':{'type':'object','properties':{'path':{'type':'string'}},'required':['path']}},{'name':'clear_agent_avatar','description':'Clear avatar','inputSchema':{'type':'object','properties':{}}}]
            send({'jsonrpc':'2.0','id':mid,'result':{'tools':tools}}); continue
          if method=='tools/call':
            try: send({'jsonrpc':'2.0','id':mid,'result':handle(params.get('name'),params.get('arguments') or {})})
            except Exception as e: send({'jsonrpc':'2.0','id':mid,'result':ok(str(e),True)})
            continue
          if mid is not None: send({'jsonrpc':'2.0','id':mid,'error':{'code':-32601,'message':str(method)}})
        """
    }()
}
