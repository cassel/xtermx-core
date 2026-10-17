#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

/// Claude Code and Codex sessions: reading their files, answering their hooks, installing the hooks.
@MainActor
@Suite(.serialized) struct AgentSessionsTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xtx-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ lines: [JSONValue]) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func append(_ path: String, _ line: JSONValue) throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(path))
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONEncoder().encode(line) + Data("\n".utf8))
        try handle.close()
    }

    static func assistant(_ id: String, input: Int = 0, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0,
                          tool: String? = nil, stop: String? = nil) -> JSONValue {
        var content: [JSONValue] = [["type": "text", "text": "…"]]
        if let tool { content.append(["type": "tool_use", "name": .string(tool), "input": [:]]) }
        return ["type": "assistant", "message": [
            "id": .string(id), "model": "claude-opus-5-5", "stop_reason": stop.map { .string($0) } ?? .null,
            "usage": ["input_tokens": .number(Double(input)), "output_tokens": .number(Double(output)),
                      "cache_read_input_tokens": .number(Double(cacheRead)), "cache_creation_input_tokens": .number(Double(cacheWrite))],
            "content": .array(content),
        ]]
    }

    @Test func readsClaudeTranscriptRegistryAndSubagents() async throws {
        let transcript = ".claude/projects/-tmp-demo/S1.jsonl"
        try write(transcript, [
            Self.assistant("m1", input: 10, output: 5, cacheRead: 100, cacheWrite: 20, tool: "Bash"),
            Self.assistant("m1", input: 10, output: 7, cacheRead: 100, cacheWrite: 20),  // same message again: counted once
            Self.assistant("m2", input: 1, output: 2),
            ["type": "ai-title", "aiTitle": "Fix the microphone"],
            ["type": "cost-state", "totalCostUSD": .number(0.42)],
        ])
        let registry = ".claude/sessions/\(getpid()).json"
        try write(registry, [["pid": .number(Double(getpid())), "sessionId": "S1", "status": "waiting", "waitingFor": "permission"]])
        try write(".claude/projects/-tmp-demo/S1/subagents/agent-abc.jsonl", [Self.assistant("s1", output: 3, stop: "end_turn")])
        try write(".claude/projects/-tmp-demo/S1/subagents/agent-abc.meta.json", [["agentType": "Explore", "description": "Find the bug"]])

        let reader = AgentTranscriptReader()
        let reg = AgentSessionTracker.Registration(paneID: "p", tool: .claude, sessionID: "S1",
                                                   transcriptPath: root.appendingPathComponent(transcript).path)
        var r = try #require(await reader.poll([reg]).first)
        #expect(!r.ended)
        #expect(r.info.tokens == TokenUsage(input: 11, output: 9, cacheRead: 100, cacheWrite: 20))
        #expect(r.info.model == "claude-opus-5-5")
        #expect(r.info.title == "Fix the microphone")
        #expect(r.info.lastTool == "Bash")
        #expect(r.info.costUSD == 0.42)
        #expect(r.info.status == .waiting)
        #expect(r.info.waitingFor == "permission")
        #expect(r.info.subagents.map(\.name) == ["Explore"])
        #expect(r.info.subagents.first?.tokens.output == 3)

        // Only what was appended is read next time.
        try append(transcript, Self.assistant("m3", output: 100))
        r = try #require(await reader.poll([reg]).first)
        #expect(r.info.tokens.output == 109)

        // The registry going away means the session ended.
        try FileManager.default.removeItem(at: root.appendingPathComponent(registry))
        r = try #require(await reader.poll([reg]).first)
        #expect(r.ended)
    }

    @Test func readsCodexRolloutTokensAndPlanLimits() async throws {
        let rollout = ".codex/sessions/2026/10/15/rollout-2026-10-15T10-00-00-T1.jsonl"
        try write(rollout, [
            ["type": "session_meta", "payload": ["id": "T1", "cwd": "/tmp"]],
            ["type": "turn_context", "payload": ["model": "gpt-5.5-codex"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Add tests for the parser"]],
            ["type": "event_msg", "payload": ["type": "task_started"]],
            ["type": "event_msg", "payload": [
                "type": "token_count",
                "info": ["total_token_usage": ["input_tokens": 1000, "cached_input_tokens": 400, "output_tokens": 50],
                         "last_token_usage": ["input_tokens": 300], "model_context_window": 272_000],
                "rate_limits": ["limit_id": "codex", "plan_type": "pro",
                                "primary": ["used_percent": .number(12.5), "window_minutes": 10080, "resets_at": 1_800_000_000],
                                "secondary": ["used_percent": 40, "window_minutes": 300, "resets_at": 1_799_990_000]],
            ]],
        ])
        try write(".codex/thread-writer-locks/T1.lock", [])

        let reader = AgentTranscriptReader()
        let reg = AgentSessionTracker.Registration(paneID: "p", tool: .codex, sessionID: "T1",
                                                   transcriptPath: root.appendingPathComponent(rollout).path)
        var r = try #require(await reader.poll([reg]).first)
        #expect(r.info.status == .working)
        #expect(r.info.model == "gpt-5.5-codex")
        #expect(r.info.title == "Add tests for the parser")
        #expect(r.info.tokens == TokenUsage(input: 600, output: 50, cacheRead: 400))
        #expect(r.info.contextWindow == 272_000)
        let account = try #require(r.account)
        #expect(account.plan == "pro")
        #expect(account.window(.fiveHour)?.usedPercent == 40)
        #expect(account.window(.weekly)?.usedPercent == 12.5)
        #expect(account.window(.weekly)?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))

        try append(rollout, ["type": "event_msg", "payload": ["type": "task_complete"]])
        r = try #require(await reader.poll([reg]).first)
        #expect(r.info.status == .idle)

        try FileManager.default.removeItem(at: root.appendingPathComponent(".codex/thread-writer-locks/T1.lock"))
        r = try #require(await reader.poll([reg]).first)
        #expect(r.ended)
    }

    // MARK: Hooks over HTTP

    func hook(_ server: MCPServer, _ body: JSONValue, token: String?, event: String? = nil) async throws -> (Int, JSONValue?) {
        let url = try #require(server.url).deletingLastPathComponent().appendingPathComponent("hook")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let event { request.setValue(event, forHTTPHeaderField: "X-XTermX-Hook") }
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// Answers the next card like the person tapping on any device, after checking what it shows.
    func answerNext(_ manager: PaneManager, check: @escaping @MainActor (ApprovalRequest) -> Void = { _ in },
                    with answer: @escaping @MainActor (ApprovalRequest) -> ApprovalAnswer) {
        var id: UUID?
        id = manager.addListener { [manager] event in
            guard case .approvals(let list) = event, let card = list.first else { return }
            if let id { manager.removeListener(id) }
            Task { @MainActor in
                check(card)
                manager.respond(card.id, answer(card))
            }
        }
    }

    @Test func permissionHooksBecomeCardsAndAnswers() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = MCPServer(manager: manager)
        try await server.start()
        defer { server.stop() }
        let pane = manager.spawn(SpawnRequest(kind: .shell, cwd: root.path))
        let token = try #require(manager.token(forPane: pane.id))
        let claudeTranscript = root.appendingPathComponent(".claude/projects/-tmp/S9.jsonl").path

        // No token: refused.
        #expect(try await hook(server, ["hook_event_name": "SessionStart"], token: nil).0 == 401)

        // SessionStart ties the session to the pane and prints nothing.
        let start = try await hook(server, ["hook_event_name": "SessionStart", "session_id": "S9",
                                            "transcript_path": .string(claudeTranscript)], token: token)
        #expect(start.0 == 200 && start.1 == nil)
        #expect(server.sessions.session(paneID: pane.id)?.tool == .claude)

        // Claude permission, "Always allow" passes the suggested rule back.
        let suggestion: JSONValue = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test"]], "behavior": "allow"]
        answerNext(manager, check: { card in
            #expect(card.kind == .permission)
            #expect(card.detail == "npm test")
            #expect(card.options.map(\.role) == [.deny, .allow, .always])
        }, with: { _ in ApprovalAnswer(optionID: "always") })
        var reply = try await hook(server, ["hook_event_name": "PermissionRequest", "transcript_path": .string(claudeTranscript),
                                            "permission_mode": "default", "tool_name": "Bash",
                                            "tool_input": ["command": "npm test"], "permission_suggestions": [suggestion]], token: token)
        var decision = reply.1?["hookSpecificOutput"]?["decision"]
        #expect(decision?["behavior"] == "allow")
        #expect(decision?["updatedPermissions"]?.array == [suggestion])

        // A question comes back as the tool input plus the answers.
        answerNext(manager, check: { card in
            #expect(card.kind == .question)
            #expect(card.questions.first?.options == ["Red", "Blue"])
        }, with: { _ in ApprovalAnswer(answers: ["Which color?": "Blue"]) })
        reply = try await hook(server, ["hook_event_name": "PermissionRequest", "transcript_path": .string(claudeTranscript),
                                        "tool_name": "AskUserQuestion",
                                        "tool_input": ["questions": [["question": "Which color?", "header": "Color",
                                                                      "options": [["label": "Red"], ["label": "Blue"]], "multiSelect": false]]]],
                               token: token)
        decision = reply.1?["hookSpecificOutput"]?["decision"]
        #expect(decision?["behavior"] == "allow")
        #expect(decision?["updatedInput"]?["answers"]?["Which color?"] == "Blue")
        #expect(decision?["updatedInput"]?["questions"]?.array?.count == 1)

        // Codex: no "always", a denial carries the typed reason.
        let rollout = root.appendingPathComponent(".codex/sessions/2026/10/15/rollout-x-T9.jsonl").path
        answerNext(manager, check: { card in
            #expect(card.agentTool == .codex)
            #expect(card.options.map(\.role) == [.deny, .allow])
        }, with: { _ in ApprovalAnswer(optionID: "deny", message: "Not on main") })
        reply = try await hook(server, ["hook_event_name": "PermissionRequest", "transcript_path": .string(rollout), "turn_id": "t1",
                                        "tool_name": "shell", "tool_input": ["command": ["git", "push"]]], token: token)
        decision = reply.1?["hookSpecificOutput"]?["decision"]
        #expect(decision?["behavior"] == "deny")
        #expect(decision?["message"] == "Not on main")

        // Plan limits from Claude Code's status line.
        _ = try await hook(server, ["transcript_path": .string(claudeTranscript),
                                    "rate_limits": ["five_hour": ["used_percentage": 23, "resets_at": 1_800_000_000],
                                                    "seven_day": ["used_percentage": 61]]], token: token, event: "statusline")
        let account = try #require(manager.accounts.first { $0.tool == .claude })
        #expect(account.window(.fiveHour)?.usedPercent == 23)
        #expect(account.window(.weekly)?.usedPercent == 61)
        manager.close(pane.id)
    }

    /// The real `xtermx hook` binary, fed on stdin like Claude Code feeds it.
    func runHook(_ stdin: JSONValue, env: [String: String]) async throws -> (String, Double) {
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/xtermx")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "swift build --product xtermx first")
        let input = try JSONEncoder().encode(stdin)
        return try await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["hook"]
            process.environment = env.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a }
            let inPipe = Pipe(), outPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            let started = Date()
            try process.run()
            inPipe.fileHandleForWriting.write(input)
            try inPipe.fileHandleForWriting.close()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: out, as: UTF8.self), Date().timeIntervalSince(started))
        }.value
    }

    @Test func hookCommandIsInertOutsidePanesAndAnswersInside() async throws {
        let request: JSONValue = ["hook_event_name": "PermissionRequest", "permission_mode": "default",
                                  "transcript_path": "/tmp/.claude/projects/-x/S.jsonl", "tool_name": "Bash", "tool_input": ["command": "ls"]]
        // Outside XTermX: nothing printed, no waiting.
        let (outside, elapsed) = try await runHook(request, env: [:])
        #expect(outside.isEmpty)
        #expect(elapsed < 5)

        let manager = PaneManager(detectAgents: false)
        let server = MCPServer(manager: manager)
        let url = try await server.start()
        defer { server.stop() }
        let pane = manager.spawn(SpawnRequest(kind: .shell, cwd: root.path))
        answerNext(manager) { _ in .allow }
        let (inside, _) = try await runHook(request, env: ["XTERMX_SESSION": try #require(manager.token(forPane: pane.id)),
                                                            "XTERMX_MCP_URL": url.absoluteString])
        let decision = try JSONDecoder().decode(JSONValue.self, from: Data(inside.utf8))["hookSpecificOutput"]?["decision"]
        #expect(decision?["behavior"] == "allow")
        manager.close(pane.id)
    }

    /// Runs a command with `stdin`, off the main actor (the server under test lives there).
    func run(_ executable: String, _ arguments: [String], stdin: String, env: [String: String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = env.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a }
            let inPipe = Pipe(), outPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try inPipe.fileHandleForWriting.close()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: out, as: UTF8.self)
        }.value
    }

    @Test func launcherScriptForwardsHooksAndKeepsTheStatusLine() async throws {
        let saved = AgentHookInstaller.home
        AgentHookInstaller.home = root.path
        defer { AgentHookInstaller.home = saved }
        try AgentHookInstaller.writeLauncher(executable: "/nonexistent")
        let launcher = AgentHookInstaller.launcher.path
        let permission = #"{"hook_event_name": "PermissionRequest", "permission_mode": "default", "transcript_path": "/tmp/.claude/projects/-x/S.jsonl", "tool_name": "Bash", "tool_input": {"command": "ls"}}"#

        // Outside a pane: silent.
        #expect(try await run(launcher, [], stdin: permission, env: ["HOME": root.path]).isEmpty)

        let manager = PaneManager(detectAgents: false)
        let server = MCPServer(manager: manager)
        let url = try await server.start()
        defer { server.stop() }
        let pane = manager.spawn(SpawnRequest(kind: .shell, cwd: root.path))
        let env = ["HOME": root.path, "XTERMX_SESSION": try #require(manager.token(forPane: pane.id)), "XTERMX_MCP_URL": url.absoluteString]

        answerNext(manager) { _ in .deny }
        let out = try await run(launcher, [], stdin: permission, env: env)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))["hookSpecificOutput"]?["decision"]?["behavior"] == "deny")

        // The status line: the person's own command still prints, and the limits reach XTermX.
        let folder = root.appendingPathComponent(".claude").path
        try FileManager.default.createDirectory(at: AgentHookInstaller.ownStatusLineFile(folder: folder).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "cat >/dev/null; echo my-status\n".write(to: AgentHookInstaller.ownStatusLineFile(folder: folder), atomically: true, encoding: .utf8)
        let line = #"{"transcript_path": "\#(folder)/projects/-x/S.jsonl", "rate_limits": {"five_hour": {"used_percentage": 5}}}"#
        let own = AgentHookInstaller.ownStatusLineFile(folder: folder).path
        #expect(try await run(launcher, ["statusline", own], stdin: line, env: env) == "my-status\n")
        // The token never shows in a process list: it is not in curl's arguments.
        #expect(!(try String(contentsOf: AgentHookInstaller.launcher, encoding: .utf8)).contains("-H \"Authorization"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(manager.accounts.first?.window(.fiveHour)?.usedPercent == 5)
        manager.close(pane.id)
    }

    @Test func cardGoesAwayWhenTheAgentGivesUpOnTheHook() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = MCPServer(manager: manager)
        let url = try await server.start()
        defer { server.stop() }
        let pane = manager.spawn(SpawnRequest(kind: .shell, cwd: root.path))
        var request = URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("hook"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(try #require(manager.token(forPane: pane.id)))", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["hook_event_name": "PermissionRequest", "permission_mode": "default",
                                                     "tool_name": "Bash", "tool_input": ["command": "make"]] as JSONValue)
        request.timeoutInterval = 1  // the agent stops waiting (the person answered in its own dialog)
        _ = try? await URLSession.shared.data(for: request)
        for _ in 0..<30 where !manager.approvals.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(manager.approvals.isEmpty)
        manager.close(pane.id)
    }

    // MARK: Installing

    @Test func installerAddsNextToExistingHooksAndRemovesCleanly() throws {
        let saved = AgentHookInstaller.home
        AgentHookInstaller.home = root.path
        defer { AgentHookInstaller.home = saved }
        try write(".claude/projects/.keep", [])
        try write(".codex/sessions/.keep", [])
        let theirs: JSONValue = ["matcher": "*", "hooks": [["type": "command", "command": "other-tool"]]]
        try write(".claude/settings.json", [["hooks": ["PermissionRequest": [theirs]],
                                             "statusLine": ["type": "command", "command": "echo hi", "padding": 0], "model": "opus"]])

        let changed = try AgentHookInstaller.install()
        #expect(changed.count == 2)
        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(".claude/settings.json")))
        #expect(settings["model"] == "opus")
        let permission = try #require(settings["hooks"]?["PermissionRequest"]?.array)
        #expect(permission.count == 2 && permission.first == theirs)
        #expect(permission.last?["hooks"]?.array?.first?["command"]?.string?.hasSuffix("xtermx-hook") == true)
        #expect(settings["statusLine"]?["command"]?.string?.contains("xtermx-hook statusline ") == true)
        #expect(try String(contentsOf: AgentHookInstaller.ownStatusLineFile(folder: root.appendingPathComponent(".claude").path),
                           encoding: .utf8) == "echo hi\n")
        #expect(settings["statusLine"]?["padding"] == 0)
        let codex = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(".codex/hooks.json")))
        #expect(Set(codex["hooks"]?.object?.keys.map { $0 } ?? []) == ["SessionStart", "SessionEnd", "PermissionRequest", "SubagentStart", "SubagentStop"])
        #expect(AgentHookInstaller.isInstalled)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".claude").path)
            .filter { $0.hasPrefix("settings.json.xtermx-backup-") }
        #expect(backups.count == 1)

        #expect(try AgentHookInstaller.install().isEmpty) // idempotent

        try AgentHookInstaller.uninstall()
        let restored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(".claude/settings.json")))
        #expect(restored["hooks"]?["PermissionRequest"]?.array == [theirs])
        #expect(restored["statusLine"]?["command"] == "echo hi")
        #expect(!AgentHookInstaller.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: AgentHookInstaller.ownStatusLineFile(folder: root.appendingPathComponent(".claude").path).path))

        // A settings file that is not plain JSON is never overwritten.
        let broken = "{ \"model\": \"opus\", // a comment\n}"
        try broken.write(to: root.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        #expect(throws: AgentHookInstaller.Failure.self) { try AgentHookInstaller.install() }
        #expect(try String(contentsOf: root.appendingPathComponent(".claude/settings.json"), encoding: .utf8) == broken)
    }
    @Test func statusLineCanBeDisabledWithoutRemovingLifecycleHooks() throws {
        let saved = AgentHookInstaller.home
        AgentHookInstaller.home = root.path
        defer { AgentHookInstaller.home = saved }
        try write(".claude/projects/.keep", [])
        let original: JSONValue = ["type": "command", "command": "echo my-status", "padding": 2]
        try write(".claude/settings.json", [["statusLine": original, "model": "test-model"]])
        _ = try AgentHookInstaller.install(manageStatusLine: false)
        let file = root.appendingPathComponent(".claude/settings.json")
        func config() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)) }
        let first = try config()
        #expect(first["statusLine"] == original)
        #expect(AgentHookInstaller.isInstalled)
        #expect(!AgentHookInstaller.isStatusLineManaged)
        _ = try AgentHookInstaller.setStatusLineManaged(true)
        #expect(AgentHookInstaller.isStatusLineManaged)
        #expect(try config()["hooks"] == first["hooks"])
        #expect(try AgentHookInstaller.setStatusLineManaged(true).isEmpty)
        _ = try AgentHookInstaller.setStatusLineManaged(false)
        #expect(try config()["statusLine"] == original)
        #expect(try config()["hooks"] == first["hooks"])
        #expect(AgentHookInstaller.isInstalled)
        #expect(!AgentHookInstaller.isStatusLineManaged)
    }

    @Test func disablingStatusLineNeverOverwritesANewerUserCommand() throws {
        let saved = AgentHookInstaller.home
        AgentHookInstaller.home = root.path
        defer { AgentHookInstaller.home = saved }
        try write(".claude/projects/.keep", [])
        try write(".claude/settings.json", [["statusLine": ["type": "command", "command": "echo before"]]])
        _ = try AgentHookInstaller.install()
        let file = root.appendingPathComponent(".claude/settings.json")
        var config = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        config["statusLine"] = ["type": "command", "command": "echo changed-by-owner"]
        try JSONSerialization.data(withJSONObject: config).write(to: file)
        let before = try Data(contentsOf: file)
        #expect(try AgentHookInstaller.setStatusLineManaged(false).isEmpty)
        #expect(try Data(contentsOf: file) == before)
        _ = try AgentHookInstaller.setStatusLineManaged(true)
        _ = try AgentHookInstaller.setStatusLineManaged(false)
        let restored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        #expect(restored["statusLine"]?["command"] == "echo changed-by-owner")
    }

    @Test func geminiHooksTrackLifecycleWithoutInventingUsageOrDecisions() async throws {
        let manager = PaneManager(detectAgents: false)
        let tracker = AgentSessionTracker(manager: manager)
        let hooks = AgentHooks(manager: manager, sessions: tracker)
        let pane = manager.spawn(.init(kind: .shell, cwd: root.path))
        defer { manager.close(pane.id) }
        let transcript = root.appendingPathComponent(".gemini/tmp/project/chats/session-test.json").path
        let base: [String: JSONValue] = ["session_id": "gemini-session", "transcript_path": .string(transcript), "cwd": .string(root.path)]
        func event(_ name: String, extra: [String: JSONValue] = [:]) async {
            var value = base.merging(extra) { _, new in new }
            value["hook_event_name"] = .string(name)
            #expect(await hooks.handle(event: "gemini", payload: .object(value), caller: pane.id) == nil)
        }
        await event("SessionStart")
        for _ in 0..<30 where manager.pane(pane.id)?.agentSession == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tracker.session(paneID: pane.id)?.tool == .gemini)
        await event("BeforeAgent")
        #expect(manager.pane(pane.id)?.agentSession?.status == .working)
        await event("Notification", extra: ["notification_type": "ToolPermission"])
        #expect(manager.pane(pane.id)?.agentSession?.status == .waiting)
        #expect(manager.approvals.isEmpty)
        await event("AfterTool")
        #expect(manager.pane(pane.id)?.agentSession?.status == .working)
        await event("AfterAgent")
        #expect(manager.pane(pane.id)?.agentSession?.status == .idle)
        #expect(manager.pane(pane.id)?.agentSession?.tokens.total == 0)
        await event("SessionEnd")
        #expect(tracker.session(paneID: pane.id) == nil)
    }

    @Test func geminiInstallerPreservesUserHooksAndUsesMillisecondTimeouts() throws {
        let saved = AgentHookInstaller.home
        AgentHookInstaller.home = root.path
        defer { AgentHookInstaller.home = saved }
        let theirs: JSONValue = ["hooks": [["type": "command", "command": "echo user-hook"]]]
        try write(".gemini/settings.json", [["hooks": ["BeforeAgent": [theirs]], "theme": "mine"]])
        _ = try AgentHookInstaller.install(manageStatusLine: false)
        let file = root.appendingPathComponent(".gemini/settings.json")
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        let entries = try #require(config["hooks"]?["BeforeAgent"]?.array)
        #expect(entries.count == 2 && entries.first == theirs)
        #expect(entries.last?["hooks"]?.array?.first?["timeout"] == 3000)
        #expect(entries.last?["hooks"]?.array?.first?["command"]?.string?.hasSuffix(" gemini") == true)
        #expect(AgentHookInstaller.targets().first?.tool == .gemini)
        #expect(try AgentHookInstaller.install(manageStatusLine: false).isEmpty)
        _ = try AgentHookInstaller.uninstall()
        let restored = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        #expect(restored["hooks"]?["BeforeAgent"]?.array == [theirs])
        #expect(restored["theme"] == "mine")
    }

}
#endif
