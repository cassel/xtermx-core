import Foundation
#if canImport(Security)
import Security

/// Paired hosts, kept in the Keychain because each one carries its secret.
public enum PairingStore {
    private static let service = "XTermX.pairings"
    private static let account = "all"

    public static func load() -> [PairingInfo] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([PairingInfo].self, from: data)) ?? []
    }

    public static func save(_ pairings: [PairingInfo]) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let data = try? JSONEncoder().encode(pairings) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
#endif

/// What the iPhone tells the Watch about one host.
public struct WatchHostState: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var connected: Bool
    public var panes: [PaneInfo]
    public var agents: [AgentDescriptor]
    public var approvals: [ApprovalRequest]
    public var screens: [String: [String]]
    public var machine: MachineLoad?
    public var accounts: [AccountUsage]?
    /// Agent sessions on the host outside its panes, without their activity.
    public var elsewhere: [AgentSessionInfo]?
    /// Services the host shares; nil from an older iPhone.
    public var services: [ServiceStatus]?

    /// Agent sessions are trimmed to what the Watch shows: the Watch link carries little.
    public init(id: String, name: String, connected: Bool, panes: [PaneInfo], agents: [AgentDescriptor],
                approvals: [ApprovalRequest], screens: [String: [String]], machine: MachineLoad?, accounts: [AccountUsage] = [],
                elsewhere: [AgentSessionInfo] = [], services: [ServiceStatus] = []) {
        self.accounts = accounts
        self.services = services
        self.elsewhere = elsewhere.map { $0.trimmed(activities: 0) }
        self.id = id
        self.name = name
        self.connected = connected
        self.panes = panes.map { p in
            var p = p
            p.agentSession = p.agentSession?.trimmed(activities: 1)
            return p
        }
        self.agents = agents
        self.approvals = approvals
        self.screens = screens
        self.machine = machine
    }
}

/// iPhone → Watch: the state of every paired host, plus the pairings so the Watch can
/// reach a host by itself when the iPhone is away.
public struct WatchState: Codable, Sendable {
    public var hosts: [WatchHostState]
    public var pairings: [PairingInfo]

    public init(hosts: [WatchHostState], pairings: [PairingInfo]) {
        self.hosts = hosts
        self.pairings = pairings
    }
}

/// Watch → iPhone: a message to relay to one host.
public struct WatchCommand: Codable, Sendable {
    public var hostID: String
    public var message: ClientMessage

    public init(hostID: String, message: ClientMessage) {
        self.hostID = hostID
        self.message = message
    }
}

/// Bytes the quick-reply buttons type into a pane.
public enum QuickReply: String, CaseIterable, Identifiable, Sendable {
    case enter, yes, no, one, two, escape, interrupt

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .enter: "Enter"
        case .yes: "y"
        case .no: "n"
        case .one: "1"
        case .two: "2"
        case .escape: "Esc"
        case .interrupt: "^C"
        }
    }

    public var symbol: String {
        switch self {
        case .enter: "return"
        case .yes: "checkmark"
        case .no: "xmark"
        case .one: "1.circle"
        case .two: "2.circle"
        case .escape: "escape"
        case .interrupt: "stop.fill"
        }
    }

    public var bytes: Data {
        switch self {
        case .enter: Data([0x0d])
        case .yes: Data("y\r".utf8)
        case .no: Data("n\r".utf8)
        case .one: Data("1".utf8)
        case .two: Data("2".utf8)
        case .escape: Data([0x1b])
        case .interrupt: Data([0x03])
        }
    }
}
