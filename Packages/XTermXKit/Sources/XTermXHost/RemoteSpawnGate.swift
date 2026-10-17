#if os(macOS) || os(Linux)
import Foundation
import Observation
import XTermXKit

public struct TrustedRemoteFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var deviceID: String
    public var deviceName: String
    public var path: String
}
public struct RemoteSpawnRules: Codable, Equatable, Sendable {
    public var askBeforeSpawn: Bool
    public var folders: [TrustedRemoteFolder]
    public init(askBeforeSpawn: Bool = true, folders: [TrustedRemoteFolder] = []) { self.askBeforeSpawn = askBeforeSpawn; self.folders = folders }
}
public struct RemoteSpawnApproval: Identifiable, Sendable {
    public var id: UUID
    public var source: UUID?
    public var deviceID: String?
    public var deviceName: String
    public var folder: String
    public var agentID: String?
    public var bypass: Bool
    public var initialInput: String?
}

/// Approvals stay on the host: remote `.respond` messages cannot approve their own spawn.
@MainActor @Observable public final class RemoteSpawnGate {
    public enum Choice { case deny, once, trustFolder }
    public var rules: RemoteSpawnRules { didSet { if rules != oldValue { onRulesChanged?(rules) } } }
    public private(set) var approvals: [RemoteSpawnApproval] = []
    @ObservationIgnored public var onRulesChanged: ((RemoteSpawnRules) -> Void)?
    @ObservationIgnored private var replies: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]
    public init(rules: RemoteSpawnRules = .init(askBeforeSpawn: false)) { self.rules = rules }

    public static func folder(for cwd: String?) -> String {
        let path = cwd.map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.homeDirectoryForCurrentUser.path
        var directory: ObjCBool = false
        let valid = FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        return URL(fileURLWithPath: valid ? path : FileManager.default.homeDirectoryForCurrentUser.path)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }
    public func isTrusted(deviceID: String?, folder: String) -> Bool {
        guard let deviceID else { return false }
        return rules.folders.contains { trusted in
            trusted.deviceID == deviceID && trusted.path != "/"
                && (folder == trusted.path || folder.hasPrefix(trusted.path + "/"))
        }
    }
    public func authorize(_ request: SpawnRequest, deviceID: String?, name: String, source: UUID?, timeout: Duration = .seconds(60)) async -> Bool {
        guard !Task.isCancelled else { return false }
        let folder = Self.folder(for: request.cwd)
        if !rules.askBeforeSpawn || isTrusted(deviceID: deviceID, folder: folder) { return true }
        guard approvals.count < 16 else { return false }
        let approval = RemoteSpawnApproval(id: UUID(), source: source, deviceID: deviceID,
                                           deviceName: String(name.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(80)), folder: folder,
                                           agentID: request.agentID, bypass: request.bypass, initialInput: request.initialInput)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                replies[approval.id] = continuation
                approvals.append(approval)
                timers[approval.id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.answer(approval.id, choice: .deny)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.answer(approval.id, choice: .deny) } }
    }
    public func answer(_ id: UUID, choice: Choice) {
        guard let approval = approvals.first(where: { $0.id == id }), let reply = replies.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        approvals.removeAll { $0.id == id }
        if case .trustFolder = choice, let deviceID = approval.deviceID, approval.folder != "/" {
            if !isTrusted(deviceID: deviceID, folder: approval.folder) {
                rules.folders.append(TrustedRemoteFolder(id: UUID(), deviceID: deviceID, deviceName: approval.deviceName, path: approval.folder))
            }
        }
        if case .deny = choice { reply.resume(returning: false) } else { reply.resume(returning: true) }
    }
    public func cancel(source: UUID? = nil) {
        for approval in approvals where source == nil || approval.source == source { answer(approval.id, choice: .deny) }
    }
}
#endif
