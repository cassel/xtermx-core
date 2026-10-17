#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

/// One thing said or done in an agent session, for a pane's chat view.
public struct AgentChatEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// What the person asked.
        case user
        /// What the agent answered.
        case assistant
        /// A tool the agent used, in words ("Read MacApp.swift").
        case tool
        /// A slash command the person ran.
        case command
    }

    /// Where it is in the transcript: stable while the file grows.
    public let id: String
    public var kind: Kind
    public var text: String
    public var symbol: String?
    public var date: Date?
}

/// A Claude Code transcript or a Codex rollout as a conversation: the person's messages, the agent's
/// answers, and its tool calls in words. Subagents' threads, tool output and the agents' own
/// bookkeeping (reminders, environment context) are left out.
public enum AgentChatTranscript {
    /// The conversation, oldest first, from at most the last `maxBytes` of the file.
    public static func read(path: String, tool: AgentTool, maxBytes: Int = 1_500_000, limit: Int = 400) -> [AgentChatEntry] {
        guard tool != .gemini else { return [] }
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var entries: [AgentChatEntry] = []
        var offset = Int(start)
        var first = start > 0 // the first line is cut in half
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            defer { offset += line.count + 1 }
            if first { first = false; continue }
            guard !line.isEmpty, let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            entries += tool == .codex ? codex(o, at: offset) : claude(o, at: offset)
        }
        return Array(entries.suffix(limit))
    }

    // MARK: Claude Code

    static func claude(_ o: [String: Any], at offset: Int) -> [AgentChatEntry] {
        if o["isSidechain"] as? Bool == true || o["isMeta"] as? Bool == true { return [] }
        let date = (o["timestamp"] as? String).flatMap(AgentTranscriptReader.parseDate)
        let content = (o["message"] as? [String: Any])?["content"]
        var parts: [[String: Any]] = content as? [[String: Any]] ?? []
        if let text = content as? String { parts = [["type": "text", "text": text]] }
        var out: [AgentChatEntry] = []
        for (i, part) in parts.enumerated() {
            let id = "\(offset).\(i)"
            switch (o["type"] as? String, part["type"] as? String) {
            case ("user", "text"):
                if let entry = personText(part["text"] as? String ?? "", id: id, date: date) { out.append(entry) }
            case ("user", "image"):
                out.append(AgentChatEntry(id: id, kind: .user, text: "[image]", date: date))
            case ("assistant", "text"):
                let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(AgentChatEntry(id: id, kind: .assistant, text: text, date: date)) }
            case ("assistant", "tool_use"):
                let words = AgentActivityText.claude(tool: part["name"] as? String ?? "tool", input: part["input"] as? [String: Any] ?? [:])
                out.append(AgentChatEntry(id: id, kind: .tool, text: words.text, symbol: words.symbol, date: date))
            default:
                break
            }
        }
        return out
    }

    /// The person's message; a slash command as just its name; the agent's own notes left out.
    static func personText(_ raw: String, id: String, date: Date?) -> AgentChatEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let r = text.range(of: "<command-name>"), let end = text.range(of: "</command-name>", range: r.upperBound..<text.endIndex) {
            var name = String(text[r.upperBound..<end.lowerBound])
            if let a = text.range(of: "<command-args>"), let b = text.range(of: "</command-args>", range: a.upperBound..<text.endIndex) {
                let args = text[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespaces)
                if !args.isEmpty { name += " " + args }
            }
            return AgentChatEntry(id: id, kind: .command, text: name, date: date)
        }
        // Reminders, command output, task notifications, interruptions: the agent's bookkeeping.
        if text.hasPrefix("<") || text.hasPrefix("[Request interrupted") || text.hasPrefix("Caveat:") { return nil }
        return AgentChatEntry(id: id, kind: .user, text: text, date: date)
    }

    // MARK: Codex

    static func codex(_ o: [String: Any], at offset: Int) -> [AgentChatEntry] {
        guard let p = o["payload"] as? [String: Any] else { return [] }
        let date = (o["timestamp"] as? String).flatMap(AgentTranscriptReader.parseDate)
        let id = "\(offset)"
        switch (o["type"] as? String, p["type"] as? String) {
        case ("event_msg", "user_message"):
            let text = (p["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.hasPrefix("<") ? [] : [AgentChatEntry(id: id, kind: .user, text: text, date: date)]
        case ("event_msg", "agent_message"):
            let text = (p["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [AgentChatEntry(id: id, kind: .assistant, text: text, date: date)]
        case ("response_item", let type?) where ["function_call", "custom_tool_call", "local_shell_call"].contains(type):
            let name = p["name"] as? String ?? type
            let arguments = (p["arguments"] as? String).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                ?? p["action"] as? [String: Any] ?? [:]
            let words = AgentActivityText.codex(tool: name, arguments: arguments, input: p["input"] as? String)
            return [AgentChatEntry(id: id, kind: .tool, text: words.text, symbol: words.symbol, date: date)]
        default:
            return []
        }
    }
}

/// One exchange of the chat: what the person said, then everything the agent did until the next
/// message — its tool calls kept apart so the chat can fold them into one row.
public struct AgentChatTurn: Identifiable, Hashable, Sendable {
    public var id: String
    /// The message or slash command that opened the turn; nil for the agent's work before the first one in view.
    public var prompt: AgentChatEntry?
    public var tools: [AgentChatEntry] = []
    public var answers: [AgentChatEntry] = []

    public init(id: String, prompt: AgentChatEntry?) {
        self.id = id
        self.prompt = prompt
    }

    public static func group(_ entries: [AgentChatEntry]) -> [AgentChatTurn] {
        var turns: [AgentChatTurn] = []
        for entry in entries {
            switch entry.kind {
            case .user, .command:
                turns.append(AgentChatTurn(id: entry.id, prompt: entry))
            case .tool, .assistant:
                if turns.isEmpty { turns.append(AgentChatTurn(id: "before-" + entry.id, prompt: nil)) }
                if entry.kind == .tool { turns[turns.count - 1].tools.append(entry) } else { turns[turns.count - 1].answers.append(entry) }
            }
        }
        return turns
    }
}

/// Follows a transcript while its chat is on screen: reads it again only when the file's size changed.
public struct AgentChatFollower: Sendable {
    public let path: String
    public let tool: AgentTool
    private var size: UInt64?

    public init(path: String, tool: AgentTool) {
        self.path = (path as NSString).expandingTildeInPath
        self.tool = tool
    }

    /// The whole conversation when the file changed since the last call; nil when it didn't or isn't there.
    public mutating func poll() -> [AgentChatEntry]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = (attributes[.size] as? NSNumber)?.uint64Value, bytes != size else { return nil }
        size = bytes
        return AgentChatTranscript.read(path: path, tool: tool)
    }
}

/// What the chat's message box types into the pane.
public enum AgentChatInput {
    /// The message trimmed, nil when empty. Several lines go as one bracketed paste, so the agent
    /// takes them as one message instead of sending each line.
    public static func payload(_ message: String) -> String? {
        let text = message.replacingOccurrences(of: "\u{1b}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.contains("\n") ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
    }
}

/// An agent's answer cut into what the chat draws differently: code fences, headings, and the text
/// between them (inline markdown, line breaks kept, list items as "•").
public enum AgentChatMarkdown {
    public enum Block: Hashable, Sendable {
        case text(String)
        case heading(String)
        case code(String)
    }

    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var text: [String] = []
        var code: [String]?
        func endText() {
            let t = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { blocks.append(.text(t)) }
            text = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    endText()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if let title = heading(line) {
                endText()
                blocks.append(.heading(title))
            } else {
                text.append(bullet(line))
            }
        }
        // A fence still open: the agent is writing it.
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        endText()
        return blocks
    }

    static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
    }

    static func bullet(_ line: String) -> String {
        let indent = line.prefix { $0 == " " }
        let rest = line.dropFirst(indent.count)
        guard rest.hasPrefix("- ") || rest.hasPrefix("* ") else { return line }
        return indent + "• " + rest.dropFirst(2)
    }
}

/// Which panes show their agent's conversation instead of the terminal: the Settings default for
/// agent panes, until a pane is switched on its own (⌘⇧C or its header button).
public struct AgentChatChoices: Hashable, Sendable {
    private var own: [String: Bool] = [:]

    public init() {}

    public func showsChat(_ paneID: String, hasSession: Bool, byDefault: Bool) -> Bool {
        hasSession && (own[paneID] ?? byDefault)
    }

    public mutating func toggle(_ paneID: String, byDefault: Bool) {
        own[paneID] = !(own[paneID] ?? byDefault)
    }

    public mutating func forget(_ paneID: String) { own[paneID] = nil }
}

/// Settings › Terminal › Chat theme: the chat's own colors, or the window theme's.
public enum AgentChatTheme: String, CaseIterable, Sendable {
    case dark, light, auto

    public var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .auto: "Auto"
        }
    }
}
#endif
