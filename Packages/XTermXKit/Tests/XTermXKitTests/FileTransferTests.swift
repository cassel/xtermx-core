#if os(macOS)
import Foundation
import Testing
import XTermXKit
import XTermXHost

struct FileTransferTests {
    @MainActor @Test func chunksRequireOwnerOrderAndDeclaredSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceivedFileStore(directory: root), receiver = FileChunkReceiver(), id = UUID()
        func failed(_ result: FileTransferReply) -> Bool { if case .failed = result { true } else { false } }
        _ = try receiver.handle(.begin(id: id, name: "clip.mov", bytes: 3), owner: "one", store: store)
        #expect(failed(try receiver.handle(.chunk(id: id, offset: 0, data: Data([1])), owner: "other", store: store)))
        #expect(failed(try receiver.handle(.chunk(id: id, offset: 1, data: Data([1])), owner: "one", store: store)))
        #expect(failed(try receiver.handle(.finish(id: id), owner: "one", store: store)))
        _ = try receiver.handle(.chunk(id: id, offset: 0, data: Data([1, 2, 3])), owner: "one", store: store)
        let result = try receiver.handle(.finish(id: id), owner: "one", store: store)
        guard case .complete(_, let file) = result else { Issue.record("Expected receipt"); return }
        let path = try #require(file.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([1, 2, 3]))
        #expect(file.bytes == 3 && file.name == "clip.mov")
        #expect(failed(try receiver.handle(.finish(id: id), owner: "one", store: store)))
        #expect(failed(try receiver.handle(.begin(id: UUID(), name: "../escape", bytes: 1), owner: "one", store: store)))
        #expect(failed(try receiver.handle(.begin(id: UUID(), name: "large.mov", bytes: RemoteFileRules.maximumTransferBytes + 1), owner: "one", store: store)))
    }
    @MainActor @Test func cancelExpiryAndSymlinksCannotPublishPartialFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceivedFileStore(directory: root), receiver = FileChunkReceiver(), id = UUID(), now = Date()
        _ = try receiver.handle(.begin(id: id, name: "clip.mov", bytes: 3), owner: "one", store: store, now: now)
        receiver.cancel(id, owner: "other")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".incoming/" + id.uuidString + ".part").path))
        receiver.cancel(id, owner: "one")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".incoming/" + id.uuidString + ".part").path))
        _ = try receiver.handle(.begin(id: id, name: "clip.mov", bytes: 3), owner: "one", store: store, now: now)
        let expired = try receiver.handle(.finish(id: id), owner: "one", store: store, now: now.addingTimeInterval(301))
        if case .failed = expired {} else { Issue.record("Expired upload should fail") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".incoming/" + id.uuidString + ".part").path))
        let incoming = root.appendingPathComponent(".incoming")
        try FileManager.default.removeItem(at: incoming)
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: incoming, withDestinationURL: foreign)
        let linked = try receiver.handle(.begin(id: UUID(), name: "clip.mov", bytes: 3), owner: "one", store: store)
        if case .failed = linked {} else { Issue.record("Symlink staging should fail") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
    }
    @Test func pathsAreLiteralAndLegacyReceiptsStillDecode() throws {
        #expect(FilePromptReference.text("/tmp/a b's.mov") == "'/tmp/a b'\"'\"'s.mov' ")
        #expect(FilePromptReference.text("/tmp/a\ncommand") == nil)
        #expect(FilePromptReference.text("relative.mov") == nil)
        let old = Data(#"{"id":"old","name":"clip.mov","bytes":3}"#.utf8)
        #expect(try JSONDecoder().decode(ReceivedFile.self, from: old).path == nil)
    }
    @MainActor @Test func videoLargerThanTheLegacyLimitTransfersOverSocketAndSignedHTTP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("screen recording.mov")
        let data = Data(repeating: 0x61, count: RemoteFileRules.maximumBytes + 17)
        try data.write(to: source)
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.receivedFiles = ReceivedFileStore(directory: root.appendingPathComponent("received"))
        server.permissions.sendFiles = true
        server.start(); defer { server.stop() }
        for polling in [false, true] {
            let client = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "Test", platform: .iOS, usePolling: polling, identity: DeviceIdentity())
            client.connect(); defer { client.disconnect() }
            #expect(await client.waitUntilReady())
            for _ in 0..<100 where client.fileTransferMaximumBytes == nil { try await Task.sleep(for: .milliseconds(20)) }
            let receipt = try await client.uploadFile(at: source)
            let path = try #require(receipt.path)
            #expect(receipt.bytes == data.count)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
            #expect(client.fileUploadProgress == nil)
            client.disconnect()
        }
        server.permissions.sendFiles = false
        let client = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "Test", platform: .iOS, identity: DeviceIdentity())
        client.connect(); defer { client.disconnect() }
        #expect(await client.waitUntilReady())
        await #expect(throws: HostConnection.FileUploadFailure.self) { try await client.uploadFile(at: source) }
        let pairing = server.pairing(address: "127.0.0.1")
        func rpc(identity: DeviceIdentity?) async throws -> [HostMessage] {
            let request = RPCRequest(message: .fileTransfer(.begin(id: UUID(), name: "denied.mov", bytes: 3)), identity: identity, secret: pairing.secret, deviceName: "Test")
            var http = URLRequest(url: URL(string: "http://127.0.0.1:\(pairing.httpPort)/rpc")!)
            http.httpMethod = "POST"
            http.httpBody = try RPCSealing.seal(request, secret: pairing.secret, .clientToHost)
            let (body, _) = try await URLSession.shared.data(for: http)
            return try RPCSealing.open(RPCResponse.self, from: body, secret: pairing.secret, .hostToClient).messages
        }
        let denied = try await rpc(identity: DeviceIdentity())
        #expect(denied.contains { if case .fileTransfer(.failed(_, let message)) = $0 { message.contains("Receive files") } else { false } })
        server.permissions.sendFiles = true
        let unsigned = try await rpc(identity: nil)
        #expect(unsigned.contains { if case .fileTransfer(.failed(_, let message)) = $0 { message.contains("identity") } else { false } })
    }
}
#endif
