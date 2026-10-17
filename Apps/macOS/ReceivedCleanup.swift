import Foundation
import Observation
import SwiftUI
import XTermXHost

@MainActor @Observable final class ReceivedCleanupController {
    var days = UserDefaults.standard.integer(forKey: "xtermx.received.keep-days") {
        didSet { UserDefaults.standard.set(days, forKey: "xtermx.received.keep-days"); run() }
    }
    private(set) var running = false
    private(set) var removed: Int?
    private(set) var error: String?
    @ObservationIgnored private var store = ReceivedFileStore()
    @ObservationIgnored private var timer: Timer?
    func start(store: ReceivedFileStore) {
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        run()
    }
    func run() {
        guard days > 0, !running else { return }
        running = true
        let store = store, days = days
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try store.cleanup(olderThanDays: days) } }.value
            guard let self else { return }
            running = false
            switch result {
            case .success(let report): removed = report.files; error = nil
            case .failure: error = "Some received files could not be cleaned up. Check the received-files folder."
            }
        }
    }
}

struct ReceivedCleanupSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        SettingsCard("Received files", "Choose how long this Mac keeps files sent by paired devices.") {
            Picker("Keep received files", selection: Binding(get: { model.receivedCleanup.days }, set: { model.receivedCleanup.days = $0 })) {
                Text("Until I remove them").tag(0)
                Text("1 day").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            Text("Expired receipts are removed automatically each hour. Only XTermX's received-files folders are eligible; unfamiliar content is left alone.").font(.caption)
            Button("Remove expired files now") { model.receivedCleanup.run() }
                .disabled(model.receivedCleanup.days == 0 || model.receivedCleanup.running)
            if let removed = model.receivedCleanup.removed { Text("Last cleanup removed \(removed) files.").font(.caption) }
            if let error = model.receivedCleanup.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
