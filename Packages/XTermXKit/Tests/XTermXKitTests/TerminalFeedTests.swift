#if os(macOS)
import AppKit
import SwiftTerm
import Testing
@testable import XTermXHost
@testable import XTermXTerminalUI

@MainActor
@Suite struct TerminalFeedTests {
    @Test func replacementViewReplaysAnIdleAlternateScreenAtTheSameSize() {
        let host = Terminal(delegate: ScreenSnapshotTests.Quiet(), options: TerminalOptions(cols: 80, rows: 24))
        host.feed(text: "\u{1b}[?1049h\u{1b}[Hxtmux chooser\u{1b}[24;1Hsession status")
        let feed = TerminalFeed()
        var replays = 0
        feed.onViewAttached = {
            replays += 1
            feed.receive(ScreenSnapshot.ansi(host))
        }
        let original = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), font: nil)
        feed.bind(original)
        #expect(String(decoding: original.getBufferAsData(), as: UTF8.self).contains("xtmux chooser"))

        // Moving the pane may replace its NSView without any new PTY bytes or resize.
        let replacement = TerminalView(frame: original.frame, font: nil)
        feed.bind(replacement)
        let contents = String(decoding: replacement.getBufferAsData(), as: UTF8.self)
        #expect(contents.contains("xtmux chooser"))
        #expect(contents.contains("session status"))
        #expect(replays == 2)
        feed.bind(replacement)
        #expect(replays == 2) // ordinary updates preserve scrollback and selection
        feed.onViewAttached = nil
    }

    @Test func replacementReplaySupersedesOutputQueuedWhileNoViewExists() {
        let feed = TerminalFeed()
        feed.receive(Data("old screen".utf8))
        feed.onViewAttached = { feed.receive(Data("\u{1b}[H\u{1b}[2Jcurrent screen".utf8)) }
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), font: nil)
        feed.bind(view)
        let contents = String(decoding: view.getBufferAsData(), as: UTF8.self)
        #expect(contents.contains("current screen"))
        #expect(!contents.contains("old screen"))
        feed.onViewAttached = nil
    }
}
#endif
