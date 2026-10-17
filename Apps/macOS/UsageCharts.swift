import Charts
import SwiftUI
import XTermXKit

/// What a usage chart counts.
enum UsageMeasure: String, CaseIterable, Identifiable {
    case tokens, cost

    var id: String { rawValue }
    var title: String { self == .tokens ? "Tokens" : "Cost" }

    func value(_ span: UsageSpan) -> Double {
        self == .tokens ? Double(span.tokens.total) : span.costUSD
    }

    func format(_ value: Double) -> String {
        switch self {
        case .tokens: UsageFormat.tokens(Int(value.rounded()))
        case .cost: value > 0 && value < 10 ? UsageFormat.dollars(value) : "$" + UsageFormat.tokens(Int(value.rounded()))
        }
    }
}

/// How far back a usage chart looks.
enum UsageRange: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var short: String {
        switch self {
        case .day: "24 h"
        case .week: "7 d"
        case .month: "30 d"
        }
    }

    var phrase: String {
        switch self {
        case .day: "in the last 24 hours"
        case .week: "in the last 7 days"
        case .month: "in the last 30 days"
        }
    }

    var unit: Calendar.Component { self == .day ? .hour : .day }

    func slots(_ usage: MachineUsage, now: Date = .now) -> [UsageSlot] {
        switch self {
        case .day: usage.hourly(24, now: now)
        case .week: usage.daily(7, now: now)
        case .month: usage.daily(30, now: now)
        }
    }

    /// "Tue 14:00" for an hour, "Oct 12" for a day.
    func label(_ slot: UsageSlot) -> String {
        self == .day ? slot.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : slot.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

extension AgentTool {
    /// The series color of this tool in usage charts, from the window theme.
    func tint(_ theme: AppTheme) -> Color {
        switch self {
        case .claude: theme.chrome.primary.color
        case .codex: theme.chrome.activity.color
        case .gemini: .blue
        }
    }
}

// MARK: - Chart

/// Tokens or cost over time, one color per agent: a stacked area by the hour, rounded columns by the day.
/// Hovering picks a slot; `hovered` reports it so the caller can say what it holds.
struct UsageChart: View {
    let slots: [UsageSlot]
    let range: UsageRange
    let measure: UsageMeasure
    let tools: [AgentTool]
    @Binding var hovered: UsageSlot?
    var height: CGFloat = 110
    @Environment(\.appTheme) private var theme

    var body: some View {
        Chart {
            ForEach(slots) { slot in
                ForEach(tools, id: \.self) { tool in
                    let y = measure.value(slot.span(tool))
                    if range == .day {
                        AreaMark(x: .value("When", slot.start, unit: .hour), y: .value(measure.title, y), stacking: .standard)
                            .foregroundStyle(by: .value("Agent", tool.name))
                            .interpolationMethod(.monotone)
                    } else {
                        BarMark(x: .value("When", slot.start, unit: .day), y: .value(measure.title, y), width: .ratio(0.62))
                            .foregroundStyle(by: .value("Agent", tool.name))
                            .clipShape(Capsule())
                            .opacity(hovered == nil || hovered?.start == slot.start ? 1 : 0.4)
                    }
                }
            }
            if let hovered {
                RuleMark(x: .value("When", hovered.start, unit: range.unit))
                    .foregroundStyle(theme.chrome.foreground.color.opacity(range == .day ? 0.35 : 0))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(domain: tools.map(\.name), range: tools.map { $0.tint(theme).opacity(range == .day ? 0.75 : 1) })
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(theme.chrome.border.color)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(measure.format(v)) }
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(theme.chrome.mutedForeground.color)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: range.unit, count: range == .day ? 6 : range == .week ? 1 : 7)) { _ in
                AxisValueLabel(format: range == .day ? .dateTime.hour() : range == .week ? .dateTime.weekday(.narrow) : .dateTime.month(.abbreviated).day())
                    .font(.system(size: 8))
                    .foregroundStyle(theme.chrome.mutedForeground.color)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard let frame = proxy.plotFrame else { return }
                            let x = point.x - geo[frame].origin.x
                            if let date: Date = proxy.value(atX: x) {
                                hovered = slots.first { $0.start <= date && date < $0.end }
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .frame(height: height)
    }
}

/// A row of capsules where one is picked: the switches above the charts.
struct UsagePills<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = value }
                } label: {
                    Text(label)
                        .font(.system(size: 10, weight: on ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .foregroundStyle(on ? theme.chrome.foreground.color : theme.chrome.mutedForeground.color)
                        .background(on ? theme.chrome.primary.color.opacity(0.28) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.chrome.muted.color.opacity(0.7), in: Capsule())
    }
}

/// The agents' colors under a chart, when there is more than one.
struct UsageLegend: View {
    let tools: [AgentTool]
    let agents: [AgentDescriptor]
    @Environment(\.appTheme) private var theme

    var body: some View {
        if tools.count > 1 {
            HStack(spacing: 12) {
                ForEach(tools, id: \.self) { tool in
                    HStack(spacing: 4) {
                        Capsule().fill(tool.tint(theme)).frame(width: 10, height: 4)
                        AgentIcon(agents.first { $0.id == tool.catalogID }, size: 11)
                        Text(tool.name)
                    }
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(theme.chrome.mutedForeground.color)
        }
    }
}

// MARK: - Breakdown

/// What the tokens of a stretch were: one segmented capsule, then each kind with its count and share.
struct UsageBreakdown: View {
    let span: UsageSpan
    @Environment(\.appTheme) private var theme

    private var kinds: [(name: String, value: Int, color: Color)] {
        [("Fresh input", span.tokens.input, theme.chrome.primary.color),
         ("Output", span.tokens.output, StateColors.done.color),
         ("Cache writes", span.tokens.cacheWrite, .orange),
         ("Cache reads", span.tokens.cacheRead, theme.chrome.mutedForeground.color.opacity(0.6))]
    }

    var body: some View {
        let total = max(span.tokens.total, 1)
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(kinds.filter { $0.value > 0 }, id: \.name) { kind in
                        kind.color.frame(width: max(2, (geo.size.width - 6) * CGFloat(kind.value) / CGFloat(total)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.chrome.muted.color)
                .clipShape(Capsule())
            }
            .frame(height: 6)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(kinds, id: \.name) { kind in
                    GridRow {
                        Circle().fill(kind.color).frame(width: 6, height: 6)
                        Text(kind.name).foregroundStyle(theme.chrome.mutedForeground.color)
                        Text(UsageFormat.tokens(kind.value)).font(.system(size: 10, design: .monospaced)).gridColumnAlignment(.trailing)
                        Text(Self.share(kind.value, of: span.tokens.total))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                            .gridColumnAlignment(.trailing)
                    }
                }
                GridRow {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                    Text("Turns").foregroundStyle(theme.chrome.mutedForeground.color)
                    Text(span.turns.formatted()).font(.system(size: 10, design: .monospaced))
                    Text("")
                }
            }
            .font(.system(size: 10))
        }
    }

    static func share(_ part: Int, of whole: Int) -> String {
        guard whole > 0, part > 0 else { return "–" }
        let p = Double(part) / Double(whole) * 100
        return p < 1 ? "<1%" : "\(Int(p.rounded()))%"
    }
}

// MARK: - Popover card

/// The Usage popover's trend: the last 24 hours or 30 days, what the tokens were, and how steady the work is.
struct UsageTrendCard: View {
    let usage: MachineUsage
    let agents: [AgentDescriptor]
    @AppStorage("xtermx.usage.trendRange") private var rangeRaw = UsageRange.day.rawValue
    @AppStorage("xtermx.usage.trendMeasure") private var measureRaw = UsageMeasure.tokens.rawValue
    @State private var hovered: UsageSlot?
    @Environment(\.appTheme) private var theme

    var body: some View {
        let range = UsageRange(rawValue: rangeRaw) == .day ? UsageRange.day : .month
        let measure = UsageMeasure(rawValue: measureRaw) ?? .tokens
        let slots = range.slots(usage)
        let tools = usage.tools
        let shown = hovered.map { [$0] } ?? slots
        let span = UsageSlot.total(shown)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(theme.chrome.mutedForeground.color)
                Text("Trend").font(.system(size: 12, weight: .semibold))
                Spacer()
                UsagePills(options: [(UsageRange.day, "24 h"), (.month, "30 d")],
                           selection: Binding(get: { range }, set: { rangeRaw = $0.rawValue; hovered = nil }))
            }
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(measure == .cost && span.costUSD == 0 && !span.fullyPriced ? "–" : measure == .cost ? UsageFormat.dollars(span.costUSD) : UsageFormat.tokens(span.tokens.total))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(hovered.map { range.label($0) } ?? range.phrase)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                }
                Spacer()
                UsagePills(options: [(UsageMeasure.tokens, "Tokens"), (.cost, "Cost")],
                           selection: Binding(get: { measure }, set: { measureRaw = $0.rawValue }))
            }
            UsageChart(slots: slots, range: range, measure: measure, tools: tools, hovered: $hovered)
            UsageLegend(tools: tools, agents: agents)
            Divider().overlay(theme.chrome.border.color)
            Text("WHAT THE TOKENS WERE").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.chrome.mutedForeground.color)
            UsageBreakdown(span: span)
            Divider().overlay(theme.chrome.border.color)
            UsageStatsRow(stats: usage.stats(days: 30))
        }
        .padding(12)
        .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.chrome.border.color))
    }
}

/// Active days as a ring, then turns and the streak, over the last 30 days.
struct UsageStatsRow: View {
    let stats: UsageStats
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                // Not a `UsageRing`: more active days is good news, so no warning colors.
                ZStack {
                    Circle().stroke(theme.chrome.mutedForeground.color.opacity(0.22), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: stats.days > 0 ? CGFloat(stats.activeDays) / CGFloat(stats.days) : 0)
                        .stroke(theme.chrome.primary.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(stats.activeDays)").font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                .frame(width: 28, height: 28)
                .padding(2)
                fact("Active days", "of the last \(stats.days)")
            }
            fact(stats.turns.formatted(), "turns", big: true)
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(stats.streak > 0 ? Color.orange : theme.chrome.mutedForeground.color)
                fact(stats.streak == 1 ? "1 day" : "\(stats.streak)\(stats.streakMayBeLonger ? "+" : "") days", "in a row", big: true)
            }
            Spacer(minLength: 0)
        }
        .help("Longest run in days: \(stats.longestStreak)")
    }

    private func fact(_ value: String, _ label: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: big ? 12 : 11, weight: .semibold, design: big ? .rounded : .default)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(theme.chrome.mutedForeground.color)
        }
    }
}
