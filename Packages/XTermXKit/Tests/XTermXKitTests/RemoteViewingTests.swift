import Foundation
import Testing
@testable import XTermXKit
#if os(macOS)
@testable import XTermXHost
#endif

@Suite struct RemoteViewingLeaseTests {
    @Test func pollingExpiresAndRefreshesOnlyTheWatchedPane() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var leases = RemoteViewLeases()
        leases.poll("a", now: now)
        leases.poll("b", now: now.addingTimeInterval(5))
        #expect(leases.active(now: now.addingTimeInterval(9)) == ["a", "b"])
        #expect(leases.active(now: now.addingTimeInterval(10)) == ["b"])
        leases.poll("b", now: now.addingTimeInterval(12))
        #expect(leases.active(now: now.addingTimeInterval(21)) == ["b"])
        #expect(leases.active(now: now.addingTimeInterval(22)).isEmpty)
        leases.poll("a", now: now.addingTimeInterval(30))
        leases.remove("a")
        #expect(leases.active(now: now.addingTimeInterval(30)).isEmpty)
        leases.poll("c", now: now)
        leases.clear()
        #expect(leases.active(now: now).isEmpty)
    }
}

#if os(macOS)
@MainActor @Suite struct RemoteViewingIntegrationTests {
    func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return predicate()
    }
    @Test func connectedIsNotWatchingAndDetachOrCloseReleasesThePane() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.start()
        defer { server.stop() }
        let pane = manager.spawn(.init(kind: .shell, cwd: NSTemporaryDirectory()))
        defer { manager.close(pane.id) }
        let client = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "viewer", platform: .iOS)
        client.connect()
        defer { client.disconnect() }
        #expect(await client.waitUntilReady())
        #expect(server.watchedPaneIDs().isEmpty)
        let token = client.attach(paneID: pane.id) { _ in }
        #expect(await wait { server.watchedPaneIDs() == [pane.id] })
        client.detach(paneID: pane.id, token: token)
        #expect(await wait { server.watchedPaneIDs().isEmpty })
        client.requestScreen(paneID: pane.id)
        #expect(await wait { server.watchedPaneIDs() == [pane.id] })
        #expect(server.watchedPaneIDs(now: .now.addingTimeInterval(11)).isEmpty)
        manager.close(pane.id)
        #expect(server.watchedPaneIDs().isEmpty)
        server.stop()
        #expect(server.watchedPaneIDs().isEmpty)
    }
}
#endif
