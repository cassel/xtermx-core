import Testing
@testable import XTermXKit

@Suite struct PaneActivitySummaryTests {
    @Test func attentionTakesPriorityAndEndedPanesDoNotCountAsLive() {
        let working = PaneInfo(id: "w", title: "build", kind: .shell, cwd: "/tmp", state: .working)
        var waiting = working; waiting.id = "q"; waiting.needsYou = true
        var idle = working; idle.id = "i"; idle.state = .idle
        var ended = waiting; ended.id = "e"; ended.state = .exited
        let result = PaneActivitySummary(panes: [working, waiting, idle, ended, working])
        #expect(result.working == 1)
        #expect(result.waiting == 1)
        #expect(result.idle == 1)
        #expect(result.ended == 1)
        #expect(result.live == 3)
        #expect(PaneActivitySummary.state(of: waiting) == .blocked)
        #expect(PaneActivitySummary.state(of: ended) == .exited)
    }
    @Test func agentQuestionCountsEvenWhenTheTerminalIsQuietAndEmptyIsZero() {
        var pane = PaneInfo(title: "agent", kind: .agent, cwd: "/tmp")
        pane.agentSession = AgentSessionInfo(tool: .codex, sessionID: "s", account: "test", status: .waiting)
        #expect(PaneActivitySummary(panes: [pane]).waiting == 1)
        #expect(PaneActivitySummary(panes: []).live == 0)
    }
}
