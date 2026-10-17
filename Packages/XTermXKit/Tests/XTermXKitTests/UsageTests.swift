#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

/// This Mac's usage: API prices, transcript scanning (Claude Code and Codex), the cache, and the spans the popover shows.
@Suite struct UsageTests {
    // 2026-10-16 12:00 UTC.
    let noon = Date(timeIntervalSince1970: 1_792_152_000)

    func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    func claudeLine(_ id: String, at date: Date, model: String = "claude-opus-5-5-20261001", input: Int = 10, output: Int = 100,
                    read: Int = 1000, write: Int = 200, long: Int = 0) -> String {
        let usage: [String: Any] = ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": read,
                                    "cache_creation_input_tokens": write,
                                    "cache_creation": ["ephemeral_1h_input_tokens": long, "ephemeral_5m_input_tokens": write - long]]
        let o: [String: Any] = ["type": "assistant", "timestamp": iso(date), "uuid": UUID().uuidString,
                                "message": ["id": id, "model": model, "role": "assistant", "usage": usage, "content": [] as [Any]]]
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    func codexCount(at date: Date, input: Int, cached: Int, output: Int) -> String {
        let total: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                                    "cache_write_input_tokens": 0, "total_tokens": input + output]
        let o: [String: Any] = ["timestamp": iso(date), "type": "event_msg",
                                "payload": ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": total]]]
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    func codexContext(_ model: String, at date: Date) -> String {
        let o: [String: Any] = ["timestamp": iso(date), "type": "turn_context", "payload": ["model": model, "cwd": "/tmp"]]
        return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xtermx-usage-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ lines: [String], to url: URL, append: Bool = false, newline: Bool = true) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (newline ? "\n" : "")
        if append, let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try! Data(text.utf8).write(to: url)
        }
        // Scans run "now"; keep the file inside the 30 days.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // MARK: Prices

    @Test func pricesMatchModelFamilies() {
        #expect(UsagePrices.price(for: "claude-opus-5-5")?.input == 4)
        #expect(UsagePrices.price(for: "claude-opus-5-5-20261001")?.output == 20)
        #expect(UsagePrices.price(for: "claude-opus-5-5[1m]")?.cacheRead == 0.2)
        #expect(UsagePrices.price(for: "claude-opus-5")?.input == 5)
        #expect(UsagePrices.price(for: "claude-fable-5-1")?.cacheRead == 0.25)
        #expect(UsagePrices.price(for: "claude-haiku-4-5-20251001")?.input == 1)
        #expect(UsagePrices.price(for: "gpt-5-codex")?.input == 1.25)
        #expect(UsagePrices.price(for: "gpt-5.1-codex-max")?.output == 10)
        #expect(UsagePrices.price(for: "gpt-5-mini")?.input == 0.25)
        #expect(UsagePrices.price(for: "gpt-6-sol")?.cacheRead == 0.2)
        #expect(UsagePrices.price(for: "gpt-6.1-sol")?.cacheRead == 0.1)
        #expect(UsagePrices.price(for: "gpt-6-sol")?.cacheWrite == 2.5)
        #expect(UsagePrices.price(for: "gpt-5.6-luna")?.output == 1.2)
        #expect(UsagePrices.price(for: "gpt-5.4-mini")?.input == 0.75)
        #expect(UsagePrices.price(for: "gpt-5.5-pro")?.input == 30)
        // A newer version is not the older one's price.
        #expect(UsagePrices.price(for: "claude-opus-5-6") == nil)
        #expect(UsagePrices.price(for: "gpt-5.7-luna") == nil)
        #expect(UsagePrices.price(for: "gpt-6.2-sol") == nil)
        #expect(UsagePrices.price(for: "codex-auto-review") == nil)
        #expect(UsagePrices.price(for: "unknown") == nil)
    }

    @Test func costCountsEveryKindOfToken() throws {
        // Opus 5.5: $4 in, $20 out, $5 5-minute write, $8 1-hour write, $0.20 read, per million.
        let t = TokenUsage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 2_000_000)
        let cost = try #require(UsagePrices.cost(t, cacheWriteLong: 1_000_000, model: "claude-opus-5-5"))
        #expect(abs(cost - (4 + 20 + 0.2 + 5 + 8)) < 1e-9)
        // Codex: cache writes at the input price.
        let codex = try #require(UsagePrices.cost(TokenUsage(input: 1_000_000, cacheWrite: 1_000_000), model: "gpt-5"))
        #expect(abs(codex - 2.5) < 1e-9)
        // Newer OpenAI models list their own cache-write price.
        let sol = try #require(UsagePrices.cost(TokenUsage(input: 1_000_000, cacheWrite: 1_000_000), model: "gpt-6-sol"))
        #expect(abs(sol - 4.5) < 1e-9)
        #expect(UsagePrices.cost(t, model: "gpt-6.2-sol") == nil)
    }

    // MARK: Charts and stats

    /// A bucket `days` local days and `hours` hours before noon.
    func bucket(daysAgo days: Int, hoursAgo hours: Int = 0, tool: AgentTool = .claude, tokens: Int = 100, turns: Int = 1,
                calendar: Calendar) -> UsageBucket {
        let at = calendar.date(byAdding: .day, value: -days, to: noon)!.addingTimeInterval(TimeInterval(-hours * 3600))
        return UsageBucket(hour: Int(at.timeIntervalSince1970 / 3600), tool: tool, model: "claude-opus-5-5",
                           tokens: TokenUsage(input: tokens), turns: turns)
    }

    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func slotsCoverEveryHourAndDay() {
        let usage = MachineUsage(buckets: [
            bucket(daysAgo: 0, calendar: utc), bucket(daysAgo: 0, tool: .codex, tokens: 50, calendar: utc),
            bucket(daysAgo: 0, hoursAgo: 23, calendar: utc), bucket(daysAgo: 0, hoursAgo: 24, calendar: utc),
            bucket(daysAgo: 29, calendar: utc), bucket(daysAgo: 30, calendar: utc),
        ])
        let hours = usage.hourly(24, now: noon)
        #expect(hours.count == 24)
        #expect(hours.last?.start == noon)
        #expect(hours.last?.span().tokens.input == 150)
        #expect(hours.last?.span(.codex).tokens.input == 50)
        #expect(hours.first?.span().tokens.input == 100)  // 23 hours ago; 24 hours ago is out
        #expect(UsageSlot.total(hours).tokens.input == 250)

        let days = usage.daily(30, now: noon, calendar: utc)
        #expect(days.count == 30)
        #expect(days.last?.start == utc.startOfDay(for: noon))
        // Today: noon (claude + codex); yesterday: 23 h and 24 h before noon fall on it.
        #expect(days.last?.span().tokens.input == 150)
        #expect(days[28].span().tokens.input == 200)
        #expect(days.first?.span().tokens.input == 100)  // 29 days ago; 30 is out
        #expect(UsageSlot.total(days, .codex).tokens.input == 50)
    }

    @Test func statsCountActiveDaysAndStreaks() {
        // Active today, 1, 2 and 3 days ago, then 5 to 7 days ago.
        let days = [0, 1, 2, 3, 5, 6, 7]
        let usage = MachineUsage(buckets: days.map { bucket(daysAgo: $0, turns: 2, calendar: utc) })
        let s = usage.stats(days: 30, now: noon, calendar: utc)
        #expect(s.days == 30)
        #expect(s.activeDays == 7)
        #expect(s.turns == 14)
        #expect(s.streak == 4)
        #expect(s.longestStreak == 4)
        #expect(!s.streakMayBeLonger)

        // Nothing yet today: the streak runs from yesterday.
        let quiet = MachineUsage(buckets: [1, 2].map { bucket(daysAgo: $0, calendar: utc) })
        #expect(quiet.stats(now: noon, calendar: utc).streak == 2)
        // Nothing today or yesterday: no streak.
        let broken = MachineUsage(buckets: [2, 3].map { bucket(daysAgo: $0, calendar: utc) })
        #expect(broken.stats(now: noon, calendar: utc).streak == 0)
        #expect(broken.stats(now: noon, calendar: utc).longestStreak == 2)
        // One tool only.
        let mixed = MachineUsage(buckets: [bucket(daysAgo: 0, tool: .codex, calendar: utc), bucket(daysAgo: 1, calendar: utc)])
        #expect(mixed.stats(.codex, now: noon, calendar: utc).activeDays == 1)
        #expect(mixed.stats(.claude, now: noon, calendar: utc).streak == 1)
        #expect(MachineUsage().stats(now: noon, calendar: utc).streak == 0)
    }

    // MARK: Plan limit notice

    func account(_ tool: AgentTool = .claude, week: Double, resets: Date?, fiveHour: Double? = nil) -> AccountUsage {
        var windows = [UsageWindow(kind: .weekly, usedPercent: week, resetsAt: resets)]
        if let fiveHour { windows.append(UsageWindow(kind: .fiveHour, usedPercent: fiveHour, resetsAt: resets?.addingTimeInterval(-86400))) }
        return AccountUsage(tool: tool, account: tool == .claude ? "~/.claude" : "~/.codex", windows: windows)
    }

    @Test func planLimitIsToldOncePerWindow() {
        let reset = noon.addingTimeInterval(2 * 86400)
        var alarm = UsageLimitAlarm()
        #expect(alarm.newAlerts([account(week: 85, resets: reset)], now: noon).isEmpty)
        let first = alarm.newAlerts([account(week: 91, resets: reset)], now: noon)
        #expect(first.map(\.kind) == [.weekly])
        #expect(first.first?.detail(now: noon) == "Weekly limit · resets in 2d 0h")
        // Climbing further, a later reading with a reset time that drifted a bit: same window, nothing new.
        #expect(alarm.newAlerts([account(week: 95, resets: reset.addingTimeInterval(40))], now: noon.addingTimeInterval(600)).isEmpty)
        #expect(alarm.newAlerts([account(week: 99, resets: reset)], now: noon.addingTimeInterval(3600)).isEmpty)
        // Survives a relaunch.
        var reloaded = (try? JSONDecoder().decode(UsageLimitAlarm.self, from: JSONEncoder().encode(alarm))) ?? UsageLimitAlarm()
        #expect(reloaded.newAlerts([account(week: 99, resets: reset)], now: noon.addingTimeInterval(7200)).isEmpty)
        // After the reset the window is over; the next week's crossing is told again.
        let later = reset.addingTimeInterval(60)
        #expect(alarm.newAlerts([account(week: 91, resets: reset)], now: later).isEmpty)
        let next = alarm.newAlerts([account(week: 92, resets: reset.addingTimeInterval(7 * 86400))], now: later.addingTimeInterval(86400))
        #expect(next.count == 1)
        // The 5-hour window is its own window, and each account is its own.
        let both = alarm.newAlerts([account(week: 92, resets: reset.addingTimeInterval(7 * 86400), fiveHour: 96),
                                    account(.codex, week: 93, resets: reset.addingTimeInterval(7 * 86400))], now: later.addingTimeInterval(86400))
        #expect(both.map(\.kind) == [.fiveHour, .weekly])
        #expect(both.map(\.tool) == [.claude, .codex])
    }

    @Test func planLimitWithoutResetTimeRearmsWhenWellUnder() {
        var alarm = UsageLimitAlarm()
        #expect(alarm.newAlerts([account(week: 90, resets: nil)], now: noon).count == 1)
        #expect(alarm.newAlerts([account(week: 97, resets: nil)], now: noon).isEmpty)
        #expect(alarm.newAlerts([account(week: 85, resets: nil)], now: noon).isEmpty)
        #expect(alarm.newAlerts([account(week: 91, resets: nil)], now: noon).isEmpty)
        #expect(alarm.newAlerts([account(week: 10, resets: nil)], now: noon).isEmpty)
        #expect(alarm.newAlerts([account(week: 90, resets: nil)], now: noon).count == 1)
        // A window that already started over is not near its limit.
        #expect(UsageLimitAlarm.alerts([account(week: 99, resets: noon.addingTimeInterval(-60))], now: noon).isEmpty)
        let second = AccountUsage(tool: .claude, account: "~/.claude-work", windows: [UsageWindow(kind: .weekly, usedPercent: 95, resetsAt: nil)])
        #expect(UsageLimitAlarm.alerts([second], now: noon).first?.detail(now: noon) == "Weekly limit · claude-work")
    }

    // MARK: Parsing

    @Test func hoursFromTimestamps() {
        #expect(UsageScanner.hourOf("1970-01-01T00:59:59.000Z") == 0)
        #expect(UsageScanner.hourOf("2026-10-16T12:34:56.789Z") == Int(noon.timeIntervalSince1970 / 3600))
        #expect(UsageScanner.hourOf("2026-10-16T14:34:56+02:00") == Int(noon.timeIntervalSince1970 / 3600))
        #expect(UsageScanner.hourOf("yesterday") == nil)
        #expect(UsageScanner.daysFromCivil(2000, 3, 1) == 11_017)
    }

    @Test func claudeRepliesCountOnce() {
        var s = UsageScanner.FileState(tool: .claude)
        let cutoff = UsageScanner.cutoffHour(noon)
        let lines = [
            claudeLine("msg_1", at: noon, long: 50),
            // The same streamed reply on its next content block: no new tokens, no new turn.
            claudeLine("msg_1", at: noon, long: 50),
            // …and once more with more output.
            claudeLine("msg_1", at: noon, output: 150, long: 50),
            claudeLine("msg_2", at: noon.addingTimeInterval(60), model: "claude-haiku-4-5", input: 1, output: 2, read: 3, write: 4),
            claudeLine("msg_3", at: noon, model: "<synthetic>"),
            // Older than 30 days.
            claudeLine("msg_4", at: noon.addingTimeInterval(-31 * 86_400)),
            #"{"type":"user","message":{"role":"user","content":"usage of assistant"}}"#,
            "not json",
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let consumed = UsageScanner.lines(in: data) { UsageScanner.feed($0, into: &s, cutoffHour: cutoff) }
        #expect(consumed == data.count)

        let opus = s.buckets.first { $0.model == "claude-opus-5-5" }
        #expect(opus?.tokens == TokenUsage(input: 10, output: 150, cacheRead: 1000, cacheWrite: 200))
        #expect(opus?.cacheWriteLong == 50)
        #expect(opus?.turns == 1)
        #expect(opus?.hour == Int(noon.timeIntervalSince1970 / 3600))
        #expect(s.buckets.first { $0.model == "claude-haiku-4-5" }?.tokens.total == 10)
        #expect(s.buckets.count == 2)
    }

    @Test func codexTotalsBecomeDeltas() {
        var s = UsageScanner.FileState(tool: .codex)
        let cutoff = UsageScanner.cutoffHour(noon)
        let lines = [
            codexContext("gpt-5-codex", at: noon),
            codexCount(at: noon, input: 1000, cached: 600, output: 50),
            // The same totals again (a limits-only report): nothing new.
            codexCount(at: noon, input: 1000, cached: 600, output: 50),
            codexCount(at: noon.addingTimeInterval(3600), input: 3000, cached: 2000, output: 150),
            codexContext("gpt-6-sol", at: noon.addingTimeInterval(3600)),
            // Totals that start over count from zero.
            codexCount(at: noon.addingTimeInterval(3700), input: 100, cached: 0, output: 10),
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        _ = UsageScanner.lines(in: data) { UsageScanner.feed($0, into: &s, cutoffHour: cutoff) }

        let hour = Int(noon.timeIntervalSince1970 / 3600)
        let first = s.buckets.first { $0.hour == hour && $0.model == "gpt-5-codex" }
        #expect(first?.tokens == TokenUsage(input: 400, output: 50, cacheRead: 600))
        #expect(first?.turns == 1)
        let second = s.buckets.first { $0.hour == hour + 1 && $0.model == "gpt-5-codex" }
        #expect(second?.tokens == TokenUsage(input: 600, output: 100, cacheRead: 1400))
        let reset = s.buckets.first { $0.model == "gpt-6-sol" }
        #expect(reset?.tokens == TokenUsage(input: 100, output: 10))
    }

    @Test func partialLineWaitsForItsEnd() {
        let line = Data(claudeLine("msg_1", at: noon).utf8)
        var data = Data(claudeLine("msg_0", at: noon).utf8) + Data([0x0A])
        data += line.prefix(40)
        var s = UsageScanner.FileState(tool: .claude)
        let consumed = UsageScanner.lines(in: data) { UsageScanner.feed($0, into: &s, cutoffHour: 0) }
        #expect(consumed == data.count - 40)
        #expect(s.buckets.first?.turns == 1)
    }

    // MARK: Scanning

    @Test func scansIncrementallyAndKeepsTheCache() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claude = dir.appendingPathComponent(".claude").path
        let codex = dir.appendingPathComponent(".codex").path
        let cache = dir.appendingPathComponent("usage-scan.json")
        let now = Date()
        let session = URL(fileURLWithPath: claude + "/projects/-x-app/s1.jsonl")
        let subagent = URL(fileURLWithPath: claude + "/projects/-x-app/s1/subagents/agent-a.jsonl")
        let rollout = URL(fileURLWithPath: codex + "/sessions/2026/10/16/rollout-1.jsonl")
        write([claudeLine("a", at: now)], to: session)
        write([claudeLine("b", at: now, input: 5, output: 5, read: 0, write: 0)], to: subagent)
        write([codexContext("gpt-5", at: now), codexCount(at: now, input: 100, cached: 0, output: 10)], to: rollout)

        let scanner = UsageScanner(url: cache)
        var usage = scanner.scan(claude: [claude], codex: [codex], now: now)
        #expect(usage.files == 3)
        #expect(usage.lastDays(1, .claude, now: now).tokens.total == 1310 + 10)
        #expect(usage.lastDays(1, .codex, now: now).tokens.total == 110)
        #expect(usage.lastDays(1, now: now).turns == 3)

        // Appended lines are read; the rest is not read again.
        write([claudeLine("c", at: now, input: 1, output: 1, read: 0, write: 0)], to: session, append: true)
        usage = scanner.scan(claude: [claude], codex: [codex], now: now)
        #expect(usage.lastDays(1, .claude, now: now).tokens.total == 1322)

        // A new scanner starts from the cache, not from zero.
        let again = UsageScanner(url: cache).scan(claude: [claude], codex: [codex], now: now)
        #expect(again.lastDays(1, now: now).tokens == usage.lastDays(1, now: now).tokens)

        // A file rewritten shorter is read from the start.
        write([claudeLine("d", at: now, input: 2, output: 0, read: 0, write: 0)], to: session)
        let rewritten = UsageScanner(url: cache).scan(claude: [claude], codex: [codex], now: now)
        #expect(rewritten.lastDays(1, .claude, now: now).tokens.total == 2 + 10)
    }

    // MARK: Spans

    @Test func spansAddUpByWindowAndPrice() {
        let hour = Int(noon.timeIntervalSince1970 / 3600)
        let usage = MachineUsage(buckets: [
            UsageBucket(hour: hour, tool: .claude, model: "claude-opus-5-5", tokens: TokenUsage(input: 1_000_000), turns: 2),
            UsageBucket(hour: hour - 4, tool: .codex, model: "gpt-6.2-sol", tokens: TokenUsage(input: 500), turns: 1),
            UsageBucket(hour: hour - 30, tool: .claude, model: "claude-opus-5-5", tokens: TokenUsage(output: 1_000_000), turns: 1),
            UsageBucket(hour: hour - 24 * 10, tool: .claude, model: "claude-opus-5-5", tokens: TokenUsage(output: 2_000_000), turns: 1),
        ], scannedAt: noon)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        let five = usage.lastFiveHours(now: noon.addingTimeInterval(1800))
        #expect(five.tokens.total == 1_000_500)
        #expect(five.unpricedTokens == 500)
        #expect(five.unpricedModels == ["gpt-6.2-sol"])
        #expect(abs(five.costUSD - 4) < 1e-9)
        #expect(!five.fullyPriced)

        #expect(abs(usage.lastDays(1, now: noon, calendar: utc).costUSD - 4) < 1e-9)
        #expect(abs(usage.lastDays(7, now: noon, calendar: utc).costUSD - 24) < 1e-9)
        #expect(abs(usage.lastDays(30, now: noon, calendar: utc).costUSD - 64) < 1e-9)
        #expect(usage.lastDays(30, .codex, now: noon, calendar: utc).turns == 1)
        #expect(usage.tools == [.claude, .codex])
    }

    @Test func bigNumbersStayShort() {
        #expect(UsageFormat.tokens(2_500_000) == "2.5M")
        #expect(UsageFormat.tokens(623_100_000) == "623M")
        #expect(UsageFormat.tokens(19_545_100_000) == "19.5B")
        #expect(UsageFormat.dollars(0.4249) == "$0.42")
        #expect(UsageFormat.dollars(9930.84).hasPrefix("$9"))
        #expect(UsageFormat.dollars(9930.84).hasSuffix("931"))
    }

    @Test func bucketsMergeAndRoundTrip() throws {
        let a = UsageBucket(hour: 5, tool: .claude, model: "m", tokens: TokenUsage(input: 1), cacheWriteLong: 2, turns: 1)
        let b = UsageBucket(hour: 5, tool: .claude, model: "m", tokens: TokenUsage(output: 3), turns: 1)
        let c = UsageBucket(hour: 4, tool: .codex, model: "m", tokens: TokenUsage(cacheRead: 7))
        let merged = UsageBucket.merged([a, b, c])
        #expect(merged.map(\.hour) == [4, 5])
        #expect(merged[1].tokens == TokenUsage(input: 1, output: 3))
        #expect(merged[1].turns == 2)
        let data = try JSONEncoder().encode(merged)
        #expect(try JSONDecoder().decode([UsageBucket].self, from: data) == merged)
    }

    @Test func limitsAndMeterOrder() {
        let soon = Date().addingTimeInterval(3600)
        let past = Date().addingTimeInterval(-60)
        #expect(UsageWindow(kind: .weekly, usedPercent: 120, resetsAt: soon).percent() == 100)
        #expect(UsageWindow(kind: .weekly, usedPercent: 50, resetsAt: past).percent() == nil)
        #expect(UsageLevel(percent: 95) == .critical)
        #expect(UsageLevel(percent: 75) == .high)
        #expect(UsageLevel(percent: 10) == .normal)
        #expect(UsageLevel(percent: nil) == .unknown)

        let w = [UsageWindow(kind: .fiveHour, usedPercent: 10, resetsAt: soon)]
        let codex = AccountUsage(tool: .codex, account: "~/.codex", windows: w)
        let work = AccountUsage(tool: .claude, account: "~/.claude-work", windows: w)
        let main = AccountUsage(tool: .claude, account: "~/.claude", windows: w + [UsageWindow(kind: .weekly, usedPercent: 40, resetsAt: soon)])
        let empty = AccountUsage(tool: .claude, account: "~/.claude-x", windows: [])
        #expect(AccountUsage.meterOrder([codex, work, empty, main]).map(\.account) == ["~/.claude", "~/.claude-work", "~/.codex"])
        #expect(AccountUsage.meterOrder([codex, work, main], first: .codex).first?.tool == .codex)
        #expect(main.headline?.kind == .weekly)
        #expect(codex.headline?.kind == .fiveHour)
    }

    /// `XTERMX_USAGE_PROBE=1 swift test --filter probeRealMachine`: times a cold and a warm scan of this Mac's
    /// transcripts into a temporary cache and prints totals only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XTERMX_USAGE_PROBE"] == "1"))
    func probeRealMachine() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scanner = UsageScanner(url: dir.appendingPathComponent("usage-scan.json"))
        let t0 = Date()
        let usage = scanner.scan()
        let cold = Date().timeIntervalSince(t0)
        let t1 = Date()
        _ = scanner.scan()
        let warm = Date().timeIntervalSince(t1)
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("usage-scan.json").path)[.size] as? Int) ?? 0
        for tool in AgentTool.allCases {
            let m = usage.lastDays(30, tool), w = usage.lastDays(7, tool), h = usage.lastFiveHours(tool)
            print("probe \(tool.rawValue): 5h \(UsageFormat.tokens(h.tokens.total)) 7d \(UsageFormat.tokens(w.tokens.total)) 30d \(UsageFormat.tokens(m.tokens.total)) · 30d $\(String(format: "%.2f", m.costUSD)) · unpriced \(UsageFormat.tokens(m.unpricedTokens)) \(m.unpricedModels.sorted())")
        }
        print(String(format: "probe files %d · cold %.2fs · warm %.2fs · cache %d KB", usage.files, cold, warm, size / 1024))
    }
}
#endif
