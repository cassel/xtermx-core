import Foundation
import Testing
@testable import XTermXKit

@Suite struct PairingTests {
    @Test func urlRoundTrip() throws {
        let info = PairingInfo(hostName: "Studio", address: "studio.local", port: 1234, httpPort: 1235, secret: SecureRandom.bytes(32))
        let parsed = try #require(PairingInfo(url: info.url))
        #expect(parsed == info)
    }

    @Test func rejectsShortSecret() {
        let url = URL(string: "xtermx://pair?n=x&h=y&k=\(SecureRandom.bytes(8).base64URLEncoded)")!
        #expect(PairingInfo(url: url) == nil)
    }
}

@Suite struct SealerTests {
    let secret = SecureRandom.bytes(32)

    @Test func sealOpen() throws {
        var a = FrameSealer(key: KeySchedule.baseKey(secret: secret, .clientToHost))
        var b = FrameSealer(key: KeySchedule.baseKey(secret: secret, .clientToHost))
        let frame = try a.seal(Data("hello".utf8))
        #expect(try b.open(frame) == Data("hello".utf8))
    }

    @Test func rejectsReplay() throws {
        var a = FrameSealer(key: KeySchedule.baseKey(secret: secret, .clientToHost))
        var b = FrameSealer(key: KeySchedule.baseKey(secret: secret, .clientToHost))
        let frame = try a.seal(Data("x".utf8))
        _ = try b.open(frame)
        #expect(throws: ChannelError.replayed) { try b.open(frame) }
    }

    @Test func rejectsWrongDirection() throws {
        var a = FrameSealer(key: KeySchedule.baseKey(secret: secret, .clientToHost))
        var b = FrameSealer(key: KeySchedule.baseKey(secret: secret, .hostToClient))
        let frame = try a.seal(Data("x".utf8))
        #expect(throws: ChannelError.authenticationFailed) { try b.open(frame) }
    }

    @Test func rejectsWrongSecret() throws {
        var a = FrameSealer(key: KeySchedule.baseKey(secret: secret, .clientToHost))
        var b = FrameSealer(key: KeySchedule.baseKey(secret: SecureRandom.bytes(32), .clientToHost))
        #expect(throws: ChannelError.authenticationFailed) { try b.open(a.seal(Data("x".utf8))) }
    }

    @Test func sessionKeysDependOnNonces() throws {
        let n1 = SecureRandom.bytes(32), n2 = SecureRandom.bytes(32), n3 = SecureRandom.bytes(32)
        var a = FrameSealer(key: KeySchedule.sessionKey(secret: secret, clientNonce: n1, hostNonce: n2, .clientToHost))
        var b = FrameSealer(key: KeySchedule.sessionKey(secret: secret, clientNonce: n1, hostNonce: n3, .clientToHost))
        #expect(throws: ChannelError.authenticationFailed) { try b.open(a.seal(Data("x".utf8))) }
    }
}

@Suite struct MessageTests {
    @Test func clientMessagesRoundTrip() throws {
        let messages: [ClientMessage] = [
            .snapshot, .subscribe(paneID: "p"), .input(paneID: "p", data: Data([0x1b, 0x5b])),
            .resize(paneID: "p", cols: 80, rows: 24), .send(paneID: "p", text: "ls"),
            .spawn(SpawnRequest(kind: .agent, agentID: "claude", cwd: "/tmp")),
            .answer(requestID: "r", allow: true), .screen(paneID: "p", lines: 10),
        ]
        let encoder = WireCoding.encoder()
        encoder.outputFormatting = .sortedKeys
        for m in messages {
            let data = try encoder.encode(m)
            let back = try WireCoding.decoder().decode(ClientMessage.self, from: data)
            #expect(try encoder.encode(back) == data)
        }
    }

    @Test func rpcSealing() throws {
        let secret = SecureRandom.bytes(32)
        let req = RPCRequest(message: .snapshot)
        let sealed = try RPCSealing.seal(req, secret: secret, .clientToHost)
        let opened = try RPCSealing.open(RPCRequest.self, from: sealed, secret: secret, .clientToHost)
        #expect(opened.id == req.id)
        #expect(throws: (any Error).self) { try RPCSealing.open(RPCRequest.self, from: sealed, secret: secret, .hostToClient) }
    }
}

@Suite struct ThemeTests {
    @Test func minimumContrastMatchesOriginal() {
        // Classic black (#14191E) must show as #6C849D at the default 4.5 contrast.
        let adjusted = AppTheme.preset("classic").terminal.adjusted(minimumContrast: 4.5)
        let black = adjusted.ansi[0]
        #expect(abs(Int(black.r) - 0x6C) <= 2 && abs(Int(black.g) - 0x84) <= 2 && abs(Int(black.b) - 0x9D) <= 2)
        #expect(adjusted.ansi[15] == RGB(0xFFFFFF))
    }
}
