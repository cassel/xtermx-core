import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

public struct RGB: Codable, Sendable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8

    public init(_ hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
    }

    init(r: Double, g: Double, b: Double) {
        self.r = UInt8(max(0, min(255, (r * 255).rounded())))
        self.g = UInt8(max(0, min(255, (g * 255).rounded())))
        self.b = UInt8(max(0, min(255, (b * 255).rounded())))
    }

    #if canImport(SwiftUI)
    public var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    #endif

    // MARK: Contrast (WCAG relative luminance)

    var luminance: Double {
        func ch(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    }

    func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let rr = Double(r) / 255, gg = Double(g) / 255, bb = Double(b) / 255
        let mx = max(rr, gg, bb), mn = min(rr, gg, bb)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case rr: h = (gg - bb) / d + (gg < bb ? 6 : 0)
        case gg: h = (bb - rr) / d + 2
        default: h = (rr - gg) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    init(h: Double, s: Double, l: Double) {
        guard s > 0 else { self.init(r: l, g: l, b: l); return }
        func hue(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        self.init(r: hue(p, q, h + 1 / 3), g: hue(p, q, h), b: hue(p, q, h - 1 / 3))
    }

    /// Lightens (on dark backgrounds) in 1% lightness steps, keeping hue and saturation,
    /// until the color reaches `ratio` against `background`.
    func ensuringContrast(_ ratio: Double, against background: RGB) -> RGB {
        guard ratio > 1, contrast(with: background) < ratio else { return self }
        var (h, s, l) = hsl
        let darkBackground = background.luminance < 0.5
        var c = self
        while c.contrast(with: background) < ratio, l >= 0, l <= 1 {
            l += darkBackground ? 0.01 : -0.01
            c = RGB(h: h, s: s, l: min(1, max(0, l)))
            if l <= 0 || l >= 1 { break }
        }
        _ = h; _ = s
        return c
    }
}

/// Window chrome colors of one preset.
public struct ChromeColors: Sendable, Hashable {
    public var background, canvas, foreground, card, popover, primary, destructive, broadcast,
               activity, border, paneBorder, muted, mutedForeground, accent, input: RGB
}

public struct TerminalTheme: Sendable, Hashable {
    public var background: RGB
    public var foreground: RGB
    public var cursor: RGB
    public var selection: RGB
    /// The 16 ANSI colors: 8 normal then 8 bright.
    public var ansi: [RGB]

    /// The palette actually handed to the terminal: every ANSI entry except white/brightWhite
    /// is pushed to `minimumContrast` against the background; bright black is capped at 3:1.
    public func adjusted(minimumContrast: Double) -> TerminalTheme {
        guard minimumContrast > 1 else { return self }
        var t = self
        t.ansi = ansi.enumerated().map { i, c in
            switch i {
            case 7, 15: c
            case 8: c.ensuringContrast(min(3, minimumContrast), against: background)
            default: c.ensuringContrast(minimumContrast, against: background)
            }
        }
        return t
    }

    public static let `default` = AppTheme.default.terminal
}

public struct AppTheme: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var tagline: String
    public var chrome: ChromeColors
    public var terminal: TerminalTheme

    public static let `default` = presets[0]

    public static func preset(_ id: String) -> AppTheme {
        presets.first { $0.id == id } ?? .default
    }

    private static func make(_ id: String, _ name: String, _ tagline: String, chrome c: [UInt32], term t: [UInt32]) -> AppTheme {
        let r = c.map(RGB.init)
        let tr = t.map(RGB.init)
        return AppTheme(
            id: id, name: name, tagline: tagline,
            chrome: ChromeColors(background: r[0], canvas: r[1], foreground: r[2], card: r[3], popover: r[4], primary: r[5],
                                 destructive: r[6], broadcast: r[7], activity: r[8], border: r[9], paneBorder: r[10],
                                 muted: r[11], mutedForeground: r[12], accent: r[13], input: r[14]),
            terminal: TerminalTheme(background: tr[0], foreground: tr[1], cursor: tr[2], selection: tr[3], ansi: Array(tr[4...]))
        )
    }

    // chrome: background canvas foreground card popover primary destructive broadcast activity border paneBorder muted mutedFg accent input
    // term:   background foreground cursor selection, then black red green yellow blue magenta cyan white, then the bright eight
    public static let presets: [AppTheme] = [
        make("classic", "Classic", "Default",
             chrome: [0x15191E, 0x0E1115, 0xDBDBDB, 0x15191E, 0x20252C, 0x128CE2, 0xF14B4B, 0x3EB3EA, 0xF6AE31, 0x323B49, 0x465367, 0x0E1115, 0xA8A8A8, 0x2B3440, 0x384252],
             term: [0x15191F, 0xDCDCDC, 0xFFFFFF, 0xB3D7FF,
                    0x14191E, 0xB43C2A, 0x00C200, 0xC7C400, 0x2744C7, 0xC040BE, 0x00C5C7, 0xC7C7C7,
                    0x686868, 0xDD7975, 0x58E790, 0xECE100, 0xA7ABF2, 0xE17EE1, 0x60FDFF, 0xFFFFFF]),
        make("dark-pro", "Dark Pro", "Modern",
             chrome: [0x1F1F1F, 0x121212, 0xCCCCCC, 0x1F1F1F, 0x2B2B2B, 0x128CE2, 0xF14B4B, 0x3EB3EA, 0xF6AE31, 0x3D3D3D, 0x575757, 0x171717, 0xADADAD, 0x383838, 0x474747],
             term: [0x1F1F1F, 0xE0E0E0, 0xE0E0E0, 0x264F78,
                    0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
                    0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF]),
        make("midnight", "Midnight", "Comfort Mono",
             chrome: [0x11151D, 0x0B0E14, 0xAEB8C7, 0x11151D, 0x1B212D, 0x128CE2, 0xF14B4B, 0x3EB3EA, 0xF6AE31, 0x2C374E, 0x3E4F6F, 0x0B0E14, 0x93A0B4, 0x273145, 0x323E58],
             term: [0x0D1117, 0xC8D0DA, 0xC7C7C7, 0x334870,
                    0x000000, 0xC94C4C, 0x5CB85C, 0xD9A74A, 0x4A90E2, 0xA770D4, 0x47B39C, 0xC7C7C7,
                    0x686868, 0xFF6E6E, 0x6EE7B7, 0xFCD34D, 0x60A5FA, 0xC084FC, 0x38BDF8, 0xFFFFFF]),
        make("tokyo-night", "Tokyo Night", "Vibrant",
             chrome: [0x1A1B29, 0x11121D, 0xBCC8FB, 0x1A1B29, 0x232538, 0x128CE2, 0xF14B4B, 0x3EB3EA, 0xF6AE31, 0x373A58, 0x4D507A, 0x14151F, 0x95A9F9, 0x31344E, 0x3D4061],
             term: [0x1A1B26, 0xC0CAF5, 0xC0CAF5, 0x364A82,
                    0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                    0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5]),
        make("catppuccin", "Catppuccin Macchiato", "Soft Pastel",
             chrome: [0x232638, 0x171926, 0xC7D1F5, 0x232638, 0x313449, 0x128CE2, 0xF14B4B, 0x3EB3EA, 0xF6AE31, 0x3D4261, 0x525984, 0x1D202F, 0xA4B4EF, 0x393D5B, 0x494E74],
             term: [0x24273A, 0xCAD3F5, 0xF4DBD6, 0x495882,
                    0x494D64, 0xED8796, 0xA6DA95, 0xEED49F, 0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xB8C0E0,
                    0x5B6078, 0xED8796, 0xA6DA95, 0xEED49F, 0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xA5ADCB]),
        make("one-dark", "One Dark Pro", "Classic Atom",
             chrome: [0x282C34, 0x1A1D23, 0xD3D7DE, 0x282C34, 0x333842, 0x128CE2, 0xF14B4B, 0x3EB3EA, 0xF6AE31, 0x434956, 0x596273, 0x21252B, 0xB6BDC8, 0x3E4451, 0x4B5362],
             term: [0x282C34, 0xABB2BF, 0x528BFF, 0x3E4451,
                    0x282C34, 0xE06C75, 0x98C379, 0xD19A66, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                    0x5C6370, 0xE06C75, 0x98C379, 0xD19A66, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF]),
        make("ember", "Ember", "High Contrast",
             chrome: [0x2B292E, 0x1C1A1E, 0xFBFBF8, 0x2B292E, 0x38353B, 0x128CE2, 0xF14B4B, 0x3EB3EA, 0xF6AE31, 0x47444B, 0x615C66, 0x242225, 0xBDBD84, 0x454148, 0x545058],
             term: [0x2D2A2E, 0xFCFCFA, 0xFCFCFA, 0x5B575C,
                    0x403E41, 0xFF6188, 0xA9DC76, 0xFFD866, 0xFC9867, 0xAB9DF2, 0x78DCE8, 0xFCFCFA,
                    0x727072, 0xFF6188, 0xA9DC76, 0xFFD866, 0xFC9867, 0xAB9DF2, 0x78DCE8, 0xFCFCFA]),
        make("solarized-dark", "Solarized Dark", "Warm Cyan",
             chrome: [0x002D38, 0x03171C, 0xCBD2D2, 0x002D38, 0x083945, 0x128CE2, 0xF14B4B, 0x3EB3EA, 0xF6AE31, 0x004E61, 0x006680, 0x002129, 0xADB8B8, 0x00495C, 0x00566B],
             term: [0x002B36, 0x839496, 0x839496, 0x073642,
                    0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                    0x586E75, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]),
        make("black", "Black", "Pure Black",
             chrome: [0x0D0D0D, 0x080808, 0xD9D9D9, 0x121212, 0x1F1F1F, 0x128CE2, 0xF14B4B, 0x3EB3EA, 0xF6AE31, 0x333333, 0x4C4C4C, 0x050505, 0xA1A1A1, 0x2E2E2E, 0x3D3D3D],
             term: [0x0D0D0D, 0xD4D4D4, 0xE6E6E6, 0x404040,
                    0x000000, 0xE0524F, 0x0DBC79, 0xE5E510, 0x3B8EEA, 0xC862C8, 0x11A8CD, 0xE5E5E5,
                    0x7A7A7A, 0xF14C4C, 0x23D18B, 0xF5F543, 0x6CB0F5, 0xD670D6, 0x29B8DB, 0xFFFFFF]),
        make("slate", "Slate", "Calm Slate",
             chrome: [0x22262F, 0x16181D, 0xD7D9DF, 0x191C24, 0x2D3139, 0x128CE2, 0xF14B4B, 0x80AAD1, 0xD2AA6A, 0x3C4353, 0x515B70, 0x1C1F26, 0xA2A7AE, 0x383E4D, 0x262A31],
             term: [0x22262D, 0xD7D9DE, 0xE1E3E7, 0x3A4658,
                    0x1A1D22, 0xD47C82, 0x7DC795, 0xD2AA68, 0x82A9D1, 0xA19AC5, 0x7EBFC4, 0xC3C7CE,
                    0x737A86, 0xE0959A, 0x96D6AB, 0xE0BF85, 0x9DBDE0, 0xB8B2D6, 0x9AD0D4, 0xF2F3F5]),
    ]
}

/// Agent-state colors shared by every theme.
public enum StateColors {
    public static let blocked = RGB(0xF14C4C)
    public static let done = RGB(0x23D18B)
    public static let idle = RGB(0x8A8A8A)
    /// Focused-pane accent "gray", also the working ring.
    public static let working = RGB(0xA1A6AF)
    public static let exited = RGB(0x5C6378)

    public static func rgb(for state: PaneState) -> RGB {
        switch state {
        case .working: working
        case .blocked: blocked
        case .idle: done
        case .exited: exited
        }
    }
}

#if canImport(SwiftUI)
private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.default
}

public extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

public extension ChromeColors {
    var bg: Color { background.color }
}

public extension PaneState {
    var color: Color { StateColors.rgb(for: self).color }

    var label: String {
        switch self {
        case .working: "Working"
        case .blocked: "Needs your input"
        case .idle: "Idle"
        case .exited: "Exited"
        }
    }

    var symbol: String {
        switch self {
        case .working: "circle.dotted"
        case .blocked: "exclamationmark.bubble.fill"
        case .idle: "checkmark.circle"
        case .exited: "stop.circle"
        }
    }
}
#endif
