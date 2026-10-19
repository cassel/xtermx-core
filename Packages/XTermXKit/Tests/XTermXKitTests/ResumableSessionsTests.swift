import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

@Suite struct ResumableSessionsTests {
    private func write(_ lines: [[String: Any]], to url: URL, modified: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test func listsClaudeAndCodexConversationsForOneFolderNewestFirst() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("resumable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = "/Users/me/Projects/my.app"
        let claude = home.appendingPathComponent(".claude/projects/-Users-me-Projects-my-app")
        #expect(ResumableSessions.claudeDirectoryName(folder) == "-Users-me-Projects-my-app")
        try write([
            ["type": "attachment", "cwd": folder],
            ["type": "user", "cwd": folder, "isMeta": true, "message": ["content": "Base directory for this skill"]],
            ["type": "user", "cwd": folder, "message": ["content": "<command-name>/clear</command-name>"]],
            ["type": "user", "cwd": folder, "message": ["content": "Fix the\nlogin   form"]],
        ], to: claude.appendingPathComponent("aaa-111.jsonl"), modified: Date(timeIntervalSince1970: 3000))
        try write([
            ["type": "ai-title", "aiTitle": "Named by the agent"],
            ["type": "user", "cwd": folder, "message": ["content": [["type": "tool_result", "content": "x"]]]],
        ], to: claude.appendingPathComponent("bbb-222.jsonl"), modified: Date(timeIntervalSince1970: 1000))
        // Same encoded directory, different real folder (`my-app` vs `my.app`).
        try write([["type": "user", "cwd": "/Users/me/Projects/my-app", "message": ["content": "elsewhere"]]],
                  to: claude.appendingPathComponent("ccc-333.jsonl"), modified: Date(timeIntervalSince1970: 4000))

        let codex = home.appendingPathComponent(".codex/sessions/2026/10/19")
        try write([
            ["type": "session_meta", "payload": ["id": "019a-codex", "cwd": folder, "source": "cli"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "# AGENTS.md instructions for /"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Add dark mode"]]]],
        ], to: codex.appendingPathComponent("rollout-1.jsonl"), modified: Date(timeIntervalSince1970: 2000))
        try write([
            ["type": "session_meta", "payload": ["id": "019a-helper", "cwd": folder, "source": ["subagent": ["other": "guardian"]]]],
            ["type": "response_item", "payload": ["role": "user", "content": [["text": "review"]]]],
        ], to: codex.appendingPathComponent("rollout-2.jsonl"), modified: Date(timeIntervalSince1970: 5000))
        try write([
            ["type": "session_meta", "payload": ["id": "019a-other", "cwd": "/tmp"]],
            ["type": "response_item", "payload": ["role": "user", "content": [["text": "other folder"]]]],
        ], to: codex.appendingPathComponent("rollout-3.jsonl"), modified: Date(timeIntervalSince1970: 6000))

        let sessions = ResumableSessions.list(cwd: folder + "/", home: home.path)
        #expect(sessions.map(\.id) == ["claude-code:aaa-111", "codex:019a-codex", "claude-code:bbb-222"])
        #expect(sessions.map(\.title) == ["Fix the login form", "Add dark mode", "Named by the agent"])
        #expect(ResumableSessions.list(cwd: "/nowhere", home: home.path).isEmpty)
    }

    @Test func resumeArgumentsAreLimitedToSafeIdsAndKnownAgents() {
        #expect(AgentCatalog.resumeArguments(agentID: "claude-code", session: "aaa-111") == ["--resume", "aaa-111"])
        #expect(AgentCatalog.resumeArguments(agentID: "codex", session: "") == ["resume"])
        #expect(AgentCatalog.resumeArguments(agentID: "codex", session: "x; rm -rf ~") == nil)
        #expect(AgentCatalog.resumeArguments(agentID: "aider", session: "") == nil)
        #expect(AgentCatalog.canResume("openclaude") && !AgentCatalog.canResume("gemini"))
    }

    @Test func paneShellsComeFromTheSystemList() {
        let listing = "# comment\n/bin/zsh\n/bin/bash\n/bin/tcsh\n/bin/zsh\n/no/such/shell\n"
        #expect(PaneManager.availableShells(listing: listing) == ["/bin/zsh", "/bin/bash"])
    }

    @Test func olderSpawnRequestsStillDecode() throws {
        let old = #"{"kind":"agent","agentID":"codex","bypass":false}"#
        let request = try JSONDecoder().decode(SpawnRequest.self, from: Data(old.utf8))
        #expect(request.resume == nil && request.shell == nil && request.isolate == nil)
    }
}
