#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation

public enum SecureRandom {
    public static func bytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }
}

/// What a client needs to reach and authenticate to a host. Shared once, by QR code or link.
public struct PairingInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(hostName)|\(address)" }
    public var hostName: String
    /// DNS name, MagicDNS/Tailscale name or IP address; empty means "find over Bonjour".
    public var address: String
    /// More ways to reach the same host, tried in order after `address` (e.g. Tailscale, then public IP).
    public var alternates: [String] = []
    public var port: UInt16
    public var httpPort: UInt16
    /// 32 random bytes; the shared secret every frame key is derived from.
    public var secret: Data
    /// MAC address of the host's primary interface, for Wake-on-LAN. Absent in older pairings.
    public var wakeMAC: String?
    /// Subnet broadcast address to send the wake packet to.
    public var wakeBroadcast: String?

    /// Whether this pairing carries what Wake-on-LAN needs.
    public var canWake: Bool { wakeMAC.flatMap(WakeOnLAN.parseMAC) != nil }

    public init(hostName: String, address: String, alternates: [String] = [], port: UInt16 = XTermXProtocol.defaultPort,
                httpPort: UInt16 = XTermXProtocol.defaultHTTPPort, secret: Data) {
        self.hostName = hostName
        self.address = address
        self.alternates = alternates.filter { $0 != address }
        self.port = port
        self.httpPort = httpPort
        self.secret = secret
    }

    /// Every address, the preferred one first.
    public var addresses: [String] { [address] + alternates }

    /// `xtermx://pair?n=<name>&h=<address>&a=<alt1,alt2>&p=<port>&w=<httpPort>&k=<base64url secret>`
    public var url: URL {
        var c = URLComponents()
        c.scheme = "xtermx"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "n", value: hostName),
            URLQueryItem(name: "h", value: address),
        ] + (alternates.isEmpty ? [] : [URLQueryItem(name: "a", value: alternates.joined(separator: ","))]) + [
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "w", value: String(httpPort)),
            URLQueryItem(name: "k", value: secret.base64URLEncoded),
        ] + [wakeMAC.map { URLQueryItem(name: "m", value: $0) }, wakeBroadcast.map { URLQueryItem(name: "b", value: $0) }].compactMap { $0 }
        return c.url!
    }

    private enum CodingKeys: String, CodingKey { case hostName, address, alternates, port, httpPort, secret, wakeMAC, wakeBroadcast }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostName = try c.decode(String.self, forKey: .hostName)
        address = try c.decode(String.self, forKey: .address)
        alternates = try c.decodeIfPresent([String].self, forKey: .alternates) ?? []
        port = try c.decode(UInt16.self, forKey: .port)
        httpPort = try c.decode(UInt16.self, forKey: .httpPort)
        secret = try c.decode(Data.self, forKey: .secret)
        wakeMAC = try c.decodeIfPresent(String.self, forKey: .wakeMAC)
        wakeBroadcast = try c.decodeIfPresent(String.self, forKey: .wakeBroadcast)
    }

    public init?(url: URL) {
        guard url.scheme == "xtermx", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let name = v("n"), let key = v("k").flatMap(Data.init(base64URLEncoded:)), key.count == 32 else { return nil }
        self.init(
            hostName: name,
            address: v("h") ?? "",
            alternates: v("a").map { $0.split(separator: ",").map(String.init) } ?? [],
            port: v("p").flatMap(UInt16.init) ?? XTermXProtocol.defaultPort,
            httpPort: v("w").flatMap(UInt16.init) ?? XTermXProtocol.defaultHTTPPort,
            secret: key
        )
        wakeMAC = v("m").flatMap { WakeOnLAN.parseMAC($0) != nil ? $0 : nil }
        wakeBroadcast = v("b").flatMap { WakeOnLAN.ipv4($0) == nil ? nil : $0 }
    }
}

public enum ChannelError: Error, Equatable {
    case frameTooShort
    case replayed
    case authenticationFailed
    case handshake(String)
}

/// Seals and opens frames for one direction of one connection.
///
/// Frame = 8-byte big-endian counter ‖ ChaChaPoly(nonce ‖ ciphertext ‖ tag), with the
/// counter as authenticated data. Counters must strictly increase, so frames cannot be
/// replayed or reordered within a connection. Session keys mix both handshake nonces,
/// so frames from an earlier connection never open in a new one.
public struct FrameSealer: Sendable {
    private let key: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var lastReceived: UInt64?

    public init(key: SymmetricKey) {
        self.key = key
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        sendCounter += 1
        var header = Data(count: 8)
        header.withUnsafeMutableBytes { $0.storeBytes(of: sendCounter.bigEndian, as: UInt64.self) }
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: header)
        return header + box.combined
    }

    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count > 8 + 12 + 16 else { throw ChannelError.frameTooShort }
        let header = Data(frame.prefix(8))
        let counter = header.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
        if let last = lastReceived, counter <= last { throw ChannelError.replayed }
        do {
            let box = try ChaChaPoly.SealedBox(combined: Data(frame.dropFirst(8)))
            let plain = try ChaChaPoly.open(box, using: key, authenticating: header)
            lastReceived = counter
            return plain
        } catch {
            throw ChannelError.authenticationFailed
        }
    }
}

public enum Direction: String, Sendable {
    case clientToHost = "c2h"
    case hostToClient = "h2c"
}

public enum KeySchedule {
    /// Key for the handshake frames and for single HTTP requests.
    public static func baseKey(secret: Data, _ direction: Direction) -> SymmetricKey {
        derive(secret: secret, salt: Data("xtermx-base-v1".utf8), direction)
    }

    /// Key for everything after the handshake of one connection.
    public static func sessionKey(secret: Data, clientNonce: Data, hostNonce: Data, _ direction: Direction) -> SymmetricKey {
        derive(secret: secret, salt: Data("xtermx-session-v1".utf8) + clientNonce + hostNonce, direction)
    }

    private static func derive(secret: Data, salt: Data, _ direction: Direction) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: Data(direction.rawValue.utf8),
            outputByteCount: 32
        )
    }
}

/// Seals a whole HTTP request or response. Freshness comes from `RPCRequest.sentAt`
/// plus the request id, which the host remembers for the accepted time window.
public enum RPCSealing {
    public static func seal<T: Encodable>(_ value: T, secret: Data, _ direction: Direction) throws -> Data {
        let json = try WireCoding.encoder().encode(value)
        return try ChaChaPoly.seal(json, using: KeySchedule.baseKey(secret: secret, direction)).combined
    }

    public static func open<T: Decodable>(_ type: T.Type, from data: Data, secret: Data, _ direction: Direction) throws -> T {
        let box = try ChaChaPoly.SealedBox(combined: data)
        let json = try ChaChaPoly.open(box, using: KeySchedule.baseKey(secret: secret, direction))
        return try WireCoding.decoder().decode(type, from: json)
    }
}

public extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        self.init(base64Encoded: b)
    }
}
