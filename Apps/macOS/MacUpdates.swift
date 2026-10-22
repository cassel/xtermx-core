import AppKit
import Observation
import XTermXKit

@MainActor @Observable
final class MacUpdateController {
    static let shared = MacUpdateController()
    var checking = false
    var available: MacUpdates.Available?
    var status = "Updates have not been checked yet."
    var automatic = UserDefaults.standard.object(forKey: "xtermx.updates.automatic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "xtermx.updates.automatic") }
    }
    var development = UserDefaults.standard.object(forKey: "xtermx.updates.development") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(development, forKey: "xtermx.updates.development")
            available = nil
            status = "Updates have not been checked yet."
            UserDefaults.standard.removeObject(forKey: "xtermx.updates.last-attempt")
        }
    }

    func checkAutomatically() async {
        if MacUpdates.shouldCheck(enabled: automatic, lastAttempt: UserDefaults.standard.object(forKey: "xtermx.updates.last-attempt") as? Date, now: .now) {
            await check(manual: false)
        } else if automatic { notifyIfNeeded() }
    }

    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        status = "Checking for updates…"
        let channel = development
        UserDefaults.standard.set(Date.now, forKey: "xtermx.updates.last-attempt")
        defer { checking = false }
        do {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let found = try await MacUpdates.find(currentVersion: AboutSettings.short, currentBuild: AboutSettings.build,
                macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", includeDevelopment: channel)
            guard channel == development else { return }
            available = found
            status = found == nil ? "No newer compatible build is available." : "A new XTermX build is available."
            if manual { showResult() } else { notifyIfNeeded() }
        } catch {
            available = nil
            status = "Could not check for updates. Try again later."
            if manual { showResult() }
        }
    }

    private func notifyIfNeeded() {
        guard automatic, NSApp.isActive, let available,
              UserDefaults.standard.string(forKey: "xtermx.updates.notified") != available.identity else { return }
        UserDefaults.standard.set(available.identity, forKey: "xtermx.updates.notified")
        showResult()
    }

    private func showResult() {
        let language = InterfaceLanguage.current
        let alert = NSAlert()
        alert.messageText = language.text(available == nil ? status : "A new XTermX build is available.")
        if let available {
            UserDefaults.standard.set(available.identity, forKey: "xtermx.updates.notified")
            alert.informativeText = "XTermX \(available.version) (\(available.build))\n\n" + language.text("Review the release and download it when convenient. Your terminals stay open.")
            alert.addButton(withTitle: language.text("View update"))
            alert.addButton(withTitle: language.text("Later"))
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(available.page) }
        } else {
            alert.addButton(withTitle: language.text("OK"))
            alert.runModal()
        }
    }
}
