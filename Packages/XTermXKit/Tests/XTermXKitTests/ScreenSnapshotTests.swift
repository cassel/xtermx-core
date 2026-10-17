#if os(macOS)
import Foundation
import SwiftTerm
import Testing
@testable import XTermXHost

/// A subscriber gets the pane redrawn at its current size, not raw output written for another width.
@Suite struct ScreenSnapshotTests {
    final class Quiet: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// What each row shows: empty cells and spaces look the same.
    static func text(_ t: Terminal) -> [String] {
        (0..<t.rows).map { row in
            var line = (t.getLine(row: row)?.translateToString() ?? "").replacingOccurrences(of: "\0", with: " ")
            while line.last == " " { line.removeLast() }
            return line
        }
    }

    @Test func redrawsAfterTheHostNarrowsToAPhone() {
        let delegate = Quiet()
        let host = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 10, scrollback: 500))
        host.feed(text: "$ ls\r\n")
        host.feed(text: "\u{1b}[1;32m" + String(repeating: "green words ", count: 12) + "\u{1b}[0m\r\n")
        host.feed(text: "wide: 日本語 ok\r\n")
        host.feed(text: "\u{1b}[44m status bar \u{1b}[0m\r\n")
        host.feed(text: "> ")
        host.resize(cols: 30, rows: 10) // the phone's size, before it subscribes

        let phone = Terminal(delegate: delegate, options: TerminalOptions(cols: 30, rows: 10, scrollback: 500))
        phone.feed(byteArray: Array(ScreenSnapshot.ansi(host)))

        let phoneRows = Self.text(phone), hostRows = Self.text(host)
        #expect(phoneRows == hostRows)
        #expect(phone.getCursorLocation().x == host.getCursorLocation().x)
        #expect(phone.getCursorLocation().y == host.getCursorLocation().y)
        // Colors survive: the green run and the blue bar.
        let green = phone.getCharData(col: 0, row: 1)?.attribute
        #expect(green?.fg == .ansi256(code: 2))
        #expect(green?.style.contains(.bold) == true)
        let bar = (0..<phone.rows).compactMap { r in phone.getLine(row: r).flatMap { $0.translateToString().contains("status bar") ? r : nil } }.first
        #expect(bar.flatMap { phone.getCharData(col: 0, row: $0)?.attribute.bg } == .ansi256(code: 4))
    }

    @Test func macReplayAfterPhoneUseRestoresFullWidthAndClearsNarrowStatusBar() {
        let delegate = Quiet()
        let host = Terminal(delegate: delegate, options: TerminalOptions(cols: 120, rows: 30, scrollback: 100))
        let mac = Terminal(delegate: delegate, options: TerminalOptions(cols: 120, rows: 30, scrollback: 100))
        host.feed(text: "\u{1b}[?1049h\u{1b}[Hinitial tmux pane")
        host.resize(cols: 45, rows: 12)
        let narrow = "\u{1b}[H\u{1b}[2Jphone session\u{1b}[12;1H\u{1b}[42m" + String(repeating: "x", count: 45) + "\u{1b}[0m"
        host.feed(text: narrow)
        mac.feed(text: narrow)
        // The PTY returns home before its next output; emulate the TUI's SIGWINCH redraw.
        host.resize(cols: 120, rows: 30)
        mac.feed(byteArray: Array(ScreenSnapshot.ansi(host)))
        #expect(Self.text(mac) == Self.text(host))
        host.feed(text: "\u{1b}[H\u{1b}[2Jback on Mac\u{1b}[30;1H\u{1b}[42m" + String(repeating: "-", count: 119) + "\u{1b}[0m\u{1b}[28;1H> ")
        mac.feed(byteArray: Array(ScreenSnapshot.ansi(host)))
        #expect(Self.text(mac) == Self.text(host))
        #expect(mac.getCursorLocation().x == host.getCursorLocation().x)
        #expect(mac.getCursorLocation().y == host.getCursorLocation().y)
        #expect(mac.getCharData(col: 118, row: 29)?.attribute.bg == .ansi256(code: 2))
        #expect(!Self.text(mac)[11].contains("xxxxx"))
    }

    @Test func recordedKeyboardHeightCycleDoesNotDuplicateNormalBufferOrMoveThePrompt() {
        let delegate = Quiet()
        let host = Terminal(delegate: delegate, options: TerminalOptions(cols: 49, rows: 45, scrollback: 1000))
        let phone = Terminal(delegate: delegate, options: TerminalOptions(cols: 49, rows: 45, scrollback: 1000))
        for row in 0..<90 { host.feed(text: "history \(row) " + String(repeating: "word ", count: 14) + "\r\n") }
        phone.feed(byteArray: Array(ScreenSnapshot.ansi(host)))
        // Same 49×25 / 49×45 keyboard cycle and normal-buffer TUI as the recording.
        for (cycle, rows) in [25, 45, 25, 45, 25, 45].enumerated() {
            host.resize(cols: 49, rows: rows)
            phone.resize(cols: 49, rows: rows)
            host.feed(text: "\u{1b}[H\u{1b}[2J")
            for row in 0..<min(32, rows - 4) { host.feed(text: "cycle \(cycle), message \(row)\r\n") }
            host.feed(text: "\u{1b}[\(rows);1H\u{1b}[42m" + String(repeating: "-", count: 48) + "\u{1b}[0m\u{1b}[\(rows - 2);3H> prompt")
            phone.feed(byteArray: Array(ScreenSnapshot.ansi(host)))
            #expect(!phone.isCurrentBufferAlternate)
            #expect(Self.text(phone) == Self.text(host))
            #expect(phone.getTopVisibleRow() == host.getTopVisibleRow())
            #expect(phone.getCursorLocation().x == host.getCursorLocation().x)
            #expect(phone.getCursorLocation().y == host.getCursorLocation().y)
            #expect(phone.getCharData(col: 47, row: rows - 1)?.attribute.bg == .ansi256(code: 2))
        }
    }

    @Test func keepsTheAlternateScreen() {
        let delegate = Quiet()
        let host = Terminal(delegate: delegate, options: TerminalOptions(cols: 40, rows: 6, scrollback: 100))
        host.feed(text: "shell history\r\n\u{1b}[?1049h\u{1b}[Hfull-screen app\u{1b}[3;5Hhere")
        let phone = Terminal(delegate: delegate, options: TerminalOptions(cols: 40, rows: 6, scrollback: 100))
        phone.feed(byteArray: Array(ScreenSnapshot.ansi(host)))
        #expect(phone.isCurrentBufferAlternate)
        #expect(Self.text(phone) == Self.text(host))
        #expect(phone.getCursorLocation().x == 8 && phone.getCursorLocation().y == 2)
    }

    @Test func reconnectAfterKeyboardResizeClearsStaleModesAndKeepsPromptRow() {
        let delegate = Quiet()
        let host = Terminal(delegate: delegate, options: TerminalOptions(cols: 40, rows: 12, scrollback: 100))
        host.feed(text: "output\r\n> current prompt")
        host.resize(cols: 40, rows: 6)
        let phone = Terminal(delegate: delegate, options: TerminalOptions(cols: 40, rows: 12, scrollback: 100))
        phone.feed(text: "\u{1b}[?1049h\u{1b}[3;8r\u{1b}[?6h\u{1b}[?1h\u{1b}[?2004hprevious app")
        phone.resize(cols: 40, rows: 6)
        phone.feed(byteArray: Array(ScreenSnapshot.ansi(host)))
        #expect(!phone.isCurrentBufferAlternate)
        #expect(!phone.applicationCursor && !phone.bracketedPasteMode)
        #expect(Self.text(phone) == Self.text(host))
        #expect(phone.getCursorLocation().x == host.getCursorLocation().x)
        #expect(phone.getCursorLocation().y == host.getCursorLocation().y)
    }
}
#endif
