import SwiftUI
import XTermXHost
import XTermXKit

/// Settings › Notifications: a grid of where each notice goes, then one card per channel with its setup.
struct NotificationsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notifier = model.notifier
        SettingsPage(section: .notifications) {
            NoticeGridCard(notifier: notifier)
            MacNoticeCard(notifier: notifier)
            TelegramNoticeCard(notifier: notifier)
            SlackNoticeCard(notifier: notifier)
            WebhookNoticeCard(notifier: notifier)
            NtfyNoticeCard(notifier: notifier)
        }
        .task { await notifier.refreshMacPermission() }
    }
}

// MARK: - Where and when

extension NoticeChannel {
    var title: String {
        switch self {
        case .mac: "This Mac"
        case .telegram: "Telegram"
        case .slack: "Slack"
        case .webhook: "Webhook"
        case .ntfy: "ntfy"
        }
    }

    var symbol: String {
        switch self {
        case .mac: "macbook"
        case .telegram: "paperplane.fill"
        case .slack: "number"
        case .webhook: "point.3.connected.trianglepath.dotted"
        case .ntfy: "bell.badge.fill"
        }
    }

    func tint(_ theme: AppTheme) -> Color {
        switch self {
        case .mac: theme.chrome.primary.color
        case .telegram: .cyan
        case .slack: .purple
        case .webhook: .orange
        case .ntfy: .green
        }
    }
}

extension AgentNoticeEvent {
    /// Events with a switch on the page.
    static let shown: [AgentNoticeEvent] = [.finished, .needsYou, .planLimit, .commandFailed, .buildFinished, .serviceDown]

    var title: String {
        switch self {
        case .finished: "Done"
        case .needsYou: "Needs you"
        case .planLimit: "Plan limit"
        case .commandFailed: "Failed"
        case .buildFinished: "Build done"
        case .serviceDown: "Service down"
        }
    }

    var symbol: String {
        switch self {
        case .finished: "checkmark.seal.fill"
        case .needsYou: "hand.raised.fill"
        case .planLimit: "gauge.with.dots.needle.67percent"
        case .commandFailed: "xmark.octagon.fill"
        case .buildFinished: "hammer.fill"
        case .serviceDown: "heart.slash.fill"
        }
    }
}

/// Rows are channels, columns are events: one tap decides whether that kind of notice goes there.
private struct NoticeGridCard: View {
    let notifier: AgentNotifier
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard("Where each notice goes",
                     "Done: an agent wraps up after working 10 s or more. Needs you: a permission, a question or a prompt waits in a pane. Plan limit: a plan passes 90 %, once per window (Settings › Usage). Failed and Build done: a command that ran 30 s or more ends with an error, or cleanly (the shell needs prompt marks, OSC 133); they start off outside this Mac. Service down: a service in Settings › Services stops answering; also off outside this Mac at first. Nothing is sent about the pane you're looking at.") {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    ForEach(AgentNoticeEvent.shown, id: \.self) { event in
                        VStack(spacing: 3) {
                            Image(systemName: event.symbol).font(.system(size: 11))
                            Text(LocalizedStringKey(event.title)).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(theme.chrome.mutedForeground.color)
                        .frame(width: 70)
                        .gridColumnAlignment(.center)
                    }
                }
                ForEach(NoticeChannel.allCases) { channel in
                    GridRow {
                        HStack(spacing: 10) {
                            ChannelBadge(channel: channel)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(LocalizedStringKey(channel.title)).font(.system(size: 12, weight: .medium))
                                Text(LocalizedStringKey(state(channel)))
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.chrome.mutedForeground.color)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(AgentNoticeEvent.shown, id: \.self) { event in
                            EventCell(event: event, tint: channel.tint(theme), enabled: notifier.isOn(channel),
                                      isOn: Binding(get: { notifier.wants(channel, event) },
                                                    set: { notifier.setWants(channel, event, $0) }))
                                .frame(width: 70)
                        }
                    }
                }
            }
        }
    }

    private func state(_ channel: NoticeChannel) -> String {
        if notifier.isOn(channel) { return "On" }
        switch channel {
        case .mac: return "Off"
        case .telegram: return notifier.telegramHasToken && notifier.telegramChat != nil ? "Off" : "Not set up"
        case .slack: return notifier.slackHasWebhook ? "Off" : "Not set up"
        case .webhook: return notifier.webhookHasURL ? "Off" : "Not set up"
        case .ntfy: return notifier.ntfyHasTopic ? "Off" : "Not set up"
        }
    }
}

private struct ChannelBadge: View {
    let channel: NoticeChannel
    @Environment(\.appTheme) private var theme

    var body: some View {
        Image(systemName: channel.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(channel.tint(theme).gradient, in: Circle())
    }
}

/// One cell of the grid: a dot that fills with the channel's color when that event goes there.
private struct EventCell: View {
    let event: AgentNoticeEvent
    let tint: Color
    let enabled: Bool
    @Binding var isOn: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        let lit = isOn && enabled
        Button { isOn.toggle() } label: {
            Image(systemName: isOn ? "checkmark" : "minus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(lit ? Color.white : theme.chrome.mutedForeground.color)
                .frame(width: 26, height: 22)
                .background(lit ? AnyShapeStyle(tint.opacity(0.85)) : AnyShapeStyle(theme.chrome.input.color), in: Capsule())
                .overlay(Capsule().stroke(lit ? .clear : theme.chrome.border.color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(Text(LocalizedStringKey(event.title)))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .help(enabled ? (isOn ? "Stop sending “\(event.title)” here" : "Send “\(event.title)” here") : "Turn this channel on first")
    }
}

// MARK: - This Mac

private struct MacNoticeCard: View {
    let notifier: AgentNotifier

    var body: some View {
        SettingsCard("This Mac", "Banners in the corner of the screen. Click one to jump to its pane.") {
            Toggle("Show notifications on this Mac", isOn: Binding(get: { notifier.macOn }, set: { notifier.setMac($0) }))
                .toggleStyle(.switch)
            HStack(spacing: 8) {
                Button("Send a test") { notifier.sendMacTest() }.disabled(!notifier.macOn)
                if notifier.macDenied {
                    Button("Open System Settings") { notifier.openSystemNotificationSettings() }
                }
            }
            NoticeStatusLine(status: notifier.macStatus)
        }
    }
}

// MARK: - Telegram

private struct TelegramNoticeCard: View {
    let notifier: AgentNotifier
    @State private var token = ""
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard("Telegram", "Notices on your phone from a bot of your own. The token stays in this Mac's Keychain.") {
            VStack(alignment: .leading, spacing: 0) {
                SetupStep(number: 1, title: "Make a bot", done: notifier.telegramHasToken) {
                    if notifier.telegramHasToken {
                        HStack {
                            Text(notifier.telegramBot ?? "Bot saved").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button("Remove", role: .destructive) { notifier.removeTelegram() }
                        }
                    } else {
                        hint("In Telegram, open @BotFather, send /newbot and paste the token it gives you.")
                        HStack {
                            SecureField("Bot token", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(save)
                            Button("Check", action: save)
                                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || notifier.telegramBusy)
                        }
                    }
                }
                SetupStep(number: 2, title: "Link your chat", done: notifier.telegramChat != nil, enabled: notifier.telegramHasToken) {
                    if let chat = notifier.telegramChat {
                        HStack {
                            Text(chat.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button("Find again") { Task { await notifier.findTelegramChat() } }.disabled(notifier.telegramBusy)
                        }
                    } else {
                        hint("Send \(notifier.telegramBot ?? "the bot") any message, then look for it here.")
                        Button("Find my chat") { Task { await notifier.findTelegramChat() } }
                            .disabled(!notifier.telegramHasToken || notifier.telegramBusy)
                    }
                    if !notifier.telegramChoices.isEmpty {
                        ForEach(notifier.telegramChoices) { chat in
                            Button { notifier.chooseTelegramChat(chat) } label: {
                                Label(chat.name, systemImage: chat.id < 0 ? "person.3" : "person")
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                SetupStep(number: 3, title: "Try it", done: false, last: true, enabled: notifier.telegramChat != nil) {
                    HStack {
                        Button("Send test") { Task { await notifier.sendTelegramTest() } }
                            .disabled(notifier.telegramChat == nil || notifier.telegramBusy)
                        Spacer()
                        Toggle("Send notices", isOn: Binding(get: { notifier.telegramOn }, set: { notifier.telegramOn = $0 }))
                            .toggleStyle(.switch)
                            .disabled(notifier.telegramChat == nil)
                    }
                }
            }
            HStack(spacing: 6) {
                if notifier.telegramBusy { ProgressView().controlSize(.small) }
                NoticeStatusLine(status: notifier.telegramStatus)
            }
        }
    }

    private func save() {
        let value = token
        Task {
            await notifier.saveTelegramToken(value)
            if notifier.telegramHasToken { token = "" }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(theme.chrome.mutedForeground.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Slack

private struct SlackNoticeCard: View {
    let notifier: AgentNotifier
    @State private var address = ""
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard("Slack", "Notices posted to a channel through an Incoming Webhook. The address stays in this Mac's Keychain.") {
            VStack(alignment: .leading, spacing: 0) {
                SetupStep(number: 1, title: "Add a webhook", done: notifier.slackHasWebhook) {
                    if notifier.slackHasWebhook {
                        HStack {
                            Text("Webhook saved").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button("Remove", role: .destructive) { notifier.removeSlack() }
                        }
                    } else {
                        Text("In Slack, add Incoming Webhooks to a channel and paste the address it shows.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            SecureField("https://hooks.slack.com/services/…", text: $address)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(save)
                            Button("Save", action: save).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                SetupStep(number: 2, title: "Try it", done: false, last: true, enabled: notifier.slackHasWebhook) {
                    HStack {
                        Button("Send test") { Task { await notifier.sendSlackTest() } }
                            .disabled(!notifier.slackHasWebhook || notifier.slackBusy)
                        Spacer()
                        Toggle("Send notices", isOn: Binding(get: { notifier.slackOn }, set: { notifier.slackOn = $0 }))
                            .toggleStyle(.switch)
                            .disabled(!notifier.slackHasWebhook)
                    }
                }
            }
            HStack(spacing: 6) {
                if notifier.slackBusy { ProgressView().controlSize(.small) }
                NoticeStatusLine(status: notifier.slackStatus)
            }
        }
    }

    private func save() {
        notifier.saveSlackWebhook(address)
        if notifier.slackHasWebhook { address = "" }
    }
}

// MARK: - Webhook

private struct WebhookNoticeCard: View {
    let notifier: AgentNotifier
    @State private var address = ""
    @State private var header = ""
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard("Webhook", "Each notice POSTed as JSON to an address of yours: event, title, body, paneID, host, time. The address and header stay in this Mac's Keychain.") {
            VStack(alignment: .leading, spacing: 0) {
                SetupStep(number: 1, title: "Add an address", done: notifier.webhookHasURL) {
                    if notifier.webhookHasURL {
                        HStack {
                            Text(notifier.webhookHost ?? "Webhook saved").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button("Remove", role: .destructive) { notifier.removeWebhook() }
                        }
                    } else {
                        Text("Home Assistant, n8n, Zapier or your own server. Add a header if it wants a key.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                            .fixedSize(horizontal: false, vertical: true)
                        SecureField("https://example.com/hooks/xtermx", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                        HStack {
                            SecureField("Header (optional), e.g. Authorization: Bearer …", text: $header)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(save)
                            Button("Save", action: save).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                SetupStep(number: 2, title: "Try it", done: false, last: true, enabled: notifier.webhookHasURL) {
                    HStack {
                        Button("Send test") { Task { await notifier.sendWebhookTest() } }
                            .disabled(!notifier.webhookHasURL || notifier.webhookBusy)
                        Spacer()
                        Toggle("Send notices", isOn: Binding(get: { notifier.webhookOn }, set: { notifier.webhookOn = $0 }))
                            .toggleStyle(.switch)
                            .disabled(!notifier.webhookHasURL)
                    }
                }
            }
            HStack(spacing: 6) {
                if notifier.webhookBusy { ProgressView().controlSize(.small) }
                NoticeStatusLine(status: notifier.webhookStatus)
            }
        }
    }

    private func save() {
        notifier.saveWebhook(address, header: header)
        if notifier.webhookHasURL { address = ""; header = "" }
    }
}

// MARK: - ntfy

private struct NtfyNoticeCard: View {
    let notifier: AgentNotifier
    @State private var server = ""
    @State private var topic = ""
    @State private var token = ""
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsCard("ntfy", "Push notices to the ntfy app on any phone, through ntfy.sh or a server of your own. The topic and token stay in this Mac's Keychain.") {
            VStack(alignment: .leading, spacing: 0) {
                SetupStep(number: 1, title: "Pick a topic", done: notifier.ntfyHasTopic) {
                    if notifier.ntfyHasTopic {
                        HStack {
                            Text(notifier.ntfyLabel ?? "Topic saved").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button("Remove", role: .destructive) { notifier.removeNtfy() }
                        }
                    } else {
                        Text("Anyone who knows a topic on ntfy.sh can read it: make it long and hard to guess, and subscribe to it in the ntfy app.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("Server (blank for ntfy.sh)", text: $server)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            SecureField("Topic", text: $topic)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(save)
                            Button("Make one") { topic = "xtermx-" + UUID().uuidString.lowercased().prefix(13).replacingOccurrences(of: "-", with: "") }
                        }
                        HStack {
                            SecureField("Access token (optional)", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(save)
                            Button("Save", action: save).disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                SetupStep(number: 2, title: "Try it", done: false, last: true, enabled: notifier.ntfyHasTopic) {
                    HStack {
                        Button("Send test") { Task { await notifier.sendNtfyTest() } }
                            .disabled(!notifier.ntfyHasTopic || notifier.ntfyBusy)
                        Spacer()
                        Toggle("Send notices", isOn: Binding(get: { notifier.ntfyOn }, set: { notifier.ntfyOn = $0 }))
                            .toggleStyle(.switch)
                            .disabled(!notifier.ntfyHasTopic)
                    }
                }
            }
            HStack(spacing: 6) {
                if notifier.ntfyBusy { ProgressView().controlSize(.small) }
                NoticeStatusLine(status: notifier.ntfyStatus)
            }
        }
    }

    private func save() {
        notifier.saveNtfy(server: server, topic: topic, token: token)
        if notifier.ntfyHasTopic { server = ""; topic = ""; token = "" }
    }
}

// MARK: - Pieces

/// One step of a channel's setup: a numbered dot on a rail, its title, then its controls.
private struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    var last = false
    var enabled = true
    @ViewBuilder var content: Content
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(done ? StateColors.done.color : theme.chrome.input.color)
                    Circle().stroke(done ? .clear : theme.chrome.border.color)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.chrome.foreground.color)
                    }
                }
                .frame(width: 20, height: 20)
                if !last {
                    Rectangle().fill(theme.chrome.border.color).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                content
            }
            .padding(.bottom, last ? 0 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(enabled ? 1 : 0.55)
    }
}

private struct NoticeStatusLine: View {
    let status: ChannelStatus?
    @Environment(\.appTheme) private var theme

    var body: some View {
        if let status {
            Label(status.text, systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(status.isError ? theme.chrome.destructive.color : theme.chrome.mutedForeground.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
