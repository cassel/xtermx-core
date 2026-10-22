import SwiftUI
import XTermXHost
import XTermXKit

/// Runs `NetworkDiagnostics` for the Network tab; one run at a time.
@MainActor
@Observable
final class NetworkDiagnosticsModel {
    private(set) var report: NetworkReport?
    private(set) var running = false

    func refresh() async {
        guard !running else { return }
        running = true
        report = await NetworkDiagnostics.run()
        running = false
    }
}

/// The Network tab: how this Mac reaches the internet, refreshed while the tab is open.
struct NetworkPanelView: View {
    @Environment(\.appTheme) private var theme
    @State private var model = NetworkDiagnosticsModel()
    /// Often enough to watch a Wi‑Fi move, rarely enough not to add traffic of its own.
    private let interval: Duration = .seconds(15)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                verdictBadge
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.running).help("Refresh")
            }
            if let report = model.report {
                ForEach(report.reasons, id: \.self) { reason in
                    Text(reason).font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)
                }
                SectionLabel("Connection")
                row("Interface", report.interface ?? "—")
                if let wifi = report.wifiName { row("Wi‑Fi", wifi) }
                row("Router", report.gateway ?? "—")
                SectionLabel("Latency")
                if let probe = report.gatewayProbe { probeRow(probe) }
                ForEach(Array(report.dnsProbes.enumerated()), id: \.offset) { _, probe in probeRow(probe) }
                if let probe = report.internetProbe { probeRow(probe) }
                SectionLabel("Name lookups")
                ForEach(report.lookups, id: \.name) { lookup in
                    HStack {
                        Text(lookup.name).font(.system(size: 12))
                        Spacer()
                        if let ms = lookup.milliseconds, lookup.resolved { latency(ms) } else {
                            Text(lookup.error ?? "Failed").font(.system(size: 11)).foregroundStyle(theme.chrome.destructive.color)
                        }
                    }
                }
                Text("Checked \(report.at.formatted(date: .omitted, time: .standard)) · TCP connect times, no ping needed")
                    .font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task {
            // Lives as long as the tab is shown: SwiftUI cancels it when the tab goes away.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private var verdictBadge: some View {
        let (title, color): (LocalizedStringKey, Color) = switch model.report?.verdict {
        case .ok?: ("Network OK", StateColors.done.color)
        case .slow?: ("Network slow", Color.orange)
        case .dnsFailing?: ("DNS failing", StateColors.blocked.color)
        case .offline?: ("Offline", StateColors.blocked.color)
        case nil: ("Checking…", StateColors.idle.color)
        }
        return Label { Text(title).font(.system(size: 13, weight: .semibold)) } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(theme.chrome.mutedForeground.color)
            Spacer()
            Text(value).font(.system(size: 12).monospaced()).textSelection(.enabled)
        }
    }

    private func probeRow(_ probe: NetworkReport.Probe) -> some View {
        HStack {
            Text(LocalizedStringKey(probe.label)).font(.system(size: 12))
            Text(probe.host).font(.system(size: 11).monospaced()).foregroundStyle(theme.chrome.mutedForeground.color)
            Spacer()
            if let ms = probe.milliseconds { latency(ms) } else {
                Text(probe.error ?? "No answer").font(.system(size: 11)).foregroundStyle(theme.chrome.destructive.color)
            }
        }
    }

    private func latency(_ ms: Double) -> some View {
        Text(ms < 10 ? String(format: "%.1f ms", ms) : "\(Int(ms)) ms").font(.system(size: 12).monospacedDigit())
    }
}

/// Shown in Devices when remote access could not listen because another process has the port.
/// It names the holders and retries; it only offers to quit holders this app started, after asking.
struct PortConflictView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var holders: [PortHolder] = []
    @State private var confirming: PortHolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if holders.isEmpty {
                Text("Another app is using the remote-access port.").font(.system(size: 11))
            } else {
                Text("The remote-access port is in use by:").font(.system(size: 11))
                ForEach(holders) { holder in
                    HStack {
                        Text("\(holder.command) (\(String(holder.pid)))").font(.system(size: 11).monospaced())
                        Text(holder.endpoints.joined(separator: ", ")).font(.system(size: 10).monospaced())
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                        Spacer()
                        if holder.isOurs {
                            Button("Quit…") { confirming = holder }.controlSize(.small)
                                .help("This process was started from an XTermX pane")
                        }
                    }
                }
            }
            Button("Retry") {
                model.server.start()
                Task { await load() }
            }
            .controlSize(.small)
        }
        .task { await load() }
        .confirmationDialog("Quit \(confirming?.command ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Quit process", role: .destructive) {
                if let holder = confirming { PortHolders.terminate(holder) }
                confirming = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    await load()
                }
            }
        } message: {
            Text("It was started from an XTermX pane. Unsaved work in it may be lost.")
        }
    }

    private func load() async {
        var found: [PortHolder] = []
        for port in Set([model.server.port, model.server.httpPort]).sorted() {
            for holder in await PortHolders.listeners(on: port) where !found.contains(where: { $0.pid == holder.pid }) {
                found.append(holder)
            }
        }
        holders = found
    }
}
