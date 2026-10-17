import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation

/// A bidirectional stream of binary frames to one host.
public protocol FrameTransport: AnyObject, Sendable {
    func send(_ frame: Data) async throws
    /// The next frame; throws once the transport has closed.
    func receive() async throws -> Data
    func close()
}

/// Opens a transport to `host:port`. Apple platforms default to URLSession; Linux nodes pass NIO.
public typealias TransportFactory = @Sendable (_ host: String, _ port: UInt16) async throws -> FrameTransport

#if canImport(Darwin)
final class URLSessionTransport: FrameTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    func send(_ frame: Data) async throws { try await task.send(.data(frame)) }

    func receive() async throws -> Data {
        while true {
            if case .data(let frame) = try await task.receive() { return frame }
        }
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
}
#endif

/// A live link from a client (iPhone, Watch, a Mac, a Linux node) to one paired host.
///
/// Streams over a WebSocket. watchOS does not allow WebSockets outside audio apps, so it
/// polls the host's HTTP endpoint instead (`usePolling`). When an address fails, the next
/// one in the pairing is tried (Tailscale, then a public address, …).
@MainActor
@Observable
public final class HostConnection {
    public enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public let pairing: PairingInfo
    public private(set) var status: Status = .disconnected
    public private(set) var hostName: String
    public private(set) var panes: [PaneInfo] = []
    public private(set) var supportsPaneNames = false
    public func canRename(_ id: String) -> Bool { status == .connected && supportsPaneNames && canControl(id) }
    public private(set) var paneAccess: [String: PaneAccess] = [:]
    public func canControl(_ id: String) -> Bool { (!snapshotReceived || panes.contains { $0.id == id }) && (paneAccess[id] ?? .control).canControl }
    public func canView(_ id: String) -> Bool { (!snapshotReceived || panes.contains { $0.id == id }) && (paneAccess[id] ?? .control).canView }
    public private(set) var agents: [AgentDescriptor] = []
    public private(set) var approvals: [ApprovalRequest] = []
    public private(set) var machine: MachineLoad?
    /// Plan limits, agent sessions outside panes, agent time and history.
    public private(set) var overview = AgentOverview()
    /// Plan limits of the host's Claude Code and Codex accounts.
    public var accounts: [AccountUsage] { overview.accounts }
    public private(set) var screens: [String: [String]] = [:]
    public private(set) var lastError: String?
    public private(set) var permissions: RemotePermissions?
    public private(set) var remoteRooms: [RemoteRoom] = []
    public private(set) var receivedFile: ReceivedFile?
    public private(set) var fileTransferMaximumBytes: Int?
    public private(set) var fileUploadProgress: Double?
    @ObservationIgnored private var activeFileUpload: UUID?
    @ObservationIgnored private var fileWaiters: [UUID: (step: UUID, continuation: CheckedContinuation<FileTransferReply, Error>)] = [:]
    /// The address currently in use.
    public private(set) var activeAddress: String
    /// True once the host's first snapshot arrived on this connection.
    public private(set) var snapshotReceived = false

    /// Output bytes per pane, delivered to whatever terminal views are attached.
    @ObservationIgnored private var outputSinks: [String: [UUID: (Data) -> Void]] = [:]
    @ObservationIgnored private var transport: FrameTransport?
    @ObservationIgnored private var sendSealer: FrameSealer?
    @ObservationIgnored private var receiveSealer: FrameSealer?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var resumeProbeTask: Task<Void, Never>?
    @ObservationIgnored private var resumeProbeID: Date?
    @ObservationIgnored private var lastProbeSecond: TimeInterval = 0
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var isBackgrounded = false
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var outbox: AsyncStream<Data>.Continuation?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var subscribed: Set<String> = []
    /// The size each pane was last fitted to here, sent again before subscribing after a reconnect.
    @ObservationIgnored private var fittedSizes: [String: (cols: Int, rows: Int)] = [:]
    @ObservationIgnored private var addressIndex = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let transportFactory: TransportFactory?
    @ObservationIgnored public let usePolling: Bool
    @ObservationIgnored private let platform: ClientPlatform
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let identity: DeviceIdentity?
    @ObservationIgnored private var expectedIdentityChallenge: Data?

    public init(pairing: PairingInfo, deviceName: String, platform: ClientPlatform, usePolling: Bool? = nil,
                transport: TransportFactory? = nil, identity: DeviceIdentity? = nil) {
        self.pairing = pairing
        self.hostName = pairing.hostName
        self.activeAddress = pairing.address
        self.deviceName = deviceName
        self.identity = identity
        self.platform = platform
        self.usePolling = usePolling ?? (platform == .watchOS)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        #if canImport(Darwin)
        config.waitsForConnectivity = false
        #endif
        let session = URLSession(configuration: config)
        self.session = session
        #if canImport(Darwin)
        self.transportFactory = transport ?? { host, port in
            let literal = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            guard let url = URL(string: "ws://\(literal):\(port)/v1") else { throw ChannelError.handshake("bad address \(host)") }
            return URLSessionTransport(url: url, session: session)
        }
        #else
        self.transportFactory = transport
        #endif
    }

    // MARK: Lifecycle

    public func connect() {
        wantsConnection = true
        guard !isBackgrounded, status != .connecting, status != .connected else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        generation += 1
        snapshotReceived = false
        status = .connecting
        if usePolling {
            startPolling()
        } else {
            let generation = generation
            startConnectionDeadline(generation)
            connectTask = Task { [weak self] in await self?.openSocket(generation) }
        }
    }

    public func disconnect() {
        wantsConnection = false
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        pollTask?.cancel()
        pollTask = nil
        tearDown()
        status = .disconnected
    }

    /// Keep a usable socket and the displayed panes. iOS may suspend networking, but
    /// leaving the app alone is not a reason to close an authenticated connection.
    public func pauseForBackground() {
        isBackgrounded = true
        reconnectTask?.cancel()
        reconnectTask = nil
        deadlineTask?.cancel()
        resumeProbeTask?.cancel()
        resumeProbeTask = nil
        resumeProbeID = nil
        if usePolling { pollTask?.cancel(); pollTask = nil }
    }

    /// Transient inactive/active changes do nothing. After actual backgrounding, probe
    /// an existing socket before replacing it; never cancel an in-flight handshake.
    public func resumeAfterBackground() {
        guard isBackgrounded else { return }
        isBackgrounded = false
        guard wantsConnection else { return }
        switch status {
        case .connected:
            if usePolling { startPolling(); return }
            let generation = generation
            // Dates are encoded to whole ISO-8601 seconds. Keep each probe distinct even
            // when multiple background/foreground transitions happen within one second.
            lastProbeSecond = max(Date.now.timeIntervalSince1970.rounded(.down), lastProbeSecond + 1)
            let probe = Date(timeIntervalSince1970: lastProbeSecond)
            resumeProbeID = probe
            send(.ping(probe))
            let timeout = activeFileUpload == nil ? 2 : 8
            resumeProbeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                guard let self, generation == self.generation, !self.isBackgrounded else { return }
                self.fail("The connection stopped responding. Reconnecting…", rotate: false,
                          generation: generation, retryDelay: 0)
            }
        case .connecting:
            if usePolling { startPolling() } else { startConnectionDeadline(generation) }
        case .failed, .disconnected:
            connect()
        }
    }

    private func startConnectionDeadline(_ generation: Int) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, !self.isBackgrounded, self.status == .connecting else { return }
            self.fail("The host did not finish connecting. Trying another address…", generation: generation)
        }
    }

    /// Waits until the first snapshot arrived, or every address failed; for command-line clients.
    public func waitUntilReady(timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if status == .connected, snapshotReceived { return true }
            if case .failed = status, addressIndex >= pairing.addresses.count { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return status == .connected && snapshotReceived
    }

    // MARK: Commands

    /// Starts streaming a pane to `sink`. Several views may watch one pane; each gets its own token,
    /// so a view that disappears after its replacement appeared cannot cut the replacement off.
    @discardableResult
    public func attach(paneID: String, sink: @escaping (Data) -> Void) -> UUID {
        let token = UUID()
        outputSinks[paneID, default: [:]][token] = sink
        subscribed.insert(paneID)
        send(usePolling ? .screen(paneID: paneID, lines: 24) : .subscribe(paneID: paneID))
        return token
    }

    public func detach(paneID: String, token: UUID) {
        outputSinks[paneID]?[token] = nil
        guard outputSinks[paneID]?.isEmpty ?? true else { return }
        outputSinks[paneID] = nil
        subscribed.remove(paneID)
        fittedSizes[paneID] = nil
        if !usePolling { send(.unsubscribe(paneID: paneID)) }
    }

    public func input(paneID: String, bytes: Data) { guard canControl(paneID) else { return }; send(.input(paneID: paneID, data: bytes)) }
    public func sendLine(paneID: String, text: String) { guard canControl(paneID) else { return }; send(.send(paneID: paneID, text: text)) }
    public func resize(paneID: String, cols: Int, rows: Int) {
        guard canControl(paneID) else { return }
        fittedSizes[paneID] = (cols, rows)
        send(.resize(paneID: paneID, cols: cols, rows: rows))
    }
    public func spawn(_ request: SpawnRequest) { send(.spawn(request)) }
    public func rename(paneID: String, name: String) {
        guard canRename(paneID) else { return }
        do { _ = try PaneNameRules.clean(name); send(.rename(paneID: paneID, name: name)) }
        catch { lastError = error.localizedDescription }
    }
    public func close(paneID: String) { guard canControl(paneID) else { return }; send(.close(paneID: paneID)) }
    public func refresh() { send(.snapshot) }
    public func refreshRooms() { send(.rooms) }
    public func updateRoom(_ action: RemoteRoomAction) { send(.roomAction(action)) }
    public func upload(name: String, data: Data) {
        lastError = nil
        receivedFile = nil
        send(.upload(name: name, data: data))
    }

    public func answer(_ request: ApprovalRequest, allow: Bool) {
        approvals.removeAll { $0.id == request.id }
        send(.answer(requestID: request.id, allow: allow))
    }

    public func respond(_ request: ApprovalRequest, answer: ApprovalAnswer) {
        approvals.removeAll { $0.id == request.id }
        send(.respond(requestID: request.id, answer: answer))
    }

    public func requestScreen(paneID: String, lines: Int = 24) {
        send(.screen(paneID: paneID, lines: lines))
    }

    public func send(_ message: ClientMessage) {
        if usePolling {
            Task { await rpc(message) }
            return
        }
        guard outbox != nil, var sealer = sendSealer else { return }
        do {
            let frame = try sealer.seal(WireCoding.encoder().encode(message))
            sendSealer = sealer
            outbox?.yield(frame)
        } catch {
            fail("encode: \(error)")
        }
    }

    // MARK: WebSocket transport

    private var currentAddress: String {
        let all = pairing.addresses
        return all[addressIndex % max(all.count, 1)]
    }

    private func openSocket(_ generation: Int) async {
        guard let factory = transportFactory else { return fail("No network transport on this platform.") }
        let address = currentAddress
        activeAddress = address
        do {
            let transport = try await factory(address, pairing.port)
            guard generation == self.generation else { transport.close(); return }
            self.transport = transport

            // Handshake: both hellos travel under the base keys; everything after uses session keys.
            let clientNonce = SecureRandom.bytes(32)
            var hello = FrameSealer(key: KeySchedule.baseKey(secret: pairing.secret, .clientToHost))
            let helloData = try WireCoding.encoder().encode(ClientHello(deviceName: deviceName, platform: platform, nonce: clientNonce))
            try await transport.send(hello.seal(helloData))

            let reply = try await transport.receive()
            var hostOpen = FrameSealer(key: KeySchedule.baseKey(secret: pairing.secret, .hostToClient))
            let hostHello = try WireCoding.decoder().decode(HostHello.self, from: hostOpen.open(reply))
            guard hostHello.protocolVersion == XTermXProtocol.version else {
                throw ChannelError.handshake("host speaks protocol \(hostHello.protocolVersion)")
            }
            guard generation == self.generation else { transport.close(); return }

            sendSealer = FrameSealer(key: KeySchedule.sessionKey(secret: pairing.secret, clientNonce: clientNonce, hostNonce: hostHello.nonce, .clientToHost))
            receiveSealer = FrameSealer(key: KeySchedule.sessionKey(secret: pairing.secret, clientNonce: clientNonce, hostNonce: hostHello.nonce, .hostToClient))
            expectedIdentityChallenge = DeviceIdentity.webSocketChallenge(secret: pairing.secret, clientNonce: clientNonce, hostNonce: hostHello.nonce)
            hostName = hostHello.hostName
            deadlineTask?.cancel()
            deadlineTask = nil
            startSender(transport, generation)
            startReceiver(transport, generation)
            status = .connected
            lastError = nil
            send(.snapshot)
            for id in subscribed {
                // The pane may have been resized meanwhile (the Mac): fit it again so its screen comes redrawn for us.
                if let size = fittedSizes[id] { send(.resize(paneID: id, cols: size.cols, rows: size.rows)) }
                send(.subscribe(paneID: id))
            }
        } catch ChannelError.authenticationFailed {
            fail("The host rejected this pairing. Pair again.", rotate: false, generation: generation, retry: false)
        } catch {
            fail("\(address): \(error.localizedDescription)", generation: generation)
        }
    }

    /// One task sends every frame, in order: the host refuses frames whose counter goes backwards.
    private func startSender(_ transport: FrameTransport, _ generation: Int) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        outbox = continuation
        sendTask = Task { [weak self] in
            for await frame in stream {
                do {
                    try await transport.send(frame)
                } catch {
                    self?.fail(error.localizedDescription, generation: generation)
                    return
                }
            }
        }
    }

    private func startReceiver(_ transport: FrameTransport, _ generation: Int) {
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await transport.receive()
                    guard let self, generation == self.generation else { return }
                    self.handleFrame(frame)
                }
            } catch {
                guard let self, generation == self.generation else { return }
                self.fail(error.localizedDescription, generation: generation)
            }
        }
    }

    private func handleFrame(_ frame: Data) {
        guard var sealer = receiveSealer else { return }
        let plain: Data
        do {
            plain = try sealer.open(frame)
            receiveSealer = sealer
        } catch {
            fail("bad frame: \(error)")
            return
        }
        // A newer host may send messages this build does not know; skip them and stay connected.
        guard let message = try? WireCoding.decoder().decode(HostMessage.self, from: plain) else { return }
        apply(message)
    }

    // MARK: HTTP polling transport (watchOS)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.rpc(.snapshot)
                for id in self.subscribed { await self.rpc(.screen(paneID: id, lines: 24)) }
                try? await Task.sleep(for: .seconds(self.subscribed.isEmpty ? 4 : 2))
            }
        }
    }

    private func rpc(_ message: ClientMessage) async {
        let generation = generation
        let address = currentAddress
        let literal = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        guard let url = URL(string: "http://\(literal):\(pairing.httpPort)/rpc") else { return fail("bad address") }
        let request = RPCRequest(message: message, identity: identity, secret: pairing.secret, deviceName: deviceName)
        do {
            var http = URLRequest(url: url)
            http.httpMethod = "POST"
            http.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            http.httpBody = try RPCSealing.seal(request, secret: pairing.secret, .clientToHost)
            let (data, response) = try await session.data(for: http)
            guard generation == self.generation, !Task.isCancelled else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return fail("host answered \((response as? HTTPURLResponse)?.statusCode ?? 0)", rotate: false)
            }
            let reply = try RPCSealing.open(RPCResponse.self, from: data, secret: pairing.secret, .hostToClient)
            guard reply.requestID == request.id else { return fail("mismatched reply") }
            if status != .connected { status = .connected }
            activeAddress = address
            reply.messages.forEach(apply)
        } catch {
            guard !Task.isCancelled else { return }
            fail("\(address): \(error.localizedDescription)", generation: generation)
        }
    }

    // MARK: State

    private func apply(_ message: HostMessage) {
        switch message {
        case .fileTransferSupport(let maximum, let chunk):
            if maximum > 0, chunk >= RemoteFileRules.chunkBytes { fileTransferMaximumBytes = min(maximum, RemoteFileRules.maximumTransferBytes) }
        case .fileTransfer(let reply):
            if case .complete(_, let file) = reply { receivedFile = file }
            fileWaiters.removeValue(forKey: reply.id)?.continuation.resume(returning: reply)
        case .deviceChallenge(let challenge):
            if challenge == expectedIdentityChallenge, let proof = try? identity?.proof(for: challenge) { send(.identifyDevice(proof)) }
        case .permissions(let permissions):
            self.permissions = permissions
            if !permissions.manageRooms { remoteRooms = [] }
        case .rooms(let rooms):
            remoteRooms = rooms
        case .receivedFile(let file):
            receivedFile = file
        case .snapshot(let s):
            supportsPaneNames = s.supportsPaneNames == true
            hostName = s.hostName
            panes = s.panes
            paneAccess = s.paneAccess ?? [:]
            remoteRooms = remoteRooms.compactMap { room in
                var room = room
                room.paneIDs.removeAll { id in !panes.contains { $0.id == id } || !(paneAccess[id] ?? .control).canControl }
                return room.paneIDs.isEmpty ? nil : room
            }
            for id in subscribed where !panes.contains(where: { $0.id == id }) {
                subscribed.remove(id); outputSinks[id] = nil; screens[id] = nil
            }
            fittedSizes = fittedSizes.filter { (paneAccess[$0.key] ?? .control).canControl }
            agents = s.agents
            approvals = s.approvals
            machine = s.machine
            overview = s.overview ?? AgentOverview()
            snapshotReceived = true
        case .paneUpdated(let pane), .spawned(let pane):
            if let i = panes.firstIndex(where: { $0.id == pane.id }) { panes[i] = pane } else { panes.append(pane) }
        case .paneClosed(let id):
            panes.removeAll { $0.id == id }
            screens[id] = nil
        case .replay(let id, let data), .output(let id, let data):
            outputSinks[id]?.values.forEach { $0(data) }
        case .screen(let id, let lines):
            screens[id] = lines
        case .approvals(let list):
            approvals = list
        case .machine(let load):
            machine = load
        case .overview(let new):
            overview = new
        case .error(let code, let text):
            lastError = "\(code): \(text)"
        case .pong(let probe):
            if probe == resumeProbeID {
                resumeProbeTask?.cancel()
                resumeProbeTask = nil
                resumeProbeID = nil
            }
        }
    }

    private func tearDown() {
        connectTask?.cancel()
        connectTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        resumeProbeTask?.cancel()
        resumeProbeTask = nil
        resumeProbeID = nil
        supportsPaneNames = false
        fileTransferMaximumBytes = nil
        let waiters = fileWaiters; fileWaiters = [:]
        for waiter in waiters.values { waiter.continuation.resume(throwing: FileUploadFailure("Disconnected during the file transfer.")) }
        expectedIdentityChallenge = nil
        permissions = nil
        remoteRooms = []
        receivedFile = nil
        receiveTask?.cancel()
        sendTask?.cancel()
        outbox?.finish()
        outbox = nil
        receiveTask = nil
        sendTask = nil
        transport?.close()
        transport = nil
        sendSealer = nil
        receiveSealer = nil
    }

    public struct FileUploadFailure: LocalizedError {
        public var errorDescription: String?
        public init(_ text: String) { errorDescription = text }
    }
    /// Streams bounded chunks; every chunk is acknowledged before reading the next one.
    public func uploadFile(at url: URL) async throws -> ReceivedFile {
        guard activeFileUpload == nil else { throw FileUploadFailure("Another file is being sent. Wait or cancel it first.") }
        guard permissions?.sendFiles == true else { throw FileUploadFailure("On the Mac, turn on Receive files from devices in Remote access settings.") }
        guard let limit = fileTransferMaximumBytes else { throw FileUploadFailure("Update XTermX on this Mac to send large files from the terminal. Older hosts only support 4 MB through Rooms & files.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes <= limit,
              RemoteFileRules.validName(url.lastPathComponent) else { throw FileUploadFailure("Choose a regular file up to 64 MB with a plain filename.") }
        let id = UUID(); activeFileUpload = id; fileUploadProgress = 0
        defer { activeFileUpload = nil; fileUploadProgress = nil }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await expectProgress(.begin(id: id, name: url.lastPathComponent, bytes: bytes), bytes: 0)
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                var offset = 0
                while offset < bytes {
                    try Task.checkCancellation()
                    let chunk = try handle.read(upToCount: min(RemoteFileRules.chunkBytes, bytes - offset)) ?? Data()
                    guard !chunk.isEmpty else { throw FileUploadFailure("The file changed during the transfer. Choose it again.") }
                    try await expectProgress(.chunk(id: id, offset: offset, data: chunk), bytes: offset + chunk.count)
                    offset += chunk.count; fileUploadProgress = bytes == 0 ? 1 : Double(offset) / Double(bytes)
                }
                guard try handle.read(upToCount: 1)?.isEmpty != false else { throw FileUploadFailure("The file changed during the transfer. Choose it again.") }
                let reply = try await fileRequest(.finish(id: id))
                if case .complete(_, let file) = reply { return file }
                throw failure(reply)
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.fileWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
                    self.send(.fileTransfer(.cancel(id: id)))
                }
            }
        } catch { send(.fileTransfer(.cancel(id: id))); throw error }
    }
    private func failure(_ reply: FileTransferReply) -> FileUploadFailure {
        if case .failed(_, let message) = reply { return FileUploadFailure(message) }
        return FileUploadFailure("The transfer acknowledgement did not match. Try again.")
    }
    private func expectProgress(_ request: FileTransferRequest, bytes: Int) async throws {
        let reply = try await fileRequest(request)
        guard case .progress(_, let received) = reply, received == bytes else { throw failure(reply) }
    }
    private func fileRequest(_ request: FileTransferRequest) async throws -> FileTransferReply {
        try Task.checkCancellation()
        guard status == .connected else { throw FileUploadFailure("Connect to the Mac before sending a file.") }
        return try await withCheckedThrowingContinuation { continuation in
            let step = UUID()
            fileWaiters[request.id] = (step, continuation)
            send(.fileTransfer(request))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.fileWaiters[request.id]?.step == step else { return }
                self.fileWaiters.removeValue(forKey: request.id)?.continuation.resume(throwing: FileUploadFailure("The transfer timed out. Try again."))
            }
        }
    }

    /// Invalidate the entire old attempt before closing it. Cancellation callbacks from
    /// its sender/receiver/handshake can never tear down the replacement connection.
    private func fail(_ reason: String, rotate: Bool = true, generation expected: Int? = nil,
                      retry: Bool = true, retryDelay: Double? = nil) {
        guard expected == nil || expected == generation else { return }
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        tearDown()
        // A suspension is not evidence that another route is better than the one in use.
        if rotate && !isBackgrounded { addressIndex += 1 }
        status = .failed(reason)
        if !retry {
            wantsConnection = false
            pollTask?.cancel()
            pollTask = nil
        } else if !usePolling, wantsConnection, !isBackgrounded {
            scheduleReconnect(delay: retryDelay)
        }
    }

    private func scheduleReconnect(delay: Double? = nil) {
        reconnectTask?.cancel()
        let generation = generation
        let delay = delay ?? (addressIndex % max(pairing.addresses.count, 1) == 0 ? 3 : 0.3)
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, generation == self.generation, self.wantsConnection,
                  !self.isBackgrounded, case .failed = self.status else { return }
            self.connect()
        }
    }
}
