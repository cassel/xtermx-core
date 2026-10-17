#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

/// Notices: which pane changes become "done" / "needs you", their words, and the Telegram and Slack requests.
@Suite struct AgentNoticesTests {
    let home = NSHomeDirectory()

    func pane(_ status: AgentSessionStatus?, state: PaneState = .idle, title: String = "api",
              waitingFor: String? = nil, task: String? = nil) -> PaneInfo {
        var p = PaneInfo(id: "p1", title: title, kind: .agent, agentID: "claude-code", cwd: home + "/app/web", state: state)
        if let status {
            p.agentSession = AgentSessionInfo(tool: .claude, sessionID: "s", account: "~/.claude", status: status,
                                              waitingFor: waitingFor, title: task)
        }
        return p
    }

    @Test func finishedOnlyAfterTenSecondsOfWork() {
        var w = AgentNoticeWatcher()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(w.paneUpdated(pane(.working), now: t0).isEmpty)
        // A short turn says nothing.
        #expect(w.paneUpdated(pane(.idle), now: t0.addingTimeInterval(4)).isEmpty)

        #expect(w.paneUpdated(pane(.working), now: t0.addingTimeInterval(10)).isEmpty)
        #expect(w.paneUpdated(pane(.shell), now: t0.addingTimeInterval(20)).isEmpty)
        let done = w.paneUpdated(pane(.idle, task: "Fix the login form"), now: t0.addingTimeInterval(200))
        #expect(done.count == 1)
        #expect(done.first?.event == .finished)
        #expect(done.first?.paneID == "p1")
        #expect(done.first?.title == "Claude Code is done")
        #expect(done.first?.body == "Fix the login form\napi · ~/app/web · worked 3 min")
        // Told once: staying idle says nothing more.
        #expect(w.paneUpdated(pane(.idle), now: t0.addingTimeInterval(300)).isEmpty)
    }

    @Test func endedCountsAsFinishedAndAWaitKeepsTheWork() {
        var w = AgentNoticeWatcher()
        let t0 = Date(timeIntervalSince1970: 0)
        _ = w.paneUpdated(pane(.working), now: t0)
        _ = w.paneUpdated(pane(.waiting, state: .blocked), now: t0.addingTimeInterval(5))
        _ = w.paneUpdated(pane(.working), now: t0.addingTimeInterval(8))
        #expect(w.paneUpdated(pane(.ended), now: t0.addingTimeInterval(12)).map(\.event) == [.finished])
        // A pane that closes mid-work is forgotten, not "done".
        _ = w.paneUpdated(pane(.working), now: t0.addingTimeInterval(20))
        var gone = pane(.working)
        gone.state = .exited
        #expect(w.paneUpdated(gone, now: t0.addingTimeInterval(60)).isEmpty)
        #expect(w.paneUpdated(pane(.idle), now: t0.addingTimeInterval(61)).isEmpty)
    }

    @Test func blockedPaneIsHeldThenToldOnce() {
        var w = AgentNoticeWatcher(grace: 1.5)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(w.paneUpdated(pane(.waiting, state: .blocked, waitingFor: "permission"), now: t0).isEmpty)
        #expect(w.due(now: t0.addingTimeInterval(1)).isEmpty)
        #expect(w.nextDue == t0.addingTimeInterval(1.5))
        let told = w.due(now: t0.addingTimeInterval(2))
        #expect(told.map(\.title) == ["Claude Code needs you"])
        #expect(told.first?.body == "permission\napi · ~/app/web")
        // Same wait: nothing new.
        #expect(w.paneUpdated(pane(.waiting, state: .blocked), now: t0.addingTimeInterval(3)).isEmpty)
        #expect(w.due(now: t0.addingTimeInterval(9)).isEmpty)
        // Answered, then asks again: a new notice.
        _ = w.paneUpdated(pane(.working, state: .working), now: t0.addingTimeInterval(10))
        _ = w.paneUpdated(pane(.waiting, state: .blocked), now: t0.addingTimeInterval(11))
        #expect(w.due(now: t0.addingTimeInterval(13)).count == 1)
    }

    @Test func shellPromptAndNeedsYouFlagCount() {
        var w = AgentNoticeWatcher(grace: 0)
        var shell = PaneInfo(id: "sh", title: "deploy", kind: .shell, cwd: home, state: .blocked, lastLine: "Continue? [y/N]")
        _ = w.paneUpdated(shell)
        let told = w.due(now: .distantFuture)
        #expect(told.first?.title == "deploy needs you")
        #expect(told.first?.body == "Continue? [y/N]\ndeploy · ~")

        shell.id = "other"
        shell.state = .idle
        shell.needsYou = true
        shell.summary = "Waiting for you to pick a database"
        shell.summaryAt = .now
        _ = w.paneUpdated(shell)
        #expect(w.due(now: .distantFuture).first?.body.hasPrefix("Waiting for you to pick a database") == true)
    }

    @Test func approvalCardReplacesTheHeldNotice() {
        var w = AgentNoticeWatcher()
        let p = pane(.waiting, state: .blocked, waitingFor: "permission")
        _ = w.paneUpdated(p, now: Date(timeIntervalSince1970: 0))
        let card = ApprovalRequest(paneID: "p1", title: "api: Bash", detail: "npm run build\nand more", kind: .permission,
                                   agentTool: .claude)
        let told = w.approvalsChanged([card], pane: { $0 == "p1" ? p : nil })
        #expect(told.count == 1)
        #expect(told.first?.title == "Claude Code needs you")
        #expect(told.first?.body == "Wants to run Bash\nnpm run build\napi · ~/app/web")
        #expect(w.due(now: .distantFuture).isEmpty)
        // The same card again is not news; a new one is.
        #expect(w.approvalsChanged([card], pane: { _ in p }).isEmpty)
        let question = ApprovalRequest(paneID: "p1", title: "Claude Code asks", detail: "api", kind: .question, agentTool: .claude,
                                       options: [], questions: [ApprovalQuestion(question: "Which database?", options: ["Postgres", "SQLite"])])
        #expect(w.approvalsChanged([card, question], pane: { _ in p }).first?.body == "Which database?\napi · ~/app/web")
    }

    @Test func cardWithoutPaneStillNotifies() {
        var w = AgentNoticeWatcher()
        let card = ApprovalRequest(paneID: nil, title: "Open a Codex pane?", detail: "in ~/app")
        let told = w.approvalsChanged([card], pane: { _ in nil })
        #expect(told.first?.title == "An agent needs you")
        #expect(told.first?.body == "Open a Codex pane?")
    }

    @Test func wordsForPlacesAndDurations() {
        #expect(AgentNoticeText.duration(8) == "8 s")
        #expect(AgentNoticeText.duration(61) == "1 min")
        #expect(AgentNoticeText.duration(3600) == "1 h")
        #expect(AgentNoticeText.duration(3900) == "1 h 5 min")
        #expect(AgentNoticeText.place(pane(nil, title: "web")) == "~/app/web")
        #expect(AgentNoticeText.clip(5)("abcdefgh\nsecond") == "abcd…")
        let limit = AgentNoticeText.planLimit(.codex, percent: 92, detail: "Weekly limit · resets in 2 days")
        #expect(limit.text == "Codex plan at 92%\nWeekly limit · resets in 2 days")
    }

    // MARK: Telegram

    @Test func telegramTokenShape() {
        #expect(TelegramBot(token: "123456:ABCdefGhIJKlmNoPQRsTUVwxyZ-_12") != nil)
        #expect(TelegramBot(token: "  123456:ABCdefGhIJKlmNoPQRsTUVwxyZ-_12\n")?.token == "123456:ABCdefGhIJKlmNoPQRsTUVwxyZ-_12")
        #expect(TelegramBot(token: "abc:ABCdefGhIJKlmNoPQRsTUVwxyZ") == nil)
        #expect(TelegramBot(token: "123456:short") == nil)
        #expect(TelegramBot(token: "123456:ABCdefGhIJKlmNoPQRsTUV/../x") == nil)
        #expect(TelegramBot(token: "123456ABCdefGhIJKlmNoPQRsTUVwxyZ") == nil)
    }

    @Test func telegramRequests() throws {
        let bot = try #require(TelegramBot(token: "42:AAAAAAAAAAAAAAAAAAAAAAAA"))
        #expect(bot.getUpdates().url?.absoluteString == "https://api.telegram.org/bot42:AAAAAAAAAAAAAAAAAAAAAAAA/getUpdates")
        #expect(bot.getMe().httpMethod == "GET")
        let send = bot.sendMessage(chatID: -100123, text: "Claude Code is done\napi")
        #expect(send.httpMethod == "POST")
        #expect(send.url?.lastPathComponent == "sendMessage")
        #expect(send.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(send.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["chat_id"] as? Int64 == -100123)
        #expect(body["text"] as? String == "Claude Code is done\napi")
        let long = bot.sendMessage(chatID: 1, text: String(repeating: "x", count: 5000))
        let longBody = try #require(long.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((longBody["text"] as? String)?.count == 4000)
    }

    @Test func telegramFindsChatsInUpdates() throws {
        let json = """
        {"ok":true,"result":[
          {"update_id":1,"message":{"message_id":1,"chat":{"id":555,"type":"private","first_name":"Ana","last_name":"Lima"},"text":"hi"}},
          {"update_id":2,"my_chat_member":{"chat":{"id":-1001,"type":"group","title":"Builds"}}},
          {"update_id":3,"message":{"message_id":2,"chat":{"id":555,"type":"private","first_name":"Ana","last_name":"Lima"},"text":"again"}},
          {"update_id":4,"callback_query":{"id":"x"}}
        ]}
        """
        let chats = try TelegramBot.chats(Data(json.utf8))
        #expect(chats == [TelegramBot.Chat(id: -1001, name: "Builds"), TelegramBot.Chat(id: 555, name: "Ana Lima")])
        #expect(throws: NoticeChannelError.noMessages) { try TelegramBot.chats(Data(#"{"ok":true,"result":[]}"#.utf8)) }
        #expect(throws: NoticeChannelError.rejected("Telegram: Conflict: can't use getUpdates method while webhook is active")) {
            try TelegramBot.chats(Data(#"{"ok":false,"error_code":409,"description":"Conflict: can't use getUpdates method while webhook is active"}"#.utf8))
        }
    }

    @Test func telegramBotNameAndSendReply() throws {
        #expect(try TelegramBot.botName(Data(#"{"ok":true,"result":{"id":1,"is_bot":true,"first_name":"Builds","username":"my_builds_bot"}}"#.utf8)) == "@my_builds_bot")
        try TelegramBot.checkSent(Data(#"{"ok":true,"result":{"message_id":3}}"#.utf8))
        #expect(throws: NoticeChannelError.self) { try TelegramBot.checkSent(Data("<html>".utf8)) }
    }

    // MARK: Slack

    @Test func slackWebhookAddress() {
        #expect(SlackWebhook("https://hooks.slack.com/services/T000/B000/XXXX") != nil)
        #expect(SlackWebhook("http://hooks.slack.com/services/T000/B000/XXXX") == nil)
        #expect(SlackWebhook("https://example.com/services/T000") == nil)
        #expect(SlackWebhook("https://hooks.slack.com/") == nil)
        #expect(SlackWebhook("not a url") == nil)
    }

    @Test func slackRequestEscapesMarkup() throws {
        let hook = try #require(SlackWebhook("https://hooks.slack.com/services/T/B/X"))
        let notice = AgentNotice(event: .needsYou, paneID: "p", title: "Codex needs you", body: "Wants to run Bash\nls <dir> && echo")
        let r = hook.post(notice)
        #expect(r.httpMethod == "POST")
        #expect(r.url == hook.url)
        let body = try #require(r.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["text"] as? String == "*Codex needs you*\nWants to run Bash\nls &lt;dir&gt; &amp;&amp; echo")
    }

    @Test func errorWordsNeverCarryTheAddress() {
        #expect(NoticeDelivery.reason(Data("invalid_token".utf8), status: 403).contains("Make a new one"))
        #expect(NoticeDelivery.reason(Data(#"{"ok":false,"description":"Unauthorized"}"#.utf8), status: 401) == "Telegram: Unauthorized")
        #expect(NoticeDelivery.reason(Data("<html>bad</html>".utf8), status: 502) == "The server answered 502.")
        let offline = URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://api.telegram.org/bot42:SECRET/getMe"])
        #expect(!NoticeDelivery.describe(offline).contains("SECRET"))
        #expect(NoticeDelivery.describe(offline) == "This Mac is offline.")
    }
}
#endif
