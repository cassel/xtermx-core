import SwiftUI
import XTermXKit

extension ShortcutModifiers {
    var events: EventModifiers {
        var flags: EventModifiers = []
        if contains(.command) { flags.insert(.command) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
extension View {
    func appShortcut(_ action: AppShortcutAction, preferences: AppShortcutPreferences) -> some View {
        let chord = preferences.chord(for: action)
        return keyboardShortcut(KeyEquivalent(chord.key.first ?? "?"), modifiers: chord.modifiers.events)
    }
}

struct ShortcutsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: AppShortcutAction?
    @State private var resetting = false
    var body: some View {
        SettingsPage(section: .shortcuts) {
            SettingsCard("Your key combinations", "Change the main actions here. The menu bar always shows the active shortcut.") {
                ForEach(AppShortcutAction.allCases) { action in
                    HStack {
                        Text(LocalizedStringKey(action.title))
                        Spacer()
                        Text(model.shortcuts.chord(for: action).display).font(.system(.body, design: .monospaced))
                        Button("Change…") { editing = action }
                    }
                }
                Button("Restore all defaults…") { resetting = true }
            }
            SettingsCard("Navigation and standard keys", "These shortcuts stay fixed so terminal controls and macOS editing keep their usual behavior.") {
                fixed("Settings", "⌘,")
                fixed("Quick Terminal Switcher", "⌃Tab / ⌃⇧Tab")
                fixed("New Terminal Here (Auto Split)", "⌃N")
                fixed("Focus Pane", "⌃← / ⌃→ / ⌃↑ / ⌃↓")
                fixed("Move Pane", "⌃⇧← / ⌃⇧→ / ⌃⇧↑ / ⌃⇧↓")
                fixed("Previous Tab", "⌥⌘←")
                fixed("Next Tab", "⌥⌘→")
                fixed("Tab by number", "⌘1…⌘8 / ⌘9")
                fixed("Copy / Paste / Cut / Select All", "⌘C / ⌘V / ⌘X / ⌘A")
                fixed("Undo / Redo", "⌘Z / ⌘⇧Z")
            }
        }
        .sheet(item: $editing) { action in ShortcutEditor(action: action, chord: model.shortcuts.chord(for: action)) }
        .alert("Restore the default shortcuts?", isPresented: $resetting) {
            Button("Restore defaults") { model.shortcuts.reset() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("All custom combinations will be removed.") }
    }
    private func fixed(_ title: String, _ keys: String) -> some View {
        HStack { Text(LocalizedStringKey(title)); Spacer(); Text(keys).font(.system(.body, design: .monospaced)) }
    }
}

private struct ShortcutEditor: View {
    let action: AppShortcutAction
    @State var chord: ShortcutChord
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(LocalizedStringKey(action.title)).font(.title2.bold())
            Text("Use one unshifted Latin letter, number or symbol. Choose modifiers separately; Command stays required.").font(.caption)
            TextField("Key", text: $chord.key).frame(width: 120)
                .onChange(of: chord.key) { _, value in chord.key = value.lowercased() }
            HStack {
                Text("⌘ Command")
                Toggle("⌥ Option", isOn: modifier(.option))
                Toggle("⇧ Shift", isOn: modifier(.shift))
                Toggle("⌃ Control", isOn: modifier(.control))
            }.toggleStyle(.checkbox)
            Text(chord.display).font(.title.monospaced())
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Use action default") { chord = action.defaultChord; error = nil }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    do { try model.shortcuts.set(action, to: chord); dismiss() }
                    catch let failure as AppShortcutPreferences.Failure { error = message(failure) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.padding(24).frame(width: 580)
    }
    private func modifier(_ value: ShortcutModifiers) -> Binding<Bool> {
        Binding(get: { chord.modifiers.contains(value) }, set: { if $0 { chord.modifiers.insert(value) } else { chord.modifiers.remove(value) } })
    }
    private func message(_ failure: AppShortcutPreferences.Failure) -> String {
        let language = InterfaceLanguage.current
        switch failure {
        case .invalidKey: return language.text("Choose a single unshifted letter, number or symbol.")
        case .needsCommand: return language.text("Keep Command in the combination.")
        case .reserved: return language.text("This combination belongs to macOS editing or fixed navigation.")
        case .conflict(let action): return String(format: language.text("Already used by %@."), language.text(action.title))
        }
    }
}

extension AppModel {
    func shortcutHint(_ source: String) -> String {
        let translated = InterfaceLanguage.current.text(source)
        let candidates = AppShortcutAction.allCases.map { action -> (AppShortcutAction, String) in
            let chord = action.defaultChord
            let modifiers = chord.modifiers
            let legacy = (modifiers.contains(.command) ? "⌘" : "") + (modifiers.contains(.option) ? "⌥" : "")
                + (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.shift) ? "⇧" : "") + chord.key.uppercased()
            return (action, legacy)
        }.sorted { $0.1.count > $1.1.count }
        guard let (action, legacy) = candidates.first(where: { source.contains($0.1) }) else { return translated }
        return translated.replacingOccurrences(of: legacy, with: shortcuts.chord(for: action).display)
    }
}
