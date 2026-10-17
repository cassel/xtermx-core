#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost
@testable import XTermXKit

struct WorktreeFixture {
    let root: URL
    let repo: URL
    let store: GitWorktreeStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xtx-worktree-" + UUID().uuidString)
        repo = root.appendingPathComponent("repo")
        store = GitWorktreeStore(directory: root.appendingPathComponent("managed"))
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try git(["init", "-b", "baseline"])
        for (key, value) in [("user.name", "XTermX Test"), ("user.email", "test@example.invalid"),
                             ("commit.gpgSign", "false"), ("core.hooksPath", "/dev/null"), ("core.attributesFile", "/dev/null")] {
            _ = try git(["config", key, value])
        }
        try "base\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."]); _ = try git(["commit", "-m", "Seed"])
    }
    func git(_ args: [String], at path: String? = nil, allowFailure: Bool = false) throws -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path ?? repo.path] + args
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 && !allowFailure { throw NSError(domain: "WorktreeFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text]) }
        return (process.terminationStatus, text)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct GitWorktreesTests {
    @Test func uniqueBranchesStartAtHEADAndLeaveDirtyOriginalFilesAlone() async throws {
        let f = try WorktreeFixture(); defer { f.cleanup() }
        try "uncommitted\n".write(to: f.repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let before = try f.git(["status", "--porcelain"]).1
        let a = try await f.store.create(cwd: f.repo.path, agentID: "claude-code")
        let b = try await f.store.create(cwd: f.repo.path, agentID: "claude-code")
        let first = try #require(a), second = try #require(b)
        #expect(first.branch == "xtermx/claude-code-1")
        #expect(second.branch == "xtermx/claude-code-2")
        #expect(first.path != second.path)
        #expect(try String(contentsOf: URL(fileURLWithPath: first.path).appendingPathComponent("file.txt"), encoding: .utf8) == "base\n")
        #expect(try f.git(["status", "--porcelain"]).1 == before)
        #expect(try await f.store.records().count == 2)
        try await f.store.remove(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try f.git(["show-ref", "--verify", "refs/heads/" + first.branch]).0 == 0)
        #expect(try await f.store.records().count == 1)
        try "keep".write(to: URL(fileURLWithPath: second.path).appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: GitWorktreeStore.Failure.self) { try await f.store.remove(second) }
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
    @Test func explicitMergeRequiresTheOriginalBranchAndKeepsTheWorktree() async throws {
        let f = try WorktreeFixture(); defer { f.cleanup() }
        let value = try await f.store.create(cwd: f.repo.path, agentID: "codex")
        let record = try #require(value)
        try "feature\n".write(to: URL(fileURLWithPath: record.path).appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        _ = try f.git(["add", "."], at: record.path); _ = try f.git(["commit", "-m", "Feature"], at: record.path)
        _ = try f.git(["checkout", "-b", "different-source"], at: record.path)
        await #expect(throws: GitWorktreeStore.Failure.self) { try await f.store.review(record) }
        await #expect(throws: GitWorktreeStore.Failure.self) { try await f.store.remove(record) }
        await #expect(throws: GitWorktreeStore.Failure.self) { try await f.store.merge(record) }
        _ = try f.git(["checkout", record.branch], at: record.path)
        _ = try f.git(["checkout", "-b", "different-destination"])
        await #expect(throws: GitWorktreeStore.Failure.self) { try await f.store.merge(record) }
        #expect(try f.git(["branch", "--show-current"]).1 == "different-destination")
        _ = try f.git(["checkout", "baseline"])
        try await f.store.merge(record)
        #expect(try f.git(["branch", "--show-current"]).1 == "baseline")
        #expect(try String(contentsOf: f.repo.appendingPathComponent("feature.txt"), encoding: .utf8) == "feature\n")
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(try await f.store.review(record).commitsAhead == 0)
    }
    @Test func conflictingMergeAbortsOnlyItsOwnOperationAndPreservesBothSides() async throws {
        let f = try WorktreeFixture(); defer { f.cleanup() }
        let value = try await f.store.create(cwd: f.repo.path, agentID: "gemini")
        let record = try #require(value)
        try "agent side\n".write(to: URL(fileURLWithPath: record.path).appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try f.git(["add", "."], at: record.path); _ = try f.git(["commit", "-m", "Agent"], at: record.path)
        try "destination side\n".write(to: f.repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try f.git(["add", "."]); _ = try f.git(["commit", "-m", "Destination"])
        let head = try f.git(["rev-parse", "HEAD"]).1
        await #expect(throws: GitWorktreeStore.Failure.self) { try await f.store.merge(record) }
        #expect(try f.git(["rev-parse", "HEAD"]).1 == head)
        #expect(try f.git(["status", "--porcelain"]).1.isEmpty)
        #expect(try f.git(["rev-parse", "--verify", "MERGE_HEAD"], allowFailure: true).0 != 0)
        #expect(try String(contentsOf: f.repo.appendingPathComponent("file.txt"), encoding: .utf8) == "destination side\n")
        #expect(try String(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("file.txt"), encoding: .utf8) == "agent side\n")
    }
    @MainActor @Test func managerPreparesBeforeSpawningAndOffersReviewOnClose() async throws {
        let f = try WorktreeFixture(); defer { f.cleanup() }
        let manager = PaneManager(detectAgents: false)
        manager.worktreeStore = f.store
        manager.agents = [.init(id: "test-agent", name: "Test", command: "true", symbol: "sparkle")]
        let request = SpawnRequest(kind: .agent, agentID: "test-agent", cwd: f.repo.path)
        let ordinary = try await manager.prepareSpawn(request)
        #expect(ordinary.worktree == nil && ordinary.request.cwd == f.repo.path)
        manager.isolateAgents = true
        let prepared = try await manager.prepareSpawn(request)
        let record = try #require(prepared.worktree)
        #expect(manager.panes.isEmpty)
        #expect(prepared.request.cwd == record.path)
        var closed: GitWorktreeRecord?
        manager.onWorktreeClosed = { closed = $0 }
        let pane = manager.spawnPrepared(prepared)
        #expect(pane.cwd == record.path)
        #expect(manager.isolatedPanes[pane.id]?.id == record.id)
        manager.close(pane.id)
        #expect(closed?.id == record.id)
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(manager.isolatedPanes.isEmpty)
        let nonGit = try await manager.prepareSpawn(SpawnRequest(kind: .agent, agentID: "test-agent", cwd: f.root.path))
        #expect(nonGit.worktree == nil)
    }
    @Test func brokenRepositoriesNeverFallBackToAnUnisolatedLaunch() async throws {
        let f = try WorktreeFixture(); defer { f.cleanup() }
        let broken = f.root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken.appendingPathComponent(".git"), withIntermediateDirectories: true)
        await #expect(throws: GitWorktreeStore.Failure.self) { try await f.store.create(cwd: broken.path, agentID: "test") }
        await #expect(throws: GitWorktreeStore.Failure.self) { try await f.store.create(cwd: f.root.appendingPathComponent("missing").path, agentID: "test") }
        let nonGit = try await f.store.create(cwd: f.root.path, agentID: "test")
        #expect(nonGit == nil)
    }

}
#endif
