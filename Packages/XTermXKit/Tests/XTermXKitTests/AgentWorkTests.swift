#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

/// What agents do, from their files: tool calls in words, shells, tasks, sessions outside the
/// panes, agent time per day, and the counts and feed built from them.
@MainActor
@Suite(.serialized) struct AgentWorkTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xtx-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ lines: [JSONValue]) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func stamp(_ secondsAgo: Double) -> JSONValue {
        .string(ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-secondsAgo)))
    }

    static func toolUse(_ id: String, _ name: String, _ input: [String: JSONValue], at secondsAgo: Double,
                        cwd: String = "/tmp/demo") -> JSONValue {
        ["type": "assistant", "timestamp": stamp(secondsAgo), "cwd": .string(cwd),
         "message": ["id": .string("m-\(id)"), "content": [["type": "tool_use", "id": .string(id), "name": .string(name), "input": .object(input)]]]]
    }

    static func toolResult(_ id: String, at secondsAgo: Double, backgroundTask: String? = nil, error: Bool = false) -> JSONValue {
        var line: [String: JSONValue] = ["type": "user", "timestamp": stamp(secondsAgo),
                                         "message": ["content": [["type": "tool_result", "tool_use_id": .string(id), "is_error": .bool(error)]]]]
        if let backgroundTask { line["toolUseResult"] = ["backgroundTaskId": .string(backgroundTask)] }
        return .object(line)
    }

    @Test func claudeToolCallsShellsAndTasks() async throws {
        let transcript = ".claude/projects/-tmp-demo/W1.jsonl"
        try write(transcript, [
            Self.toolUse("t1", "Edit", ["file_path": "/tmp/demo/Models.swift"], at: 120),
            // A quick foreground command: never shown as a shell.
            Self.toolUse("t2", "Bash", ["command": "ls", "description": "List files"], at: 110),
            Self.toolResult("t2", at: 109.5),
            // A background build that failed, and a dev server still running.
            Self.toolUse("t3", "Bash", ["command": "swift build", "description": "Build the package", "run_in_background": true], at: 100),
            Self.toolResult("t3", at: 99, backgroundTask: "b1"),
            Self.toolUse("t4", "Bash", ["command": "npm run dev", "run_in_background": true], at: 90),
            Self.toolResult("t4", at: 89, backgroundTask: "b2"),
            ["type": "user", "timestamp": Self.stamp(10), "message": ["content": .string(
                "<task-notification>\n<task-id>b1</task-id>\n<tool-use-id>t3</tool-use-id>\n<status>failed</status>\n</task-notification>")]],
            Self.toolUse("t5", "TodoWrite", ["todos": [
                ["content": "Read the code", "status": "completed"],
                ["content": "Write the tests", "status": "in_progress"],
                ["content": "Ship it", "status": "pending"],
            ]], at: 5),
            Self.toolUse("t6", "mcp__plugin_ecc_github__create_pull_request", [:], at: 4),
        ])
        let reader = AgentTranscriptReader()
        let reg = AgentSessionTracker.Registration(paneID: "p", tool: .claude, sessionID: "W1",
                                                   transcriptPath: root.appendingPathComponent(transcript).path)
        let info = try #require(await reader.poll([reg]).first).info

        #expect(info.cwd == "/tmp/demo")
        #expect(info.activity.map(\.text) == ["Editing Models.swift", "List files", "Build the package", "$ npm run dev",
                                              "Updating tasks", "ecc github: create pull request"])
        #expect(info.shells.map(\.label) == ["Build the package", "npm run dev"])
        #expect(info.shells.first?.outcome == .failed)
        #expect(info.runningShells.map(\.id) == ["t4"])
        #expect(info.tasks.map(\.status) == [.completed, .inProgress, .pending])
        #expect(info.tasks.map(\.title) == ["Read the code", "Write the tests", "Ship it"])
    }

    @Test func codexToolCallsAndPlan() async throws {
        let rollout = ".codex/sessions/2026/10/15/rollout-2026-10-15T10-00-00-T1.jsonl"
        try write(rollout, [
            ["type": "session_meta", "timestamp": Self.stamp(60), "payload": ["id": "T1", "cwd": "/tmp/codex"]],
            ["type": "event_msg", "timestamp": Self.stamp(59), "payload": ["type": "task_started"]],
            ["type": "response_item", "timestamp": Self.stamp(58), "payload": [
                "type": "function_call", "name": "exec_command", "call_id": "c1",
                "arguments": .string(#"{"cmd": "cargo test --all"}"#)]],
            ["type": "response_item", "timestamp": Self.stamp(50), "payload": [
                "type": "function_call", "name": "update_plan", "call_id": "c2",
                "arguments": .string(#"{"plan": [{"step": "Fix parser", "status": "completed"}, {"step": "Add test", "status": "in_progress"}]}"#)]],
            ["type": "response_item", "timestamp": Self.stamp(40), "payload": [
                "type": "custom_tool_call", "name": "apply_patch", "call_id": "c3",
                "input": "*** Begin Patch\n*** Update File: src/lib.rs\n*** Update File: src/main.rs\n*** End Patch"]],
        ])
        let reader = AgentTranscriptReader()
        let reg = AgentSessionTracker.Registration(paneID: "p", tool: .codex, sessionID: "T1",
                                                   transcriptPath: root.appendingPathComponent(rollout).path)
        let info = try #require(await reader.poll([reg]).first).info
        #expect(info.cwd == "/tmp/codex")
        #expect(info.activity.map(\.text) == ["$ cargo test --all", "Updating the plan", "Editing lib.rs and 1 more"])
        #expect(info.runningShells.map(\.label) == ["cargo test --all"])
        #expect(info.tasks.map(\.title) == ["Fix parser", "Add test"])
        #expect(info.tasks.map(\.status) == [.completed, .inProgress])
    }

    @Test func findsSessionsOutsideThePanes() async throws {
        let claude = root.appendingPathComponent(".claude").path
        let codex = root.appendingPathComponent(".codex").path
        // A live Claude Code session (this test's own pid) and one whose process is gone.
        try write(".claude/sessions/\(getpid()).json", [["pid": .number(Double(getpid())), "sessionId": "E1", "cwd": "/tmp/elsewhere",
                                                         "status": "busy", "name": "elsewhere-1", "startedAt": .number(1_792_000_000_000)]])
        try write(".claude/sessions/999999.json", [["pid": 999_999, "sessionId": "DEAD", "cwd": "/tmp/x", "status": "idle"]])
        try write(".claude/projects/-tmp-elsewhere/E1.jsonl", [Self.toolUse("e1", "Grep", ["pattern": "TODO"], at: 3, cwd: "/tmp/elsewhere")])
        // A pane's own session: left to the panes.
        try write(".claude/sessions/\(getppid()).json", [["pid": .number(Double(getppid())), "sessionId": "PANE", "status": "idle"]])

        // An open Codex thread, and a subagent thread of it.
        let day = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        let dir = String(format: ".codex/sessions/%04d/%02d/%02d", day.year!, day.month!, day.day!)
        try write("\(dir)/rollout-x-C1.jsonl", [["type": "session_meta", "payload": ["id": "C1", "cwd": "/tmp/c"]],
                                               ["type": "event_msg", "payload": ["type": "task_started"]]])
        try write("\(dir)/rollout-x-C2.jsonl", [["type": "session_meta", "payload": ["id": "C2", "parent_thread_id": "C1"]]])
        for id in ["C1", "C2"] {
            try write(".codex/thread-writer-locks/\(id).lock", [])
        }

        let reader = AgentTranscriptReader()
        let found = await reader.pollMachine(excluding: ["PANE"], folders: ([claude], [codex]))
        let byID = Dictionary(uniqueKeysWithValues: found.sessions.map { ($0.sessionID, $0) })
        #expect(Set(byID.keys) == ["E1", "C1"])
        let e1 = try #require(byID["E1"])
        #expect(e1.status == .working)
        #expect(e1.title == "elsewhere-1")
        #expect(e1.cwd == "/tmp/elsewhere")
        #expect(e1.activity.map(\.text) == ["Searching for “TODO”"])
        #expect(byID["C1"]?.status == .working)
        #expect(byID["C1"]?.cwd == "/tmp/c")

        // Its registry goes away: the session ended.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".claude/sessions/\(getpid()).json"))
        let later = await reader.pollMachine(excluding: ["PANE"], folders: ([claude], [codex]), now: .now.addingTimeInterval(6))
        #expect(later.sessions.map(\.sessionID) == ["C1"])
    }

    @Test func dayStatsCountTimeTokensAndCost() throws {
        let file = root.appendingPathComponent("agent-history.json")
        let store = AgentHistoryStore(url: file)
        let start = Date.now
        var info = AgentSessionInfo(tool: .claude, sessionID: "H1", account: "~/.claude", status: .working,
                                    tokens: TokenUsage(input: 100, output: 10), costUSD: 1, startedAt: start, cwd: "/tmp/proj")
        store.observe(info, now: start)                        // first sighting: nothing counted yet
        info.tokens = TokenUsage(input: 150, output: 30)
        info.costUSD = 1.5
        store.observe(info, now: start.addingTimeInterval(2))  // 2 s working
        info.status = .waiting
        store.observe(info, now: start.addingTimeInterval(3))  // 1 s waiting
        store.observe(info, now: start.addingTimeInterval(60)) // a gap counts 5 s at most

        let day = try #require(store.days.first)
        #expect(day.day == AgentDayStats.key(start))
        #expect(day.working == 2)
        #expect(day.waiting == 6)
        #expect(day.tokens == TokenUsage(input: 50, output: 20))
        #expect(abs(day.costUSD - 0.5) < 1e-9)
        #expect(day.sessions == 1)
        #expect(day.projects == ["/tmp/proj": 2])
        #expect(store.history.first?.working == 2)
        #expect(store.history.first?.endedAt == nil)

        store.ended(sessionID: "H1", at: start.addingTimeInterval(61))
        let reloaded = AgentHistoryStore(url: file)
        #expect(reloaded.days.first?.working == 2)
        #expect(reloaded.history.first?.endedAt != nil)
        #expect(reloaded.history.first?.title == "proj")
    }

    @Test func countsAndFeedCoverPanesAndElsewhere() {
        func session(_ id: String, _ status: AgentSessionStatus, activity: [AgentActivity] = []) -> AgentSessionInfo {
            AgentSessionInfo(tool: .claude, sessionID: id, account: "~/.claude", status: status, title: id, activity: activity)
        }
        var a = PaneInfo(id: "a", title: "a", kind: .agent, cwd: "/tmp")
        a.agentSession = session("A", .working, activity: [AgentActivity(id: "1", date: .now.addingTimeInterval(-5), symbol: "pencil", text: "old")])
        var b = PaneInfo(id: "b", title: "b", kind: .agent, cwd: "/tmp")
        b.agentID = "codex"
        b.state = .blocked                                      // hooks off: the screen says it waits
        let shell = PaneInfo(id: "c", title: "zsh", kind: .shell, cwd: "/tmp")
        let other = session("E", .idle, activity: [AgentActivity(id: "2", date: .now, symbol: "terminal", text: "new")])

        let counts = AgentCounts(panes: [a, b, shell], elsewhere: [other])
        #expect(counts.total == 3)
        #expect(counts.working == 1)
        #expect(counts.waiting == 1)
        #expect(counts.idle == 1)
        #expect(counts.label == "3 agents · 1 working · 1 needs you")

        let feed = AgentFeedItem.merge(panes: [a, b], elsewhere: [other])
        #expect(feed.map(\.activity.text) == ["new", "old"])
        #expect(feed.map(\.paneID) == [nil, "a"])
    }

    @Test func processTreeFindsParents() {
        #expect(ProcessTree.parent(of: getpid()) == getppid())
        #expect(ProcessTree.parent(of: 999_999) == nil)
    }

    @Test func clientsSkipMessagesTheyDoNotKnow() throws {
        let known = try WireCoding.encoder().encode(HostMessage.pong(.now))
        let json = #"{"requestID": "AAAA", "messages": [{"fromTheFuture": {"x": 1}}, "#
            + String(decoding: known, as: UTF8.self) + "]}"
        let response = try WireCoding.decoder().decode(RPCResponse.self, from: Data(json.utf8))
        #expect(response.messages.count == 1)
    }

    /// A pane's chat view: what the person asked, what the agent said, its tools in words; no bookkeeping.
    @Test func chatFromTranscripts() throws {
        try write("claude/s.jsonl", [
            ["type": "user", "timestamp": "2026-10-16T10:00:00.000Z", "message": ["role": "user", "content": "Fix the login bug"]],
            ["type": "user", "message": ["content": "<system-reminder>internal</system-reminder>"]],
            ["type": "user", "message": ["content": "<command-name>/model</command-name><command-args>opus</command-args>"]],
            ["type": "assistant", "message": ["content": [
                ["type": "thinking", "thinking": "hmm"],
                ["type": "text", "text": "Looking at it."],
                ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/x/Login.swift"]],
            ]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "content": "file body"]]]],
            ["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": "subagent talk"]]]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Fixed."]]]],
        ])
        let claude = AgentChatTranscript.read(path: root.appendingPathComponent("claude/s.jsonl").path, tool: .claude)
        #expect(claude.map(\.kind) == [.user, .command, .assistant, .tool, .assistant])
        #expect(claude.map(\.text) == ["Fix the login bug", "/model opus", "Looking at it.", claude[3].text, "Fixed."])
        #expect(claude[3].text.contains("Login.swift"))
        #expect(claude[0].date != nil)
        #expect(Set(claude.map(\.id)).count == claude.count)

        try write("codex/rollout-x.jsonl", [
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>…"]]]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Run the tests"]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "call_id": "c1",
                                                  "arguments": "{\"cmd\":\"swift test\"}"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1", "output": "ok"]],
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "All 37 pass."]],
        ])
        let codex = AgentChatTranscript.read(path: root.appendingPathComponent("codex/rollout-x.jsonl").path, tool: .codex)
        #expect(codex.map(\.kind) == [.user, .tool, .assistant])
        #expect(codex.first?.text == "Run the tests" && codex.last?.text == "All 37 pass.")
        #expect(codex[1].text.contains("swift test"))
    }

    /// Claude Code's limits reach XTermX from sessions outside the panes, through the file its status line leaves.
    @Test func claudeLimitsFromAnySession() throws {
        let dir = root.appendingPathComponent("limits")
        let resets = Date.now.addingTimeInterval(3600).timeIntervalSince1970.rounded()
        try write("limits/claude-_Users_x__claude.json", [[
            "transcript_path": "/Users/x/.claude/projects/-Users-x-app/s1.jsonl",
            "rate_limits": ["five_hour": ["used_percentage": 42, "resets_at": .number(resets)],
                            "seven_day": ["used_percentage": 8]],
        ]])
        try write("limits/claude-no-limits.json", [["transcript_path": "/Users/x/.claude/projects/a/s.jsonl"]])
        try write("limits/other.json", [["rate_limits": [:]]])

        let found = AgentSessionTracker.claudeLimitFiles(in: dir)
        #expect(found.count == 1)
        let usage = try #require(found.first)
        #expect(usage.tool == .claude && usage.account == "/Users/x/.claude")
        #expect(usage.windows.map(\.kind) == [.fiveHour, .weekly])
        #expect(usage.windows.first?.usedPercent == 42)
        #expect(usage.windows.first?.resetsAt == Date(timeIntervalSince1970: resets))
        // A week later the file is too old to trust.
        #expect(AgentSessionTracker.claudeLimitFiles(in: dir, now: .now.addingTimeInterval(8 * 86_400)).isEmpty)
        #expect(AgentHookInstaller.limitsFile(configDir: "/Users/x/.claude").lastPathComponent == "claude-_Users_x__claude.json")
    }
}
#endif
