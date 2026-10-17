#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

/// Received files are inert, private and never placed in a workspace or executed automatically.
public struct ReceivedFileStore: Sendable {
    public let directory: URL
    public init(directory: URL = FileSecretStore.defaultDirectory.appendingPathComponent("received")) { self.directory = directory }

    public enum Failure: LocalizedError {
        case invalid, full, unsafeDirectory
        public var errorDescription: String? {
            switch self {
            case .invalid: "Choose a file up to 4 MB with a plain filename."
            case .unsafeDirectory: "Cleanup skipped because the received-files location is a symbolic link."
            case .full: "The received-files folder is full. Remove old files on the Mac first."
            }
        }
    }

    public func receive(name: String, data: Data) throws -> ReceivedFile {
        guard RemoteFileRules.validName(name), data.count <= RemoteFileRules.maximumBytes else { throw Failure.invalid }
        return try save(name: name, bytes: data.count) { try data.write(to: $0, options: .withoutOverwriting) }
    }

    public func receive(name: String, source: URL) throws -> ReceivedFile {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard RemoteFileRules.validName(name), values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes <= RemoteFileRules.maximumTransferBytes else { throw Failure.invalid }
        return try save(name: name, bytes: bytes) { try FileManager.default.copyItem(at: source, to: $0) }
    }

    private func save(name: String, bytes: Int, write: (URL) throws -> Void) throws -> ReceivedFile {
        let fm = FileManager.default
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.unsafeDirectory }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Keep paired clients from filling the disk with many small, otherwise valid uploads.
        let folders = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard folders.filter({ $0.lastPathComponent != ".incoming" }).count < 256 else { throw Failure.full }
        var stored = 0
        for folder in folders where folder.lastPathComponent != ".incoming" {
            let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
            let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            for file in files {
                let value = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                if value.isRegularFile == true, value.isSymbolicLink != true { stored += value.fileSize ?? 0 }
            }
        }
        guard stored + bytes <= RemoteFileRules.maximumStoredBytes else { throw Failure.full }
        let id = UUID().uuidString
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let url = folder.appendingPathComponent(name, isDirectory: false)
            try write(url)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return ReceivedFile(id: id, name: name, bytes: bytes, path: folder.appendingPathComponent(name).path)
    }
    public struct CleanupReport: Sendable {
        public var files = 0
        public var bytes = 0
        public var skipped = 0
    }

    /// Deletes only our UUID receipt directories, never symlinks or unfamiliar nested content.
    public func cleanup(olderThanDays days: Int, now: Date = .now) throws -> CleanupReport {
        var report = CleanupReport()
        let fm = FileManager.default
        guard days > 0, fm.fileExists(atPath: directory.path) else { return report }
        let root = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard root.isSymbolicLink != true else { throw Failure.unsafeDirectory }
        let cutoff = now.addingTimeInterval(-Double(min(days, 3650)) * 86_400)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        for folder in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
            let info = try folder.resourceValues(forKeys: keys)
            guard UUID(uuidString: folder.lastPathComponent) != nil, info.isDirectory == true,
                  info.isSymbolicLink != true, let changed = info.contentModificationDate else { report.skipped += 1; continue }
            let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
            var latest = changed, bytes = 0, safe = true
            for file in files {
                let value = try file.resourceValues(forKeys: keys)
                guard value.isRegularFile == true, value.isSymbolicLink != true,
                      RemoteFileRules.validName(file.lastPathComponent), let date = value.contentModificationDate else { safe = false; break }
                latest = max(latest, date); bytes += value.fileSize ?? 0
            }
            guard safe else { report.skipped += 1; continue }
            guard latest < cutoff else { continue }
            try fm.removeItem(at: folder)
            report.files += files.count; report.bytes += bytes
        }
        return report
    }

}
#endif
