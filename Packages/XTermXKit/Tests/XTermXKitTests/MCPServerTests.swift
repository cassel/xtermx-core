#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

/// The agent tool server, spoken to over real HTTP the way Claude Code or Codex would.
@MainActor
@Suite(.serialized) struct MCPServerTests {
    let manager = PaneManager(detectAgents: false)
    let server: MCPServer
    let repo: URL

    init() async throws {
        server = MCPServer(manager: manager)
        try await server.start()
        manager.agents = [AgentDescriptor(id: "fake", name: "Fake Agent", command: "true", installed: true, symbol: "x")]
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("xtx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    struct Reply {
        var status: Int
        var json: JSONValue?
        var text: String? { json?["result"]?["content"]?.array?.first?["text"]?.string }
        var isError: Bool { json?["result"]?["isError"]?.bool ?? false }
    }

    func post(_ body: JSONValue, token: String?, headers: [String: String] = [:]) async throws -> Reply {
        var request = URLRequest(url: try #require(server.url))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        return Reply(status: (response as! HTTPURLResponse).statusCode, json: try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    func call(_ tool: String, _ args: JSONValue = [:], as pane: String) async throws -> Reply {
        try await post(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": args]],
                       token: manager.token(forPane: pane))
    }

    func parent() -> PaneInfo { manager.spawn(SpawnRequest(kind: .shell, cwd: repo.path)) }

    /// Answers the next approval card with `allow`, like the person tapping on any device.
    func answerNextApproval(_ allow: Bool) {
        var id: UUID?
        id = manager.addListener { [manager] event in
            guard case .approvals(let list) = event, let card = list.first else { return }
            if let id { manager.removeListener(id) }
            Task { @MainActor in manager.answer(card.id, allow: allow) }
        }
    }

    @Test func protocolBasicsAndSecurity() async throws {
        let p = parent()
        defer { manager.close(p.id) }
        let token = manager.token(forPane: p.id)

        let initReply = try await post(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                        "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                   "clientInfo": ["name": "test", "version": "1"]]], token: token)
        #expect(initReply.status == 200)
        #expect(initReply.json?["result"]?["protocolVersion"]?.string == "2025-06-18")
        #expect(initReply.json?["result"]?["instructions"]?.string?.contains("pane_spawn") == true)

        let note = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], token: token)
        #expect(note.status == 202)

        let list = try await post(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], token: token)
        let names = list.json?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
        #expect(names.contains("pane_spawn") && names.contains("pane_report") && names.contains("watch_summary"))
        #expect(names.allSatisfy { $0.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil })

        #expect(try await post(["jsonrpc": "2.0", "id": 3, "method": "ping"], token: nil).status == 401)
        #expect(try await post(["jsonrpc": "2.0", "id": 3, "method": "ping"], token: "forged").status == 401)
        #expect(try await post(["jsonrpc": "2.0", "id": 3, "method": "ping"], token: token, headers: ["Origin": "https://evil.example"]).status == 403)
    }

    @Test func spawnNeedsSettingAndApproval() async throws {
        let p = parent()
        defer { manager.panes.map(\.id).forEach(manager.close) }
        let brief: JSONValue = ["agent": "fake", "title": "Helper", "brief": "GOAL: say hi\nSCOPE: nothing"]

        server.tools.allowAgentPanes = false
        let off = try await call("pane_spawn", brief, as: p.id)
        #expect(off.isError && off.text?.hasPrefix("PANE_SPAWN_OFF") == true)

        server.tools.allowAgentPanes = true
        defer { server.tools.allowAgentPanes = false }

        answerNextApproval(false)
        let denied = try await call("pane_spawn", brief, as: p.id)
        #expect(denied.isError && denied.text?.hasPrefix("SPAWN_DENIED") == true)
        #expect(manager.panes.count == 1)

        answerNextApproval(true)
        let opened = try await call("pane_spawn", brief, as: p.id)
        #expect(!opened.isError)
        let child = try #require(manager.panes.first { $0.parentID == p.id })
        #expect(child.openedByAgent && child.title == "Helper" && child.agentID == "fake")

        // The brief sits in a private file.
        let briefURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XTermX/briefs/\(child.id).md")
        #expect((try? String(contentsOf: briefURL, encoding: .utf8))?.contains("say hi") == true)
        let perms = try FileManager.default.attributesOfItem(atPath: briefURL.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        // Children cannot open children, and nobody closes panes but the person.
        let grandchild = try await call("pane_spawn", brief, as: child.id)
        #expect(grandchild.text?.hasPrefix("CHILD_CANNOT_SPAWN") == true)
        let close = try await call("pane_close", ["pane": .string(String(child.id.prefix(8)))], as: p.id)
        #expect(close.text?.hasPrefix("PANE_CLOSE_PERSON_ONLY") == true)
        try? FileManager.default.removeItem(at: briefURL)
    }

    @Test func childReportsReachTheOpener() async throws {
        let p = parent()
        defer { manager.panes.map(\.id).forEach(manager.close) }
        server.tools.allowAgentPanes = true
        defer { server.tools.allowAgentPanes = false }

        let shell = try await call("pane_shell", ["title": "build"], as: p.id)
        #expect(!shell.isError)
        let child = try #require(manager.panes.first { $0.parentID == p.id })
        let handle = String(child.id.prefix(8)).lowercased()

        let listed = try await call("pane_list", as: p.id)
        #expect(listed.text?.contains(handle) == true)

        #expect(try await call("pane_send", ["pane": .string(handle), "text": "echo MCP_$((20+22))"], as: p.id).isError == false)
        #expect(try await call("pane_send", ["pane": .string(handle), "text": "true --go"], as: p.id).text?.hasPrefix("AGENT_COMMAND") == true)

        var screen = ""
        for _ in 0..<40 where !screen.contains("MCP_42") {
            try await Task.sleep(for: .milliseconds(250))
            screen = try await call("pane_read", ["pane": .string(handle), "lines": 20], as: p.id).text ?? ""
        }
        #expect(screen.contains("MCP_42") && screen.contains("<untrusted-data"))

        // The child reports; the opener's wait returns it.
        async let waited = call("pane_wait", ["on": ["report"], "timeoutMs": 10_000], as: p.id)
        try await Task.sleep(for: .milliseconds(300))
        let sent = try await call("pane_report", ["text": "All green", "status": "done", "files": ["a.swift"],
                                                  "tests": ["passed": 3, "failed": 0]], as: child.id)
        #expect(!sent.isError)
        let result = try await waited
        #expect(result.text?.contains("All green") == true && result.text?.contains("\"timedOut\" : false") == true)

        // A pane nobody opened has nobody to report to; foreign panes stay private.
        #expect(try await call("pane_report", ["text": "x", "status": "done"], as: p.id).text?.hasPrefix("NO_OPENER") == true)
        let other = parent()
        #expect(try await call("pane_read", ["pane": .string(handle)], as: other.id).text?.hasPrefix("NOT_YOUR_PANE") == true)
    }

    @Test func foldersStayInsideTheRepository() async throws {
        let p = parent()
        defer { manager.panes.map(\.id).forEach(manager.close) }
        server.tools.allowAgentPanes = true
        defer { server.tools.allowAgentPanes = false }
        let outside = try await call("pane_shell", ["cwd": "/tmp"], as: p.id)
        #expect(outside.text?.hasPrefix("CWD_OUTSIDE_REPO") == true)
        let escape = try await call("pane_shell", ["cwd": "../.."], as: p.id)
        #expect(escape.text?.hasPrefix("CWD_OUTSIDE_REPO") == true)
        let inside = try await call("pane_shell", ["cwd": "sub/dir"], as: p.id)
        #expect(!inside.isError)
    }

    @Test func agentLaunchRegistersTheServer() async throws {
        manager.agents = [
            AgentDescriptor(id: "claude-code", name: "Claude Code", command: "true", installed: true, symbol: "x"),
            AgentDescriptor(id: "codex", name: "Codex", command: "true", installed: true, symbol: "x"),
            AgentDescriptor(id: "gemini", name: "Gemini CLI", command: "true", installed: true, symbol: "sparkle"),
        ]
        let claude = manager.spawn(SpawnRequest(kind: .agent, agentID: "claude-code", cwd: repo.path, initialInput: "hi"))
        let config = PaneManager.toolConfigURL(paneID: claude.id)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: config))
        #expect(json["mcpServers"]?["xtermx"]?["url"]?.string == server.url?.absoluteString)
        #expect(json["mcpServers"]?["xtermx"]?["headers"]?["Authorization"]?.string == "Bearer \(manager.token(forPane: claude.id) ?? "-")")
        let perms = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        manager.close(claude.id)
        #expect(!FileManager.default.fileExists(atPath: config.path))
        let gemini = manager.spawn(SpawnRequest(kind: .agent, agentID: "gemini", cwd: repo.path))
        let geminiConfig = PaneManager.toolConfigURL(paneID: gemini.id)
        defer { manager.close(gemini.id) }
        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: geminiConfig))
        #expect(settings["mcpServers"]?["xtermx-pane"]?["httpUrl"]?.string == server.url?.absoluteString)
        #expect(settings["mcpServers"]?["xtermx-pane"]?["headers"]?["Authorization"]?.string == "Bearer \(manager.token(forPane: gemini.id) ?? "-")")
        #expect(try FileManager.default.attributesOfItem(atPath: geminiConfig.path)[.posixPermissions] as? Int == 0o600)
    }
}
#endif

#if os(macOS)
/// A real Claude Code talking to the tool server. Opt in: `XTX_LIVE_CLAUDE=1 swift test --filter LiveClaude`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["XTX_LIVE_CLAUDE"] == "1"))
struct LiveClaudeTests {
    @Test func claudeCodeCallsTheTools() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = MCPServer(manager: manager)
        let url = try await server.start()
        manager.agents = [AgentDescriptor(id: "fake", name: "Fake Agent", command: "true", installed: true, symbol: "x")]
        server.tools.allowAgentPanes = true
        defer { server.tools.allowAgentPanes = false }

        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("xtx-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let parent = manager.spawn(SpawnRequest(kind: .shell, cwd: repo.path, title: "Live parent"))
        defer { manager.panes.map(\.id).forEach(manager.close) }
        let token = try #require(manager.token(forPane: parent.id))

        let config = repo.appendingPathComponent("mcp.json")
        let json: JSONValue = ["mcpServers": ["xtermx": ["type": "http", "url": .string(url.absoluteString),
                                                         "headers": ["Authorization": .string("Bearer \(token)")]]]]
        try Data(json.prettyText.utf8).write(to: config)

        // Approve the spawn card like the person would.
        manager.addListener { [manager] event in
            if case .approvals(let list) = event, let card = list.first {
                Task { @MainActor in manager.answer(card.id, allow: true) }
            }
        }

        let prompt = "Use the xtermx tools: call machine_check, then pane_spawn with agent \"fake\", title \"Live child\" " +
            "and brief \"GOAL: nothing\", then pane_list. Reply with one line: the machine_check verdict and the spawned pane handle."
        let claude = Process()
        claude.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/claude")
        claude.arguments = ["-p", prompt, "--model", "haiku", "--strict-mcp-config", "--mcp-config", config.path,
                            "--allowedTools", "mcp__xtermx__machine_check,mcp__xtermx__pane_spawn,mcp__xtermx__pane_list"]
        claude.currentDirectoryURL = repo
        let out = Pipe()
        claude.standardOutput = out
        claude.standardError = out
        try claude.run()
        // Keep the main actor free while Claude works: the server answers on it.
        while claude.isRunning { try await Task.sleep(for: .milliseconds(200)) }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        print("claude said:", text)

        let tools = server.recentCalls.map(\.tool)
        print("tool calls:", server.recentCalls.map { "\($0.tool) ok=\($0.ok) \($0.detail)" })
        #expect(tools.contains("machine_check"))
        #expect(tools.contains("pane_spawn"))
        #expect(manager.panes.contains { $0.parentID == parent.id && $0.title == "Live child" && $0.openedByAgent })
    }
}
#endif
