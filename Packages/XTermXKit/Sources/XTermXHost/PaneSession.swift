#if os(macOS) || os(Linux)
import Foundation
import SwiftTerm
import XTermXKit

/// One pseudo-terminal and the program in it, plus what clients need to see it:
/// a replay buffer for late subscribers and a headless terminal whose screen gives
/// plain-text lines (Watch, state detection).
@MainActor
public final class PaneSession {
    public private(set) var info: PaneInfo
    public var onOutput: ((Data) -> Void)?
    public var onChange: ((PaneInfo) -> Void)?
    public var onExit: ((PaneInfo) -> Void)?

    private var process: LocalProcess!
    /// The pane's shell; agents started in the pane descend from it.
    public var shellPID: Int32 { process.shellPid }
    private let screen: Terminal
    private let screenDelegate = HeadlessDelegate()
    private var replay = Data()
    private var stateTimer: Timer?
    private var promptMarks = SemanticPromptTracker()

    public init(info: PaneInfo, shell: String, environment: [String], initialInput: String?) {
        self.info = info
        self.screen = Terminal(delegate: screenDelegate, options: TerminalOptions(cols: info.cols, rows: info.rows, scrollback: 2000))
        screenDelegate.onTitle = { [weak self] title in self?.titleChanged(title) }
        // Shells with prompt marks (OSC 133) say when a command starts and ends, and with what code.
        screen.registerOscHandler(code: 133) { [weak self] data in
            let mark = String(decoding: data, as: UTF8.self)
            MainActor.assumeIsolated { self?.promptMarked(mark) }
        }
        self.process = LocalProcess(delegate: self, dispatchQueue: .main)

        Self.closeInheritedDescriptors()
        // A login, interactive shell: agents get the person's PATH and dotfiles, and when an
        // agent quits the pane falls back to a prompt instead of closing.
        process.startProcess(executable: shell, args: ["-l", "-i"], environment: environment,
                             execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: info.cwd)

        if let initialInput, !initialInput.isEmpty {
            // Give the shell a moment to print its prompt before typing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.write(Data((initialInput + "\r").utf8))
            }
        }

        stateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshState() }
        }
    }

    // MARK: Input

    public func write(_ data: Data) {
        guard info.state != .exited else { return }
        process.send(data: ArraySlice(data))
    }

    public func sendLine(_ text: String) {
        write(Data(text.utf8))
        // A separate Return lets TUIs (Claude Code, Codex) treat the text as a paste first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.write(Data([0x0d])) }
    }

    /// Sockets the app holds (the remote-access listeners, open connections) would otherwise pass to every
    /// shell, which then keeps the port busy after remote access is turned off and on again.
    private static func closeInheritedDescriptors() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else { return }
        for fd in names.compactMap(Int32.init) where fd > 2 {
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0, flags & FD_CLOEXEC == 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 4, rows > 2, cols != info.cols || rows != info.rows else { return }
        info.cols = cols
        info.rows = rows
        screen.resize(cols: cols, rows: rows)
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
        onChange?(info)
    }

    /// Asks the program in front to draw again at the current size: a view that just appeared may hold
    /// nothing, and the kernel only signals a size change when the size actually changed.
    public func redraw() {
        guard info.state != .exited else { return }
        let group = tcgetpgrp(process.childfd)
        if group > 0 { kill(-group, SIGWINCH) }
    }

    /// An agent's one-liner for the phone and Watch.
    public func setSummary(_ text: String, needsYou: Bool) {
        info.summary = String(text.prefix(160))
        info.summaryAt = .now
        info.needsYou = needsYou
        onChange?(info)
    }

    public func setCustomName(_ name: String?) {
        info.customName = name
        onChange?(info)
    }

    public func clearNeedsYou() {
        guard info.needsYou else { return }
        info.needsYou = false
        onChange?(info)
    }

    public func terminate() {
        stateTimer?.invalidate()
        process.terminate()
    }

    // MARK: Output views

    public var replayData: Data { replay }

    /// The scrollback and screen redrawn at the pane's current size, for a client that just subscribed.
    public func snapshot() -> Data { ScreenSnapshot.ansi(screen) }

    /// The bottom `count` non-trailing-empty lines of the screen, without colors.
    public func screenLines(_ count: Int) -> [String] {
        var lines: [String] = []
        for row in 0..<screen.rows {
            lines.append(screen.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    // MARK: Internals

    fileprivate func received(_ bytes: ArraySlice<UInt8>) {
        let data = Data(bytes)
        replay.append(data)
        if replay.count > XTermXProtocol.replayBytes {
            replay.removeFirst(replay.count - XTermXProtocol.replayBytes)
        }
        screen.feed(byteArray: Array(bytes))
        info.lastActivity = .now
        if info.state != .working {
            info.state = .working
            onChange?(info)
        }
        onOutput?(data)
    }

    fileprivate func exited(_ code: Int32?) {
        stateTimer?.invalidate()
        info.state = .exited
        info.exitCode = code
        info.lastLine = screenLines(1).first ?? ""
        onChange?(info)
        onExit?(info)
    }

    private func promptMarked(_ mark: String) {
        guard let run = promptMarks.handle(mark) else { return }
        info.lastCommand = run
        DispatchQueue.main.async { [weak self] in if let self { self.onChange?(self.info) } }
    }

    private func titleChanged(_ title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != info.title else { return }
        info.title = clean
        onChange?(info)
    }

    /// The agent's own report beats reading the screen; nil goes back to reading the screen.
    func setAgentSession(_ session: AgentSessionInfo?) {
        guard session != info.agentSession else { return }
        info.agentSession = session
        refreshState(force: true)
    }

    private func refreshState(force: Bool = false) {
        guard info.state != .exited else { return }
        let tail = screenLines(6)
        let last = tail.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let quiet = Date.now.timeIntervalSince(info.lastActivity) > 2.5
        let next: PaneState
        switch info.agentSession?.status {
        case .working?: next = .working
        case .waiting?: next = .blocked
        case .shell?, .idle?: next = quiet ? .idle : .working
        case .ended?, nil: next = quiet ? (PaneStateClassifier.isWaitingForPerson(tail) ? .blocked : .idle) : .working
        }
        if force { info.lastLine = String(last.prefix(200)); info.state = next; onChange?(info); return }
        if next != info.state || last != info.lastLine {
            info.state = next
            info.lastLine = String(last.prefix(200))
            onChange?(info)
        }
    }
}

extension PaneSession: @preconcurrency LocalProcessDelegate {
    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) { exited(exitCode) }
    public func dataReceived(slice: ArraySlice<UInt8>) { received(slice) }
    public func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(info.rows), ws_col: UInt16(info.cols), ws_xpixel: 0, ws_ypixel: 0)
    }
}

/// Recognises the prompts coding agents and shells show when they need an answer.
public enum PaneStateClassifier {
    static let patterns: [String] = [
        "(y/n)", "[y/n]", "[y/N]", "[Y/n]", "(yes/no)",
        "do you want to", "do you trust", "allow ", "approve", "permission",
        "❯ 1.", "› 1.", "> 1. yes", "press enter", "continue?", "proceed?",
        "waiting for your", "requires approval",
    ]

    public static func isWaitingForPerson(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: "\n").lowercased()
        return patterns.contains { text.contains($0.lowercased()) }
    }
}

/// A Terminal needs a delegate even when nothing draws it.
private final class HeadlessDelegate: TerminalDelegate {
    var onTitle: ((String) -> Void)?
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func setTerminalTitle(source: Terminal, title: String) { onTitle?(title) }
}
#endif
