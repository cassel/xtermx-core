import Foundation

/// Local labels for verified installations. Labels do not affect pairing or authorization.
public struct DeviceNames: Codable, Equatable, Sendable {
    public private(set) var labels: [String: String] = [:]
    public init() {}
    public func name(identity: String?, reported: String) -> String {
        identity.flatMap { labels[$0] } ?? reported
    }
    public mutating func set(_ name: String, identity: String) throws {
        guard !identity.isEmpty else { throw PaneNameRules.InvalidPaneName() }
        labels[identity] = try PaneNameRules.clean(name)
    }
}

public struct RememberedDevice: Codable, Equatable, Sendable, Identifiable {
    /// Verified signing-key fingerprint; a friendly name is never an identity.
    public var id: String
    public var name: String
    public var platform: ClientPlatform
    public var firstConnectedAt: Date
    public var lastConnectedAt: Date
}

/// Devices that have actually connected, including ones currently offline. This grants no access.
public struct DeviceHistory: Codable, Equatable, Sendable {
    public private(set) var devices: [RememberedDevice] = []
    public init() {}
    public mutating func record(identity: String, name: String, platform: ClientPlatform, at now: Date = .now) {
        guard !identity.isEmpty else { return }
        let name = (try? PaneNameRules.clean(String(name.prefix(60)))) ?? "Device"
        if let index = devices.firstIndex(where: { $0.id == identity }) {
            devices[index].name = name
            devices[index].platform = platform
            devices[index].lastConnectedAt = now
        } else {
            devices.append(RememberedDevice(id: identity, name: name, platform: platform, firstConnectedAt: now, lastConnectedAt: now))
        }
        devices.sort { $0.lastConnectedAt > $1.lastConnectedAt }
        if devices.count > 256 { devices = Array(devices.prefix(256)) }
    }
}
