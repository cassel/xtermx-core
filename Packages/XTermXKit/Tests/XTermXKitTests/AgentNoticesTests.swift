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

    // MARK: Commands (E19.1)

    func shellPane(_ run: CommandRun?, kind: PaneKind = .shell) -> PaneInfo {
        var p = PaneInfo(id: "c1", title: "make", kind: kind, cwd: home + "/app/web", state: .idle)
        p.lastLine = "error: build failed"
        p.lastCommand = run
        return p
    }

    func run(_ code: Int32?, ran seconds: TimeInterval, endingAt end: Date = Date(timeIntervalSince1970: 5000)) -> CommandRun {
        CommandRun(exitCode: code, startedAt: end.addingTimeInterval(-seconds), endedAt: end)
    }

    @Test func aQuickFailureSaysNothing() {
        var w = AgentNoticeWatcher()
        #expect(w.paneUpdated(shellPane(run(1, ran: 0.2))).isEmpty)
    }

    @Test func aLongCommandThatFailsIsTold() {
        var w = AgentNoticeWatcher()
        let out = w.paneUpdated(shellPane(run(1, ran: 40)))
        #expect(out.count == 1)
        #expect(out.first?.event == .commandFailed)
        #expect(out.first?.paneID == "c1")
        #expect(out.first?.title == "make failed · exit 1")
        #expect(out.first?.body == "error: build failed\n~/app/web · ran 40 s")
        // Told once: the same run reported again says nothing; the next long one is told.
        #expect(w.paneUpdated(shellPane(run(1, ran: 40))).isEmpty)
        #expect(w.paneUpdated(shellPane(run(1, ran: 50, endingAt: Date(timeIntervalSince1970: 6000)))).count == 1)
    }

    @Test func aLongCommandThatSucceedsIsABuildFinished() {
        var w = AgentNoticeWatcher()
        let out = w.paneUpdated(shellPane(run(0, ran: 30)))
        #expect(out.map(\.event) == [.buildFinished])
        #expect(out.first?.title == "make finished")
        var fresh = AgentNoticeWatcher()
        #expect(fresh.paneUpdated(shellPane(run(0, ran: 29.9))).isEmpty)
        // No exit status in the mark: finished, not failed.
        #expect(fresh.paneUpdated(shellPane(run(nil, ran: 60, endingAt: Date(timeIntervalSince1970: 7000)))).map(\.event) == [.buildFinished])
    }

    @Test func agentPanesDontCountAsCommands() {
        var w = AgentNoticeWatcher()
        #expect(w.paneUpdated(shellPane(run(1, ran: 60), kind: .agent)).isEmpty)
    }

    @Test func aPaneWhoseShellExitsWithAnErrorIsAFailure() {
        var w = AgentNoticeWatcher()
        let now = Date(timeIntervalSince1970: 5000)
        var p = PaneInfo(id: "c2", title: "deploy", kind: .ssh, cwd: home, state: .exited,
                         createdAt: now.addingTimeInterval(-45), exitCode: 255)
        #expect(w.paneUpdated(p, now: now).first?.title == "deploy failed · exit 255")
        #expect(w.paneUpdated(p, now: now).isEmpty)
        // Closing a shell cleanly, however long it was open, isn't news.
        p.id = "c3"
        p.exitCode = 0
        #expect(w.paneUpdated(p, now: now).isEmpty)
        p.id = "c4"
        p.exitCode = 1
        p.createdAt = now.addingTimeInterval(-2)
        #expect(w.paneUpdated(p, now: now).isEmpty)
    }

    @Test func semanticPromptMarksMakeCommandRuns() {
        var marks = SemanticPromptTracker()
        let t0 = Date(timeIntervalSince1970: 100)
        // A prompt redrawn without a command in between is no run.
        #expect(marks.handle("A", now: t0) == nil)
        #expect(marks.handle("D", now: t0) == nil)
        #expect(marks.handle("C", now: t0) == nil)
        #expect(marks.handle("D;1", now: t0.addingTimeInterval(40)) == CommandRun(exitCode: 1, startedAt: t0, endedAt: t0.addingTimeInterval(40)))
        #expect(marks.handle("D;0", now: t0.addingTimeInterval(41)) == nil)
        #expect(marks.handle("C;cmdline=make", now: t0.addingTimeInterval(50)) == nil)
        #expect(marks.handle("D;0;aid=7", now: t0.addingTimeInterval(52))?.exitCode == 0)
        #expect(marks.handle("C", now: t0) == nil)
        #expect(marks.handle("D", now: t0.addingTimeInterval(1))?.exitCode == nil)
    }

    // MARK: Webhook (E19.2)

    @Test func webhookAddressAndHeader() {
        #expect(GenericWebhook("https://example.com/hook") != nil)
        #expect(GenericWebhook("http://192.168.1.4:8080/n") != nil)
        #expect(GenericWebhook("ftp://example.com") == nil)
        #expect(GenericWebhook("not a url") == nil)
        #expect(GenericWebhook("https://example.com/hook", header: "Authorization: Bearer abc")?.header?.name == "Authorization")
        #expect(GenericWebhook("https://example.com/hook", header: "Authorization: Bearer abc")?.header?.value == "Bearer abc")
        #expect(GenericWebhook("https://example.com/hook", header: "  ")?.header == nil)
        #expect(GenericWebhook("https://example.com/hook", header: "no colon") == nil)
        #expect(GenericWebhook("https://example.com/hook", header: ": value") == nil)
    }

    @Test func webhookPostsTheNoticeAsJSON() throws {
        let hook = try #require(GenericWebhook("https://example.com/hook", header: "X-Key: s3cret"))
        let notice = AgentNotice(event: .commandFailed, paneID: "p9", title: "make failed · exit 1", body: "~/app")
        let r = hook.post(notice, host: "studio", time: Date(timeIntervalSince1970: 0))
        #expect(r.httpMethod == "POST")
        #expect(r.url == hook.url)
        #expect(r.timeoutInterval == 10)
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.value(forHTTPHeaderField: "X-Key") == "s3cret")
        let body = try #require(r.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(body.keys) == ["event", "title", "body", "paneID", "host", "time"])
        #expect(body["event"] as? String == "commandFailed")
        #expect(body["title"] as? String == "make failed · exit 1")
        #expect(body["body"] as? String == "~/app")
        #expect(body["paneID"] as? String == "p9")
        #expect(body["host"] as? String == "studio")
        #expect(body["time"] as? String == "1970-01-01T00:00:00Z")
        // No pane: null, still there.
        let plan = hook.post(AgentNotice(event: .planLimit, paneID: nil, title: "t", body: ""), host: "h", time: .now)
        let planBody = try #require(plan.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(planBody["paneID"] is NSNull)
    }

    @Test func deliveryTriesOnceMore() async {
        actor Count { var n = 0; func bump() -> Int { n += 1; return n } }
        let flaky = Count()
        let data = try? await NoticeDelivery.retrying(once: true, pause: .zero) {
            if await flaky.bump() == 1 { throw NoticeChannelError.network("No answer in time. Try again.") }
            return Data("ok".utf8)
        }
        #expect(data == Data("ok".utf8))
        #expect(await flaky.n == 2)

        let broken = Count()
        await #expect(throws: NoticeChannelError.network("down")) {
            try await NoticeDelivery.retrying(once: true, pause: .zero) {
                _ = await broken.bump()
                throw NoticeChannelError.network("down")
            }
        }
        #expect(await broken.n == 2)
    }

    // MARK: ntfy (E19.3)

    @Test func ntfyServerAndTopic() {
        #expect(NtfyTopic(server: "", topic: "xtermx-alerts")?.url.absoluteString == "https://ntfy.sh/xtermx-alerts")
        #expect(NtfyTopic(server: "https://ntfy.example.com/", topic: "a_b")?.url.absoluteString == "https://ntfy.example.com/a_b")
        #expect(NtfyTopic(server: "ntfy.example.com", topic: "t")?.url.absoluteString == "https://ntfy.example.com/t")
        #expect(NtfyTopic(server: "", topic: "") == nil)
        #expect(NtfyTopic(server: "", topic: "has space") == nil)
        #expect(NtfyTopic(server: "", topic: "a/b") == nil)
        #expect(NtfyTopic(server: "ftp://x", topic: "t") == nil)
    }

    @Test func ntfyHeaders() throws {
        let topic = try #require(NtfyTopic(server: "", topic: "mine", token: "tk_123"))
        let failed = topic.post(AgentNotice(event: .commandFailed, paneID: "p", title: "make failed · exit 1", body: "~/app · ran 40 s"))
        #expect(failed.httpMethod == "POST")
        #expect(failed.timeoutInterval == 10)
        #expect(failed.url?.absoluteString == "https://ntfy.sh/mine")
        #expect(failed.value(forHTTPHeaderField: "Authorization") == "Bearer tk_123")
        #expect(failed.value(forHTTPHeaderField: "Priority") == "high")
        #expect(failed.value(forHTTPHeaderField: "Tags") == "x")
        // Headers are ASCII: anything else goes RFC 2047 encoded, which ntfy reads.
        #expect(failed.value(forHTTPHeaderField: "Title") == "=?UTF-8?B?" + Data("make failed · exit 1".utf8).base64EncodedString() + "?=")
        #expect(failed.httpBody == Data("~/app · ran 40 s".utf8))

        let plain = try #require(NtfyTopic(server: "", topic: "mine"))
        let done = plain.post(AgentNotice(event: .finished, paneID: nil, title: "Codex is done", body: ""))
        #expect(done.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(done.value(forHTTPHeaderField: "Title") == "Codex is done")
        #expect(done.value(forHTTPHeaderField: "Priority") == "default")
        #expect(done.value(forHTTPHeaderField: "Tags") == "white_check_mark")
        #expect(done.httpBody == Data("Codex is done".utf8))
        #expect(plain.post(AgentNotice(event: .needsYou, paneID: nil, title: "t", body: "b")).value(forHTTPHeaderField: "Priority") == "high")
    }

    // MARK: Channel × event (E19.4)

    @Test func newEventsStartOffOutsideTheMac() {
        let m = NoticeMatrix()
        for event in [AgentNoticeEvent.finished, .needsYou, .planLimit] {
            for channel in ["mac", "telegram", "slack", "webhook", "ntfy"] { #expect(m.wants(channel, event)) }
        }
        #expect(m.wants("mac", .commandFailed))
        #expect(m.wants("mac", .buildFinished))
        for channel in ["telegram", "slack", "webhook", "ntfy"] {
            #expect(!m.wants(channel, .commandFailed))
            #expect(!m.wants(channel, .buildFinished))
        }
    }

    @Test func choicesStickAndFilterTheChannels() {
        var m = NoticeMatrix()
        m.set("slack", .commandFailed, true)
        m.set("mac", .planLimit, false)
        #expect(m.wants("slack", .commandFailed))
        #expect(!m.wants("mac", .planLimit))
        #expect(m.channels(for: .commandFailed, among: ["mac", "telegram", "slack"]) == ["mac", "slack"])
        #expect(m.channels(for: .planLimit, among: ["mac", "telegram"]) == ["telegram"])
        // Kept as explicit choices, so a later change of defaults doesn't flip them.
        #expect(NoticeMatrix(choices: m.choices) == m)
        #expect(m.choices == ["slack.commandFailed": true, "mac.planLimit": false])
    }

    @Test func migratesTheOldMutedList() {
        // E4.4 kept the pairs turned off; everything else was on.
        let m = NoticeMatrix.migrating(muted: ["telegram.finished", "mac.needsYou", "junk"])
        #expect(!m.wants("telegram", .finished))
        #expect(!m.wants("mac", .needsYou))
        #expect(m.wants("telegram", .needsYou))
        #expect(m.wants("slack", .planLimit))
        #expect(!m.wants("telegram", .commandFailed))
        #expect(m.choices == ["telegram.finished": false, "mac.needsYou": false])
        #expect(NoticeMatrix.migrating(muted: []) == NoticeMatrix())
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
