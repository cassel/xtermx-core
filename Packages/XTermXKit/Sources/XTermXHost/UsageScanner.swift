#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

/// Tokens every Claude Code and Codex session on this machine spent, read from their transcripts: panes,
/// other terminals and IDEs alike. Each file is read once and then only what was appended since; what each
/// file spent per hour is kept in `~/.config/xtermx/usage-scan.json` for 30 days. Blocking: call it off the main thread.
public final class UsageScanner: @unchecked Sendable {
    public static let keepDays = 30
    static let version = 1

    private let url: URL?
    private let lock = NSLock()
    private var files: [String: FileState] = [:]
    private var loaded = false

    public init(url: URL? = FileSecretStore.defaultDirectory.appendingPathComponent("usage-scan.json")) {
        self.url = url
    }

    /// What one transcript file spent, and where reading stopped.
    struct FileState: Codable, Equatable {
        var tool: AgentTool
        /// Bytes read so far: always the end of a complete line.
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var modified: Double = 0
        var buckets: [UsageBucket] = []
        /// Claude: the last replies seen and what was counted for each (a streamed reply repeats its usage on every line).
        var recent: [Seen] = []
        /// Codex: the model of the current turn and the session's running totals.
        var model: String?
        var total: TokenUsage?

        struct Seen: Codable, Equatable {
            var id: String
            var tokens: TokenUsage
            var long: Int
        }
    }

    private struct File: Codable {
        var version: Int
        var files: [String: FileState]
    }

    /// Reads what changed since the last scan and returns the last 30 days.
    public func scan(claude: [String] = AgentHookInstaller.claudeFolders(), codex: [String] = AgentHookInstaller.codexFolders(),
                     now: Date = .now) -> MachineUsage {
        lock.lock()
        defer { lock.unlock() }
        load()
        let cutoff = Self.cutoffHour(now)
        let oldest = now.timeIntervalSince1970 - Double(Self.keepDays) * 86_400
        var found: [(path: String, tool: AgentTool, size: UInt64, modified: Double)] = []
        for folder in claude { found += Self.transcripts(in: [folder + "/projects"], tool: .claude, newerThan: oldest) }
        for folder in codex {
            found += Self.transcripts(in: [folder + "/sessions", folder + "/archived_sessions"], tool: .codex, newerThan: oldest)
        }

        // Unchanged files keep what they had; the rest are read in parallel.
        var next: [String: FileState] = [:]
        var todo: [(path: String, state: FileState)] = []
        for f in found {
            if var s = files[f.path], s.tool == f.tool, s.size == f.size, s.modified == f.modified {
                s.buckets.removeAll { $0.hour < cutoff }
                next[f.path] = s
                continue
            }
            var s = files[f.path] ?? FileState(tool: f.tool)
            if f.size < s.offset || s.tool != f.tool { s = FileState(tool: f.tool) } // rewritten: start over
            s.size = f.size
            s.modified = f.modified
            todo.append((f.path, s))
        }
        let results = Results(count: todo.count)
        DispatchQueue.concurrentPerform(iterations: todo.count) { i in
            var s = todo[i].state
            Self.read(path: todo[i].path, into: &s, cutoffHour: cutoff)
            results.set(i, s)
        }
        for (i, item) in todo.enumerated() { next[item.path] = results.get(i) ?? item.state }

        let changed = next != files
        files = next
        if changed { save() }
        return MachineUsage(buckets: UsageBucket.merged(files.values.flatMap(\.buckets)), scannedAt: now, files: files.count)
    }

    // MARK: Files

    private final class Results: @unchecked Sendable {
        private var items: [FileState?]
        private let lock = NSLock()
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ i: Int, _ s: FileState) { lock.lock(); items[i] = s; lock.unlock() }
        func get(_ i: Int) -> FileState? { lock.lock(); defer { lock.unlock() }; return items[i] }
    }

    static func cutoffHour(_ now: Date) -> Int { Int(now.timeIntervalSince1970 / 3600) - keepDays * 24 }

    /// `*.jsonl` under these folders modified after `newerThan`, each once.
    static func transcripts(in roots: [String], tool: AgentTool, newerThan: TimeInterval) -> [(path: String, tool: AgentTool, size: UInt64, modified: Double)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var out: [(path: String, tool: AgentTool, size: UInt64, modified: Double)] = []
        for root in roots {
            let url = URL(fileURLWithPath: root).resolvingSymlinksInPath()
            guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in walk where file.pathExtension == "jsonl" {
                guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let modified = v.contentModificationDate?.timeIntervalSince1970, modified >= newerThan else { continue }
                out.append((file.path, tool, UInt64(v.fileSize ?? 0), modified))
            }
        }
        return out
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.version == Self.version else { return }
        files = file.files
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(File(version: Self.version, files: files)).write(to: url, options: .atomic)
        } catch {}
    }

    // MARK: Reading

    private static let claudeMarkers = [Array(#""usage""#.utf8), Array(#""assistant""#.utf8)]
    private static let codexCount = Array(#""token_count""#.utf8)
    private static let codexContext = Array(#""turn_context""#.utf8)

    /// Reads complete lines from `state.offset` to the end and adds what they spent.
    static func read(path: String, into state: inout FileState, cutoffHour: Int) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: state.offset) } catch { return }
        var pending = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 22), !chunk.isEmpty else { break }
            if pending.isEmpty { pending = chunk } else { pending.append(chunk) }
            let consumed = lines(in: pending) { line in
                feed(line, into: &state, cutoffHour: cutoffHour)
            }
            state.offset += UInt64(consumed)
            pending = consumed == pending.count ? Data() : pending.subdata(in: consumed..<pending.count)
        }
    }

    /// Calls `body` with every complete line; returns the bytes consumed (up to the last newline).
    static func lines(in data: Data, _ body: (UnsafeRawBufferPointer) -> Void) -> Int {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var start = 0
            while start < raw.count, let nl = memchr(base + start, 0x0A, raw.count - start) {
                let end = base.distance(to: UnsafeRawPointer(nl))
                if end > start { body(UnsafeRawBufferPointer(rebasing: raw[start..<end])) }
                start = end + 1
            }
            return start
        }
    }

    /// One transcript line: only lines that can hold usage are parsed.
    static func feed(_ line: UnsafeRawBufferPointer, into state: inout FileState, cutoffHour: Int) {
        switch state.tool {
        case .gemini: break // Gemini usage has no transcript reader yet; do not infer tokens.
        case .claude:
            guard claudeMarkers.allSatisfy({ contains(line, $0) }), let o = object(line) else { return }
            readClaude(o, into: &state, cutoffHour: cutoffHour)
        case .codex:
            if contains(line, codexCount) || contains(line, codexContext), let o = object(line) {
                readCodex(o, into: &state, cutoffHour: cutoffHour)
            }
        }
    }

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress, line.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in memmem(base, line.count, n.baseAddress!, n.count) != nil }
    }

    private static func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }

    /// A Claude Code assistant line: `message.usage`, `message.model`, `message.id`, `timestamp`.
    static func readClaude(_ o: [String: Any], into s: inout FileState, cutoffHour: Int) {
        guard o["type"] as? String == "assistant", let m = o["message"] as? [String: Any],
              let u = m["usage"] as? [String: Any], let model = m["model"] as? String, model != "<synthetic>",
              let hour = (o["timestamp"] as? String).flatMap(hourOf), hour >= cutoffHour else { return }
        let t = TokenUsage(input: int(u["input_tokens"]), output: int(u["output_tokens"]),
                           cacheRead: int(u["cache_read_input_tokens"]), cacheWrite: int(u["cache_creation_input_tokens"]))
        let long = int((u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
        let id = m["id"] as? String ?? o["uuid"] as? String ?? ""
        var spent = t, spentLong = long, turn = 1
        if let i = s.recent.firstIndex(where: { $0.id == id }) {
            // The same reply again: only what grew counts.
            let old = s.recent[i]
            spent = grown(from: old.tokens, to: t)
            spentLong = max(0, long - old.long)
            turn = 0
            s.recent[i] = .init(id: id, tokens: maxed(old.tokens, t), long: max(old.long, long))
        } else {
            s.recent.append(.init(id: id, tokens: t, long: long))
            if s.recent.count > 16 { s.recent.removeFirst(s.recent.count - 16) }
        }
        guard spent.total > 0 || turn > 0 else { return }
        add(UsageBucket(hour: hour, tool: .claude, model: UsagePrices.normalized(model), tokens: spent, cacheWriteLong: spentLong, turns: turn), to: &s)
    }

    /// A Codex rollout line: `turn_context` names the model, `token_count` carries the session's running totals.
    static func readCodex(_ o: [String: Any], into s: inout FileState, cutoffHour: Int) {
        guard let p = o["payload"] as? [String: Any] else { return }
        if o["type"] as? String == "turn_context" {
            if let model = p["model"] as? String, !model.isEmpty { s.model = UsagePrices.normalized(model) }
            return
        }
        guard p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
              let t = info["total_token_usage"] as? [String: Any] else { return }
        let cached = int(t["cached_input_tokens"])
        let total = TokenUsage(input: max(0, int(t["input_tokens"]) - cached), output: int(t["output_tokens"]),
                               cacheRead: cached, cacheWrite: int(t["cache_write_input_tokens"]))
        // Totals only grow within a session; a smaller one means they started over.
        let spent = s.total.map { $0.total <= total.total ? grown(from: $0, to: total) : total } ?? total
        s.total = total
        guard spent.total > 0, let hour = (o["timestamp"] as? String).flatMap(hourOf), hour >= cutoffHour else { return }
        add(UsageBucket(hour: hour, tool: .codex, model: s.model ?? "unknown", tokens: spent, turns: 1), to: &s)
    }

    private static func add(_ b: UsageBucket, to s: inout FileState) {
        if let i = s.buckets.lastIndex(where: { $0.hour == b.hour && $0.model == b.model }) {
            s.buckets[i].tokens = s.buckets[i].tokens + b.tokens
            s.buckets[i].cacheWriteLong += b.cacheWriteLong
            s.buckets[i].turns += b.turns
        } else {
            s.buckets.append(b)
        }
    }

    /// What grew from `a` to `b`, never negative.
    static func grown(from a: TokenUsage, to b: TokenUsage) -> TokenUsage {
        TokenUsage(input: max(0, b.input - a.input), output: max(0, b.output - a.output),
                   cacheRead: max(0, b.cacheRead - a.cacheRead), cacheWrite: max(0, b.cacheWrite - a.cacheWrite))
    }

    private static func maxed(_ a: TokenUsage, _ b: TokenUsage) -> TokenUsage {
        TokenUsage(input: max(a.input, b.input), output: max(a.output, b.output),
                   cacheRead: max(a.cacheRead, b.cacheRead), cacheWrite: max(a.cacheWrite, b.cacheWrite))
    }

    private static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    /// Hours since 1970 UTC of an ISO 8601 time; the common `2026-10-16T12:34:56.789Z` without a formatter.
    static func hourOf(_ s: String) -> Int? {
        let u = Array(s.utf8)
        func num(_ a: Int, _ b: Int) -> Int? {
            var n = 0
            for i in a..<b {
                guard u[i] >= 48, u[i] <= 57 else { return nil }
                n = n * 10 + Int(u[i] - 48)
            }
            return n
        }
        if u.count >= 20, u.last == UInt8(ascii: "Z"), u[4] == UInt8(ascii: "-"), u[10] == UInt8(ascii: "T"),
           let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10), let h = num(11, 13) {
            return daysFromCivil(y, mo, d) * 24 + h
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }()
        return date.map { Int(($0.timeIntervalSince1970 / 3600).rounded(.down)) }
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
#endif
