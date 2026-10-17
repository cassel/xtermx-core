#if os(macOS) || os(Linux)
import Foundation
import Observation
#if os(macOS)
import SystemConfiguration
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Glibc)
import Glibc
#endif
import XTermXKit
import XTermXNIO

// MARK: - Secret storage

/// Where a node keeps the 32-byte secret its paired devices share.
public protocol SecretStore: Sendable {
    func load() -> Data?
    func save(_ secret: Data)
    func delete()
}

/// A base64 file readable only by its owner: the store for Linux nodes and `xtermx serve`.
public struct FileSecretStore: SecretStore {
    public let url: URL

    public init(directory: URL = FileSecretStore.defaultDirectory) {
        url = directory.appendingPathComponent("secret")
    }

    /// `$XDG_CONFIG_HOME/xtermx`, or `~/.config/xtermx`.
    public static var defaultDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("xtermx")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/xtermx")
    }

    public func load() -> Data? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else { return nil }
        return data
    }

    public func save(_ secret: Data) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: url.path, contents: Data(secret.base64EncodedString().utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    public func delete() { try? FileManager.default.removeItem(at: url) }
}

/// Keeps nothing on disk: tests and throwaway nodes.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var secret: Data?
    public init(_ secret: Data? = nil) { self.secret = secret }
    public func load() -> Data? { secret }
    public func save(_ secret: Data) { self.secret = secret }
    public func delete() { secret = nil }
}

#if canImport(Security)
/// The login Keychain: the store for the Mac app.
public struct KeychainSecretStore: SecretStore {
    private static let service = "XTermX"
    private static let account = "host-secret"

    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    public func load() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    public func save(_ secret: Data) {
        var q = query
        q[kSecValueData as String] = secret
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    public func delete() { SecItemDelete(query as CFDictionary) }
}
#endif

// MARK: - Identity

public enum HostIdentity {
    public static var defaultStore: SecretStore {
        #if canImport(Security)
        KeychainSecretStore()
        #else
        FileSecretStore()
        #endif
    }

    public static func secret(_ store: SecretStore = defaultStore) -> Data {
        if let existing = store.load() { return existing }
        let fresh = SecureRandom.bytes(32)
        store.save(fresh)
        return fresh
    }

    /// Forgets every paired device: they all need to scan the new code.
    @discardableResult
    public static func rotate(_ store: SecretStore = defaultStore) -> Data {
        store.delete()
        return secret(store)
    }

    /// The name devices see for this machine.
    public static var hostName: String {
        #if os(macOS)
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    /// The shared IPv4 range used by a Tailscale interface; an address alone does not prove reachability.
    public static func isTailscaleAddress(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        let octets = parts.compactMap { Int($0) }
        return octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
            && octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// Addresses a client may use, best first: Tailscale (100.64/10), then the Bonjour name (Mac),
    /// then the machine's other IPv4 addresses.
    public static func addresses() -> [String] {
        var tailscale: [String] = []
        var others: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let flags = Int32(ptr.pointee.ifa_flags)
                let up: Int32 = 0x1, loopback: Int32 = 0x8
                guard flags & up != 0, flags & loopback == 0, let sa = ptr.pointee.ifa_addr,
                      Int32(sa.pointee.sa_family) == AF_INET else { continue }
                var host = [CChar](repeating: 0, count: 1025)
                if getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if isTailscaleAddress(ip) {
                        if !tailscale.contains(ip) { tailscale.append(ip) }
                    } else if !others.contains(ip) { others.append(ip) }
                }
            }
        }
        var result = tailscale
        #if os(macOS)
        // Read the configured Bonjour label directly; NSHost.names may block on DNS.
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty { result.append(local + ".local") }
        #endif
        return result + others
    }
}

public struct ConnectedDevice: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var platform: ClientPlatform
    public var since: Date
    public var address: String
    /// Verified signing-key fingerprint, independent of the reported name and connection UUID.
    public var identity: String? = nil
    public var connectionCount: Int = 1

    /// Two sockets from the same installation are one device. Equal names alone prove nothing.
    public static func grouped(_ connections: [ConnectedDevice]) -> [ConnectedDevice] {
        var result: [ConnectedDevice] = []
        var byIdentity: [String: Int] = [:]
        for device in connections {
            if let identity = device.identity, let index = byIdentity[identity] {
                result[index].connectionCount += device.connectionCount
            } else {
                if let identity = device.identity { byIdentity[identity] = result.count }
                result.append(device)
            }
        }
        return result
    }
}

// MARK: - Remote server

/// Serves the panes of a `PaneManager` to paired devices and other nodes: a WebSocket for
/// iPhones, Macs and Linux nodes, and `POST /rpc` over plain HTTP for the Watch.
/// The same code runs in the Mac app and in `xtermx serve` on Linux.
@MainActor
@Observable
public final class RemoteServer {
    public private(set) var isRunning = false
    private var deviceConnections: [ConnectedDevice] = []
    public var devices: [ConnectedDevice] { ConnectedDevice.grouped(deviceConnections) }
    @ObservationIgnored public var onDeviceVerified: ((ConnectedDevice) -> Void)?
    @ObservationIgnored public var onDevicesForgotten: (() -> Void)?
    public private(set) var lastError: String?
    public var permissions = RemotePermissions() {
        didSet {
            guard permissions != oldValue else { return }
            if !permissions.sendFiles { fileChunks.cancelAll() }
            onPermissionsChanged?(permissions)
            for peer in peers.values where peer.sendSealer != nil { send(.permissions(permissions), to: peer) }
        }
    }
    public var allowRemoteSpawn: Bool {
        get { permissions.openSessions }
        set { permissions.openSessions = newValue }
    }
    @ObservationIgnored public var onPermissionsChanged: ((RemotePermissions) -> Void)?
    @ObservationIgnored public var roomList: (() -> [RemoteRoom])?
    @ObservationIgnored public var roomAction: ((RemoteRoomAction) -> Void)?
    @ObservationIgnored public var receivedFiles = ReceivedFileStore()
    @ObservationIgnored private let fileChunks = FileChunkReceiver()
    public let passwordPairing = PasswordPairingGate()
    public let spawnGate = RemoteSpawnGate()
    public private(set) var paneSharing = PaneSharingPolicy() {
        didSet {
            guard paneSharing != oldValue else { return }
            onSharingChanged?(paneSharing)
            for pane in manager.panes where oldValue.access(pane.id).canControl && !paneSharing.access(pane.id).canControl {
                manager.releaseRemoteSize(pane.id)
            }
            for peer in peers.values where peer.sendSealer != nil {
                for id in peer.subscriptions where !paneSharing.access(id).canControl { manager.release(id, device: peer.id) }
                for id in peer.subscriptions where !paneSharing.access(id).canView {
                    peer.subscriptions.remove(id)
                    viewLeases.remove(id)
                    send(.paneClosed(paneID: id), to: peer)
                }
                send(.snapshot(snapshotForDevices()), to: peer)
                if permissions.manageRooms { send(.rooms(roomsForDevices()), to: peer) }
            }
        }
    }
    @ObservationIgnored public var onSharingChanged: ((PaneSharingPolicy) -> Void)?
    public func restoreSharing(_ policy: PaneSharingPolicy) { paneSharing = policy }
    public func setPaneAccess(_ id: String, to access: PaneAccess) {
        var policy = paneSharing
        policy.set(id, to: access)
        if let pane = manager.panes.first(where: { $0.id == id }) { policy.remember(pane) }
        paneSharing = policy
    }
    private func snapshotForDevices() -> HostSnapshot {
        var snapshot = manager.snapshot()
        snapshot.panes.removeAll { !paneSharing.access($0.id).canView }
        snapshot.approvals = paneSharing.visibleApprovals(snapshot.approvals)
        snapshot.paneAccess = Dictionary(uniqueKeysWithValues: snapshot.panes.map { ($0.id, paneSharing.access($0.id)) })
        snapshot.overview = snapshot.overview.map(paneSharing.visibleOverview)
        return snapshot
    }
    private func roomsForDevices() -> [RemoteRoom] {
        (roomList?() ?? []).compactMap { room in
            var room = room
            room.paneIDs.removeAll { !paneSharing.access($0).canControl }
            return room.paneIDs.isEmpty ? nil : room
        }
    }
    private var paneDenied: [HostMessage] { [.error(code: "PANE_ACCESS", message: "This pane does not allow that remote action.")] }
    @ObservationIgnored private var viewLeases = RemoteViewLeases()

    @ObservationIgnored private let manager: PaneManager
    @ObservationIgnored private let store: SecretStore
    @ObservationIgnored private var secret: Data
    @ObservationIgnored private var wsServer: WSServer?
    @ObservationIgnored private var httpServer: RawHTTPServer?
    @ObservationIgnored private var peers: [UUID: Peer] = [:]
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var seenRPC: [Data: Date] = [:]
    @ObservationIgnored public private(set) var port: UInt16
    @ObservationIgnored public private(set) var httpPort: UInt16
    @ObservationIgnored private let bindHost: String
    #if os(macOS)
    @ObservationIgnored private var bonjour: NetService?
    #endif

    public init(manager: PaneManager, port: UInt16 = XTermXProtocol.defaultPort, httpPort: UInt16 = XTermXProtocol.defaultHTTPPort,
                secretStore: SecretStore = HostIdentity.defaultStore, bindHost: String = "0.0.0.0") {
        self.manager = manager
        self.port = port
        self.httpPort = httpPort
        self.store = secretStore
        self.secret = HostIdentity.secret(secretStore)
        self.bindHost = bindHost
    }

    public func pairing(address: String) -> PairingInfo {
        PairingInfo(hostName: manager.hostName, address: address, port: port, httpPort: httpPort, secret: secret)
    }

    /// A pairing that lists several ways in (Tailscale, LAN, public); clients try them in order.
    public func pairing(addresses: [String]) -> PairingInfo {
        PairingInfo(hostName: manager.hostName, address: addresses.first ?? "", alternates: Array(addresses.dropFirst()),
                    port: port, httpPort: httpPort, secret: secret)
    }

    public func rotateSecret() {
        secret = HostIdentity.rotate(store)
        for peer in Array(peers.values) { peer.connection.close(); drop(peer.id) }
        onDevicesForgotten?()
    }

    // MARK: Lifecycle

    public func start() {
        guard !isRunning else { return }
        let ws = WSServer { [weak self] connection in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(connection) } }
        }
        let http = RawHTTPServer { [weak self] request in
            await self?.respond(to: request) ?? Data()
        }
        do {
            port = UInt16(try ws.start(host: bindHost, port: Int(port)))
            httpPort = UInt16(try http.start(host: bindHost, port: Int(httpPort)))
        } catch {
            ws.stop()
            http.stop()
            lastError = "\(error)"
            return
        }
        wsServer = ws
        httpServer = http
        listenerID = manager.addListener { [weak self] event in self?.broadcast(event) }
        #if os(macOS)
        let service = NetService(domain: "local.", type: XTermXProtocol.bonjourType + ".", name: manager.hostName, port: Int32(port))
        service.publish()
        bonjour = service
        #endif
        lastError = nil
        isRunning = true
    }

    public func stop() {
        fileChunks.cancelAll()
        viewLeases.clear()
        spawnGate.cancel()
        wsServer?.stop()
        httpServer?.stop()
        wsServer = nil
        httpServer = nil
        #if os(macOS)
        bonjour?.stop()
        bonjour = nil
        #endif
        for peer in peers.values { peer.connection.close() }
        peers.removeAll()
        deviceConnections.removeAll()
        if let listenerID { manager.removeListener(listenerID) }
        listenerID = nil
        isRunning = false
    }

    // MARK: WebSocket peers

    @MainActor
    private final class Peer {
        let connection: WSConnection
        var sendSealer: FrameSealer?
        var receiveSealer: FrameSealer?
        var subscriptions: Set<String> = []
        var deviceID: String?
        var deviceName = "Paired device"
        var identityChallenge = Data()
        init(connection: WSConnection) { self.connection = connection }
        var id: UUID { connection.id }
    }

    private func accept(_ connection: WSConnection) {
        let peer = Peer(connection: connection)
        peers[peer.id] = peer
        let id = peer.id
        connection.onFrame { [weak self] frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleFrame(frame, from: id) } }
        }
        connection.onClose { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.drop(id) } }
        }
    }

    private func drop(_ id: UUID) {
        spawnGate.cancel(source: id)
        peers[id] = nil
        deviceConnections.removeAll { $0.id == id }
        fileChunks.cancelAll(owner: "ws:" + id.uuidString)
        manager.release(device: id)
    }

    private func handleFrame(_ frame: Data, from id: UUID) {
        guard let peer = peers[id] else { return }
        do {
            guard var opener = peer.receiveSealer else {
                try handshake(frame, peer: peer)
                return
            }
            let plain = try opener.open(frame)
            peer.receiveSealer = opener
            let message = try WireCoding.decoder().decode(ClientMessage.self, from: plain)
            if case .spawn(let request) = message {
                Task { [weak self, weak peer] in
                    guard let self, let peer else { return }
                    let replies = await spawn(request, deviceID: peer.deviceID, name: peer.deviceName, source: peer.id)
                    guard peers[peer.id] != nil else { return }
                    for reply in replies { send(reply, to: peer) }
                }
            } else { for reply in handle(message, peer: peer) { send(reply, to: peer) } }
        } catch {
            // Wrong secret, replay or garbage: close without telling why.
            peer.connection.close()
        }
    }

    private func handshake(_ frame: Data, peer: Peer) throws {
        var opener = FrameSealer(key: KeySchedule.baseKey(secret: secret, .clientToHost))
        let hello = try WireCoding.decoder().decode(ClientHello.self, from: opener.open(frame))
        guard hello.nonce.count == 32 else { throw ChannelError.handshake("nonce") }
        let hostNonce = SecureRandom.bytes(32)
        peer.deviceName = hello.deviceName
        peer.identityChallenge = DeviceIdentity.webSocketChallenge(secret: secret, clientNonce: hello.nonce, hostNonce: hostNonce)
        var sealer = FrameSealer(key: KeySchedule.baseKey(secret: secret, .hostToClient))
        peer.connection.send(try sealer.seal(WireCoding.encoder().encode(HostHello(hostName: manager.hostName, nonce: hostNonce))))
        peer.sendSealer = FrameSealer(key: KeySchedule.sessionKey(secret: secret, clientNonce: hello.nonce, hostNonce: hostNonce, .hostToClient))
        peer.receiveSealer = FrameSealer(key: KeySchedule.sessionKey(secret: secret, clientNonce: hello.nonce, hostNonce: hostNonce, .clientToHost))
        deviceConnections.append(ConnectedDevice(id: peer.id, name: hello.deviceName, platform: hello.platform, since: .now,
                                       address: peer.connection.remoteAddress))
    }

    private func send(_ message: HostMessage, to peer: Peer) {
        guard var sealer = peer.sendSealer, let json = try? WireCoding.encoder().encode(message),
              let frame = try? sealer.seal(json) else { return }
        peer.sendSealer = sealer
        peer.connection.send(frame)
    }

    private func broadcast(_ event: HostEvent) {
        if case .paneUpdated(let info) = event {
            var policy = paneSharing
            policy.remember(info)
            if policy != paneSharing { paneSharing = policy }
        }
        for peer in peers.values where peer.sendSealer != nil {
            switch event {
            case .output(let id, let data):
                if peer.subscriptions.contains(id), paneSharing.access(id).canView { send(.output(paneID: id, data: data), to: peer) }
            case .paneUpdated(let info):
                if paneSharing.access(info.id).canView { send(.paneUpdated(info), to: peer) }
            case .paneClosed(let id):
                viewLeases.remove(id)
                peer.subscriptions.remove(id)
                send(.paneClosed(paneID: id), to: peer)
            case .approvals(let list):
                send(.approvals(paneSharing.visibleApprovals(list)), to: peer)
            case .machine(let load):
                send(.machine(load), to: peer)
            case .overview(let overview):
                send(.overview(paneSharing.visibleOverview(overview)), to: peer)
            }
        }
    }

    /// Only actual subscribers or recently polled panes count, never idle paired devices.
    public func watchedPaneIDs(now: Date = .now) -> Set<String> {
        guard isRunning else { return [] }
        let streamed = Set(peers.values.flatMap { $0.subscriptions })
        return streamed.union(viewLeases.active(now: now)).filter { manager.session($0) != nil && paneSharing.access($0).canView }
    }

    // MARK: Messages (both transports)

    private func handle(_ message: ClientMessage, peer: Peer?, uploadOwner: String? = nil) -> [HostMessage] {
        switch message {
        case .snapshot:
            var replies: [HostMessage] = [.snapshot(snapshotForDevices()), .permissions(permissions), .fileTransferSupport(maximumBytes: RemoteFileRules.maximumTransferBytes, chunkBytes: RemoteFileRules.chunkBytes)]
            if let peer { replies.insert(.deviceChallenge(peer.identityChallenge), at: 0) }
            return replies
        case .identifyDevice(let proof):
            guard let peer, let id = DeviceIdentity.verifiedID(proof, challenge: peer.identityChallenge),
                  peer.deviceID == nil || peer.deviceID == id else {
                return [.error(code: "IDENTITY_INVALID", message: "Device identity could not be verified.")]
            }
            peer.deviceID = id
            if let index = deviceConnections.firstIndex(where: { $0.id == peer.id }) {
                deviceConnections[index].identity = id
                onDeviceVerified?(deviceConnections[index])
            }
            return []
        case .rooms:
            guard permissions.manageRooms else { return [.error(code: "ROOMS_OFF", message: "Room access is off on this Mac.")] }
            return [.rooms(roomsForDevices())]
        case .roomAction(let action):
            guard permissions.manageRooms else { return [.error(code: "ROOMS_OFF", message: "Room access is off on this Mac.")] }
            guard roomList != nil, let roomAction, action.isValid(in: roomsForDevices()) else {
                return [.error(code: "ROOM_INVALID", message: "The room or its members have changed. Refresh and try again.")]
            }
            roomAction(action)
            return [.rooms(roomsForDevices())]
        case .fileTransfer(let request):
            guard let owner = uploadOwner ?? peer.map({ "ws:" + $0.id.uuidString }) else { return [.fileTransfer(.failed(id: request.id, message: "A verified device identity is required for this transfer."))] }
            if case .cancel = request { fileChunks.cancel(request.id, owner: owner); return [.fileTransfer(.progress(id: request.id, bytes: 0))] }
            guard permissions.sendFiles else { fileChunks.cancel(request.id, owner: owner); return [.fileTransfer(.failed(id: request.id, message: "On the Mac, turn on Receive files from devices in Remote access settings."))] }
            do { return [.fileTransfer(try fileChunks.handle(request, owner: owner, store: receivedFiles))] }
            catch { fileChunks.cancel(request.id, owner: owner); return [.fileTransfer(.failed(id: request.id, message: "The Mac could not save this transfer. Check free space and try again."))] }
        case .upload(let name, let data):
            guard permissions.sendFiles else { return [.error(code: "FILES_OFF", message: "Receiving files is off on this Mac.")] }
            do { return [.receivedFile(try receivedFiles.receive(name: name, data: data))] }
            catch let error as ReceivedFileStore.Failure {
                return [.error(code: "FILE_REJECTED", message: error.localizedDescription)]
            } catch { return [.error(code: "FILE_FAILED", message: "The Mac could not save this file.")] }
        case .subscribe(let id):
            guard paneSharing.access(id).canView else { return paneDenied }
            guard let session = manager.session(id) else { return [.error(code: "NO_PANE", message: "No pane \(id)")] }
            peer?.subscriptions.insert(id)
            // Redrawn at the pane's size (a client resizes first): raw output wraps wrongly at another width.
            return [.replay(paneID: id, data: session.snapshot())]
        case .unsubscribe(let id):
            peer?.subscriptions.remove(id)
            if let peer { manager.release(id, device: peer.id) }
            return []
        case .input(let id, let data):
            guard paneSharing.access(id).canControl else { return paneDenied }
            manager.write(id, data)
            return []
        case .resize(let id, let cols, let rows):
            guard paneSharing.access(id).canControl else { return paneDenied }
            manager.resize(id, cols: cols, rows: rows, device: peer?.id)
            return []
        case .send(let id, let text):
            guard paneSharing.access(id).canControl else { return paneDenied }
            manager.sendLine(id, text)
            return []
        case .spawn:
            return [.error(code: "SPAWN_DENIED", message: "This request needs host approval.")]
        case .rename(let id, let name):
            guard paneSharing.access(id).canControl else { return paneDenied }
            do {
                guard let pane = try manager.rename(id, to: name) else { return [.error(code: "NO_PANE", message: "This terminal has closed.")] }
                return [.paneUpdated(pane)]
            } catch { return [.error(code: "PANE_NAME", message: error.localizedDescription)] }
        case .close(let id):
            guard paneSharing.access(id).canControl else { return paneDenied }
            manager.close(id)
            return []
        case .answer(let requestID, let allow):
            guard let request = manager.approvals.first(where: { $0.id == requestID }),
                  request.paneID.map({ paneSharing.access($0).canControl }) ?? true else { return paneDenied }
            manager.answer(requestID, allow: allow)
            return []
        case .respond(let requestID, let answer):
            guard let request = manager.approvals.first(where: { $0.id == requestID }),
                  request.paneID.map({ paneSharing.access($0).canControl }) ?? true else { return paneDenied }
            manager.respond(requestID, answer)
            return []
        case .screen(let id, let lines):
            guard paneSharing.access(id).canView else { return paneDenied }
            guard let session = manager.session(id) else { return [.error(code: "NO_PANE", message: "No pane \(id)")] }
            viewLeases.poll(id)
            return [.screen(paneID: id, lines: session.screenLines(max(1, min(lines, 80))))]
        case .ping(let date):
            return [.pong(date)]
        }
    }

    private func spawn(_ request: SpawnRequest, deviceID: String?, name: String, source: UUID?) async -> [HostMessage] {
        guard allowRemoteSpawn else { return [.error(code: "SPAWN_OFF", message: "Opening panes from other devices is off on this machine.")] }
        var request = request
        request.cwd = RemoteSpawnGate.folder(for: request.cwd)
        guard await spawnGate.authorize(request, deviceID: deviceID, name: name, source: source),
              !Task.isCancelled, isRunning, allowRemoteSpawn, source.map({ peers[$0] != nil }) ?? true else {
            return [.error(code: "SPAWN_DENIED", message: "The Mac did not approve this terminal.")]
        }
        do {
            let prepared = try await manager.prepareSpawn(request)
            guard !Task.isCancelled, isRunning, allowRemoteSpawn, source.map({ peers[$0] != nil }) ?? true else { return [.error(code: "SPAWN_DENIED", message: "This request is no longer allowed.")] }
            return [.spawned(manager.spawnPrepared(prepared))]
        } catch { return [.error(code: "SPAWN_FAILED", message: "The Mac could not prepare an isolated terminal. Check it on the Mac.")] }
    }

    // MARK: HTTP (Watch)

    private func respond(to request: HTTPRequest) async -> Data {
        var status = "200 OK"
        var body = Data()
        if request.method == "POST", request.path == "/pair/start" || request.path == "/pair/finish" {
            do {
                guard request.body.count <= 4096 else { throw PasswordPairingError.refused }
                if request.path == "/pair/start" {
                    let start = try JSONDecoder().decode(PasswordPairingStart.self, from: request.body)
                    body = try JSONEncoder().encode(passwordPairing.begin(start))
                } else {
                    let proof = try JSONDecoder().decode(PasswordPairingProof.self, from: request.body)
                    body = try JSONEncoder().encode(passwordPairing.finish(proof, pairing: pairing(addresses: HostIdentity.addresses())))
                }
            } catch PasswordPairingError.rateLimited { status = "429 Too Many Requests" }
            catch { status = "403 Forbidden" }
        } else if request.method == "POST", request.path == "/rpc" {
            do {
                let rpc = try RPCSealing.open(RPCRequest.self, from: request.body, secret: secret, .clientToHost)
                let now = Date.now
                seenRPC = seenRPC.filter { now.timeIntervalSince($0.value) < 300 }
                guard abs(now.timeIntervalSince(rpc.sentAt)) < 120, seenRPC[rpc.id] == nil else { throw ChannelError.replayed }
                seenRPC[rpc.id] = now
                var replies: [HostMessage]
                let identity = rpc.deviceProof.flatMap { proof in
                    (try? rpc.identityChallenge(secret: secret)).flatMap { DeviceIdentity.verifiedID(proof, challenge: $0) }
                }
                if case .spawn(let request) = rpc.message {
                    replies = await spawn(request, deviceID: identity, name: rpc.deviceName ?? "Paired device", source: nil)
                } else { replies = handle(rpc.message, peer: nil, uploadOwner: identity.map { "rpc:" + $0 }) }
                if replies.isEmpty { replies = [.snapshot(snapshotForDevices())] }
                body = try RPCSealing.seal(RPCResponse(requestID: rpc.id, messages: replies), secret: secret, .hostToClient)
            } catch {
                status = "403 Forbidden"
            }
        } else {
            status = "404 Not Found"
        }
        let type = body.isEmpty ? "text/plain" : "application/octet-stream"
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
#endif
