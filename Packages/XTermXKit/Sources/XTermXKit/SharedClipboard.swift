import Foundation

/// What may travel on the shared clipboard: plain text, not empty, at most 256 KB of UTF-8.
public enum ClipboardRules {
    public static let maximumBytes = 256 * 1024

    public static func accepts(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maximumBytes
    }
}

/// Keeps one side of the shared clipboard from bouncing text back where it came from.
///
/// `incoming` is text a peer sent (apply it locally when non-nil); `outgoing` is a local clipboard
/// change (send it when non-nil). Text that just arrived from the peer, or was just sent, is not sent again.
public struct ClipboardSync: Sendable {
    private var lastReceived: String?
    private var lastSent: String?

    public init() {}

    public mutating func incoming(_ text: String) -> String? {
        guard ClipboardRules.accepts(text), text != lastSent, text != lastReceived else { return nil }
        lastReceived = text
        return text
    }

    public mutating func outgoing(_ text: String) -> String? {
        guard ClipboardRules.accepts(text), text != lastReceived, text != lastSent else { return nil }
        lastSent = text
        lastReceived = nil
        return text
    }
}

/// OSC 52: a program in a pane (often over SSH) asks the terminal to copy text.
/// Always on in the Mac's own panes; elsewhere off unless the person turns on "Allow programs to set the
/// clipboard". Never answers a read (`?`).
public enum ProgramClipboard {
    public static let defaultsKey = "xtermx.terminal.programClipboard"

    public static func isAllowed(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }

    /// The payload after `ESC ]`, with or without the leading `52;`: `<targets>;<base64>`.
    public static func decode(osc payload: String) -> String? {
        var rest = Substring(payload)
        if rest.hasPrefix("52;") { rest = rest.dropFirst(3) }
        guard let semicolon = rest.firstIndex(of: ";") else { return nil }
        guard rest[..<semicolon].allSatisfy({ "cpqs01234567".contains($0) }) else { return nil }
        let body = rest[rest.index(after: semicolon)...]
        guard body != "?", body.utf8.count <= (ClipboardRules.maximumBytes / 3 + 1) * 4,
              let data = Data(base64Encoded: String(body)) else { return nil }
        return text(data)
    }

    /// Decoded bytes as clipboard text: valid UTF-8, no NUL, within the shared clipboard's limit.
    public static func text(_ data: Data) -> String? {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8), ClipboardRules.accepts(text) else { return nil }
        return text
    }
}
