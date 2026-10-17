import AppKit
import Observation
import ServiceManagement
import SwiftUI
import XTermXHost
import XTermXKit

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var status = SMAppService.mainApp.status
    @State private var changing = false
    @State private var error: String?

    var body: some View {
        SettingsPage(section: .general) {
            SettingsCard("Your language", "Choose the language for XTermX's interface. Terminal programs keep their own language.") {
                InterfaceLanguagePicker()
            }
            SettingsCard("Ready when you sign in", "Have XTermX open automatically after you log in to this Mac.") {
                Toggle("Open at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: setLogin))
                    .toggleStyle(.switch).disabled(changing)
                if status == .requiresApproval {
                    Text("macOS needs your approval in Login Items.").font(.caption)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Button("Refresh status") { status = SMAppService.mainApp.status }
            }
            ReceivedCleanupSettings()
            SettingsCard("Memory at a glance", "See XTermX and the programs running inside its local panes.") {
                Toggle("Show process memory in the title bar", isOn: Binding(get: { model.appMemory.enabled },
                                                                             set: { model.appMemory.enabled = $0 }))
                    .toggleStyle(.switch)
                Text("Updates every five seconds while enabled. Resident memory includes shared pages in each process, so totals are approximate.").font(.caption)
                if let sample = model.appMemory.sample {
                    LabeledContent("XTermX", value: AppMemoryMeter.format(sample.appBytes))
                    LabeledContent("Pane programs", value: AppMemoryMeter.format(sample.paneBytes))
                    Text("\(sample.paneProcesses) processes · \(sample.unreadable) unreadable").font(.caption)
                }
            }
        }
        .onAppear { status = SMAppService.mainApp.status }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }
    private func setLogin(_ enabled: Bool) {
        changing = true; error = nil
        Task { @MainActor in
            defer { changing = false; status = SMAppService.mainApp.status }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor @Observable final class AppMemoryMeter {
    var enabled = UserDefaults.standard.bool(forKey: "xtermx.memory.title") {
        didSet { UserDefaults.standard.set(enabled, forKey: "xtermx.memory.title"); if enabled { refresh() } else { sample = nil } }
    }
    private(set) var sample: ProcessMemorySummary?
    @ObservationIgnored private weak var manager: PaneManager?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing = false
    func start(manager: PaneManager) {
        self.manager = manager
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }
    private func refresh() {
        guard enabled, !refreshing, let manager else { return }
        refreshing = true
        let pids = manager.panes.compactMap { manager.session($0.id)?.shellPID }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { ProcessMemory.sample(appPID: ownPID, panePIDs: pids) }.value
            guard let self else { return }
            refreshing = false
            if enabled { sample = result }
        }
    }
    static func format(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

struct AppMemoryBadge: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.appMemory.enabled {
            let sample = model.appMemory.sample
            Chip(systemImage: "memorychip", text: "XTermX \(AppMemoryMeter.format(sample?.appBytes)) · panes \(AppMemoryMeter.format(sample?.paneBytes))")
                .help("Resident memory · XTermX and local pane processes; shared pages may be counted more than once")
        }
    }
}
