#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost

@MainActor @Suite struct PasswordPairingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func pairing() -> PairingInfo { PairingInfo(hostName: "Test", address: "127.0.0.1", secret: SecureRandom.bytes(32)) }

    @Test func passwordsLifetimesAndStoredVerifier() throws {
        #expect(throws: PasswordPairingError.self) { try PasswordPairingGate.makeRecord(password: "short", lifetime: .hour) }
        #expect(throws: PasswordPairingError.self) { try PasswordPairingGate.makeRecord(password: String(repeating: "a", count: 129), lifetime: .hour) }
        for (lifetime, seconds) in [(PairingPasswordLifetime.hour, 3600.0), (.workday, 28_800), (.day, 86_400)] {
            let record = try PasswordPairingGate.makeRecord(password: "secret-password", lifetime: lifetime, now: now)
            #expect(record.expiresAt == now.addingTimeInterval(seconds))
            #expect(record.isActive(at: now))
            #expect(!record.isActive(at: now.addingTimeInterval(seconds)))
            #expect(!String(decoding: try JSONEncoder().encode(record), as: UTF8.self).contains("secret-password"))
        }
        #expect(try PasswordPairingGate.makeRecord(password: "secret", lifetime: .unlimited).expiresAt == nil)
        let passwords = (0..<10).map { _ in PasswordPairingGate.generatePassword() }
        #expect(Set(passwords).count == 10)
        #expect(passwords.allSatisfy { $0.count == 24 })
    }

    @Test func mutuallyVerifiedExchangeEncryptsPairingAndRejectsReplay() throws {
        let gate = PasswordPairingGate(record: try PasswordPairingGate.makeRecord(password: "secret", lifetime: .hour, now: now))
        let client = PasswordPairingClient()
        let challenge = try gate.begin(client.start, now: now)
        let proof = try client.answer(challenge, password: "secret")
        let expected = pairing()
        let result = try gate.finish(proof, pairing: expected, now: now)
        #expect(try client.accept(result) == expected)
        #expect(!result.sealedPairing.contains(expected.secret))
        #expect(throws: (any Error).self) { try gate.finish(proof, pairing: expected, now: now) }
        #expect(throws: (any Error).self) { try client.accept(result) }
    }

    @Test func wrongPasswordsTamperedProofsExpiryAndRotationFail() throws {
        let record = try PasswordPairingGate.makeRecord(password: "secret", lifetime: .hour, now: now)
        let gate = PasswordPairingGate(record: record)
        let wrong = PasswordPairingClient()
        let wrongProof = try wrong.answer(gate.begin(wrong.start, now: now), password: "wrong-password")
        #expect(throws: (any Error).self) { try gate.finish(wrongProof, pairing: pairing(), now: now) }
        let client = PasswordPairingClient()
        let challenge = try gate.begin(client.start, now: now)
        let proof = try client.answer(challenge, password: "secret")
        #expect(throws: (any Error).self) { try gate.finish(proof, pairing: pairing(), now: now.addingTimeInterval(61)) }
        #expect(throws: (any Error).self) { try gate.begin(PasswordPairingClient().start, now: now.addingTimeInterval(3600)) }
        let beforeExpiry = now.addingTimeInterval(3590)
        let pending = PasswordPairingClient()
        let expiring = try pending.answer(gate.begin(pending.start, now: beforeExpiry), password: "secret")
        #expect(throws: (any Error).self) { try gate.finish(expiring, pairing: pairing(), now: now.addingTimeInterval(3600)) }
        let rotated = PasswordPairingClient()
        let old = try rotated.answer(gate.begin(rotated.start, now: now), password: "secret")
        gate.record = try PasswordPairingGate.makeRecord(password: "new-password", lifetime: .hour, now: now)
        #expect(throws: (any Error).self) { try gate.finish(old, pairing: pairing(), now: now) }
        #expect(throws: (any Error).self) { try gate.begin(PasswordPairingStart(publicKey: Data(repeating: 0, count: 256)), now: now) }

        let valid = PasswordPairingClient()
        let reply = try gate.finish(valid.answer(gate.begin(valid.start, now: now), password: "new-password"), pairing: pairing(), now: now)
        var tampered = reply
        tampered.proof[0] ^= 1
        #expect(throws: (any Error).self) { try valid.accept(tampered) }
    }

    @Test func startsAreBoundedAndRearmAfterAMinute() throws {
        let gate = PasswordPairingGate(record: try PasswordPairingGate.makeRecord(password: "secret", lifetime: .hour, now: now))
        for _ in 0..<8 { _ = try gate.begin(PasswordPairingClient().start, now: now) }
        #expect(throws: PasswordPairingError.self) { try gate.begin(PasswordPairingClient().start, now: now) }
        _ = try gate.begin(PasswordPairingClient().start, now: now.addingTimeInterval(61))
        gate.record = nil
        #expect(throws: PasswordPairingError.self) { try gate.begin(PasswordPairingClient().start, now: now) }
    }

    @Test func pairsOverRealHTTPWithoutQRCode() async throws {
        let manager = PaneManager(detectAgents: false)
        let server = RemoteServer(manager: manager, port: 0, httpPort: 0, secretStore: MemorySecretStore(), bindHost: "127.0.0.1")
        server.passwordPairing.record = try PasswordPairingGate.makeRecord(password: "pairing-password", lifetime: .hour)
        server.start()
        defer { server.stop() }
        let port = server.httpPort
        let received = try await PasswordPairingClient.pair(host: "127.0.0.1", port: port, password: "pairing-password")
        #expect(received.secret == server.pairing(address: "127.0.0.1").secret)
        #expect(received.address == "127.0.0.1")
        let connection = HostConnection(pairing: received, deviceName: "password test", platform: .macOS)
        connection.connect()
        defer { connection.disconnect() }
        #expect(await connection.waitUntilReady())
        do {
            _ = try await PasswordPairingClient.pair(host: "127.0.0.1", port: port, password: "wrong-password")
            Issue.record("Incorrect password was accepted")
        } catch { }
        server.passwordPairing.record = nil
        do {
            _ = try await PasswordPairingClient.pair(host: "127.0.0.1", port: port, password: "pairing-password")
            Issue.record("Disabled password was accepted")
        } catch { }
    }
}
#endif
