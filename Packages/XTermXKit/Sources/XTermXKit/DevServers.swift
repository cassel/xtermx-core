import Foundation

/// A TCP port listening in a pane: a process started from the pane's shell (a dev server) accepts connections on it.
public struct DevServerPort: Codable, Sendable, Hashable, Identifiable {
    public var port: UInt16
    public var paneID: String
    /// The listening program's name (`node`, `python3`, …), when known.
    public var process: String?

    public init(port: UInt16, paneID: String, process: String? = nil) {
        self.port = port; self.paneID = paneID; self.process = process
    }

    public var id: String { "\(paneID):\(port)" }
    public var label: String { ":\(port)" }
    /// Where the server answers on the machine that runs it.
    public var localURL: URL { URL(string: "http://localhost:\(port)/")! }
}

public enum DevServerTunnelRules {
    /// Bytes per `tunnelData` frame; larger reads are split.
    public static let chunkBytes = 64 * 1024
    /// Streams one device may hold open at once (a browser opens several per page).
    public static let maximumStreams = 32
    /// Bytes a host lets wait for one dev server socket before closing that stream.
    public static let maximumPendingBytesPerStream = 4 << 20
    /// Bytes a host lets wait across all of one device's streams, in either direction, before closing the stream that overflows.
    public static let maximumPendingBytesPerDevice = 16 << 20

    /// Whether `shared` lets a device open `port`, in `paneID` when it names one.
    public static func allows(port: UInt16, paneID: String?, in shared: [DevServerPort]) -> Bool {
        shared.contains { $0.port == port && (paneID == nil || $0.paneID == paneID) }
    }

    /// Splits a read into frame-sized pieces.
    public static func chunks(_ data: Data, size: Int = chunkBytes) -> [Data] {
        guard !data.isEmpty, size > 0 else { return [] }
        return stride(from: data.startIndex, to: data.endIndex, by: size).map { Data(data[$0..<min($0 + size, data.endIndex)]) }
    }
}
