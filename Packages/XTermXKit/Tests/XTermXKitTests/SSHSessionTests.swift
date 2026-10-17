#if os(macOS)
import Foundation
import Testing
import XTermXTerminalUI

struct SSHSessionTests {
    @MainActor @Test func credentialsAreCheckedWithoutConnectingOrWritingKeychain() {
        #expect(SSHSession.secretError(nil, for: .password) != nil)
        #expect(SSHSession.secretError("", for: .password) != nil)
        #expect(SSHSession.secretError("local test password", for: .password) == nil)
        #expect(SSHSession.secretError("not a private key", for: .ed25519Key) != nil)
    }
    @Test func olderSavedHostsInheritTheWindowTheme() throws {
        let original = SSHHost(name: "Test", host: "example.invalid", username: "deploy")
        let data = try JSONEncoder().encode(original)
        var fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields.removeValue(forKey: "themeID")
        let old = try JSONDecoder().decode(SSHHost.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(old.themeID == nil && old.id == original.id)
        var changed = old; changed.themeID = "midnight"
        #expect(try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(changed)).themeID == "midnight")
    }
    @Test func savedHostsKeepTheirIdentityAndHaveNoSecretField() throws {
        let host = SSHHost(name: "Test", host: "example.invalid", username: "deploy", auth: .ed25519Key)
        let data = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(SSHHost.self, from: data) == host)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["secret"] == nil && fields["password"] == nil && fields["privateKey"] == nil)
    }
}
#endif
