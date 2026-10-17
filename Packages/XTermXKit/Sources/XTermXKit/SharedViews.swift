#if canImport(SwiftUI)
import SwiftUI

/// The rounded tile with an agent's mark, as in the launcher.
public struct AgentIcon: View {
    let agent: AgentDescriptor?
    let size: CGFloat

    public init(_ agent: AgentDescriptor?, size: CGFloat = 16) {
        self.agent = agent
        self.size = size
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(RGB(0x1C1C1E).color)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: agent?.symbol ?? "terminal")
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundStyle(agent.map { RGB($0.tint).color } ?? RGB(0xDBDBDB).color)
            }
    }
}

/// A small state dot; blocked panes pulse.
public struct StateDot: View {
    let state: PaneState
    let size: CGFloat
    @State private var pulse = false

    public init(_ state: PaneState, size: CGFloat = 7) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .opacity(state == .blocked ? (pulse ? 1 : 0.55) : 1)
            .overlay {
                if state == .working {
                    Circle().stroke(state.color.opacity(0.5), lineWidth: 1).scaleEffect(pulse ? 2 : 1).opacity(pulse ? 0 : 1)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: state == .blocked ? 1.4 : 1).repeatForever(autoreverses: state == .blocked)) {
                    pulse = true
                }
            }
            .id(state)
            .accessibilityLabel(state.label)
    }
}

/// "Needs you" card for one request: an agent's permission (allow once / always / deny),
/// its multiple-choice questions, or a pane it wants to open. Optional typed reply.
public struct ApprovalCard: View {
    let request: ApprovalRequest
    let respond: (ApprovalAnswer) -> Void
    @State private var picks: [String: [String]] = [:]
    @State private var message = ""
    @Environment(\.appTheme) private var theme

    public init(_ request: ApprovalRequest, respond: @escaping (ApprovalAnswer) -> Void) {
        self.request = request
        self.respond = respond
    }

    private var typed: String? {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(request.title, systemImage: request.kind == .question ? "questionmark.bubble.fill" : "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StateColors.blocked.color)
                .lineLimit(2)
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 11, design: request.kind == .permission ? .monospaced : .default))
                    .foregroundStyle(theme.chrome.mutedForeground.color).lineLimit(6)
            }
            ForEach(request.questions) { q in question(q) }
            if request.allowsMessage {
                TextField(request.kind == .question ? "Other answer…" : "Reason, if you deny (optional)", text: $message, axis: .vertical)
                    .font(.system(size: 11))
                    .lineLimit(1...3)
            }
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(StateColors.blocked.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(StateColors.blocked.color).frame(width: 2) }
    }

    @ViewBuilder private func question(_ q: ApprovalQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q.question).font(.system(size: 11, weight: .medium))
            ForEach(q.options, id: \.self) { option in
                let chosen = picks[q.question, default: []].contains(option)
                Button {
                    pick(option, in: q)
                } label: {
                    Label(option, systemImage: chosen ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                      : (q.multiSelect ? "square" : "circle"))
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(request.options) { option in
            let button = Button(option.label, role: option.role == .deny ? .destructive : nil) {
                respond(ApprovalAnswer(optionID: option.id, message: typed))
            }
            if option.role == .allow { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
        if !request.questions.isEmpty {
            Button("Answer") { respond(ApprovalAnswer(answers: picks.mapValues { $0.joined(separator: ", ") }, message: typed)) }
                .buttonStyle(.borderedProminent)
                .disabled(picks.isEmpty && typed == nil)
            Button("Dismiss", role: .destructive) { respond(ApprovalAnswer()) }.buttonStyle(.bordered)
        }
    }

    /// One choice per question unless it allows several; a single one-choice question answers at once.
    private func pick(_ option: String, in q: ApprovalQuestion) {
        var chosen = picks[q.question, default: []]
        if q.multiSelect {
            if let i = chosen.firstIndex(of: option) { chosen.remove(at: i) } else { chosen.append(option) }
        } else {
            chosen = [option]
        }
        picks[q.question] = chosen.isEmpty ? nil : chosen
        if request.questions.count == 1, !q.multiSelect, typed == nil {
            respond(ApprovalAnswer(answers: [q.question: option]))
        }
    }
}

/// A Claude Code or Codex session's one-line vitals: model · tokens · subagents.
public struct AgentSessionSummary: View {
    let session: AgentSessionInfo
    @Environment(\.appTheme) private var theme

    public init(_ session: AgentSessionInfo) { self.session = session }

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(session.paneState.color).frame(width: 6, height: 6)
            Text(session.statusLabel)
            if let model = session.model { Text(Self.shortModel(model)).lineLimit(1) }
            Text("\(UsageFormat.tokens(session.tokens.total)) tok")
            if session.runningSubagents > 0 {
                Label("\(session.runningSubagents)", systemImage: "person.2.fill").labelStyle(.titleAndIcon)
            }
            if let cost = session.costUSD, cost > 0 { Text(String(format: "$%.2f", cost)) }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(theme.chrome.mutedForeground.color)
        .lineLimit(1)
    }

    /// `claude-opus-5-5-20261001` → `opus-5-5`; `gpt-5.5-codex` stays.
    static func shortModel(_ model: String) -> String {
        var m = model.hasPrefix("claude-") ? String(model.dropFirst(7)) : model
        if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) { m.removeSubrange(r) }
        return m
    }
}

extension AgentSessionInfo {
    /// The pane color that matches this status.
    public var paneState: PaneState {
        switch status {
        case .working, .shell: .working
        case .waiting: .blocked
        case .idle: .idle
        case .ended: .exited
        }
    }

    public var statusLabel: String {
        switch status {
        case .working: "working"
        case .waiting: waitingFor.map { "needs you: \($0)" } ?? "needs you"
        case .shell: "shell running"
        case .idle: "idle"
        case .ended: "ended"
        }
    }
}

/// An account's plan limits as two bars: the 5-hour session and the week.
public struct AccountUsageView: View {
    let account: AccountUsage
    let compact: Bool
    @Environment(\.appTheme) private var theme

    public init(_ account: AccountUsage, compact: Bool = false) {
        self.account = account
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(account.displayName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if let plan = account.plan { Text(plan).font(.system(size: 9)).foregroundStyle(theme.chrome.mutedForeground.color) }
                Spacer()
                if Date.now.timeIntervalSince(account.fetchedAt) > 1800 {
                    Text("outdated").font(.system(size: 9)).foregroundStyle(theme.chrome.mutedForeground.color)
                }
            }
            ForEach(account.windows, id: \.kind) { w in
                // A window that has reset since the numbers were taken is unknown until new numbers come.
                let reset = w.resetsAt.map { $0 < .now } ?? false
                HStack(spacing: 6) {
                    Text(w.label).font(.system(size: 9, weight: .medium)).frame(width: compact ? 26 : 30, alignment: .leading)
                    ProgressView(value: reset ? 0 : min(max(w.usedPercent, 0), 100), total: 100)
                        .tint(w.usedPercent >= 90 ? StateColors.blocked.color : w.usedPercent >= 70 ? .orange : StateColors.working.color)
                    Text(reset ? "–" : "\(Int(w.usedPercent.rounded()))%").font(.system(size: 9, design: .monospaced)).frame(width: 30, alignment: .trailing)
                    if !compact, let left = UsageFormat.until(w.resetsAt) {
                        Text("↻ \(left)").font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.chrome.mutedForeground.color).frame(width: 58, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// One-line pane summary used in lists on every platform.
public struct PaneRow: View {
    let pane: PaneInfo
    let agent: AgentDescriptor?
    @Environment(\.appTheme) private var theme

    public init(_ pane: PaneInfo, agent: AgentDescriptor?) {
        self.pane = pane
        self.agent = agent
    }

    public var body: some View {
        HStack(spacing: 8) {
            AgentIcon(agent, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if pane.currentSummary == nil, let session = pane.agentSession {
                    AgentSessionSummary(session)
                } else {
                    Text(pane.currentSummary ?? (pane.lastLine.isEmpty ? (pane.cwd as NSString).abbreviatingWithTildeInPath : pane.lastLine))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if pane.needsYou { Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(StateColors.blocked.color) }
            StateDot(pane.state)
        }
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            if pane.state == .blocked { Rectangle().fill(StateColors.blocked.color).frame(width: 2).offset(x: -6) }
        }
    }
}
// MARK: - Agents across the host

/// "11 agents · 2 working · 1 needs you" as a compact line with dots.
public struct AgentCountsView: View {
    let counts: AgentCounts
    @Environment(\.appTheme) private var theme

    public init(_ counts: AgentCounts) { self.counts = counts }

    public var body: some View {
        HStack(spacing: 8) {
            Label("\(counts.total)", systemImage: "cpu").labelStyle(.titleAndIcon)
            if counts.working > 0 { dot(StateColors.working.color, "\(counts.working) working") }
            if counts.waiting > 0 { dot(StateColors.blocked.color, counts.waiting == 1 ? "1 needs you" : "\(counts.waiting) need you") }
            if counts.idle > 0 { dot(StateColors.idle.color, "\(counts.idle) idle") }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }

    private func dot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }
}

/// One line of the activity feed: what, who, when.
public struct AgentFeedRow: View {
    let item: AgentFeedItem
    @Environment(\.appTheme) private var theme

    public init(_ item: AgentFeedItem) { self.item = item }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: item.activity.symbol).font(.system(size: 10)).frame(width: 14)
                .foregroundStyle(theme.chrome.mutedForeground.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.activity.text).font(.system(size: 11)).lineLimit(2)
                Text(item.who).font(.system(size: 9)).foregroundStyle(theme.chrome.mutedForeground.color).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(item.activity.date, style: .time).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(theme.chrome.mutedForeground.color)
        }
    }
}

/// A shell command an agent runs: a ticking timer while it runs, how it ended after.
public struct AgentShellRow: View {
    let shell: AgentShell
    @Environment(\.appTheme) private var theme

    public init(_ shell: AgentShell) { self.shell = shell }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color).frame(width: 14)
            Text(shell.label).font(.system(size: 10, design: .monospaced)).lineLimit(1)
            Spacer(minLength: 4)
            Group {
                if shell.outcome == .running {
                    Text(timerInterval: shell.startedAt...Date.distantFuture, countsDown: false)
                } else {
                    Text(Self.duration((shell.endedAt ?? .now).timeIntervalSince(shell.startedAt)))
                }
            }
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.chrome.mutedForeground.color)
            .frame(minWidth: 40, alignment: .trailing)
        }
    }

    private var symbol: String {
        switch shell.outcome {
        case .running: "hourglass"
        case .completed: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .killed: "stop.circle"
        }
    }

    private var color: Color {
        switch shell.outcome {
        case .running: StateColors.working.color
        case .completed: StateColors.done.color
        case .failed: StateColors.blocked.color
        case .killed: StateColors.idle.color
        }
    }

    /// 75 → "1m 15s", 4000 → "1h 06m".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%dh %02dm", s / 3600, s % 3600 / 60) }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}

/// An agent's task list, with how much of it is done.
public struct AgentTaskList: View {
    let tasks: [AgentTask]
    let limit: Int
    @Environment(\.appTheme) private var theme

    public init(_ tasks: [AgentTask], limit: Int = 8) {
        self.tasks = tasks
        self.limit = limit
    }

    public var body: some View {
        let done = tasks.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Tasks \(done)/\(tasks.count)").font(.system(size: 9, weight: .semibold))
                ProgressView(value: Double(done), total: Double(max(tasks.count, 1)))
            }
            // The one in progress and what follows matter more than what is done.
            let shown = tasks.filter { $0.status != .completed }.prefix(limit)
            ForEach(Array(shown)) { task in
                HStack(spacing: 5) {
                    Image(systemName: task.status == .inProgress ? "circle.dotted.circle" : "circle")
                        .font(.system(size: 9))
                        .foregroundStyle(task.status == .inProgress ? StateColors.working.color : theme.chrome.mutedForeground.color)
                    Text(task.title).font(.system(size: 10, weight: task.status == .inProgress ? .medium : .regular)).lineLimit(1)
                }
            }
        }
    }
}

/// Agent time in panes on one day.
public struct AgentDayView: View {
    let day: AgentDayStats
    @Environment(\.appTheme) private var theme

    public init(_ day: AgentDayStats) { self.day = day }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                stat("Working", AgentShellRow.duration(day.active))
                stat("Waited on you", AgentShellRow.duration(day.waiting))
                stat("Sessions", "\(day.sessions)")
            }
            HStack(spacing: 10) {
                stat("Tokens", UsageFormat.tokens(day.tokens.total))
                if day.costUSD > 0 { stat("Cost", String(format: "$%.2f", day.costUSD)) }
                stat("Output", UsageFormat.tokens(day.tokens.output))
            }
            let projects = day.projects.sorted { $0.value > $1.value }.prefix(4)
            ForEach(Array(projects), id: \.key) { project, seconds in
                HStack {
                    Text((project as NSString).lastPathComponent).font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    Text(AgentShellRow.duration(seconds)).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(label).font(.system(size: 9)).foregroundStyle(theme.chrome.mutedForeground.color)
        }
    }
}

/// A session outside the panes (or one in the history): who, where, and its vitals.
public struct AgentElsewhereRow: View {
    let session: AgentSessionInfo
    let agent: AgentDescriptor?
    @Environment(\.appTheme) private var theme

    public init(_ session: AgentSessionInfo, agent: AgentDescriptor?) {
        self.session = session
        self.agent = agent
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentIcon(agent, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let cwd = session.cwd, session.title != nil {
                        Text((cwd as NSString).lastPathComponent).font(.system(size: 10))
                            .foregroundStyle(theme.chrome.mutedForeground.color).lineLimit(1)
                    }
                }
                AgentSessionSummary(session)
                if let last = session.activity.last {
                    Label(last.text, systemImage: last.symbol).font(.system(size: 10)).lineLimit(1)
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                }
            }
        }
    }
}

/// A past (or running) session in panes, from the history.
public struct AgentHistoryRow: View {
    let record: AgentSessionRecord
    @Environment(\.appTheme) private var theme

    public init(_ record: AgentSessionRecord) { self.record = record }

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(record.endedAt == nil ? StateColors.working.color : StateColors.exited.color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title ?? record.tool.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text([record.cwd.map { ($0 as NSString).lastPathComponent }, record.model.map(AgentSessionSummary.shortModel),
                      "\(UsageFormat.tokens(record.tokens.total)) tok", record.costUSD.flatMap { $0 > 0 ? String(format: "$%.2f", $0) : nil }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.chrome.mutedForeground.color).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(record.startedAt, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.system(size: 9))
                Text(AgentShellRow.duration(record.working)).font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(theme.chrome.mutedForeground.color)
        }
    }
}

// MARK: - Usage

extension UsageLevel {
    /// Calm while there is room, orange past 70 %, red past 90 %.
    public var color: Color {
        switch self {
        case .unknown: StateColors.idle.color
        case .normal: StateColors.done.color
        case .high: .orange
        case .critical: StateColors.blocked.color
        }
    }
}

/// A plan limit as a ring that fills as it is used; nil draws only the track.
public struct UsageRing<Center: View>: View {
    let percent: Double?
    let size: CGFloat
    let lineWidth: CGFloat
    let center: Center
    @Environment(\.appTheme) private var theme

    public init(_ percent: Double?, size: CGFloat = 14, lineWidth: CGFloat? = nil, @ViewBuilder center: () -> Center) {
        self.percent = percent
        self.size = size
        self.lineWidth = lineWidth ?? max(2, size / 6)
        self.center = center()
    }

    public var body: some View {
        let level = UsageLevel(percent: percent)
        ZStack {
            Circle().stroke(theme.chrome.mutedForeground.color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent ?? 0, 0), 100) / 100))
                .stroke(level.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .frame(width: size, height: size)
        .padding(lineWidth / 2)
        .animation(.easeOut(duration: 0.4), value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(percent.map { "\(Int($0.rounded())) percent used" } ?? "unknown")
    }
}

extension UsageRing where Center == EmptyView {
    public init(_ percent: Double?, size: CGFloat = 14, lineWidth: CGFloat? = nil) {
        self.init(percent, size: size, lineWidth: lineWidth) { EmptyView() }
    }
}
#endif
