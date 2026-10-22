#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

@Suite struct HostAddressesTests {
    @Test func tailscaleComesFirstAndTheRestKeepTheirOrder() {
        #expect(HostAddresses.ordered(["192.168.1.5", "studio.local", "100.101.1.2", "fd7a:115c:a1e0::1", "203.0.113.4"])
                == ["100.101.1.2", "fd7a:115c:a1e0::1", "192.168.1.5", "studio.local", "203.0.113.4"])
    }

    @Test func onlyPlausibleAddressesAreKept() {
        let list = ["192.168.1.5", "", "a b", "evil\r\nhost", "x/y", "192.168.1.5", String(repeating: "a", count: 300)]
            + (1...20).map { "10.0.0.\($0)" }
        let valid = HostAddresses.valid(list)
        #expect(valid.first == "192.168.1.5")
        #expect(valid.count == HostAddresses.maximumCount)
        #expect(!valid.contains(""))
        #expect(!valid.contains { $0.contains(" ") || $0.contains("/") || $0.contains("\r") })
    }

    @Test func liveAddressesUpdateTheSavedPairingButKeepItsIdentity() {
        let saved = PairingInfo(hostName: "Studio", address: "studio.local", alternates: ["192.168.1.5"], secret: Data(repeating: 1, count: 32))
        let updated = HostAddresses.merge(saved, live: ["100.64.0.9", "192.168.1.9", "studio.local"])
        #expect(updated.id == saved.id)
        #expect(updated.address == "studio.local")
        #expect(updated.alternates == ["100.64.0.9", "192.168.1.9"])
        #expect(updated.secret == saved.secret)
        #expect(HostAddresses.merge(saved, live: []) == saved)
    }

    @Test func addressesMessageRoundTrips() throws {
        let back = try WireCoding.decoder().decode(HostMessage.self, from: WireCoding.encoder().encode(HostMessage.addresses(["100.64.0.9"])))
        guard case .addresses(let list) = back else { Issue.record("Decoded \(back)"); return }
        #expect(list == ["100.64.0.9"])
    }
}

@MainActor
@Suite(.serialized) struct LiveAddressesTests {
    func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test func clientsLearnTheHostsCurrentAddressesAndReconnectOnNetworkChange() async throws {
        let server = RemoteServer(manager: PaneManager(detectAgents: false), port: 0, httpPort: 0, secretStore: MemorySecretStore(),
                                  bindHost: "127.0.0.1")
        server.addressProvider = { ["192.168.1.9", "100.64.0.9"] }
        server.start()
        defer { server.stop() }
        let phone = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "phone", platform: .iOS)
        var told: [[String]] = []
        phone.onAddresses = { told.append($0) }
        phone.connect()
        defer { phone.disconnect() }
        #expect(await waitUntil { told.last == ["100.64.0.9", "192.168.1.9"] })
        #expect(phone.addressList.first == "127.0.0.1" || phone.addressList.contains("100.64.0.9"))

        server.addressProvider = { ["100.64.0.10"] }
        server.announceAddresses()
        #expect(await waitUntil { told.last == ["100.64.0.10"] })

        phone.networkChanged()
        #expect(await waitUntil(25) { phone.status == .connected && phone.activeAddress == "127.0.0.1" }, "falls back through the list to the working address")
    }
}
#endif
