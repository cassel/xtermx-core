import AppKit
import XTermXHost
import XTermXKit

extension AppModel {
    static var sessionURL: URL { FileSecretStore.defaultDirectory.appendingPathComponent("session.json") }

    /// The window as it is now; nil while nothing local is open.
    func currentSession() -> SavedSession? {
        var tabs: [SavedSession.Tab] = []
        var panes: [SavedSession.Pane] = []
        var active: Int?
        for ws in workspaces {
            var layout: SplitNode? = ws.layout
            for leaf in ws.layout.leaves where remoteLeaves[leaf] != nil || sshSessions[leaf] != nil || pane(leaf) == nil {
                layout = layout?.removing(leaf)
            }
            guard let layout else { continue }
            for id in layout.leaves {
                guard let info = pane(id) else { continue }
                panes.append(.init(id: id, kind: info.kind, agentID: info.agentID, cwd: manager.currentDirectory(id) ?? info.cwd, customName: info.customName))
            }
            if ws.id == activeID { active = tabs.count }
            tabs.append(.init(name: ws.name, layout: layout,
                              focused: layout.leaves.contains(ws.focused) ? ws.focused : layout.leaves[0]))
        }
        guard !tabs.isEmpty else { return nil }
        let splits = Set(tabs.flatMap(\.layout.splitIDs))
        let fractions = splitFractions.filter { splits.contains($0.key) }.mapValues { $0.map(Double.init) }
        return SavedSession(tabs: tabs, active: active, panes: panes, fractions: fractions, savedAt: .now)
    }

    func saveSession() {
        guard let session = currentSession() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        try? FileManager.default.createDirectory(at: Self.sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.sessionURL, options: .atomic)
    }

    /// Opens the last session's tabs and panes; false when there is none to open.
    func restoreSession() -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let saved = try? decoder.decode(SavedSession.self, from: data), !saved.tabs.isEmpty else { return false }
        let panes = Dictionary(saved.panes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        spawningLocally = true
        defer { spawningLocally = false }
        for tab in saved.tabs {
            // Same pane ids as before, so the saved split sizes still match their splits.
            for id in tab.layout.leaves {
                _ = manager.spawn(SpawnRequest(kind: .shell, cwd: panes[id]?.cwd), id: id)
                if let name = panes[id]?.customName { _ = try? manager.rename(id, to: name) }
            }
            workspaces.append(Workspace(name: tab.name, layout: tab.layout, focused: tab.focused))
        }
        splitFractions = balanceOnOpen ? [:] : saved.fractions.mapValues { $0.map { CGFloat($0) } }
        let active = workspaces[min(saved.active ?? 0, workspaces.count - 1)]
        activeID = active.id
        focus(active.focused)
        return true
    }

    /// Saves when the app quits, and every few seconds meanwhile (folders change, and a crash saves nothing).
    func keepSessionSaved() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }
}
