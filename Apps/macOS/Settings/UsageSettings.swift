import SwiftUI
import XTermXKit

/// Settings › Usage: the week or month on this Mac, what the title bar shows, and the warning near a plan's limit.
struct UsageSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage(section: .usage) {
            UsageHistoryCard(usage: model.meter.usage, scanning: model.meter.scanning, agents: model.manager.agents)
            TitleBarMetersCard(agents: model.manager.agents)
            LimitWarningCard(agents: model.manager.agents)
        }
    }
}

/// Tokens or cost by the day, a week or a month back, with what each agent spent.
private struct UsageHistoryCard: View {
    let usage: MachineUsage?
    let scanning: Bool
    let agents: [AgentDescriptor]
    @State private var range = UsageRange.week
    @State private var measure = UsageMeasure.tokens
    @State private var hovered: UsageSlot?
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard("Day by day", "Every Claude Code and Codex session on this Mac, in panes or not. Cost is at API list prices, not what a plan bills.") {
            if let usage, !usage.buckets.isEmpty {
                let slots = range.slots(usage)
                let tools = usage.tools
                let shown = hovered.map { [$0] } ?? slots
                HStack {
                    UsagePills(options: [(UsageRange.week, "7 days"), (.month, "30 days")],
                               selection: Binding(get: { range }, set: { range = $0; hovered = nil }))
                    Spacer()
                    UsagePills(options: [(UsageMeasure.tokens, "Tokens"), (.cost, "Cost")], selection: $measure)
                }
                UsageChart(slots: slots, range: range, measure: measure, tools: tools, hovered: $hovered, height: 150)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(tools, id: \.self) { tool in
                        total(tool, UsageSlot.total(shown, tool))
                    }
                    Spacer(minLength: 0)
                }
                Text(hovered.map { range.label($0) } ?? range.phrase.prefix(1).uppercased() + range.phrase.dropFirst())
                    .font(.system(size: 10))
                    .foregroundStyle(theme.chrome.mutedForeground.color)
            } else if scanning || usage == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the transcripts of the last 30 days…").font(.system(size: 11))
                }
                .foregroundStyle(theme.chrome.mutedForeground.color)
            } else {
                Text("Nothing yet. Numbers show up after the first Claude Code or Codex session.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.chrome.mutedForeground.color)
            }
        }
    }

    private func total(_ tool: AgentTool, _ span: UsageSpan) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(tool.tint(theme)).frame(width: 3, height: 26)
            AgentIcon(agents.first { $0.id == tool.catalogID }, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name).font(.system(size: 10)).foregroundStyle(theme.chrome.mutedForeground.color)
                HStack(spacing: 6) {
                    Text(UsageFormat.tokens(span.tokens.total)).font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text(span.costUSD == 0 && !span.fullyPriced ? "no price" : UsageFormat.dollars(span.costUSD) + (span.fullyPriced ? "" : "+"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                }
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(theme.chrome.muted.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// How many plan meters sit in the title bar, and whose come first.
private struct TitleBarMetersCard: View {
    let agents: [AgentDescriptor]
    @AppStorage("xtermx.usage.meters") private var count = 2
    @AppStorage(UsageMeterModel.Key.first) private var pinned = ""
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard("Meters in the title bar", "A ring per plan with the week's share used. Click it for the details.") {
            VStack(alignment: .leading, spacing: 10) {
                row("How many") {
                    UsagePills(options: [(1, "1"), (2, "2"), (3, "3")],
                               selection: Binding(get: { min(max(count, 1), 3) }, set: { count = $0 }))
                }
                row("Show first") {
                    UsagePills(options: [("", "Usual order")] + AgentTool.allCases.map { ($0.rawValue, $0.name) }, selection: $pinned)
                }
                if let tool = AgentTool(rawValue: pinned) {
                    HStack(spacing: 5) {
                        AgentIcon(agents.first { $0.id == tool.catalogID }, size: 12)
                        Text("\(tool.name) plans take the first spots, then the rest.")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(theme.chrome.mutedForeground.color)
                }
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            content()
        }
    }
}

/// The banner on agent panes and the "plan limit" notice once a window passes 90 %.
private struct LimitWarningCard: View {
    let agents: [AgentDescriptor]
    @AppStorage("xtermx.settings.section") private var section = SettingsSection.usage.rawValue
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard("Near the limit",
                     "When a plan's 5-hour or weekly window passes \(Int(UsageLimitAlarm.threshold)) %, its agent panes get a slim banner and one notice goes out. Nothing more until the window starts over.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AgentTool.allCases, id: \.self) { tool in
                    WarnToggle(tool: tool, agent: agents.first { $0.id == tool.catalogID })
                }
                Button {
                    section = SettingsSection.notifications.rawValue
                } label: {
                    Label("Choose where the notice goes", systemImage: "bell.badge")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
            }
        }
    }
}

private struct WarnToggle: View {
    let tool: AgentTool
    let agent: AgentDescriptor?
    @AppStorage private var on: Bool

    init(tool: AgentTool, agent: AgentDescriptor?) {
        self.tool = tool
        self.agent = agent
        _on = AppStorage(wrappedValue: true, UsageMeterModel.Key.warn(tool))
    }

    var body: some View {
        Toggle(isOn: $on) {
            HStack(spacing: 7) {
                AgentIcon(agent, size: 16)
                Text("Warn about \(tool.name)").font(.system(size: 12))
            }
        }
        .toggleStyle(.switch)
    }
}
