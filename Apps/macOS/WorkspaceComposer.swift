import AppKit
import SwiftUI
import XTermXHost
import XTermXKit

/// Composed workspaces lay out lines along the grid's longer side; a square grid follows the person's choice.
enum WorkspaceGrid {
    static func byColumns(_ shape: (columns: Int, rows: Int), vertical: Bool) -> Bool {
        shape.rows > shape.columns || (shape.rows == shape.columns && vertical)
    }
    static func layout(_ ids: [String], limits: PaneGridLimits, vertical: Bool) -> SplitNode? {
        guard let shape = limits.shape(for: ids.count, vertical: vertical) else { return nil }
        let byColumns = byColumns(shape, vertical: vertical)
        return SplitNode.grid(ids, lines: byColumns ? shape.columns : shape.rows, vertical: byColumns)
    }
}

/// The new-workspace composer: folder and past sessions on the left, panes and options on the right.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var folder = ""
    @State private var agentCounts: [String: Int] = [:]
    @State private var terminals = 0
    @State private var vertical = false
    @State private var bypass = false
    @State private var isolate = false
    @State private var resumePicker = false
    @State private var prompt = ""
    @State private var shell = ""
    @State private var shells: [String] = []
    @State private var sessions: [ResumableSession] = []
    @State private var sessionFilter: String?
    @State private var chosen: Set<String> = []
    @State private var showAllSessions = false
    @State private var showMissing = false
    @State private var width: CGFloat = 1000
    @State private var started = false

    private static let presets = [1, 2, 4, 6, 8, 9, 10, 12, 16, 20]
    /// Agents whose past sessions XTermX can list.
    private static let sessionAgents = ["claude-code", "codex"]

    private struct PlannedPane: Identifiable {
        let id: Int
        let agent: AgentDescriptor?
        let session: ResumableSession?
    }

    var body: some View {
        let wide = width >= 920
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("XTermX").font(.system(size: 26, weight: .bold))
                        Text("Run many terminals, side by side.").foregroundStyle(muted)
                    }
                    Spacer()
                    if !model.workspaces.isEmpty {
                        Button("Cancel") { model.composing = false }.keyboardShortcut(.cancelAction)
                    }
                }
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                layout {
                    composePanel.frame(maxHeight: wide ? .infinity : nil, alignment: .top)
                    terminalsPanel.frame(width: wide ? 470 : nil)
                }
                .fixedSize(horizontal: false, vertical: wide)
            }
            .padding(28)
            .frame(maxWidth: 1240)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.chrome.canvas.color)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear(perform: start)
        .onChange(of: installed.map(\.id)) { if agentTotal == 0 && total <= 1 { choose(total: 1) } }
        .task(id: folder) { await loadSessions() }
    }

    // MARK: Compose

    private var composePanel: some View {
        panel("Compose", symbol: "square.and.pencil") {
            subsection("Working folder") {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(muted)
                    TextField("Choose a folder…", text: $folder).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    Button { browse() } label: { Label("Browse", systemImage: "folder.badge.plus") }.controlSize(.small)
                }
                .padding(.horizontal, 10).frame(height: 36)
                .background(theme.chrome.input.color, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.chrome.border.color))
            }
            if !model.recentFolders.isEmpty {
                subsection("Recent") {
                    VStack(spacing: 1) { ForEach(Array(model.recentFolders.prefix(5)), id: \.self, content: recentRow) }
                }
            }
            subsection("Resume sessions") {
                HStack(spacing: 10) {
                    Button("Select all") { filtered.filter(canChoose).forEach(choose) }
                    Text(verbatim: "·").foregroundStyle(muted)
                    Button("Clear all") { chosen = [] }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(muted)
                .disabled(filtered.isEmpty)
            } content: {
                sessionList
            }
        }
    }

    private func recentRow(_ path: String) -> some View {
        let on = (folder as NSString).expandingTildeInPath == path
        return Button { folder = path } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: (path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                Text(verbatim: (path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(on ? theme.chrome.accent.color : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(path)
    }

    @ViewBuilder private var sessionList: some View {
        HStack(spacing: 6) {
            filterChip(nil, Text("All (\(sessions.count))"), count: sessions.count)
            ForEach(sessionAgents) { agent in
                let count = sessions.filter { $0.agentID == agent.id }.count
                filterChip(agent, Text("\(agent.name) (\(count))"), count: count)
            }
        }
        if filtered.isEmpty {
            Text("No earlier Claude Code or Codex sessions in this folder.")
                .font(.system(size: 12)).foregroundStyle(muted).padding(.vertical, 6)
        } else {
            VStack(spacing: 1) { ForEach(showAllSessions ? filtered : Array(filtered.prefix(6)), content: sessionRow) }
            if filtered.count > 6 {
                Button { showAllSessions.toggle() } label: { showAllSessions ? Text("Show fewer") : Text("Show all (\(filtered.count))") }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(muted).frame(maxWidth: .infinity)
            }
        }
    }

    private func filterChip(_ agent: AgentDescriptor?, _ label: Text, count: Int) -> some View {
        let on = sessionFilter == agent?.id
        return Button { sessionFilter = agent?.id } label: {
            HStack(spacing: 4) {
                if let agent { AgentIcon(agent, size: 12) }
                label
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).frame(height: 24)
            .background(on ? theme.chrome.primary.color.opacity(0.18) : theme.chrome.card.color, in: Capsule())
            .overlay(Capsule().stroke(on ? theme.chrome.primary.color : theme.chrome.border.color))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(agent != nil && count == 0)
        .opacity(agent != nil && count == 0 ? 0.45 : 1)
    }

    private func sessionRow(_ session: ResumableSession) -> some View {
        let agent = model.manager.agents.first { $0.id == session.agentID }
        let on = chosen.contains(session.id)
        return Button { toggle(session) } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? theme.chrome.primary.color : muted)
                AgentIcon(agent, size: 14)
                Text(verbatim: session.title).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 8)
                Text(session.modified, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(muted)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(on ? theme.chrome.accent.color : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canChoose(session))
        .help(session.title)
    }

    // MARK: Terminals

    private var terminalsPanel: some View {
        panel("Terminals", symbol: "rectangle.split.3x3") {
            subsection("How many terminals?") {
                Picker("Layout", selection: $vertical) {
                    Text("Horizontal").tag(false)
                    Text("Vertical").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            } content: {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 6)], spacing: 6) {
                    ForEach(Self.presets, id: \.self) { n in
                        tile(on: total == n, enabled: fits(n)) { choose(total: n) } label: {
                            Text(verbatim: String(n)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
                tile(on: total > 0 && agentTotal == 0, enabled: fits(max(total, 1))) { choose(total: max(total, 1), blank: true) } label: {
                    Label("All blank", systemImage: "apple.terminal").font(.system(size: 12, weight: .medium))
                }
            }
            subsection("AI agents") {
                Text("used \(agentTotal) / \(total)").font(.system(size: 11)).monospacedDigit().foregroundStyle(muted)
            } content: {
                VStack(spacing: 0) {
                    ForEach(installed, content: agentRow)
                    terminalRow
                    if !missing.isEmpty {
                        DisclosureGroup(isExpanded: $showMissing) {
                            ForEach(missing) { agent in
                                HStack(spacing: 8) {
                                    AgentIcon(agent, size: 18).opacity(0.5)
                                    Text(verbatim: agent.name).font(.system(size: 13)).foregroundStyle(muted)
                                    Spacer()
                                    Text("Not installed").font(.system(size: 10)).foregroundStyle(muted)
                                }
                                .padding(.horizontal, 8).frame(height: 30)
                            }
                        } label: {
                            Text("Not installed (\(missing.count))").font(.system(size: 12)).foregroundStyle(muted)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
                .padding(4)
                .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.chrome.border.color))
                TextField("First message for the agents (optional)", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
            }
            subsection("Preview") {
                preview
                Group {
                    if let shape {
                        Text("\(total) panes · \(shape.columns)×\(shape.rows) · \(agentTotal) AI agents · \(terminals) terminals")
                    } else if total > 0 {
                        Text("Too many panes for this layout. Change the limits in Terminal settings.")
                    }
                }
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(muted).frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                option($bypass, "Enable Bypass Mode (auto-approve CLI permissions)", symbol: "checkmark.shield",
                       detail: "Agents run without asking for permission each time. Use with care.")
                option($isolate, "Isolate agents in Git worktrees", symbol: "arrow.triangle.branch",
                       detail: "Each agent pane starts in its own worktree and branch.")
                option($resumePicker, "Resume previous session", symbol: "clock.arrow.circlepath",
                       detail: "Claude Code and Codex open their own session list. A session chosen on the left wins.")
            }
            VStack(spacing: 6) {
                Button(action: create) {
                    Text("Create workspace").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 28)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(total == 0 || shape == nil)
                Text("Press ⌘↵ to create").font(.system(size: 11)).foregroundStyle(muted)
            }
        }
    }

    private func agentRow(_ agent: AgentDescriptor) -> some View {
        let count = agentCounts[agent.id, default: 0]
        let resumed = chosenCount(agent.id)
        return HStack(spacing: 8) {
            AgentIcon(agent, size: 18)
            Text(verbatim: agent.name).font(.system(size: 13))
            if resumed > 0 { Chip(systemImage: "clock.arrow.circlepath", text: String(localized: "\(resumed) resumed")) }
            Spacer()
            counter(count, minus: count > resumed, plus: terminals > 0 || fits(total + 1)) { setCount(agent.id, count + $0) }
        }
        .padding(.horizontal, 8).frame(height: 32)
    }

    private var terminalRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.terminal").font(.system(size: 13)).frame(width: 18)
            Text("Terminal").font(.system(size: 13))
            Text("Plain shell").font(.system(size: 10)).foregroundStyle(muted)
            Spacer()
            if shells.count > 1 {
                Picker("Shell for plain terminals", selection: $shell) {
                    ForEach(shells, id: \.self) { Text(verbatim: ($0 as NSString).lastPathComponent).tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
            }
            counter(terminals, minus: terminals > 0, plus: fits(total + 1)) { terminals += $0 }
        }
        .padding(.horizontal, 8).frame(height: 32)
    }

    private var preview: some View {
        let panes = plan
        return GeometryReader { geo in
            let frames = WorkspaceGrid.layout(panes.map { String($0.id) }, limits: model.gridLimits, vertical: vertical)?
                .frames(in: CGRect(origin: .zero, size: geo.size)) { _, _ in [] } ?? [:]
            ForEach(panes) { pane in
                if let r = frames[String(pane.id)] {
                    previewCell(pane).frame(width: max(r.width - 5, 4), height: max(r.height - 5, 4)).position(x: r.midX, y: r.midY)
                }
            }
        }
        .frame(height: 150)
        .padding(5)
        .background(theme.chrome.canvas.color, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.chrome.border.color))
    }

    private func previewCell(_ pane: PlannedPane) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(theme.chrome.card.color)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.chrome.border.color.opacity(0.6)))
            .overlay {
                if let agent = pane.agent { AgentIcon(agent, size: 16) } else { Image(systemName: "apple.terminal").foregroundStyle(muted) }
            }
            .overlay(alignment: .topTrailing) {
                if pane.session != nil || (resumePicker && pane.agent.map { AgentCatalog.canResume($0.id) } == true) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 8)).foregroundStyle(muted).padding(4)
                }
            }
    }

    // MARK: Pieces

    private var muted: Color { theme.chrome.mutedForeground.color }

    private func panel<Content: View>(_ title: LocalizedStringKey, symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Label { SectionLabel(title) } icon: {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.chrome.primary.color)
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.chrome.background.color, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.chrome.border.color))
    }

    private func subsection<Trailing: View, Content: View>(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing,
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func subsection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        subsection(title, trailing: { EmptyView() }, content: content)
    }

    private func tile<Content: View>(on: Bool, enabled: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Content) -> some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 32)
                .background(on ? theme.chrome.primary.color.opacity(0.18) : theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? theme.chrome.primary.color : theme.chrome.border.color, lineWidth: on ? 1.5 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }

    private func counter(_ value: Int, minus: Bool, plus: Bool, change: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            stepButton("minus", enabled: minus) { change(-1) }
            Text(verbatim: String(value)).font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(minWidth: 22)
                .foregroundStyle(value > 0 ? theme.chrome.foreground.color : muted)
            stepButton("plus", enabled: plus) { change(1) }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
                .background(theme.chrome.background.color, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.chrome.border.color))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }

    private func option(_ isOn: Binding<Bool>, _ title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        }
        .toggleStyle(.checkbox)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isOn.wrappedValue ? theme.chrome.accent.color : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.chrome.border.color))
    }

    // MARK: State

    private var installed: [AgentDescriptor] { model.manager.agents.filter(\.installed) }
    private var missing: [AgentDescriptor] { model.manager.agents.filter { !$0.installed } }
    private var sessionAgents: [AgentDescriptor] { model.manager.agents.filter { Self.sessionAgents.contains($0.id) } }
    private var agentTotal: Int { agentCounts.values.reduce(0, +) }
    private var total: Int { agentTotal + terminals }
    private var shape: (columns: Int, rows: Int)? { model.gridLimits.shape(for: total, vertical: vertical) }
    private var filtered: [ResumableSession] { sessions.filter { sessionFilter == nil || $0.agentID == sessionFilter } }
    private var chosenSessions: [ResumableSession] { sessions.filter { chosen.contains($0.id) } }
    private func chosenCount(_ agentID: String) -> Int { chosenSessions.filter { $0.agentID == agentID }.count }
    private func fits(_ count: Int) -> Bool { model.gridLimits.shape(for: count, vertical: vertical) != nil }
    private func canChoose(_ session: ResumableSession) -> Bool { installed.contains { $0.id == session.agentID } }

    /// Agents in list order, each one's chosen sessions first, then plain terminals.
    private var plan: [PlannedPane] {
        var panes: [PlannedPane] = []
        for agent in installed {
            let resumed = chosenSessions.filter { $0.agentID == agent.id }
            for i in 0..<agentCounts[agent.id, default: 0] {
                panes.append(PlannedPane(id: panes.count, agent: agent, session: resumed.indices.contains(i) ? resumed[i] : nil))
            }
        }
        for _ in 0..<terminals { panes.append(PlannedPane(id: panes.count, agent: nil, session: nil)) }
        return panes
    }

    private func start() {
        if folder.isEmpty { folder = model.recentFolders.first ?? NSHomeDirectory() }
        guard !started else { return }
        started = true
        shell = model.manager.shell
        shells = PaneManager.availableShells()
        if !shells.contains(shell) { shells.insert(shell, at: 0) }
        isolate = model.manager.isolateAgents
        choose(total: 1)
    }

    /// Presets keep the mix: the busiest agent takes added panes; terminals, then later agents, give way.
    private func choose(total n: Int, blank: Bool = false) {
        guard !blank, let first = installed.first(where: { $0.id == "claude-code" }) ?? installed.first else {
            agentCounts = [:]; chosen = []; terminals = n; return
        }
        if agentTotal == 0 {
            if terminals > 0 { terminals = n } else { agentCounts = [first.id: n] }
            return
        }
        var diff = n - total
        if diff > 0 {
            let busiest = installed.max { agentCounts[$0.id, default: 0] < agentCounts[$1.id, default: 0] } ?? first
            agentCounts[busiest.id, default: 0] += diff
            return
        }
        let fromTerminals = min(terminals, -diff)
        terminals -= fromTerminals; diff += fromTerminals
        for agent in installed.reversed() where diff < 0 {
            let cut = min(agentCounts[agent.id, default: 0], -diff)
            agentCounts[agent.id, default: 0] -= cut; diff += cut
            let keep = Set(chosenSessions.filter { $0.agentID == agent.id }.prefix(agentCounts[agent.id, default: 0]).map(\.id))
            chosen = chosen.filter { id in keep.contains(id) || !id.hasPrefix(agent.id + ":") }
        }
    }

    /// More agent panes take terminal slots first; fewer leave terminals behind. Never below the sessions chosen for it.
    private func setCount(_ agentID: String, _ value: Int) {
        let old = agentCounts[agentID, default: 0], value = max(value, chosenCount(agentID))
        if value > old { terminals = max(0, terminals - (value - old)) } else { terminals += old - value }
        agentCounts[agentID] = value
    }

    private func choose(_ session: ResumableSession) {
        chosen.insert(session.id)
        if agentCounts[session.agentID, default: 0] < chosenCount(session.agentID) { setCount(session.agentID, chosenCount(session.agentID)) }
    }

    private func toggle(_ session: ResumableSession) {
        if chosen.remove(session.id) == nil { choose(session) }
    }

    private func loadSessions() async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let path = (folder as NSString).expandingTildeInPath
        let found = await Task.detached(priority: .utility) { ResumableSessions.list(cwd: path) }.value
        guard !Task.isCancelled else { return }
        sessions = found
        chosen = []
        showAllSessions = false
        if let filter = sessionFilter, !found.contains(where: { $0.agentID == filter }) { sessionFilter = nil }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func create() {
        let cwd = folder.isEmpty ? nil : (folder as NSString).expandingTildeInPath
        let requests = plan.map { pane -> SpawnRequest in
            guard let agent = pane.agent else { return SpawnRequest(kind: .shell, cwd: cwd, shell: shell) }
            let resume = pane.session?.sessionID ?? (resumePicker && AgentCatalog.canResume(agent.id) ? "" : nil)
            // Agents look sessions up by folder, so a resumed pane stays in the original one.
            return SpawnRequest(kind: .agent, agentID: agent.id, cwd: cwd, initialInput: prompt.isEmpty ? nil : prompt,
                                bypass: bypass, resume: resume, isolate: resume == nil && isolate)
        }
        guard !requests.isEmpty else { return }
        model.newGridWorkspace(requests, vertical: vertical)
        chosen = []
        prompt = ""
    }
}
