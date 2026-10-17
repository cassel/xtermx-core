import Foundation

/// The owner grants a coordinator a bounded set of peers; pane ownership itself never changes.
public struct RoomCoordinatorRoute: Sendable, Equatable {
    public var coordinator: String
    public var members: Set<String>
    public init(coordinator: String, members: [String]) { self.coordinator = coordinator; self.members = Set(members).subtracting([coordinator]) }
    public func canForward(caller: String, to target: String) -> Bool { caller == coordinator && members.contains(target) }
}
