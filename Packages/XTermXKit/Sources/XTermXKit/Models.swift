import Foundation

/// `/Users/me/project` → `~/project`; works the same on macOS and Linux.
public func tildePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// What runs inside a pane.
public enum PaneKind: String, Codable, Sendable, CaseIterable {
    case shell
    case agent
    case ssh
}

/// Activity state of a pane, derived on the host from its output.
public enum PaneState: String, Codable, Sendable {
    /// Output arrived within the last couple of seconds.
    case working
    /// The program waits for the person (a y/n question, a permission prompt).
    case blocked
    /// Nothing new; at a prompt.
    case idle
    /// The process ended.
    case exited
}

public struct PaneInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    /// A person’s label; automatic terminal and agent titles keep updating underneath it.
    public var customName: String?
    public var displayTitle: String { customName ?? agentSession?.title ?? title }
    public var kind: PaneKind
    /// Agent catalog id (`claude`, `codex`, …) for agent panes.
    public var agentID: String?
    public var cwd: String
    public var state: PaneState
    /// Last non-empty line of the screen, ANSI-free; what the Watch shows.
    public var lastLine: String
    public var cols: Int
    public var rows: Int
    public var createdAt: Date
    public var lastActivity: Date
    public var exitCode: Int32?
    /// Pane that opened this one (agent-opened panes), if any.
    public var parentID: String?
    /// Opened by an agent through `pane_spawn`/`pane_shell` rather than by the person.
    public var openedByAgent: Bool
    /// Spoken-style one-liner an agent left for the phone and Watch (`watch_summary`), with its time.
    public var summary: String?
    public var summaryAt: Date?
    /// The agent said it needs the person (from `watch_summary` or a blocked report).
    public var needsYou: Bool
    /// The Claude Code or Codex session running here, from its hooks and transcript.
    public var agentSession: AgentSessionInfo?

    public init(
        id: String = UUID().uuidString,
        title: String,
        kind: PaneKind,
        agentID: String? = nil,
        cwd: String,
        state: PaneState = .idle,
        lastLine: String = "",
        cols: Int = 120,
        rows: Int = 36,
        createdAt: Date = .now,
        lastActivity: Date = .now,
        exitCode: Int32? = nil,
        parentID: String? = nil,
        openedByAgent: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.agentID = agentID
        self.cwd = cwd
        self.state = state
        self.lastLine = lastLine
        self.cols = cols
        self.rows = rows
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.exitCode = exitCode
        self.parentID = parentID
        self.openedByAgent = openedByAgent
        self.summary = nil
        self.summaryAt = nil
        self.needsYou = false
        self.agentSession = nil
    }

    /// The summary if it is still fresh (agents' summaries expire after 5 minutes).
    public var currentSummary: String? {
        guard let summary, let at = summaryAt, Date.now.timeIntervalSince(at) < 300 else { return nil }
        return summary
    }
}

/// A decision the host asks the person to make: an agent wants to open a pane, run a tool,
/// or asks a question. Every device shows it; the first answer wins.
public struct ApprovalRequest: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var paneID: String?
    public var title: String
    public var detail: String
    public var createdAt: Date
    public var expiresAt: Date
    public var kind: ApprovalKind
    /// The agent asking, when it is Claude Code or Codex.
    public var agentTool: AgentTool?
    /// Buttons, in order; empty for a card that only has questions.
    public var options: [ApprovalOption]
    public var questions: [ApprovalQuestion]
    /// The person may type a reply (a reason to deny, an "other" answer).
    public var allowsMessage: Bool

    public init(id: String = UUID().uuidString, paneID: String?, title: String, detail: String,
                createdAt: Date = .now, timeout: TimeInterval = 120, kind: ApprovalKind = .paneSpawn,
                agentTool: AgentTool? = nil, options: [ApprovalOption] = [.deny, .allow],
                questions: [ApprovalQuestion] = [], allowsMessage: Bool = false) {
        self.id = id
        self.paneID = paneID
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(timeout)
        self.kind = kind
        self.agentTool = agentTool
        self.options = options
        self.questions = questions
        self.allowsMessage = allowsMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id, paneID, title, detail, createdAt, expiresAt, kind, agentTool, options, questions, allowsMessage
    }

    /// Cards from an older host have only Allow / Deny.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        paneID = try c.decodeIfPresent(String.self, forKey: .paneID)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decode(String.self, forKey: .detail)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        kind = try c.decodeIfPresent(ApprovalKind.self, forKey: .kind) ?? .paneSpawn
        agentTool = try c.decodeIfPresent(AgentTool.self, forKey: .agentTool)
        options = try c.decodeIfPresent([ApprovalOption].self, forKey: .options) ?? [.deny, .allow]
        questions = try c.decodeIfPresent([ApprovalQuestion].self, forKey: .questions) ?? []
        allowsMessage = try c.decodeIfPresent(Bool.self, forKey: .allowsMessage) ?? false
    }
}

/// Host machine load, shown in the status bar and on the Watch.
public struct MachineLoad: Codable, Sendable, Hashable {
    public var cpuPercent: Double
    public var memoryUsedGB: Double
    public var memoryTotalGB: Double
    public var livePanes: Int

    public init(cpuPercent: Double, memoryUsedGB: Double, memoryTotalGB: Double, livePanes: Int) {
        self.cpuPercent = cpuPercent
        self.memoryUsedGB = memoryUsedGB
        self.memoryTotalGB = memoryTotalGB
        self.livePanes = livePanes
    }
}

/// An agent the host can launch, as advertised to clients.
public struct AgentDescriptor: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Command line typed into the pane's shell (may carry arguments, e.g. `goose session`).
    public var command: String
    /// Flag that skips the agent's own permission prompts; used only when the person asks for it.
    public var bypassFlag: String?
    public var installed: Bool
    public var symbol: String
    /// Mark color of the agent's icon, 0xRRGGBB.
    public var tint: UInt32

    public init(id: String, name: String, command: String, bypassFlag: String? = nil, installed: Bool = false,
                symbol: String, tint: UInt32 = 0xDBDBDB) {
        self.id = id
        self.name = name
        self.command = command
        self.bypassFlag = bypassFlag
        self.installed = installed
        self.symbol = symbol
        self.tint = tint
    }

    /// The executable looked up on PATH.
    public var executable: String { String(command.split(separator: " ").first ?? "") }
}

/// Empty names restore the automatic title. Names are labels, never terminal input.
public enum PaneNameRules {
    public static let maximumLength = 60
    public static func isValid(_ text: String) -> Bool {
        do { _ = try clean(text); return true } catch { return false }
    }
    public static func clean(_ text: String) throws -> String? {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else { throw InvalidPaneName() }
        let name = text.trimmingCharacters(in: .whitespaces)
        guard name.count <= maximumLength else { throw InvalidPaneName() }
        return name.isEmpty ? nil : name
    }
    public struct InvalidPaneName: LocalizedError {
        public var errorDescription: String? { "Use up to 60 characters on one line." }
    }
}
