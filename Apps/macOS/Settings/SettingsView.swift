import SwiftUI
import XTermXKit

/// One page of the Settings window, in sidebar order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, notifications
    case agents, usage
    case remoteAccess, sharing
    case theme, terminal, shortcuts
    case privacy, tour, feedback, about

    var id: String { rawValue }

    /// The page a stored `xtermx.settings.section` value points at, including the names E1.1 wrote.
    init(stored: String) {
        switch stored {
        case "tokenMeter": self = .usage
        case "appearance": self = .theme
        case "onboarding": self = .tour
        default: self = SettingsSection(rawValue: stored) ?? .general
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .agents: "Agents"
        case .usage: "Usage"
        case .remoteAccess: "Remote access"
        case .sharing: "Sharing"
        case .theme: "Theme"
        case .terminal: "Terminal"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        case .tour: "Tour"
        case .feedback: "Feedback"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup and everyday behavior."
        case .notifications: "Get a heads-up when an agent is done or stuck."
        case .agents: "Which agents are here and what they're allowed to do."
        case .usage: "How much of each plan your sessions have used."
        case .remoteAccess: "Drive this Mac from your iPhone and Apple Watch."
        case .sharing: "Who can watch or type in a pane you share."
        case .theme: "The colors of the whole window."
        case .terminal: "Text in the panes, and agent panes as a chat."
        case .shortcuts: "Keys for panes, splits and workspaces."
        case .privacy: "What stays on this Mac. Nothing leaves it."
        case .tour: "Walk through the welcome steps again."
        case .feedback: "Tell us what broke or what's missing."
        case .about: "Which XTermX this is."
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .notifications: "bell.badge"
        case .agents: "wand.and.stars"
        case .usage: "chart.pie"
        case .remoteAccess: "iphone.radiowaves.left.and.right"
        case .sharing: "person.2"
        case .theme: "swatchpalette"
        case .terminal: "chevron.left.forwardslash.chevron.right"
        case .shortcuts: "command"
        case .privacy: "lock.shield"
        case .tour: "map"
        case .feedback: "envelope"
        case .about: "seal"
        }
    }

    /// Fill of the section's icon tile; the window theme's own colors where it has one.
    func tint(_ theme: AppTheme) -> Color {
        switch self {
        case .general: StateColors.exited.color
        case .notifications: theme.chrome.destructive.color
        case .agents: .purple
        case .usage: theme.chrome.activity.color
        case .remoteAccess: theme.chrome.primary.color
        case .sharing: theme.chrome.broadcast.color
        case .theme: .pink
        case .terminal: StateColors.done.color
        case .shortcuts: .indigo
        case .privacy: .teal
        case .tour: .orange
        case .feedback: .mint
        case .about: StateColors.idle.color
        }
    }

    /// Titles of the options on the page, so the sidebar search finds a section by what's inside it.
    /// A page that gains an option adds its title here.
    var keywords: [String] {
        switch self {
        case .general: ["Interface language", "Your language", "Ready when you sign in", "Open at login", "Open Login Items", "Memory at a glance", "Show process memory in the title bar", "Received files", "Keep received files", "Remove expired files now"]
        case .notifications: ["Where each notice goes", "Done", "Needs you", "Plan limit", "Show notifications on this Mac",
                              "Telegram", "Bot token", "BotFather", "Find my chat", "Send test", "Slack", "Webhook"]
        case .agents: ["Installed agents", "Check again", "Let agents open panes", "Tool server", "MCP", "Separate agent branches", "Isolate agents in Git worktrees", "Review worktree"]
        case .usage: ["Day by day", "Tokens", "Cost", "Meters in the title bar", "How many", "Show first",
                      "Near the limit", "Plan limit", "Warn about Claude Code", "Warn about Codex"]
        case .remoteAccess: ["Connect", "Devices", "Advanced", "A link to this Mac", "Connect my phone",
                             "Beyond your Wi-Fi", "First address", "Refresh addresses", "Copy pairing link",
                             "Remote access", "Address", "Tailscale", "QR code", "Copy link",
                             "Forget all devices", "Let devices open new panes", "Connected devices", "What devices can do",
                             "Manage Control Rooms", "Receive files from devices", "Show received files",
                             "Pair with a password", "Generate password", "Password lifetime",
                             "Ask before opening terminals", "Trusted folders", "Remove trust", "Stay ready",
                             "Stay awake during remote viewing"]
        case .sharing: ["Shared panes", "View & control", "View only", "Private", "Remote access to this pane"]
        case .theme: ["Window theme", "Minimum terminal contrast", "Dim inactive panes", "Pane border", "Focused pane",
                      "Show message trails", "Use curved trails", "Trail pattern", "Trail width", "Trail color"] + AppTheme.presets.map(\.name)
        case .terminal: ["Font size", "Open agent panes as a chat", "Chat colors", "Copy when selecting text",
                         "Balance after adding a pane", "Balance when opening saved tabs", "Balance this tab now", "panes across", "panes down", "Speak into a pane", "Hold a key to dictate", "Hold key", "Right Option", "Speech language", "Apple speech service", "Manage Claude Code status line", "Claude status line"]
        case .tour: ["Welcome steps", "Show the welcome again", "Onboarding"]
        case .shortcuts: ["Your key combinations", "Change", "Restore all defaults", "Navigation and standard keys"]
        case .privacy: ["Keep local activity logs", "Remove activity after", "Review activity", "Clear activity", "Prepare diagnostic preview", "Save reviewed diagnostic"]
        case .feedback: ["Tell us what happened", "Short title", "Prepare diagnostic preview", "Save reviewed diagnostic", "Open issue draft in browser"]
        case .about: ["Version", "Build", "Copy version", "Project and releases", "Release notes and updates", "Project on GitHub"]
        default: []
        }
    }

    /// nil when the section doesn't match `query`; otherwise the option title that matched,
    /// or "" when the query is empty or the section's own name matched.
    func match(_ query: String) -> String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty || [title, subtitle].contains(where: { $0.localizedCaseInsensitiveContains(q) || InterfaceLanguage.current.text($0).localizedCaseInsensitiveContains(q) }) { return "" }
        return keywords.first { $0.localizedCaseInsensitiveContains(q) || InterfaceLanguage.current.text($0).localizedCaseInsensitiveContains(q) }
    }

    /// Sidebar groups, in order.
    static let groups: [(name: String, sections: [SettingsSection])] = [
        ("Essentials", [.general, .notifications]),
        ("Agents", [.agents, .usage]),
        ("Devices", [.remoteAccess, .sharing]),
        ("Look", [.theme, .terminal, .shortcuts]),
        ("Help", [.privacy, .tour, .feedback, .about]),
    ]
}

/// The Settings window (⌘, or Settings in the main sidebar): searchable sections on the left, one page of cards on the right.
struct SettingsView: View {
    @Environment(\.appTheme) private var theme
    /// Remembered so the window reopens on the page you left. Another view can write a raw value here before opening Settings.
    @AppStorage("xtermx.settings.section") private var stored = SettingsSection.general.rawValue

    private var selection: Binding<SettingsSection> {
        Binding(get: { SettingsSection(stored: stored) }, set: { stored = $0.rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: selection)
                .frame(width: 230)
            Divider().overlay(theme.chrome.border.color)
            ScrollView {
                page(selection.wrappedValue)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
            }
            .id(selection.wrappedValue)
            .background(theme.chrome.canvas.color)
        }
        .frame(width: 820, height: 580)
        .onAppear { stored = SettingsSection(stored: stored).rawValue }
    }

    @ViewBuilder private func page(_ section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralSettings()
        case .notifications: NotificationsSettings()
        case .agents: AgentsSettings()
        case .usage: UsageSettings()
        case .remoteAccess: RemoteAccessSettings()
        case .sharing: PaneSharingSettings()
        case .theme: ThemeSettings()
        case .terminal: TerminalSettings()
        case .tour: TourSettings()
        case .about: AboutSettings()
        case .privacy: PrivacySettings()
        case .shortcuts: ShortcutsSettings()
        case .feedback: FeedbackSettings()
        default: ComingSoonSettings(section: section)
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @State private var query = ""
    @Environment(\.appTheme) private var theme

    private struct Row: Identifiable {
        let section: SettingsSection
        /// The option title that matched the search, or "".
        let hint: String
        var id: SettingsSection { section }
    }

    private var results: [(name: String, rows: [Row])] {
        SettingsSection.groups.compactMap { group in
            let rows = group.sections.compactMap { s in s.match(query).map { Row(section: s, hint: $0) } }
            return rows.isEmpty ? nil : (group.name, rows)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSearchField(query: $query) {
                if let first = results.first?.rows.first { selection = first.section }
            }
            .padding(10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(results, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel(LocalizedStringKey(group.name))
                                .padding(.horizontal, 8)
                                .padding(.bottom, 4)
                            ForEach(group.rows) { row in
                                SettingsSidebarRow(section: row.section, hint: row.hint, selected: row.section == selection) {
                                    selection = row.section
                                }
                            }
                        }
                    }
                    if results.isEmpty {
                        Text("Nothing matches “\(query)”.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .background(theme.chrome.background.color)
    }
}

/// Search box at the top of the Settings sidebar; ↩ opens the first match.
private struct SettingsSearchField: View {
    @Binding var query: String
    var onSubmit: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.chrome.mutedForeground.color)
            TextField("Find a setting", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(onSubmit)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.chrome.input.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let hint: String
    let selected: Bool
    var action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SettingsTile(section: section, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(section.title))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(theme.chrome.foreground.color)
                    if !hint.isEmpty {
                        Text(LocalizedStringKey(hint))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.chrome.accent.color : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A section's SF Symbol on its colored rounded tile.
struct SettingsTile: View {
    let section: SettingsSection
    var size: CGFloat = 22
    @Environment(\.appTheme) private var theme

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(section.tint(theme).gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// A settings page: the section's tile, title and one line, then its cards.
struct SettingsPage<Content: View>: View {
    let section: SettingsSection
    @ViewBuilder var content: Content
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                SettingsTile(section: section, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(section.title)).font(.system(size: 20, weight: .semibold))
                    Text(LocalizedStringKey(section.subtitle)).font(.system(size: 12)).foregroundStyle(theme.chrome.mutedForeground.color)
                }
            }
            VStack(alignment: .leading, spacing: 12) { content }
        }
    }
}

/// One card on a settings page: a title, one sentence saying what it's for, then its controls.
struct SettingsCard<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content
    @Environment(\.appTheme) private var theme

    init(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.chrome.mutedForeground.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.chrome.border.color))
    }
}

/// A page whose story hasn't landed yet.
struct ComingSoonSettings: View {
    let section: SettingsSection

    var body: some View {
        SettingsPage(section: section) {
            SettingsCard("On the way", "This page comes with a later update.") { EmptyView() }
        }
    }
}
