#if os(macOS)
import AppKit
import SwiftTerm
import Testing
@testable import XTermXTerminalUI

@MainActor
@Suite struct TerminalPointerTests {
    private final class Delegate: NSObject, TerminalViewDelegate {
        var links: [String] = []
        var input: [UInt8] = []
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) { input.append(contentsOf: data) }
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { links.append(link) }
        func bell(source: TerminalView) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat = 4, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 495), modifierFlags: flags,
                          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                          clickCount: clicks, pressure: 0)!
    }

    private func drainEvents() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func wheel(_ delta: Int32) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                            wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        event.location = CGPoint(x: 30, y: 30)
        return NSEvent(cgEvent: event)!
    }

    @Test func wheelUsesMouseProtocolWithoutEnablingClickCapture() async {
        let view = SelectionCopyTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let delegate = Delegate(); view.terminalDelegate = delegate
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h")
        view.handleScrollWheel(wheel(1))
        view.handleScrollWheel(wheel(-1))
        await drainEvents()
        let bytes = String(decoding: delegate.input, as: UTF8.self)
        #expect(bytes.contains("\u{1b}[<64;"))
        #expect(bytes.contains("\u{1b}[<65;"))
        #expect(!bytes.contains("\u{1b}[A") && !bytes.contains("\u{1b}[B"))
        #expect(!view.allowMouseReporting)
    }

    @Test func wheelNeverBecomesArrowKeysWhenMouseTrackingIsOff() async {
        let view = SelectionCopyTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let delegate = Delegate(); view.terminalDelegate = delegate
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1h")
        view.handleScrollWheel(wheel(1)); view.handleScrollWheel(wheel(-1))
        await drainEvents()
        #expect(delegate.input.isEmpty)
        view.feed(text: "\u{1b}[?1049l" + String(repeating: "history\r\n", count: 100))
        let before = view.terminalStateSnapshot().viewportRow
        view.handleScrollWheel(wheel(3))
        #expect(view.terminalStateSnapshot().viewportRow < before)
        await drainEvents()
        #expect(delegate.input.isEmpty)
    }

    @Test func draggingSelectsTextEvenWhenTheProgramCapturesTheMouse() async {
        let view = SelectionCopyTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.feed(text: "select this text\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h")
        delegate.input = []
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseDragged(with: event(.leftMouseDragged, x: 100))
        view.mouseUp(with: event(.leftMouseUp, x: 100))
        #expect(view.selectionActive)
        #expect(view.getSelection()?.hasPrefix("select") == true)
        await drainEvents()
        #expect(delegate.input.isEmpty)
    }

    @Test func optionClickStillReachesMouseAwareProgramsAndNextDragSelects() async {
        let view = SelectionCopyTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.feed(text: "select again\u{1b}[?1000h\u{1b}[?1006h")
        delegate.input = []
        view.mouseDown(with: event(.leftMouseDown, flags: .option))
        view.mouseUp(with: event(.leftMouseUp, flags: .option))
        await drainEvents()
        #expect(String(decoding: delegate.input, as: UTF8.self).contains("\u{1b}[<"))
        #expect(!view.allowMouseReporting)
        delegate.input = []
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp, x: 90))
        #expect(view.getSelection()?.hasPrefix("select") == true)
        await drainEvents()
        #expect(delegate.input.isEmpty)
    }

    @Test func controlClickOpensDetectedWebLinksButPlainClickAndDraggingDoNot() {
        let view = SelectionCopyTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.feed(text: "https://example.com/path?q=1")
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))
        #expect(delegate.links.isEmpty)
        view.mouseDown(with: event(.leftMouseDown, flags: .control))
        view.mouseUp(with: event(.leftMouseUp, flags: .control))
        #expect(delegate.links == ["https://example.com/path?q=1"])
        view.mouseDown(with: event(.leftMouseDown, flags: .control))
        view.mouseDragged(with: event(.leftMouseDragged, x: 90, flags: .control))
        view.mouseUp(with: event(.leftMouseUp, x: 90, flags: .control))
        #expect(delegate.links.count == 1)
    }

    @Test func commandHoverOverALinkShowsThePointingHand() {
        let view = SelectionCopyTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        view.feed(text: "https://example.com/path?q=1")
        #expect(view.linkHighlighted == false)
        func modifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
        }
        view.flagsChanged(with: modifiers(.command))
        view.mouseMoved(with: event(.mouseMoved, flags: .command))
        #expect(view.linkHighlighted == true)
        view.updateLinkCursor(inside: true, held: true)
        #expect(view.showsLinkCursor)
        view.flagsChanged(with: modifiers([]))
        view.updateLinkCursor(inside: true, held: false)
        #expect(!view.showsLinkCursor)
    }

    @Test func browserLinksRejectLocalFilesAndExecutableSchemes() {
        #expect(SelectionCopyTerminalView.browserURL("https://example.com/path")?.host == "example.com")
        #expect(SelectionCopyTerminalView.browserURL("http://localhost:3000")?.port == 3000)
        for link in ["file:///etc/passwd", "javascript:alert(1)", "xtermx://pair", "/tmp/test", "https:missing-host"] {
            #expect(SelectionCopyTerminalView.browserURL(link) == nil)
        }
    }

    @Test func localFilesAndFoldersUseFileURLsWithoutLosingFilenameCharacters() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["wireframes.pdf", "relatório #1 100%.txt", "image.png", "source.swift"] {
            let file = folder.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: file)
            for link in [file.path, file.absoluteString] {
                let url = SelectionCopyTerminalView.fileOrBrowserURL(link)
                #expect(url?.isFileURL == true)
                #expect(url?.path == file.path)
            }
        }
        #expect(SelectionCopyTerminalView.fileOrBrowserURL(folder.path)?.path == folder.path)
        #expect(SelectionCopyTerminalView.fileOrBrowserURL(folder.absoluteString)?.isFileURL == true)
        #expect(SelectionCopyTerminalView.fileOrBrowserURL("~/")?.path == NSHomeDirectory())
    }

    @Test func fileOpeningRejectsMissingPathsRemoteFileHostsAndCustomSchemes() {
        for link in ["/nonexistent-" + UUID().uuidString, "file://remote.example/etc/passwd",
                     "relative.pdf", "javascript:alert(1)", "xtermx://pair", "https:missing-host"] {
            #expect(SelectionCopyTerminalView.fileOrBrowserURL(link) == nil)
        }
        #expect(SelectionCopyTerminalView.fileOrBrowserURL("https://example.com/document.pdf")?.scheme == "https")
    }

    @Test func commandAndControlClickDispatchLocalPathsWithoutSendingTerminalInput() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let view = SelectionCopyTerminalView(frame: CGRect(x: 0, y: 0, width: 1200, height: 500))
        let delegate = Delegate()
        view.terminalDelegate = delegate
        view.feed(text: file.path)
        for flags in [NSEvent.ModifierFlags.command, .control] {
            view.mouseDown(with: event(.leftMouseDown, flags: flags))
            view.mouseUp(with: event(.leftMouseUp, flags: flags))
        }
        #expect(delegate.links == [file.path, file.path])
        await drainEvents()
        #expect(delegate.input.isEmpty)
    }

    @Test func controlHoverUsesLinkModifiersWithoutChangingTheOriginalEvent() {
        let flags = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.control, .shift],
                                    timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
        let mapped = SelectionCopyTerminalView.linkEvent(flags)
        #expect(mapped.modifierFlags.contains([.command, .shift]))
        #expect(!mapped.modifierFlags.contains(.control))
        #expect(flags.modifierFlags.contains(.control))
    }

    @Test func controlCIsNeverTranslatedToCommandC() {
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                  timestamp: 0, windowNumber: 0, context: nil,
                                  characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        #expect(SelectionCopyTerminalView.linkEvent(key) === key)
        #expect(key.modifierFlags.contains(.control))
    }
}
#endif
