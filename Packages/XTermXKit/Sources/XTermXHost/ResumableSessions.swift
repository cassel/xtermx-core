#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

/// A past agent conversation in a folder that its CLI can reopen.
public struct ResumableSession: Sendable, Hashable, Identifiable {
    public var agentID: String
    public var sessionID: String
    public var title: String
    public var modified: Date
    public var id: String { agentID + ":" + sessionID }

    public init(agentID: String, sessionID: String, title: String, modified: Date) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.title = title
        self.modified = modified
    }
}

/// Claude Code and Codex conversations started in a folder, newest first, read from the agents' own
/// transcripts. Bounded: the newest `maxFiles` per agent, and only the head of each file. Call off the main actor.
public enum ResumableSessions {
    public static let maxFiles = 300
    static let headBytes = 512 * 1024

    public static func list(cwd: String, home: String = NSHomeDirectory(), limit: Int = 200) -> [ResumableSession] {
        let folder = standardized(cwd)
        let found = claude(folder: folder, root: home + "/.claude/projects") + codex(folder: folder, root: home + "/.codex/sessions")
        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// Claude Code's folder for a project: the path with every character outside [A-Za-z0-9] as `-`.
    static func claudeDirectoryName(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    static func claude(folder: String, root: String) -> [ResumableSession] {
        let dir = URL(fileURLWithPath: root).appendingPathComponent(claudeDirectoryName(folder))
        return newest(in: dir, recursive: false) { $0.pathExtension == "jsonl" }.compactMap { url, modified in
            var title: String?, aiTitle: String?, otherFolder = false
            forEachHeadLine(url) { o in
                if let cwd = o["cwd"] as? String, standardized(cwd) != folder { otherFolder = true; return false }
                if o["type"] as? String == "ai-title" { aiTitle = o["aiTitle"] as? String }
                guard o["type"] as? String == "user", o["isMeta"] as? Bool != true, o["isSidechain"] as? Bool != true,
                      let text = userText((o["message"] as? [String: Any])?["content"]) else { return true }
                title = text
                return false
            }
            guard !otherFolder, let text = title ?? aiTitle.map(oneLine) else { return nil }
            return ResumableSession(agentID: "claude-code", sessionID: url.deletingPathExtension().lastPathComponent, title: text, modified: modified)
        }
    }

    static func codex(folder: String, root: String) -> [ResumableSession] {
        newest(in: URL(fileURLWithPath: root), recursive: true) { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
            .compactMap { url, modified in
                var sessionID: String?, title: String?
                forEachHeadLine(url) { o in
                    guard let p = o["payload"] as? [String: Any] else { return true }
                    guard sessionID != nil else {
                        // The first line describes the session; helper threads (reviewers, spawned agents) are not resumable work.
                        guard o["type"] as? String == "session_meta", let cwd = p["cwd"] as? String, standardized(cwd) == folder,
                              !(p["source"] is [String: Any]), let id = p["id"] as? String else { return false }
                        sessionID = id
                        return true
                    }
                    guard o["type"] as? String == "response_item", p["role"] as? String == "user",
                          let text = userText(p["content"]), !text.hasPrefix("# AGENTS.md instructions") else { return true }
                    title = text
                    return false
                }
                guard let sessionID, let title else { return nil }
                return ResumableSession(agentID: "codex", sessionID: sessionID, title: title, modified: modified)
            }
    }

    /// The typed text of a user message; nil for tool results and injected `<…>` blocks.
    static func userText(_ content: Any?) -> String? {
        let raw: String? = if let s = content as? String { s }
            else { (content as? [[String: Any]])?.first { $0["text"] is String }?["text"] as? String }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return oneLine(text)
    }

    static func oneLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
    }

    static func standardized(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func newest(in dir: URL, recursive: Bool, _ keep: (URL) -> Bool) -> [(URL, Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let fm = FileManager.default
        let urls: [URL] = recursive
            ? (fm.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])?.compactMap { $0 as? URL } ?? [])
            : ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
        let dated = urls.filter(keep).compactMap { url -> (URL, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return (url, v.contentModificationDate ?? .distantPast)
        }
        return Array(dated.sorted { $0.1 > $1.1 }.prefix(maxFiles))
    }

    /// Calls `body` with each JSON object line of the file's head until it returns false.
    private static func forEachHeadLine(_ url: URL, _ body: ([String: Any]) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var buffer = Data(), read = 0
        while read < headBytes, let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            read += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], !body(o) { return }
            }
        }
    }
}
#endif
