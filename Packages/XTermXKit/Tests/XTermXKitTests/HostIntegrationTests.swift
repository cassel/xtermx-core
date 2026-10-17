#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit
import XTermXNIO

/// A real host (PTY + server) and a real client talking over loopback.
@MainActor
@Suite(.serialized) struct HostIntegrationTests {
    func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test func streamsPaneOutputToClient() async throws {
        let manager = PaneManager()
        let server = RemoteServer(manager: manager, port: 48_910, httpPort: 48_911)
        server.start()
        defer { server.stop() }
        #expect(server.isRunning)

        let pane = manager.spawn(SpawnRequest(kind: .shell, cwd: NSTemporaryDirectory(), initialInput: "echo XTX_$((40+2))"))
        let client = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "test", platform: .macOS)
        client.connect()
        #expect(await waitUntil { client.status == .connected && client.panes.contains { $0.id == pane.id } })

        var received = Data()
        client.attach(paneID: pane.id) { received.append($0) }
        #expect(await waitUntil { String(decoding: received, as: UTF8.self).contains("XTX_42") })

        client.sendLine(paneID: pane.id, text: "echo SECOND_$((1+1))")
        #expect(await waitUntil { String(decoding: received, as: UTF8.self).contains("SECOND_2") })

        // The Watch path: sealed HTTP request/response, plain-text screen.
        let watch = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "watch", platform: .watchOS)
        watch.connect()
        watch.requestScreen(paneID: pane.id)
        #expect(await waitUntil { (watch.screens[pane.id] ?? []).contains { $0.contains("SECOND_2") } })
        watch.disconnect()
        client.disconnect()
        manager.close(pane.id)
    }

    /// What a Linux node does: the NIO client, and a pairing whose first address is dead.
    @Test func linuxClientFallsBackToTheNextAddress() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 48_914, httpPort: 48_915, secretStore: MemorySecretStore())
        server.start()
        defer { server.stop() }
        let pane = manager.spawn(SpawnRequest(kind: .shell, cwd: NSTemporaryDirectory(), initialInput: "echo NIO_$((6*7))"))

        // 127.0.0.2 has nothing listening on that port; 127.0.0.1 does.
        var pairing = server.pairing(addresses: ["127.0.0.2", "127.0.0.1"])
        pairing.port = 48_914
        let client = HostConnection(pairing: pairing, deviceName: "linux-node", platform: .macOS, transport: NIOFrameTransport.factory)
        client.connect()
        #expect(await client.waitUntilReady(timeout: 20))
        #expect(client.activeAddress == "127.0.0.1")
        #expect(server.devices.contains { $0.name == "linux-node" })

        var received = Data()
        client.attach(paneID: pane.id) { received.append($0) }
        #expect(await waitUntil { String(decoding: received, as: UTF8.self).contains("NIO_42") })
        client.sendLine(paneID: pane.id, text: "echo TYPED_$((2+3))")
        #expect(await waitUntil { String(decoding: received, as: UTF8.self).contains("TYPED_5") })
        client.disconnect()
        manager.close(pane.id)
    }

    @Test func rejectsWrongSecret() async throws {
        let manager = PaneManager()
        let server = RemoteServer(manager: manager, port: 48_912, httpPort: 48_913)
        server.start()
        defer { server.stop() }
        var pairing = server.pairing(address: "127.0.0.1")
        pairing.secret = SecureRandom.bytes(32)
        let client = HostConnection(pairing: pairing, deviceName: "intruder", platform: .watchOS)
        client.connect()
        #expect(await waitUntil(5) { if case .failed = client.status { return true } else { return false } })
        #expect(client.panes.isEmpty)
        client.disconnect()
    }

    /// A phone takes a pane to its size while it watches; when it leaves, the pane is the Mac's size again.
    @Test func paneGoesBackToTheMacSizeWhenThePhoneLeaves() {
        let manager = PaneManager(detectAgents: false)
        let pane = manager.spawn(SpawnRequest(kind: .shell, cwd: NSTemporaryDirectory()))
        defer { manager.close(pane.id) }
        func size() -> (Int, Int) { manager.session(pane.id).map { ($0.info.cols, $0.info.rows) } ?? (0, 0) }
        let phone = UUID(), tablet = UUID()

        manager.resize(pane.id, cols: 160, rows: 48) // the Mac's view
        manager.resize(pane.id, cols: 50, rows: 40, device: phone)
        #expect(size() == (50, 40))
        manager.resize(pane.id, cols: 90, rows: 30, device: tablet)
        manager.release(pane.id, device: phone)
        #expect(size() == (90, 30)) // the tablet still watches
        manager.release(device: tablet)
        #expect(size() == (160, 48))

        // Typing on the Mac takes the pane back at once; the phone leaving later changes nothing.
        manager.resize(pane.id, cols: 50, rows: 40, device: phone)
        manager.resize(pane.id, cols: 150, rows: 45)
        manager.release(pane.id, device: phone)
        #expect(size() == (150, 45))

        // The Mac's window moving or a card showing doesn't take the pane from the phone; leaving does.
        manager.resize(pane.id, cols: 50, rows: 40, device: phone)
        manager.setHomeSize(pane.id, cols: 140, rows: 44)
        #expect(size() == (50, 40))
        manager.release(pane.id, device: phone)
        #expect(size() == (140, 44))
        manager.setHomeSize(pane.id, cols: 130, rows: 40) // nobody holds it: applies at once
        #expect(size() == (130, 40))
    }
}
#endif
