import Foundation

/// Mutually exclusive live terminal counts. Attention beats output; closed panes are never live.
public struct PaneActivitySummary: Equatable, Sendable {
    public private(set) var working = 0
    public private(set) var waiting = 0
    public private(set) var idle = 0
    public private(set) var ended = 0
    public var live: Int { working + waiting + idle }
    public static func state(of pane: PaneInfo) -> PaneState {
        if pane.state == .exited { return .exited }
        if pane.needsYou || pane.state == .blocked || pane.agentSession?.status == .waiting { return .blocked }
        return pane.state
    }
    public init(panes: [PaneInfo]) {
        var seen = Set<String>()
        for pane in panes where seen.insert(pane.id).inserted {
            switch Self.state(of: pane) {
            case .working: working += 1
            case .blocked: waiting += 1
            case .idle: idle += 1
            case .exited: ended += 1
            }
        }
    }
}
