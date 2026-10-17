import Foundation
import Testing
@testable import XTermXKit

/// What a terminal answers by itself never counts as typing (it would take a shared pane's size).
@Suite struct TerminalRepliesTests {
    static func bytes(_ s: String) -> Data { Data(s.replacingOccurrences(of: "^", with: "\u{1b}").utf8) }

    @Test func answersAndReportsAreAutomatic() {
        for reply in [
            "^[24;80R",                    // cursor position
            "^[?62;22c", "^[>1;10;0c",     // device attributes
            "^[?2004;2$y",                 // mode report
            "^[?0u",                       // keyboard protocol flags
            "^[8;31;131t",                 // size report
            "^[0n",                        // status
            "^]11;rgb:1c1c/1e1e/2424^\\",  // background color, ESC \ ends it
            "^]10;rgb:ffff/ffff/ffff\u{07}", // foreground color, BEL ends it
            "^P1+r544e=787465726d^\\",     // capability
            "^[I", "^[O",                  // focus
            "^[<35;10;5M", "^[<0;3;4m",    // SGR mouse
            "^[M #!",                      // X10 mouse
            "^[24;80R^[?62;22c",           // several at once
        ] {
            #expect(TerminalReplies.isAutomatic(Self.bytes(reply)), "\(reply)")
        }
    }

    @Test func keysAreTyped() {
        for key in ["a", "ls\r", "\u{03}", "^", "^[A", "^[1;5C", "^OA", "^[3~", "^[1;2R", "^b", "^[200~text^[201~", "^[24;80Rx"] {
            #expect(!TerminalReplies.isAutomatic(Self.bytes(key)), "\(key)")
        }
    }
}
