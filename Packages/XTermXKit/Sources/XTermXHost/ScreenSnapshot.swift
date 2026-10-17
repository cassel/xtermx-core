#if os(macOS) || os(Linux)
import Foundation
import SwiftTerm

/// A pane's scrollback and screen as the bytes that draw them again, at the pane's current size.
/// Sent to a client that subscribes instead of the raw output, which was written for whatever
/// width the pane had then and wraps into a mess on a narrower screen (a phone).
enum ScreenSnapshot {
    static func ansi(_ t: Terminal, maxLines: Int = 1000) -> Data {
        // A reconnect/re-fit can reuse a view that was in an alternate buffer or scroll region.
        // Clearing text alone leaves those modes active and moves the replay's prompt to another row.
        var out = "\u{1b}[?1047l\u{1b}[?6l\u{1b}[r\u{1b}[?69l\u{1b}[?7h\u{1b}[?1l\u{1b}[?2004l\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[3J"
        if t.isCurrentBufferAlternate { out += "\u{1b}[?1049h\u{1b}[H\u{1b}[2J" }

        var lines: [BufferLine] = []
        var row = t.buffer.totalLinesTrimmed
        while let line = t.getScrollInvariantLine(row: row) {
            lines.append(line)
            row += 1
        }
        let start = max(0, lines.count - maxLines)
        var attr = Attribute.empty
        for i in start..<lines.count {
            let line = lines[i]
            if i > start && !line.isWrapped {
                if attr != .empty { out += "\u{1b}[0m"; attr = .empty }
                out += "\r\n"
            }
            // A line that continues on the next one is written to the edge so the client wraps it too.
            let continues = i + 1 < lines.count && lines[i + 1].isWrapped
            let end = continues ? min(line.count, t.cols) : lastContent(line, cols: t.cols)
            var col = 0
            while col < end {
                let cell = line[col]
                col += 1
                if cell.width == 0 { continue } // the right half of a wide character
                if cell.attribute != attr {
                    out += sgr(cell.attribute)
                    attr = cell.attribute
                }
                let text = cell.getText()
                out += text.isEmpty || text == "\u{0}" ? " " : text
            }
        }
        out += "\u{1b}[0m"
        if t.buffer.scrollTop != 0 || t.buffer.scrollBottom != t.rows - 1 {
            out += "\u{1b}[\(t.buffer.scrollTop + 1);\(t.buffer.scrollBottom + 1)r"
        }
        let cursor = t.getCursorLocation()
        out += "\u{1b}[\(cursor.y + 1);\(min(cursor.x, max(t.cols - 1, 0)) + 1)H"
        if t.applicationCursor { out += "\u{1b}[?1h" }
        if t.bracketedPasteMode { out += "\u{1b}[?2004h" }
        return Data(out.utf8)
    }

    /// One past the last cell with a character or a background color.
    static func lastContent(_ line: BufferLine, cols: Int) -> Int {
        var end = min(line.count, cols)
        while end > 0 {
            let cell = line[end - 1]
            let text = cell.getText()
            let blank = text.isEmpty || text == " " || text == "\u{0}"
            if !blank || cell.attribute.bg != Attribute.empty.bg || cell.attribute.style.contains(.inverse) { break }
            end -= 1
        }
        return end
    }

    static func sgr(_ a: Attribute) -> String {
        var codes = ["0"]
        let s = a.style
        if s.contains(.bold) { codes.append("1") }
        if s.contains(.dim) { codes.append("2") }
        if s.contains(.italic) { codes.append("3") }
        if s.contains(.underline) { codes.append("4") }
        if s.contains(.blink) { codes.append("5") }
        if s.contains(.inverse) { codes.append("7") }
        if s.contains(.invisible) { codes.append("8") }
        if s.contains(.crossedOut) { codes.append("9") }
        codes += color(a.fg, foreground: true)
        codes += color(a.bg, foreground: false)
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    static func color(_ c: Attribute.Color, foreground: Bool) -> [String] {
        switch c {
        case .ansi256(let code):
            if code < 8 { return ["\((foreground ? 30 : 40) + Int(code))"] }
            if code < 16 { return ["\((foreground ? 90 : 100) + Int(code) - 8)"] }
            return [foreground ? "38" : "48", "5", "\(code)"]
        case .trueColor(let r, let g, let b):
            return [foreground ? "38" : "48", "2", "\(r)", "\(g)", "\(b)"]
        case .defaultColor, .defaultInvertedColor:
            return []
        }
    }
}
#endif
