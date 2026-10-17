import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
#if canImport(Security)
import Security
#endif

public struct DeviceProof: Codable, Sendable {
    public var publicKey: Data
    public var signature: Data
}

/// A signing key identifies an installation, independent of its self-reported device name.
public struct DeviceIdentity: Sendable {
    private let privateKey: Data
    public init() { privateKey = Curve25519.Signing.PrivateKey().rawRepresentation }
    public init(rawRepresentation: Data) throws {
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        privateKey = rawRepresentation
    }
    public func proof(for challenge: Data) throws -> DeviceProof {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        return DeviceProof(publicKey: key.publicKey.rawRepresentation, signature: try key.signature(for: challenge))
    }
    public static func webSocketChallenge(secret: Data, clientNonce: Data, hostNonce: Data) -> Data {
        Data("xtermx-ws-identity-v1".utf8) + Data(SHA256.hash(data: secret)) + clientNonce + hostNonce
    }
    public static func verifiedID(_ proof: DeviceProof, challenge: Data) -> String? {
        guard proof.publicKey.count == 32, proof.signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: proof.publicKey),
              key.isValidSignature(proof.signature, for: challenge) else { return nil }
        return SHA256.hash(data: proof.publicKey).map { String(format: "%02x", $0) }.joined()
    }

    /// Apps call this once. Tests pass an ephemeral identity and never touch the real Keychain.
    public static func loadOrCreate() throws -> DeviceIdentity {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "XTermX.device-identity", kSecAttrAccount as String: "signing-key"]
        var read = query
        read[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return try DeviceIdentity(rawRepresentation: data) }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let identity = DeviceIdentity()
        var add = query
        add[kSecValueData as String] = identity.privateKey
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(add as CFDictionary, nil)
        guard saved == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(saved)) }
        return identity
        #else
        // Headless nodes without a persistent signing-key store remain untrusted between runs.
        return DeviceIdentity()
        #endif
    }
}

extension RPCRequest {
    public func identityChallenge(secret: Data) throws -> Data {
        struct Context: Encodable {
            var id: Data
            var seconds: Int64
            var name: String?
            var message: ClientMessage
        }
        let encoder = WireCoding.encoder()
        encoder.outputFormatting = .sortedKeys
        let context = Context(id: id, seconds: Int64(sentAt.timeIntervalSince1970), name: deviceName, message: message)
        return Data("xtermx-rpc-identity-v1".utf8) + Data(SHA256.hash(data: secret))
            + Data(SHA256.hash(data: try encoder.encode(context)))
    }
}
