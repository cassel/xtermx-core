import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import os
import XTermXHost
import XTermXKit
import XTermXTerminalUI

// MARK: - Window

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    /// Set once the welcome steps have been closed; until then they open with the window.
    @AppStorage("xtermx.onboarded") private var onboarded = false

    var body: some View {
        @Bindable var model = model
        content
            .sheet(isPresented: $model.tourVisible) { TourSheet() }
            .sheet(item: Binding(get: { model.worktreeReviews.first }, set: { value in if value == nil, !model.worktreeReviews.isEmpty { model.worktreeReviews.removeFirst() } })) { record in
                WorktreeReviewSheet(record: record)
            }
            .alert("Action needs attention", isPresented: Binding(get: { model.launchError != nil }, set: { if !$0 { model.launchError = nil } })) {
                Button("OK") { model.launchError = nil }
            } message: { Text(model.launchError ?? "") }
            .onAppear { if !onboarded { model.tourVisible = true } }
            .alert("Pane limit", isPresented: Binding(get: { model.layoutLimitMessage != nil }, set: { if !$0 { model.layoutLimitMessage = nil } })) {
                Button("OK") { model.layoutLimitMessage = nil }
            } message: { Text(model.layoutLimitMessage ?? "") }
    }

    private var content: some View {
        VStack(spacing: 0) {
            TitleBar()
            Divider().overlay(theme.chrome.border.color)
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    Sidebar().frame(width: 232)
                    Divider().overlay(theme.chrome.border.color)
                }
                ZStack {
                    theme.chrome.canvas.color
                    if let ws = model.active, !model.composing {
                        WorkspaceView(workspace: ws).id(ws.id)
                            .opacity(model.homeVisible ? 0 : 1)
                            .allowsHitTesting(!model.homeVisible)
                            .accessibilityHidden(model.homeVisible)
                    }
                    if model.homeVisible {
                        HomeDashboard()
                    } else if model.composing || model.workspaces.isEmpty {
                        WelcomeView()
                    }
                }
                if model.rightPanelVisible {
                    Divider().overlay(theme.chrome.border.color)
                    RightPanel().frame(width: 340)
                }
            }
        }
        .background(theme.chrome.background.color)
        .foregroundStyle(theme.chrome.foreground.color)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if model.paletteVisible { CommandPalette() }
            if model.switcher != nil { QuickSwitcher() }
        }
        .overlay(alignment: .topTrailing) {
            // Approval cards float over everything: an agent is waiting, and silence is a no.
            if !model.manager.approvals.isEmpty || !model.server.spawnGate.approvals.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.server.spawnGate.approvals) { approval in RemoteSpawnCard(approval: approval) }
                    ForEach(model.manager.approvals) { req in
                        ApprovalCard(req) { model.manager.respond(req.id, $0) }
                            .background(theme.chrome.popover.color, in: RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                    }
                }
                .frame(width: 340)
                .padding(.top, 46).padding(.trailing, 12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.manager.approvals)
    }
}

// MARK: - Title bar (tabs + status chips)

struct TitleBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var renaming: UUID?
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 72) // traffic lights
            IconButton("sidebar.left", help: "Toggle Sidebar ⌘B") { model.sidebarVisible.toggle() }
            IconButton("house", help: "Home") { model.showHome() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.workspaces) { ws in tab(ws) }
                    NewTabMenu()
                }
            }
            Spacer(minLength: 8)
            UsageMeters()
            AppMemoryBadge()
            if model.pendingLaunches > 0 { ProgressView().controlSize(.mini).help("Preparing terminals") }
            let counts = AgentCounts(panes: model.manager.panes, elsewhere: model.manager.overview.elsewhere)
            if counts.total > 0 {
                Button {
                    model.rightTab = .agents
                    model.rightPanelVisible = true
                } label: {
                    Chip(systemImage: "cpu", text: counts.waiting > 0 ? "\(counts.total) · \(counts.waiting) need you" : "\(counts.total) · \(counts.working) working",
                         tint: counts.waiting > 0 ? StateColors.blocked.color : nil)
                }
                .buttonStyle(.plain)
                .help(counts.label + " — panes and elsewhere on this Mac")
            }
            if let load = model.manager.machine {
                Chip(systemImage: "memorychip", text: String(format: "%.0f%% · %.1f/%.0f GB", load.cpuPercent, load.memoryUsedGB, load.memoryTotalGB))
                    .help("CPU and memory on this Mac")
            }
            if model.broadcast {
                Chip(systemImage: "dot.radiowaves.left.and.right", text: "Broadcast", tint: theme.chrome.broadcast.color)
            }
            RemoteAccessMenu()
            IconButton("sidebar.right", help: "Toggle Right Panel ⌘⇧B") { model.rightPanelVisible.toggle() }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(theme.chrome.background.color)
    }

    @ViewBuilder
    private func tab(_ ws: Workspace) -> some View {
        let active = ws.id == model.activeID && !model.homeVisible
        let panes = ws.layout.leaves.compactMap(model.pane)
        let blocked = panes.contains { $0.state == .blocked }
        let working = panes.contains { $0.state == .working }
        HStack(spacing: 6) {
            if renaming == ws.id {
                TextField("", text: $draft, onCommit: {
                    model.rename(ws.id, to: draft)
                    renaming = nil
                })
                .textFieldStyle(.plain).frame(width: 110)
            } else {
                Text(ws.name).lineLimit(1)
            }
            if ws.layout.leaves.count > 1 {
                Text("\(ws.layout.leaves.count)").font(.system(size: 10)).foregroundStyle(theme.chrome.mutedForeground.color)
            }
            Button { model.closeWorkspace(ws.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).opacity(active ? 0.8 : 0.4).help("Close tab")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(active ? theme.chrome.popover.color : .clear, in: RoundedRectangle(cornerRadius: 6))
        .background(blocked ? StateColors.blocked.color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) {
            if blocked {
                Rectangle().fill(StateColors.blocked.color).frame(height: 2)
            } else if working {
                TabGlide(color: StateColors.working.color)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            draft = ws.name
            renaming = ws.id
        }
        .onTapGesture { model.select(ws.id) }
        .contextMenu {
            Button("Rename Tab…") {
                draft = ws.name
                renaming = ws.id
            }
            Button("Close", role: .destructive) { model.closeWorkspace(ws.id) }
        }
        .help(blocked ? "Needs your input: jump to it" : ws.name)
    }
}

/// The 2px working bar that glides along the bottom of a tab.
struct TabGlide: View {
    let color: Color
    @State private var phase = false
    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(colors: [.clear, color, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * 0.38, height: 2)
                .offset(x: phase ? geo.size.width * 0.62 : 0)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2)
        .onAppear { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { phase = true } }
    }
}

struct NewTabMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("New tab…") { model.homeVisible = false; model.composing = true }
            Button("New terminal") { model.newWorkspace(SpawnRequest(kind: .shell)) }
            if !model.recentFolders.isEmpty {
                Section("Recent") {
                    ForEach(model.recentFolders.prefix(5), id: \.self) { folder in
                        Button((folder as NSString).abbreviatingWithTildeInPath) {
                            model.newWorkspace(SpawnRequest(kind: .shell, cwd: folder))
                        }
                    }
                }
            }
            Section("Agents") {
                ForEach(model.manager.agents.filter(\.installed)) { agent in
                    Menu(agent.name) {
                        Button("Start") { model.newWorkspace(SpawnRequest(kind: .agent, agentID: agent.id, cwd: model.recentFolders.first)) }
                        if agent.bypassFlag != nil {
                            Button("Bypass (skip permission prompts, this once)") {
                                model.newWorkspace(SpawnRequest(kind: .agent, agentID: agent.id, cwd: model.recentFolders.first, bypass: true))
                            }
                        }
                    }
                }
                if !model.manager.agents.contains(where: \.installed) {
                    Text("No agents found yet. Set them up in Settings")
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New tab ⌘T")
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @Environment(\.openSettings) private var openSettings

    @AppStorage("xtermx.sidebar.workspaces") private var workspacesOpen = true
    @AppStorage("xtermx.sidebar.terminals") private var terminalsOpen = true
    @AppStorage("xtermx.sidebar.recent") private var recentOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Button { model.showHome() } label: { Label("Home", systemImage: "house.fill") }
                    .buttonStyle(.plain)
                    .listRowBackground(model.homeVisible ? theme.chrome.accent.color : .clear)
                Section(isExpanded: $workspacesOpen) {
                    ForEach(model.workspaces) { ws in
                        let panes = ws.layout.leaves.compactMap(model.pane)
                        HStack {
                            Image(systemName: "square.split.2x1").foregroundStyle(theme.chrome.mutedForeground.color)
                            Text(ws.name).lineLimit(1)
                            Spacer()
                            if let worst = panes.map(\.state).min(by: { rank($0) < rank($1) }) { StateDot(worst) }
                            Text("\(panes.count)").font(.system(size: 10)).foregroundStyle(theme.chrome.mutedForeground.color)
                        }
                        .font(.system(size: 12))
                        .listRowBackground(ws.id == model.activeID && !model.homeVisible ? theme.chrome.accent.color : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(ws.id) }
                    }
                    Button { model.homeVisible = false; model.composing = true } label: { Label("New Workspace", systemImage: "plus") }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(theme.chrome.mutedForeground.color)
                } header: {
                    HStack {
                        SectionLabel("Workspaces")
                        Spacer()
                        Button { model.broadcast.toggle() } label: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(model.broadcast ? theme.chrome.broadcast.color : theme.chrome.mutedForeground.color)
                        }
                        .buttonStyle(.plain).help("Toggle broadcast mode ⌘⌥B")
                    }
                }

                Section(isExpanded: $terminalsOpen) {
                    Picker("Terminal list", selection: $recentOnly) {
                        Text("All").tag(false)
                        Text("Recent").tag(true)
                    }.pickerStyle(.segmented)
                    let live = model.workspaces.flatMap { $0.layout.leaves }
                    let ids = recentOnly ? RecentPaneList.ids(history: [model.focusedPane].compactMap { $0 } + model.focusHistory, live: live) : live
                    ForEach(ids, id: \.self) { id in
                        if let pane = model.pane(id) {
                            PaneRow(pane, agent: model.agent(for: pane))
                                .listRowBackground(id == model.focusedPane ? theme.chrome.accent.color : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { model.focus(id) }
                        }
                    }
                    if ids.isEmpty { Text(LocalizedStringKey(recentOnly ? "Focus a terminal to see it here." : "No open terminals.")).font(.caption) }
                } header: { SectionLabel("Terminals") }

                if !model.manager.approvals.isEmpty {
                    Section {
                        ForEach(model.manager.approvals) { req in
                            ApprovalCard(req) { model.manager.respond(req.id, $0) }
                        }
                    } header: { SectionLabel("Needs you") }
                }

                MachinesSection()
                SSHSidebarSection()
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().overlay(theme.chrome.border.color)
            HStack {
                Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(10)
        }
        .background(theme.chrome.background.color)
    }

    private func rank(_ s: PaneState) -> Int {
        switch s {
        case .blocked: 0
        case .working: 1
        case .idle: 2
        case .exited: 3
        }
    }
}

struct SectionLabel: View {
    let text: LocalizedStringKey
    @Environment(\.appTheme) private var theme
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).textCase(.uppercase).font(.system(size: 10, weight: .semibold)).tracking(0.5)
            .foregroundStyle(theme.chrome.mutedForeground.color)
    }
}

// MARK: - Panes

struct WorkspaceView: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let max = model.maximized, workspace.layout.leaves.contains(max) {
                PaneView(paneID: max)
                    .id(max)
            } else {
                SplitNodeView(node: workspace.layout)
            }
        }
        .overlay { if model.maximized == nil { PaneMessageOverlay(workspace: workspace) } }
        .padding(4)
    }
}

struct SplitNodeView: View {
    let node: SplitNode

    var body: some View {
        switch node {
        case .leaf(let id):
            PaneView(paneID: id)
                .id(id)
        case .split(let vertical, let children):
            SplitContainer(key: node.id, vertical: vertical, children: children)
        }
    }
}

/// Lays children out side by side (or stacked) with exact sizes from the model's fractions,
/// so every terminal knows its real size and the row never grows past the window.
/// A new split starts equal; dividers drag; ⌘P equalizes again.
struct SplitContainer: View {
    let key: String
    let vertical: Bool
    let children: [SplitNode]
    @Environment(AppModel.self) private var model
    @State private var dragStart: [CGFloat]?
    static let divider: CGFloat = 6
    static let minFraction: CGFloat = 0.08

    var body: some View {
        GeometryReader { geo in
            let total = vertical ? geo.size.height : geo.size.width
            let available = max(0, total - Self.divider * CGFloat(children.count - 1))
            let fractions = model.fractions(key, count: children.count)
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                ForEach(Array(children.enumerated()), id: \.element.id) { i, child in
                    SplitNodeView(node: child)
                        .frame(width: vertical ? geo.size.width : available * fractions[i],
                               height: vertical ? available * fractions[i] : geo.size.height)
                        .clipped()
                    if i < children.count - 1 {
                        handle(after: i, available: available)
                    }
                }
            }
        }
    }

    private func handle(after i: Int, available: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: vertical ? nil : Self.divider, height: vertical ? Self.divider : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? model.fractions(key, count: children.count)
                        if dragStart == nil { dragStart = start }
                        guard available > 0 else { return }
                        let delta = (vertical ? value.translation.height : value.translation.width) / available
                        let pair = start[i] + start[i + 1]
                        let left = min(max(start[i] + delta, Self.minFraction), pair - Self.minFraction)
                        var next = start
                        next[i] = left
                        next[i + 1] = pair - left
                        model.splitFractions[key] = next
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { model.splitFractions[key] = nil }
            .help("Drag to resize · double-click to equalize")
    }
}

struct PaneView: View {
    let paneID: String
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var binder = PaneFeedBinder()

    @State private var sshFilesVisible = false
    var body: some View {
        let palette = model.sshTheme(paneID, fallback: theme).terminal.adjusted(minimumContrast: model.appearance.contrast.rawValue)
        let pane = model.pane(paneID)
        let focused = model.focusedPane == paneID
        // The terminal stays underneath the chat, so it keeps its screen, size and feed.
        let chat = model.showsChat(paneID) ? model.tools.sessions.session(paneID: paneID) : nil
        VStack(spacing: 0) {
            if let pane { PaneHeader(pane: pane, leafID: paneID, focused: focused) }
            if let session = pane?.agentSession, model.remoteLeaves[paneID] == nil {
                PlanLimitBanner(session: session)
            }
            if let ssh = model.sshSessions[paneID] {
                HStack {
                    SSHConnectionStrip(session: ssh)
                    Button { sshFilesVisible.toggle() } label: { Label("Files", systemImage: "folder") }.padding(.trailing, 6)
                }
            }
            HStack(spacing: 0) {
            ZStack {
                TerminalSurface(feed: model.sshSessions[paneID]?.feed ?? binder.feed, theme: palette, fontSize: model.fontSize,
                                focused: chat == nil && focused && !model.homeVisible && !model.paletteVisible && model.switcher == nil, copyOnSelection: model.copyOnSelection)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(palette.background.color)
                    .opacity(chat == nil ? 1 : 0)
                    .allowsHitTesting(chat == nil)
                if let chat {
                    PaneChatView(paneID: paneID, session: chat, focused: focused)
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                binder.reclaim(paneID: paneID, model: model)
                model.focus(paneID)
            })
                if sshFilesVisible, let ssh = model.sshSessions[paneID] { Divider(); SSHFilesPanel(session: ssh) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { if !focused { RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(model.appearance.dimOpacity)).allowsHitTesting(false) } }
        .overlay { PaneRing(state: pane?.state ?? .idle, focused: focused, broadcast: model.broadcast) }
        .padding(2)
        .frame(minWidth: 160, minHeight: 100)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            binder.reclaim(paneID: paneID, model: model)
        }
        .onAppear { binder.bind(paneID: paneID, model: model) }
        .onDisappear { binder.unbind(model: model) }
    }
}

/// A slim strip under an agent pane's header while its plan is past 90 %: which window, and when it starts over.
struct PlanLimitBanner: View {
    let session: AgentSessionInfo
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    // Read here so turning the warning off in Settings › Usage hides the strip at once.
    @AppStorage(UsageMeterModel.Key.warn(.claude)) private var warnClaude = true
    @AppStorage(UsageMeterModel.Key.warn(.codex)) private var warnCodex = true

    var body: some View {
        TimelineView(.everyMinute) { context in
            let on = session.tool == .claude ? warnClaude : warnCodex
            if on, let alert = model.meter.alert(for: session, accounts: model.manager.overview.accounts, now: context.date) {
                HStack(spacing: 6) {
                    UsageRing(alert.percent, size: 9, lineWidth: 2)
                    Text("\(alert.windowName): \(Int(alert.percent.rounded(.down)))% of the plan used")
                        .font(.system(size: 10, weight: .semibold))
                    if let left = UsageFormat.until(alert.resetsAt, from: context.date) {
                        Text("· starts over in \(left)")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                    }
                    Spacer(minLength: 4)
                    Button { model.meter.dismiss(alert) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.chrome.mutedForeground.color)
                    .help("Hide until this window starts over")
                }
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(UsageLevel.critical.color.opacity(0.14))
                .overlay(alignment: .leading) { UsageLevel.critical.color.frame(width: 2) }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

/// Wires one pane's PTY to one terminal view: replay first, then live output.
@MainActor
final class PaneFeedBinder {
    let feed = TerminalFeed()

    private var listener: UUID?
    private var boundPaneID: String?
    private var size: (cols: Int, rows: Int)?

    private var hostSize: (cols: Int, rows: Int)?
    private var remote: (connection: HostConnection, pane: String, token: UUID)?

    func bind(paneID: String, model: AppModel) {
        guard model.sshSessions[paneID] == nil else { return }
        if boundPaneID != nil, boundPaneID != paneID {
            unbind(model: model)
            feed.reset()
            size = nil
            hostSize = nil
        }
        guard listener == nil, remote == nil else { return }
        boundPaneID = paneID
        // SwiftUI can replace the AppKit view while retaining this binder when a pane moves.
        // Its replacement needs a screen even if the program is idle and its size is unchanged.
        feed.onViewAttached = { [weak self, weak model] in
            guard let self, let model else { return }
            if let remote = self.remote {
                let token = remote.connection.attach(paneID: remote.pane) { [weak self] data in
                    self?.feed.receive(data)
                }
                self.remote = (remote.connection, remote.pane, token)
                remote.connection.detach(paneID: remote.pane, token: remote.token)
            } else if let session = model.manager.session(paneID) {
                self.feed.receive(session.snapshot())
                model.manager.redraw(paneID)
            }
        }
        if let leaf = model.remoteLeaves[paneID], let connection = model.machines.connection(leaf.machine) {
            // A terminal on another machine: same feed, the bytes travel over the encrypted link.
            feed.onInput = { [weak self, weak model] data in
                let typed = !TerminalReplies.isAutomatic(data) && model?.homeVisible != true
                if typed, let size = self?.size { connection.resize(paneID: leaf.pane, cols: size.cols, rows: size.rows) }
                if typed, model?.focusedPane != paneID { model?.focus(paneID) }
                connection.input(paneID: leaf.pane, bytes: data)
            }
            feed.onResize = { [weak self] cols, rows in
                self?.size = (cols, rows)
                connection.resize(paneID: leaf.pane, cols: cols, rows: rows)
            }
            let token = connection.attach(paneID: leaf.pane) { [weak self] data in self?.feed.receive(data) }
            remote = (connection, leaf.pane, token)
            return
        }
        // UIKit/AppKit can finish its first layout before SwiftUI calls onAppear.
        size = feed.size
        if let size { model.manager.setHomeSize(paneID, cols: size.cols, rows: size.rows) }
        if let session = model.manager.session(paneID) {
            hostSize = (session.info.cols, session.info.rows)
            feed.receive(session.snapshot())
        }
        feed.onInput = { [weak self, weak model] data in
            // The last device to type sets the size: take the pane back from a phone. What the terminal
            // answers or reports on its own (after a resize tmux and Codex query it) isn't typing.
            if TerminalReplies.isAutomatic(data) {
                // A local observer must not answer the program's geometry queries using the
                // Mac's wider viewport while that program is drawing for the phone.
                if let size = self?.size, let info = model?.manager.pane(paneID),
                   info.cols != size.cols || info.rows != size.rows { return }
            } else if model?.homeVisible != true, let size = self?.size {
                if model?.manager.session(paneID).map({ $0.info.cols != size.cols || $0.info.rows != size.rows }) == true {
                    Logger(subsystem: "us.cassel.xtermx", category: "size").debug("Mac input reclaimed the terminal size")
                }
                model?.manager.resize(paneID, cols: size.cols, rows: size.rows)
            }
            if !TerminalReplies.isAutomatic(data), model?.homeVisible != true, model?.focusedPane != paneID { model?.focus(paneID) }
            model?.input(data, from: paneID)
        }
        feed.onResize = { [weak self, weak model] cols, rows in
            self?.size = (cols, rows)
            // The window or the splits changed: a phone using the pane keeps it until it leaves.
            model?.manager.setHomeSize(paneID, cols: cols, rows: rows)
        }
        // A layout that settled before onResize was set never reached the terminal.
        if let natural = feed.size, natural.cols != size?.cols || natural.rows != size?.rows {
            size = natural
            model.manager.setHomeSize(paneID, cols: natural.cols, rows: natural.rows)
        }
        model.manager.redraw(paneID)
        listener = model.manager.addListener { [weak self, weak model] event in
            guard let self, let model else { return }
            switch event {
            case .output(let id, let data) where id == paneID: self.feed.receive(data)
            case .paneUpdated(let pane) where pane.id == paneID:
                guard self.hostSize?.cols != pane.cols || self.hostSize?.rows != pane.rows else { return }
                self.hostSize = (pane.cols, pane.rows)
                if let session = model.manager.session(paneID) { self.feed.receive(session.snapshot()) }
            default: break
            }
        }
    }

    func reclaim(paneID: String, model: AppModel) {
        guard remote == nil, model.sshSessions[paneID] == nil else { return }
        if let natural = feed.size { size = natural }
        if let size { model.manager.setHomeSize(paneID, cols: size.cols, rows: size.rows) }
        // The size-change listener reconstructs the view as the PTY returns home.
        // Ordinary clicks at an unchanged size preserve selection and scroll position.
        model.manager.reclaimHomeSize(paneID)
    }

    func unbind(model: AppModel) {
        if let listener { model.manager.removeListener(listener) }
        listener = nil
        if let remote { remote.connection.detach(paneID: remote.pane, token: remote.token) }
        remote = nil
        boundPaneID = nil
        feed.onViewAttached = nil
        feed.onInput = nil
        feed.onResize = nil
    }
}

/// Border that shows the pane's state: a moving ring while working, a breathing red ring when blocked.
struct PaneRing: View {
    let state: PaneState
    let focused: Bool
    let broadcast: Bool
    @Environment(\.appTheme) private var theme
    @Environment(AppModel.self) private var model
    @State private var phase: CGFloat = 0
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        ZStack {
            if model.appearance.border != .none {
            shape.stroke(broadcast ? theme.chrome.broadcast.color : (focused ? (model.appearance.focusColor ?? theme.chrome.primary).color : theme.chrome.paneBorder.color),
                         style: StrokeStyle(lineWidth: focused ? 2 : 1, dash: model.appearance.border == .dashed ? [6, 4] : []))
            if state == .working {
                shape.stroke(StateColors.working.color.opacity(focused ? 0.95 : 0.55),
                             style: StrokeStyle(lineWidth: 1.5, dash: [40, 260], dashPhase: phase))
            }
            if state == .blocked {
                shape.stroke(StateColors.blocked.color.opacity(breathe ? 1 : 0.55), lineWidth: 1.5)
                    .shadow(color: StateColors.blocked.color.opacity(0.5), radius: breathe ? 11 : 4)
            }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 3.6).repeatForever(autoreverses: false)) { phase = -300 }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

struct PaneHeader: View {
    let pane: PaneInfo
    /// The layout leaf: the pane id for local terminals, a `remote-…` id for other machines'.
    let leafID: String
    let focused: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    @State private var renaming = false
    @State private var name = ""

    private func editName() { name = pane.customName ?? ""; renaming = true }

    var body: some View {
        HStack(spacing: 6) {
            AgentIcon(model.agent(for: pane), size: 15)
            if let machine = model.machineName(leafID) {
                Label(machine, systemImage: "server.rack")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.chrome.primary.color.opacity(0.25), in: Capsule())
            }
            if let worktree = model.manager.isolatedPanes[pane.id] {
                Image(systemName: "arrow.triangle.branch").help("Isolated branch: " + worktree.branch)
            }
            Button(action: editName) { Image(systemName: "pencil") }
                .buttonStyle(.plain).accessibilityLabel("Rename pane…").help("Rename pane…").disabled(!model.canRenamePane(leafID))
            Text(pane.displayTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text((pane.cwd as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.chrome.mutedForeground.color)
                .lineLimit(1)
                .truncationMode(.head)
            if pane.openedByAgent, let parent = pane.parentID {
                Text("spawned by \(model.pane(parent)?.displayTitle ?? "an agent that has closed")")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.chrome.accent.color, in: Capsule())
                    .foregroundStyle(theme.chrome.mutedForeground.color)
                    .lineLimit(1)
            }
            if pane.state != .idle {
                Text(LocalizedStringKey(pane.state.label)).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(pane.state.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(pane.state.color)
            }
            Spacer(minLength: 4)
            if model.dictation.session.paneID == leafID {
                Button { model.dictation.stop() } label: { Label("Dictating…", systemImage: "mic.fill").font(.caption2) }
                    .foregroundStyle(theme.chrome.destructive.color).help(model.shortcutHint("Finish dictation ⌘⇧L"))
            }
            Group {
                if model.remoteLeaves[leafID] == nil, model.sshSessions[leafID] == nil {
                    Menu {
                        Picker("Remote access to this pane", selection: Binding(get: { model.server.paneSharing.access(pane.id) },
                                                                             set: { model.server.setPaneAccess(pane.id, to: $0) })) {
                            ForEach(PaneAccess.allCases) { access in Text(LocalizedStringKey(access.title)).tag(access) }
                        }
                    } label: { Image(systemName: model.server.paneSharing.access(pane.id).symbol) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Remote access: \(model.server.paneSharing.access(pane.id).title)")
                }
                if model.hasChat(leafID) {
                    let chat = model.showsChat(leafID)
                    IconButton(chat ? "apple.terminal" : "text.bubble", help: chat ? "Show Terminal ⌘⇧C" : "Show as Chat ⌘⇧C") {
                        model.focus(leafID)
                        model.toggleChat(leafID)
                    }
                }
                IconButton("rectangle.split.2x1", help: "Split Right ⌘D") {
                    model.focus(leafID)
                    model.split(vertical: false)
                }
                IconButton("rectangle.split.1x2", help: "Split Down ⌘⇧D") {
                    model.focus(leafID)
                    model.split(vertical: true)
                }
                IconButton(model.maximized == leafID ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           help: "Maximize Pane ⌘⇧M") {
                    model.focus(leafID)
                    model.toggleMaximize()
                }
                IconButton("xmark", help: "Close Terminal Pane ⌘W") { model.closePane(leafID) }
            }
            .opacity(focused ? 1 : 0.6)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(focused ? theme.chrome.popover.color : theme.chrome.card.color.opacity(0.9))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(focused ? 0.25 : 0.2)).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.focus(leafID)
            model.toggleMaximize()
        }
        .onTapGesture { model.focus(leafID) }
        .alert("Name this pane", isPresented: $renaming) {
            TextField("Pane name", text: $name)
            Button("Save") { model.renamePane(leafID, to: name) }
                .disabled(!PaneNameRules.isValid(name))
            Button("Use automatic name") { model.renamePane(leafID, to: "") }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Shown on Mac, iPhone and Watch. Up to 60 characters.") }
        .contextMenu {
            Button("Rename pane…", action: editName).disabled(!model.canRenamePane(leafID))
            Divider()
            Button("Split Right") {
                model.focus(leafID)
                model.split(vertical: false)
            }
            Button("Split Down") {
                model.focus(leafID)
                model.split(vertical: true)
            }
            Button("Clear Screen") { model.write(leafID, Data([0x0c])) }
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: pane.cwd) }
            Divider()
            Button("Close", role: .destructive) { model.closePane(leafID) }
        }
    }
}

// MARK: - Welcome / compose

/// Wrapping row of small views.
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

// MARK: - Right panel

struct RightPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("", selection: $model.rightTab) {
                ForEach(RightTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(8)
            Divider().overlay(theme.chrome.border.color)
            switch model.rightTab {
            case .controlRoom: ControlRoomView()
            case .agents: AgentActivityView()
            case .devices: ScrollView { DevicesView().padding(12) }
            }
        }
        .background(theme.chrome.background.color)
    }
}

struct ControlRoomView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var text = ""
    @State private var execute = false
    @State private var members: Set<String> = []

    var body: some View {
        let panes = model.active?.layout.leaves.compactMap(model.pane) ?? []
        let messages = model.activeID.flatMap { model.rooms[$0] } ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Route messages", selection: Binding(get: { model.activeID.flatMap { model.roomCoordinators[$0] } }, set: { model.chooseCoordinator($0, members: Array(members)) })) {
                    Text("Keep notes here").tag(nil as String?)
                    ForEach(panes.filter { $0.agentID != nil && model.remoteLeaves[$0.id] == nil && $0.state != .exited }) { pane in
                        Text("Via \(pane.displayTitle)").tag(Optional(pane.id))
                    }
                }
                Text("The coordinator receives messages first and may forward to the checked agents. Run still targets the checked terminals.")
                    .font(.caption2).foregroundStyle(theme.chrome.mutedForeground.color)
                SectionLabel("Members · \(panes.count)")
                ForEach(panes) { pane in
                    Toggle(isOn: Binding(get: { members.contains(pane.id) },
                                         set: { on in if on { members.insert(pane.id) } else { members.remove(pane.id) } })) {
                        PaneRow(pane, agent: model.agent(for: pane))
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(10)
            Divider().overlay(theme.chrome.border.color)
            SectionLabel("Discussion").padding(.horizontal, 10).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if messages.isEmpty {
                        Text("No room messages yet.")
                            .font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)
                    }
                    ForEach(messages) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(m.author).font(.system(size: 11, weight: .semibold))
                                if m.executed {
                                    Text("Execute").font(.system(size: 9)).padding(.horizontal, 4)
                                        .background(theme.chrome.activity.color.opacity(0.25), in: Capsule())
                                }
                                Spacer()
                                Text(m.date, style: .time).font(.system(size: 9)).foregroundStyle(theme.chrome.mutedForeground.color)
                            }
                            Text(m.text).font(.system(size: 12)).textSelection(.enabled)
                        }
                        .padding(8)
                        .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
            }
            Divider().overlay(theme.chrome.border.color)
            VStack(alignment: .trailing, spacing: 6) {
                TextField(execute ? "Runs in each chosen terminal…" : "Message the room…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5)
                    .onSubmit(send)
                HStack {
                    Picker("", selection: $execute) {
                        Text("Send").tag(false)
                        Text("Execute").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    Spacer()
                    Button(LocalizedStringKey(execute ? "Run" : "Send"), action: send).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(10)
        }
        .onAppear { members = Set(panes.map(\.id)); model.updateRoomMembers(Array(members)) }
        .onChange(of: model.activeID) { _, _ in members = Set(panes.map(\.id)); model.updateRoomMembers(Array(members)) }
        .onChange(of: members) { _, _ in model.updateRoomMembers(Array(members)) }
        .onChange(of: panes.map(\.id)) { _, ids in
            members.formIntersection(ids)
            if let id = model.activeID, let head = model.roomCoordinators[id], !ids.contains(head) { model.chooseCoordinator(nil) }
            model.updateRoomMembers(Array(members))
        }
    }

    private func send() {
        model.roomSend(text, to: Array(members), execute: execute)
        text = ""
    }
}

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var address = ""
    @State private var addresses: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Remote access", isOn: Binding(get: { model.remoteEnabled }, set: { model.remoteEnabled = $0 }))
                .toggleStyle(.switch)
            if let error = model.server.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(theme.chrome.destructive.color)
            }
            if model.server.isRunning {
                if !addresses.isEmpty {
                Picker("Address", selection: $address) {
                    ForEach(addresses, id: \.self) { a in
                        Text(HostIdentity.isTailscaleAddress(a) ? "\(a) (Tailscale)" : a).tag(a)
                    }
                }
                let url = model.server.pairing(addresses: [address] + addresses.filter { $0 != address }).url
                QRCodeView(text: url.absoluteString)
                    .frame(width: 200, height: 200)
                    .frame(maxWidth: .infinity)
                Text("Scan with XTermX on iPhone. The Apple Watch pairs through the iPhone.")
                    .font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)
                HStack {
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Spacer()
                    Button("Forget all devices", role: .destructive) { model.server.rotateSecret() }
                        .help("Makes a new secret; every device must scan again")
                }
                .controlSize(.small)
                } else { ProgressView() }
                Toggle("Let devices open new panes", isOn: Binding(get: { model.server.allowRemoteSpawn },
                                                                  set: { model.server.allowRemoteSpawn = $0 }))
                Toggle("Receive files from devices", isOn: Binding(get: { model.server.permissions.sendFiles }, set: { model.server.permissions.sendFiles = $0 }))
                    .toggleStyle(.switch)
                Text("Configure attachment limits in Settings → Remote access. Older Rooms & files uploads: up to 4 MB.")
                    .font(.caption).foregroundStyle(theme.chrome.mutedForeground.color)
            }
            SectionLabel("Devices · \(model.deviceRoster.count)")
            ForEach(model.deviceRoster) { device in
                ConnectedDeviceRow(device: device)
            }
        }
        .task(id: model.server.isRunning) {
            let found = await Task.detached(priority: .userInitiated) { HostIdentity.addresses() }.value
            guard !Task.isCancelled else { return }
            addresses = found
            if !found.contains(address) { address = found.first ?? "" }
        }
    }
}

struct QRCodeView: View {
    let text: String
    @State private var image: NSImage?
    var body: some View {
        Group {
        if let image {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
        } else { ProgressView() }
        }
        .task(id: text) { image = Self.render(text) }
    }

    static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Command palette

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @State private var query = ""
    @FocusState private var focused: Bool

    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let run: () -> Void
    }

    var actions: [Action] {
        var list: [Action] = [
            Action(title: InterfaceLanguage.current.text("New workspace tab"), symbol: "plus") { model.homeVisible = false; model.composing = true },
            Action(title: InterfaceLanguage.current.text("Split pane right"), symbol: "rectangle.split.2x1") { model.split(vertical: false) },
            Action(title: InterfaceLanguage.current.text("Split pane down"), symbol: "rectangle.split.1x2") { model.split(vertical: true) },
            Action(title: InterfaceLanguage.current.text("Toggle broadcast mode"), symbol: "dot.radiowaves.left.and.right") { model.broadcast.toggle() },
            Action(title: InterfaceLanguage.current.text("Control Room"), symbol: "bubble.left.and.bubble.right") {
                model.rightTab = .controlRoom
                model.rightPanelVisible = true
            },
            Action(title: InterfaceLanguage.current.text("Remote access & devices"), symbol: "globe") {
                model.rightTab = .devices
                model.rightPanelVisible = true
            },
        ]
        for agent in model.manager.agents where agent.installed {
            list.append(Action(title: String(format: InterfaceLanguage.current.text("Open %@ here"), agent.name), symbol: agent.symbol) {
                model.split(vertical: false, SpawnRequest(kind: .agent, agentID: agent.id, cwd: model.focusedPane.flatMap(model.pane)?.cwd))
            })
        }
        for pane in model.manager.panes {
            list.append(Action(title: String(format: InterfaceLanguage.current.text("Go to %@"), pane.displayTitle), symbol: "terminal") { model.focus(pane.id) })
        }
        return list
    }

    var body: some View {
        let filtered = actions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.paletteVisible = false }
            VStack(spacing: 0) {
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).padding(12)
                    .focused($focused)
                    .onSubmit {
                        filtered.first?.run()
                        model.paletteVisible = false
                    }
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered) { action in
                            Button {
                                action.run()
                                model.paletteVisible = false
                            } label: {
                                Label(action.title, systemImage: action.symbol)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 520)
            .background(theme.chrome.popover.color, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.chrome.border.color))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onExitCommand { model.paletteVisible = false }
    }
}

// MARK: - Small controls

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }
    @Environment(\.appTheme) private var theme
    @Environment(AppModel.self) private var model

    var body: some View {
        let hint = model.shortcutHint(help)
        Button {
            HoverHint.shared.hide()
            action()
        } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hint)
        .onHover { inside in inside ? HoverHint.shared.show(hint, theme: theme) : HoverHint.shared.hide() }
        .onDisappear { HoverHint.shared.hide() }
    }
}

/// The tooltip for icon buttons, with the shortcut as a key cap. SwiftUI's `.help` restarts its delay
/// whenever the view updates, and pane headers update constantly while an agent animates the title,
/// so its tooltip never appeared there; this one lives in its own window and ignores re-renders.
@MainActor
final class HoverHint {
    static let shared = HoverHint()
    private var panel: NSPanel?
    private var pending: Task<Void, Never>?

    func show(_ text: String, theme: AppTheme, after delay: Duration = .milliseconds(600)) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.present(text, theme: theme)
        }
    }

    func hide() {
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
    }

    private func present(_ text: String, theme: AppTheme) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: HintLabel(text: text, theme: theme))
        panel.contentView = host
        let size = host.fittingSize
        // Under the pointer like a system tooltip, kept on the pointer's screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 18)
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        if origin.y < screen.minY + 4 { origin.y = mouse.y + 12 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        return panel
    }
}

/// "Split Right ⌘D" → "Split Right" plus a ⌘D key cap.
private struct HintLabel: View {
    let text: String
    let theme: AppTheme

    var body: some View {
        let (title, keys) = Self.split(text)
        HStack(spacing: 6) {
            Text(title).foregroundStyle(theme.chrome.foreground.color)
            if let keys {
                Text(keys)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.chrome.muted.color, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(theme.chrome.foreground.color)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(theme.chrome.popover.color, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.chrome.border.color, lineWidth: 0.5))
        .fixedSize()
    }

    /// The last word is a shortcut when it starts with a modifier glyph.
    static func split(_ text: String) -> (String, String?) {
        guard let space = text.lastIndex(of: " "), let first = text[text.index(after: space)...].first,
              "⌘⌃⌥⇧".contains(first) else { return (text, nil) }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
}

struct Chip: View {
    let systemImage: String
    let text: String
    var tint: Color?
    @Environment(\.appTheme) private var theme
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).frame(height: 20)
            .foregroundStyle(tint ?? theme.chrome.mutedForeground.color)
            .background((tint ?? theme.chrome.accent.color).opacity(tint == nil ? 1 : 0.15), in: Capsule())
    }
}

// MARK: - Agent activity

struct AgentActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        let opened = model.manager.panes.filter(\.openedByAgent)
        let sessions = model.manager.panes.filter { $0.agentSession != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Claude Code & Codex hooks", isOn: Binding(get: { model.agentHooksInstalled }, set: { model.setAgentHooks($0) }))
                    .toggleStyle(.switch)
                Text("Status, tokens, plan limits, and answering permissions and questions here, on your iPhone and on your Watch. The hooks do nothing outside XTermX panes.")
                    .font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)
                if let note = model.agentHooksMessage {
                    Text(note).font(.system(size: 11)).foregroundStyle(StateColors.blocked.color)
                }

                let overview = model.manager.overview
                AgentCountsView(AgentCounts(panes: model.manager.panes, elsewhere: overview.elsewhere))
                    .foregroundStyle(theme.chrome.foreground.color)

                if !overview.accounts.isEmpty {
                    SectionLabel("Plan limits")
                    ForEach(overview.accounts) { AccountUsageView($0) }
                }

                SectionLabel("Sessions in panes · \(sessions.count)")
                if sessions.isEmpty {
                    Text(model.agentHooksInstalled ? "Start claude or codex in a pane." : "Turn on the hooks, then start claude or codex in a pane.")
                        .font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)
                }
                ForEach(sessions) { pane in
                    if let session = pane.agentSession {
                        AgentSessionDetail(pane: pane, session: session)
                            .contentShape(Rectangle())
                            .onTapGesture { model.focus(pane.id) }
                    }
                }

                if let today = overview.today() {
                    SectionLabel("Today in panes")
                    AgentDayView(today)
                }

                if !overview.elsewhere.isEmpty {
                    SectionLabel("Elsewhere on this Mac · \(overview.elsewhere.count)")
                    ForEach(overview.elsewhere, id: \.sessionID) { session in
                        AgentElsewhereRow(session, agent: model.manager.agents.first { $0.id == session.tool.catalogID })
                    }
                }

                let feed = AgentFeedItem.merge(panes: model.manager.panes, elsewhere: overview.elsewhere, limit: 30)
                if !feed.isEmpty {
                    SectionLabel("Activity")
                    ForEach(feed) { item in
                        AgentFeedRow(item)
                            .contentShape(Rectangle())
                            .onTapGesture { if let pane = item.paneID { model.focus(pane) } }
                    }
                }

                let past = overview.history.filter { $0.endedAt != nil }
                if !past.isEmpty {
                    SectionLabel("Recent sessions in panes")
                    ForEach(past.prefix(15)) { AgentHistoryRow($0) }
                }

                Divider().overlay(theme.chrome.border.color)
                Toggle("Let agents open panes", isOn: Binding(get: { model.agentPanesAllowed }, set: { model.agentPanesAllowed = $0 }))
                    .toggleStyle(.switch)
                Text("Each request shows a card here, on your iPhone and on your Watch. No answer in 120 s means no.")
                    .font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)

                SectionLabel("Opened by agents · \(opened.count)")
                if opened.isEmpty {
                    Text("None yet.").font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)
                }
                ForEach(opened) { pane in
                    VStack(alignment: .leading, spacing: 2) {
                        PaneRow(pane, agent: model.agent(for: pane))
                        if let parent = pane.parentID.flatMap(model.pane) {
                            Text("by \(parent.displayTitle)").font(.system(size: 10)).foregroundStyle(theme.chrome.mutedForeground.color)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.focus(pane.id) }
                }

                SectionLabel("Tool calls")
                if model.tools.recentCalls.isEmpty {
                    Text("No agent has called a tool yet.").font(.system(size: 11)).foregroundStyle(theme.chrome.mutedForeground.color)
                }
                ForEach(model.tools.recentCalls) { call in
                    HStack(spacing: 6) {
                        Image(systemName: call.ok ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(call.ok ? StateColors.done.color : StateColors.blocked.color)
                        Text(call.tool).font(.system(size: 11, design: .monospaced))
                        if !call.detail.isEmpty {
                            Text(call.detail).font(.system(size: 10, design: .monospaced)).foregroundStyle(StateColors.blocked.color)
                        }
                        Spacer()
                        Text(model.pane(call.paneID)?.displayTitle ?? "closed pane").font(.system(size: 10)).lineLimit(1)
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                        Text(call.at, style: .time).font(.system(size: 9)).foregroundStyle(theme.chrome.mutedForeground.color)
                    }
                }

                SectionLabel("Endpoint")
                Text(model.tools.url?.absoluteString ?? "starting…")
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(theme.chrome.mutedForeground.color)
            }
            .padding(12)
        }
    }
}

/// One agent session in the Agents tab: what it does, its tokens and context, its subagents.
struct AgentSessionDetail: View {
    let pane: PaneInfo
    let session: AgentSessionInfo
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AgentIcon(model.manager.agents.first { $0.id == session.tool.catalogID }, size: 16)
                Text(pane.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                StateDot(session.paneState)
            }
            AgentSessionSummary(session)
            let t = session.tokens
            Text("in \(UsageFormat.tokens(t.input)) · out \(UsageFormat.tokens(t.output)) · cache \(UsageFormat.tokens(t.cacheRead))/\(UsageFormat.tokens(t.cacheWrite))"
                 + (session.lastTool.map { " · \($0)" } ?? ""))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.chrome.mutedForeground.color).lineLimit(1)
            if let used = session.contextTokens, let window = session.contextWindow, window > 0 {
                ProgressView(value: Double(min(used, window)), total: Double(window)) {
                    Text("context \(Int(Double(used) / Double(window) * 100))%").font(.system(size: 9))
                }
            }
            if let last = session.activity.last {
                Label(last.text, systemImage: last.symbol).font(.system(size: 10)).lineLimit(1)
            }
            ForEach(session.shells) { AgentShellRow($0) }
            if !session.tasks.isEmpty { AgentTaskList(session.tasks) }
            ForEach(session.subagents.prefix(8)) { sub in
                HStack(spacing: 6) {
                    Circle().fill(sub.running ? StateColors.working.color : theme.chrome.mutedForeground.color).frame(width: 5, height: 5)
                    Text(sub.name).font(.system(size: 10, weight: .medium))
                    Text(sub.detail).font(.system(size: 10)).foregroundStyle(theme.chrome.mutedForeground.color).lineLimit(1)
                    Spacer()
                    if sub.tokens.total > 0 {
                        Text(UsageFormat.tokens(sub.tokens.total)).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.chrome.mutedForeground.color)
                    }
                }
                .padding(.leading, 12)
            }
        }
        .padding(8)
        .background(theme.chrome.card.color, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Quick Terminal Switcher

/// ⌃⇥ list of every terminal, most recent first; ⌃⇥ again moves down, releasing ⌃ picks.
struct QuickSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme

    var body: some View {
        let order = model.switcherOrder
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { model.switcher = nil }
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Terminals · release ⌃ to switch").padding(.horizontal, 10).padding(.top, 8)
                ForEach(Array(order.enumerated()), id: \.element) { i, id in
                    if let pane = model.pane(id) {
                        HStack(spacing: 8) {
                            PaneRow(pane, agent: model.agent(for: pane))
                            Text(model.workspace(containing: id)?.name ?? "")
                                .font(.system(size: 10)).foregroundStyle(theme.chrome.mutedForeground.color)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(i == model.switcher ? theme.chrome.primary.color.opacity(0.35) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.switcher = i
                            model.switcherCommit()
                        }
                    }
                }
            }
            .padding(6)
            .frame(width: 460)
            .background(theme.chrome.popover.color, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.chrome.border.color))
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        }
        .onExitCommand { model.switcher = nil }
    }
}
