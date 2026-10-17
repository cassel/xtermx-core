#if os(macOS)
import AppKit
import SwiftTerm
import Testing
@testable import XTermXHost
@testable import XTermXTerminalUI

@MainActor
@Suite struct TerminalFeedTests {
    @Test func cursorModeTracksSplitSequencesAndBothKindsOfReset() {
        let feed = TerminalFeed()
        for byte in Array("\u{1b}[?1;2004h".utf8) { feed.receive(Data([byte])) }
        #expect(feed.applicationCursor)
        feed.receive(Data([27])); feed.receive(Data([99]))
        #expect(!feed.applicationCursor)
        feed.receive(Data("\u{1b}[?1h".utf8)); #expect(feed.applicationCursor)
        feed.reset(); #expect(!feed.applicationCursor)
    }

    @Test func visibleTextCopiesTheViewportWithoutChangingLiveSelectionOrSendingInput() {
        let feed = TerminalFeed()
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500), font: nil)
        feed.bind(view)
        feed.receive(Data(("old scrollback marker\r\n" + String(repeating: "\r\n", count: 100) + "current screen").utf8))
        view.selectAll(view)
        let selection = view.getSelection()
        let text = feed.visibleText()
        #expect(text.contains("current screen"))
        #expect(!text.contains("old scrollback marker"))
        #expect(view.getSelection() == selection)
        feed.receive(Data("\r\nnew output".utf8))
        #expect(!text.contains("new output")) // snapshot is frozen, while the terminal continues
        #expect(feed.visibleText().contains("new output"))
    }

    @Test func visibleTextRejoinsWrappedLinksAndUsesTheActiveAlternateScreen() {
        let feed = TerminalFeed()
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 180, height: 500), font: nil)
        feed.bind(view)
        feed.receive(Data("shell text\u{1b}[?1049h\u{1b}[H".utf8))
        let link = "https://example.com/" + String(repeating: "segment/", count: 6)
        feed.receive(Data(link.utf8))
        #expect(view.terminalStateSnapshot().visibleRows.contains { $0.isWrapped })
        let text = feed.visibleText()
        #expect(text.contains(link))
        #expect(!text.contains("shell text"))
        #expect(TerminalFeed().visibleText().isEmpty)
    }

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
