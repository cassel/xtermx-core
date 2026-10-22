import Foundation
import Testing
@testable import XTermXKit

/// Wake-on-LAN: MAC parsing, the magic packet, broadcast math and the optional pairing fields.
@Suite struct WakeOnLANTests {
    @Test func parsesColonAndDashMACs() {
        #expect(WakeOnLAN.parseMAC("a4:83:E7:01:02:0f") == [0xA4, 0x83, 0xE7, 0x01, 0x02, 0x0F])
        #expect(WakeOnLAN.parseMAC("A4-83-E7-01-02-0F") == [0xA4, 0x83, 0xE7, 0x01, 0x02, 0x0F])
    }

    @Test(arguments: ["", "a4:83:e7:01:02", "a4:83:e7:01:02:0g", "a4:83:e7:01:02:03:04", "a483e701020f0", "00:00:00:00:00:00"])
    func rejectsMalformedMACs(_ bad: String) {
        #expect(WakeOnLAN.parseMAC(bad) == nil)
    }

    @Test func magicPacketIsSyncThenSixteenCopies() throws {
        let packet = try #require(WakeOnLAN.magicPacket(mac: "01:23:45:67:89:ab"))
        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == [UInt8](repeating: 0xFF, count: 6))
        for i in 0..<16 {
            #expect(Array(packet[(6 + i * 6)..<(12 + i * 6)]) == [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB])
        }
        #expect(WakeOnLAN.magicPacket(mac: "junk") == nil)
    }

    @Test func broadcastForSubnet() {
        #expect(WakeOnLAN.broadcast(address: "192.168.1.20", netmask: "255.255.255.0") == "192.168.1.255")
        #expect(WakeOnLAN.broadcast(address: "10.0.5.9", netmask: "255.255.0.0") == "10.0.255.255")
        #expect(WakeOnLAN.broadcast(address: "nope", netmask: "255.255.255.0") == nil)
    }

    @Test func legacyPairingDecodesWithoutWake() throws {
        let secret = Data(repeating: 1, count: 32).base64EncodedString()
        let legacy = #"{"hostName":"Mac","address":"10.0.0.2","port":7681,"httpPort":7682,"secret":"\#(secret)"}"#
        let p = try JSONDecoder().decode(PairingInfo.self, from: Data(legacy.utf8))
        #expect(p.wakeMAC == nil)
        #expect(p.wakeBroadcast == nil)
        #expect(!p.canWake)
        let fromURL = try #require(PairingInfo(url: PairingInfo(hostName: "Mac", address: "x", secret: Data(repeating: 1, count: 32)).url))
        #expect(!fromURL.canWake)
    }

    @Test func wakeFieldsRoundTripThroughJSONAndURL() throws {
        var p = PairingInfo(hostName: "Mac", address: "10.0.0.2", secret: Data(repeating: 2, count: 32))
        p.wakeMAC = "a4:83:e7:01:02:0f"
        p.wakeBroadcast = "10.0.0.255"
        let json = try JSONDecoder().decode(PairingInfo.self, from: JSONEncoder().encode(p))
        #expect(json.wakeMAC == p.wakeMAC)
        #expect(json.wakeBroadcast == p.wakeBroadcast)
        #expect(json.canWake)
        let url = try #require(PairingInfo(url: p.url))
        #expect(url.wakeMAC == p.wakeMAC)
        #expect(url.wakeBroadcast == p.wakeBroadcast)
    }
}
