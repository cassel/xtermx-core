import Foundation
import Testing
import XTermXKit

struct AppShortcutsTests {
    @Test func shortcutsDetectConflictsAndPreserveEditingAndTabKeys() throws {
        var preferences = AppShortcutPreferences()
        let defaults = AppShortcutAction.allCases.map { preferences.chord(for: $0) }
        #expect(Set(defaults).count == defaults.count)
        #expect(throws: AppShortcutPreferences.Failure.self) { try preferences.set(.palette, to: .init("d")) }
        #expect(throws: AppShortcutPreferences.Failure.self) { try preferences.set(.palette, to: .init("c")) }
        #expect(throws: AppShortcutPreferences.Failure.self) { try preferences.set(.palette, to: .init("1")) }
        #expect(throws: AppShortcutPreferences.Failure.self) { try preferences.set(.palette, to: .init("x", modifiers: .control)) }
        #expect(throws: AppShortcutPreferences.Failure.self) { try preferences.set(.palette, to: .init("many")) }
        try preferences.set(.palette, to: .init("K", modifiers: [.command, .option]))
        #expect(preferences.chord(for: .palette).display == "⌥⌘K")
        #expect(preferences.chord(for: .splitRight) == AppShortcutAction.splitRight.defaultChord)
        let stored = try JSONEncoder().encode(preferences)
        #expect(AppShortcutPreferences.restored(from: stored) == preferences)
        preferences.reset()
        #expect(preferences == AppShortcutPreferences())
    }
    @Test func persistedCorruptionCannotStealReservedShortcuts() throws {
        let chord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ShortcutChord("q")))
        let corrupt = try JSONSerialization.data(withJSONObject: ["overrides": ["palette": chord]])
        #expect(AppShortcutPreferences.restored(from: corrupt) == AppShortcutPreferences())
        #expect(AppShortcutPreferences.restored(from: Data("invalid".utf8)) == AppShortcutPreferences())
        var preferences = AppShortcutPreferences()
        try preferences.set(.palette, to: .init("g", modifiers: [.command, .option]))
        try preferences.set(.remoteSettings, to: .init("k"))
        #expect(AppShortcutPreferences.restored(from: try JSONEncoder().encode(preferences)) == preferences)
    }
}
