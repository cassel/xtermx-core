#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

public struct GitWorktreeRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var repository: String
    public var path: String
    public var branch: String
    public var baseBranch: String?
    public var baseCommit: String
    public var agentID: String
    public var createdAt: Date
}
public struct GitWorktreeReview: Sendable {
    public var changes: String
    public var commitsAhead: Int
    public var clean: Bool { changes.isEmpty }
}
public struct PreparedPaneSpawn: Sendable {
    public var request: SpawnRequest
    public var worktree: GitWorktreeRecord?
}

/// Every mutation is serialized, outside the UI actor. No forced removal or automatic merge.
public actor GitWorktreeStore {
    public struct Failure: LocalizedError {
        public var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    public let directory: URL
    public init(directory: URL = FileSecretStore.defaultDirectory.appendingPathComponent("worktrees")) { self.directory = directory }
    private var recordsURL: URL { directory.appendingPathComponent("records", isDirectory: true) }
    private func treeURL(_ id: UUID) -> URL { directory.appendingPathComponent("trees", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true) }
    private func indexURL(_ record: GitWorktreeRecord) -> URL { recordsURL.appendingPathComponent(record.id.uuidString + ".json") }

    private func git(_ args: [String], at cwd: String) throws -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd] + args
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        for key in ["GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"] { environment[key] = nil }
        process.environment = environment
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func checked(_ args: [String], at cwd: String) throws -> String {
        let (status, output) = try git(args, at: cwd)
        guard status == 0 else { throw Failure(String(output.prefix(1200))) }
        return output
    }
    private func validate(_ record: GitWorktreeRecord) throws {
        guard URL(fileURLWithPath: record.path).standardizedFileURL.path == treeURL(record.id).standardizedFileURL.path,
              record.branch.hasPrefix("xtermx/") else { throw Failure("This worktree is outside XTermX's managed directory.") }
    }
    public func create(cwd: String, agentID: String) throws -> GitWorktreeRecord? {
        let cwd = (cwd as NSString).expandingTildeInPath
        let (status, root) = try git(["rev-parse", "--show-toplevel"], at: cwd)
        guard status == 0 else {
            var ancestor = URL(fileURLWithPath: cwd).standardizedFileURL
            var marker = false
            while true {
                if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) { marker = true; break }
                let parent = ancestor.deletingLastPathComponent()
                if parent.path == ancestor.path { break }
                ancestor = parent
            }
            if root.contains("not a git repository"), !marker { return nil }
            throw Failure(String(root.prefix(1200)))
        }
        let commit = try checked(["rev-parse", "HEAD"], at: root)
        let branch = try checked(["rev-parse", "--abbrev-ref", "HEAD"], at: root)
        let slug = String(agentID.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }.prefix(40))
        let prefix = "xtermx/" + (slug.isEmpty ? "agent" : slug) + "-"
        let existing = Set(try checked(["for-each-ref", "--format=%(refname:short)", "refs/heads/" + prefix + "*"], at: root).split(separator: "\n").map(String.init))
        guard let number = (1...10_000).first(where: { !existing.contains(prefix + String($0)) }) else { throw Failure("Too many isolated branches for this agent. Review kept worktrees first.") }
        let id = UUID(), target = treeURL(id)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = prefix + String(number)
        _ = try checked(["worktree", "add", "-b", name, target.path, "HEAD"], at: root)
        let record = GitWorktreeRecord(id: id, repository: root, path: target.path, branch: name,
                                       baseBranch: branch == "HEAD" ? nil : branch, baseCommit: commit,
                                       agentID: agentID, createdAt: .now)
        try FileManager.default.createDirectory(at: recordsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: indexURL(record), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL(record).path)
        return record
    }
    public func records() throws -> [GitWorktreeRecord] {
        guard FileManager.default.fileExists(atPath: recordsURL.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: recordsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try decoder.decode(GitWorktreeRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func review(_ record: GitWorktreeRecord) throws -> GitWorktreeReview {
        try validate(record)
        guard try checked(["branch", "--show-current"], at: record.path) == record.branch else {
            throw Failure("This worktree is on another branch. Switch it back in Git before reviewing it here.")
        }
        let changes = try checked(["status", "--porcelain"], at: record.path)
        let ahead = try checked(["rev-list", "--count", (record.baseBranch ?? record.baseCommit) + ".." + record.branch], at: record.repository)
        return GitWorktreeReview(changes: changes, commitsAhead: Int(ahead) ?? 0)
    }
    public func remove(_ record: GitWorktreeRecord) throws {
        try validate(record)
        guard try review(record).clean else { throw Failure("This worktree has changes. Keep it or commit them before removing its folder.") }
        _ = try checked(["worktree", "remove", record.path], at: record.repository)
        try FileManager.default.removeItem(at: indexURL(record))
        // Its branch is deliberately kept, including all committed work.
    }
    public func merge(_ record: GitWorktreeRecord) throws {
        try validate(record)
        guard let base = record.baseBranch else { throw Failure("This worktree started from a detached commit. Choose a merge destination in Git.") }
        guard try review(record).clean else { throw Failure("Commit or keep the worktree's changes before merging.") }
        let current = try checked(["branch", "--show-current"], at: record.repository)
        guard current == base else { throw Failure("The repository is on another branch. Switch to \(base) yourself before merging.") }
        guard try checked(["status", "--porcelain"], at: record.repository).isEmpty else { throw Failure("The destination has changes. Commit or stash them before merging.") }
        for operation in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            guard try git(["rev-parse", "--verify", operation], at: record.repository).0 != 0 else { throw Failure("Finish the repository's current Git operation before merging.") }
        }
        let (status, output) = try git(["merge", "--no-ff", "--no-edit", record.branch], at: record.repository)
        guard status == 0 else {
            if try git(["rev-parse", "--verify", "MERGE_HEAD"], at: record.repository).0 == 0 {
                _ = try checked(["merge", "--abort"], at: record.repository)
            }
            throw Failure("Merge did not complete; the worktree was kept. " + String(output.prefix(800)))
        }
    }
}
#endif
