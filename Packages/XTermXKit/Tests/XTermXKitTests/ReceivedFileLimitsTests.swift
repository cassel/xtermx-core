#if os(macOS)
import Foundation
import Testing
import XTermXKit
import XTermXHost

@MainActor struct ReceivedFileLimitsTests {
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    @Test func oldHiddenQuotaIsGoneAndOptionalHostQuotaRejectsBeforeStaging() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: false)
        let existing = receipt.appendingPathComponent("existing.mov")
        FileManager.default.createFile(atPath: existing.path, contents: nil)
        let file = try FileHandle(forWritingTo: existing); try file.truncate(atOffset: 66 * 1024 * 1024); try file.close()
        let store = ReceivedFileStore(directory: root)
        try store.checkCapacity(bytes: 500 * 1024 * 1024)
        let quotaStore = ReceivedFileStore(directory: root, limits: .init(maximumFileBytes: 64 * 1024 * 1024, maximumStoredBytes: 100 * 1024 * 1024))
        let receiver = FileChunkReceiver()
        #expect(throws: ReceivedFileStore.Failure.full) {
            try receiver.handle(.begin(id: UUID(), name: "new.mov", bytes: 40 * 1024 * 1024), owner: "test", store: quotaStore)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".incoming").path))
        #expect(try existing.resourceValues(forKeys: [.fileSizeKey]).fileSize == 66 * 1024 * 1024)
    }
    @Test func hostCanChooseAFileLimitAboveFiveHundredMB() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceivedFileStore(directory: root, limits: .init(maximumFileBytes: 700 * 1024 * 1024))
        let receiver = FileChunkReceiver(), id = UUID()
        let result = try receiver.handle(.begin(id: id, name: "large.mp4", bytes: 600 * 1024 * 1024), owner: "test", store: store)
        guard case .progress = result else { Issue.record("Configured limit must be accepted"); return }
        receiver.cancel(id, owner: "test")
        let denied = try receiver.handle(.begin(id: UUID(), name: "large.mp4", bytes: 701 * 1024 * 1024), owner: "test", store: store)
        guard case .failed(_, let message) = denied else { Issue.record("Host limit must be enforced"); return }
        #expect(message.contains("700"))
    }
    @Test func pendingTransfersReserveTheConfiguredStorageQuota() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceivedFileStore(directory: root, limits: .init(maximumFileBytes: 60, maximumStoredBytes: 100))
        let receiver = FileChunkReceiver(), first = UUID()
        _ = try receiver.handle(.begin(id: first, name: "a.mov", bytes: 60), owner: "a", store: store)
        defer { receiver.cancelAll() }
        #expect(throws: ReceivedFileStore.Failure.full) {
            try receiver.handle(.begin(id: UUID(), name: "b.mov", bytes: 60), owner: "b", store: store)
        }
    }
    @Test func errorsDistinguishQuotaDiskSpaceAndPermissions() {
        #expect(ReceivedFileStore.transferErrorMessage(ReceivedFileStore.Failure.full).contains("storage limit"))
        #expect(ReceivedFileStore.transferErrorMessage(NSError(domain: NSPOSIXErrorDomain, code: 28)).contains("free disk space"))
        #expect(ReceivedFileStore.transferErrorMessage(NSError(domain: NSPOSIXErrorDomain, code: 13)).contains("permissions"))
        #expect(!ReceivedFileLimits(maximumFileBytes: -1).isValid)
        #expect(!ReceivedFileLimits(maximumFileBytes: 100, maximumStoredBytes: 50).isValid)
        #expect(ReceivedFileLimits().maximumFileBytes == 500 * 1024 * 1024)
        #expect(ReceivedFileLimits().maximumStoredBytes == nil)
    }
    @Test func changedLimitsReachConnectedDevicesWithoutReconnecting() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.start(); defer { server.stop() }
        let client = HostConnection(pairing: server.pairing(address: "127.0.0.1"), deviceName: "limits-test", platform: .iOS)
        client.connect(); defer { client.disconnect() }
        #expect(await client.waitUntilReady())
        let limit = 700 * 1024 * 1024
        server.updateReceivedFileLimits(.init(maximumFileBytes: limit))
        let deadline = Date.now.addingTimeInterval(3)
        while client.fileTransferMaximumBytes != limit && Date.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.fileTransferMaximumBytes == limit)
        #expect(client.status == .connected)
    }
}
#endif
