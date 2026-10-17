import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let shift = Self(rawValue: 4)
    public static let control = Self(rawValue: 8)
}
public struct ShortcutChord: Codable, Hashable, Sendable {
    public var key: String
    public var modifiers: ShortcutModifiers
    public init(_ key: String, modifiers: ShortcutModifiers = .command) { self.key = key.lowercased(); self.modifiers = modifiers }
    public var display: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + key.uppercased()
    }
}
public enum AppShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case newWorkspace, newTerminal, splitRight, splitDown, maximize, equalize, closePane, dictation, chat
    case nextPane, previousPane, sidebar, rightPanel, palette, remoteSettings, broadcast, zoomIn, zoomOut, actualSize
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .newWorkspace: "New Workspace Tab"; case .newTerminal: "New Terminal"
        case .splitRight: "Split Pane Right"; case .splitDown: "Split Pane Down"
        case .maximize: "Maximize Pane"; case .equalize: "Equalize Panes"; case .closePane: "Close Pane"
        case .dictation: "Toggle Dictation"; case .chat: "Toggle Chat View"
        case .nextPane: "Next Pane"; case .previousPane: "Previous Pane"
        case .sidebar: "Toggle Sidebar"; case .rightPanel: "Toggle Right Panel"
        case .palette: "Command Palette"; case .remoteSettings: "Remote Access Settings…"
        case .broadcast: "Toggle Broadcast Mode"; case .zoomIn: "Zoom In"; case .zoomOut: "Zoom Out"; case .actualSize: "Actual Size"
        }
    }
    public var defaultChord: ShortcutChord {
        switch self {
        case .newWorkspace: .init("t"); case .newTerminal: .init("n")
        case .splitRight: .init("d"); case .splitDown: .init("d", modifiers: [.command, .shift])
        case .maximize: .init("m", modifiers: [.command, .shift]); case .equalize: .init("p"); case .closePane: .init("w")
        case .dictation: .init("l", modifiers: [.command, .shift]); case .chat: .init("c", modifiers: [.command, .shift])
        case .nextPane: .init("]"); case .previousPane: .init("[")
        case .sidebar: .init("b"); case .rightPanel: .init("b", modifiers: [.command, .shift])
        case .palette: .init("k"); case .remoteSettings: .init("g", modifiers: [.command, .shift])
        case .broadcast: .init("b", modifiers: [.command, .option])
        case .zoomIn: .init("="); case .zoomOut: .init("-"); case .actualSize: .init("0")
        }
    }
}
public struct AppShortcutPreferences: Codable, Sendable, Equatable {
    public enum Failure: Error, Equatable { case invalidKey, needsCommand, reserved, conflict(AppShortcutAction) }
    private var overrides: [String: ShortcutChord] = [:]
    public init() {}
    public func chord(for action: AppShortcutAction) -> ShortcutChord { overrides[action.rawValue] ?? action.defaultChord }
    private static func validate(_ chord: ShortcutChord) throws {
        guard chord.key.utf8.count == 1, let byte = chord.key.utf8.first, (33...126).contains(byte), chord.key == chord.key.lowercased(), chord.modifiers.rawValue & ~15 == 0 else { throw Failure.invalidKey }
        guard chord.modifiers.contains(.command) else { throw Failure.needsCommand }
        if chord.modifiers == .command, ["a", "c", "v", "x", "z", "q", "h", "m", ",", "1", "2", "3", "4", "5", "6", "7", "8", "9"].contains(chord.key) { throw Failure.reserved }
        if chord.modifiers == [.command, .shift], ["z", "[", "]"].contains(chord.key) { throw Failure.reserved }
    }
    public mutating func set(_ action: AppShortcutAction, to chord: ShortcutChord) throws {
        try Self.validate(chord)
        if let conflict = AppShortcutAction.allCases.first(where: { $0 != action && self.chord(for: $0) == chord }) { throw Failure.conflict(conflict) }
        overrides[action.rawValue] = chord == action.defaultChord ? nil : chord
    }
    public mutating func reset() { overrides = [:] }
    public static func restored(from data: Data?) -> Self {
        guard let data, data.count < 16_384, let saved = try? JSONDecoder().decode(Self.self, from: data),
              saved.overrides.keys.allSatisfy({ AppShortcutAction(rawValue: $0) != nil }) else { return Self() }
        let chords = AppShortcutAction.allCases.map { saved.chord(for: $0) }
        guard Set(chords).count == chords.count, chords.allSatisfy({ (try? Self.validate($0)) != nil }) else { return Self() }
        return saved
    }
}
