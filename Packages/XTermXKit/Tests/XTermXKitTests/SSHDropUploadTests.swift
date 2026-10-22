import Foundation
import Testing
@testable import XTermXKit

@Suite struct SSHDropUploadTests {
    @Test func osc7GivesTheShellFolder() {
        #expect(SSHFileRules.directory(fromOSC7: "file://box.local/home/me/my%20app") == "/home/me/my app")
        #expect(SSHFileRules.directory(fromOSC7: "file:///srv") == "/srv")
        #expect(SSHFileRules.directory(fromOSC7: "7;file://box/tmp") == "/tmp")
        #expect(SSHFileRules.directory(fromOSC7: "/plain/path") == "/plain/path")
        #expect(SSHFileRules.directory(fromOSC7: "https://x/y") == nil)
        #expect(SSHFileRules.directory(fromOSC7: "file://box/a%0Ab") == nil)
        #expect(SSHFileRules.directory(fromOSC7: "relative") == nil)
    }

    @Test func conflictsGetAFreeName() {
        #expect(SSHFileRules.freeName("notes.txt", taken: []) == "notes.txt")
        #expect(SSHFileRules.freeName("notes.txt", taken: ["notes.txt"]) == "notes 2.txt")
        #expect(SSHFileRules.freeName("notes.txt", taken: ["notes.txt", "notes 2.txt"]) == "notes 3.txt")
        #expect(SSHFileRules.freeName("Makefile", taken: ["Makefile"]) == "Makefile 2")
        #expect(SSHFileRules.freeName(".env", taken: [".env"]) == ".env 2")
    }
}
