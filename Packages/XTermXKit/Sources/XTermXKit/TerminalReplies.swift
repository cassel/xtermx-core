import Foundation

/// Tells keys a person typed from what a terminal sends on its own: answers to a program's queries
/// (cursor position, device attributes, mode and size reports, colors), focus and mouse reports.
/// Only typing should decide whose screen size a shared pane takes; tmux and Codex query the
/// terminal after every resize, and those answers arrive on the same path as keys.
public enum TerminalReplies {
    /// True when every sequence in `data` is something the terminal answers or reports by itself.
    public static func isAutomatic(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard !b.isEmpty else { return false }
        var i = 0
        while i < b.count {
            guard let end = automaticSequence(b, at: i) else { return false }
            i = end
        }
        return true
    }

    /// The end of the automatic sequence starting at `i`, or nil when it isn't one.
    static func automaticSequence(_ b: [UInt8], at i: Int) -> Int? {
        guard i + 1 < b.count, b[i] == 0x1b else { return nil }
        switch b[i + 1] {
        case 0x5d, 0x50: // OSC (colors, clipboard) or DCS (capabilities): up to BEL or ESC \
            var j = i + 2
            while j < b.count {
                if b[j] == 0x07 { return j + 1 }
                if b[j] == 0x1b, j + 1 < b.count, b[j + 1] == 0x5c { return j + 2 }
                j += 1
            }
            return nil
        case 0x5b: // CSI
            guard i + 2 < b.count else { return nil }
            if b[i + 2] == 0x4d { return i + 6 <= b.count ? i + 6 : nil } // mouse, X10 form
            var j = i + 2
            while j < b.count, (0x20...0x3f).contains(b[j]) { j += 1 }
            guard j < b.count else { return nil }
            let params = Array(b[(i + 2)..<j])
            let final = b[j]
            let privateMark = params.first.map { [0x3f, 0x3e, 0x3c, 0x3d].contains($0) } ?? false
            switch final {
            case 0x49, 0x4f: // focus in / out
                return params.isEmpty ? j + 1 : nil
            case 0x4d, 0x6d: // SGR mouse
                return params.first == 0x3c ? j + 1 : nil
            case 0x52: // cursor position report: ESC [ row ; col R (a key with modifiers is ESC [ 1 ; m R)
                return params.contains(0x3b) && !params.starts(with: [0x31, 0x3b]) ? j + 1 : nil
            case 0x63: // device attributes
                return privateMark ? j + 1 : nil
            case 0x79: // mode reports: … $ y
                return params.last == 0x24 ? j + 1 : nil
            case 0x75: // keyboard protocol flags: ESC [ ? flags u
                return params.first == 0x3f ? j + 1 : nil
            case 0x74: // window and cell size reports
                return params.contains(0x3b) ? j + 1 : nil
            case 0x6e: // status report
                return params == [0x30] || params.first == 0x3f ? j + 1 : nil
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
