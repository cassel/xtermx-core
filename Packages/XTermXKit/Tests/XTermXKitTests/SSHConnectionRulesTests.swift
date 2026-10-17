import Testing
import XTermXKit

struct SSHConnectionRulesTests {
    @Test func endpointsAreValidatedBeforeNetworkAccess() {
        for host in ["server.tailnet.ts.net", "100.64.0.1", "::1"] {
            #expect(SSHConnectionRules.error(host: host, port: 22, username: "deploy") == nil)
        }
        for host in ["", "ssh://server", "server\ncommand", " server"] {
            #expect(SSHConnectionRules.error(host: host, port: 22, username: "deploy") != nil)
        }
        #expect(SSHConnectionRules.error(host: "server", port: 0, username: "deploy") != nil)
        #expect(SSHConnectionRules.error(host: "server", port: 65536, username: "deploy") != nil)
        #expect(SSHConnectionRules.error(host: "server", port: 22, username: "bad\nuser") != nil)
    }
}
