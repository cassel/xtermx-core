import Foundation

/// HTTP screens have no unsubscribe socket: a short lease ends after polling stops.
public struct RemoteViewLeases: Sendable {
    private var seen: [String: Date] = [:]
    public static let lifetime: TimeInterval = 10
    public init() {}
    public mutating func poll(_ paneID: String, now: Date = .now) {
        seen = seen.filter { now.timeIntervalSince($0.value) < Self.lifetime }
        seen[paneID] = now
    }
    public func active(now: Date = .now) -> Set<String> {
        Set(seen.compactMap { now.timeIntervalSince($0.value) < Self.lifetime ? $0.key : nil })
    }
    public mutating func remove(_ paneID: String) { seen[paneID] = nil }
    public mutating func clear() { seen = [:] }
}
