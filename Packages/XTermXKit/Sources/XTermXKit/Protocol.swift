import Foundation

/// Wire protocol between a host (the Mac running the panes) and its clients
/// (iPhone, Apple Watch, another Mac). Every message travels as JSON inside a
/// sealed frame (`SecureChannel`).
public enum XTermXProtocol {
    public static let version = 1
    public static let bonjourType = "_xtermx._tcp"
    public static let defaultPort: UInt16 = 47_820
    /// Plain HTTP request/response port for the Watch, which may not open WebSockets.
    public static let defaultHTTPPort: UInt16 = 47_821
    /// Bytes of output the host keeps per pane to replay to a new subscriber.
    public static let replayBytes = 512 * 1024
}

public enum ClientPlatform: String, Codable, Sendable {
    case iOS, watchOS, macOS
}

public struct ClientHello: Codable, Sendable {
    public var deviceName: String
    public var platform: ClientPlatform
    public var protocolVersion: Int
    public var nonce: Data

    public init(deviceName: String, platform: ClientPlatform, nonce: Data) {
        self.deviceName = deviceName
        self.platform = platform
        self.protocolVersion = XTermXProtocol.version
        self.nonce = nonce
    }
}

public struct HostHello: Codable, Sendable {
    public var hostName: String
    public var protocolVersion: Int
    public var nonce: Data

    public init(hostName: String, nonce: Data) {
        self.hostName = hostName
        self.protocolVersion = XTermXProtocol.version
        self.nonce = nonce
    }
}

public struct SpawnRequest: Codable, Sendable, Hashable {
    public var kind: PaneKind
    public var agentID: String?
    public var cwd: String?
    public var title: String?
    /// Text typed into the pane once it starts (a first prompt for an agent).
    public var initialInput: String?
    /// Start the agent with its own skip-permissions flag, this once.
    public var bypass: Bool
    /// Reopen a past conversation by id, or "" for the agent's own session picker. Agents without one start fresh.
    public var resume: String?
    /// Shell for the pane, one listed in /etc/shells; nil means the person's login shell.
    public var shell: String?
    /// Give this agent pane its own Git worktree; nil follows the host setting.
    public var isolate: Bool?

    public init(kind: PaneKind, agentID: String? = nil, cwd: String? = nil, title: String? = nil,
                initialInput: String? = nil, bypass: Bool = false, resume: String? = nil, shell: String? = nil, isolate: Bool? = nil) {
        self.kind = kind
        self.agentID = agentID
        self.cwd = cwd
        self.title = title
        self.initialInput = initialInput
        self.bypass = bypass
        self.resume = resume
        self.shell = shell
        self.isolate = isolate
    }
}

/// Everything the host knows, sent right after the handshake and on request.
public struct HostSnapshot: Codable, Sendable {
    public var hostName: String
    public var panes: [PaneInfo]
    public var agents: [AgentDescriptor]
    public var approvals: [ApprovalRequest]
    public var machine: MachineLoad?
    /// Plan limits, agent sessions outside panes, agent time and history; nil from older hosts.
    public var overview: AgentOverview?
    public var paneAccess: [String: PaneAccess]?
    public var supportsPaneNames: Bool?

    public init(hostName: String, panes: [PaneInfo], agents: [AgentDescriptor], approvals: [ApprovalRequest], machine: MachineLoad?,
                overview: AgentOverview = .init()) {
        self.hostName = hostName
        self.panes = panes
        self.agents = agents
        self.approvals = approvals
        self.machine = machine
        self.overview = overview
    }
}

public enum ClientMessage: Codable, Sendable {
    case snapshot
    case identifyDevice(DeviceProof)
    case rooms
    case roomAction(RemoteRoomAction)
    case upload(name: String, data: Data)
    case fileTransfer(FileTransferRequest)
    case subscribe(paneID: String)
    case unsubscribe(paneID: String)
    case input(paneID: String, data: Data)
    /// The newest client to type sets the pane size, like tmux `window-size latest`.
    case resize(paneID: String, cols: Int, rows: Int)
    /// Text plus Return, as dictated or typed in a message box.
    case send(paneID: String, text: String)
    case spawn(SpawnRequest)
    case rename(paneID: String, name: String)
    case close(paneID: String)
    case answer(requestID: String, allow: Bool)
    /// A full answer: the chosen option, question answers, a typed reply.
    case respond(requestID: String, answer: ApprovalAnswer)
    /// Plain-text screen of a pane, for clients without a terminal emulator.
    case screen(paneID: String, lines: Int)
    case ping(Date)
    /// Open a TCP stream to a dev server the host shares. Send only to hosts that sent `devServers`:
    /// older hosts close connections on messages they do not know.
    /// `paneID` names the pane whose server is meant; hosts then check that pair, not just the port.
    case tunnelOpen(streamID: UUID, port: UInt16, paneID: String? = nil)
    case tunnelData(streamID: UUID, data: Data)
    case tunnelClose(streamID: UUID)
    /// Shared clipboard text (≤ 256 KB). Send only to hosts whose permissions say `shareClipboard`:
    /// older hosts close connections on messages they do not know.
    case clipboard(text: String)
    /// This device wants the host's clipboard changes. Same rule as `clipboard`.
    case clipboardOptIn(Bool)
}

public enum HostMessage: Codable, Sendable {
    case deviceChallenge(Data)
    case permissions(RemotePermissions)
    case rooms([RemoteRoom])
    case receivedFile(ReceivedFile)
    case fileTransferSupport(maximumBytes: Int, chunkBytes: Int)
    case fileTransfer(FileTransferReply)
    case snapshot(HostSnapshot)
    case paneUpdated(PaneInfo)
    case paneClosed(paneID: String)
    /// Replay of recent output sent once on subscribe, then `output` frames follow.
    case replay(paneID: String, data: Data)
    case output(paneID: String, data: Data)
    case screen(paneID: String, lines: [String])
    case approvals([ApprovalRequest])
    case machine(MachineLoad)
    case overview(AgentOverview)
    case spawned(PaneInfo)
    case error(code: String, message: String)
    case pong(Date)
    /// Dev servers devices may preview; empty while sharing is off. Its arrival also means the host speaks tunnels.
    case devServers([DevServerPort])
    case tunnelOpened(streamID: UUID)
    case tunnelData(streamID: UUID, data: Data)
    case tunnelClosed(streamID: UUID, reason: String?)
    /// Services the host checks (empty while sharing them is off). Older clients skip it.
    case services([ServiceStatus])
    /// The host's clipboard changed; only sent to devices that opted in.
    case clipboard(text: String)
    /// The ways in the host has right now (Tailscale, LAN…); clients update their saved pairing. Older clients skip it.
    case addresses([String])
}

/// One request and its answer over HTTP (`POST /rpc`), used by the Watch.
public struct RPCRequest: Codable, Sendable {
    public var id: Data
    public var sentAt: Date
    public var message: ClientMessage
    public var deviceProof: DeviceProof?
    public var deviceName: String?

    public init(message: ClientMessage, identity: DeviceIdentity? = nil, secret: Data? = nil, deviceName: String? = nil) {
        self.id = SecureRandom.bytes(16)
        self.sentAt = .now
        self.message = message
        self.deviceName = deviceName
        self.deviceProof = nil
        if let identity, let secret { deviceProof = try? identity.proof(for: identityChallenge(secret: secret)) }
    }
}

public struct RPCResponse: Codable, Sendable {
    public var requestID: Data
    public var messages: [HostMessage]

    public init(requestID: Data, messages: [HostMessage]) {
        self.requestID = requestID
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey { case requestID, messages }
    private struct Unknown: Decodable {}

    /// Messages this build does not know (from a newer host) are skipped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(Data.self, forKey: .requestID)
        var list = try c.nestedUnkeyedContainer(forKey: .messages)
        var messages: [HostMessage] = []
        while !list.isAtEnd {
            if let m = try? list.decode(HostMessage.self) { messages.append(m) } else { _ = try list.decode(Unknown.self) }
        }
        self.messages = messages
    }
}

public enum WireCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
