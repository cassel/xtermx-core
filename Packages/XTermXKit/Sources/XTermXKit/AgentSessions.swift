import Foundation

/// A coding agent whose own session files XTermX reads (tokens, status, subagents, plan limits).
public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case gemini

    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        }
    }

    /// The `AgentCatalog` id, for icons.
    public var catalogID: String {
        switch self {
        case .claude: "claude-code"
        case .codex: "codex"
        case .gemini: "gemini"
        }
    }
}

/// What a live agent session is doing, from the agent's own records rather than the screen.
public enum AgentSessionStatus: String, Codable, Sendable {
    case working
    /// Asking the person: a permission, a question, a dialog.
    case waiting
    /// Done with its turn while a background command still runs.
    case shell
    case idle
    case ended
}

public struct TokenUsage: Codable, Sendable, Hashable {
    /// Fresh input tokens, not counting cache reads or writes.
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

/// A helper agent started by a session (Claude Code subagents, Codex spawned threads).
public struct SubagentInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var running: Bool
    public var tokens: TokenUsage

    public init(id: String, name: String, detail: String = "", running: Bool, tokens: TokenUsage = .init()) {
        self.id = id
        self.name = name
        self.detail = detail
        self.running = running
        self.tokens = tokens
    }
}

/// The agent session running in a pane, as reported by its hooks and transcript.
public struct AgentSessionInfo: Codable, Sendable, Hashable {
    public var tool: AgentTool
    public var sessionID: String
    /// Account the session runs under (its config folder, e.g. `~/.claude` or `~/.codex-work`).
    public var account: String
    public var status: AgentSessionStatus
    /// What it waits for, in the agent's words ("permission", "input needed"…).
    public var waitingFor: String?
    public var model: String?
    public var title: String?
    /// Last tool the agent called, e.g. `Bash`, `Edit`.
    public var lastTool: String?
    public var tokens: TokenUsage
    /// Tokens in the context window at the last turn, and the window size when known.
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var costUSD: Double?
    public var subagents: [SubagentInfo]
    public var startedAt: Date
    public var updatedAt: Date
    /// The folder the session works in.
    public var cwd: String?
    /// Its latest tool calls in words, oldest first.
    public var activity: [AgentActivity]
    /// Shell commands still running, and those that just finished.
    public var shells: [AgentShell]
    /// Its task list (Claude Code todos and tasks, Codex plan).
    public var tasks: [AgentTask]

    public init(tool: AgentTool, sessionID: String, account: String, status: AgentSessionStatus = .idle,
                waitingFor: String? = nil, model: String? = nil, title: String? = nil, lastTool: String? = nil,
                tokens: TokenUsage = .init(), contextTokens: Int? = nil, contextWindow: Int? = nil, costUSD: Double? = nil,
                subagents: [SubagentInfo] = [], startedAt: Date = .now, updatedAt: Date = .now, cwd: String? = nil,
                activity: [AgentActivity] = [], shells: [AgentShell] = [], tasks: [AgentTask] = []) {
        self.cwd = cwd
        self.activity = activity
        self.shells = shells
        self.tasks = tasks
        self.tool = tool
        self.sessionID = sessionID
        self.account = account
        self.status = status
        self.waitingFor = waitingFor
        self.model = model
        self.title = title
        self.lastTool = lastTool
        self.tokens = tokens
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.costUSD = costUSD
        self.subagents = subagents
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var runningSubagents: Int { subagents.filter(\.running).count }
    public var runningShells: [AgentShell] { shells.filter { $0.outcome == .running } }
}

/// One thing an agent did, in words: "Editing Models.swift", "Run the test suite".
public struct AgentActivity: Codable, Sendable, Hashable, Identifiable {
    /// The tool call's id.
    public var id: String
    public var date: Date
    /// SF Symbol name.
    public var symbol: String
    public var text: String

    public init(id: String, date: Date, symbol: String, text: String) {
        self.id = id
        self.date = date
        self.symbol = symbol
        self.text = text
    }
}

/// A shell command an agent started, while it runs and for a little while after.
public struct AgentShell: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case running
        case completed
        case failed
        case killed
    }

    /// The tool call's id.
    public var id: String
    /// The agent's description of the command, or the command itself.
    public var label: String
    public var startedAt: Date
    /// Started in the background (or sent there), so the agent may have moved on.
    public var background: Bool
    public var outcome: Outcome
    public var endedAt: Date?

    public init(id: String, label: String, startedAt: Date, background: Bool, outcome: Outcome = .running, endedAt: Date? = nil) {
        self.id = id
        self.label = label
        self.startedAt = startedAt
        self.background = background
        self.outcome = outcome
        self.endedAt = endedAt
    }
}

/// An item on an agent's task list.
public struct AgentTask: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress
        case completed
    }

    public var id: String
    public var title: String
    public var status: Status

    public init(id: String, title: String, status: Status) {
        self.id = id
        self.title = title
        self.status = status
    }
}

/// Agent time in panes on one day: how long agents worked, waited on you, ran shells or sat idle.
public struct AgentDayStats: Codable, Sendable, Hashable, Identifiable {
    public var id: String { day }
    /// Local date, `yyyy-MM-dd`.
    public var day: String
    public var working: TimeInterval
    public var waiting: TimeInterval
    public var shell: TimeInterval
    public var idle: TimeInterval
    /// Tokens and cost spent that day (not what sessions had spent before it).
    public var tokens: TokenUsage
    public var costUSD: Double
    public var sessionIDs: [String]
    /// Working time per folder, `~`-abbreviated.
    public var projects: [String: TimeInterval]

    public init(day: String, working: TimeInterval = 0, waiting: TimeInterval = 0, shell: TimeInterval = 0, idle: TimeInterval = 0,
                tokens: TokenUsage = .init(), costUSD: Double = 0, sessionIDs: [String] = [], projects: [String: TimeInterval] = [:]) {
        self.day = day
        self.working = working
        self.waiting = waiting
        self.shell = shell
        self.idle = idle
        self.tokens = tokens
        self.costUSD = costUSD
        self.sessionIDs = sessionIDs
        self.projects = projects
    }

    public var sessions: Int { sessionIDs.count }
    public var active: TimeInterval { working + shell }

    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// A session that ran in a pane, for the history.
public struct AgentSessionRecord: Codable, Sendable, Hashable, Identifiable {
    /// The session id.
    public var id: String
    public var tool: AgentTool
    public var title: String?
    public var cwd: String?
    public var account: String
    public var model: String?
    public var startedAt: Date
    /// Nil while it runs.
    public var endedAt: Date?
    public var tokens: TokenUsage
    public var costUSD: Double?
    public var working: TimeInterval

    public init(id: String, tool: AgentTool, title: String? = nil, cwd: String? = nil, account: String, model: String? = nil,
                startedAt: Date, endedAt: Date? = nil, tokens: TokenUsage = .init(), costUSD: Double? = nil, working: TimeInterval = 0) {
        self.id = id
        self.tool = tool
        self.title = title
        self.cwd = cwd
        self.account = account
        self.model = model
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tokens = tokens
        self.costUSD = costUSD
        self.working = working
    }
}

/// Everything the host knows about agents beyond its panes' own sessions.
public struct AgentOverview: Codable, Sendable, Hashable {
    /// Plan limits of the Claude Code and Codex accounts in use.
    public var accounts: [AccountUsage]
    /// Sessions running on the host outside its panes: another terminal, an IDE.
    public var elsewhere: [AgentSessionInfo]
    /// Agent time in panes over the last days, today first.
    public var days: [AgentDayStats]
    /// Sessions that ran in panes over the last days, newest first.
    public var history: [AgentSessionRecord]

    public init(accounts: [AccountUsage] = [], elsewhere: [AgentSessionInfo] = [], days: [AgentDayStats] = [], history: [AgentSessionRecord] = []) {
        self.accounts = accounts
        self.elsewhere = elsewhere
        self.days = days
        self.history = history
    }

    public func today(_ now: Date = .now) -> AgentDayStats? { days.first { $0.day == AgentDayStats.key(now) } }
}

/// How many agents run on a host and what they are doing, panes and elsewhere together.
public struct AgentCounts: Sendable, Hashable {
    public var total = 0
    public var working = 0
    public var waiting = 0
    public var idle = 0

    public init(panes: [PaneInfo], elsewhere: [AgentSessionInfo] = []) {
        for pane in panes where pane.state != .exited {
            if let session = pane.agentSession {
                add(session.status)
            } else if pane.agentID != nil {
                // An agent pane without hooks: its screen is all there is to go on.
                switch pane.state {
                case .working: add(.working)
                case .blocked: add(.waiting)
                default: add(.idle)
                }
            }
        }
        for session in elsewhere { add(session.status) }
    }

    private mutating func add(_ status: AgentSessionStatus) {
        switch status {
        case .working, .shell: working += 1
        case .waiting: waiting += 1
        case .idle: idle += 1
        case .ended: return
        }
        total += 1
    }

    /// "5 agents · 3 working · 1 needs you".
    public var label: String {
        var parts = ["\(total) agent\(total == 1 ? "" : "s")"]
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        return parts.joined(separator: " · ")
    }
}

/// One line of the activity feed: an activity and whose it was.
public struct AgentFeedItem: Sendable, Hashable, Identifiable {
    public var id: String { "\(sessionID)|\(activity.id)" }
    public var activity: AgentActivity
    public var sessionID: String
    public var tool: AgentTool
    /// The session's title, or its folder's name.
    public var who: String
    /// The pane the session runs in; nil for sessions elsewhere.
    public var paneID: String?

    /// Every session's recent activities, newest first.
    public static func merge(panes: [PaneInfo], elsewhere: [AgentSessionInfo], limit: Int = 60) -> [AgentFeedItem] {
        var items: [AgentFeedItem] = []
        let sessions = panes.compactMap { p in p.agentSession.map { ($0, Optional(p.id)) } } + elsewhere.map { ($0, nil as String?) }
        for (session, paneID) in sessions {
            for a in session.activity {
                items.append(AgentFeedItem(activity: a, sessionID: session.sessionID, tool: session.tool, who: session.displayName, paneID: paneID))
            }
        }
        return Array(items.sorted { $0.activity.date > $1.activity.date }.prefix(limit))
    }
}

extension AgentSessionInfo {
    /// Its title, else its folder's name, else the tool.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return tool.name
    }

    /// The same session without what only panes show (shells, tasks) and fewer activities, for small payloads.
    public func trimmed(activities: Int = 3) -> AgentSessionInfo {
        var s = self
        s.activity = Array(activity.suffix(activities))
        s.shells = []
        s.tasks = []
        s.subagents = subagents.filter(\.running)
        return s
    }
}

/// One rolling plan limit: how much of it is used and when it starts over.
public struct UsageWindow: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case fiveHour
        case weekly
    }

    public var kind: Kind
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(kind: Kind, usedPercent: Double, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var label: String {
        switch kind {
        case .fiveHour: "5h"
        case .weekly: "Week"
        }
    }
}

/// An agent account and its plan limits.
public struct AccountUsage: Codable, Sendable, Hashable, Identifiable {
    /// `<tool>:<config folder>`.
    public var id: String
    public var tool: AgentTool
    /// The config folder, `~`-abbreviated.
    public var account: String
    public var plan: String?
    public var windows: [UsageWindow]
    public var fetchedAt: Date

    public init(tool: AgentTool, account: String, plan: String? = nil, windows: [UsageWindow], fetchedAt: Date = .now) {
        self.id = "\(tool.rawValue):\(account)"
        self.tool = tool
        self.account = account
        self.plan = plan
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    public func window(_ kind: UsageWindow.Kind) -> UsageWindow? { windows.first { $0.kind == kind } }

    /// Short account name for lists: `Claude Code`, or `Claude Code · claude-work` for a second account.
    public var displayName: String {
        let folder = (account as NSString).lastPathComponent
        let defaultFolder = tool == .claude ? ".claude" : tool == .codex ? ".codex" : ".gemini"
        return folder == defaultFolder ? tool.name : "\(tool.name) · \(folder.trimmingCharacters(in: CharacterSet(charactersIn: ".")))"
    }
}

// MARK: - Decisions

/// What an approval card asks.
public enum ApprovalKind: String, Codable, Sendable {
    /// An agent wants to open a pane (`pane_spawn`).
    case paneSpawn
    /// An agent wants to run a tool that needs permission.
    case permission
    /// An agent asks the person one or more multiple-choice questions.
    case question
}

/// A button on an approval card.
public struct ApprovalOption: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case allow
        /// Allow, and keep allowing this kind of call.
        case always
        case deny
    }

    public var id: String
    public var label: String
    public var role: Role

    public init(id: String, label: String, role: Role) {
        self.id = id
        self.label = label
        self.role = role
    }

    public static let allow = ApprovalOption(id: "allow", label: "Allow", role: .allow)
    public static let deny = ApprovalOption(id: "deny", label: "Deny", role: .deny)
}

/// One multiple-choice question from an agent (Claude Code's AskUserQuestion).
public struct ApprovalQuestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String { question }
    public var question: String
    public var header: String?
    public var options: [String]
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [String], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// The person's answer to an approval card.
public struct ApprovalAnswer: Codable, Sendable, Hashable {
    /// The chosen `ApprovalOption.id`; nil when the card only had questions.
    public var optionID: String?
    /// Question text → chosen label(s), joined with ", " for multiple choice.
    public var answers: [String: String]
    /// Free text: a reason for a denial, or an "other" answer.
    public var message: String?

    public init(optionID: String? = nil, answers: [String: String] = [:], message: String? = nil) {
        self.optionID = optionID
        self.answers = answers
        self.message = message
    }

    public static let allow = ApprovalAnswer(optionID: ApprovalOption.allow.id)
    public static let deny = ApprovalAnswer(optionID: ApprovalOption.deny.id)
}

// MARK: - Formatting

public enum UsageFormat {
    /// 1234 → "1.2k", 2_500_000 → "2.5M".
    public static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<1_000_000: return String(format: n < 10_000 ? "%.1fk" : "%.0fk", Double(n) / 1000)
        case ..<1_000_000_000: return String(format: n < 100_000_000 ? "%.1fM" : "%.0fM", Double(n) / 1_000_000)
        default: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        }
    }

    /// Time until a reset: "2h 05m", "3d 4h", "12m".
    public static func until(_ date: Date?, from now: Date = .now) -> String? {
        guard let date else { return nil }
        let s = max(0, Int(date.timeIntervalSince(now)))
        if s >= 86_400 { return "\(s / 86_400)d \(s % 86_400 / 3600)h" }
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }
        return "\(s / 60)m"
    }
}
