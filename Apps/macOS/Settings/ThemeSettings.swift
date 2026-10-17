import AppKit
import SwiftUI
import XTermXHost
import XTermXKit

struct ThemeSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @AppStorage("xtermx.theme") private var themeID = AppTheme.default.id

    var body: some View {
        @Bindable var model = model
        SettingsPage(section: .theme) {
            SettingsCard("Window theme", "Try a palette using its own terminal preview.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 12) {
                    ForEach(AppTheme.presets) { preset in
                        Button { themeID = preset.id } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                miniTerminal(preset)
                                HStack {
                                    Text(preset.name).fontWeight(.semibold)
                                    Spacer()
                                    if themeID == preset.id { Image(systemName: "checkmark.circle.fill") }
                                }
                                Text(preset.tagline).font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
                            }
                            .padding(10)
                            .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(themeID == preset.id ? theme.chrome.primary.color : theme.chrome.border.color,
                                                                           lineWidth: themeID == preset.id ? 2 : 1))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Use \(preset.name) theme")
                    }
                }
            }
            SettingsCard("Read comfortably", "Raise terminal color contrast and let inactive panes recede.") {
                Picker("Minimum terminal contrast", selection: $model.appearance.contrast) {
                    ForEach(MinimumContrast.allCases) { value in Text(LocalizedStringKey(value.title)).tag(value) }
                }
                HStack {
                    Text("Dim inactive panes")
                    Slider(value: $model.appearance.inactiveDim, in: 0...0.8, step: 0.05)
                    Text("\(Int(model.appearance.dimOpacity * 100))%").monospacedDigit().frame(width: 40)
                }
            }
            SettingsCard("Find your focus", "Choose the pane outline and the focused pane's color.") {
                Picker("Pane border", selection: $model.appearance.border) {
                    ForEach(PaneBorderStyle.allCases) { value in Text(LocalizedStringKey(value.title)).tag(value) }
                }.pickerStyle(.segmented)
                ColorPicker("Focused pane", selection: colorBinding(\.focusColor, fallback: theme.chrome.primary), supportsOpacity: false)
                Button("Use theme focus color") { model.appearance.focusColor = nil }
            }
            SettingsCard("Messages across the room", "A short trail follows agent messages and reports between panes.") {
                Toggle("Show message trails", isOn: $model.appearance.messageLines).toggleStyle(.switch)
                Toggle("Use curved trails", isOn: $model.appearance.curvedMessages).toggleStyle(.switch)
                Picker("Trail pattern", selection: $model.appearance.messagePattern) {
                    ForEach(MessageLinePattern.allCases) { value in Text(LocalizedStringKey(value.title)).tag(value) }
                }
                HStack {
                    Text("Trail width")
                    Slider(value: $model.appearance.messageWidth, in: 0.5...6, step: 0.5)
                    Text("\(model.appearance.lineWidth.formatted()) pt").monospacedDigit().frame(width: 45)
                }
                ColorPicker("Trail color", selection: colorBinding(\.messageColor, fallback: theme.chrome.activity), supportsOpacity: false)
                Button("Use theme trail color") { model.appearance.messageColor = nil }
                Text("Only real sends and reports draw a trail. Reduce Motion uses a brief static line.").font(.caption)
            }
        }
    }
    private func colorBinding(_ path: WritableKeyPath<AppearancePreferences, RGB?>, fallback: RGB) -> Binding<Color> {
        Binding(get: { (model.appearance[keyPath: path] ?? fallback).color }, set: { value in
            let color = NSColor(value).usingColorSpace(.sRGB) ?? .white
            func byte(_ component: CGFloat) -> UInt32 { UInt32((max(0, min(1, component)) * 255).rounded()) }
            model.appearance[keyPath: path] = RGB((byte(color.redComponent) << 16) | (byte(color.greenComponent) << 8) | byte(color.blueComponent))
        })
    }
    private func miniTerminal(_ preset: AppTheme) -> some View {
        let palette = preset.terminal.adjusted(minimumContrast: model.appearance.contrast.rawValue)
        return VStack(alignment: .leading, spacing: 5) {
            Text("$ git status").foregroundStyle(palette.foreground.color)
            Text("On branch feature").foregroundStyle(palette.ansi[6].color)
            Text("✓ ready to build").foregroundStyle(palette.ansi[2].color)
            Text("› _").foregroundStyle(palette.cursor.color)
        }
        .font(.system(size: 11, design: .monospaced)).padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background.color, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Settings › Terminal: how text looks in the panes, and how agent panes read as a conversation.
struct TerminalSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("xtermx.chatTheme") private var chatTheme = AgentChatTheme.auto.rawValue

    var body: some View {
        @Bindable var model = model
        SettingsPage(section: .terminal) {
            SettingsCard("Font size", "Size of the text in every pane.") {
                Stepper("\(Int(model.fontSize)) pt", value: $model.fontSize, in: 8...32)
            }
            SettingsCard("Claude's status line", "Collect plan limits while keeping your own status command running.") {
                Toggle("Manage Claude Code's status line", isOn: Binding(get: { model.claudeStatusLineManaged },
                                                                        set: { model.setClaudeStatusLineManaged($0) }))
                    .toggleStyle(.switch)
                Text("Turning it off restores your own line. Lifecycle and approval hooks keep working; plan limits may stop updating.").font(.caption)
                if let error = model.statusLineMessage { Text(error).font(.caption).foregroundStyle(.red) }
            }
            PaneDictationSettings()
            SettingsCard("Select and keep", "Copy selected terminal text when you finish selecting with the mouse.") {
                Toggle("Copy when selecting text", isOn: $model.copyOnSelection).toggleStyle(.switch)
            }
            SettingsCard("Room for each pane", "Choose when split sizes reset and how dense a tab can become.") {
                Toggle("Balance after adding a pane", isOn: $model.balanceAfterSplit).toggleStyle(.switch)
                Toggle("Balance when opening saved tabs", isOn: $model.balanceOnOpen).toggleStyle(.switch)
                Stepper("Up to \(model.maxPaneColumns) panes across", value: $model.maxPaneColumns, in: 1...12)
                Stepper("Up to \(model.maxPaneRows) panes down", value: $model.maxPaneRows, in: 1...12)
                Button("Balance this tab now") { model.equalizePanes() }.disabled(model.active == nil)
                Text("Limits apply to new splits. Existing and restored layouts keep all their panes.").font(.caption)
            }
            SettingsCard("Agent panes as a chat",
                         "Claude Code and Codex messages, answers and tool calls read like a conversation; ⌘⇧C or the pane's header switches back to the terminal.") {
                Toggle("Open agent panes as a chat", isOn: $model.chatViewByDefault)
                    .toggleStyle(.switch)
                Picker("Chat colors", selection: $chatTheme) {
                    ForEach(AgentChatTheme.allCases, id: \.rawValue) { t in
                        Text(LocalizedStringKey(t == .auto ? "Auto (window theme)" : t.label)).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}
