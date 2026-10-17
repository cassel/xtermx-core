#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost

@Suite struct DeviceIdentityTests {
    @Test func proofBindsDeviceHostAndConnection() throws {
        let identity = DeviceIdentity(), other = DeviceIdentity()
        let secret = SecureRandom.bytes(32), clientNonce = SecureRandom.bytes(32), hostNonce = SecureRandom.bytes(32)
        let challenge = DeviceIdentity.webSocketChallenge(secret: secret, clientNonce: clientNonce, hostNonce: hostNonce)
        let proof = try identity.proof(for: challenge)
        let id = try #require(DeviceIdentity.verifiedID(proof, challenge: challenge))
        #expect(id != DeviceIdentity.verifiedID(try other.proof(for: challenge), challenge: challenge))
        #expect(DeviceIdentity.verifiedID(proof, challenge: DeviceIdentity.webSocketChallenge(secret: secret, clientNonce: clientNonce, hostNonce: SecureRandom.bytes(32))) == nil)
        #expect(DeviceIdentity.verifiedID(proof, challenge: DeviceIdentity.webSocketChallenge(secret: SecureRandom.bytes(32), clientNonce: clientNonce, hostNonce: hostNonce)) == nil)
    }
    @Test func signedRPCSurvivesWireCodingAndRejectsChanges() throws {
        let identity = DeviceIdentity(), secret = SecureRandom.bytes(32)
        let rpc = RPCRequest(message: .spawn(.init(kind: .shell, cwd: "/tmp")), identity: identity, secret: secret, deviceName: "Phone")
        let decoded = try WireCoding.decoder().decode(RPCRequest.self, from: WireCoding.encoder().encode(rpc))
        let proof = try #require(decoded.deviceProof)
        #expect(try DeviceIdentity.verifiedID(proof, challenge: decoded.identityChallenge(secret: secret)) != nil)
        var changed = decoded
        changed.message = .spawn(.init(kind: .shell, cwd: "/private"))
        #expect(try DeviceIdentity.verifiedID(proof, challenge: changed.identityChallenge(secret: secret)) == nil)
        changed = decoded; changed.deviceName = "Different device"
        #expect(try DeviceIdentity.verifiedID(proof, challenge: changed.identityChallenge(secret: secret)) == nil)
    }
}

@MainActor @Suite(.serialized) struct RemoteSpawnTests {
    func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return predicate()
    }

    @Test func trustUsesCanonicalFoldersAndVerifiedIdentityOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("repo")
        let child = project.appendingPathComponent("src")
        let sibling = root.appendingPathComponent("repo-other")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape"), withDestinationURL: sibling)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RemoteSpawnGate(rules: .init())
        let request = SpawnRequest(kind: .shell, cwd: project.path, initialInput: "pwd")
        let pending = Task { await gate.authorize(request, deviceID: "signed-device", name: "Phone\n", source: nil) }
        #expect(await wait { gate.approvals.count == 1 })
        #expect(gate.approvals.first?.initialInput == "pwd")
        #expect(gate.approvals.first?.deviceName == "Phone")
        gate.answer(try #require(gate.approvals.first?.id), choice: .trustFolder)
        #expect(await pending.value)
        #expect(gate.isTrusted(deviceID: "signed-device", folder: RemoteSpawnGate.folder(for: child.path)))
        #expect(!gate.isTrusted(deviceID: "other-device", folder: RemoteSpawnGate.folder(for: child.path)))
        #expect(!gate.isTrusted(deviceID: nil, folder: RemoteSpawnGate.folder(for: child.path)))
        #expect(!gate.isTrusted(deviceID: "signed-device", folder: RemoteSpawnGate.folder(for: sibling.path)))
        #expect(!gate.isTrusted(deviceID: "signed-device", folder: RemoteSpawnGate.folder(for: project.appendingPathComponent("escape").path)))
        let saved = try JSONDecoder().decode(RemoteSpawnRules.self, from: JSONEncoder().encode(gate.rules))
        #expect(saved == gate.rules)
        gate.rules.folders = []
        #expect(!gate.isTrusted(deviceID: "signed-device", folder: RemoteSpawnGate.folder(for: child.path)))
    }

    @Test func pendingRequestsDenyOnTimeoutDisconnectAndCancellation() async throws {
        let gate = RemoteSpawnGate(rules: .init())
        let request = SpawnRequest(kind: .shell)
        #expect(await !gate.authorize(request, deviceID: nil, name: "Old client", source: nil, timeout: .milliseconds(20)))
        #expect(gate.approvals.isEmpty)
        let source = UUID()
        let pending = Task { await gate.authorize(request, deviceID: nil, name: "Phone", source: source) }
        #expect(await wait { !gate.approvals.isEmpty })
        gate.cancel(source: source)
        #expect(await !pending.value)
        let cancelled = Task { await gate.authorize(request, deviceID: nil, name: "Phone", source: nil) }
        #expect(await wait { !gate.approvals.isEmpty })
        cancelled.cancel()
        #expect(await !cancelled.value)
        #expect(gate.approvals.isEmpty)
    }

    @Test func remoteDevicesCannotApproveThemselvesAndTrustSurvivesReconnect() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.spawnGate.rules = .init()
        server.start()
        defer { server.stop(); for pane in manager.panes { manager.close(pane.id) } }
        let pairing = server.pairing(address: "127.0.0.1")
        let identity = DeviceIdentity()
        let client = HostConnection(pairing: pairing, deviceName: "Phone", platform: .iOS, identity: identity)
        client.connect()
        defer { client.disconnect() }
        #expect(await client.waitUntilReady())
        client.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        #expect(await wait { !server.spawnGate.approvals.isEmpty })
        let approval = try #require(server.spawnGate.approvals.first)
        #expect(approval.deviceID != nil)
        client.send(.answer(requestID: approval.id.uuidString, allow: true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.panes.isEmpty)
        #expect(server.spawnGate.approvals.count == 1)
        server.spawnGate.answer(approval.id, choice: .trustFolder)
        #expect(await wait { manager.panes.count == 1 })
        client.disconnect()
        client.connect()
        #expect(await client.waitUntilReady())
        client.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        #expect(await wait { manager.panes.count == 2 })
        #expect(server.spawnGate.approvals.isEmpty)
        let impostor = HostConnection(pairing: pairing, deviceName: "Phone", platform: .iOS, identity: DeviceIdentity())
        impostor.connect()
        defer { impostor.disconnect() }
        #expect(await impostor.waitUntilReady())
        impostor.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        #expect(await wait { !server.spawnGate.approvals.isEmpty })
        #expect(manager.panes.count == 2)
        server.spawnGate.answer(try #require(server.spawnGate.approvals.first?.id), choice: .deny)
        #expect(await wait { impostor.lastError?.contains("SPAWN_DENIED") == true })
    }

    @Test func HTTPSpawnRequiresMacApprovalAndRechecksPermissionAfterApproval() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.spawnGate.rules = .init()
        server.start()
        defer { server.stop() }
        let pairing = server.pairing(address: "127.0.0.1")
        let identity = DeviceIdentity()
        let request = RPCRequest(message: .spawn(.init(kind: .shell)), identity: identity, secret: pairing.secret, deviceName: "Watch")
        var http = URLRequest(url: URL(string: "http://127.0.0.1:\(pairing.httpPort)/rpc")!)
        http.httpMethod = "POST"
        http.httpBody = try RPCSealing.seal(request, secret: pairing.secret, .clientToHost)
        let work = Task { try await URLSession.shared.data(for: http) }
        #expect(await wait { !server.spawnGate.approvals.isEmpty })
        #expect(server.spawnGate.approvals.first?.deviceID != nil)
        #expect(manager.panes.isEmpty)
        server.permissions.openSessions = false
        server.spawnGate.answer(try #require(server.spawnGate.approvals.first?.id), choice: .once)
        let (data, _) = try await work.value
        let reply = try RPCSealing.open(RPCResponse.self, from: data, secret: pairing.secret, .hostToClient)
        #expect(reply.messages.contains { if case .error(let code, _) = $0 { code == "SPAWN_DENIED" } else { false } })
        #expect(manager.panes.isEmpty)
    }
}
#endif
