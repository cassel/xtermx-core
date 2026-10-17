#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

/// Received files are inert, private and never placed in a workspace or executed automatically.
public struct ReceivedFileStore: Sendable {
    public let directory: URL
    public var limits: ReceivedFileLimits
    public init(directory: URL = FileSecretStore.defaultDirectory.appendingPathComponent("received"), limits: ReceivedFileLimits = .init()) {
        self.directory = directory
        self.limits = limits.isValid ? limits : .init()
    }

    public enum Failure: LocalizedError, Equatable {
        case invalid, full, unsafeDirectory, insufficientSpace, tooManyFiles
        case tooLarge(Int)
        public var errorDescription: String? {
            switch self {
            case .invalid: "Choose a regular file with a plain filename."
            case .tooLarge(let limit): "The file exceeds this host's limit of \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .binary))."
            case .insufficientSpace: "The host does not have enough free disk space for this transfer."
            case .tooManyFiles: "There are too many received files on the host. Remove old received files first."
            case .unsafeDirectory: "Cleanup skipped because the received-files location is a symbolic link."
            case .full: "The host's received-files storage limit was reached. Increase it in Remote access settings or remove old received files."
            }
        }
    }

    public func receive(name: String, data: Data) throws -> ReceivedFile {
        guard RemoteFileRules.validName(name) else { throw Failure.invalid }
        guard data.count <= min(RemoteFileRules.maximumBytes, limits.maximumFileBytes) else { throw Failure.tooLarge(min(RemoteFileRules.maximumBytes, limits.maximumFileBytes)) }
        return try save(name: name, bytes: data.count) { try data.write(to: $0, options: .withoutOverwriting) }
    }

    public func receive(name: String, source: URL) throws -> ReceivedFile {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard RemoteFileRules.validName(name), values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize else { throw Failure.invalid }
        guard bytes <= limits.maximumFileBytes else { throw Failure.tooLarge(limits.maximumFileBytes) }
        return try save(name: name, bytes: bytes) { try FileManager.default.copyItem(at: source, to: $0) }
    }

    public func checkCapacity(bytes: Int, reserved: Int = 0) throws {
        guard bytes >= 0, reserved >= 0, limits.isValid else { throw Failure.invalid }
        let (requested, overflow) = bytes.addingReportingOverflow(reserved)
        guard !overflow else { throw Failure.insufficientSpace }
        let fm = FileManager.default
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.unsafeDirectory }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folders = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard folders.filter({ $0.lastPathComponent != ".incoming" }).count < 256 else { throw Failure.tooManyFiles }
        if let quota = limits.maximumStoredBytes {
            guard requested <= quota else { throw Failure.full }
            var remaining = quota - requested
            for folder in folders where folder.lastPathComponent != ".incoming" {
                let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
                for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                    let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    if info.isRegularFile == true, info.isSymbolicLink != true {
                        let size = info.fileSize ?? 0
                        guard size <= remaining else { throw Failure.full }
                        remaining -= size
                    }
                }
            }
        }
        let free = (try fm.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value
        if let free, free < requested { throw Failure.insufficientSpace }
    }

    public static func transferErrorMessage(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.localizedDescription }
        let e = error as NSError
        if (e.domain == NSCocoaErrorDomain && e.code == CocoaError.fileWriteOutOfSpace.rawValue) || (e.domain == NSPOSIXErrorDomain && e.code == 28) {
            return Failure.insufficientSpace.localizedDescription
        }
        if (e.domain == NSCocoaErrorDomain && e.code == CocoaError.fileWriteNoPermission.rawValue) || (e.domain == NSPOSIXErrorDomain && [1, 13, 30].contains(e.code)) {
            return "The host cannot write to its received-files folder. Check that folder's permissions."
        }
        return "The host could not save this transfer (\(e.domain) \(e.code))."
    }

    private func save(name: String, bytes: Int, write: (URL) throws -> Void) throws -> ReceivedFile {
        let fm = FileManager.default
        try checkCapacity(bytes: bytes)
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
