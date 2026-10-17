import Foundation
import IOKit.pwr_mgt
import Observation
import XTermXHost

/// Holds only idle system sleep, not the display or explicit user sleep. macOS releases it on process exit.
@MainActor @Observable final class RemoteAwakeController {
    var enabled = UserDefaults.standard.object(forKey: "xtermx.remote.stay-awake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "xtermx.remote.stay-awake"); refresh() }
    }
    private(set) var active = false
    private(set) var error: String?
    @ObservationIgnored private var assertion = IOPMAssertionID(kIOPMNullAssertionID)
    @ObservationIgnored private weak var server: RemoteServer?
    @ObservationIgnored private var timer: Timer?

    func start(server: RemoteServer) {
        self.server = server
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }
    private func refresh() {
        let needed = enabled && !(server?.watchedPaneIDs().isEmpty ?? true)
        if needed, !active {
            var created = IOPMAssertionID(kIOPMNullAssertionID)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "XTermX remote terminal viewing" as CFString, &created)
            if result == 0 { assertion = created; active = true; error = nil }
            else { error = "macOS could not keep this Mac awake." }
        } else if !needed {
            if active { IOPMAssertionRelease(assertion) }
            assertion = IOPMAssertionID(kIOPMNullAssertionID)
            active = false; error = nil
        }
    }
}
