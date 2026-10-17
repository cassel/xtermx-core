import Foundation

public enum PaneAccess: String, Codable, Sendable, CaseIterable, Identifiable {
    case control, view, none
    public var id: Self { self }
    public var canView: Bool { self != .none }
    public var canControl: Bool { self == .control }
    public var title: String {
        switch self { case .control: "View & control"; case .view: "View only"; case .none: "Private" }
    }
    public var symbol: String {
        switch self { case .control: "person.2"; case .view: "eye"; case .none: "lock.fill" }
    }
}

public struct PaneSharingPolicy: Codable, Sendable, Equatable {
    public private(set) var choices: [String: PaneAccess] = [:]
    /// Remember private transcript ids even after their panes close, so history does not reveal them later.
    private var privateSessions: Set<String> = []
    public init() {}
    public func access(_ id: String) -> PaneAccess { choices[id] ?? .control }
    public mutating func set(_ id: String, to access: PaneAccess) { choices[id] = access }
    public mutating func remember(_ pane: PaneInfo) {
        if access(pane.id) == .none, let session = pane.agentSession { privateSessions.insert(session.sessionID) }
    }
    public func visibleApprovals(_ approvals: [ApprovalRequest]) -> [ApprovalRequest] {
        approvals.filter { $0.paneID.map { access($0).canControl } ?? true }
    }
    public func visibleOverview(_ overview: AgentOverview) -> AgentOverview {
        var result = overview
        result.elsewhere.removeAll { privateSessions.contains($0.sessionID) }
        result.history.removeAll { privateSessions.contains($0.id) }
        return result
    }
}
