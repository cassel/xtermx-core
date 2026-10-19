import Testing
@testable import XTermXKit
#if os(macOS)
import SwiftTerm
#endif

@Suite struct WrappedLinksTests {
    let url = "https://github.com/cassel/xtermx-core/releases/tag/dev-2026.10.19-0910"

    @Test func rejoinsAnIndentedBreakFromAFullRow() {
        let text = "⏺ Link: " + url.prefix(32) + "\n  " + url.dropFirst(32) + "\n  Next line."
        #expect(WrappedLinks.join(text, columns: 40) == "⏺ Link: " + url + "\n  Next line.")
    }

    @Test func rejoinsAcrossThreeRows() {
        let text = url.prefix(30) + "\n" + url.dropFirst(30).prefix(30) + "\n" + url.dropFirst(60)
        #expect(WrappedLinks.join(String(text), columns: 30) == url)
    }

    @Test func aSelectionStartingAtTheLinkJoinsAPathPiece() {
        let text = url.prefix(20) + "\n  " + url.dropFirst(20)
        #expect(WrappedLinks.join(String(text), columns: 80) == url)
    }

    @Test func keepsOrdinaryBreaks() {
        let short = "See " + url + "\n  and then continue"
        #expect(WrappedLinks.join(short, columns: 200) == short)
        let edge = "https://example.com/abcdefghijklmnopqrstu\nNext sentence here."
        #expect(WrappedLinks.join(edge, columns: 41) == edge)
        let spaced = "https://example.com/abc \n/tmp/file"
        #expect(WrappedLinks.join(spaced, columns: 24) == spaced)
        let plain = String(repeating: "x", count: 40) + "\n/tmp/file"
        #expect(WrappedLinks.join(plain, columns: 40) == plain)
    }

    #if os(macOS)
    final class Sink: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }

    /// What Claude Code sends once FORCE_HYPERLINK is set: each row re-opens the same OSC 8 link.
    @Test func anOSC8LinkBrokenAcrossRowsOpensWhole() {
        let terminal = Terminal(delegate: Sink(), options: TerminalOptions(cols: 40, rows: 6))
        let open = "\u{1b}]8;;\(url)\u{1b}\\", close = "\u{1b}]8;;\u{1b}\\"
        terminal.feed(text: "⏺ " + open + url.prefix(30) + close + "\r\n  " + open + url.dropFirst(30) + close + "\r\n")
        #expect(terminal.link(at: .buffer(Position(col: 5, row: 0)), mode: .explicitAndImplicit) == url)
        #expect(terminal.link(at: .buffer(Position(col: 5, row: 1)), mode: .explicitAndImplicit) == url)
    }
    #endif
}
