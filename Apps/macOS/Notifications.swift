import AppKit
import Observation
import Security
import UserNotifications
import XTermXHost
import XTermXKit

/// Where notices go.
enum NoticeChannel: String, CaseIterable, Identifiable {
    case mac, telegram, slack, webhook, ntfy
    var id: String { rawValue }
}

/// Channel secrets (the Telegram bot token, the Slack and generic webhook addresses and header), in the Keychain like `PairingStore`.
enum NoticeSecrets {
    private static let service = "XTermX.notifications"
    static let telegramToken = "telegram.token"
    static let slackWebhook = "slack.webhook"
    static let webhookURL = "webhook.url"
    static let webhookHeader = "webhook.header"
    static let ntfyTopic = "ntfy.topic"
    static let ntfyToken = "ntfy.token"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// A line under a channel's controls: how the last step went.
struct ChannelStatus: Equatable {
    var text: String
    var isError: Bool

    static func ok(_ text: String) -> ChannelStatus { ChannelStatus(text: text, isError: false) }
    static func failed(_ error: Error) -> ChannelStatus {
        ChannelStatus(text: (error as? LocalizedError)?.errorDescription ?? "That didn't work.", isError: true)
    }
}

/// Tells the person when an agent is done or needs them: Mac notifications, Telegram, Slack, a webhook.
/// Which changes count lives in `AgentNoticeWatcher`; this sends them where the person chose.
@MainActor
@Observable
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    private enum Key {
        static let mac = "xtermx.notify.mac"
        static let telegram = "xtermx.notify.telegram"
        static let slack = "xtermx.notify.slack"
        static let webhook = "xtermx.notify.webhook"
        static let ntfy = "xtermx.notify.ntfy"
        static let ntfyServer = "xtermx.notify.ntfy.server"
        /// E4.4's list of turned-off pairs; read once to migrate into `matrix`.
        static let muted = "xtermx.notify.muted"
        static let matrix = "xtermx.notify.matrix"
        static let bot = "xtermx.notify.telegram.bot"
        static let chatID = "xtermx.notify.telegram.chatID"
        static let chatName = "xtermx.notify.telegram.chatName"
    }

    /// Focuses a pane when its Mac notification is clicked.
    @ObservationIgnored var onOpen: ((String) -> Void)?
    /// True when the person is looking at the pane already (app active, pane focused): nothing is sent.
    @ObservationIgnored var isOnScreen: (String?) -> Bool = { _ in false }
    /// Named in the test message.
    @ObservationIgnored var hostName = "this Mac"
    @ObservationIgnored private var watcher = AgentNoticeWatcher()
    @ObservationIgnored private var dueTask: Task<Void, Never>?
    @ObservationIgnored private var telegramToken: String?
    @ObservationIgnored private var slackAddress: String?
    @ObservationIgnored private var webhookAddress: String?
    @ObservationIgnored private var webhookHeader: String?
    @ObservationIgnored private var ntfyTopicName: String?
    @ObservationIgnored private var ntfyToken: String?
    private let defaults = UserDefaults.standard

    // MARK: Switches

    private(set) var macOn: Bool { didSet { defaults.set(macOn, forKey: Key.mac) } }
    /// The system said no to notifications for XTermX.
    private(set) var macDenied = false
    var telegramOn: Bool { didSet { defaults.set(telegramOn, forKey: Key.telegram) } }
    var slackOn: Bool { didSet { defaults.set(slackOn, forKey: Key.slack) } }
    var webhookOn: Bool { didSet { defaults.set(webhookOn, forKey: Key.webhook) } }
    var ntfyOn: Bool { didSet { defaults.set(ntfyOn, forKey: Key.ntfy) } }
    /// Which events go to which channel (only the person's own choices are stored).
    private var matrix: NoticeMatrix { didSet { defaults.set(matrix.choices, forKey: Key.matrix) } }

    // MARK: Telegram

    private(set) var telegramBot: String? { didSet { defaults.set(telegramBot, forKey: Key.bot) } }
    private(set) var telegramChat: TelegramBot.Chat? {
        didSet {
            defaults.set(telegramChat.map { String($0.id) }, forKey: Key.chatID)
            defaults.set(telegramChat?.name, forKey: Key.chatName)
        }
    }
    /// Several chats wrote to the bot: the person picks one.
    var telegramChoices: [TelegramBot.Chat] = []
    var telegramStatus: ChannelStatus?
    var telegramBusy = false
    var telegramHasToken: Bool { telegramToken != nil }

    // MARK: Slack

    private(set) var slackHasWebhook = false
    var slackStatus: ChannelStatus?
    var slackBusy = false
    var macStatus: ChannelStatus?

    // MARK: Webhook

    private(set) var webhookHasURL = false
    /// The saved address's host, to show which one is set without showing the secret path.
    var webhookHost: String? { webhookAddress.flatMap { URL(string: $0)?.host } }
    var webhookStatus: ChannelStatus?
    var webhookBusy = false

    // MARK: ntfy

    /// Empty means ntfy.sh. Not a secret; the topic is.
    private(set) var ntfyServer: String { didSet { defaults.set(ntfyServer, forKey: Key.ntfyServer) } }
    var ntfyHasTopic: Bool { ntfyTopicName != nil }
    /// "ntfy.sh · alerts…": enough to recognise the topic without showing all of it.
    var ntfyLabel: String? {
        guard let topic = ntfyTopicName, let t = NtfyTopic(server: ntfyServer, topic: topic) else { return nil }
        return "\(t.url.host ?? "ntfy") · \(topic.prefix(4))…"
    }
    var ntfyStatus: ChannelStatus?
    var ntfyBusy = false

    override init() {
        let d = UserDefaults.standard
        macOn = d.bool(forKey: Key.mac)
        telegramOn = d.bool(forKey: Key.telegram)
        slackOn = d.bool(forKey: Key.slack)
        webhookOn = d.bool(forKey: Key.webhook)
        ntfyOn = d.bool(forKey: Key.ntfy)
        ntfyServer = d.string(forKey: Key.ntfyServer) ?? ""
        if let choices = d.dictionary(forKey: Key.matrix) as? [String: Bool] {
            matrix = NoticeMatrix(choices: choices)
        } else {
            let migrated = NoticeMatrix.migrating(muted: d.stringArray(forKey: Key.muted) ?? [])
            matrix = migrated
            d.set(migrated.choices, forKey: Key.matrix)
            d.removeObject(forKey: Key.muted)
        }
        telegramBot = d.string(forKey: Key.bot)
        if let id = d.string(forKey: Key.chatID).flatMap(Int64.init), let name = d.string(forKey: Key.chatName) {
            telegramChat = TelegramBot.Chat(id: id, name: name)
        }
        telegramToken = NoticeSecrets.read(NoticeSecrets.telegramToken)
        slackAddress = NoticeSecrets.read(NoticeSecrets.slackWebhook)
        slackHasWebhook = slackAddress != nil
        webhookAddress = NoticeSecrets.read(NoticeSecrets.webhookURL)
        webhookHeader = NoticeSecrets.read(NoticeSecrets.webhookHeader)
        webhookHasURL = webhookAddress != nil
        ntfyTopicName = NoticeSecrets.read(NoticeSecrets.ntfyTopic)
        ntfyToken = NoticeSecrets.read(NoticeSecrets.ntfyToken)
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let firstRun = d.object(forKey: Key.mac) == nil
        Task { await refreshMacPermission(adoptingGrant: firstRun) }
    }

    // MARK: Choices

    func wants(_ channel: NoticeChannel, _ event: AgentNoticeEvent) -> Bool {
        matrix.wants(channel.rawValue, event)
    }

    func setWants(_ channel: NoticeChannel, _ event: AgentNoticeEvent, _ on: Bool) {
        matrix.set(channel.rawValue, event, on)
    }

    func isOn(_ channel: NoticeChannel) -> Bool {
        switch channel {
        case .mac: macOn
        case .telegram: telegramOn && telegramHasToken && telegramChat != nil
        case .slack: slackOn && slackHasWebhook
        case .webhook: webhookOn && webhookHasURL
        case .ntfy: ntfyOn && ntfyHasTopic
        }
    }

    /// Mac notifications: asks the system the first time they're turned on.
    func setMac(_ on: Bool) {
        guard on else { macOn = false; macStatus = nil; return }
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            await refreshMacPermission(adoptingGrant: false)
            macOn = granted
            macStatus = granted ? nil : ChannelStatus(text: "macOS has notifications off for XTermX.", isError: true)
        }
    }

    /// Whether the system allows notifications. The first time this runs, a permission granted
    /// before notifications were a setting counts as having them on.
    func refreshMacPermission(adoptingGrant: Bool = false) async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let allowed = status == .authorized || status == .provisional
        macDenied = status == .denied
        if adoptingGrant { macOn = allowed }
        if macOn, macDenied { macStatus = ChannelStatus(text: "macOS has notifications off for XTermX.", isError: true) }
    }

    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Events

    func paneUpdated(_ pane: PaneInfo, agentName: String?) {
        deliver(watcher.paneUpdated(pane, agentName: agentName))
        scheduleHeld()
    }

    func approvalsChanged(_ cards: [ApprovalRequest], pane: (String) -> PaneInfo?, agentName: (PaneInfo) -> String?) {
        deliver(watcher.approvalsChanged(cards, pane: pane, agentName: agentName))
        scheduleHeld()
    }

    func forget(_ paneID: String) {
        watcher.forget(paneID)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [paneID])
    }

    /// A notice from elsewhere in the app (plan limits).
    func post(_ notice: AgentNotice) { deliver([notice]) }

    private func scheduleHeld() {
        dueTask?.cancel()
        guard let next = watcher.nextDue else { return }
        dueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.deliver(self.watcher.due())
            self.scheduleHeld()
        }
    }

    private func deliver(_ notices: [AgentNotice]) {
        for notice in notices where !isOnScreen(notice.paneID) {
            if isOn(.mac), wants(.mac, notice.event) { showOnMac(notice) }
            if isOn(.telegram), wants(.telegram, notice.event) { Task { await sendTelegram(notice, isTest: false) } }
            if isOn(.slack), wants(.slack, notice.event) { Task { await sendSlack(notice, isTest: false) } }
            if isOn(.webhook), wants(.webhook, notice.event) { Task { await sendWebhook(notice, isTest: false) } }
            if isOn(.ntfy), wants(.ntfy, notice.event) { Task { await sendNtfy(notice, isTest: false) } }
        }
    }

    private func showOnMac(_ notice: AgentNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        if let pane = notice.paneID {
            content.userInfo = ["pane": pane]
            content.threadIdentifier = pane
        }
        // One per pane: a newer notice replaces the older one in Notification Center.
        let id = notice.paneID ?? notice.id
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func sendMacTest() {
        guard macOn else { return }
        showOnMac(AgentNoticeText.test(from: hostName))
    }

    // MARK: Telegram setup

    /// Checks the token with Telegram, then keeps it in the Keychain.
    func saveTelegramToken(_ raw: String) async {
        guard let bot = TelegramBot(token: raw) else { telegramStatus = .failed(NoticeChannelError.badToken); return }
        telegramBusy = true
        defer { telegramBusy = false }
        do {
            let name = try TelegramBot.botName(try await NoticeDelivery.perform(bot.getMe()))
            NoticeSecrets.write(NoticeSecrets.telegramToken, bot.token)
            telegramToken = bot.token
            telegramBot = name
            telegramChat = nil
            telegramChoices = []
            telegramStatus = .ok("Token works. Now send \(name) any message in Telegram.")
        } catch {
            telegramStatus = .failed(error)
        }
    }

    /// Looks for the chat that wrote to the bot last.
    func findTelegramChat() async {
        guard let bot = telegramToken.flatMap(TelegramBot.init(token:)) else { return }
        telegramBusy = true
        defer { telegramBusy = false }
        do {
            let chats = try TelegramBot.chats(try await NoticeDelivery.perform(bot.getUpdates()))
            if chats.count == 1 {
                chooseTelegramChat(chats[0])
            } else {
                telegramChoices = chats.reversed()
                telegramStatus = .ok("Several chats wrote to the bot. Pick yours.")
            }
        } catch {
            telegramStatus = .failed(error)
        }
    }

    func chooseTelegramChat(_ chat: TelegramBot.Chat) {
        telegramChat = chat
        telegramChoices = []
        telegramOn = true
        telegramStatus = .ok("Linked to \(chat.name). Send a test to be sure.")
    }

    func sendTelegramTest() async { await sendTelegram(AgentNoticeText.test(from: hostName), isTest: true) }

    func removeTelegram() {
        NoticeSecrets.write(NoticeSecrets.telegramToken, nil)
        telegramToken = nil
        telegramBot = nil
        telegramChat = nil
        telegramChoices = []
        telegramOn = false
        telegramStatus = nil
    }

    private func sendTelegram(_ notice: AgentNotice, isTest: Bool) async {
        guard let bot = telegramToken.flatMap(TelegramBot.init(token:)), let chat = telegramChat else { return }
        if isTest { telegramBusy = true }
        defer { if isTest { telegramBusy = false } }
        do {
            try TelegramBot.checkSent(try await NoticeDelivery.perform(bot.sendMessage(chatID: chat.id, text: notice.text)))
            if isTest || telegramStatus?.isError == true { telegramStatus = .ok("Sent to \(chat.name).") }
        } catch {
            telegramStatus = isTest ? .failed(error) : ChannelStatus(text: "Last notice didn't go through: \(ChannelStatus.failed(error).text)", isError: true)
        }
    }

    // MARK: Slack setup

    func saveSlackWebhook(_ raw: String) {
        guard let hook = SlackWebhook(raw) else { slackStatus = .failed(NoticeChannelError.badWebhook); return }
        NoticeSecrets.write(NoticeSecrets.slackWebhook, hook.url.absoluteString)
        slackAddress = hook.url.absoluteString
        slackHasWebhook = true
        slackOn = true
        slackStatus = .ok("Saved. Send a test to be sure.")
    }

    func sendSlackTest() async { await sendSlack(AgentNoticeText.test(from: hostName), isTest: true) }

    func removeSlack() {
        NoticeSecrets.write(NoticeSecrets.slackWebhook, nil)
        slackAddress = nil
        slackHasWebhook = false
        slackOn = false
        slackStatus = nil
    }

    private func sendSlack(_ notice: AgentNotice, isTest: Bool) async {
        guard let hook = slackAddress.flatMap(SlackWebhook.init) else { return }
        if isTest { slackBusy = true }
        defer { if isTest { slackBusy = false } }
        do {
            _ = try await NoticeDelivery.perform(hook.post(notice))
            if isTest || slackStatus?.isError == true { slackStatus = .ok("Sent. Check the channel.") }
        } catch {
            slackStatus = isTest ? .failed(error) : ChannelStatus(text: "Last notice didn't go through: \(ChannelStatus.failed(error).text)", isError: true)
        }
    }

    // MARK: Webhook setup

    /// Keeps the address and the optional "Name: value" header in the Keychain.
    func saveWebhook(_ address: String, header: String) {
        guard GenericWebhook(address) != nil else { webhookStatus = .failed(NoticeChannelError.badAddress); return }
        guard let hook = GenericWebhook(address, header: header) else {
            webhookStatus = .failed(NoticeChannelError.badHeader)
            return
        }
        let line = hook.header.map { "\($0.name): \($0.value)" }
        NoticeSecrets.write(NoticeSecrets.webhookURL, hook.url.absoluteString)
        NoticeSecrets.write(NoticeSecrets.webhookHeader, line)
        webhookAddress = hook.url.absoluteString
        webhookHeader = line
        webhookHasURL = true
        webhookOn = true
        webhookStatus = .ok("Saved. Send a test to be sure.")
    }

    func sendWebhookTest() async { await sendWebhook(AgentNoticeText.test(from: hostName), isTest: true) }

    func removeWebhook() {
        NoticeSecrets.write(NoticeSecrets.webhookURL, nil)
        NoticeSecrets.write(NoticeSecrets.webhookHeader, nil)
        webhookAddress = nil
        webhookHeader = nil
        webhookHasURL = false
        webhookOn = false
        webhookStatus = nil
    }

    private func sendWebhook(_ notice: AgentNotice, isTest: Bool) async {
        guard let hook = webhookAddress.flatMap({ GenericWebhook($0, header: webhookHeader) }) else { return }
        if isTest { webhookBusy = true }
        defer { if isTest { webhookBusy = false } }
        let request = hook.post(notice, host: hostName)
        do {
            // A 10 s timeout, then one more try.
            _ = try await NoticeDelivery.retrying { try await NoticeDelivery.perform(request) }
            if isTest || webhookStatus?.isError == true { webhookStatus = .ok("Sent. The server said OK.") }
        } catch {
            webhookStatus = isTest ? .failed(error) : ChannelStatus(text: "Last notice didn't go through: \(ChannelStatus.failed(error).text)", isError: true)
        }
    }

    // MARK: ntfy setup

    func saveNtfy(server: String, topic: String, token: String) {
        guard let t = NtfyTopic(server: server, topic: topic, token: token) else {
            let serverOK = NtfyTopic(server: server, topic: "x") != nil
            ntfyStatus = .failed(serverOK ? NoticeChannelError.badTopic : NoticeChannelError.badAddress)
            return
        }
        let name = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        ntfyServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        NoticeSecrets.write(NoticeSecrets.ntfyTopic, name)
        NoticeSecrets.write(NoticeSecrets.ntfyToken, t.token)
        ntfyTopicName = name
        ntfyToken = t.token
        ntfyOn = true
        ntfyStatus = .ok("Saved. Subscribe to the topic in the ntfy app, then send a test.")
    }

    func sendNtfyTest() async { await sendNtfy(AgentNoticeText.test(from: hostName), isTest: true) }

    func removeNtfy() {
        NoticeSecrets.write(NoticeSecrets.ntfyTopic, nil)
        NoticeSecrets.write(NoticeSecrets.ntfyToken, nil)
        ntfyTopicName = nil
        ntfyToken = nil
        ntfyServer = ""
        ntfyOn = false
        ntfyStatus = nil
    }

    private func sendNtfy(_ notice: AgentNotice, isTest: Bool) async {
        guard let topic = ntfyTopicName.flatMap({ NtfyTopic(server: ntfyServer, topic: $0, token: ntfyToken) }) else { return }
        if isTest { ntfyBusy = true }
        defer { if isTest { ntfyBusy = false } }
        let request = topic.post(notice)
        do {
            _ = try await NoticeDelivery.retrying { try await NoticeDelivery.perform(request) }
            if isTest || ntfyStatus?.isError == true { ntfyStatus = .ok("Sent. Check the ntfy app.") }
        } catch {
            ntfyStatus = isTest ? .failed(error) : ChannelStatus(text: "Last notice didn't go through: \(ChannelStatus.failed(error).text)", isError: true)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners while XTermX is in front too; a notice for the pane in view is never posted.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let pane = response.notification.request.content.userInfo["pane"] as? String
        await MainActor.run {
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
            if let pane { self.onOpen?(pane) }
        }
    }
}
