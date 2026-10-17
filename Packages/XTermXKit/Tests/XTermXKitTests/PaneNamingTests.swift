#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost

@Suite struct PaneNamingRulesTests {
    @Test func namesOverrideAutomaticTitlesAndOldSnapshotsStillDecode() throws {
        var pane = PaneInfo(title: "shell", kind: .shell, cwd: "/tmp")
        pane.agentSession = AgentSessionInfo(tool: .codex, sessionID: "test", account: "test", title: "Automatic task")
        #expect(pane.displayTitle == "Automatic task")
        pane.customName = try PaneNameRules.clean("  Backend API 🚀  ")
        #expect(pane.displayTitle == "Backend API 🚀")
        pane.title = "terminal changed by OSC"
        #expect(pane.displayTitle == "Backend API 🚀")
        let restored = try JSONDecoder().decode(PaneInfo.self, from: JSONEncoder().encode(pane))
        #expect(restored.customName == pane.customName)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pane)) as? [String: Any])
        legacy.removeValue(forKey: "customName")
        let old = try JSONDecoder().decode(PaneInfo.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.customName == nil)
        #expect(old.displayTitle == "Automatic task")
        #expect(try PaneNameRules.clean("   ") == nil)
        #expect(PaneNameRules.isValid(String(repeating: "a", count: 60)))
        for bad in [String(repeating: "a", count: 61), "name\ncommand", "x\u{1b}[2J", "\t", "line\u{2028}break"] {
            #expect(!PaneNameRules.isValid(bad))
        }
    }

    @Test func savedNamesSurviveFreshLayoutsAndLegacyFiles() throws {
        let session = SavedSession(tabs: [.init(name: "Work", layout: .leaf("p"), focused: "p")], active: 0,
                                   panes: [.init(id: "p", kind: .shell, cwd: "/tmp", customName: "API")], fractions: [:])
        let copy = try session.freshCopy()
        #expect(copy.panes[0].id != "p")
        #expect(copy.panes[0].customName == "API")
        let restored = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(copy))
        #expect(restored.panes[0].customName == "API")
        let old = try JSONDecoder().decode(SavedSession.Pane.self, from: Data(#"{"id":"p","kind":"shell"}"#.utf8))
        #expect(old.customName == nil)
    }
}

@MainActor @Suite(.serialized) struct PaneNamingIntegrationTests {
    func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return predicate()
    }

    @Test func remoteNamesPropagateAndReadOnlyCannotRenameOnEitherTransport() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.start()
        let pane = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        defer { manager.close(pane.id); server.stop() }
        let pairing = server.pairing(address: "127.0.0.1")
        let client = HostConnection(pairing: pairing, deviceName: "names-test", platform: .iOS)
        client.connect()
        defer { client.disconnect() }
        #expect(await client.waitUntilReady())
        #expect(client.canRename(pane.id))
        client.rename(paneID: pane.id, name: "Backend")
        #expect(await wait { client.panes.first?.customName == "Backend" })
        // Later shell output and agent titles cannot replace a person's label.
        manager.write(pane.id, Data("printf '\\033]0;Automatic title\\007'\r".utf8))
        #expect(await wait { manager.pane(pane.id)?.title == "Automatic title" })
        #expect(manager.pane(pane.id)?.displayTitle == "Backend")

        func rpc(_ message: ClientMessage) async throws -> [HostMessage] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(pairing.httpPort)/rpc")!)
            request.httpMethod = "POST"
            request.httpBody = try RPCSealing.seal(RPCRequest(message: message), secret: pairing.secret, .clientToHost)
            let (data, _) = try await URLSession.shared.data(for: request)
            return try RPCSealing.open(RPCResponse.self, from: data, secret: pairing.secret, .hostToClient).messages
        }
        let replies = try await rpc(.rename(paneID: pane.id, name: "Database"))
        #expect(replies.contains { if case .paneUpdated(let p) = $0 { p.customName == "Database" } else { false } })
        #expect(await wait { client.panes.first?.customName == "Database" })
        server.setPaneAccess(pane.id, to: .view)
        #expect(await wait { !client.canRename(pane.id) })
        client.send(.rename(paneID: pane.id, name: "Not allowed"))
        #expect(await wait { client.lastError?.contains("PANE_ACCESS") == true })
        let denied = try await rpc(.rename(paneID: pane.id, name: "Not allowed"))
        #expect(denied.contains { if case .error(let code, _) = $0 { code == "PANE_ACCESS" } else { false } })
        #expect(manager.pane(pane.id)?.customName == "Database")
        server.setPaneAccess(pane.id, to: .control)
        let invalid = try await rpc(.rename(paneID: pane.id, name: "a\ncommand"))
        #expect(invalid.contains { if case .error(let code, _) = $0 { code == "PANE_NAME" } else { false } })
        _ = try await rpc(.rename(paneID: pane.id, name: ""))
        #expect(manager.pane(pane.id)?.customName == nil)
    }

    @Test func returningToMacRestoresLastHomeSizeWithoutTypingAndSurvivesLateRelease() async throws {
        let manager = PaneManager(detectAgents: false)
        let pane = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        defer { manager.close(pane.id) }
        let phone = UUID(), tablet = UUID()
        manager.setHomeSize(pane.id, cols: 130, rows: 40)
        manager.resize(pane.id, cols: 45, rows: 18, device: phone)
        manager.resize(pane.id, cols: 70, rows: 22, device: tablet)
        manager.setHomeSize(pane.id, cols: 140, rows: 42)
        #expect(manager.pane(pane.id)?.cols == 70)
        #expect(manager.reclaimHomeSize(pane.id))
        #expect(manager.pane(pane.id)?.cols == 140)
        #expect(manager.pane(pane.id)?.rows == 42)
        manager.release(pane.id, device: phone)
        manager.release(pane.id, device: tablet)
        #expect(manager.pane(pane.id)?.cols == 140)
        #expect(!manager.reclaimHomeSize(pane.id))
        manager.write(pane.id, Data("stty size\r".utf8))
        #expect(await wait { manager.session(pane.id)?.screenLines(20).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "42 140" }) == true })
        manager.resize(pane.id, cols: 45, rows: 18, device: phone)
        manager.release(pane.id, device: phone)
        #expect(manager.pane(pane.id)?.cols == 140)
    }
}
#endif
