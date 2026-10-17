import Foundation
import Testing
import XTermXKit

struct SSHTextDocumentTests {
    @Test func editorPreservesBytesAndRejectsConflictingWrites() throws {
        let bytes = Data("Olá\r\n你好\r\n".utf8)
        var doc = try SSHTextDocument(data: bytes)
        let unchanged = try doc.replacement()
        #expect(!doc.isDirty && unchanged == bytes)
        doc.text = "short\n"
        #expect(doc.isDirty)
        try doc.checkRemote(bytes)
        #expect(throws: SSHTextDocument.Failure.self) { try doc.checkRemote(Data("other edit".utf8)) }
        #expect(doc.text == "short\n")
        doc.didSave()
        #expect(!doc.isDirty)
        #expect(doc.original == Data("short\n".utf8))
    }
    @Test func binaryAndLargeFilesStayOutOfTheEditor() throws {
        #expect(throws: SSHTextDocument.Failure.self) { try SSHTextDocument(data: Data([0xff, 0xfe])) }
        #expect(throws: SSHTextDocument.Failure.self) { try SSHTextDocument(data: Data([65, 0, 66])) }
        #expect(throws: SSHTextDocument.Failure.self) { try SSHTextDocument(data: Data(repeating: 65, count: SSHTextDocument.limit + 1)) }
        var doc = try SSHTextDocument(data: Data())
        doc.text = String(repeating: "é", count: SSHTextDocument.limit)
        #expect(throws: SSHTextDocument.Failure.self) { try doc.replacement() }
    }
}
