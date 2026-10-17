#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost

@Suite struct RemoteActionRulesTests {
    @Test func roomsRejectUnknownMembersAndUnboundedContent() {
        let rooms = [RemoteRoom(id: "one", name: "Build", paneIDs: ["a", "b"])]
        #expect(RemoteRoomAction.rename(id: "one", name: "Review").isValid(in: rooms))
        #expect(!RemoteRoomAction.rename(id: "missing", name: "Review").isValid(in: rooms))
        #expect(!RemoteRoomAction.rename(id: "one", name: "\n").isValid(in: rooms))
        #expect(!RemoteRoomAction.rename(id: "one", name: String(repeating: "a", count: 121)).isValid(in: rooms))
        #expect(RemoteRoomAction.message(id: "one", text: "Review this", paneIDs: ["a"], execute: false).isValid(in: rooms))
        #expect(!RemoteRoomAction.message(id: "one", text: "ls", paneIDs: ["other"], execute: true).isValid(in: rooms))
        #expect(!RemoteRoomAction.message(id: "one", text: "ls", paneIDs: ["a", "a"], execute: true).isValid(in: rooms))
        #expect(!RemoteRoomAction.message(id: "one", text: "ls", paneIDs: [], execute: true).isValid(in: rooms))
        #expect(!RemoteRoomAction.message(id: "one", text: String(repeating: "a", count: 32_769), paneIDs: ["a"], execute: true).isValid(in: rooms))
    }

    @Test func receivedFilesNeverTraverseOrOverwriteAndArePrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceivedFileStore(directory: root)
        for name in ["../outside", "/tmp/outside", "a/b", "a\\b", ".", "..", "", "bad\u{0}name", "bad\nname"] {
            #expect(throws: ReceivedFileStore.Failure.self) { try store.receive(name: name, data: Data()) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let first = try store.receive(name: "notes.txt", data: Data("one".utf8))
        let second = try store.receive(name: "notes.txt", data: Data("two".utf8))
        #expect(first.id != second.id)
        let file = root.appendingPathComponent(first.id).appendingPathComponent(first.name)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(throws: ReceivedFileStore.Failure.self) {
            try store.receive(name: "big", data: Data(repeating: 0, count: RemoteFileRules.maximumBytes + 1))
        }
    }
}

@MainActor @Suite(.serialized) struct RemotePermissionsIntegrationTests {
    func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }

    @Test func permissionsAreEnforcedOverWebSocketAndHTTP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.receivedFiles = ReceivedFileStore(directory: root)
        server.permissions = RemotePermissions(openSessions: false)
        var changes: [RemotePermissions] = []
        server.onPermissionsChanged = { changes.append($0) }
        var room = RemoteRoom(id: "room", name: "Build", paneIDs: ["a"])
        var actions = 0
        server.roomList = { [room] }
        server.roomAction = { action in
            actions += 1
            if case .rename(_, let name) = action { room.name = name }
        }
        server.start()
        defer { server.stop() }
        #expect(server.isRunning)
        let pairing = server.pairing(address: "127.0.0.1")
        let client = HostConnection(pairing: pairing, deviceName: "test", platform: .macOS)
        client.connect()
        defer { client.disconnect() }
        #expect(await client.waitUntilReady())
        #expect(await wait { client.permissions?.openSessions == false })
        client.spawn(SpawnRequest(kind: .shell))
        #expect(await wait { client.lastError?.contains("SPAWN_OFF") == true })
        #expect(manager.panes.isEmpty)
        client.refreshRooms()
        #expect(await wait { client.lastError?.contains("ROOMS_OFF") == true })
        client.updateRoom(.rename(id: "room", name: "Denied"))
        client.upload(name: "no.txt", data: Data("no".utf8))
        #expect(await wait { client.lastError?.contains("FILES_OFF") == true })
        #expect(actions == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        // HTTP is the Watch path: it must enforce the same policy, even without a WebSocket peer.
        func rpc(_ message: ClientMessage) async throws -> [HostMessage] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(pairing.httpPort)/rpc")!)
            request.httpMethod = "POST"
            request.httpBody = try RPCSealing.seal(RPCRequest(message: message), secret: pairing.secret, .clientToHost)
            let (data, _) = try await URLSession.shared.data(for: request)
            return try RPCSealing.open(RPCResponse.self, from: data, secret: pairing.secret, .hostToClient).messages
        }
        for (message, expected) in [(ClientMessage.spawn(SpawnRequest(kind: .shell)), "SPAWN_OFF"),
                                    (.rooms, "ROOMS_OFF"), (.roomAction(.rename(id: "room", name: "Denied")), "ROOMS_OFF"),
                                    (.upload(name: "no.txt", data: Data()), "FILES_OFF")] {
            let replies = try await rpc(message)
            #expect(replies.contains { if case .error(let code, _) = $0 { code == expected } else { false } })
        }
        #expect(manager.panes.isEmpty && actions == 0)

        server.permissions = RemotePermissions(openSessions: false, manageRooms: true, sendFiles: true)
        #expect(changes.last?.sendFiles == true)
        #expect(await wait { client.permissions?.sendFiles == true })
        client.refreshRooms()
        #expect(await wait { client.remoteRooms.first?.name == "Build" })
        client.updateRoom(.message(id: "room", text: "ls", paneIDs: ["outside"], execute: true))
        #expect(await wait { client.lastError?.contains("ROOM_INVALID") == true })
        #expect(actions == 0)
        client.updateRoom(.rename(id: "room", name: "Review"))
        #expect(await wait { client.remoteRooms.first?.name == "Review" })
        #expect(actions == 1)
        client.upload(name: "notes.txt", data: Data("contents".utf8))
        #expect(await wait { client.receivedFile != nil })
        let receipt = try #require(client.receivedFile)
        #expect(try String(contentsOf: root.appendingPathComponent(receipt.id).appendingPathComponent(receipt.name), encoding: .utf8) == "contents")
        let allowed = try await rpc(.upload(name: "watch.txt", data: Data("watch".utf8)))
        #expect(allowed.contains { if case .receivedFile(let f) = $0 { f.name == "watch.txt" } else { false } })
        server.permissions.manageRooms = false
        #expect(await wait { client.remoteRooms.isEmpty && client.permissions?.manageRooms == false })
        #expect(actions == 1)
    }
}
#endif
