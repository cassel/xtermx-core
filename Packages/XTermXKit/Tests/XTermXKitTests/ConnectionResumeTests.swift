#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost
import XTermXNIO

/// Real encrypted loopback connections, with gates around transport operations to reproduce races.
private actor ResumeTransport: FrameTransport {
    let base: any FrameTransport
    var delay: Duration = .zero
    var holdNextSend = false
    var blockedSend: CheckedContinuation<Void, Error>?
    var discardIncoming = false
    init(_ base: any FrameTransport) { self.base = base }
    func send(_ frame: Data) async throws {
        if holdNextSend {
            holdNextSend = false
            try await withCheckedThrowingContinuation { blockedSend = $0 }
        }
        if delay != .zero { try await Task.sleep(for: delay) }
        try await base.send(frame)
    }
    func receive() async throws -> Data {
        while true {
            let frame = try await base.receive()
            if !discardIncoming { return frame }
        }
    }
    nonisolated func close() { base.close() }
    func holdSend() { holdNextSend = true }
    func releaseSend() { blockedSend?.resume(); blockedSend = nil }
    func releaseSendWithError() { blockedSend?.resume(throwing: URLError(.networkConnectionLost)); blockedSend = nil }
    func silence() { discardIncoming = true }
    func slowDown() { delay = .milliseconds(20) }
    var hasBlockedSend: Bool { blockedSend != nil }
}

private actor ResumeFactory {
    var addresses: [String] = []
    var streams: [ResumeTransport] = []
    var holdFirstOpen = false
    var blockedOpen: CheckedContinuation<Void, Error>?
    init(holdFirstOpen: Bool = false) { self.holdFirstOpen = holdFirstOpen }
    func open(_ host: String, _ port: UInt16) async throws -> any FrameTransport {
        addresses.append(host)
        if addresses.count == 1, holdFirstOpen {
            try await withCheckedThrowingContinuation { blockedOpen = $0 }
        }
        let stream = ResumeTransport(try await NIOFrameTransport.factory(host, port))
        streams.append(stream)
        return stream
    }
    func releaseOpen() { blockedOpen?.resume(); blockedOpen = nil }
    func releaseOpenWithError() { blockedOpen?.resume(throwing: URLError(.cancelled)); blockedOpen = nil }
    var hasBlockedOpen: Bool { blockedOpen != nil }
}

@MainActor @Suite(.serialized) struct ConnectionResumeTests {
    private func wait(_ check: () async -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(6)
        while Date.now < deadline {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await check()
    }
    private func server() -> RemoteServer {
        let server = RemoteServer(manager: PaneManager(detectAgents: false), port: 0, httpPort: 0,
                                  secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.start()
        return server
    }
    private func makeClient(_ server: RemoteServer, factory: ResumeFactory) -> HostConnection {
        HostConnection(pairing: server.pairing(addresses: ["127.0.0.1", "192.0.2.1"]),
                       deviceName: "resume-test", platform: .iOS,
                       transport: { host, port in try await factory.open(host, port) }, identity: DeviceIdentity())
    }

    @Test func returningToTheAppPreservesAHealthySocketAndDeviceIdentity() async throws {
        let server = server(); defer { server.stop() }
        let factory = ResumeFactory()
        let connection = self.makeClient(server, factory: factory)
        defer { connection.disconnect() }
        connection.connect()
        #expect(await connection.waitUntilReady())
        #expect(await wait { server.devices.count == 1 })
        let device = try #require(server.devices.first?.id)
        for _ in 0..<4 {
            connection.resumeAfterBackground() // notification/control-center inactivity: no background transition
            connection.pauseForBackground()
            connection.resumeAfterBackground()
            try await Task.sleep(for: .milliseconds(60))
            #expect(connection.status == .connected)
        }
        #expect(await factory.addresses == ["127.0.0.1"])
        #expect(server.devices.map(\.id) == [device])
        connection.disconnect()
        connection.pauseForBackground(); connection.resumeAfterBackground()
        #expect(connection.status == .disconnected) // explicit Disconnect is respected
    }

    @Test func aHandshakeAlreadyOpeningFinishesAfterReturningWithoutRestarting() async throws {
        let server = server(); defer { server.stop() }
        let factory = ResumeFactory(holdFirstOpen: true)
        let connection = makeClient(server, factory: factory); defer { connection.disconnect() }
        connection.connect()
        #expect(await wait { await factory.hasBlockedOpen })
        connection.pauseForBackground(); connection.resumeAfterBackground()
        await factory.releaseOpen()
        #expect(await connection.waitUntilReady())
        #expect(await factory.addresses == ["127.0.0.1"])
    }

    @Test func anInFlightHandshakeIsNotCancelledAndOldHandshakeErrorsCannotDropItsReplacement() async throws {
        let server = server(); defer { server.stop() }
        let factory = ResumeFactory(holdFirstOpen: true)
        let connection = makeClient(server, factory: factory); defer { connection.disconnect() }
        connection.connect()
        #expect(await wait { await factory.hasBlockedOpen })
        connection.pauseForBackground(); connection.resumeAfterBackground()
        #expect(await factory.addresses.count == 1)
        #expect(connection.status == .connecting)
        connection.disconnect(); connection.connect()
        #expect(await connection.waitUntilReady())
        await factory.releaseOpenWithError()
        try await Task.sleep(for: .milliseconds(100))
        #expect(connection.status == .connected)
        #expect(await factory.addresses.count == 2)
    }

    @Test func oldSenderFailuresCannotCloseTheNewConnection() async throws {
        let server = server(); defer { server.stop() }
        let factory = ResumeFactory()
        let client = self.makeClient(server, factory: factory); defer { client.disconnect() }
        client.connect(); #expect(await client.waitUntilReady())
        let old = try #require(await factory.streams.first)
        await old.holdSend()
        client.refresh()
        #expect(await wait { await old.hasBlockedSend })
        client.disconnect(); client.connect()
        #expect(await client.waitUntilReady())
        await old.releaseSendWithError()
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.status == .connected)
        #expect(await factory.addresses.count == 2)
    }

    @Test func backgroundFailureWaitsForForegroundAndRetriesTheWorkingAddress() async throws {
        let server = server(); defer { server.stop() }
        let factory = ResumeFactory()
        let client = self.makeClient(server, factory: factory); defer { client.disconnect() }
        client.connect(); #expect(await client.waitUntilReady())
        let stream = try #require(await factory.streams.first)
        client.pauseForBackground()
        stream.close()
        #expect(await wait { if case .failed = client.status { return true }; return false })
        try await Task.sleep(for: .milliseconds(450))
        #expect(await factory.addresses == ["127.0.0.1"])
        client.resumeAfterBackground()
        #expect(await client.waitUntilReady())
        #expect(await factory.addresses == ["127.0.0.1", "127.0.0.1"])
    }

    @Test func aSilentSocketIsReplacedOnceWhenTheForegroundProbeTimesOut() async throws {
        let server = server(); defer { server.stop() }
        let factory = ResumeFactory()
        let client = self.makeClient(server, factory: factory); defer { client.disconnect() }
        client.connect(); #expect(await client.waitUntilReady())
        let stream = try #require(await factory.streams.first)
        await stream.silence()
        client.pauseForBackground(); client.resumeAfterBackground()
        #expect(await wait { await factory.addresses.count == 2 && client.status == .connected })
        #expect(await factory.addresses == ["127.0.0.1", "127.0.0.1"])
    }

    @Test func switchingAppsDoesNotCancelAnActiveChunkedFileTransfer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data(repeating: 0x63, count: 1024 * 1024)
        let source = folder.appendingPathComponent("sample-video.mp4")
        try bytes.write(to: source)
        let receiver = folder.appendingPathComponent("received")
        let server = RemoteServer(manager: PaneManager(detectAgents: false), port: 0, httpPort: 0,
            secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.receivedFiles = ReceivedFileStore(directory: receiver)
        server.permissions.sendFiles = true
        server.start(); defer { server.stop() }
        let factory = ResumeFactory()
        let client = self.makeClient(server, factory: factory); defer { client.disconnect() }
        client.connect(); #expect(await client.waitUntilReady())
        #expect(await wait { client.fileTransferMaximumBytes != nil && client.permissions?.sendFiles == true })
        let stream = try #require(await factory.streams.first)
        await stream.slowDown()
        let upload = Task { try await client.uploadFile(at: source) }
        #expect(await wait { (client.fileUploadProgress ?? 0) > 0 })
        client.pauseForBackground(); client.resumeAfterBackground()
        let receipt = try await upload.value
        let path = try #require(receipt.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(await factory.addresses == ["127.0.0.1"])
        #expect(client.status == .connected)
    }
    @Test func navigationHasBackpressureAndExpiresWithoutReplayingAfterReconnect() async throws {
        let manager = PaneManager(detectAgents: false)
        let pane = manager.spawn(SpawnRequest(kind: .shell, cwd: NSTemporaryDirectory()))
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.start(); defer { server.stop(); manager.close(pane.id) }
        let factory = ResumeFactory()
        let client = makeClient(server, factory: factory); defer { client.disconnect() }
        client.connect(); #expect(await client.waitUntilReady())
        #expect(await wait { client.panes.contains { $0.id == pane.id } })
        let stream = try #require(await factory.streams.first)
        await stream.holdSend(); client.refresh()
        #expect(await wait { await stream.hasBlockedSend })
        let held = Task { await client.navigationInput(paneID: pane.id, bytes: Data([27,91,65])) { true } }
        try await Task.sleep(for: .milliseconds(50))
        let extra = await client.navigationInput(paneID: pane.id, bytes: Data([27,91,66])) { true }
        #expect(!extra)
        try await Task.sleep(for: .milliseconds(150))
        await stream.releaseSend()
        #expect(await held.value == false) // Expired event was skipped rather than catching up.
        client.disconnect(); client.connect(); #expect(await client.waitUntilReady())
        #expect(await wait { client.panes.contains { $0.id == pane.id } })
        #expect(await client.navigationInput(paneID: pane.id, bytes: Data([27,91,67])) { false } == false)
        #expect(await client.reviewedInput(paneID: pane.id, bytes: Data("echo XTX_NAV_TEST\r".utf8)))
        client.disconnect()
        #expect(await client.navigationInput(paneID: pane.id, bytes: Data([27,91,68])) { true } == false)
    }

}
#endif
