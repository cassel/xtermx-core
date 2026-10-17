import AppKit
import SwiftUI
import XTermXHost
import XTermXKit

/// The welcome steps, in the order the rail lists them.
enum TourStep: Int, CaseIterable, Identifiable {
    case start, defaults, reach, inside

    var id: Int { rawValue }

    /// Name on the progress rail.
    var title: String {
        switch self {
        case .start: "Hello"
        case .defaults: "Defaults"
        case .reach: "Other screens"
        case .inside: "What's inside"
        }
    }

    /// One line under the name on the rail.
    var line: String {
        switch self {
        case .start: "Hooks for your agents"
        case .defaults: "Chat and notices"
        case .reach: "iPhone, Watch, machines"
        case .inside: "Everything it does today"
        }
    }

    var heading: String {
        switch self {
        case .start: "A terminal that keeps an eye on your agents"
        case .defaults: "Pick how agents show up"
        case .reach: "Reach this Mac from other screens"
        case .inside: "What's inside"
        }
    }

    var lead: String {
        switch self {
        case .start: "Run shells and coding agents side by side in split panes. XTermX shows what each agent is doing, asks you when one needs a decision, and lets you answer from your iPhone or Apple Watch."
        case .defaults: "Two defaults: what an agent pane looks like, and how you hear from one."
        case .reach: "Your iPhone and Apple Watch can drive this Mac, and this Mac can open terminals on your other machines."
        case .inside: "A short list to come back to. Everything here works today."
        }
    }
}

/// First-launch welcome (and Settings › Tour): a progress rail on the left, one step on the right.
/// Every control acts at once; Skip and Done only close the sheet.
struct TourSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("xtermx.onboarded") private var onboarded = false
    @State private var step = TourStep.start

    var body: some View {
        HStack(spacing: 0) {
            TourRail(step: $step)
                .frame(width: 214)
            Divider().overlay(theme.chrome.border.color)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LocalizedStringKey(step.heading)).font(.system(size: 20, weight: .semibold))
                            Text(LocalizedStringKey(step.lead))
                                .font(.system(size: 12))
                                .foregroundStyle(theme.chrome.mutedForeground.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if step == .start { InterfaceLanguagePicker() }
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 22)
                }
                .id(step)
                Divider().overlay(theme.chrome.border.color)
                footer
            }
            .background(theme.chrome.canvas.color)
        }
        .frame(width: 780, height: 540)
        .background(theme.chrome.background.color)
        .foregroundStyle(theme.chrome.foreground.color)
        .onDisappear { onboarded = true }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .start: TourStartStep()
        case .defaults: TourDefaultsStep()
        case .reach: TourReachStep()
        case .inside: TourInsideStep()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .inside {
                Button("Skip") { close() }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.chrome.mutedForeground.color)
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if let back = TourStep(rawValue: step.rawValue - 1) {
                Button("Back") { withAnimation(.easeOut(duration: 0.15)) { step = back } }
            }
            if let next = TourStep(rawValue: step.rawValue + 1) {
                Button("Continue") { withAnimation(.easeOut(duration: 0.15)) { step = next } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func close() {
        onboarded = true
        model.tourVisible = false
        dismiss()
    }
}

// MARK: - Rail

/// The steps as a vertical track: passed steps get a check, the current one a ring. Each one can be clicked.
private struct TourRail: View {
    @Binding var step: TourStep
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("XTermX").font(.system(size: 13, weight: .semibold))
                    Text("Four quick steps").font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)
                }
            }
            .padding(.bottom, 26)

            ForEach(TourStep.allCases) { s in
                Button { withAnimation(.easeOut(duration: 0.15)) { step = s } } label: {
                    HStack(alignment: .top, spacing: 11) {
                        VStack(spacing: 0) {
                            node(s)
                            if s != TourStep.allCases.last {
                                Rectangle()
                                    .fill(s.rawValue < step.rawValue ? theme.chrome.primary.color : theme.chrome.border.color)
                                    .frame(width: 2, height: 30)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(s.title))
                                .font(.system(size: 12, weight: s == step ? .semibold : .regular))
                                .foregroundStyle(s.rawValue > step.rawValue ? theme.chrome.mutedForeground.color : theme.chrome.foreground.color)
                            Text(LocalizedStringKey(s.line))
                                .font(.system(size: 10))
                                .foregroundStyle(theme.chrome.mutedForeground.color)
                        }
                        .padding(.top, 3)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
            Text("All of this is in Settings too, whenever you want to change it.")
                .font(.system(size: 10))
                .foregroundStyle(theme.chrome.mutedForeground.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.chrome.background.color)
    }

    @ViewBuilder private func node(_ s: TourStep) -> some View {
        let primary = theme.chrome.primary.color
        ZStack {
            if s.rawValue < step.rawValue {
                Circle().fill(primary)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            } else if s == step {
                Circle().fill(primary.opacity(0.18))
                Circle().strokeBorder(primary, lineWidth: 2)
                Circle().fill(primary).frame(width: 7, height: 7)
            } else {
                Circle().strokeBorder(theme.chrome.border.color, lineWidth: 1.5)
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Steps

private struct TourStartStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        let installed = model.manager.agents.filter(\.installed)
        SettingsCard("Agents on this Mac", installed.isEmpty
                     ? "No coding agents found yet. Install one and it shows up in the new-tab menu."
                     : "Found and ready to open in a pane.") {
            if !installed.isEmpty {
                FlowRow(items: installed) { agent in
                    HStack(spacing: 6) {
                        AgentIcon(agent, size: 16)
                        Text(agent.name).font(.system(size: 12)).lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(theme.chrome.muted.color, in: Capsule())
                }
            }
        }

        SettingsCard("Connect Claude Code and Codex",
                     "XTermX adds a few hooks to their settings, so each session reports its status, tokens and plan limits, and you can answer it from any device. Turning this off takes them out again.") {
            Toggle("Hooks for Claude Code & Codex", isOn: Binding(get: { model.agentHooksInstalled }, set: { model.setAgentHooks($0) }))
                .toggleStyle(.switch)
            if let note = model.agentHooksMessage {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.chrome.mutedForeground.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TourDefaultsStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @AppStorage("xtermx.settings.section") private var settingsSection = SettingsSection.general.rawValue
    /// "No thanks" was picked here; nothing is highlighted until one of the two is.
    @State private var saidNo = false

    var body: some View {
        @Bindable var model = model
        let notifier = model.notifier

        SettingsCard("Agent panes as a chat",
                     "New agent panes open as a conversation. The terminal keeps running underneath, one ⌘⇧C away.") {
            Toggle("Open agent panes as a chat", isOn: $model.chatViewByDefault)
                .toggleStyle(.switch)
        }

        SettingsCard("Banners on this Mac",
                     "A banner when an agent finishes or is waiting on you. macOS asks for permission only after you pick Yes.") {
            HStack(spacing: 8) {
                TourChoice(title: "Yes, show them", symbol: "bell", selected: notifier.macOn) {
                    saidNo = false
                    notifier.setMac(true)
                }
                TourChoice(title: "No thanks", symbol: "bell.slash", selected: saidNo && !notifier.macOn) {
                    saidNo = true
                    notifier.setMac(false)
                }
            }
            if let status = notifier.macStatus {
                Text(status.text)
                    .font(.system(size: 11))
                    .foregroundStyle(status.isError ? theme.chrome.destructive.color : theme.chrome.mutedForeground.color)
            }
        }

        SettingsCard("Away from the Mac",
                     "The same notices can go to Telegram or a Slack channel. Each takes a minute in Settings › Notifications.") {
            HStack(spacing: 8) {
                channelButton("Telegram", on: notifier.isOn(.telegram))
                channelButton("Slack", on: notifier.isOn(.slack))
            }
        }
    }

    private func channelButton(_ name: String, on: Bool) -> some View {
        Button {
            settingsSection = SettingsSection.notifications.rawValue
            openSettings()
        } label: {
            Label(on ? "\(name) is on" : "Set up \(name)", systemImage: on ? "checkmark.circle.fill" : "arrow.up.forward.app")
        }
    }
}

private struct TourReachStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var pairing = false
    @State private var adding = false

    var body: some View {
        let devices = model.server.devices.count
        SettingsCard("iPhone and Apple Watch",
                     "Scan a code with XTermX on iPhone; the Watch pairs through the phone. From there you see every pane and answer agents.") {
            HStack(spacing: 10) {
                Button { pairing = true } label: { Label("Show pairing code", systemImage: "qrcode") }
                    .popover(isPresented: $pairing, arrowEdge: .bottom) {
                        DevicesView().padding(14).frame(width: 300)
                    }
                if devices > 0 { note("\(devices) connected now") }
            }
        }

        let roomOpen = model.rightPanelVisible && model.rightTab == .controlRoom
        SettingsCard("Control Room",
                     "One conversation to message several agents at once and read what they send each other. It lives in the right panel.") {
            HStack(spacing: 10) {
                Button {
                    model.rightTab = .controlRoom
                    model.rightPanelVisible = true
                } label: { Label("Open Control Room", systemImage: "bubble.left.and.bubble.right") }
                    .disabled(roomOpen)
                if roomOpen { note("Open on the right") }
            }
        }

        let machines = model.machines.pairings.count
        SettingsCard("Other machines",
                     "Pair a Linux box (run xtermx pair there) or another Mac, and its terminals appear in the sidebar under Machines.") {
            HStack(spacing: 10) {
                Button { adding = true } label: { Label("Add a machine…", systemImage: "server.rack") }
                if machines > 0 { note(machines == 1 ? "1 machine paired" : "\(machines) machines paired") }
            }
        }
        .sheet(isPresented: $adding) { AddMachineSheet() }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(StateColors.done.color)
    }
}

private struct TourInsideStep: View {
    @Environment(\.appTheme) private var theme

    private struct Item: Identifiable {
        let symbol: String
        let tint: Color
        let title: String
        let line: String
        var id: String { title }
    }

    private var items: [Item] {
        [
            Item(symbol: "rectangle.split.2x1", tint: theme.chrome.primary.color, title: "Split panes",
                 line: "⌘D splits right, ⌘⇧D down; ⌃⇧ and an arrow moves a pane, ⌘P evens them out."),
            Item(symbol: "arrow.uturn.backward", tint: StateColors.done.color, title: "Back where you were",
                 line: "Tabs, splits and folders come back when the app opens again."),
            Item(symbol: "square.grid.2x2", tint: .teal, title: "Layouts for later",
                 line: "Save tabs, splits, folders and agents from File › Saved Layouts."),
            Item(symbol: "eye", tint: .teal, title: "Share on your terms",
                 line: "Each pane can stay private, be watched or accept remote input."),
            Item(symbol: "text.bubble", tint: .purple, title: "Chat view",
                 line: "Read an agent pane as a conversation; ⌘⇧C flips to the terminal."),
            Item(symbol: "hand.raised", tint: StateColors.blocked.color, title: "You approve",
                 line: "An agent that wants to open a pane asks first, here, on iPhone or on the Watch."),
            Item(symbol: "bubble.left.and.bubble.right", tint: theme.chrome.activity.color, title: "Control Room",
                 line: "Message several agents at once from the right panel."),
            Item(symbol: "dot.radiowaves.left.and.right", tint: theme.chrome.broadcast.color, title: "Broadcast",
                 line: "Type into every pane at once with ⌘⌥B."),
            Item(symbol: "rectangle.stack", tint: .indigo, title: "Quick switcher",
                 line: "⌃Tab steps through panes; let go of ⌃ to jump."),
            Item(symbol: "command", tint: .pink, title: "Command palette",
                 line: "⌘K finds any action or pane by name."),
            Item(symbol: "bell.badge", tint: theme.chrome.destructive.color, title: "Notices",
                 line: "Mac banners, Telegram or Slack when an agent is done or needs you."),
            Item(symbol: "network", tint: .cyan, title: "SSH and remote files",
                 line: "Connect saved hosts, transfer files and edit small text files beside the terminal."),
            Item(symbol: "arrow.triangle.branch", tint: .green, title: "Separate agent branches",
                 line: "Opt into a Git worktree for each agent, then review its work when the pane closes."),
            Item(symbol: "server.rack", tint: .teal, title: "Other machines",
                 line: "Terminals on your other computers, right in the sidebar."),
        ]
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)],
                  alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(item.title)).font(.system(size: 12, weight: .semibold))
                        Text(LocalizedStringKey(item.line))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.chrome.border.color))
            }
        }


    }
}

/// One of two answers, drawn as a tile that stays highlighted once picked.
private struct TourChoice: View {
    let title: String
    let symbol: String
    let selected: Bool
    var action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? theme.chrome.primary.color.opacity(0.18) : theme.chrome.muted.color,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? theme.chrome.primary.color : theme.chrome.border.color))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
