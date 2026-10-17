#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

/// Agent time and sessions in panes over the last week, kept in `~/.config/xtermx/agent-history.json`.
/// Fed once a second with each pane session's state; the time since the last sighting goes to its status.
@MainActor
final class AgentHistoryStore {
    static let keepDays = 7
    static let keepSessions = 100

    private(set) var days: [AgentDayStats] = []
    private(set) var history: [AgentSessionRecord] = []
    private var last: [String: (tokens: TokenUsage, cost: Double, at: Date)] = [:]
    private let url: URL?
    private var dirty = false
    private var savedAt = Date.distantPast

    private struct File: Codable {
        var savedAt: Date
        var days: [AgentDayStats]
        var history: [AgentSessionRecord]
    }

    init(url: URL? = FileSecretStore.defaultDirectory.appendingPathComponent("agent-history.json")) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let file = try? WireCoding.decoder().decode(File.self, from: data) {
            days = file.days
            // A session still open when XTermX quit ended then, as far as anyone can tell.
            history = file.history.map { r in
                var r = r
                if r.endedAt == nil { r.endedAt = max(r.startedAt, file.savedAt) }
                return r
            }
        }
        prune(.now)
    }

    func observe(_ info: AgentSessionInfo, now: Date = .now) {
        let key = AgentDayStats.key(now)
        var day = days.first { $0.day == key } ?? AgentDayStats(day: key)
        var record = history.first { $0.id == info.sessionID }
            ?? AgentSessionRecord(id: info.sessionID, tool: info.tool, account: info.account, startedAt: info.startedAt)

        if let prev = last[info.sessionID] {
            // Gaps (a sleeping Mac, a stalled poll) are not agent time.
            let dt = min(max(now.timeIntervalSince(prev.at), 0), 5)
            switch info.status {
            case .working: day.working += dt
            case .shell: day.shell += dt
            case .waiting: day.waiting += dt
            case .idle: day.idle += dt
            case .ended: break
            }
            if info.status == .working || info.status == .shell {
                record.working += dt
                day.projects[info.cwd.map(tildePath) ?? "?", default: 0] += dt
            }
            day.tokens = day.tokens + Self.growth(from: prev.tokens, to: info.tokens)
            day.costUSD += max(0, (info.costUSD ?? 0) - prev.cost)
        }
        if !day.sessionIDs.contains(info.sessionID) { day.sessionIDs.append(info.sessionID) }
        last[info.sessionID] = (info.tokens, info.costUSD ?? 0, now)

        record.title = info.displayName
        record.cwd = info.cwd ?? record.cwd
        record.model = info.model ?? record.model
        record.tokens = info.tokens
        record.costUSD = info.costUSD
        record.endedAt = nil

        put(day)
        put(record)
        dirty = true
    }

    func ended(sessionID: String, at date: Date = .now) {
        last[sessionID] = nil
        guard let i = history.firstIndex(where: { $0.id == sessionID }) else { return }
        history[i].endedAt = date
        dirty = true
        save(force: true, now: date)
    }

    /// Writes at most every 30 s unless forced.
    func save(force: Bool = false, now: Date = .now) {
        guard dirty, force || now.timeIntervalSince(savedAt) >= 30, let url else { return }
        prune(now)
        savedAt = now // on failure, try again later rather than every second
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WireCoding.encoder().encode(File(savedAt: now, days: days, history: history)).write(to: url, options: .atomic)
            dirty = false
        } catch {}
    }

    private func put(_ day: AgentDayStats) {
        if let i = days.firstIndex(where: { $0.day == day.day }) { days[i] = day } else { days.insert(day, at: 0) }
    }

    private func put(_ record: AgentSessionRecord) {
        if let i = history.firstIndex(where: { $0.id == record.id }) { history[i] = record } else { history.insert(record, at: 0) }
    }

    private func prune(_ now: Date) {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(Self.keepDays - 1), to: calendar.startOfDay(for: now)) ?? now
        let oldest = AgentDayStats.key(cutoff)
        days = days.filter { $0.day >= oldest }.sorted { $0.day > $1.day }
        history = Array(history.filter { ($0.endedAt ?? now) >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }.prefix(Self.keepSessions))
    }

    /// What a session spent since the last sighting; never negative (a cleared session starts over).
    static func growth(from a: TokenUsage, to b: TokenUsage) -> TokenUsage {
        TokenUsage(input: max(0, b.input - a.input), output: max(0, b.output - a.output),
                   cacheRead: max(0, b.cacheRead - a.cacheRead), cacheWrite: max(0, b.cacheWrite - a.cacheWrite))
    }
}
#endif
