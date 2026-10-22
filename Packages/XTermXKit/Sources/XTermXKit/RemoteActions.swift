import Foundation

/// Host-wide permissions for paired devices. New capabilities start off until the owner chooses them.
public struct RemotePermissions: Codable, Sendable, Equatable {
    public var openSessions: Bool
    public var manageRooms: Bool
    public var sendFiles: Bool
    /// Devices may preview servers listening in this host's panes. Off until the owner turns it on.
    public var shareDevServers: Bool
    /// Devices see the services this host checks and whether they are up. Off until the owner turns it on.
    public var shareServices: Bool
    /// Devices that opt in share the clipboard with this host (text only). Off until the owner turns it on.
    /// A host that sends this as true also understands the clipboard messages.
    public var shareClipboard: Bool

    public init(openSessions: Bool = true, manageRooms: Bool = false, sendFiles: Bool = false, shareDevServers: Bool = false,
                shareServices: Bool = false, shareClipboard: Bool = false) {
        self.shareClipboard = shareClipboard
        self.openSessions = openSessions; self.manageRooms = manageRooms; self.sendFiles = sendFiles
        self.shareDevServers = shareDevServers
        self.shareServices = shareServices
    }

    private enum CodingKeys: String, CodingKey { case openSessions, manageRooms, sendFiles, shareDevServers, shareServices, shareClipboard }

    /// Settings saved, or sent by a host, before a switch existed decode with that switch off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openSessions = try c.decode(Bool.self, forKey: .openSessions)
        manageRooms = try c.decode(Bool.self, forKey: .manageRooms)
        sendFiles = try c.decode(Bool.self, forKey: .sendFiles)
        shareDevServers = try c.decodeIfPresent(Bool.self, forKey: .shareDevServers) ?? false
        shareServices = try c.decodeIfPresent(Bool.self, forKey: .shareServices) ?? false
        shareClipboard = try c.decodeIfPresent(Bool.self, forKey: .shareClipboard) ?? false
    }
}

public struct RemoteRoom: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var paneIDs: [String]
    public init(id: String, name: String, paneIDs: [String]) { self.id = id; self.name = name; self.paneIDs = paneIDs }
}

public enum RemoteRoomAction: Codable, Sendable {
    case rename(id: String, name: String)
    case message(id: String, text: String, paneIDs: [String], execute: Bool)

    public var roomID: String {
        switch self { case .rename(let id, _), .message(let id, _, _, _): id }
    }

    /// A client may only address members of the chosen room, and may not send unbounded text.
    public func isValid(in rooms: [RemoteRoom]) -> Bool {
        guard let room = rooms.first(where: { $0.id == roomID }) else { return false }
        switch self {
        case .rename(_, let name):
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 120
                && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        case .message(_, let text, let ids, _):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 32_768
                && !ids.isEmpty && Set(ids).count == ids.count && Set(ids).isSubset(of: Set(room.paneIDs))
        }
    }
}

public struct ReceivedFile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var bytes: Int
    public var path: String?
    public init(id: String, name: String, bytes: Int, path: String? = nil) { self.id = id; self.name = name; self.bytes = bytes; self.path = path }
}

public enum RemoteFileRules {
    public static let maximumBytes = 4 * 1024 * 1024
    public static let maximumTransferBytes = 500 * 1024 * 1024
    public static let chunkBytes = 256 * 1024
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 180 && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Host policy advertised to paired devices. Storage quotas are optional, not a hidden global cap.
public struct ReceivedFileLimits: Codable, Sendable, Equatable {
    public var maximumFileBytes: Int
    public var maximumStoredBytes: Int?
    public init(maximumFileBytes: Int = RemoteFileRules.maximumTransferBytes, maximumStoredBytes: Int? = nil) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumStoredBytes = maximumStoredBytes
    }
    public var isValid: Bool {
        maximumFileBytes > 0 && (maximumStoredBytes.map { $0 > 0 && $0 >= maximumFileBytes } ?? true)
    }
}
