#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

@Suite struct ServicesWireTests {
    @Test func servicesMessageRoundTrips() throws {
        let list = [ServiceStatus(id: UUID(), name: "api", address: "localhost:8080", health: .down, lastError: "refused",
                                  checkedAt: Date(timeIntervalSince1970: 100))]
        let decoded = try WireCoding.decoder().decode(HostMessage.self, from: WireCoding.encoder().encode(HostMessage.services(list)))
        guard case .services(let back) = decoded else { Issue.record("Decoded \(decoded)"); return }
        #expect(back == list)
    }

    @Test func olderPermissionsAndWatchStateDecodeWithServicesOff() throws {
        let old = #"{"openSessions":true,"manageRooms":false,"sendFiles":false}"#
        #expect(try JSONDecoder().decode(RemotePermissions.self, from: Data(old.utf8)).shareServices == false)
        let state = WatchHostState(id: "h", name: "Mac", connected: true, panes: [], agents: [], approvals: [], screens: [:], machine: nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["services"] = nil
        let legacy = try JSONDecoder().decode(WatchHostState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.services == nil)
    }

    @Test func rpcRepliesFromANewerHostKeepKnownMessages() throws {
        let reply = RPCResponse(requestID: Data([1]), messages: [.services([]), .pong(Date(timeIntervalSince1970: 0))])
        var json = try JSONSerialization.jsonObject(with: WireCoding.encoder().encode(reply)) as! [String: Any]
        var messages = json["messages"] as! [Any]
        messages.append(["somethingNew": ["_0": 1]])
        json["messages"] = messages
        let decoded = try WireCoding.decoder().decode(RPCResponse.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.messages.count == 2)
    }

    @Test func serviceDownNoticeIsQuietOutsideAndCleaned() {
        #expect(NoticeMatrix().wants("mac", .serviceDown))
        #expect(!NoticeMatrix().wants("ntfy", .serviceDown))
        #expect(!NoticeMatrix().wants("telegram", .serviceDown))
        let status = ServiceStatus(id: UUID(), name: "api\u{1b}]0;x\u{7}", address: "localhost:8080", health: .down, lastError: "refused\r\nX: 1")
        let notice = AgentNoticeText.serviceDown(status)
        #expect(notice.event == .serviceDown)
        #expect(!notice.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        let lines = notice.body.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(!lines.contains { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        #expect(notice.title.hasSuffix("is down"))
        #expect(notice.body.contains("localhost:8080"))
    }
}

@MainActor
@Suite(.serialized) struct ServicesSharingTests {
    func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test func devicesSeeServicesOnlyWhenShared() async throws {
        let suite = "ServicesSharingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = ServiceMonitor(defaults: defaults, probe: { _ in .init(latency: 0.01) })
        monitor.setTargets([try #require(ServiceTarget(name: "api", address: "localhost:1"))])
        let server = RemoteServer(manager: PaneManager(detectAgents: false), port: 0, httpPort: 0, secretStore: MemorySecretStore(),
                                  bindHost: "127.0.0.1", services: monitor)
        server.start()
        defer { server.stop() }
        let phone = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "phone", platform: .iOS)
        phone.connect()
        defer { phone.disconnect() }
        #expect(await waitUntil { phone.snapshotReceived })
        try await Task.sleep(for: .milliseconds(200))
        #expect(phone.services.isEmpty)

        server.permissions.shareServices = true
        #expect(await waitUntil { phone.services.count == 1 })
        await monitor.checkNow()
        #expect(await waitUntil { phone.services.first?.health == .up })

        let watch = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "watch", platform: .watchOS)
        watch.connect()
        defer { watch.disconnect() }
        #expect(await waitUntil { watch.services.first?.health == .up })

        server.permissions.shareServices = false
        #expect(await waitUntil { phone.services.isEmpty })
    }
}
#endif
