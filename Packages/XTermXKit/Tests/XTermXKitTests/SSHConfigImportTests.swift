#if os(macOS)
import Foundation
import Testing
import XTermXKit
import XTermXTerminalUI

struct SSHConfigImportTests {
    @Test func hostsSavedBeforeImportFieldsStillDecode() throws {
        let legacy = #"[{"id":"7D1C6E4A-3B5E-4C4B-9C1A-1F1E2D3C4B5A","name":"Old","host":"old.example","port":22,"username":"me","auth":"password","startupCommand":""}]"#
        let hosts = try JSONDecoder().decode([SSHHost].self, from: Data(legacy.utf8))
        #expect(hosts.count == 1 && hosts[0].identityFile == nil && hosts[0].proxyJump == nil && hosts[0].importedFrom == nil)
        #expect(hosts[0].needsKey == nil)
    }

    @Test func importCreatesHostsAndReimportUpdatesByAlias() {
        let entries = [SSHConfigEntry(alias: "web", hostName: "web.example", user: "deploy", port: 2222,
                                      identityFile: "/k/id", proxyJump: "bastion"),
                       SSHConfigEntry(alias: "bare")]
        let first = SSHHost.importCandidates(entries, from: "/Users/me/.ssh/config", existing: [], defaultUser: "me")
        #expect(first.map(\.host.name) == ["web", "bare"] && first.allSatisfy { !$0.isUpdate })
        let web = first[0].host
        #expect(web.host == "web.example" && web.port == 2222 && web.username == "deploy")
        #expect(web.identityFile == "/k/id" && web.proxyJump == "bastion" && web.importedFrom == "/Users/me/.ssh/config")
        #expect(first[1].host.host == "bare" && first[1].host.username == "me" && first[1].host.port == 22)

        var saved = first.map(\.host)
        saved[0].startupCommand = "tmux"
        let changed = [SSHConfigEntry(alias: "web", hostName: "web2.example", user: "deploy")]
        let second = SSHHost.importCandidates(changed, from: "/Users/me/.ssh/config", existing: saved, defaultUser: "me")
        #expect(second.count == 1 && second[0].isUpdate)
        #expect(second[0].host.id == saved[0].id && second[0].host.host == "web2.example" && second[0].host.startupCommand == "tmux")
        let merged = SSHHost.merging(second.map(\.host), into: saved)
        #expect(merged.count == 2 && merged[0].host == "web2.example")
    }

    @Test func onlyUnencryptedEd25519KeysAreLoaded() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("id_rsa")
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nnot really\n-----END OPENSSH PRIVATE KEY-----\n".write(to: bad, atomically: true, encoding: .utf8)
        #expect(SSHHost.loadableKey(at: bad.path) == nil)
        #expect(SSHHost.loadableKey(at: dir.appendingPathComponent("missing").path) == nil)
    }

    @MainActor @Test func jumpHopsResolveSavedAliasesFirst() {
        let bastion = SSHHost(name: "bastion", host: "10.0.0.1", port: 2200, username: "ops")
        var target = SSHHost(name: "db", host: "db.internal", username: "deploy")
        target.proxyJump = "bastion,carol@edge:2022"
        let hops = SSHSession.jumpChain(for: target, saved: [bastion, target])
        #expect(hops.map(\.host) == ["10.0.0.1", "edge"])
        #expect(hops[0].id == bastion.id && hops[1].username == "carol" && hops[1].port == 2022)
        #expect(hops[1].id != target.id) // a password never goes to another machine
        var keyed = target
        keyed.auth = .ed25519Key
        #expect(SSHSession.jumpChain(for: keyed, saved: [bastion])[1].id == keyed.id) // a key may be borrowed
        #expect(hops.allSatisfy { $0.proxyJump == nil })
        #expect(SSHSession.jumpChain(for: SSHHost(name: "x", host: "x", username: "u"), saved: []).isEmpty)
    }

    @Test func hopFailuresNameTheHop() {
        let text = SSHSession.Failure.hop("bastion (10.0.0.1:22)", "Connection refused").localizedDescription
        #expect(text.contains("bastion") && text.contains("Connection refused"))
    }
}
#endif
