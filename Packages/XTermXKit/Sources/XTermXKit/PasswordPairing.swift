import Foundation
import Observation

public enum PairingPasswordLifetime: String, Codable, CaseIterable, Sendable, Identifiable {
    case hour, workday, day, unlimited
    public var id: Self { self }
    public var title: String {
        switch self { case .hour: "1 hour"; case .workday: "8 hours"; case .day: "24 hours"; case .unlimited: "Until turned off" }
    }
    public func expiry(from now: Date) -> Date? {
        switch self {
        case .hour: now.addingTimeInterval(3600)
        case .workday: now.addingTimeInterval(8 * 3600)
        case .day: now.addingTimeInterval(24 * 3600)
        case .unlimited: nil
        }
    }
}

public struct PairingPasswordRecord: Codable, Sendable {
    public var salt: Data
    public var verifier: Data
    public var expiresAt: Date?
    public func isActive(at now: Date) -> Bool {
        salt.count == 32 && verifier.count == 256 && (expiresAt.map { now < $0 } ?? true)
    }
}

public struct PasswordPairingStart: Codable, Sendable {
    public var publicKey: Data
    public init(publicKey: Data) { self.publicKey = publicKey }
}
public struct PasswordPairingChallenge: Codable, Sendable {
    public var attemptID: UUID
    public var salt: Data
    public var publicKey: Data
}
public struct PasswordPairingProof: Codable, Sendable {
    public var attemptID: UUID
    public var proof: Data
    public init(attemptID: UUID, proof: Data) { self.attemptID = attemptID; self.proof = proof }
}
public struct PasswordPairingResult: Codable, Sendable {
    public var proof: Data
    public var sealedPairing: Data
}

public enum PasswordPairingError: LocalizedError {
    case invalidPassword, refused, rateLimited, invalidHost
    public var errorDescription: String? {
        switch self {
        case .invalidPassword: "Use between 6 and 128 characters for the pairing password."
        case .refused: "Pairing failed. Check the address, password and its expiry on the Mac."
        case .rateLimited: "Too many pairing attempts. Wait a minute and try again."
        case .invalidHost: "Enter a Mac address and a valid port."
        }
    }
}

#if !os(watchOS)
#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
@preconcurrency import SRP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SRP-6a (RFC 5054, 2048-bit group, SHA-256). Passwords and the host key are never sent in plaintext.
@MainActor @Observable public final class PasswordPairingGate {
    private struct Attempt {
        var challenge: PasswordPairingChallenge
        var clientKey: SRPKey
        var secret: SRPKey
        var expiresAt: Date
    }
    public var record: PairingPasswordRecord? { didSet { attempts = [:]; starts = [] } }
    private var attempts: [UUID: Attempt] = [:]
    private var starts: [Date] = []
    private var server: SRPServer<SHA256> { SRPServer(configuration: SRPConfiguration(.N2048)) }
    private static let identity = "xtermx-pair-v1"

    public init(record: PairingPasswordRecord? = nil) { self.record = record }

    public static func makeRecord(password: String, lifetime: PairingPasswordLifetime, now: Date = .now) throws -> PairingPasswordRecord {
        guard (6...128).contains(password.count), password.utf8.count <= 512 else { throw PasswordPairingError.invalidPassword }
        let client = SRPClient<SHA256>(configuration: SRPConfiguration(.N2048))
        let values = client.generateSaltAndVerifier(username: identity, password: password)
        return PairingPasswordRecord(salt: Data(values.salt), verifier: Data(values.verifier.bytes), expiresAt: lifetime.expiry(from: now))
    }

    public static func generatePassword() -> String { SecureRandom.bytes(18).base64URLEncoded }

    public func begin(_ start: PasswordPairingStart, now: Date = .now) throws -> PasswordPairingChallenge {
        starts.removeAll { now.timeIntervalSince($0) >= 60 }
        guard starts.count < 8 else { throw PasswordPairingError.rateLimited }
        starts.append(now)
        attempts = attempts.filter { now < $0.value.expiresAt }
        guard let record, record.isActive(at: now), start.publicKey.count == 256 else { throw PasswordPairingError.refused }
        let verifier = SRPKey(record.verifier), clientKey = SRPKey(start.publicKey)
        let keys = server.generateKeys(verifier: verifier)
        let secret = try server.calculateSharedSecret(clientPublicKey: clientKey, serverKeys: keys, verifier: verifier)
        let challenge = PasswordPairingChallenge(attemptID: UUID(), salt: record.salt, publicKey: Data(keys.public.bytes))
        attempts[challenge.attemptID] = Attempt(challenge: challenge, clientKey: clientKey, secret: secret,
                                              expiresAt: min(now.addingTimeInterval(60), record.expiresAt ?? .distantFuture))
        return challenge
    }

    public func finish(_ proof: PasswordPairingProof, pairing: PairingInfo, now: Date = .now) throws -> PasswordPairingResult {
        // One use, including failures; credential changes, expiry and replay invalidate the exchange.
        guard let attempt = attempts.removeValue(forKey: proof.attemptID), now < attempt.expiresAt,
              let record, record.isActive(at: now), proof.proof.count == 32 else { throw PasswordPairingError.refused }
        let serverProof = try server.verifyClientProof(proof: Array(proof.proof), username: Self.identity,
                                                      salt: Array(record.salt), clientPublicKey: attempt.clientKey,
                                                      serverPublicKey: SRPKey(attempt.challenge.publicKey), sharedSecret: attempt.secret)
        let key = Data(SHA256.hash(data: attempt.secret.bytes))
        return PasswordPairingResult(proof: Data(serverProof), sealedPairing: try RPCSealing.seal(pairing, secret: key, .hostToClient))
    }
}

/// A fresh client keypair for each attempt; a verified server proof is required before accepting a Mac key.
@MainActor public final class PasswordPairingClient {
    private let client = SRPClient<SHA256>(configuration: SRPConfiguration(.N2048))
    private let keys: SRPKeyPair
    private var secret: SRPKey?
    private var proof: [UInt8]?
    private var used = false
    private static let identity = "xtermx-pair-v1"

    public init() { keys = client.generateKeys() }
    public var start: PasswordPairingStart { PasswordPairingStart(publicKey: Data(keys.public.bytes)) }

    public func answer(_ challenge: PasswordPairingChallenge, password: String) throws -> PasswordPairingProof {
        guard !used, challenge.publicKey.count == 256, challenge.salt.count == 32,
              (6...128).contains(password.count), password.utf8.count <= 512 else { throw PasswordPairingError.refused }
        used = true
        let serverKey = SRPKey(challenge.publicKey)
        let shared = try client.calculateSharedSecret(username: Self.identity, password: password,
                                                      salt: Array(challenge.salt), clientKeys: keys, serverPublicKey: serverKey)
        let proof = client.calculateClientProof(username: Self.identity, salt: Array(challenge.salt),
                                               clientPublicKey: keys.public, serverPublicKey: serverKey, sharedSecret: shared)
        self.secret = shared; self.proof = proof
        return PasswordPairingProof(attemptID: challenge.attemptID, proof: Data(proof))
    }

    public func accept(_ result: PasswordPairingResult) throws -> PairingInfo {
        guard let secret, let proof, result.proof.count == 32 else { throw PasswordPairingError.refused }
        defer { self.secret = nil; self.proof = nil }
        try client.verifyServerProof(serverProof: Array(result.proof), clientProof: proof, clientPublicKey: keys.public, sharedSecret: secret)
        let pairing = try RPCSealing.open(PairingInfo.self, from: result.sealedPairing,
                                         secret: Data(SHA256.hash(data: secret.bytes)), .hostToClient)
        guard pairing.secret.count == 32 else { throw PasswordPairingError.refused }
        return pairing
    }

    public static func pair(host: String, port: UInt16, password: String) async throws -> PairingInfo {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains("@"), port > 0 else { throw PasswordPairingError.invalidHost }
        let client = PasswordPairingClient()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func post<T: Encodable, R: Decodable>(_ path: String, _ value: T, as: R.Type) async throws -> R {
            var parts = URLComponents()
            parts.scheme = "http"; parts.host = host; parts.port = Int(port); parts.path = path
            guard let url = parts.url else { throw PasswordPairingError.invalidHost }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(value)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw PasswordPairingError.refused }
            guard response.statusCode != 429 else { throw PasswordPairingError.rateLimited }
            guard response.statusCode == 200, data.count < 16_384 else { throw PasswordPairingError.refused }
            return try JSONDecoder().decode(R.self, from: data)
        }
        let challenge = try await post("/pair/start", client.start, as: PasswordPairingChallenge.self)
        let proof = try client.answer(challenge, password: password)
        let result = try await post("/pair/finish", proof, as: PasswordPairingResult.self)
        let pairing = try client.accept(result)
        return PairingInfo(hostName: pairing.hostName, address: host, alternates: pairing.addresses,
                           port: pairing.port, httpPort: pairing.httpPort, secret: pairing.secret)
    }
}
#endif
