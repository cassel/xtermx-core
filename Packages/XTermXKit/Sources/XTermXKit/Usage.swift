import Foundation

// MARK: - Prices

/// API list prices of one model family, US$ per million tokens.
public struct UsagePrice: Sendable, Hashable {
    public var input: Double
    public var output: Double
    /// Prompt-cache writes kept for 5 minutes (Codex: what OpenAI bills for them, the input price).
    public var cacheWrite: Double
    /// Prompt-cache writes kept for an hour (Claude's 1-hour cache).
    public var cacheWriteLong: Double
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheWrite: Double, cacheWriteLong: Double? = nil, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheWriteLong = cacheWriteLong ?? cacheWrite
        self.cacheRead = cacheRead
    }

    /// Anthropic's shape: 5-minute writes at 1.25× input, 1-hour writes at 2×.
    static func claude(_ input: Double, _ output: Double, read: Double) -> UsagePrice {
        UsagePrice(input: input, output: output, cacheWrite: input * 1.25, cacheWriteLong: input * 2, cacheRead: read)
    }

    /// OpenAI's shape: cache writes cost what input does, unless the model lists its own write price.
    static func openAI(_ input: Double, _ output: Double, read: Double, write: Double? = nil) -> UsagePrice {
        UsagePrice(input: input, output: output, cacheWrite: write ?? input, cacheRead: read)
    }
}

/// A local table of API list prices. It ages: newer models show as "no price" until it is updated.
public enum UsagePrices {
    /// When the Claude prices were last checked against Anthropic's list.
    public static let claudeAsOf = "2026-10-06"
    /// When the OpenAI prices were last checked against https://developers.openai.com/api/docs/pricing (Standard tier).
    public static let codexAsOf = "2026-10-16"

    /// Model id prefixes, longest first so `claude-opus-5-5` wins over `claude-opus-5`.
    static let table: [(prefix: String, price: UsagePrice)] = [
        ("claude-fable-5-1", .claude(10, 50, read: 0.25)),
        ("claude-mythos-5-1", .claude(10, 50, read: 0.25)),
        ("claude-fable-5", .claude(10, 50, read: 1)),
        ("claude-mythos-5", .claude(10, 50, read: 1)),
        ("claude-opus-5-5", .claude(4, 20, read: 0.2)),
        ("claude-opus-5", .claude(5, 25, read: 0.5)),
        ("claude-opus-4-8", .claude(5, 25, read: 0.5)),
        ("claude-opus-4-7", .claude(5, 25, read: 0.5)),
        ("claude-opus-4-6", .claude(5, 25, read: 0.5)),
        ("claude-opus-4-5", .claude(5, 25, read: 0.5)),
        ("claude-opus-4-1", .claude(15, 75, read: 1.5)),
        ("claude-opus-4", .claude(15, 75, read: 1.5)),
        ("claude-sonnet-5-5", .claude(2, 10, read: 0.2)),
        ("claude-sonnet-5", .claude(2, 10, read: 0.2)),
        ("claude-sonnet-4-6", .claude(3, 15, read: 0.3)),
        ("claude-sonnet-4-5", .claude(3, 15, read: 0.3)),
        ("claude-sonnet-4", .claude(3, 15, read: 0.3)),
        ("claude-3-7-sonnet", .claude(3, 15, read: 0.3)),
        // Haiku 5.5 costs 5× more past 100K prompt tokens; agent turns rarely get there.
        ("claude-haiku-5-5", .claude(0.1, 0.5, read: 0.01)),
        ("claude-haiku-4-5", .claude(1, 5, read: 0.1)),
        ("claude-3-5-haiku", .claude(0.8, 4, read: 0.08)),
        // OpenAI, Standard tier, as of 2026-10-16 from https://developers.openai.com/api/docs/pricing.
        // Short-context rates (≤ 272K input tokens); Fast mode and data-residency uplifts are left out.
        // "Pro" models list no cached-input price, so reads cost what input does.
        ("gpt-6-astra", .openAI(10, 50, read: 1, write: 12.5)),
        ("gpt-6.1-sol", .openAI(2, 10, read: 0.1, write: 2.5)),
        ("gpt-6-sol", .openAI(2, 10, read: 0.2, write: 2.5)),
        ("gpt-6-luna", .openAI(0.1, 0.5, read: 0.01, write: 0.125)),
        // Promotional price, "at least through November 21, 2026".
        ("gpt-5.6-sol", .openAI(4, 20, read: 0.4, write: 5)),
        ("gpt-5.6-terra", .openAI(2, 12, read: 0.2, write: 2.5)),
        ("gpt-5.6-luna", .openAI(0.2, 1.2, read: 0.02, write: 0.25)),
        ("gpt-5.5-pro", .openAI(30, 180, read: 30)),
        ("gpt-5.5", .openAI(5, 30, read: 0.5)),
        ("gpt-5.4-pro", .openAI(30, 180, read: 30)),
        ("gpt-5.4-mini", .openAI(0.75, 4.5, read: 0.075)),
        ("gpt-5.4-nano", .openAI(0.2, 1.25, read: 0.02)),
        ("gpt-5.4", .openAI(2.5, 15, read: 0.25)),
        ("gpt-5.3-codex", .openAI(1.75, 14, read: 0.175)),
        ("gpt-5.2-pro", .openAI(21, 168, read: 21)),
        ("gpt-5.2", .openAI(1.75, 14, read: 0.175)),
        ("gpt-5.1", .openAI(1.25, 10, read: 0.125)),
        ("gpt-5-pro", .openAI(15, 120, read: 15)),
        ("gpt-5-mini", .openAI(0.25, 2, read: 0.025)),
        ("gpt-5-nano", .openAI(0.05, 0.4, read: 0.005)),
        ("gpt-5", .openAI(1.25, 10, read: 0.125)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// The price of a model id such as `claude-opus-5-5-20261001`, `claude-opus-5-5[1m]` or `gpt-5.1-codex`.
    /// A prefix counts only when what follows starts a new word (`gpt-5-codex`), never a version (`gpt-5.6`, `claude-opus-5-6`).
    public static func price(for model: String) -> UsagePrice? {
        let id = normalized(model)
        for (prefix, price) in table where id.hasPrefix(prefix) {
            let rest = id.dropFirst(prefix.count)
            if rest.isEmpty { return price }
            if rest.first == "-", let next = rest.dropFirst().first, next.isLetter { return price }
        }
        return nil
    }

    /// Lowercased, without `[1m]`-style tags, `@` versions or a trailing `-yyyymmdd` date.
    public static func normalized(_ model: String) -> String {
        var id = model.lowercased()
        if let cut = id.firstIndex(where: { $0 == "[" || $0 == "@" }) { id = String(id[..<cut]) }
        if let r = id.range(of: #"-\d{8}$"#, options: .regularExpression) { id.removeSubrange(r) }
        return id
    }

    /// US$ for these tokens at the model's list price; nil when the table has no price for it.
    /// `cacheWriteLong` is the part of `tokens.cacheWrite` written to the 1-hour cache.
    public static func cost(_ tokens: TokenUsage, cacheWriteLong: Int = 0, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        let long = min(max(cacheWriteLong, 0), tokens.cacheWrite)
        let dollars = Double(tokens.input) * p.input + Double(tokens.output) * p.output
            + Double(tokens.cacheWrite - long) * p.cacheWrite + Double(long) * p.cacheWriteLong
            + Double(tokens.cacheRead) * p.cacheRead
        return dollars / 1_000_000
    }
}

// MARK: - Buckets

/// What one model spent in one clock hour on this machine.
public struct UsageBucket: Codable, Sendable, Hashable {
    /// Hours since 1970-01-01 00:00 UTC.
    public var hour: Int
    public var tool: AgentTool
    /// Model id without its date suffix.
    public var model: String
    public var tokens: TokenUsage
    /// The part of `tokens.cacheWrite` written to the 1-hour cache.
    public var cacheWriteLong: Int
    /// Model replies (Claude) or token reports (Codex).
    public var turns: Int

    public init(hour: Int, tool: AgentTool, model: String, tokens: TokenUsage = .init(), cacheWriteLong: Int = 0, turns: Int = 0) {
        self.hour = hour
        self.tool = tool
        self.model = model
        self.tokens = tokens
        self.cacheWriteLong = cacheWriteLong
        self.turns = turns
    }

    public var start: Date { Date(timeIntervalSince1970: TimeInterval(hour) * 3600) }
    public var costUSD: Double? { UsagePrices.cost(tokens, cacheWriteLong: cacheWriteLong, model: model) }

    // Short keys: the scan cache keeps thousands of these.
    enum CodingKeys: String, CodingKey { case h, t, m, i, o, r, w, l, n }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = try c.decode(Int.self, forKey: .h)
        tool = try c.decode(AgentTool.self, forKey: .t)
        model = try c.decode(String.self, forKey: .m)
        tokens = TokenUsage(input: try c.decodeIfPresent(Int.self, forKey: .i) ?? 0, output: try c.decodeIfPresent(Int.self, forKey: .o) ?? 0,
                            cacheRead: try c.decodeIfPresent(Int.self, forKey: .r) ?? 0, cacheWrite: try c.decodeIfPresent(Int.self, forKey: .w) ?? 0)
        cacheWriteLong = try c.decodeIfPresent(Int.self, forKey: .l) ?? 0
        turns = try c.decodeIfPresent(Int.self, forKey: .n) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hour, forKey: .h)
        try c.encode(tool, forKey: .t)
        try c.encode(model, forKey: .m)
        if tokens.input != 0 { try c.encode(tokens.input, forKey: .i) }
        if tokens.output != 0 { try c.encode(tokens.output, forKey: .o) }
        if tokens.cacheRead != 0 { try c.encode(tokens.cacheRead, forKey: .r) }
        if tokens.cacheWrite != 0 { try c.encode(tokens.cacheWrite, forKey: .w) }
        if cacheWriteLong != 0 { try c.encode(cacheWriteLong, forKey: .l) }
        if turns != 0 { try c.encode(turns, forKey: .n) }
    }

    /// Buckets of the same hour, tool and model added together, oldest first.
    public static func merged(_ buckets: [UsageBucket]) -> [UsageBucket] {
        var byKey: [String: UsageBucket] = [:]
        for b in buckets {
            let key = "\(b.hour)|\(b.tool.rawValue)|\(b.model)"
            if var old = byKey[key] {
                old.tokens = old.tokens + b.tokens
                old.cacheWriteLong += b.cacheWriteLong
                old.turns += b.turns
                byKey[key] = old
            } else {
                byKey[key] = b
            }
        }
        return byKey.values.sorted { ($0.hour, $0.tool.rawValue, $0.model) < ($1.hour, $1.tool.rawValue, $1.model) }
    }
}

/// Tokens and API-price cost over a stretch of time.
public struct UsageSpan: Sendable, Hashable {
    public var tokens = TokenUsage()
    public var cacheWriteLong = 0
    public var turns = 0
    /// At API list prices, for the tokens that have one.
    public var costUSD = 0.0
    /// Tokens of models the price table does not know.
    public var unpricedTokens = 0
    public var unpricedModels: Set<String> = []

    public init() {}

    public mutating func add(_ b: UsageBucket) {
        tokens = tokens + b.tokens
        cacheWriteLong += b.cacheWriteLong
        turns += b.turns
        if let cost = b.costUSD {
            costUSD += cost
        } else if b.tokens.total > 0 {
            unpricedTokens += b.tokens.total
            unpricedModels.insert(b.model)
        }
    }

    /// Another span's numbers added to these.
    public mutating func add(_ other: UsageSpan) {
        tokens = tokens + other.tokens
        cacheWriteLong += other.cacheWriteLong
        turns += other.turns
        costUSD += other.costUSD
        unpricedTokens += other.unpricedTokens
        unpricedModels.formUnion(other.unpricedModels)
    }

    /// Every token had a price.
    public var fullyPriced: Bool { unpricedTokens == 0 }

    /// Anything happened: a token or a turn.
    public var isActive: Bool { tokens.total > 0 || turns > 0 }
}

/// What agents on this machine spent, from every session's transcript (panes, other terminals, IDEs).
public struct MachineUsage: Codable, Sendable, Hashable {
    /// Hourly buckets over the last 30 days, oldest first.
    public var buckets: [UsageBucket]
    public var scannedAt: Date
    /// Transcript files read.
    public var files: Int

    public init(buckets: [UsageBucket] = [], scannedAt: Date = .now, files: Int = 0) {
        self.buckets = buckets
        self.scannedAt = scannedAt
        self.files = files
    }

    /// Everything from the clock hour that holds `start` on, optionally for one tool.
    public func span(since start: Date, tool: AgentTool? = nil) -> UsageSpan {
        let first = Int((start.timeIntervalSince1970 / 3600).rounded(.down))
        var span = UsageSpan()
        for b in buckets where b.hour >= first && (tool == nil || b.tool == tool) { span.add(b) }
        return span
    }

    /// The last 5 hours, by the hour (so 5 to 6 hours of buckets).
    public func lastFiveHours(_ tool: AgentTool? = nil, now: Date = .now) -> UsageSpan {
        span(since: now.addingTimeInterval(-5 * 3600), tool: tool)
    }

    /// Today and the `days - 1` days before it, local calendar days.
    public func lastDays(_ days: Int, _ tool: AgentTool? = nil, now: Date = .now, calendar: Calendar = .current) -> UsageSpan {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        return span(since: start, tool: tool)
    }

    /// Which tools spent anything.
    public var tools: [AgentTool] { AgentTool.allCases.filter { t in buckets.contains { $0.tool == t } } }
}

// MARK: - Charts and stats

/// One bar of a usage chart: a clock hour or a local day, split by tool.
public struct UsageSlot: Sendable, Hashable, Identifiable {
    public var start: Date
    public var end: Date
    public var byTool: [AgentTool: UsageSpan]

    public init(start: Date, end: Date, byTool: [AgentTool: UsageSpan] = [:]) {
        self.start = start
        self.end = end
        self.byTool = byTool
    }

    public var id: Date { start }

    /// One tool's numbers, or every tool's together.
    public func span(_ tool: AgentTool? = nil) -> UsageSpan {
        if let tool { return byTool[tool] ?? UsageSpan() }
        var total = UsageSpan()
        for span in byTool.values { total.add(span) }
        return total
    }

    /// Slots added up, for the breakdown under a chart.
    public static func total(_ slots: [UsageSlot], _ tool: AgentTool? = nil) -> UsageSpan {
        var total = UsageSpan()
        for slot in slots { total.add(slot.span(tool)) }
        return total
    }
}

/// How regular the agent work on this machine is, over the days the scan keeps.
public struct UsageStats: Sendable, Hashable {
    /// Days looked at.
    public var days = 0
    /// Days with at least one token or turn.
    public var activeDays = 0
    /// Model replies (Claude) and token reports (Codex).
    public var turns = 0
    /// Active days in a row up to today. A today with nothing yet doesn't break it: it counts from yesterday.
    public var streak = 0
    /// The longest run of active days in the stretch.
    public var longestStreak = 0

    public init() {}

    /// True when the streak reaches back to the first day kept, so it may be longer than the data shows.
    public var streakMayBeLonger: Bool { streak > 0 && streak >= days }
}

extension MachineUsage {
    /// The last `hours` clock hours, the current one last; hours with nothing are there, empty.
    public func hourly(_ hours: Int = 24, now: Date = .now) -> [UsageSlot] {
        let count = max(hours, 1)
        let current = Int((now.timeIntervalSince1970 / 3600).rounded(.down))
        let first = current - count + 1
        var slots = (0..<count).map { i in
            UsageSlot(start: Date(timeIntervalSince1970: TimeInterval(first + i) * 3600),
                      end: Date(timeIntervalSince1970: TimeInterval(first + i + 1) * 3600))
        }
        for b in buckets where b.hour >= first && b.hour <= current {
            slots[b.hour - first].byTool[b.tool, default: UsageSpan()].add(b)
        }
        return slots
    }

    /// Today and the `days - 1` local calendar days before it, today last; days with nothing are there, empty.
    public func daily(_ days: Int = 30, now: Date = .now, calendar: Calendar = .current) -> [UsageSlot] {
        let count = max(days, 1)
        let today = calendar.startOfDay(for: now)
        var starts: [Date] = []
        for back in stride(from: count - 1, through: 0, by: -1) {
            starts.append(calendar.date(byAdding: .day, value: -back, to: today) ?? today)
        }
        var slots = starts.enumerated().map { i, start in
            UsageSlot(start: start, end: i + 1 < starts.count ? starts[i + 1] : calendar.date(byAdding: .day, value: 1, to: today) ?? now)
        }
        var index: [Date: Int] = [:]
        for (i, s) in slots.enumerated() { index[s.start] = i }
        for b in buckets {
            // A bucket belongs to the day its hour starts in.
            guard let i = index[calendar.startOfDay(for: b.start)] else { continue }
            slots[i].byTool[b.tool, default: UsageSpan()].add(b)
        }
        return slots
    }

    /// Active days, turns and streaks over the last `days` days, optionally for one tool.
    public func stats(days: Int = 30, _ tool: AgentTool? = nil, now: Date = .now, calendar: Calendar = .current) -> UsageStats {
        let slots = daily(days, now: now, calendar: calendar)
        var stats = UsageStats()
        stats.days = slots.count
        var run = 0
        for slot in slots {
            let span = slot.span(tool)
            stats.turns += span.turns
            if span.isActive {
                stats.activeDays += 1
                run += 1
                stats.longestStreak = max(stats.longestStreak, run)
            } else {
                run = 0
            }
        }
        var active = slots.map { $0.span(tool).isActive }
        if active.last == false { active.removeLast() }
        stats.streak = active.reversed().prefix { $0 }.count
        return stats
    }
}

// MARK: - Limits

/// How close a plan limit is to running out, for colors.
public enum UsageLevel: Sendable, Hashable {
    case unknown, normal, high, critical

    public init(percent: Double?) {
        guard let percent else { self = .unknown; return }
        self = percent >= 90 ? .critical : percent >= 70 ? .high : .normal
    }
}

extension UsageWindow {
    /// The used share, or nil when the window has started over since the numbers were taken.
    public func percent(now: Date = .now) -> Double? {
        if let resetsAt, resetsAt < now { return nil }
        return min(max(usedPercent, 0), 100)
    }
}

extension AccountUsage {
    /// The window a one-number meter shows: the week, else the 5-hour session.
    public var headline: UsageWindow? { window(.weekly) ?? window(.fiveHour) }

    /// Accounts in the order the title bar shows them: by tool (`first` on top), then the default account, then by name.
    public static func meterOrder(_ accounts: [AccountUsage], first: AgentTool? = nil) -> [AccountUsage] {
        func rank(_ t: AgentTool) -> Int { t == first ? -1 : AgentTool.allCases.firstIndex(of: t) ?? 0 }
        return accounts.filter { !$0.windows.isEmpty }.sorted {
            if $0.tool != $1.tool { return rank($0.tool) < rank($1.tool) }
            let d0 = $0.displayName == $0.tool.name, d1 = $1.displayName == $1.tool.name
            if d0 != d1 { return d0 }
            return $0.account < $1.account
        }
    }
}

/// A plan window past the warning line: the pane banner and the "plan limit" notice.
public struct UsageLimitAlert: Sendable, Hashable, Identifiable {
    public var accountID: String
    public var tool: AgentTool
    /// The config folder, as `AgentSessionInfo.account` has it.
    public var account: String
    public var displayName: String
    public var kind: UsageWindow.Kind
    public var percent: Double
    public var resetsAt: Date?

    public var id: String { "\(accountID)|\(kind.rawValue)" }

    /// "Week" or "5 hours".
    public var windowName: String { kind == .weekly ? "Week" : "5 hours" }

    /// "Weekly limit · resets in 2d 3h", with the account folder when it isn't the tool's default one.
    public func detail(now: Date = .now) -> String {
        var parts = [kind == .weekly ? "Weekly limit" : "5-hour limit"]
        if let left = UsageFormat.until(resetsAt, from: now) { parts.append("resets in \(left)") }
        if displayName != tool.name { parts.append((account as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }
        return parts.joined(separator: " · ")
    }
}

/// Which plan windows were already announced, so each one is told about once until it starts over.
public struct UsageLimitAlarm: Codable, Sendable, Hashable {
    /// Percent of a window from which it is announced.
    public static let threshold = 90.0
    /// Two reset times this close apart are the same window (the reported time can drift a little).
    static let sameWindow: TimeInterval = 30 * 60

    struct Told: Codable, Sendable, Hashable {
        var resetsAt: Date?
        var at: Date
    }

    /// Alert id → the window that was announced.
    var told: [String: Told] = [:]

    public init() {}

    /// Every window at or past the threshold right now, the fullest first.
    public static func alerts(_ accounts: [AccountUsage], now: Date = .now) -> [UsageLimitAlert] {
        var out: [UsageLimitAlert] = []
        for a in accounts {
            for w in a.windows {
                guard let p = w.percent(now: now), p >= threshold else { continue }
                out.append(UsageLimitAlert(accountID: a.id, tool: a.tool, account: a.account, displayName: a.displayName,
                                           kind: w.kind, percent: p, resetsAt: w.resetsAt))
            }
        }
        return out.sorted { $0.percent != $1.percent ? $0.percent > $1.percent : $0.id < $1.id }
    }

    /// The alerts not announced yet for their window; they count as announced from now on.
    public mutating func newAlerts(_ accounts: [AccountUsage], now: Date = .now) -> [UsageLimitAlert] {
        // Forget windows that are over; a window without a reset time re-arms once it is well under the line again.
        told = told.filter { _, t in
            if let r = t.resetsAt { return r > now }
            return now.timeIntervalSince(t.at) < 8 * 86400
        }
        for a in accounts {
            for w in a.windows where w.resetsAt == nil && w.usedPercent < Self.threshold - 20 {
                told["\(a.id)|\(w.kind.rawValue)"] = nil
            }
        }
        var fresh: [UsageLimitAlert] = []
        for alert in Self.alerts(accounts, now: now) {
            if let t = told[alert.id], Self.same(t.resetsAt, alert.resetsAt) { continue }
            told[alert.id] = Told(resetsAt: alert.resetsAt, at: now)
            fresh.append(alert)
        }
        return fresh
    }

    static func same(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < sameWindow
        default: false
        }
    }
}

extension UsageFormat {
    /// US$: "$0.42", "$12.30", "$9,931".
    public static func dollars(_ value: Double) -> String {
        if value >= 1000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return "$" + (f.string(from: NSNumber(value: value.rounded())) ?? String(format: "%.0f", value))
        }
        return String(format: "$%.2f", value)
    }
}
