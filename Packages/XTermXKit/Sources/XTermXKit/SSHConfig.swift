import Foundation

/// One concrete `Host` alias from an OpenSSH client config, with the options that apply to it.
public struct SSHConfigEntry: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    /// Absolute path after `~` expansion.
    public var identityFile: String?
    public var proxyJump: String?

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil,
                identityFile: String? = nil, proxyJump: String? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
    }
}

/// A read-only subset of `ssh_config(5)`: Host, HostName, User, Port, IdentityFile, ProxyJump and Include.
/// `Match` blocks are skipped; wildcard and negated patterns only lend defaults and are never imported.
public enum SSHConfig {
    public struct Hop: Equatable, Sendable {
        public var user: String?
        public var host: String
        public var port: Int?
        public init(user: String?, host: String, port: Int?) {
            self.user = user
            self.host = host
            self.port = port
        }
    }

    private struct Block {
        var patterns: [String]?   // nil: a Match block, never applied
        var options: [(String, String)] = []
    }

    private static let includeDepth = 8

    /// Reads `~/.ssh/config` (or `path`) from disk.
    public static func load(path: String? = nil, home: String = NSHomeDirectory()) -> [SSHConfigEntry] {
        let path = path ?? home + "/.ssh/config"
        guard let text = readSmallFile(path) else { return [] }
        return parse(text, home: home, read: readSmallFile, expand: glob)
    }

    public static func parse(_ text: String, home: String,
                             read: (String) -> String?, expand: (String) -> [String]) -> [SSHConfigEntry] {
        var blocks = [Block(patterns: ["*"])]  // options before the first Host apply to every host
        collect(text, home: home, read: read, expand: expand, depth: 0, into: &blocks)

        var aliases: [String] = []
        for block in blocks {
            for pattern in block.patterns ?? [] where isConcrete(pattern) && !aliases.contains(pattern) {
                aliases.append(pattern)
            }
        }
        return aliases.map { alias in
            var entry = SSHConfigEntry(alias: alias)
            var seen = Set<String>()
            for block in blocks where block.patterns.map({ applies($0, to: alias) }) == true {
                for (key, value) in block.options where !seen.contains(key) {
                    seen.insert(key)
                    switch key {
                    case "hostname": entry.hostName = value
                    case "user": entry.user = value
                    case "port": entry.port = Int(value).flatMap { (1...65535).contains($0) ? $0 : nil }
                    case "identityfile": entry.identityFile = expandTilde(value, home: home)
                    case "proxyjump": entry.proxyJump = value.lowercased() == "none" ? nil : value
                    default: break
                    }
                }
            }
            return entry
        }
    }

    /// Splits `ProxyJump` into hops: `[user@]host[:port]`, comma separated, optional `ssh://`.
    public static func jumpHops(_ value: String) -> [Hop] {
        guard value.trimmingCharacters(in: .whitespaces).lowercased() != "none" else { return [] }
        return value.split(separator: ",").compactMap { raw in
            var text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("ssh://") { text.removeFirst(6) }
            guard !text.isEmpty else { return nil }
            var user: String?
            if let at = text.lastIndex(of: "@") {
                user = String(text[..<at]); text = String(text[text.index(after: at)...])
            }
            var port: Int?
            if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
                let rest = text[text.index(after: close)...]
                if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
                text = String(text[text.index(after: text.startIndex)..<close])
            } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
                port = Int(text[text.index(after: colon)...]); text = String(text[..<colon])
            }
            guard !text.isEmpty else { return nil }
            return Hop(user: user, host: text, port: port)
        }
    }

    /// `*` and `?` glob matching, as ssh_config patterns and Include paths use.
    public static func matches(_ text: String, pattern: String) -> Bool {
        let t = Array(text), p = Array(pattern)
        var ti = 0, pi = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] { ti += 1; pi += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    // MARK: - Parsing

    private static func collect(_ text: String, home: String, read: (String) -> String?, expand: (String) -> [String],
                                depth: Int, into blocks: inout [Block]) {
        for line in text.components(separatedBy: .newlines) {
            guard let (key, args) = split(line) else { continue }
            switch key {
            case "host":
                blocks.append(Block(patterns: args))
            case "match":
                blocks.append(Block(patterns: nil))
            case "include":
                guard depth < includeDepth else { continue }
                for arg in args {
                    var path = expandTilde(arg, home: home)
                    if !path.hasPrefix("/") { path = home + "/.ssh/" + path }
                    for file in expand(path) {
                        if let included = read(file) {
                            collect(included, home: home, read: read, expand: expand, depth: depth + 1, into: &blocks)
                        }
                    }
                }
            default:
                if let value = args.first { blocks[blocks.count - 1].options.append((key, value)) }
            }
        }
    }

    /// Keyword (lowercased) and arguments, honoring `key=value`, double quotes and `#` comments.
    private static func split(_ line: String) -> (String, [String])? {
        var words: [String] = []
        var current = "", quoted = false, inWord = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); inWord = true; continue }
            if !quoted, ch == "#" { break }
            if !quoted, ch == " " || ch == "\t" || (ch == "=" && (words.isEmpty || (words.count == 1 && !inWord))) {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(ch); inWord = true
        }
        if inWord { words.append(current) }
        guard let first = words.first, !first.isEmpty else { return nil }
        return (first.lowercased(), Array(words.dropFirst()))
    }

    private static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains(where: { "*?!,".contains($0) })
    }

    private static func applies(_ patterns: [String], to alias: String) -> Bool {
        var hit = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if matches(alias, pattern: String(pattern.dropFirst())) { return false }
            } else if matches(alias, pattern: pattern) { hit = true }
        }
        return hit
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    private static func readSmallFile(_ path: String) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= 1_048_576 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private static func glob(_ pattern: String) -> [String] {
        guard pattern.contains(where: { "*?".contains($0) }) else { return [pattern] }
        let dir = (pattern as NSString).deletingLastPathComponent
        let name = (pattern as NSString).lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { !$0.hasPrefix(".") && matches($0, pattern: name) }.sorted().map { dir + "/" + $0 }
    }
}
