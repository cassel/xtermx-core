import AppKit
import Observation
import SwiftUI
import XTermXHost
import XTermXKit

@MainActor @Observable
final class PrivacyController {
    let store = LocalActivityStore()
    var enabled = UserDefaults.standard.object(forKey: "xtermx.privacy.activity") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "xtermx.privacy.activity") }
    }
    var days = UserDefaults.standard.object(forKey: "xtermx.privacy.days") as? Int ?? 30 {
        didSet { days = min(90, max(30, days)); UserDefaults.standard.set(days, forKey: "xtermx.privacy.days"); Task { await refresh() } }
    }
    var records: [LocalPaneActivity] = []
    var error: String?
    var diagnostic: String?
    @ObservationIgnored private var timer: Timer?
    func start(_ manager: PaneManager) {
        manager.onPaneActivity = { [weak self] record in
            guard let self, enabled else { return }
            let retention = days
            Task { @MainActor in
                do { try await store.append(record, days: retention) } catch { self.error = error.localizedDescription }
            }
        }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
    func refresh() async {
        do { records = try await store.records(days: days); error = nil } catch { self.error = error.localizedDescription }
    }
    func clear() async {
        do { try await store.clear(); records = []; error = nil } catch { self.error = error.localizedDescription }
    }
    func prepareDiagnostic(_ model: AppModel) async {
        await refresh()
        let summary = DiagnosticSummary(version: AboutSettings.short, build: AboutSettings.build,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            localPanes: model.manager.panes.count, sshPanes: model.sshSessions.count, remoteMachinePanes: model.remoteLeaves.count,
            remoteAccessEnabled: model.remoteEnabled, connectedDevices: model.server.devices.count, activityEvents: records.count)
        do { diagnostic = try summary.preview() } catch { self.error = error.localizedDescription }
    }
    func saveDiagnostic() {
        guard let diagnostic else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "XTermX-diagnostic.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(diagnostic.utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
}
