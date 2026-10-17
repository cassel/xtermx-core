import AppKit
import SwiftUI
import XTermXHost
import XTermXKit

/// An agent pane shown as a conversation, turn by turn: what the person said, then the agent's
/// part marked by a line in its tint — its tool calls folded into one row, its answers in markdown —
/// and a message box that types into the pane.
struct PaneChatView: View {
    let paneID: String
    let session: AgentSessionTracker.Registration
    let focused: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.appTheme) private var theme
    @AppStorage("xtermx.chatTheme") private var chatTheme = AgentChatTheme.auto.rawValue
    @State private var entries: [AgentChatEntry] = []
    @State private var loaded = false
    @State private var message = ""
    @State private var inputHeight: CGFloat = 18
    /// Turns whose tool calls are unfolded.
    @State private var openTools: Set<String> = []

    private var palette: ChatPalette { ChatPalette(AgentChatTheme(rawValue: chatTheme) ?? .auto, window: theme) }
    private var textSize: CGFloat { model.fontSize + 1 }

    var body: some View {
        let palette = palette
        let turns = AgentChatTurn.group(entries)
        let approvals = model.manager.approvals.filter { $0.paneID == paneID }
        let pane = model.pane(paneID)
        let agent = pane.flatMap(model.agent(for:)) ?? model.manager.agents.first { $0.id == session.tool.catalogID }
        let speaker = ChatSpeaker(agent: agent, name: session.tool.name,
                                  tint: agent.map { RGB($0.tint).color } ?? theme.chrome.primary.color)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(turns) { turn in
                            ChatTurnView(turn: turn, speaker: speaker, palette: palette, textSize: textSize,
                                         working: turn.id == turns.last?.id && pane?.state == .working,
                                         toolsOpen: Binding(get: { openTools.contains(turn.id) },
                                                            set: { open in if open { openTools.insert(turn.id) } else { openTools.remove(turn.id) } }))
                        }
                        ForEach(approvals) { req in
                            ApprovalCard(req) { model.manager.respond(req.id, $0) }
                        }
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                .overlay {
                    if loaded, turns.isEmpty, approvals.isEmpty {
                        Label("Nothing in this session yet", systemImage: "text.bubble")
                            .font(.system(size: 12)).foregroundStyle(palette.muted)
                    }
                }
                .onChange(of: entries.last?.id) { proxy.scrollTo(Self.end, anchor: .bottom) }
                .onChange(of: approvals.count) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            inputBar(palette, speaker: speaker)
        }
        .background(palette.background)
        .task(id: session.transcriptPath) { await follow() }
    }

    private static let end = "chat-end"

    private func inputBar(_ palette: ChatPalette, speaker: ChatSpeaker) -> some View {
        let empty = AgentChatInput.payload(message) == nil
        return HStack(alignment: .bottom, spacing: 8) {
            ChatInputField(text: $message, height: $inputHeight, focused: focused && !model.paletteVisible && model.switcher == nil,
                           fontSize: textSize, textColor: NSColor(palette.text), onSend: send)
                .frame(height: inputHeight)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Ask \(speaker.name)…   ↩ send · ⇧↩ new line")
                            .font(.system(size: textSize))
                            .foregroundStyle(palette.muted)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(empty ? palette.muted : .white)
                    .frame(width: 24, height: 22)
                    .background(empty ? palette.chip : palette.accent, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .help("Type it into the pane (↩)")
        }
        .padding(.leading, 8).padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(palette.input, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? speaker.tint.opacity(0.6) : palette.border))
        .padding(8)
    }

    private func send() {
        guard let text = AgentChatInput.payload(message) else { return }
        model.manager.sendLine(paneID, text)
        message = ""
    }

    /// Reads the transcript again about every second while the chat is on screen, off the main
    /// thread, and only when the file's size changed.
    private func follow() async {
        var follower = AgentChatFollower(path: session.transcriptPath, tool: session.tool)
        entries = []
        loaded = false
        while !Task.isCancelled {
            let current = follower
            let (next, read) = await Task.detached(priority: .utility) {
                var f = current
                let read = f.poll()
                return (f, read)
            }.value
            guard !Task.isCancelled else { return }
            follower = next
            if let read, read != entries { entries = read }
            loaded = true
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// The agent in the pane, as the chat labels its turns.
struct ChatSpeaker {
    let agent: AgentDescriptor?
    let name: String
    let tint: Color
}

/// The chat's colors: its own dark or light set, or the window theme's (Auto).
struct ChatPalette {
    var background, text, muted, card, chip, code, input, border, accent: Color

    init(_ choice: AgentChatTheme, window theme: AppTheme) {
        let accent = RGB(0x128CE2).color
        switch choice {
        case .dark:
            (background, text, muted) = (RGB(0x17191D).color, RGB(0xE6E8EB).color, RGB(0x8E949C).color)
            (card, chip, code) = (RGB(0x23272E).color, RGB(0x2D333B).color, RGB(0x101215).color)
            (input, border, self.accent) = (RGB(0x1F2328).color, RGB(0x343B45).color, accent)
        case .light:
            (background, text, muted) = (RGB(0xFBFBFC).color, RGB(0x1E2227).color, RGB(0x6A717A).color)
            (card, chip, code) = (RGB(0xEEF1F4).color, RGB(0xE3E7EC).color, RGB(0xF2F4F6).color)
            (input, border, self.accent) = (RGB(0xFFFFFF).color, RGB(0xD3D8DE).color, accent)
        case .auto:
            (background, text, muted) = (theme.terminal.background.color, theme.chrome.foreground.color, theme.chrome.mutedForeground.color)
            (card, chip, code) = (theme.chrome.popover.color, theme.chrome.accent.color, theme.chrome.canvas.color)
            (input, border, self.accent) = (theme.chrome.popover.color, theme.chrome.border.color, theme.chrome.primary.color)
        }
    }
}

/// One exchange: the person's message, then the agent's part beside a line in its tint.
private struct ChatTurnView: View {
    let turn: AgentChatTurn
    let speaker: ChatSpeaker
    let palette: ChatPalette
    let textSize: CGFloat
    let working: Bool
    @Binding var toolsOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt = turn.prompt { ChatPrompt(entry: prompt, palette: palette, textSize: textSize) }
            if !turn.tools.isEmpty || !turn.answers.isEmpty || working {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        AgentIcon(speaker.agent, size: 14)
                        Text(speaker.name).font(.system(size: textSize - 3, weight: .semibold)).foregroundStyle(palette.muted)
                        if working {
                            Circle().fill(StateColors.working.color).frame(width: 5, height: 5)
                            Text("working").font(.system(size: textSize - 3)).foregroundStyle(StateColors.working.color)
                        }
                    }
                    if !turn.tools.isEmpty { ChatTools(tools: turn.tools, open: $toolsOpen, palette: palette, textSize: textSize) }
                    ForEach(turn.answers) { ChatAnswer(text: $0.text, palette: palette, textSize: textSize) }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(speaker.tint.opacity(0.85)).frame(width: 2)
                }
            }
        }
    }
}

/// What the person said: a message in a card, or a slash command as a tag.
private struct ChatPrompt: View {
    let entry: AgentChatEntry
    let palette: ChatPalette
    let textSize: CGFloat

    var body: some View {
        if entry.kind == .command {
            Label(entry.text, systemImage: "chevron.right.2")
                .font(.system(size: textSize - 2, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.text)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(palette.chip, in: RoundedRectangle(cornerRadius: 5))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.fill").font(.system(size: textSize - 3)).foregroundStyle(palette.muted)
                Text(entry.text)
                    .font(.system(size: textSize))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border.opacity(0.7)))
        }
    }
}

/// A turn's tool calls folded into one row ("4 tool calls · the last one"); a click lists them all.
private struct ChatTools: View {
    let tools: [AgentChatEntry]
    @Binding var open: Bool
    let palette: ChatPalette
    let textSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: textSize - 5, weight: .bold))
                    Image(systemName: "hammer")
                    Text("Tool calls: \(tools.count)").fontWeight(.medium)
                    if !open, let last = tools.last {
                        Text("· \(last.text)").lineLimit(1).truncationMode(.middle)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Fold the tool calls" : "List the tool calls")
            if open {
                ForEach(tools) { tool in
                    Label {
                        Text(tool.text).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: tool.symbol ?? "hammer")
                    }
                    .padding(.leading, 12)
                }
            }
        }
        .font(.system(size: textSize - 3))
        .foregroundStyle(palette.muted)
    }
}

/// An agent's answer in markdown: headings, code blocks, and inline styling with its line breaks.
private struct ChatAnswer: View {
    let text: String
    let palette: ChatPalette
    let textSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(AgentChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    Text(Self.inline(s)).font(.system(size: textSize))
                case .heading(let s):
                    Text(Self.inline(s)).font(.system(size: textSize + 1, weight: .semibold))
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s).font(.system(size: textSize - 1, design: .monospaced)).fixedSize()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.code, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .foregroundStyle(palette.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// The chat's message box: Return sends, Shift-Return starts a new line, up to six lines tall.
struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focused: Bool
    let fontSize: CGFloat
    let textColor: NSColor
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 1)
        style(view)
        if focused { claimFocus(view) }
        context.coordinator.wasFocused = focused
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            view.string = text
            context.coordinator.measure(view)
        }
        if view.font?.pointSize != fontSize || view.textColor != textColor {
            style(view)
            context.coordinator.measure(view)
        }
        // Take the keyboard when the pane becomes the focused one, not on every update.
        if focused, !context.coordinator.wasFocused { claimFocus(view) }
        context.coordinator.wasFocused = focused
    }

    private func style(_ view: NSTextView) {
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = textColor
        view.insertionPointColor = textColor
    }

    private func claimFocus(_ view: NSTextView) {
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputField
        var wasFocused = false

        init(_ parent: ChatInputField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            measure(view)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSend()
            }
            return true
        }

        func measure(_ view: NSTextView) {
            guard let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let line = ceil((view.font ?? .systemFont(ofSize: parent.fontSize)).boundingRectForFont.height)
            let used = layout.usedRect(for: container).height + view.textContainerInset.height * 2
            let next = min(max(ceil(used), line), line * 6)
            guard abs(next - parent.height) > 0.5 else { return }
            Task { @MainActor [weak self] in self?.parent.height = next }
        }
    }
}
