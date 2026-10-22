import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XTermXKit

// MARK: - Events and their text

/// Something worth telling the person while they look elsewhere. Every channel (Mac, Telegram, Slack) gets the same ones.
public enum AgentNoticeEvent: String, Codable, Sendable, CaseIterable {
    /// An agent finished a turn it worked on for a while.
    case finished
    /// An agent waits for the person: a permission, a question, a prompt in the terminal.
    case needsYou
    /// A plan is nearly used up (posted by the plan meters).
    case planLimit
    /// A command (a pane that isn't an agent) ran a while and exited with a code other than 0.
    case commandFailed
    /// A command ran a while and exited cleanly: a build, a test run, a long copy.
    case buildFinished
    /// A service the Mac checks stopped answering (Settings › Services).
    case serviceDown
}

/// One notice, ready for any channel.
public struct AgentNotice: Sendable, Hashable, Identifiable {
    /// Unique per occurrence; the Mac uses it as the notification's identifier.
    public var id: String
    public var event: AgentNoticeEvent
    /// The pane it is about; clicking the Mac notification focuses it.
    public var paneID: String?
    public var title: String
    public var body: String

    public init(id: String = UUID().uuidString, event: AgentNoticeEvent, paneID: String?, title: String, body: String) {
        self.id = id
        self.event = event
        self.paneID = paneID
        self.title = title
        self.body = body
    }

    /// Title over body, for chat channels.
    public var text: String { body.isEmpty ? title : title + "\n" + body }
}

/// The words of each notice: who, what happened, where.
public enum AgentNoticeText {
    /// "web · ~/app/web", or just the folder when the pane is named after it.
    public static func place(_ pane: PaneInfo) -> String {
        let path = pane.agentSession?.cwd ?? pane.cwd
        let folder = tildePath(path)
        let name = (pane.customName ?? pane.title).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == (path as NSString).lastPathComponent || name == folder { return folder }
        return "\(name) · \(folder)"
    }

    /// The agent's name: its session's tool, else the catalog name the caller knows, else the pane's title.
    public static func agent(_ pane: PaneInfo?, fallback: String?) -> String {
        pane?.agentSession?.tool.name ?? fallback ?? pane?.title ?? "An agent"
    }

    public static func finished(_ pane: PaneInfo, agent: String, worked: TimeInterval) -> AgentNotice {
        var lines: [String] = []
        if let task = pane.agentSession?.title.map(clip(80)), !task.isEmpty { lines.append(task) }
        lines.append("\(place(pane)) · worked \(duration(worked))")
        return AgentNotice(event: .finished, paneID: pane.id, title: "\(agent) is done", body: lines.joined(separator: "\n"))
    }

    /// A pane that asks without a card: the agent's own words for what it waits on, else its last line.
    public static func needsYou(_ pane: PaneInfo, agent: String) -> AgentNotice {
        let what = [pane.agentSession?.waitingFor, pane.needsYou ? pane.currentSummary : nil, pane.lastLine]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let body = [what.map(clip(140)), place(pane)].compactMap { $0 }.joined(separator: "\n")
        return AgentNotice(event: .needsYou, paneID: pane.id, title: "\(agent) needs you", body: body)
    }

    /// An approval card: the question, or the tool it wants to run and with what.
    public static func approval(_ card: ApprovalRequest, pane: PaneInfo?, agent: String) -> AgentNotice {
        var what: [String] = []
        if let question = card.questions.first?.question {
            what.append(clip(140)(question))
        } else {
            // Permission cards are titled "<pane>: <tool>"; the pane is named on the last line already.
            var title = card.title
            if let pane, title.hasPrefix(pane.title + ": ") { title = String(title.dropFirst(pane.title.count + 2)) }
            what.append(card.kind == .permission ? "Wants to run \(title)" : title)
            let detail = card.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if card.kind == .permission, !detail.isEmpty { what.append(clip(140)(detail)) }
        }
        if let pane { what.append(place(pane)) }
        return AgentNotice(event: .needsYou, paneID: card.paneID, title: "\(agent) needs you", body: what.joined(separator: "\n"))
    }

    /// `detail` says which limit and when it resets, e.g. "Weekly limit · resets in 2 days".
    public static func planLimit(_ tool: AgentTool, percent: Int, detail: String) -> AgentNotice {
        AgentNotice(event: .planLimit, paneID: nil, title: "\(tool.name) plan at \(percent)%", body: detail)
    }

    /// A pane's command ended after running `ran` seconds; an `exitCode` other than 0 is a failure.
    public static func commandEnded(_ pane: PaneInfo, exitCode: Int32?, ran: TimeInterval) -> AgentNotice {
        let title = pane.displayTitle.trimmingCharacters(in: .whitespaces)
        let name = title.isEmpty ? "A command" : title
        let failed = (exitCode ?? 0) != 0
        let last = clip(140)(pane.lastLine)
        let body = [last.isEmpty ? nil : last, "\(tildePath(pane.cwd)) · ran \(duration(ran))"].compactMap { $0 }
        return AgentNotice(event: failed ? .commandFailed : .buildFinished, paneID: pane.id,
                           title: failed ? "\(name) failed · exit \(exitCode ?? 0)" : "\(name) finished",
                           body: body.joined(separator: "\n"))
    }

    /// A checked service stopped answering. Names and errors can come from anywhere, so control characters go.
    public static func serviceDown(_ status: ServiceStatus) -> AgentNotice {
        let name = ServiceRules.clean(status.name)
        let body = [status.lastError.map { clip(140)(ServiceRules.clean($0)) }, ServiceRules.clean(status.address)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return AgentNotice(event: .serviceDown, paneID: nil, title: "\(name) is down", body: body.joined(separator: "\n"))
    }

    /// What "Send test" sends.
    public static func test(from host: String) -> AgentNotice {
        AgentNotice(event: .finished, paneID: nil, title: "XTermX is connected",
                    body: "Notices from \(host) will show up here.")
    }

    /// "8 s", "4 min", "1 h 5 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func clip(_ limit: Int) -> (String) -> String {
        { text in
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
        }
    }
}

// MARK: - Which changes become notices

/// Turns pane and approval updates into notices, each one once.
///
/// *Finished*: the agent session goes from working (or a background shell) to idle or ended after at
/// least `minimumWork` seconds. *Needs you*: the pane is blocked, the agent said it needs the person, its
/// session waits, or an approval card appears. A pane that asks without a card is held for `grace`
/// seconds, because the card that usually follows says what is asked; `due(now:)` releases it.
/// *Command failed / build finished*: in a pane that isn't an agent, a command the shell marked (OSC 133)
/// ran `commandMinimum` seconds or more; a code other than 0 is a failure. A pane whose shell itself
/// exits with an error after that long is a failure too; a clean exit is just the person closing it.
public struct AgentNoticeWatcher: Sendable {
    public var minimumWork: TimeInterval
    public var grace: TimeInterval
    public var commandMinimum: TimeInterval
    /// Panes whose exit was already told.
    private var toldExit: Set<String> = []
    /// The end of the last command looked at, per pane.
    private var lastRun: [String: Date] = [:]
    private var workingSince: [String: Date] = [:]
    /// Panes whose current wait was already told (or is held).
    private var asking: Set<String> = []
    private var held: [String: (notice: AgentNotice, due: Date)] = [:]
    private var seenCards: Set<String> = []

    public init(minimumWork: TimeInterval = 10, grace: TimeInterval = 1.5, commandMinimum: TimeInterval = 30) {
        self.minimumWork = minimumWork
        self.grace = grace
        self.commandMinimum = commandMinimum
    }

    /// Notices due at once for a pane update. `agentName` is the catalog name for agents without a session.
    public mutating func paneUpdated(_ pane: PaneInfo, agentName: String? = nil, now: Date = .now) -> [AgentNotice] {
        let id = pane.id
        if pane.state == .exited {
            clear(id)
            guard pane.kind != .agent, let code = pane.exitCode, code != 0, !toldExit.contains(id) else { return [] }
            let ran = now.timeIntervalSince(pane.createdAt)
            guard ran >= commandMinimum else { return [] }
            toldExit.insert(id)
            return [AgentNoticeText.commandEnded(pane, exitCode: code, ran: ran)]
        }
        var out: [AgentNotice] = []
        if pane.kind != .agent, let run = pane.lastCommand, lastRun[id] != run.endedAt {
            lastRun[id] = run.endedAt
            if run.duration >= commandMinimum {
                out.append(AgentNoticeText.commandEnded(pane, exitCode: run.exitCode, ran: run.duration))
            }
        }
        let agent = AgentNoticeText.agent(pane, fallback: agentName)

        switch pane.agentSession?.status {
        case .working?, .shell?:
            if workingSince[id] == nil { workingSince[id] = now }
        case .idle?, .ended?:
            if let since = workingSince.removeValue(forKey: id), now.timeIntervalSince(since) >= minimumWork {
                out.append(AgentNoticeText.finished(pane, agent: agent, worked: now.timeIntervalSince(since)))
            }
        case .waiting?:
            break // still the same piece of work
        case nil:
            workingSince[id] = nil
        }

        let asks = pane.state == .blocked || pane.needsYou || pane.agentSession?.status == .waiting
        if !asks {
            asking.remove(id)
            held[id] = nil
        } else if !asking.contains(id) {
            asking.insert(id)
            held[id] = (AgentNoticeText.needsYou(pane, agent: agent), now.addingTimeInterval(grace))
        }
        return out
    }

    /// Notices for cards that weren't there before. A card replaces the held notice of its pane.
    public mutating func approvalsChanged(_ cards: [ApprovalRequest], pane: (String) -> PaneInfo?,
                                          agentName: (PaneInfo) -> String? = { _ in nil }) -> [AgentNotice] {
        var out: [AgentNotice] = []
        for card in cards where !seenCards.contains(card.id) {
            seenCards.insert(card.id)
            let p = card.paneID.flatMap(pane)
            if let id = card.paneID {
                held[id] = nil
                asking.insert(id)
            }
            let agent = card.agentTool?.name ?? AgentNoticeText.agent(p, fallback: p.flatMap(agentName))
            out.append(AgentNoticeText.approval(card, pane: p, agent: agent))
        }
        seenCards.formIntersection(cards.map(\.id))
        return out
    }

    /// Held notices whose grace is over.
    public mutating func due(now: Date = .now) -> [AgentNotice] {
        let ready = held.filter { $0.value.due <= now }
        for id in ready.keys { held[id] = nil }
        return ready.values.sorted { $0.due < $1.due }.map(\.notice)
    }

    /// When the next held notice is due, if any.
    public var nextDue: Date? { held.values.map(\.due).min() }

    public mutating func forget(_ paneID: String) {
        clear(paneID)
        toldExit.remove(paneID)
        lastRun[paneID] = nil
    }

    private mutating func clear(_ paneID: String) {
        workingSince[paneID] = nil
        asking.remove(paneID)
        held[paneID] = nil
    }
}

/// Reads a shell's semantic prompt marks (OSC 133): `C` when a command starts, `D;<code>` when it ends.
/// A `D` without a `C` before it is a prompt drawn again, not a command.
public struct SemanticPromptTracker: Sendable {
    private var started: Date?

    public init() {}

    /// The command that just ended, if this mark ends one. `payload` is what follows `133;`.
    public mutating func handle(_ payload: String, now: Date = .now) -> CommandRun? {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        switch parts.first {
        case "C":
            started = now
            return nil
        case "D":
            guard let since = started else { return nil }
            started = nil
            let code = parts.count > 1 ? Int32(parts[1]) : nil
            return CommandRun(exitCode: code, startedAt: since, endedAt: now)
        default:
            return nil
        }
    }
}

// MARK: - Which channel gets which event

/// Which kinds of notice go to which channel. Channels are named by id ("mac", "telegram", …).
/// Only the person's own choices are kept; the rest follow the defaults: everything on, except that
/// the command events (newer and noisier) start off on channels that leave this Mac.
public struct NoticeMatrix: Sendable, Equatable {
    /// "channel.event" → on.
    public private(set) var choices: [String: Bool]

    public static let localChannels: Set<String> = ["mac"]
    /// Events that start off outside the Mac.
    public static let quietOutside: Set<AgentNoticeEvent> = [.commandFailed, .buildFinished, .serviceDown]

    public init(choices: [String: Bool] = [:]) {
        self.choices = choices
    }

    /// From the E4.4 list of "channel.event" pairs turned off, where everything else was on.
    public static func migrating(muted: [String]) -> NoticeMatrix {
        var m = NoticeMatrix()
        for pair in muted {
            let parts = pair.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, let event = AgentNoticeEvent(rawValue: parts[1]) else { continue }
            m.set(parts[0], event, false)
        }
        return m
    }

    public static func isOnByDefault(_ channel: String, _ event: AgentNoticeEvent) -> Bool {
        localChannels.contains(channel) || !quietOutside.contains(event)
    }

    public func wants(_ channel: String, _ event: AgentNoticeEvent) -> Bool {
        choices[Self.key(channel, event)] ?? Self.isOnByDefault(channel, event)
    }

    public mutating func set(_ channel: String, _ event: AgentNoticeEvent, _ on: Bool) {
        choices[Self.key(channel, event)] = on
    }

    /// The channels, in the order given, that take this event.
    public func channels(for event: AgentNoticeEvent, among channels: [String]) -> [String] {
        channels.filter { wants($0, event) }
    }

    static func key(_ channel: String, _ event: AgentNoticeEvent) -> String { "\(channel).\(event.rawValue)" }
}

// MARK: - Channels

public enum NoticeChannelError: Error, Equatable, LocalizedError {
    case badToken
    case badWebhook
    case badAddress
    case badHeader
    case badTopic
    case noMessages
    /// The service answered with an error, in its words.
    case rejected(String)
    /// The request didn't get through.
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .badToken: "That doesn't look like a bot token. It has digits, a colon, then letters."
        case .badWebhook: "That isn't a webhook address. It starts with https://hooks.slack.com/."
        case .badAddress: "That isn't a web address. It starts with https:// or http://."
        case .badTopic: "A topic is letters, digits, - and _, with no spaces."
        case .badHeader: "A header is a name, a colon, then its value, e.g. Authorization: Bearer abc."
        case .noMessages: "No messages yet. Send your bot any message in Telegram, then try again."
        case .rejected(let why): why
        case .network(let why): why
        }
    }
}

/// A Telegram bot made with BotFather. The token is part of every request's path, so requests and
/// their URLs must never be logged.
public struct TelegramBot: Sendable {
    public let token: String

    /// nil when `token` isn't shaped like `123456:ABC-def_…`.
    public init?(token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy(\.isASCII), parts[0].allSatisfy(\.isNumber),
              parts[1].count >= 20, parts[1].unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        self.token = t
    }

    private func url(_ method: String) -> URL {
        URL(string: "https://api.telegram.org/bot\(token)/\(method)")!
    }

    /// Who the bot is, to show its @name.
    public func getMe() -> URLRequest { URLRequest(url: url("getMe"), timeoutInterval: 15) }

    /// Recent messages people sent the bot: where "Find my chat" looks.
    public func getUpdates() -> URLRequest { URLRequest(url: url("getUpdates"), timeoutInterval: 15) }

    public func sendMessage(chatID: Int64, text: String) -> URLRequest {
        var r = URLRequest(url: url("sendMessage"), timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["chat_id": chatID, "text": String(text.prefix(4000)), "disable_web_page_preview": true]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    public struct Chat: Codable, Sendable, Hashable, Identifiable {
        public var id: Int64
        public var name: String
        public init(id: Int64, name: String) {
            self.id = id
            self.name = name
        }
    }

    private struct Reply<T: Decodable>: Decodable {
        let ok: Bool
        let result: T?
        let description: String?
    }
    private struct Me: Decodable {
        let username: String?
        let first_name: String?
    }
    private struct Update: Decodable {
        struct Message: Decodable { let chat: RawChat }
        let message: Message?
        let edited_message: Message?
        let channel_post: Message?
        let my_chat_member: Message?
    }
    private struct RawChat: Decodable {
        let id: Int64
        let title: String?
        let first_name: String?
        let last_name: String?
        let username: String?
    }

    private static func result<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
        guard let reply = try? JSONDecoder().decode(Reply<T>.self, from: data) else {
            throw NoticeChannelError.rejected("Telegram sent an answer XTermX couldn't read.")
        }
        guard reply.ok, let result = reply.result else {
            throw NoticeChannelError.rejected(reply.description.map { "Telegram: \($0)" } ?? "Telegram said no.")
        }
        return result
    }

    /// "@name" from a `getMe` answer.
    public static func botName(_ data: Data) throws -> String {
        let me = try result(data, as: Me.self)
        return me.username.map { "@" + $0 } ?? me.first_name ?? "your bot"
    }

    /// The chats in a `getUpdates` answer, most recent last, each once.
    public static func chats(_ data: Data) throws -> [Chat] {
        let updates = try result(data, as: [Update].self)
        var out: [Chat] = []
        for u in updates {
            guard let c = (u.message ?? u.edited_message ?? u.channel_post ?? u.my_chat_member)?.chat else { continue }
            let person = [c.first_name, c.last_name].compactMap { $0 }.joined(separator: " ")
            let name = c.title ?? (person.isEmpty ? nil : person) ?? c.username.map { "@" + $0 } ?? String(c.id)
            out.removeAll { $0.id == c.id }
            out.append(Chat(id: c.id, name: name))
        }
        if out.isEmpty { throw NoticeChannelError.noMessages }
        return out
    }

    /// Throws when a `sendMessage` answer isn't ok.
    public static func checkSent(_ data: Data) throws {
        struct Sent: Decodable {}
        _ = try result(data, as: Sent.self)
    }
}

/// A Slack Incoming Webhook. Its URL is the secret.
public struct SlackWebhook: Sendable {
    public let url: URL

    /// nil unless `address` is an https URL on Slack's webhook host.
    public init?(_ address: String) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              url.host == "hooks.slack.com", url.path.count > 1 else { return nil }
        self.url = url
    }

    /// `{"text": …}` with the title in bold.
    public func post(_ notice: AgentNotice) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let text = notice.body.isEmpty ? "*\(Self.escape(notice.title))*"
            : "*\(Self.escape(notice.title))*\n\(Self.escape(notice.body))"
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        return r
    }

    /// Slack reads `&`, `<` and `>` as markup.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Any web address that takes a POST, e.g. Home Assistant, n8n, Zapier or a server of your own.
/// The address and the optional header (often a key) are secrets: neither is ever logged.
public struct GenericWebhook: Sendable {
    public struct Header: Sendable, Hashable {
        public var name: String
        public var value: String
    }

    public let url: URL
    public let header: Header?

    /// nil unless `address` is an http(s) URL and `header`, when there is one, reads "Name: value".
    public init?(_ address: String, header: String? = nil) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http", url.host?.isEmpty == false else { return nil }
        self.url = url
        let line = header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.isEmpty {
            self.header = nil
        } else {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
            else { return nil }
            self.header = Header(name: name, value: value)
        }
    }

    /// `{"event","title","body","paneID","host","time"}`; `paneID` is null for notices about no pane.
    public func post(_ notice: AgentNotice, host: String, time: Date = .now) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let header { r.setValue(header.value, forHTTPHeaderField: header.name) }
        let body: [String: Any] = [
            "event": notice.event.rawValue, "title": notice.title, "body": notice.body,
            "paneID": notice.paneID ?? NSNull(), "host": host, "time": ISO8601DateFormatter().string(from: time),
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }
}

/// A topic on an ntfy server (ntfy.sh unless the person runs their own). Anyone who knows a public
/// topic can read it, so the topic and the optional access token are kept as secrets.
public struct NtfyTopic: Sendable {
    public static let defaultServer = "https://ntfy.sh"
    public let url: URL
    public let token: String?

    /// nil when the topic has characters ntfy won't take or the server isn't a web address.
    /// An empty server means ntfy.sh; a bare host gets https://.
    public init?(server: String, topic: String, token: String? = nil) {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = Self.defaultServer }
        if !base.contains("://") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        let name = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(name.count),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let url = URL(string: base + "/" + name), url.scheme == "https" || url.scheme == "http",
              url.host?.isEmpty == false else { return nil }
        self.url = url
        let t = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.token = t.isEmpty ? nil : t
    }

    /// The body is the message; `Title`, `Priority` and `Tags` (emoji names) ride in headers.
    public func post(_ notice: AgentNotice) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue(Self.header(notice.title), forHTTPHeaderField: "Title")
        r.setValue(Self.priority(notice.event), forHTTPHeaderField: "Priority")
        r.setValue(Self.tag(notice.event), forHTTPHeaderField: "Tags")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.httpBody = Data((notice.body.isEmpty ? notice.title : notice.body).utf8)
        return r
    }

    /// Things that wait on the person or broke ring louder.
    static func priority(_ event: AgentNoticeEvent) -> String {
        switch event {
        case .needsYou, .commandFailed, .serviceDown: "high"
        case .finished, .planLimit, .buildFinished: "default"
        }
    }

    static func tag(_ event: AgentNoticeEvent) -> String {
        switch event {
        case .finished: "white_check_mark"
        case .needsYou: "raising_hand"
        case .planLimit: "warning"
        case .commandFailed: "x"
        case .buildFinished: "hammer"
        case .serviceDown: "rotating_light"
        }
    }

    /// Header values must be ASCII; ntfy decodes RFC 2047 for the rest.
    static func header(_ text: String) -> String {
        // The title comes from the pane, which a program can set: no control character reaches a header.
        let line = String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
        if line.allSatisfy({ $0.isASCII }) { return line }
        return "=?UTF-8?B?" + Data(line.utf8).base64EncodedString() + "?="
    }
}

/// Sends channel requests off the main thread, with errors in words that never carry the URL (it holds the secret).
public enum NoticeDelivery {
    /// The body of a 2xx answer.
    public static func perform(_ request: URLRequest, session: URLSession = .shared) async throws -> Data {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, Error>) in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    return done.resume(throwing: NoticeChannelError.network(describe(error)))
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data ?? Data()
                guard (200..<300).contains(status) else {
                    return done.resume(throwing: NoticeChannelError.rejected(reason(body, status: status)))
                }
                done.resume(returning: body)
            }.resume()
        }
    }

    /// Runs `attempt`, and once more after `pause` when it fails and `once` is true.
    public static func retrying(once: Bool = true, pause: Duration = .seconds(2),
                                _ attempt: @Sendable () async throws -> Data) async throws -> Data {
        do {
            return try await attempt()
        } catch where once {
            try? await Task.sleep(for: pause)
            return try await attempt()
        }
    }

    static func describe(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet?, .networkConnectionLost?: "This Mac is offline."
        case .timedOut?: "No answer in time. Try again."
        case .cannotFindHost?, .cannotConnectToHost?, .dnsLookupFailed?: "Couldn't reach the server."
        case .secureConnectionFailed?, .serverCertificateUntrusted?: "The secure connection failed."
        default: "The request didn't go through."
        }
    }

    /// Telegram explains in `description`; Slack answers a word such as `invalid_token`.
    static func reason(_ body: Data, status: Int) -> String {
        if let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let d = o["description"] as? String {
            return "Telegram: \(d)"
        }
        let text = String(decoding: body.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "invalid_token", "no_service", "no_team", "team_disabled": return "Slack doesn't know this webhook (\(text)). Make a new one."
        case "channel_not_found", "channel_is_archived": return "Slack: the webhook's channel is gone (\(text))."
        case "": return status == 0 ? "No answer." : "The server answered \(status)."
        default: return text.count < 80 && !text.contains("<") ? "Slack: \(text)" : "The server answered \(status)."
        }
    }
}
