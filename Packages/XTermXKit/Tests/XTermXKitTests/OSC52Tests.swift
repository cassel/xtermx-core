import Foundation
import Testing
@testable import XTermXKit

@Suite struct OSC52Tests {
    @Test func decodesClipboardPayloads() {
        let b64 = Data("hello\nworld".utf8).base64EncodedString()
        #expect(ProgramClipboard.decode(osc: "c;\(b64)") == "hello\nworld")
        #expect(ProgramClipboard.decode(osc: ";\(b64)") == "hello\nworld")
        #expect(ProgramClipboard.decode(osc: "pc;\(b64)") == "hello\nworld")
        #expect(ProgramClipboard.decode(osc: "52;c;\(b64)") == "hello\nworld")
    }

    @Test func refusesQueriesBinaryAndHugePayloads() {
        #expect(ProgramClipboard.decode(osc: "c;?") == nil)
        #expect(ProgramClipboard.decode(osc: "c;!!notbase64") == nil)
        #expect(ProgramClipboard.decode(osc: "c;") == nil)
        #expect(ProgramClipboard.decode(osc: "c;" + Data([0xff, 0xfe, 0x00]).base64EncodedString()) == nil)
        #expect(ProgramClipboard.text(Data("a\u{0}b".utf8)) == nil)
        #expect(ProgramClipboard.text(Data(repeating: 0x61, count: 256 * 1024 + 1)) == nil)
        #expect(ProgramClipboard.text(Data("ok\t".utf8)) == "ok\t")
    }

    @Test func offUnlessThePersonAllowsIt() {
        let d = UserDefaults(suiteName: "OSC52Tests-\(UUID().uuidString)")!
        #expect(!ProgramClipboard.isAllowed(d))
        d.set(true, forKey: ProgramClipboard.defaultsKey)
        #expect(ProgramClipboard.isAllowed(d))
    }
}
