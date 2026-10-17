import Foundation

/// Constructed from an allowlist of counters and build metadata, never from user files or logs.
public struct DiagnosticSummary: Codable, Sendable {
    public var version: String
    public var build: String
    public var operatingSystem: String
    public var localPanes: Int
    public var sshPanes: Int
    public var remoteMachinePanes: Int
    public var remoteAccessEnabled: Bool
    public var connectedDevices: Int
    public var activityEvents: Int
    public init(version: String, build: String, operatingSystem: String, localPanes: Int, sshPanes: Int,
                remoteMachinePanes: Int, remoteAccessEnabled: Bool, connectedDevices: Int, activityEvents: Int) {
        self.version = version; self.build = build; self.operatingSystem = operatingSystem
        self.localPanes = localPanes; self.sshPanes = sshPanes; self.remoteMachinePanes = remoteMachinePanes
        self.remoteAccessEnabled = remoteAccessEnabled; self.connectedDevices = connectedDevices; self.activityEvents = activityEvents
    }
    public func preview() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
