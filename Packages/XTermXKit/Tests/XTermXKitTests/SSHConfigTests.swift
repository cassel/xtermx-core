import Foundation
import Testing
import XTermXKit

struct SSHConfigTests {
    private func parse(_ text: String, files: [String: String] = [:]) -> [SSHConfigEntry] {
        SSHConfig.parse(text, home: "/Users/me", read: { files[$0] }, expand: { pattern in
            files.keys.filter { SSHConfig.matches($0, pattern: pattern) }.sorted()
        })
    }

    @Test func aliasesBecomeEntriesAndWildcardsOnlyLendDefaults() {
        let entries = parse("""
        # personal boxes
        Host web web-alias
            HostName web.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_web

        Host *.internal
            User nobody

        Host *
            User fallback
            Port 22
        """)
        #expect(entries.map(\.alias) == ["web", "web-alias"])
        let web = entries[0]
        #expect(web.hostName == "web.example.com" && web.user == "deploy" && web.port == 2222)
        #expect(web.identityFile == "/Users/me/.ssh/id_web")
    }

    @Test func firstValueWinsAndStarDefaultsFill() {
        let entries = parse("""
        Host db
          Port 2200
        Host *
          User shared
          Port 22
          ProxyJump bastion
        Host bastion
          HostName 10.0.0.1
        """)
        let db = entries.first { $0.alias == "db" }!
        #expect(db.port == 2200 && db.user == "shared" && db.hostName == nil && db.proxyJump == "bastion")
        let bastion = parse("Host bastion\n  ProxyJump none\nHost *\n  ProxyJump hop").first!
        #expect(bastion.proxyJump == nil)
    }

    @Test func quotesEqualsAndCommentsAreHandled() {
        let entries = parse("""
        Host="quoted"   # trailing comment
        HostName = "my host.example"
        User=alice
        IdentityFile "~/My Keys/id_ed25519"
        """)
        #expect(entries.count == 1)
        #expect(entries.first?.alias == "quoted" && entries.first?.hostName == "my host.example" && entries.first?.user == "alice")
        #expect(entries.first?.identityFile == "/Users/me/My Keys/id_ed25519")
    }

    @Test func matchBlocksAreIgnoredUntilTheNextHost() {
        let entries = parse("""
        Match host *.corp exec "true"
          User matched
          Port 9
        Host plain
          HostName plain.example
        """)
        #expect(entries.count == 1 && entries.first?.alias == "plain" && entries.first?.user == nil && entries.first?.port == nil)
    }

    @Test func negatedAndPatternHostsAreSkipped() {
        let entries = parse("Host a !b c? d*\n  User u\nHost b\n  HostName b.example")
        #expect(entries.map(\.alias) == ["a", "b"])
        #expect(entries.last?.user == nil)
    }

    @Test func includesAreRelativeToSSHDirectoryAndGlobbed() {
        let files = [
            "/Users/me/.ssh/config.d/one": "Host one\n  HostName one.example",
            "/Users/me/.ssh/config.d/two": "Host two\n  HostName two.example\n  Include config.d/*",
        ]
        let entries = parse("Include config.d/*\nHost three\n  User x", files: files)
        #expect(entries.map(\.alias) == ["one", "two", "three"])
    }

    @Test func badPortsAndUnknownKeywordsDoNotBreakParsing() {
        let entries = parse("Host x\n  Port banana\n  ForwardAgent yes\n  HostName x.example")
        #expect(entries.first?.port == nil && entries.first?.hostName == "x.example")
    }

    @Test func proxyJumpHopsSplitWithUserAndPort() {
        let hops = SSHConfig.jumpHops("alice@bastion:2222,inner, ssh://bob@edge")
        #expect(hops == [.init(user: "alice", host: "bastion", port: 2222), .init(user: nil, host: "inner", port: nil),
                         .init(user: "bob", host: "edge", port: nil)])
        #expect(SSHConfig.jumpHops("none").isEmpty)
    }
}
