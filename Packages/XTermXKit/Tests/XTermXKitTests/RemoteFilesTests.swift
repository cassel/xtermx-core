import Testing
import XTermXKit

struct RemoteFilesTests {
    @Test func remoteNamesCannotEscapeOrBecomeLocalPaths() {
        for name in ["", ".", "..", "../key", "/etc", "a/b", "a\\b", "bad\nname", "bad\0name"] { #expect(!SSHFileRules.validName(name)) }
        #expect(SSHFileRules.joining("/", "file.txt") == "/file.txt")
        #expect(SSHFileRules.joining("/home/user/", "a b") == "/home/user/a b")
        #expect(SSHFileRules.joining(".", "file") == "./file")
        #expect(SSHFileRules.joining("/safe", "../escape") == nil)
    }
    @Test func permissionsAndPostconditionsAreChecked() {
        #expect(SSHFileRules.permissions("644") == 0o644)
        #expect(SSHFileRules.permissions("0755") == 0o755)
        for invalid in ["888", "64", "10000", "-1", " 644", "u+x"] { #expect(SSHFileRules.permissions(invalid) == nil) }
        #expect(!SSHFileRules.removed("old", names: ["old"]))
        #expect(SSHFileRules.removed("old", names: ["other"]))
        #expect(!SSHFileRules.renamed("old", to: "new", names: ["old", "new"]))
        #expect(!SSHFileRules.renamed("old", to: "new", names: []))
        #expect(SSHFileRules.renamed("old", to: "new", names: ["new"]))
        #expect(SSHRemoteFile(name: "dir", size: nil, permissions: 0o040755).isDirectory)
        #expect(SSHRemoteFile(name: "link", size: nil, permissions: 0o120777).isLink)
    }
}
