#if os(macOS) || os(iOS)
import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH
import Observation
import Security
import XTermXKit

/// A saved SSH destination. Secrets live in the Keychain, never in this struct.
public struct SSHHost: Codable, Identifiable, Hashable, Sendable {
    public enum Auth: String, Codable, Sendable, CaseIterable {
        case password
        case ed25519Key
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: Auth
    /// Typed after login, e.g. `tmux new -A -s main` so the phone and the Mac share sessions.
    public var startupCommand: String
    /// Nil inherits the app palette; optional for compatibility with existing saved hosts.
    public var themeID: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
                auth: Auth = .password, startupCommand: String = "", themeID: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.startupCommand = startupCommand
        self.themeID = themeID
    }
}

public enum SSHHostStore {
    private static let key = "xtermx.ssh.hosts"
    private static let knownHostsKey = "xtermx.ssh.known_hosts"

    public static func load() -> [SSHHost] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SSHHost].self, from: data)) ?? []
    }

    public static func save(_ hosts: [SSHHost]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(hosts), forKey: key)
    }

    // Password or OpenSSH private key text, per host.
    public static func secret(for host: SSHHost) -> String? { Keychain.read(account: host.id.uuidString) }
    public static func setSecret(_ value: String, for host: SSHHost) { Keychain.write(value, account: host.id.uuidString) }
    public static func deleteSecret(for host: SSHHost) { Keychain.delete(account: host.id.uuidString) }

    static func knownKey(_ endpoint: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: knownHostsKey) as? [String: String])?[endpoint]
    }

    static func remember(_ endpoint: String, key: String) {
        var all = (UserDefaults.standard.dictionary(forKey: knownHostsKey) as? [String: String]) ?? [:]
        all[endpoint] = key
        UserDefaults.standard.set(all, forKey: knownHostsKey)
    }

    public static func forget(_ host: SSHHost) {
        var all = (UserDefaults.standard.dictionary(forKey: knownHostsKey) as? [String: String]) ?? [:]
        all["\(host.host):\(host.port)"] = nil
        UserDefaults.standard.set(all, forKey: knownHostsKey)
    }
}

enum Keychain {
    static let service = "XTermX.ssh"

    static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

/// Trust on first use: the first key a host shows is remembered; a different key later is refused.
final class TOFUValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let endpoint: String
    let onNewKey: @Sendable (String) -> Void
    init(endpoint: String, onNewKey: @escaping @Sendable (String) -> Void) {
        self.endpoint = endpoint
        self.onNewKey = onNewKey
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        if let known = SSHHostStore.knownKey(endpoint) {
            if known == presented {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHSession.Failure.hostKeyChanged)
            }
        } else {
            SSHHostStore.remember(endpoint, key: presented)
            onNewKey(presented)
            validationCompletePromise.succeed(())
        }
    }
}

/// One interactive shell over SSH, wired to a `TerminalFeed`.
@MainActor
@Observable
public final class SSHSession {
    public enum Failure: LocalizedError {
        case hostKeyChanged
        case noSecret
        case badKey

        public var errorDescription: String? {
            switch self {
            case .hostKeyChanged: "The server's host key changed since the first connection. If you expected this, forget the key and connect again."
            case .noSecret: "No password or key saved for this host."
            case .badKey: "The private key is not an unencrypted OpenSSH Ed25519 key."
            }
        }
    }

    public enum Status: Equatable {
        case idle, connecting, connected, closed
        case failed(String)
    }

    public let host: SSHHost
    public private(set) var status: Status = .idle
    public private(set) var newHostKey: String?
    @ObservationIgnored public let feed = TerminalFeed()
    @ObservationIgnored var client: SSHClient?
    @ObservationIgnored private var writer: TTYStdinWriter?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    public init(host: SSHHost) {
        self.host = host
        feed.onInput = { [weak self] data in self?.write(data) }
        feed.onResize = { [weak self] cols, rows in self?.resize(cols: cols, rows: rows) }
    }

    public func connect() {
        guard task == nil else { return }
        status = .connecting
        let host = host
        let generation = UUID(); self.generation = generation
        task = Task { [weak self] in
            do {
                try await self?.run(host, generation: generation)
                guard self?.generation == generation else { return }
                self?.status = .closed
            } catch {
                guard self?.generation == generation else { return }
                self?.status = .failed(error.localizedDescription)
            }
            self?.task = nil
        }
    }

    public func disconnect() {
        generation = UUID()
        task?.cancel()
        task = nil
        let client = client
        self.client = nil; writer = nil
        Task { try? await client?.close() }
        status = .closed
    }

    public static func secretError(_ secret: String?, for auth: SSHHost.Auth) -> String? {
        guard let secret, !secret.isEmpty else { return Failure.noSecret.localizedDescription }
        if auth == .ed25519Key, (try? Curve25519.Signing.PrivateKey(sshEd25519: secret)) == nil { return Failure.badKey.localizedDescription }
        return nil
    }
    private func checkedSecret(_ host: SSHHost) throws -> String {
        if let error = SSHConnectionRules.error(host: host.host, port: host.port, username: host.username) {
            throw NSError(domain: "XTermX.SSH", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        guard let secret = SSHHostStore.secret(for: host), !secret.isEmpty else { throw Failure.noSecret }
        if host.auth == .ed25519Key, Self.secretError(secret, for: host.auth) != nil { throw Failure.badKey }
        return secret
    }

    private nonisolated static func authentication(_ host: SSHHost, _ secret: String) -> SSHAuthenticationMethod {
        switch host.auth {
        case .password:
            return .passwordBased(username: host.username, password: secret)
        case .ed25519Key:
            // Validated by `checkedSecret` before connecting.
            return .ed25519(username: host.username, privateKey: try! Curve25519.Signing.PrivateKey(sshEd25519: secret))
        }
    }

    private func run(_ host: SSHHost, generation: UUID) async throws {
        let secret = try checkedSecret(host)
        let validator = TOFUValidator(endpoint: "\(host.host):\(host.port)") { [weak self] key in
            Task { @MainActor in self?.newHostKey = key }
        }
        let settings = SSHClientSettings(host: host.host, port: host.port, authenticationMethod: { Self.authentication(host, secret) },
                                         hostKeyValidator: .custom(validator))
        let client = try await SSHClient.connect(to: settings)
        guard self.generation == generation, !Task.isCancelled else { try? await client.close(); return }
        self.client = client
        status = .connected

        let size = feed.size ?? (80, 24)
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: size.cols, terminalRowHeight: size.rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:])
        )
        do {
        try await client.withPTY(pty, environment: [.init(wantReply: false, name: "LANG", value: "en_US.UTF-8")]) { [weak self] inbound, outbound in
            await MainActor.run { if self?.generation == generation { self?.writer = outbound } }
            if !host.startupCommand.isEmpty {
                try await outbound.write(ByteBuffer(string: host.startupCommand + "\r"))
            }
            for try await chunk in inbound {
                let buffer: ByteBuffer
                switch chunk {
                case .stdout(let b), .stderr(let b): buffer = b
                }
                let data = Data(buffer.readableBytesView)
                await MainActor.run { if self?.generation == generation { self?.feed.receive(data) } }
            }
        }
        } catch {
            try? await client.close()
            if self.generation == generation { self.client = nil; writer = nil }
            throw error
        }
        try? await client.close()
        if self.generation == generation { self.client = nil; writer = nil }
    }

    public func send(_ data: Data) { write(data) }

    private func write(_ data: Data) {
        guard let writer else { return }
        Task { try? await writer.write(ByteBuffer(bytes: data)) }
    }

    private func resize(cols: Int, rows: Int) {
        guard let writer else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }
}
#endif
