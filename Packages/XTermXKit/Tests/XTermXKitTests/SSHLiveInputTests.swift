#if os(macOS)
import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import XTermXTerminalUI

/// Opt-in live SSH/SFTP fixture, never a saved user host. Requires port, host.pub, client, terminal_fixture.py and view.txt in the explicit fixture directory.
@MainActor @Suite(.serialized) struct SSHLiveInputTests {
    private func wait(_ check: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            if check() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return check()
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XTERMX_SSH_FIXTURE"] != nil)) func livePTYCursorModesResizeSFTPAndFullScreenPrograms() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["XTERMX_SSH_FIXTURE"] else {
            return // Explicit opt-in; ordinary tests never read user SSH keys or contact a host.
        }
        let root = URL(fileURLWithPath: fixture, isDirectory: true)
        let port = try #require(Int(String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8)))
        let username = NSUserName()
        let host = SSHHost(name: "Offline test SSH", host: "127.0.0.1", port: port, username: username,
                           auth: .ed25519Key, startupCommand: "/usr/bin/python3 -u '\(root.path)/terminal_fixture.py'")
        let endpoint = "127.0.0.1:\(port)"
        let previous = SSHHostStore.knownKey(endpoint)
        let publicKey = try String(contentsOf: root.appendingPathComponent("host.pub"), encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        SSHHostStore.remember(endpoint, key: publicKey)
        let secret = try String(contentsOf: root.appendingPathComponent("client"), encoding: .utf8)
        SSHHostStore.setSecret(secret, for: host)
        defer {
            SSHHostStore.deleteSecret(for: host)
            if let previous { SSHHostStore.remember(endpoint, key: previous) }
            else {
                var hosts = UserDefaults.standard.dictionary(forKey: "xtermx.ssh.known_hosts") ?? [:]
                hosts.removeValue(forKey: endpoint); UserDefaults.standard.set(hosts, forKey: "xtermx.ssh.known_hosts")
            }
        }
        let session = SSHSession(host: host)
        let view = TerminalView(frame: CGRect(x:0,y:0,width:1000,height:700), font:nil)
        session.feed.bind(view)
        session.connect(); defer { session.disconnect() }
        func has(_ marker: String) -> Bool { session.feed.visibleText().contains(marker) }
        #expect(await wait { has("SSH_READY") })
        #expect(session.status == .connected && session.feed.applicationCursor)
        #expect(await session.navigationInput(Data([27,79,65])))
        #expect(await wait { has("NAV=1b4f41") })
        session.feed.onResize?(101,37)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await session.reviewedInput(Data("S".utf8)))
        #expect(await wait { has("SIZE=37x101") })
        let listing = try await session.listFiles(at: root.path)
        #expect(listing.contains { $0.name == "view.txt" })
        let data = Data(repeating: 65, count: 150_000)
        let source = root.appendingPathComponent("upload-source-" + UUID().uuidString)
        let remote = root.appendingPathComponent("uploaded-漢字 " + UUID().uuidString)
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: remote) }
        try await session.uploadFile(at: source, to: remote.path)
        let received = try await session.readFile(at: remote.path, limit: 200_000)
        let same = received == data; #expect(same)
        var refusedOverwrite = false
        do { try await session.uploadFile(at: source, to: remote.path) } catch { refusedOverwrite = true }
        #expect(refusedOverwrite)
        #expect(await session.reviewedInput(Data("Q".utf8)))
        #expect(await wait { has("SSH_DONE") })
        #expect(await session.reviewedInput(Data("/usr/bin/vim -Nu NONE -i NONE -n '\(root.path)/view.txt'\r".utf8)))
        #expect(await wait { has("VIM_FIXTURE") })
        #expect(await session.navigationInput(Data([27,91,66])))
        #expect(await session.reviewedInput(Data("\u{1b}:q!\r".utf8)))
        #expect(await wait { !session.feed.applicationCursor })
        #expect(await session.reviewedInput(Data("LESSHISTFILE=/dev/null /usr/bin/less '\(root.path)/view.txt'\r".utf8)))
        #expect(await wait { has("[row 000]") })
        #expect(await session.navigationInput(Data([27,91,54,126])))
        #expect(await session.reviewedInput(Data("G".utf8)))
        #expect(await wait { has("(END)") })
        #expect(await session.reviewedInput(Data("q".utf8)))
        session.disconnect()
        #expect(await session.navigationInput(Data([27,91,65])) == false)
    }
}
#endif
