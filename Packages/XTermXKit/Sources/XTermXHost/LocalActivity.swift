#if os(macOS) || os(Linux)
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XTermXKit

/// Deliberately excludes terminal text, commands, folders, agent names and credentials.
public struct LocalPaneActivity: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case opened, closed }
    public var date: Date
    public var action: Action
    public var paneReference: String
    public var kind: PaneKind
    public var openedByAgent: Bool
    public init(action: Action, pane: PaneInfo, date: Date = .now) {
        self.date = date; self.action = action; kind = pane.kind; openedByAgent = pane.openedByAgent
        paneReference = SHA256.hash(data: Data(pane.id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public actor LocalActivityStore {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("activity.json") }
    public init(directory: URL = FileSecretStore.defaultDirectory.appendingPathComponent("privacy")) { self.directory = directory }
    public struct Failure: LocalizedError { public var errorDescription: String? = "The local log path is not a regular private file." }
    private func checkPath() throws {
        for url in [directory, file] {
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) {
                guard values.isSymbolicLink != true, url == directory ? values.isDirectory == true : values.isRegularFile == true else { throw Failure() }
            }
        }
    }
    private func load() throws -> [LocalPaneActivity] {
        try checkPath()
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else { throw Failure() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LocalPaneActivity].self, from: Data(contentsOf: file))
    }
    private func save(_ records: [LocalPaneActivity]) throws {
        try checkPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func records(days: Int, now: Date = .now) throws -> [LocalPaneActivity] {
        let cutoff = now.addingTimeInterval(-Double(min(90, max(30, days))) * 86400)
        let all = try load()
        let kept = Array(all.filter { $0.date >= cutoff && $0.date <= now }.suffix(2000))
        if kept.count != all.count { try save(kept) }
        return kept
    }
    public func append(_ record: LocalPaneActivity, days: Int, now: Date = .now) throws {
        var kept = try records(days: days, now: now)
        kept.append(record)
        try save(Array(kept.suffix(2000)))
    }
    public func clear() throws {
        try checkPath()
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
#endif
