#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

@Suite struct ClipboardSyncTests {
    @Test func messagesRoundTrip() throws {
        let client: [ClientMessage] = [.clipboard(text: "héllo"), .clipboardOptIn(true)]
        for m in client {
            let back = try WireCoding.decoder().decode(ClientMessage.self, from: WireCoding.encoder().encode(m))
            switch (m, back) {
            case (.clipboard(let a), .clipboard(let b)): #expect(a == b)
            case (.clipboardOptIn(let a), .clipboardOptIn(let b)): #expect(a == b)
            default: Issue.record("Decoded \(back) from \(m)")
            }
        }
        let back = try WireCoding.decoder().decode(HostMessage.self, from: WireCoding.encoder().encode(HostMessage.clipboard(text: "x")))
        guard case .clipboard(let text) = back else { Issue.record("Decoded \(back)"); return }
        #expect(text == "x")
    }

    @Test func olderPermissionsLeaveClipboardOff() throws {
        let old = #"{"openSessions":true,"manageRooms":false,"sendFiles":false,"shareDevServers":true}"#
        #expect(try JSONDecoder().decode(RemotePermissions.self, from: Data(old.utf8)).shareClipboard == false)
    }

    @Test func onlyTextUpTo256KB() {
        #expect(ClipboardRules.accepts("a"))
        #expect(!ClipboardRules.accepts(""))
        #expect(ClipboardRules.accepts(String(repeating: "a", count: 256 * 1024)))
        #expect(!ClipboardRules.accepts(String(repeating: "a", count: 256 * 1024 + 1)))
    }

    @Test func noEchoOfWhatCameFromThePeer() {
        var sync = ClipboardSync()
        #expect(sync.incoming("from phone") == "from phone")
        #expect(sync.outgoing("from phone") == nil)
        #expect(sync.outgoing("typed on mac") == "typed on mac")
        #expect(sync.outgoing("typed on mac") == nil)
        #expect(sync.incoming("typed on mac") == nil)
        #expect(sync.incoming(String(repeating: "x", count: 300_000)) == nil)
        #expect(sync.outgoing("from phone") == "from phone")
    }
}

@MainActor
@Suite(.serialized) struct SharedClipboardTests {
    func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test func clipboardFlowsOnlyBetweenOptedInDevicesWithoutEcho() async throws {
        let server = RemoteServer(manager: PaneManager(detectAgents: false), port: 0, httpPort: 0, secretStore: MemorySecretStore(),
                                  bindHost: "127.0.0.1")
        var onMac: [String] = []
        server.onClipboard = { text, _ in onMac.append(text) }
        server.start()
        defer { server.stop() }
        let phone = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "phone", platform: .iOS)
        let other = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "other", platform: .iOS)
        var onPhone: [String] = []
        var onOther: [String] = []
        phone.onClipboard = { onPhone.append($0) }
        other.onClipboard = { onOther.append($0) }
        phone.shareClipboard = true
        phone.connect(); other.connect()
        defer { phone.disconnect(); other.disconnect() }
        #expect(await waitUntil { phone.snapshotReceived && other.snapshotReceived })

        // Off on the Mac: the phone sends nothing (an older host would drop the connection).
        #expect(!phone.sendClipboard("too early"))
        server.permissions.shareClipboard = true
        #expect(await waitUntil { phone.canShareClipboard })
        #expect(!other.canShareClipboard)
        try await Task.sleep(for: .milliseconds(200))

        #expect(phone.sendClipboard("from phone"))
        #expect(await waitUntil { onMac == ["from phone"] })
        server.shareClipboard("from mac")
        #expect(await waitUntil { onPhone == ["from mac"] })
        try await Task.sleep(for: .milliseconds(200))
        #expect(onOther.isEmpty)
        #expect(!phone.status.isFailed)
    }
}

extension HostConnection.Status {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}
#endif
