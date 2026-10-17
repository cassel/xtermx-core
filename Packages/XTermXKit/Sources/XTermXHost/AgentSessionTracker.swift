#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import XTermXKit

/// Follows the Claude Code and Codex sessions running in panes: their hooks say which session
/// runs in which pane, then the session's own files say what it does — status, model, title,
/// tokens, subagents, tool calls, shells, tasks — and the account's plan limits. With
/// `watchMachine`, it also follows the sessions open elsewhere on this machine, found through
/// the agents' own session registries. Nothing is read outside the agents' files.
@MainActor
public final class AgentSessionTracker {
    /// A session announced by its `SessionStart` hook.
    public struct Registration: Sendable, Hashable {
        public var paneID: String
        public var tool: AgentTool
        public var sessionID: String
        public var transcriptPath: String
        public var model: String?

        public init(paneID: String, tool: AgentTool, sessionID: String, transcriptPath: String, model: String? = nil) {
            self.paneID = paneID
            self.tool = tool
            self.sessionID = sessionID
            self.transcriptPath = transcriptPath
            self.model = model
        }
    }

    private let manager: PaneManager
    private let reader = AgentTranscriptReader()
    private var geminiStates: [String: AgentSessionStatus] = [:]
    private var registrations: [String: Registration] = [:]
    /// Permission cards waiting on a pane (parallel tool calls ask at once), and whether the agent was seen waiting since.
    private var pending: [String: (ids: [String], sawWaiting: Bool)] = [:]
    /// Codex subagents, from its SubagentStart/Stop hooks (Codex keeps them in other rollouts).
    private var hookSubagents: [String: [SubagentInfo]] = [:]
    private var accounts: [String: AccountUsage] = [:]
    private var timer: Timer?
    private var polling = false
    private let history: AgentHistoryStore
    private let watchMachine: Bool
    private var elsewhere: [AgentSessionInfo] = []
    private var machineScannedAt = Date.distantPast
    /// Days and history go out every 10 s at most: they change every second.
    private var historyShown: (days: [AgentDayStats], history: [AgentSessionRecord], at: Date) = ([], [], .distantPast)

    /// `historyURL`: where agent time and sessions in panes are kept (nil keeps them in memory only).
    /// `watchMachine`: also follow sessions running outside the panes.
    public init(manager: PaneManager, historyURL: URL? = nil, watchMachine: Bool = false) {
        self.manager = manager
        self.history = AgentHistoryStore(url: historyURL)
        self.watchMachine = watchMachine
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func register(_ registration: Registration) {
        registrations[registration.paneID] = registration
        if registration.tool == .gemini { geminiStates[registration.paneID] = .idle }
        hookSubagents[registration.paneID] = nil
        tick()
    }

    public func unregister(paneID: String) {
        guard let reg = registrations.removeValue(forKey: paneID) else { return }
        pending[paneID] = nil
        geminiStates[paneID] = nil
        hookSubagents[paneID] = nil
        manager.setAgentSession(paneID, nil)
        history.ended(sessionID: reg.sessionID)
        publishOverview(historyChanged: true)
    }

    public func session(paneID: String) -> Registration? { registrations[paneID] }

    public func geminiActivity(paneID: String, status: AgentSessionStatus) {
        guard registrations[paneID]?.tool == .gemini else { return }
        geminiStates[paneID] = status
        if var info = manager.pane(paneID)?.agentSession {
            info.status = status
            info.waitingFor = status == .waiting ? "input in the Gemini terminal" : nil
            manager.setAgentSession(paneID, info)
            history.observe(info)
        }
        tick()
    }

    func permissionPending(paneID: String, requestID: String) {
        var p = pending[paneID] ?? ([], false)
        p.ids.append(requestID)
        pending[paneID] = p
        tick()
    }

    func permissionSettled(paneID: String, requestID: String) {
        guard var p = pending[paneID] else { return }
        p.ids.removeAll { $0 == requestID }
        pending[paneID] = p.ids.isEmpty ? nil : p
        tick()
    }

    func subagent(paneID: String, id: String, name: String, running: Bool) {
        var list = hookSubagents[paneID] ?? []
        if let i = list.firstIndex(where: { $0.id == id }) {
            list[i].running = running
        } else {
            list.append(SubagentInfo(id: id, name: name, running: running))
        }
        hookSubagents[paneID] = Array(list.suffix(30))
        tick()
    }

    /// Claude Code's plan limits, as its status line receives them.
    func claudeLimits(transcriptPath: String?, windows: [UsageWindow]) {
        guard !windows.isEmpty else { return }
        let account = AgentTranscriptReader.account(of: transcriptPath ?? "", tool: .claude)
            ?? tildePath(NSHomeDirectory() + "/.claude")
        keepNewest(AccountUsage(tool: .claude, account: account, windows: windows))
        publishOverview()
    }

    /// The plan limits every Claude Code session left through its status line (`AgentHookInstaller.limitsDirectory`),
    /// in a pane or not; as of when the file was written. A week old or more is gone.
    nonisolated static func claudeLimitFiles(in directory: URL = AgentHookInstaller.limitsDirectory, now: Date = .now) -> [AccountUsage] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }.compactMap { name in
            let path = directory.appendingPathComponent(name).path
            guard let written = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(written) < 7 * 86_400,
                  let data = FileManager.default.contents(atPath: path),
                  let input = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let transcript = input["transcript_path"]?.string,
                  let account = AgentTranscriptReader.account(of: transcript, tool: .claude) else { return nil }
            let windows = AgentHooks.claudeWindows(input["rate_limits"])
            return windows.isEmpty ? nil : AccountUsage(tool: .claude, account: account, windows: windows, fetchedAt: written)
        }
    }

    /// Two sessions of one account report its limits; the most recent report wins.
    private func keepNewest(_ usage: AccountUsage) {
        if let old = accounts[usage.id], old.fetchedAt > usage.fetchedAt { return }
        accounts[usage.id] = usage
    }

    private func tick() {
        for paneID in registrations.keys where manager.pane(paneID) == nil || manager.pane(paneID)?.state == .exited {
            unregister(paneID: paneID)
        }
        let scanMachine = watchMachine && Date.now.timeIntervalSince(machineScannedAt) >= 2
        guard !polling, !registrations.isEmpty || scanMachine else { return }
        polling = true
        let regs = Array(registrations.values)
        Task {
            let results = await reader.poll(regs)
            apply(results)
            if scanMachine {
                machineScannedAt = .now
                let found = await reader.pollMachine(excluding: Set(registrations.values.map(\.sessionID)))
                // An agent in a pane without hooks is the pane's, not elsewhere.
                elsewhere = found.sessions.filter { s in found.pids[s.sessionID].map { manager.pane(containingProcess: $0) == nil } ?? true }
                for usage in found.accounts { keepNewest(usage) }
                for usage in Self.claudeLimitFiles() { keepNewest(usage) }
            }
            publishOverview()
            history.save()
            polling = false
        }
    }

    private func apply(_ results: [AgentTranscriptReader.Result]) {
        for r in results {
            // A newer SessionStart (e.g. /clear) may have replaced this one meanwhile.
            guard registrations[r.paneID]?.sessionID == r.info.sessionID else { continue }
            if r.ended {
                unregister(paneID: r.paneID)
                continue
            }
            var info = r.info
            if info.tool == .gemini { info.status = geminiStates[r.paneID] ?? .idle; info.waitingFor = info.status == .waiting ? "input in the Gemini terminal" : nil }
            if let extra = hookSubagents[r.paneID] { info.subagents += extra }
            if var p = pending[r.paneID] {
                // Claude Code shows its own dialog too; once the person answers there, take the card down.
                if r.registryStatus == "waiting" { p.sawWaiting = true; pending[r.paneID] = p }
                if p.sawWaiting, let s = r.registryStatus, s != "waiting" {
                    pending[r.paneID] = nil
                    for id in p.ids { manager.withdraw(id) }
                } else {
                    info.status = .waiting
                    info.waitingFor = info.waitingFor ?? "permission"
                }
            }
            manager.setAgentSession(r.paneID, info)
            history.observe(info)
            if let usage = r.account { keepNewest(usage) }
        }
    }

    private func publishOverview(historyChanged: Bool = false) {
        if historyChanged || Date.now.timeIntervalSince(historyShown.at) >= 10 {
            historyShown = (history.days, Array(history.history.prefix(40)), .now)
        }
        manager.setOverview(AgentOverview(
            accounts: accounts.values.sorted { ($0.tool.rawValue, $0.account) < ($1.tool.rawValue, $1.account) },
            elsewhere: elsewhere, days: historyShown.days, history: historyShown.history))
    }
}

// MARK: - Reading the agents' files

/// Reads transcripts incrementally, off the main actor. Each poll reads only what was appended.
actor AgentTranscriptReader {
    struct Result: Sendable {
        var paneID: String
        var info: AgentSessionInfo
        var ended: Bool
        /// Claude Code's own status word from its session registry, when found.
        var registryStatus: String?
        var account: AccountUsage?
    }

    /// One growing JSONL file.
    final class Tail {
        let path: String
        var offset: UInt64 = 0
        var remainder = Data()
        var fileNumber: Int?
        /// A long transcript is caught up over several polls instead of read whole at once.
        static let chunk = 8 << 20

        init(path: String) { self.path = path }

        /// Complete new lines since the last call; restarts if the file was replaced or shrank.
        func newLines() -> [Data] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let number = (attributes?[.systemFileNumber] as? NSNumber)?.intValue
            if let number, let known = fileNumber, number != known { offset = 0; remainder = Data() }
            fileNumber = number
            guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < offset { offset = 0; remainder = Data() }
            guard size > offset else { return [] }
            try? handle.seek(toOffset: offset)
            guard let chunk = try? handle.read(upToCount: Self.chunk), !chunk.isEmpty else { return [] }
            offset += UInt64(chunk.count)
            var data = remainder + chunk
            var lines: [Data] = []
            while let nl = data.firstIndex(of: 0x0A) {
                lines.append(data[data.startIndex..<nl])
                data = data[(nl + 1)...]
            }
            remainder = Data(data)
            return lines
        }
    }

    final class SessionState {
        let tail: Tail
        var info: AgentSessionInfo
        /// Claude Code repeats a message's usage on several lines: keep the largest per message id.
        var usageByMessage: [String: TokenUsage] = [:]
        /// Title candidates by priority (lower wins).
        var titles: [Int: String] = [:]
        var registryPath: String?
        var registryFound = false
        var registryStatus: String?
        var subagents: [String: SubagentState] = [:]
        var lastSubagentScan = Date.distantPast
        var account: AccountUsage?
        var lockPath: String?
        /// When the line being read was written (Codex lines carry a timestamp).
        var lineDate = Date.now
        var activity: [AgentActivity] = []
        /// By tool call id.
        var shells: [String: AgentShell] = [:]
        /// Claude Code's background task id → the tool call that started it.
        var shellOfTask: [String: String] = [:]
        var tasks: [AgentTask] = []
        var nextTaskID = 1

        init(path: String, info: AgentSessionInfo) {
            tail = Tail(path: path)
            self.info = info
        }

        static let keepActivities = 12

        func record(_ described: (symbol: String, text: String), id: String, date: Date) {
            activity.removeAll { $0.id == id }
            activity.append(AgentActivity(id: id, date: date, symbol: described.symbol, text: described.text))
            if activity.count > Self.keepActivities { activity.removeFirst(activity.count - Self.keepActivities) }
        }

        func endShell(_ id: String, _ outcome: AgentShell.Outcome, at date: Date) {
            guard var shell = shells[id], shell.outcome == .running else { return }
            shell.outcome = outcome
            shell.endedAt = date
            shells[id] = shell
        }

        /// Copies activity, tasks and shells into `info`. Finished shells stay 30 s; quick
        /// foreground commands never show. `foregroundLive`: a foreground command can be running now
        /// (not while the agent waits on a permission); `turnOver`: none can (the agent is idle).
        func publishWork(foregroundLive: Bool, turnOver: Bool, now: Date = .now) {
            shells = shells.filter { _, shell in
                if shell.outcome != .running { return now.timeIntervalSince(shell.endedAt ?? now) < 30 }
                if turnOver && !shell.background { return false }
                return now.timeIntervalSince(shell.startedAt) < 86_400
            }
            info.shells = shells.values.filter { shell in
                if shell.outcome == .running && !shell.background && !foregroundLive { return false }
                return shell.background || (shell.endedAt ?? now).timeIntervalSince(shell.startedAt) >= 3
            }.sorted { $0.startedAt < $1.startedAt }
            info.activity = activity
            info.tasks = tasks
        }
    }

    final class SubagentState {
        let tail: Tail
        var info: SubagentInfo
        var usageByMessage: [String: TokenUsage] = [:]
        var endTurn = false
        var lastWrite = Date.distantPast

        init(path: String, info: SubagentInfo) {
            tail = Tail(path: path)
            self.info = info
        }
    }

    private var states: [String: SessionState] = [:]

    func poll(_ registrations: [AgentSessionTracker.Registration]) -> [Result] {
        let live = Set(registrations.map { "\($0.paneID)|\($0.sessionID)" })
        for key in states.keys where !live.contains(key) { states[key] = nil }
        return registrations.map { reg in
            let key = "\(reg.paneID)|\(reg.sessionID)"
            let state = states[key] ?? {
                let account = Self.account(of: reg.transcriptPath, tool: reg.tool) ?? "?"
                let s = SessionState(path: reg.transcriptPath,
                                     info: AgentSessionInfo(tool: reg.tool, sessionID: reg.sessionID, account: account, model: reg.model))
                states[key] = s
                return s
            }()
            var ended = false
            switch reg.tool {
            case .claude: ended = pollClaude(state)
            case .codex: ended = pollCodex(state)
            case .gemini: break
            }
            return Result(paneID: reg.paneID, info: state.info, ended: ended, registryStatus: state.registryStatus, account: state.account)
        }
    }

    // MARK: Sessions elsewhere on the machine

    struct MachineResult: Sendable {
        var sessions: [AgentSessionInfo]
        var accounts: [AccountUsage]
        /// Session id → the agent's process, when its registry says.
        var pids: [String: Int32] = [:]
    }

    struct Found {
        var tool: AgentTool
        var transcript: String
        var registry: String?
        var cwd: String?
        var startedAt: Date?
        var pid: Int32?
    }

    private var others: [String: SessionState] = [:]
    private var found: [String: Found] = [:]
    private var foundAt = Date.distantPast
    /// Codex thread id → its rollout, or "" for a thread that is someone's subagent.
    private var rollouts: [String: String] = [:]

    /// Every Claude Code and Codex session open on this machine but not in `excluding` (the panes' own).
    /// `folders`: the account folders to look in; every account on the machine by default.
    func pollMachine(excluding: Set<String>, folders: (claude: [String], codex: [String])? = nil, now: Date = .now) -> MachineResult {
        if now.timeIntervalSince(foundAt) >= 5 {
            let folders = folders ?? (AgentHookInstaller.claudeFolders(), AgentHookInstaller.codexFolders())
            found = discoverClaude(folders.claude).merging(discoverCodex(folders.codex, now: now)) { a, _ in a }
            foundAt = now
        }
        others = others.filter { found[$0.key] != nil && !excluding.contains($0.key) }
        var sessions: [AgentSessionInfo] = []
        var accounts: [AccountUsage] = []
        for (id, f) in found where !excluding.contains(id) {
            let s = others[id] ?? {
                let account = Self.account(of: f.transcript, tool: f.tool) ?? "?"
                let s = SessionState(path: f.transcript, info: AgentSessionInfo(
                    tool: f.tool, sessionID: id, account: account, startedAt: f.startedAt ?? now, cwd: f.cwd))
                s.registryPath = f.registry
                others[id] = s
                return s
            }()
            let ended = f.tool == .claude ? pollClaude(s) : pollCodex(s)
            if ended {
                others[id] = nil
                found[id] = nil
                continue
            }
            // Shells and tasks are for sessions in panes; elsewhere shows what it does, not the details.
            sessions.append(s.info.trimmed(activities: 8))
            if let usage = s.account { accounts.append(usage) }
        }
        return MachineResult(sessions: sessions.sorted { $0.startedAt > $1.startedAt }, accounts: accounts,
                             pids: found.compactMapValues(\.pid))
    }

    /// Claude Code keeps `sessions/<pid>.json` for each open session.
    private func discoverClaude(_ folders: [String]) -> [String: Found] {
        var result: [String: Found] = [:]
        for folder in folders {
            let dir = folder + "/sessions"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") {
                let path = dir + "/" + name
                guard let data = FileManager.default.contents(atPath: path), let o = Self.object(data),
                      let id = o["sessionId"] as? String, let pid = o["pid"] as? Int else { continue }
                if kill(pid_t(pid), 0) != 0, errno == ESRCH { continue }
                let cwd = o["cwd"] as? String
                let started = (o["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                result[id] = Found(tool: .claude, transcript: Self.claudeTranscript(folder: folder, cwd: cwd, sessionID: id),
                                   registry: path, cwd: cwd, startedAt: started, pid: Int32(pid))
            }
        }
        return result
    }

    /// `<folder>/projects/<cwd with every non-alphanumeric as "-">/<id>.jsonl`, else wherever it is.
    static func claudeTranscript(folder: String, cwd: String?, sessionID: String) -> String {
        let projects = folder + "/projects"
        let file = sessionID + ".jsonl"
        if let cwd {
            let dir = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            let path = projects + "/" + dir + "/" + file
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] {
            let path = projects + "/" + dir + "/" + file
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // Not written yet (no message so far): it will be there.
        let dir = cwd.map { String($0.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }) } ?? "-"
        return projects + "/" + dir + "/" + file
    }

    /// Codex holds `thread-writer-locks/<id>.lock` while a thread is open; subagent threads are skipped.
    private func discoverCodex(_ folders: [String], now: Date) -> [String: Found] {
        var result: [String: Found] = [:]
        for home in folders {
            let locks = home + "/thread-writer-locks"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: locks)) ?? [] where name.hasSuffix(".lock") {
                let id = String(name.dropLast(5))
                guard let path = rollout(home: home, id: id, now: now) else { continue }
                result[id] = Found(tool: .codex, transcript: path, registry: nil, cwd: nil, startedAt: nil)
            }
        }
        return result
    }

    private func rollout(home: String, id: String, now: Date) -> String? {
        if let known = rollouts[id] { return known.isEmpty ? nil : known }
        let calendar = Calendar.current
        for back in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = String(format: "%@/sessions/%04d/%02d/%02d", home, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            guard let name = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).first(where: { $0.hasSuffix("-\(id).jsonl") })
            else { continue }
            let path = dir + "/" + name
            // A lock left by a Codex that died: no writes for a day.
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            if now.timeIntervalSince(modified) > 86_400 { return nil }
            let meta = Self.firstLine(path).flatMap(Self.object)?["payload"] as? [String: Any]
            rollouts[id] = meta?["parent_thread_id"] is String ? "" : path
            return rollouts[id]!.isEmpty ? nil : path
        }
        return nil
    }

    static func firstLine(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256 << 10) else { return nil }
        return head.firstIndex(of: 0x0A).map { head[head.startIndex..<$0] } ?? head
    }

    /// `~/.claude/projects/-x-y/<id>.jsonl` → `~/.claude`; `~/.codex/sessions/2026/…` → `~/.codex`.
    static func account(of transcriptPath: String, tool: AgentTool) -> String? {
        if tool == .gemini, let marker = transcriptPath.range(of: "/.gemini/") { return tildePath(String(transcriptPath[..<marker.upperBound].dropLast())) }
        let path = (transcriptPath as NSString).expandingTildeInPath
        if tool == .codex, let r = path.range(of: "/archived_sessions/") { return tildePath(String(path[..<r.lowerBound])) }
        let marker = tool == .claude ? "/projects/" : "/sessions/"
        guard let r = path.range(of: marker, options: .backwards) else { return nil }
        return tildePath(String(path[..<r.lowerBound]))
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    // MARK: Claude Code

    private func pollClaude(_ s: SessionState) -> Bool {
        let lines = s.tail.newLines()
        if !lines.isEmpty { s.info.updatedAt = .now }
        for line in lines {
            guard let o = Self.object(line) else { continue }
            Self.readClaudeLine(o, usage: &s.usageByMessage, info: &s.info, titles: &s.titles)
            Self.readClaudeWork(o, s)
        }
        s.info.tokens = s.usageByMessage.values.reduce(TokenUsage(), +)
        if let title = s.titles.min(by: { $0.key < $1.key })?.value { s.info.title = title }

        // The registry says what the session is doing and whether it still lives.
        let configDir = (Self.account(of: s.tail.path, tool: .claude).map { ($0 as NSString).expandingTildeInPath })
            ?? NSHomeDirectory() + "/.claude"
        if s.registryPath.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
            s.registryPath = findClaudeRegistry(configDir: configDir, sessionID: s.info.sessionID)
        }
        if let path = s.registryPath, let data = FileManager.default.contents(atPath: path), let o = Self.object(data),
           o["sessionId"] as? String == s.info.sessionID {
            s.registryFound = true
            if let pid = o["pid"] as? Int, kill(pid_t(pid), 0) != 0, errno == ESRCH { return true }
            let status = o["status"] as? String
            s.registryStatus = status
            s.info.status = switch status {
            case "busy": .working
            case "waiting": .waiting
            case "shell": .shell
            default: .idle
            }
            s.info.waitingFor = status == "waiting" ? (o["waitingFor"] as? String) : nil
            if s.titles.isEmpty, let name = o["name"] as? String, !name.isEmpty { s.info.title = name }
        } else if s.registryFound {
            return true // it was there and is gone: the session ended (or was cleared; a new SessionStart follows)
        } else {
            s.registryStatus = nil
        }

        if Date.now.timeIntervalSince(s.lastSubagentScan) > 2 {
            s.lastSubagentScan = .now
            scanClaudeSubagents(s)
        }
        s.info.subagents = s.subagents.values.map(\.info).sorted { ($0.running ? 0 : 1, $0.name) < ($1.running ? 0 : 1, $1.name) }
        let registry = s.registryStatus
        s.publishWork(foregroundLive: registry == nil || registry == "busy", turnOver: registry == "idle")
        return false
    }

    /// Tool calls, shells and tasks from one line of a Claude Code transcript.
    static func readClaudeWork(_ o: [String: Any], _ s: SessionState) {
        let date = (o["timestamp"] as? String).flatMap(parseDate) ?? .now
        if let cwd = o["cwd"] as? String, !cwd.isEmpty { s.info.cwd = cwd }
        switch o["type"] as? String {
        case "assistant":
            guard let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }
            for part in content where part["type"] as? String == "tool_use" {
                guard let name = part["name"] as? String, let id = part["id"] as? String else { continue }
                let input = part["input"] as? [String: Any] ?? [:]
                s.record(AgentActivityText.claude(tool: name, input: input), id: id, date: date)
                readClaudeTool(name, input: input, id: id, date: date, s)
            }
        case "user":
            let content = (o["message"] as? [String: Any])?["content"]
            if let text = content as? String { readTaskNotifications(text, date: date, s) }
            for part in content as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "tool_result":
                    guard let id = part["tool_use_id"] as? String, var shell = s.shells[id], shell.outcome == .running else { continue }
                    // Sent to the background (at the start or with Ctrl-B): it ends with a task notification.
                    if let task = (o["toolUseResult"] as? [String: Any])?["backgroundTaskId"] as? String {
                        shell.background = true
                        s.shells[id] = shell
                        s.shellOfTask[task] = id
                    } else {
                        s.endShell(id, part["is_error"] as? Bool == true ? .failed : .completed, at: date)
                    }
                case "text":
                    if let text = part["text"] as? String { readTaskNotifications(text, date: date, s) }
                default:
                    break
                }
            }
        case "queue-operation":
            if let text = o["content"] as? String { readTaskNotifications(text, date: date, s) }
        default:
            break
        }
    }

    static func readClaudeTool(_ name: String, input: [String: Any], id: String, date: Date, _ s: SessionState) {
        switch name {
        case "Bash":
            let label = (input["description"] as? String).flatMap(AgentActivityText.oneLine)
                ?? (input["command"] as? String).flatMap(AgentActivityText.oneLine) ?? "command"
            s.shells[id] = AgentShell(id: id, label: label, startedAt: date, background: input["run_in_background"] as? Bool ?? false)
        case "TaskStop", "KillShell", "KillBash":
            let task = (input["task_id"] ?? input["shell_id"] ?? input["bash_id"]) as? String
            if let task, let shell = s.shellOfTask[task] { s.endShell(shell, .killed, at: date) }
        case "TodoWrite":
            guard let todos = input["todos"] as? [[String: Any]] else { return }
            s.tasks = todos.enumerated().compactMap { i, t in
                guard let title = t["content"] as? String else { return nil }
                return AgentTask(id: "\(i)", title: title, status: taskStatus(t["status"] as? String))
            }
        case "TaskCreate":
            guard let title = (input["subject"] ?? input["description"]) as? String else { return }
            s.tasks.append(AgentTask(id: "\(s.nextTaskID)", title: title, status: .pending))
            s.nextTaskID += 1
        case "TaskUpdate":
            let taskID = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init)
            guard let taskID, let i = s.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            if input["status"] as? String == "deleted" { s.tasks.remove(at: i); return }
            if let status = input["status"] as? String { s.tasks[i].status = taskStatus(status) }
            if let subject = input["subject"] as? String { s.tasks[i].title = subject }
        default:
            break
        }
    }

    static func taskStatus(_ text: String?) -> AgentTask.Status {
        switch text {
        case "in_progress", "inProgress": .inProgress
        case "completed", "done": .completed
        default: .pending
        }
    }

    /// `<task-notification>` blocks: a background command (or agent) finished, failed or was stopped.
    static func readTaskNotifications(_ text: String, date: Date, _ s: SessionState) {
        guard text.contains("<task-notification>") else { return }
        for block in text.components(separatedBy: "<task-notification>").dropFirst() {
            let shell = tag("tool-use-id", in: block).flatMap { s.shells[$0] != nil ? $0 : nil }
                ?? tag("task-id", in: block).flatMap { s.shellOfTask[$0] }
            guard let shell else { continue }
            let outcome: AgentShell.Outcome = switch tag("status", in: block) {
            case "failed": .failed
            case "killed", "stopped", "cancelled": .killed
            default: .completed
            }
            s.endShell(shell, outcome, at: date)
        }
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
        return text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readClaudeLine(_ o: [String: Any], usage: inout [String: TokenUsage], info: inout AgentSessionInfo,
                               titles: inout [Int: String]) {
        switch o["type"] as? String {
        case "assistant":
            guard let m = o["message"] as? [String: Any] else { return }
            if let model = m["model"] as? String, model != "<synthetic>" { info.model = model }
            if let u = m["usage"] as? [String: Any] {
                let t = TokenUsage(input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                                   cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                                   cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
                guard let id = m["id"] as? String ?? o["uuid"] as? String else { return }
                let old = usage[id] ?? TokenUsage()
                usage[id] = TokenUsage(input: max(old.input, t.input), output: max(old.output, t.output),
                                       cacheRead: max(old.cacheRead, t.cacheRead), cacheWrite: max(old.cacheWrite, t.cacheWrite))
                let context = t.input + t.cacheRead + t.cacheWrite
                if context > 0 { info.contextTokens = context }
            }
            if let content = m["content"] as? [[String: Any]],
               let tool = content.last(where: { $0["type"] as? String == "tool_use" })?["name"] as? String {
                info.lastTool = tool
            }
        case "custom-title": if let t = o["customTitle"] as? String { titles[0] = t }
        case "agent-name": if let t = o["agentName"] as? String { titles[1] = t }
        case "ai-title": if let t = o["aiTitle"] as? String { titles[2] = t }
        case "last-prompt": if let t = o["lastPrompt"] as? String { titles[3] = String(t.prefix(80)) }
        case "cost-state": if let c = (o["totalCostUSD"] as? NSNumber)?.doubleValue { info.costUSD = c }
        default: break
        }
    }

    /// `sessions/<pid>.json` whose `sessionId` is this session (never the `.key` files beside them).
    private func findClaudeRegistry(configDir: String, sessionID: String) -> String? {
        let dir = configDir + "/sessions"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        for name in names where name.hasSuffix(".json") {
            let path = dir + "/" + name
            if let data = FileManager.default.contents(atPath: path), let o = Self.object(data),
               o["sessionId"] as? String == sessionID { return path }
        }
        return nil
    }

    /// `<project>/<session>/subagents/**/agent-<id>.jsonl`, with `agent-<id>.meta.json` beside it.
    private func scanClaudeSubagents(_ s: SessionState) {
        let root = (s.tail.path as NSString).deletingPathExtension + "/subagents"
        guard let walker = FileManager.default.enumerator(atPath: root) else { return }
        while let rel = walker.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { continue }
            let path = root + "/" + rel
            let id = String(name.dropFirst(6).dropLast(6))
            let sub = s.subagents[path] ?? {
                let metaPath = (path as NSString).deletingPathExtension + ".meta.json"
                let meta = FileManager.default.contents(atPath: metaPath).flatMap(Self.object)
                let state = SubagentState(path: path, info: SubagentInfo(
                    id: id, name: meta?["agentType"] as? String ?? "agent",
                    detail: meta?["description"] as? String ?? "", running: true))
                s.subagents[path] = state
                return state
            }()
            var scratch = s.info
            var titles: [Int: String] = [:]
            var grew = false
            for line in sub.tail.newLines() {
                grew = true
                guard let o = Self.object(line) else { continue }
                Self.readClaudeLine(o, usage: &sub.usageByMessage, info: &scratch, titles: &titles)
                if o["type"] as? String == "assistant", let m = o["message"] as? [String: Any] {
                    sub.endTurn = m["stop_reason"] as? String == "end_turn"
                }
            }
            if grew { sub.lastWrite = .now }
            if sub.lastWrite == .distantPast,
               let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                sub.lastWrite = date
            }
            sub.info.tokens = sub.usageByMessage.values.reduce(TokenUsage(), +)
            let quiet = Date.now.timeIntervalSince(sub.lastWrite)
            sub.info.running = !(sub.endTurn && quiet > 5) && quiet < 600
        }
    }

    // MARK: Codex

    private func pollCodex(_ s: SessionState) -> Bool {
        let lines = s.tail.newLines()
        if !lines.isEmpty { s.info.updatedAt = .now }
        for line in lines {
            guard let o = Self.object(line), let p = o["payload"] as? [String: Any] else { continue }
            s.lineDate = (o["timestamp"] as? String).flatMap(Self.parseDate) ?? .now
            switch o["type"] as? String {
            case "session_meta":
                if let cwd = p["cwd"] as? String { s.info.cwd = cwd }
            case "turn_context":
                if let model = p["model"] as? String { s.info.model = model }
                if let cwd = p["cwd"] as? String { s.info.cwd = cwd }
            case "event_msg":
                Self.readCodexEvent(p, s)
            case "response_item":
                Self.readCodexItem(p, s)
            default:
                break
            }
        }
        if let first = s.titles[3], s.info.title == nil { s.info.title = first }
        s.publishWork(foregroundLive: s.info.status == .working, turnOver: s.info.status == .idle)

        // Codex holds a lock file while the thread is open.
        let home = (Self.account(of: s.tail.path, tool: .codex).map { ($0 as NSString).expandingTildeInPath })
            ?? NSHomeDirectory() + "/.codex"
        let lock = home + "/thread-writer-locks/\(s.info.sessionID).lock"
        if FileManager.default.fileExists(atPath: lock) {
            s.lockPath = lock
        } else if s.lockPath != nil {
            return true
        }
        return false
    }

    static func readCodexEvent(_ p: [String: Any], _ s: SessionState) {
        switch p["type"] as? String {
        case "task_started", "turn_started":
            s.info.status = .working
        case "task_complete", "turn_complete", "turn_aborted":
            s.info.status = .idle
        case "user_message":
            if s.titles[3] == nil, let m = p["message"] as? String { s.titles[3] = String(m.prefix(80)) }
        case "token_count":
            if let info = p["info"] as? [String: Any] {
                if let t = info["total_token_usage"] as? [String: Any] {
                    let input = t["input_tokens"] as? Int ?? 0
                    let cached = t["cached_input_tokens"] as? Int ?? 0
                    s.info.tokens = TokenUsage(input: max(0, input - cached), output: t["output_tokens"] as? Int ?? 0,
                                               cacheRead: cached, cacheWrite: t["cache_write_input_tokens"] as? Int ?? 0)
                }
                if let last = info["last_token_usage"] as? [String: Any] { s.info.contextTokens = last["input_tokens"] as? Int }
                if let window = info["model_context_window"] as? Int { s.info.contextWindow = window }
            }
            if let limits = p["rate_limits"] as? [String: Any],
               let usage = codexLimits(limits, account: s.info.account, at: s.lineDate) {
                s.account = usage
            }
        default:
            break
        }
    }

    /// A tool call, or its output, from a Codex rollout.
    static func readCodexItem(_ p: [String: Any], _ s: SessionState) {
        let type = p["type"] as? String
        switch type {
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = p["name"] as? String ?? type ?? "tool"
            let id = p["call_id"] as? String ?? p["id"] as? String ?? UUID().uuidString
            let arguments = (p["arguments"] as? String).flatMap { object(Data($0.utf8)) }
                ?? p["action"] as? [String: Any] ?? [:]
            s.info.lastTool = name
            s.record(AgentActivityText.codex(tool: name, arguments: arguments, input: p["input"] as? String), id: id, date: s.lineDate)
            if AgentActivityText.codexShellTools.contains(name) {
                s.shells[id] = AgentShell(id: id, label: AgentActivityText.command(arguments) ?? "command", startedAt: s.lineDate, background: false)
            } else if name == "update_plan", let plan = arguments["plan"] as? [[String: Any]] {
                s.tasks = plan.enumerated().compactMap { i, step in
                    (step["step"] as? String).map { AgentTask(id: "\(i)", title: $0, status: taskStatus(step["status"] as? String)) }
                }
            }
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            if let id = p["call_id"] as? String { s.endShell(id, .completed, at: s.lineDate) }
        default:
            break
        }
    }

    /// Windows are told apart by length (300 min, 10080 min), never by position.
    static func codexLimits(_ limits: [String: Any], account: String, at date: Date = .now) -> AccountUsage? {
        if let id = limits["limit_id"] as? String, id != "codex" { return nil }
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = w["window_minutes"] as? Int ?? 0
            let kind: UsageWindow.Kind = minutes >= 1440 ? .weekly : .fiveHour
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(UsageWindow(kind: kind, usedPercent: used, resetsAt: resets))
        }
        guard !windows.isEmpty else { return nil }
        return AccountUsage(tool: .codex, account: account, plan: limits["plan_type"] as? String,
                            windows: windows.sorted { $0.kind == .fiveHour && $1.kind == .weekly }, fetchedAt: date)
    }

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ text: String) -> Date? {
        isoFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
#endif
