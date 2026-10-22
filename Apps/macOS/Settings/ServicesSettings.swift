import SwiftUI
import XTermXKit
import XTermXHost

struct ServicesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var address = ""
    @State private var invalid = false

    private var monitor: ServiceMonitor { model.server.services }

    var body: some View {
        SettingsPage(section: .services) {
            SettingsCard("Services", "Web addresses (https://…) and ports (host:port) this Mac checks. Up is a quick answer; degraded is slow or a 4xx; down is no answer or a 5xx.") {
                if monitor.statuses.isEmpty {
                    Text("No services yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(monitor.statuses) { status in
                    HStack {
                        ServiceRow(status: status)
                        Button(role: .destructive) {
                            monitor.setTargets(monitor.targets.filter { $0.id != status.id })
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                HStack {
                    TextField("Name", text: $name).frame(width: 120)
                    TextField("Address", text: $address, prompt: Text("https://localhost:3000/health or db.local:5432"))
                        .onSubmit(add)
                    Button("Add service", action: add).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if invalid {
                    Text("Use a web address starting with http:// or https://, or a host and port like db.local:5432.")
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Picker("Check every", selection: Binding(get: { monitor.interval }, set: { monitor.setInterval($0) })) {
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                        Text("10 minutes").tag(600.0)
                    }
                    .fixedSize()
                    Spacer()
                    if monitor.isChecking { ProgressView().controlSize(.small) }
                    Button("Check now") { Task { await monitor.checkNow() } }.disabled(monitor.targets.isEmpty)
                }
                Text("A service that stops answering sends a Service down notice where Settings › Notifications says. Paired devices see this list only if Remote access › Show services on my devices is on.").font(.caption)
            }
        }
    }

    private func add() {
        guard let target = ServiceTarget(name: name, address: address) else { invalid = true; return }
        invalid = false
        monitor.setTargets(monitor.targets + [target])
        name = ""
        address = ""
        Task { await monitor.checkNow() }
    }
}

/// A service's state dot, name, address, latency and last error.
struct ServiceRow: View {
    let status: ServiceStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(status.health.color).frame(width: 8, height: 8)
                .accessibilityLabel(Text(status.health.label))
            VStack(alignment: .leading, spacing: 1) {
                Text(status.name).lineLimit(1)
                Text(status.address).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let error = status.lastError {
                    Text(error).font(.caption2).foregroundStyle(status.health.color).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let ms = status.latencyMilliseconds, status.health != .down {
                Text("\(Int(ms)) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .help(status.checkedAt.map { "Checked \($0.formatted(date: .omitted, time: .standard))" } ?? "Not checked yet")
    }
}

extension ServiceHealth {
    var color: Color {
        switch self {
        case .up: StateColors.done.color
        case .degraded: .orange
        case .down: .red
        case .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .up: "Up"
        case .degraded: "Degraded"
        case .down: "Down"
        case .unknown: "Not checked"
        }
    }
}

/// "n/m up" in the title bar; a popover lists each service. Hidden while no services are set up.
struct ServicesChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @State private var showing = false

    var body: some View {
        let monitor = model.server.services
        if !monitor.statuses.isEmpty {
            let worst = monitor.statuses.contains { $0.health == .down } ? ServiceHealth.down
                : monitor.statuses.contains { $0.health == .degraded } ? .degraded : nil
            Button { showing.toggle() } label: {
                Chip(systemImage: "heart.text.square", text: monitor.summary.text, tint: worst?.color)
            }
            .buttonStyle(.plain)
            .help("Services this Mac checks")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Services").font(.headline)
                    ForEach(monitor.statuses) { status in
                        Button {
                            if let url = status.openURL { openURL(url) }
                        } label: { ServiceRow(status: status).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                    }
                    Divider()
                    HStack {
                        Button("Check now") { Task { await monitor.checkNow() } }
                        if monitor.isChecking { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Edit services") {
                            showing = false
                            UserDefaults.standard.set(SettingsSection.services.rawValue, forKey: "xtermx.settings.section")
                            openSettings()
                        }
                    }
                }
                .padding(12)
                .frame(width: 300)
            }
        }
    }
}
