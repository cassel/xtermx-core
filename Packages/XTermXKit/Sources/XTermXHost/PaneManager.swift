#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Observation
#if canImport(os)
import os
#endif
import XTermXKit

/// Something that happened on the host that clients may want to know.
public enum HostEvent: Sendable {
    case paneUpdated(PaneInfo)
    case paneClosed(String)
    case output(paneID: String, data: Data)
    case approvals([ApprovalRequest])
    case machine(MachineLoad)
    case overview(AgentOverview)
}

/// Owns every pane on this Mac, the approval queue and the machine-load sampler.
/// The Mac UI and the remote server are both views of this one object.
@MainActor
@Observable
public final class PaneManager {
    public private(set) var panes: [PaneInfo] = []
    public var isolateAgents = false
    @ObservationIgnored public var worktreeStore = GitWorktreeStore()
    public private(set) var isolatedPanes: [String: GitWorktreeRecord] = [:]
    @ObservationIgnored public var onPaneActivity: ((LocalPaneActivity) -> Void)?
    @ObservationIgnored public var onWorktreeClosed: ((GitWorktreeRecord) -> Void)?

    public func prepareSpawn(_ request: SpawnRequest) async throws -> PreparedPaneSpawn {
        guard isolateAgents, let agent = request.agentID, agents.contains(where: { $0.id == agent }) else { return PreparedPaneSpawn(request: request) }
        var request = request
        let record = try await worktreeStore.create(cwd: request.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path, agentID: agent)
        if let record { request.cwd = record.path }
        return PreparedPaneSpawn(request: request, worktree: record)
    }
    @discardableResult public func spawnPrepared(_ prepared: PreparedPaneSpawn, parentID: String? = nil, openedByAgent: Bool = false,
                                                id: String = UUID().uuidString) -> PaneInfo {
        let pane = spawn(prepared.request, parentID: parentID, openedByAgent: openedByAgent, id: id)
        if let record = prepared.worktree { isolatedPanes[pane.id] = record }
        return pane
    }
    public private(set) var approvals: [ApprovalRequest] = []
    public internal(set) var agents: [AgentDescriptor] = AgentCatalog.known
    public private(set) var machine: MachineLoad?
    /// Plan limits, agent sessions outside panes, agent time and history (from `AgentSessionTracker`).
    public private(set) var overview = AgentOverview()
    public var accounts: [AccountUsage] { overview.accounts }
    public var hostName: String = HostIdentity.hostName

    @ObservationIgnored private var sessions: [String: PaneSession] = [:]
    @ObservationIgnored private var listeners: [UUID: (HostEvent) -> Void] = [:]
    @ObservationIgnored private var pendingAnswers: [String: CheckedContinuation<ApprovalAnswer?, Never>] = [:]
    @ObservationIgnored private var expiries: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadTimer: Timer?
    @ObservationIgnored private let loadSampler = LoadSampler()
    @ObservationIgnored public private(set) var loginPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    /// The agent tool (MCP) endpoint panes are told about; nil until the tool server is up.
    @ObservationIgnored public var toolServerURL: URL?
    /// Per-pane bearer tokens: a token identifies the calling pane to the tool server.
    @ObservationIgnored private var tokens: [String: String] = [:]
    @ObservationIgnored private var tokenOfPane: [String: String] = [:]

    public init(detectAgents: Bool = true) {
        loadTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLoad() }
        }
        if detectAgents { Task { await refreshAgents() } }
    }

    // MARK: Events

    @discardableResult
    public func addListener(_ listener: @escaping (HostEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    public func removeListener(_ id: UUID) { listeners[id] = nil }

    private func emit(_ event: HostEvent) {
        for l in listeners.values { l(event) }
    }

    // MARK: Panes

    /// The person's shell: $SHELL, else the passwd entry (services started by systemd have no $SHELL).
    public var shell: String {
        if let env = ProcessInfo.processInfo.environment["SHELL"], !env.isEmpty { return env }
        if let entry = getpwuid(getuid()), let sh = entry.pointee.pw_shell {
            let path = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/bash"
    }

    @discardableResult
    public func spawn(_ request: SpawnRequest, parentID: String? = nil, openedByAgent: Bool = false,
                      id: String = UUID().uuidString) -> PaneInfo {
        let agent = request.agentID.flatMap { id in agents.first { $0.id == id } }
        let cwd = request.cwd.map { ($0 as NSString).expandingTildeInPath }
            .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let title = request.title ?? agent?.name ?? (cwd as NSString).lastPathComponent
        let info = PaneInfo(id: id, title: String(title.prefix(60)), kind: agent == nil ? request.kind : .agent, agentID: agent?.id,
                            cwd: cwd, parentID: parentID, openedByAgent: openedByAgent)
        let token = SecureRandom.bytes(32).base64URLEncoded
        tokens[token] = info.id
        tokenOfPane[info.id] = token

        // An agent pane is a shell that starts the agent, then an optional first message.
        var firstInput = agent.map { a in
            var parts = [a.command]
            if request.bypass, let flag = a.bypassFlag { parts.append(flag) }
            parts += toolArguments(for: a, paneID: info.id, token: token, beforePrompt: true)
            return parts.joined(separator: " ")
        }
        if let extra = request.initialInput, !extra.isEmpty {
            firstInput = firstInput.map { "\($0) \(Self.shellQuote(extra))" } ?? extra
        }
        if let a = agent {
            let trailing = toolArguments(for: a, paneID: info.id, token: token, beforePrompt: false)
            if !trailing.isEmpty { firstInput = ([firstInput ?? a.command] + trailing).joined(separator: " ") }
        }

        let session = PaneSession(info: info, shell: shell, environment: environment(for: info, token: token), initialInput: firstInput)
        session.onOutput = { [weak self] data in self?.emit(.output(paneID: info.id, data: data)) }
        session.onChange = { [weak self] updated in self?.update(updated) }
        sessions[info.id] = session
        panes.append(info)
        onPaneActivity?(LocalPaneActivity(action: .opened, pane: info))
        emit(.paneUpdated(info))
        return info
    }

    public func session(_ id: String) -> PaneSession? { sessions[id] }

    @discardableResult public func rename(_ id: String, to name: String) throws -> PaneInfo? {
        let clean = try PaneNameRules.clean(name)
        guard let session = sessions[id] else { return nil }
        session.setCustomName(clean)
        return session.info
    }

    public func close(_ id: String) {
        for key in roomRoutes.keys {
            if roomRoutes[key]?.coordinator == id { roomRoutes[key] = nil }
            else { roomRoutes[key]?.members.remove(id) }
        }
        // Nobody is left to act on this pane's cards.
        for card in approvals where card.paneID == id { withdraw(card.id) }
        if let pane = sessions[id]?.info { onPaneActivity?(LocalPaneActivity(action: .closed, pane: pane)) }
        sessions[id]?.terminate()
        sessions[id] = nil
        homeSizes[id] = nil
        borrowers[id] = nil
        if let token = tokenOfPane.removeValue(forKey: id) { tokens[token] = nil }
        try? FileManager.default.removeItem(at: Self.toolConfigURL(paneID: id))
        panes.removeAll { $0.id == id }
        emit(.paneClosed(id))
        if let record = isolatedPanes.removeValue(forKey: id) { onWorktreeClosed?(record) }
    }

    public func write(_ id: String, _ data: Data) { sessions[id]?.write(data) }
    @ObservationIgnored public private(set) var roomRoutes: [String: RoomCoordinatorRoute] = [:]
    public func setRoomCoordinator(_ room: String, coordinator: String?, members: [String]) {
        guard let coordinator, let head = pane(coordinator), head.agentID != nil, head.state != .exited else { roomRoutes[room] = nil; return }
        let agents = members.filter { id in pane(id).map { $0.agentID != nil && $0.state != .exited } ?? false }
        roomRoutes[room] = RoomCoordinatorRoute(coordinator: coordinator, members: agents)
    }
    public func roomPeers(for caller: String) -> [PaneInfo] {
        let ids = roomRoutes.values.filter { $0.coordinator == caller }.reduce(into: Set<String>()) { $0.formUnion($1.members) }
        return panes.filter { ids.contains($0.id) && $0.agentID != nil && $0.state != .exited }
    }
    public func roomHeads(for member: String) -> [PaneInfo] {
        let ids = Set(roomRoutes.values.filter { $0.members.contains(member) }.map(\.coordinator))
        return panes.filter { ids.contains($0.id) && $0.agentID != nil && $0.state != .exited }
    }
    @ObservationIgnored public var onPaneMessage: ((String, String) -> Void)?
    public func signalMessage(from: String, to: String) {
        guard from != to, sessions[from] != nil, sessions[to] != nil else { return }
        onPaneMessage?(from, to)
    }
    public func sendLine(_ id: String, _ text: String, from source: String? = nil) {
        guard let session = sessions[id] else { return }
        if session.info.kind == .agent, text.contains("\n") {
            guard let payload = AgentChatInput.payload(text) else { return }
            session.sendLine(payload)
        } else { session.sendLine(text) }
        if let source { signalMessage(from: source, to: id) }
    }
    // MARK: Sizes
    //
    // The Mac's own view sets a pane's home size. A device watching it (the phone) may take it to its own
    // size; when the last device that did lets go (leaves the pane, disconnects), the pane goes back home,
    // so the Mac never stays with a phone-sized program drawn in the top corner of its view.

    private var homeSizes: [String: (cols: Int, rows: Int)] = [:]
    private var borrowers: [String: Set<UUID>] = [:]

    /// Why a pane changed size, in the system log (`log stream --predicate 'subsystem == "us.cassel.xtermx"'`).
    private func logSize(_ id: String, _ what: String) {
        #if canImport(os)
        let size = sessions[id].map { "\($0.info.cols)x\($0.info.rows)" } ?? "-"
        Logger(subsystem: "us.cassel.xtermx", category: "size")
            .info("pane \(id.prefix(8), privacy: .public) \(what, privacy: .public) → \(size, privacy: .public) holders=\(self.borrowers[id]?.count ?? 0, privacy: .public)")
        #endif
    }

    /// Typing on this machine: the pane takes the size of its view here again, from any device.
    public func resize(_ id: String, cols: Int, rows: Int) {
        homeSizes[id] = (cols, rows)
        borrowers[id] = nil
        sessions[id]?.resize(cols: cols, rows: rows)
        logSize(id, "typed here \(cols)x\(rows)")
    }

    /// The pane's view on this machine changed size (window, splits, a card above it). Applied at once
    /// unless a device holds the pane; then it waits until that device lets go or this machine types.
    public func setHomeSize(_ id: String, cols: Int, rows: Int) {
        homeSizes[id] = (cols, rows)
        if borrowers[id]?.isEmpty ?? true { sessions[id]?.resize(cols: cols, rows: rows) }
        logSize(id, "home \(cols)x\(rows)")
    }

    /// A device's size for the pane while it watches; `device` nil for one that never says when it leaves.
    public func resize(_ id: String, cols: Int, rows: Int, device: UUID?) {
        if let device { borrowers[id, default: []].insert(device) }
        sessions[id]?.resize(cols: cols, rows: rows)
        logSize(id, "device \(device.map { String($0.uuidString.prefix(8)) } ?? "-") \(cols)x\(rows)")
    }

    /// The device stopped watching the pane: back to the home size once no device holds it.
    public func release(_ id: String, device: UUID) {
        guard borrowers[id]?.remove(device) != nil else { return }
        guard borrowers[id]?.isEmpty ?? true else { return }
        borrowers[id] = nil
        if let home = homeSizes[id] { sessions[id]?.resize(cols: home.cols, rows: home.rows) }
        logSize(id, "device \(device.uuidString.prefix(8)) left")
    }

    /// A pane became view-only/private: no remote device may keep its borrowed size.
    public func releaseRemoteSize(_ id: String) {
        borrowers[id] = nil
        if let home = homeSizes[id] { sessions[id]?.resize(cols: home.cols, rows: home.rows) }
    }

    /// Returning to this machine releases remote sizing without requiring a keystroke.
    @discardableResult public func reclaimHomeSize(_ id: String) -> Bool {
        guard let home = homeSizes[id], let session = sessions[id] else { return false }
        let changed = session.info.cols != home.cols || session.info.rows != home.rows
        borrowers[id] = nil
        session.resize(cols: home.cols, rows: home.rows)
        return changed
    }

    /// The folder the pane's shell is in now, which may differ from the one it opened in.
    public func currentDirectory(_ id: String) -> String? {
        sessions[id].flatMap { ProcessTree.currentDirectory(of: $0.shellPID) }
    }

    /// The device went away: every pane it held goes back.
    public func release(device: UUID) {
        for id in borrowers.keys { release(id, device: device) }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { panes[$0] }
        var rest = panes.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        panes = rest
    }

    private func update(_ info: PaneInfo) {
        if let i = panes.firstIndex(where: { $0.id == info.id }) { panes[i] = info }
        emit(.paneUpdated(info))
    }

    func token(forPane id: String) -> String? { tokenOfPane[id] }

    /// The pane a tool-server bearer token belongs to.
    public func paneID(forToken token: String) -> String? { tokens[token] }

    public func pane(_ id: String) -> PaneInfo? { panes.first { $0.id == id } }

    /// Command-line arguments that register the tool server with an agent for this one launch,
    /// without touching the person's global agent config. Claude Code's `--mcp-config` takes
    /// several values, so it goes last; Codex's `-c` overrides go before the prompt.
    private func toolArguments(for agent: AgentDescriptor, paneID: String, token: String, beforePrompt: Bool) -> [String] {
        guard let url = toolServerURL else { return [] }
        switch (agent.id, beforePrompt) {
        case ("codex", true):
            return ["-c", Self.shellQuote("mcp_servers.xtermx.url=\"\(url.absoluteString)\""),
                    "-c", Self.shellQuote("mcp_servers.xtermx.bearer_token_env_var=\"XTERMX_SESSION\"")]
        case ("claude-code", false), ("openclaude", false):
            guard let file = writeToolConfig(paneID: paneID, url: url, token: token) else { return [] }
            return ["--mcp-config", Self.shellQuote(file.path)]
        default:
            return []
        }
    }

    static func toolConfigURL(paneID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("XTermX/mcp/\(paneID).json")
    }

    /// A private (0600) MCP config file for one pane, holding its URL and token.
    private func writeToolConfig(paneID: String, url: URL, token: String) -> URL? {
        let file = Self.toolConfigURL(paneID: paneID)
        let config: JSONValue = ["mcpServers": ["xtermx": ["type": "http", "url": .string(url.absoluteString),
                                                           "headers": ["Authorization": .string("Bearer \(token)")]]]]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(config.prettyText.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        } catch {
            return nil
        }
    }

    /// Gemini merges this per-pane system layer with its normal user/workspace settings. Preserve the existing system policy.
    private func writeGeminiToolConfig(paneID: String, url: URL, token: String) -> URL? {
        let source = ProcessInfo.processInfo.environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"]
            ?? "/Library/Application Support/GeminiCli/settings.json"
        do {
            var config: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: source) {
                guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source))) as? [String: Any] else { return nil }
                config = object
            }
            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            servers["xtermx-pane"] = ["httpUrl": url.absoluteString, "headers": ["Authorization": "Bearer " + token]]
            config["mcpServers"] = servers
            let file = Self.toolConfigURL(paneID: paneID)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        } catch { return nil }
    }

    private func environment(for info: PaneInfo, token: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["XTERMX_SESSION"] = token
        if let url = toolServerURL {
            env["XTERMX_MCP_URL"] = url.absoluteString
            if info.agentID == "gemini", let config = writeGeminiToolConfig(paneID: info.id, url: url, token: token) {
                env["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = config.path
            }
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "XTermX"
        env["XTERMX_PANE_ID"] = info.id
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = ([loginPath] + AgentCatalog.extraDirectories()).joined(separator: ":")
        // Never leak this app's own agent session into child panes.
        for key in env.keys where key.hasPrefix("CLAUDECODE") || key == "CLAUDE_CODE_ENTRYPOINT" { env[key] = nil }
        return env.map { "\($0.key)=\($0.value)" }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Approvals

    /// Asks the person on every device at once. The first answer wins; silence is a no.
    public func requestApproval(paneID: String?, title: String, detail: String, timeout: TimeInterval = 120) async -> Bool {
        let answer = await requestDecision(ApprovalRequest(paneID: paneID, title: title, detail: detail, timeout: timeout))
        return answer?.optionID == ApprovalOption.allow.id
    }

    /// Shows `request` on every device and waits for the first answer; nil when it expires or is withdrawn.
    public func requestDecision(_ request: ApprovalRequest) async -> ApprovalAnswer? {
        approvals.append(request)
        emit(.approvals(approvals))
        let timeout = request.expiresAt.timeIntervalSinceNow
        expiries[request.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, timeout)))
            guard !Task.isCancelled else { return }
            self?.withdraw(request.id)
        }
        return await withCheckedContinuation { pendingAnswers[request.id] = $0 }
    }

    public func answer(_ requestID: String, allow: Bool) {
        respond(requestID, allow ? .allow : .deny)
    }

    public func respond(_ requestID: String, _ answer: ApprovalAnswer) { settle(requestID, answer) }

    /// Takes a card down without an answer: it expired, or the person answered in the terminal.
    public func withdraw(_ requestID: String) { settle(requestID, nil) }

    private func settle(_ requestID: String, _ answer: ApprovalAnswer?) {
        expiries.removeValue(forKey: requestID)?.cancel()
        guard let continuation = pendingAnswers.removeValue(forKey: requestID) else { return }
        approvals.removeAll { $0.id == requestID }
        emit(.approvals(approvals))
        continuation.resume(returning: answer)
    }

    // MARK: Agent sessions

    /// What the Claude Code or Codex session in a pane is doing; nil when it ended.
    public func setAgentSession(_ paneID: String, _ info: AgentSessionInfo?) {
        sessions[paneID]?.setAgentSession(info)
    }

    /// The pane whose shell `pid` descends from, if any.
    public func pane(containingProcess pid: Int32) -> String? {
        let shells = Dictionary(sessions.map { ($0.value.shellPID, $0.key) }, uniquingKeysWith: { a, _ in a })
        var current = pid
        for _ in 0..<12 {
            if let pane = shells[current] { return pane }
            guard let parent = ProcessTree.parent(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    public func setOverview(_ new: AgentOverview) {
        guard new != overview else { return }
        overview = new
        emit(.overview(new))
    }

    // MARK: Snapshot

    public func snapshot() -> HostSnapshot {
        var snapshot = HostSnapshot(hostName: hostName, panes: panes, agents: agents, approvals: approvals, machine: machine, overview: overview)
        snapshot.supportsPaneNames = true
        return snapshot
    }

    // MARK: Agents and load

    public func refreshAgents() async {
        let path = await AgentCatalog.loginShellPath(shell: shell)
        if let path { loginPath = path }
        agents = AgentCatalog.sorted(AgentCatalog.known.map { a in
            var a = a
            a.installed = AgentCatalog.isInstalled(a.executable, path: loginPath)
            return a
        })
    }

    private func sampleLoad() {
        guard var load = loadSampler.sample() else { return }
        load.livePanes = panes.filter { $0.state != .exited }.count
        machine = load
        emit(.machine(load))
    }
}

public enum AgentCatalog {
    /// Coding agents the app knows how to start, in launcher order; `installed` comes from PATH.
    public static let known: [AgentDescriptor] = [
        .init(id: "claude-code", name: "Claude Code", command: "claude", bypassFlag: "--dangerously-skip-permissions", symbol: "asterisk", tint: 0xD97757),
        .init(id: "codex", name: "Codex", command: "codex", bypassFlag: "--dangerously-bypass-approvals-and-sandbox", symbol: "hexagon", tint: 0xFFFFFF),
        .init(id: "grok", name: "Grok", command: "grok", bypassFlag: "--always-approve", symbol: "slash.circle", tint: 0xFFFFFF),
        .init(id: "gemini", name: "Gemini CLI", command: "gemini", bypassFlag: "--yolo", symbol: "sparkle", tint: 0x4285F4),
        .init(id: "omp", name: "Oh My Pi", command: "omp", symbol: "p.circle", tint: 0xC7D0E0),
        .init(id: "opencode", name: "OpenCode", command: "opencode", symbol: "curlybraces.square", tint: 0x8A8888),
        .init(id: "qwen-code", name: "Qwen Code", command: "qwen", bypassFlag: "--yolo", symbol: "q.circle", tint: 0x6950EF),
        .init(id: "github-copilot", name: "GitHub Copilot", command: "copilot", symbol: "airplane", tint: 0xFFFFFF),
        .init(id: "amp", name: "Amp", command: "amp", symbol: "bolt.fill", tint: 0xF34E3F),
        .init(id: "cursor", name: "Cursor Agent", command: "cursor-agent", symbol: "cursorarrow.rays", tint: 0xE8EAF0),
        .init(id: "goose", name: "Goose", command: "goose session", symbol: "bird", tint: 0xDBDBDB),
        .init(id: "antigravity", name: "Antigravity", command: "agy", bypassFlag: "--dangerously-skip-permissions", symbol: "arrow.up.circle", tint: 0xB9AEFF),
        .init(id: "openclaw", name: "OpenClaw", command: "openclaw chat", symbol: "pawprint", tint: 0xF25C54),
        .init(id: "hermes", name: "Hermes", command: "hermes", bypassFlag: "--yolo", symbol: "wind", tint: 0xDBDBDB),
        .init(id: "openclaude", name: "OpenClaude", command: "openclaude", bypassFlag: "--dangerously-skip-permissions", symbol: "asterisk.circle", tint: 0xD97757),
        .init(id: "devin", name: "Devin", command: "devin", bypassFlag: "--permission-mode bypass", symbol: "d.circle", tint: 0xDBDBDB),
        .init(id: "kimi", name: "Kimi", command: "kimi", bypassFlag: "--auto", symbol: "moon.fill", tint: 0xDBDBDB),
        .init(id: "mistral-vibe", name: "Mistral Vibe", command: "vibe", bypassFlag: "--auto-approve", symbol: "wave.3.right", tint: 0xFA520F),
        .init(id: "aider", name: "Aider", command: "aider", bypassFlag: "--yes-always", symbol: "person.2", tint: 0xFFFFFF),
        .init(id: "cline", name: "Cline", command: "cline", symbol: "c.circle", tint: 0xDBDBDB),
        .init(id: "crush", name: "Crush", command: "crush", bypassFlag: "--yolo", symbol: "heart.fill", tint: 0x6C51FF),
        .init(id: "kilo", name: "Kilo Code", command: "kilo", symbol: "k.circle", tint: 0xFAF74F),
        .init(id: "kiro", name: "Kiro", command: "kiro-cli chat", bypassFlag: "--trust-all-tools", symbol: "ghost", tint: 0x9046FF),
        .init(id: "auggie", name: "Auggie", command: "auggie", symbol: "a.circle", tint: 0xDBDBDB),
        .init(id: "autohand", name: "Autohand", command: "autohand", bypassFlag: "--unrestricted", symbol: "hand.raised", tint: 0xDBDBDB),
        .init(id: "codebuff", name: "Codebuff", command: "codebuff", symbol: "b.circle", tint: 0xDBDBDB),
        .init(id: "command-code", name: "Command Code", command: "command-code", bypassFlag: "--yolo", symbol: "command", tint: 0xDBDBDB),
        .init(id: "continue", name: "Continue", command: "cn", symbol: "forward.end", tint: 0xDBDBDB),
    ]

    /// Places agents install into that a GUI app's PATH usually lacks.
    public static func extraDirectories(home: String = NSHomeDirectory()) -> [String] {
        ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
         "\(home)/.npm-packages/bin", "\(home)/.cargo/bin", "\(home)/.volta/bin", "\(home)/.asdf/shims",
         "\(home)/.yarn/bin", "\(home)/.opencode/bin", "\(home)/.grok/bin", "\(home)/.bun/bin"]
    }

    public static func isInstalled(_ executable: String, path: String) -> Bool {
        (path.split(separator: ":").map(String.init) + extraDirectories()).contains { dir in
            FileManager.default.isExecutableFile(atPath: "\(dir)/\(executable)")
        }
    }

    /// Installed agents first, keeping catalog order within each group.
    public static func sorted(_ agents: [AgentDescriptor]) -> [AgentDescriptor] {
        agents.filter(\.installed) + agents.filter { !$0.installed }
    }

    /// PATH as the person's login shell sets it; apps started from Finder get a bare one.
    public static func loginShellPath(shell: String) async -> String? {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = ["-l", "-i", "-c", "printf '__XTX__%s__XTX__' \"$PATH\""]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let parts = text.components(separatedBy: "__XTX__")
                continuation.resume(returning: parts.count >= 3 ? parts[1] : nil)
            }
            do { try p.run() } catch { continuation.resume(returning: nil) }
        }
    }
}

/// CPU from tick deltas between samples; memory from the kernel's counters.
final class LoadSampler {
    #if canImport(Darwin)
    private var previous: host_cpu_load_info?

    func sample() -> MachineLoad? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var cpu = 0.0
        if let prev = previous {
            let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
            let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
            let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
            let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
            let total = user + system + idle + nice
            cpu = total > 0 ? (user + system + nice) / total * 100 : 0
        }
        previous = info

        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        let page = Double(sysconf(_SC_PAGESIZE))
        let used = Double(UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return MachineLoad(cpuPercent: cpu, memoryUsedGB: used / 1_073_741_824, memoryTotalGB: total / 1_073_741_824, livePanes: 0)
    }
    #else
    private var previous: (busy: Double, total: Double)?

    /// `/proc/stat` first line for CPU, `/proc/meminfo` MemTotal − MemAvailable for memory.
    func sample() -> MachineLoad? {
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = stat.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else { return nil }
        let ticks = line.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard ticks.count >= 4 else { return nil }
        let idle = ticks[3] + (ticks.count > 4 ? ticks[4] : 0)
        let total = ticks.reduce(0, +)
        var cpu = 0.0
        if let prev = previous, total > prev.total {
            cpu = ((total - idle) - prev.busy) / (total - prev.total) * 100
        }
        previous = (total - idle, total)

        var memTotal = 0.0, memAvailable = 0.0
        if let meminfo = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) {
            for row in meminfo.split(separator: "\n") {
                let parts = row.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let kb = Double(parts[1]) else { continue }
                if parts[0] == "MemTotal:" { memTotal = kb }
                if parts[0] == "MemAvailable:" { memAvailable = kb }
            }
        }
        let gb = 1_048_576.0
        return MachineLoad(cpuPercent: max(0, min(100, cpu)), memoryUsedGB: (memTotal - memAvailable) / gb,
                           memoryTotalGB: memTotal / gb, livePanes: 0)
    }
    #endif
}
#endif
