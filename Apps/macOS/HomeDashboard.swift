import AppKit
import Charts
import SwiftUI
import XTermXKit

/// An overview above the still-mounted terminals: opening Home never rebuilds a PTY or its feed.
struct HomeDashboard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    private var panes: [PaneInfo] { model.manager.panes }
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Home", systemImage: "house.fill").font(.largeTitle.bold())
                        Text("Your terminals, at a glance.").foregroundStyle(theme.chrome.mutedForeground.color)
                    }
                    Spacer()
                    Button("New terminal") { model.newWorkspace(SpawnRequest(kind: .shell)) }
                        .buttonStyle(.borderedProminent)
                }
                nowSection
                plansSection
                activitySection
                todaySection
            }
            .padding(24)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.chrome.canvas.color)
        .onAppear {
            DispatchQueue.main.async { if model.homeVisible { NSApp.keyWindow?.makeFirstResponder(nil) } }
        }
        .task { await model.meter.refreshWhileVisible() }
    }

    private var nowSection: some View {
        let summary = PaneActivitySummary(panes: panes)
        return VStack(alignment: .leading, spacing: 12) {
            heading("Right now", detail: "Live terminal activity on this Mac", symbol: "sparkles")
            LazyVGrid(columns: columns, spacing: 10) {
                metric("In motion", value: String(summary.working), symbol: "waveform.path", color: StateColors.working.color)
                metric("Needs you", value: String(summary.waiting), symbol: "hand.raised.fill", color: StateColors.blocked.color)
                metric("At a prompt", value: String(summary.idle), symbol: "pause.circle", color: theme.chrome.primary.color)
                metric("Ended", value: String(summary.ended), symbol: "checkmark.circle", color: theme.chrome.mutedForeground.color)
            }
            if panes.isEmpty {
                Text("Open a terminal to start seeing activity here.").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(panes) { pane in
                        let state = PaneActivitySummary.state(of: pane)
                        Button { model.focus(pane.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                StateDot(state, size: 9).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pane.displayTitle).font(.headline).lineLimit(1)
                                    Text(pane.agentSession?.activity.last?.text ?? tildePath(pane.cwd))
                                        .font(.caption).foregroundStyle(theme.chrome.mutedForeground.color).lineLimit(2)
                                    Text(LocalizedStringKey(state.label)).font(.caption2).foregroundStyle(state.color)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
                                .padding(12).background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var plansSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Plan usage", detail: "Plan limits and this Mac’s usage history", symbol: "chart.xyaxis.line")
            let accounts = AccountUsage.meterOrder(model.manager.overview.accounts, first: UsageMeterModel.pinned)
            if accounts.isEmpty {
                Text("Plan limits appear after the agent reports them.").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(accounts) { account in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(account.displayName).font(.headline)
                            if let window = account.headline, let percent = window.percent() {
                                HStack {
                                    Text("\(Int(percent.rounded()))% used").monospacedDigit()
                                    Spacer()
                                    Text(LocalizedStringKey(window.kind == .weekly ? "Week" : "5 hours")).foregroundStyle(.secondary)
                                }.font(.caption)
                                ProgressView(value: min(max(percent, 0), 100), total: 100).tint(UsageLevel(percent: percent).color)
                                if let left = UsageFormat.until(window.resetsAt) { Text("Resets in \(left)").font(.caption2).foregroundStyle(.secondary) }
                            } else { Text("Waiting for fresh limits").font(.caption).foregroundStyle(.secondary) }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if let usage = model.meter.usage, !usage.buckets.isEmpty {
                UsageTrendCard(usage: usage, agents: model.manager.agents)
            } else {
                Label(model.meter.scanning ? "Reading usage history…" : "No usage history yet", systemImage: "chart.bar")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100)
                    .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text("Activity updates live. Usage refreshes every 15 seconds while this view is open.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Usage settings") {
                    UserDefaults.standard.set(SettingsSection.usage.rawValue, forKey: "xtermx.settings.section")
                    openSettings()
                }
            }
        }
    }

    private var activitySection: some View {
        let feed = AgentFeedItem.merge(panes: panes, elsewhere: model.manager.overview.elsewhere, limit: 10)
        return VStack(alignment: .leading, spacing: 12) {
            heading("Recent activity", detail: "The latest actions reported by your agents", symbol: "bolt.horizontal.circle")
            if feed.isEmpty {
                Text("Agent activity appears here when reported. Terminal states above are already live.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(feed) { item in
                Button { if let pane = item.paneID { model.focus(pane) } } label: {
                    AgentFeedRow(item).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(item.paneID == nil)
            }
        }
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Today’s snapshot", detail: "All measured Claude Code and Codex sessions on this Mac", symbol: "sun.max")
            if let usage = model.meter.usage {
                let today = usage.lastDays(1)
                LazyVGrid(columns: columns, spacing: 10) {
                    metric("Tokens today", value: UsageFormat.tokens(today.tokens.total), symbol: "number", color: theme.chrome.primary.color)
                    metric("Turns today", value: String(today.turns), symbol: "bubble.left.and.bubble.right", color: theme.chrome.activity.color)
                    metric("Devices online", value: String(model.server.devices.count), symbol: "iphone", color: StateColors.done.color)
                }
                if let day = model.manager.overview.today() { AgentDayView(day) }
                Text("Plan percentages come from the provider. Token graphs come from local transcripts; API price estimates are not subscription charges.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Usage read at \(usage.scannedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else { Text("Reading usage history…").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func heading(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.title3.bold())
            Text(detail).font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
        }
    }
    private func metric(_ title: LocalizedStringKey, value: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).foregroundStyle(color)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && symbol == "waveform.path" && PaneActivitySummary(panes: panes).working > 0)
                Spacer()
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.18)))
    }
}
