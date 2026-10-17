#if os(macOS) || os(Linux)
import Foundation
import Testing
import XTermXHost
import XTermXKit

struct LocalActivityTests {
    @MainActor @Test func managerRecordsLifecycleWithoutTerminalContent() {
        let manager = PaneManager(detectAgents: false)
        var events: [LocalPaneActivity] = []
        manager.onPaneActivity = { events.append($0) }
        let pane = manager.spawn(SpawnRequest(kind: .shell, cwd: "/tmp"), openedByAgent: true)
        manager.close(pane.id)
        manager.close(pane.id)
        #expect(events.map(\.action) == [.opened, .closed])
        #expect(events.allSatisfy { $0.openedByAgent })
        #expect(events.first?.paneReference == events.last?.paneReference)
        #expect(events.first?.paneReference != pane.id)
    }
    @Test func retentionAndPrivacyUseOnlyAllowlistedMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalActivityStore(directory: root)
        let now = Date()
        let pane = PaneInfo(id: "secret-identifier", title: "private prompt", kind: .agent, agentID: "private-agent", cwd: "/private/folder", lastLine: "secret-token", openedByAgent: true)
        let old = LocalPaneActivity(action: .opened, pane: pane, date: now.addingTimeInterval(-40 * 86400))
        try await store.append(old, days: 90, now: now)
        try await store.append(.init(action: .closed, pane: pane, date: now), days: 90, now: now)
        #expect(try await store.records(days: 90, now: now).count == 2)
        #expect(try await store.records(days: 30, now: now).count == 1)
        let raw = try String(contentsOf: root.appendingPathComponent("activity.json"), encoding: .utf8)
        for secret in ["secret-identifier", "private prompt", "private-agent", "/private/folder", "secret-token"] { #expect(!raw.contains(secret)) }
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("activity.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await store.clear()
        #expect(try await store.records(days: 30).isEmpty)
    }
    @Test func clearAndAppendRefuseSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: target)
        let folder = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("activity.json"), withDestinationURL: target)
        let store = LocalActivityStore(directory: folder)
        await #expect(throws: LocalActivityStore.Failure.self) { try await store.clear() }
        let pane = PaneInfo(title: "Test", kind: .shell, cwd: "/")
        await #expect(throws: LocalActivityStore.Failure.self) { try await store.append(.init(action: .opened, pane: pane), days: 30) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
    }
    @Test func diagnosticHasNoRawLogsOrUserDataFields() throws {
        let diagnostic = DiagnosticSummary(version: "1", build: "2", operatingSystem: "Test OS", localPanes: 1, sshPanes: 2, remoteMachinePanes: 3, remoteAccessEnabled: true, connectedDevices: 0, activityEvents: 4)
        let json = try #require(JSONSerialization.jsonObject(with: Data(diagnostic.preview().utf8)) as? [String: Any])
        #expect(Set(json.keys) == Set(["version", "build", "operatingSystem", "localPanes", "sshPanes", "remoteMachinePanes", "remoteAccessEnabled", "connectedDevices", "activityEvents"]))
    }
}
#endif
