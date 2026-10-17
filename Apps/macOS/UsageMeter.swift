import SwiftUI
import XTermXHost
import XTermXKit

/// This Mac's usage from every Claude Code and Codex transcript, read again every two minutes and on Refresh.
@Observable @MainActor
final class UsageMeterModel {
    private(set) var usage: MachineUsage?
    private(set) var scanning = false
    @ObservationIgnored private let scanner = UsageScanner()
    @ObservationIgnored private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let scanner = scanner
        Task {
            // The first scan reads every transcript of the last 30 days; later ones only what was appended.
            let result = await Task.detached(priority: .utility) { scanner.scan() }.value
            usage = result
            scanning = false
        }
    }

    /// Incremental transcript reads happen off the main actor, only while an overview is visible.
    func refreshWhileVisible() async {
        refresh()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: Plan limits

    enum Key {
        /// Settings › Usage: the provider whose meters come first (an `AgentTool` raw value, "" for the usual order).
        static let first = "xtermx.usage.first"
        /// Windows already announced, so a relaunch doesn't announce them again.
        static let alarm = "xtermx.usage.alarm"
        /// Settings › Usage: warn near the limit, per provider (on unless turned off).
        static func warn(_ tool: AgentTool) -> String { "xtermx.usage.warn.\(tool.rawValue)" }
    }

    /// Banners closed by hand: alert id and reset time, so the next window shows its own.
    private(set) var dismissed: Set<String> = []
    @ObservationIgnored private var alarm: UsageLimitAlarm = {
        guard let data = UserDefaults.standard.data(forKey: Key.alarm) else { return UsageLimitAlarm() }
        return (try? JSONDecoder().decode(UsageLimitAlarm.self, from: data)) ?? UsageLimitAlarm()
    }()

    static func warns(_ tool: AgentTool) -> Bool {
        UserDefaults.standard.object(forKey: Key.warn(tool)) as? Bool ?? true
    }

    static var pinned: AgentTool? { AgentTool(rawValue: UserDefaults.standard.string(forKey: Key.first) ?? "") }

    /// New plan limit numbers came in: the windows that just passed 90 %, once each, as notices.
    func limitNotices(_ accounts: [AccountUsage], now: Date = .now) -> [AgentNotice] {
        let watched = accounts.filter { Self.warns($0.tool) }
        let before = alarm
        let fresh = alarm.newAlerts(watched, now: now)
        if alarm != before, let data = try? JSONEncoder().encode(alarm) { UserDefaults.standard.set(data, forKey: Key.alarm) }
        return fresh.map { AgentNoticeText.planLimit($0.tool, percent: Int($0.percent.rounded(.down)), detail: $0.detail(now: now)) }
    }

    /// The fullest window past 90 % of the account a pane's agent runs under, unless its banner was closed.
    func alert(for session: AgentSessionInfo, accounts: [AccountUsage], now: Date = .now) -> UsageLimitAlert? {
        guard Self.warns(session.tool) else { return nil }
        let mine = accounts.filter { $0.tool == session.tool && $0.account == session.account }
        return UsageLimitAlarm.alerts(mine, now: now).first { !dismissed.contains(Self.dismissKey($0)) }
    }

    func dismiss(_ alert: UsageLimitAlert) { dismissed.insert(Self.dismissKey(alert)) }

    private static func dismissKey(_ alert: UsageLimitAlert) -> String {
        "\(alert.id)|\(Int((alert.resetsAt?.timeIntervalSince1970 ?? 0) / 3600))"
    }
}

// MARK: - Title bar

/// One small ring per plan in the title bar: the week's share used. Click for the details.
struct UsageMeters: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    /// Settings › Usage: how many plans show here (1–3).
    @AppStorage("xtermx.usage.meters") private var count = 2
    /// Settings › Usage: the provider shown first.
    @AppStorage(UsageMeterModel.Key.first) private var pinned = ""
    @State private var open = false

    var body: some View {
        let ordered = AccountUsage.meterOrder(model.manager.overview.accounts, first: AgentTool(rawValue: pinned))
        let accounts = Array(ordered.prefix(min(max(count, 1), 3)))
        if !accounts.isEmpty || model.meter.usage?.buckets.isEmpty == false {
            Button { open.toggle() } label: {
                HStack(spacing: 9) {
                    if accounts.isEmpty {
                        Label("Usage", systemImage: "gauge.with.dots.needle.33percent")
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                    }
                    ForEach(accounts) { meter($0) }
                }
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(theme.chrome.accent.color, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(accounts.isEmpty ? "Tokens and cost on this Mac" : accounts.map(Self.hint).joined(separator: "\n"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                UsagePopover().frame(width: 344)
            }
        }
    }

    private func meter(_ account: AccountUsage) -> some View {
        let percent = account.headline?.percent()
        let level = UsageLevel(percent: percent)
        return HStack(spacing: 4) {
            AgentIcon(model.manager.agents.first { $0.id == account.tool.catalogID }, size: 13)
            UsageRing(percent, size: 10, lineWidth: 2.5)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(level == .high || level == .critical ? level.color : theme.chrome.mutedForeground.color)
        }
    }

    /// "Claude Code · 64% of the week used · resets in 2d 3h".
    static func hint(_ account: AccountUsage) -> String {
        guard let w = account.headline else { return account.displayName }
        let span = w.kind == .weekly ? "the week" : "the 5 hours"
        guard let p = w.percent() else { return "\(account.displayName) · \(span) started over" }
        var text = "\(account.displayName) · \(Int(p.rounded()))% of \(span) used"
        if let left = UsageFormat.until(w.resetsAt) { text += " · resets in \(left)" }
        return text
    }
}

// MARK: - Popover

struct UsagePopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @AppStorage(UsageMeterModel.Key.first) private var pinned = ""

    var body: some View {
        let accounts = AccountUsage.meterOrder(model.manager.overview.accounts, first: AgentTool(rawValue: pinned))
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let usage = model.meter.usage, !usage.buckets.isEmpty {
                    UsageTrendCard(usage: usage, agents: model.manager.agents)
                }
                if accounts.isEmpty {
                    Text("Plan limits show up here once Claude Code has run in an XTermX pane, or Codex anywhere on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(accounts) { account in
                    UsageAccountCard(account: account, usage: model.meter.usage,
                                     agent: model.manager.agents.first { $0.id == account.tool.catalogID })
                }
                ThisMacCard(usage: model.meter.usage, agents: model.manager.agents)
            }
            .padding(12)
        }
        .task { await model.meter.refreshWhileVisible() }
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.chrome.popover.color)
        .foregroundStyle(theme.chrome.foreground.color)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(theme.chrome.primary.color)
            Text("Usage").font(.system(size: 13, weight: .semibold))
            Spacer()
            Group {
                if model.meter.scanning {
                    Text("Reading transcripts…")
                } else if let at = model.meter.usage?.scannedAt {
                    Text("Updated \(Text(at, style: .relative)) ago")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(theme.chrome.mutedForeground.color)
            Button { model.meter.refresh() } label: {
                Group {
                    if model.meter.scanning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                    }
                }
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.meter.scanning)
            .help("Read the transcripts again")
        }
    }
}

/// A plan: the 5-hour and weekly rings side by side, and what else is known about it.
private struct UsageAccountCard: View {
    let account: AccountUsage
    let usage: MachineUsage?
    let agent: AgentDescriptor?
    @State private var expanded = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentIcon(agent, size: 18)
                Text(account.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let plan = account.plan, !plan.isEmpty {
                    Text(plan.capitalized)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(theme.chrome.accent.color, in: Capsule())
                }
                Spacer(minLength: 4)
                if Date.now.timeIntervalSince(account.fetchedAt) > 1800 {
                    Label("Outdated", systemImage: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                        .help("These numbers are from \(account.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            HStack(alignment: .center, spacing: 14) {
                gauge(.fiveHour, "5 hours")
                gauge(.weekly, "Week")
                Spacer(minLength: 0)
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(expanded ? "Less" : "More")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.chrome.mutedForeground.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { details }
        }
        .padding(12)
        .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.chrome.border.color))
    }

    @ViewBuilder
    private func gauge(_ kind: UsageWindow.Kind, _ label: String) -> some View {
        if let w = account.window(kind) {
            let percent = w.percent()
            HStack(spacing: 8) {
                UsageRing(percent, size: 38, lineWidth: 5) {
                    Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 11, weight: .medium))
                    Text(Self.resets(w, percent: percent))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                }
            }
        }
    }

    static func resets(_ w: UsageWindow, percent: Double?) -> String {
        if percent == nil { return "Started over" }
        return UsageFormat.until(w.resetsAt).map { "Resets in \($0)" } ?? "No reset time"
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            row("Folder", account.account)
            row("Numbers from", account.fetchedAt.formatted(date: .abbreviated, time: .shortened))
            ForEach(account.windows, id: \.kind) { w in
                if let at = w.resetsAt {
                    row(w.kind == .weekly ? "Week resets" : "5 hours reset", at.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                }
            }
            if let usage {
                let tool = account.tool
                row("This Mac, 5 h", UsageFormat.tokens(usage.lastFiveHours(tool).tokens.total) + " tokens")
                row("This Mac, 7 days", UsageFormat.tokens(usage.lastDays(7, tool).tokens.total) + " tokens")
                let month = usage.lastDays(30, tool)
                row("API price, 30 days", month.costUSD > 0 ? UsageFormat.dollars(month.costUSD) + (month.fullyPriced ? "" : " (part)") : "No price")
            }
        }
        .font(.system(size: 10))
        .padding(.leading, 12)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(theme.chrome.mutedForeground.color)
            Text(value).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// Every session on this Mac, in panes or not: tokens and what they would cost at API prices.
private struct ThisMacCard: View {
    let usage: MachineUsage?
    let agents: [AgentDescriptor]
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer").foregroundStyle(theme.chrome.mutedForeground.color)
                Text("This Mac").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("All sessions, in panes or not").font(.system(size: 9)).foregroundStyle(theme.chrome.mutedForeground.color)
            }
            if let usage {
                let tools = usage.tools
                tiles("Tokens", [("5 hours", usage.lastFiveHours()), ("7 days", usage.lastDays(7)), ("30 days", usage.lastDays(30))], tools: tools) { span in
                    UsageFormat.tokens(span.tokens.total)
                } byTool: { label, tool in
                    let span = label == "5 hours" ? usage.lastFiveHours(tool) : usage.lastDays(label == "7 days" ? 7 : 30, tool)
                    return UsageFormat.tokens(span.tokens.total)
                }
                tiles("At API prices", [("Today", usage.lastDays(1)), ("7 days", usage.lastDays(7)), ("30 days", usage.lastDays(30))], tools: tools) { span in
                    span.costUSD == 0 && !span.fullyPriced ? "–" : UsageFormat.dollars(span.costUSD)
                } byTool: { label, tool in
                    let span = usage.lastDays(label == "Today" ? 1 : label == "7 days" ? 7 : 30, tool)
                    return span.tokens.total == 0 ? "–" : span.costUSD == 0 && !span.fullyPriced ? "no price" : UsageFormat.dollars(span.costUSD)
                }
                footnote(usage.lastDays(30))
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the transcripts of the last 30 days…").font(.system(size: 11))
                }
                .foregroundStyle(theme.chrome.mutedForeground.color)
            }
        }
        .padding(12)
        .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.chrome.border.color))
    }

    private func tiles(_ title: String, _ spans: [(String, UsageSpan)], tools: [AgentTool], value: @escaping (UsageSpan) -> String,
                       byTool: @escaping (String, AgentTool) -> String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.chrome.mutedForeground.color)
            HStack(spacing: 6) {
                ForEach(spans, id: \.0) { label, span in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(value(span)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(label).font(.system(size: 10)).foregroundStyle(theme.chrome.mutedForeground.color)
                        if tools.count > 1 {
                            ForEach(tools, id: \.self) { tool in
                                HStack(spacing: 3) {
                                    AgentIcon(agents.first { $0.id == tool.catalogID }, size: 10)
                                    Text(byTool(label, tool)).font(.system(size: 9, design: .monospaced)).lineLimit(1)
                                }
                                .foregroundStyle(theme.chrome.mutedForeground.color)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(theme.chrome.muted.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func footnote(_ month: UsageSpan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("At API list prices, not what a subscription is billed. Claude prices as of \(Self.day(UsagePrices.claudeAsOf)), OpenAI as of \(Self.day(UsagePrices.codexAsOf)).")
            if !month.fullyPriced {
                let models = month.unpricedModels.sorted()
                let names = models.prefix(3).joined(separator: ", ") + (models.count > 3 ? " and \(models.count - 3) more" : "")
                Text("No price yet for \(names): their \(UsageFormat.tokens(month.unpricedTokens)) tokens are left out of the cost.")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(theme.chrome.mutedForeground.color)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "2026-10-06" → "Oct 6, 2026".
    static func day(_ iso: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)?.formatted(date: .abbreviated, time: .omitted) ?? iso
    }
}
