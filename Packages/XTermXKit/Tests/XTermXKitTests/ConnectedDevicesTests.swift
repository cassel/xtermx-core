#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost

@Suite struct ConnectedDevicesTests {
    @Test func sameNameIsNotTheSameDeviceAndOnlyVerifiedReconnectsCollapse() throws {
        let first = ConnectedDevice(id: UUID(), name: "iPhone", platform: .iOS, since: .now, address: "127.0.0.1", identity: "first")
        var again = first; again.id = UUID(); again.address = "127.0.0.2"
        var other = first; other.id = UUID(); other.identity = "second"
        var unverified = first; unverified.id = UUID(); unverified.identity = nil
        var unknown = unverified; unknown.id = UUID()
        let grouped = ConnectedDevice.grouped([first, again, other, unverified, unknown])
        #expect(grouped.count == 4)
        #expect(grouped[0].id == first.id)
        #expect(grouped[0].connectionCount == 2)
        #expect(grouped[1].identity == "second")
        #expect(ConnectedDevice.grouped([again]).first?.id == again.id)
        var names = DeviceNames()
        try names.set("  Cassel’s phone  ", identity: "first")
        #expect(names.name(identity: again.identity, reported: again.name) == "Cassel’s phone")
        #expect(names.name(identity: other.identity, reported: other.name) == "iPhone")
        #expect(names.name(identity: nil, reported: "iPhone") == "iPhone")
        let restored = try JSONDecoder().decode(DeviceNames.self, from: JSONEncoder().encode(names))
        #expect(restored == names)
        #expect(throws: PaneNameRules.InvalidPaneName.self) { try names.set("bad\nname", identity: "first") }
        #expect(names.name(identity: "first", reported: "iPhone") == "Cassel’s phone")
        try names.set("", identity: "first")
        #expect(names.name(identity: "first", reported: "iPhone") == "iPhone")
    }

    @Test func historySurvivesRestartAndReconnectUpdatesInsteadOfDuplicating() throws {
        var history = DeviceHistory()
        let first = Date(timeIntervalSince1970: 100), next = Date(timeIntervalSince1970: 200)
        history.record(identity: "a", name: "iPhone", platform: .iOS, at: first)
        history.record(identity: "b", name: "iPhone", platform: .iOS, at: first)
        let restored = try JSONDecoder().decode(DeviceHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.devices.count == 2)
        history = restored
        history.record(identity: "a", name: "Phone", platform: .iOS, at: next)
        #expect(history.devices.count == 2)
        #expect(history.devices[0].firstConnectedAt == first)
        #expect(history.devices[0].lastConnectedAt == next)
        #expect(history.devices[0].name == "Phone")
        history.record(identity: "", name: "Unverified", platform: .iOS)
        #expect(history.devices.count == 2)
    }

    @Test func localRoutesHaveNoEmptyOrDuplicateEntries() {
        let routes = HostIdentity.addresses()
        #expect(routes.allSatisfy { !$0.isEmpty })
        #expect(Set(routes).count == routes.count)
        #expect(!HostIdentity.hostName.isEmpty)
    }
}

@MainActor @Suite(.serialized) struct ConnectedDevicesIntegrationTests {
    func wait(_ predicate: () -> Bool) async -> Bool {
        let end = Date.now.addingTimeInterval(8)
        while Date.now < end {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return predicate()
    }
    @Test func verifiedDuplicateConnectionsShareOneDeviceAndOtherPhonesStaySeparate() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        var history = DeviceHistory()
        server.onDeviceVerified = { device in
            if let identity = device.identity { history.record(identity: identity, name: device.name, platform: device.platform) }
        }
        server.onDevicesForgotten = { history = DeviceHistory() }
        server.start()
        defer { server.stop() }
        let pairing = server.pairing(address: "127.0.0.1")
        let identity = DeviceIdentity()
        let a = HostConnection(pairing: pairing, deviceName: "iPhone", platform: .iOS, identity: identity)
        let b = HostConnection(pairing: pairing, deviceName: "iPhone", platform: .iOS, identity: identity)
        let c = HostConnection(pairing: pairing, deviceName: "iPhone", platform: .iOS, identity: DeviceIdentity())
        defer { a.disconnect(); b.disconnect(); c.disconnect() }
        a.connect(); b.connect(); c.connect()
        #expect(await a.waitUntilReady())
        #expect(await b.waitUntilReady())
        #expect(await c.waitUntilReady())
        #expect(await wait { server.devices.count == 2 && server.devices.contains { $0.connectionCount == 2 } })
        let key = try #require(server.devices.first { $0.connectionCount == 2 }?.identity)
        a.disconnect()
        #expect(await wait { server.devices.count == 2 && server.devices.allSatisfy { $0.connectionCount == 1 } })
        #expect(server.devices.contains { $0.identity == key })
        b.disconnect()
        #expect(await wait { server.devices.count == 1 })
        #expect(server.devices.first?.identity != key)
        c.disconnect()
        #expect(await wait { server.devices.isEmpty })
        #expect(history.devices.count == 2) // Offline is not forgotten.
        server.stop()
        #expect(history.devices.count == 2)
        server.rotateSecret() // Explicit Forget all devices clears the remembered list too.
        #expect(history.devices.isEmpty)
    }
}
#endif
