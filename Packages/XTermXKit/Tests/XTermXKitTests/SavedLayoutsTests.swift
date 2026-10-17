import Foundation
import Testing
@testable import XTermXKit

@Suite struct SavedLayoutsTests {
    func session() -> SavedSession {
        let inner = SplitNode.split(vertical: true, [.leaf("b"), .leaf("c")])
        let layout = SplitNode.split(vertical: false, [.leaf("a"), inner])
        return SavedSession(tabs: [.init(name: "Build", layout: layout, focused: "c"),
                                   .init(name: "Notes", layout: .leaf("d"), focused: "d")], active: 1,
                            panes: [.init(id: "a", kind: .shell, cwd: "/tmp/project"),
                                    .init(id: "b", kind: .agent, agentID: "claude", cwd: "/tmp/project"),
                                    .init(id: "c", kind: .shell), .init(id: "d", kind: .shell)],
                            fractions: [layout.id: [0.3, 0.7], inner.id: [0.6, 0.4]])
    }

    @Test func repeatedRestoresKeepTopologyAndNeverReuseLiveIDs() throws {
        let saved = session()
        let first = try saved.freshCopy(), second = try saved.freshCopy()
        try first.validate()
        try second.validate()
        let originalIDs = Set(saved.panes.map(\.id))
        let firstIDs = Set(first.panes.map(\.id))
        #expect(firstIDs.isDisjoint(with: originalIDs))
        #expect(firstIDs.isDisjoint(with: Set(second.panes.map(\.id))))
        #expect(first.tabs.map(\.name) == ["Build", "Notes"])
        #expect(first.active == 1)
        #expect(first.tabs[0].layout.leaves[2] == first.tabs[0].focused)
        #expect(first.panes[1].agentID == "claude")
        #expect(first.panes[0].cwd == "/tmp/project")
        #expect(first.fractions[first.tabs[0].layout.id] == [0.3, 0.7])
        #expect(first.fractions.values.contains([0.6, 0.4]))
        #expect(Set(first.fractions.keys).isDisjoint(with: Set(saved.fractions.keys)))
    }

    @Test func rejectsBrokenTopologyBeforeOpeningAnything() {
        var invalid = session()
        invalid.panes.removeLast()
        #expect(throws: SavedLayoutError.self) { try invalid.freshCopy() }
        invalid = session(); invalid.tabs[0].focused = "missing"
        #expect(throws: SavedLayoutError.self) { try invalid.validate() }
        invalid = session(); invalid.panes.append(invalid.panes[0])
        #expect(throws: SavedLayoutError.self) { try invalid.validate() }
        invalid = session(); invalid.tabs[1].layout = .leaf("a")
        #expect(throws: SavedLayoutError.self) { try invalid.validate() }
        invalid = session(); invalid.active = -1
        #expect(throws: SavedLayoutError.self) { try invalid.validate() }
        invalid = session(); invalid.fractions[invalid.tabs[0].layout.id] = [-0.2, 1.2]
        #expect(throws: SavedLayoutError.self) { try invalid.validate() }
        invalid = session(); invalid.fractions[invalid.tabs[0].layout.id] = [0.1, 0.1]
        #expect(throws: SavedLayoutError.self) { try invalid.validate() }
    }

    @Test func namesAndSearchIncludeFoldersTabsAndAgents() throws {
        let layout = try SavedLayout(name: "  Daily work \n", session: session())
        #expect(layout.name == "Daily work")
        for query in ["DAILY", "project", "build", "Claude", "  "] { #expect(layout.matches(query)) }
        #expect(!layout.matches("absent"))
        #expect(throws: SavedLayoutError.self) { try SavedLayout(name: " \n", session: session()) }
    }

    @Test func libraryPersistsRenameDeleteAndReportsDamagedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("layouts.json")
        #expect(try SavedLayoutStore.load(from: url).isEmpty)
        let layout = try SavedLayout(name: "Daily", session: session())
        try SavedLayoutStore.save([layout], to: url)
        let loaded = try #require(SavedLayoutStore.load(from: url).first)
        #expect(loaded.id == layout.id)
        #expect(loaded.session.tabs[0].layout == layout.session.tabs[0].layout)
        let renamed = try SavedLayout(id: loaded.id, name: "Renamed", session: loaded.session)
        try SavedLayoutStore.save([renamed], to: url)
        #expect(try SavedLayoutStore.load(from: url).first?.name == "Renamed")
        try SavedLayoutStore.save([], to: url)
        #expect(try SavedLayoutStore.load(from: url).isEmpty)
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try SavedLayoutStore.load(from: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }

    @Test func automaticSessionFormatStillRoundTrips() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(session())
        let restored = try decoder.decode(SavedSession.self, from: data)
        #expect(restored.tabs[0].layout == session().tabs[0].layout)
        #expect(restored.fractions == session().fractions)
        try restored.validate()
    }
    @Test func transferPreservesLayoutButCreatesANewLibraryIdentity() throws {
        let original = try SavedLayout(name: "Shared", session: session())
        let data = try SavedLayoutTransfer.encode(original)
        let imported = try SavedLayoutTransfer.decode(data)
        let second = try SavedLayoutTransfer.decode(data)
        #expect(imported.id != original.id)
        #expect(imported.id != second.id)
        #expect(imported.name == original.name)
        #expect(imported.session.tabs[0].layout == original.session.tabs[0].layout)
        #expect(imported.session.panes[1].agentID == "claude")
        #expect(imported.session.fractions == original.session.fractions)
    }

    @Test func transferRejectsUnknownFormatsBrokenPanesAndOversizedFiles() throws {
        let original = try SavedLayout(name: "Shared", session: session())
        let data = try SavedLayoutTransfer.encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 99
        #expect(throws: SavedLayoutTransfer.TransferError.self) {
            try SavedLayoutTransfer.decode(JSONSerialization.data(withJSONObject: object))
        }
        object["version"] = 1; object["format"] = "other-app"
        #expect(throws: SavedLayoutTransfer.TransferError.self) {
            try SavedLayoutTransfer.decode(JSONSerialization.data(withJSONObject: object))
        }
        object["format"] = "xtermx-layout"
        var layout = try #require(object["layout"] as? [String: Any])
        var session = try #require(layout["session"] as? [String: Any])
        session["panes"] = []
        layout["session"] = session; object["layout"] = layout
        #expect(throws: SavedLayoutError.self) {
            try SavedLayoutTransfer.decode(JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: SavedLayoutTransfer.TransferError.self) {
            try SavedLayoutTransfer.decode(Data(repeating: 0x20, count: SavedLayoutTransfer.maximumBytes))
        }
        #expect(throws: (any Error).self) { try SavedLayoutTransfer.decode(Data("{}".utf8)) }
    }

}
