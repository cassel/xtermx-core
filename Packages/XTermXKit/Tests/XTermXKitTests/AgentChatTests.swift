#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

/// The pane chat view's logic: following the transcript, the message typed into the pane,
/// how answers are cut for drawing, and which panes show the chat.
@Suite struct AgentChatTests {
    @Test func followerReadsOnlyWhenTheFileGrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xtx-chat-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var follower = AgentChatFollower(path: url.path, tool: .claude)
        #expect(follower.poll() == nil) // not there yet

        let first = #"{"type":"user","message":{"role":"user","content":"Fix the build"}}"# + "\n"
        try first.write(to: url, atomically: true, encoding: .utf8)
        #expect(follower.poll()?.map(\.text) == ["Fix the build"])
        #expect(follower.poll() == nil) // same size

        let answer = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"# + "\n"
        try (first + answer).write(to: url, atomically: true, encoding: .utf8)
        #expect(follower.poll()?.map(\.kind) == [.user, .assistant])
    }

    @Test func payloadTrimsAndPastesSeveralLinesAsOne() {
        #expect(AgentChatInput.payload("  \n ") == nil)
        #expect(AgentChatInput.payload(" run the tests \n") == "run the tests")
        #expect(AgentChatInput.payload("one\ntwo") == "\u{1b}[200~one\ntwo\u{1b}[201~")
        // An escape typed in can't end the paste early.
        #expect(AgentChatInput.payload("a\n\u{1b}[201~b") == "\u{1b}[200~a\n[201~b\u{1b}[201~")
    }

    @Test func markdownBlocks() {
        let text = """
        ## Plan
        Change **two** files:
        - `MacApp.swift`
          * nested

        ```swift
        let x = 1
        ```
        #not a heading
        """
        #expect(AgentChatMarkdown.blocks(text) == [
            .heading("Plan"),
            .text("Change **two** files:\n• `MacApp.swift`\n  • nested"),
            .code("let x = 1"),
            .text("#not a heading"),
        ])
        // A fence the agent is still writing shows as code.
        #expect(AgentChatMarkdown.blocks("Here:\n```\nmake") == [.text("Here:"), .code("make")])
    }

    @Test func turnsGroupTheAgentsWorkUnderEachMessage() {
        func e(_ id: String, _ kind: AgentChatEntry.Kind) -> AgentChatEntry { AgentChatEntry(id: id, kind: kind, text: id) }
        let turns = AgentChatTurn.group([
            e("t0", .tool), e("a0", .assistant),
            e("u1", .user), e("t1", .tool), e("a1", .assistant), e("t2", .tool), e("a2", .assistant),
            e("c2", .command),
            e("u3", .user),
        ])
        #expect(turns.map(\.id) == ["before-t0", "u1", "c2", "u3"])
        #expect(turns[0].prompt == nil)
        #expect(turns[0].tools.map(\.id) == ["t0"])
        #expect(turns[1].tools.map(\.id) == ["t1", "t2"])
        #expect(turns[1].answers.map(\.id) == ["a1", "a2"])
        #expect(turns[2].prompt?.kind == .command)
        #expect(turns[3].tools.isEmpty && turns[3].answers.isEmpty)
        #expect(AgentChatTurn.group([]).isEmpty)
    }

    @Test func choicesFollowTheDefaultUntilAPaneIsToggled() {
        var choices = AgentChatChoices()
        #expect(!choices.showsChat("a", hasSession: true, byDefault: false))
        #expect(choices.showsChat("a", hasSession: true, byDefault: true))
        #expect(!choices.showsChat("a", hasSession: false, byDefault: true)) // no session: the terminal

        choices.toggle("a", byDefault: true)
        #expect(!choices.showsChat("a", hasSession: true, byDefault: true))
        #expect(choices.showsChat("b", hasSession: true, byDefault: true))
        choices.toggle("a", byDefault: true)
        #expect(choices.showsChat("a", hasSession: true, byDefault: false))
        choices.forget("a")
        #expect(!choices.showsChat("a", hasSession: true, byDefault: false))
    }
}
#endif
