#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost

@Suite struct ReceivedCleanupTests {
    @Test func retentionOnlyRemovesExpiredRecognizedReceipts() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = ReceivedFileStore(directory: root.appendingPathComponent("received"))
        let now = Date.now, old = now.addingTimeInterval(-10 * 86_400)
        func datedReceipt(_ name: String, _ date: Date) throws -> URL {
            let receipt = try store.receive(name: name, data: Data("keep me safe".utf8))
            let folder = store.directory.appendingPathComponent(receipt.id)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: folder.appendingPathComponent(name).path)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
            return folder
        }
        let expired = try datedReceipt("old.txt", old)
        let fresh = try datedReceipt("new.txt", now)
        let boundary = try datedReceipt("boundary.txt", now.addingTimeInterval(-7 * 86_400))
        let unfamiliar = store.directory.appendingPathComponent("owner-folder")
        try fm.createDirectory(at: unfamiliar, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: unfamiliar.appendingPathComponent("mine.txt"))
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("outside.txt"))
        let symlink = store.directory.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let nested = try datedReceipt("nested.txt", old)
        try fm.createDirectory(at: nested.appendingPathComponent("user-content"), withIntermediateDirectories: false)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: nested.path)
        #expect(try store.cleanup(olderThanDays: 0, now: now).files == 0)
        #expect(fm.fileExists(atPath: expired.path))
        let result = try store.cleanup(olderThanDays: 7, now: now)
        #expect(result.files == 1)
        #expect(result.skipped >= 3)
        #expect(!fm.fileExists(atPath: expired.path))
        for folder in [fresh, boundary, unfamiliar, outside, nested] { #expect(fm.fileExists(atPath: folder.path)) }
        #expect(try String(contentsOf: outside.appendingPathComponent("outside.txt"), encoding: .utf8) == "outside")
        #expect(try store.cleanup(olderThanDays: 7, now: now).files == 0)
    }
    @Test func symbolicLinkRootIsNeverCleaned() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try fm.createDirectory(at: actual, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("received")
        try fm.createSymbolicLink(at: link, withDestinationURL: actual)
        #expect(throws: ReceivedFileStore.Failure.self) { try ReceivedFileStore(directory: link).cleanup(olderThanDays: 1) }
        #expect(fm.fileExists(atPath: actual.path))
    }
}
#endif
