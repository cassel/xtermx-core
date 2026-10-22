#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

/// Answers the hooks Claude Code and Codex run inside panes (`xtermx hook`, POST /hook):
/// a session starting tells which transcript belongs to which pane, a permission request
/// becomes a card on every device, and Claude Code's status line brings its plan limits.
@MainActor
public final class AgentHooks {
    private let manager: PaneManager
    public let sessions: AgentSessionTracker

    /// How long a card waits. Claude Code shows its own dialog at the same time, so it can wait long;
    /// Codex shows its dialog only after the hook returns, so it must not wait too long.
    static let claudeTimeout: TimeInterval = 3600
    static let codexTimeout: TimeInterval = 90

    /// Claude Code's cards still waiting, so an answer given in its own dialog can take them down: it keeps
    /// the hook running after that answer instead of ending it.
    private var waiting: [String: (paneID: String, tool: String, input: JSONValue)] = [:]

    public init(manager: PaneManager, sessions: AgentSessionTracker) {
        self.manager = manager
        self.sessions = sessions
    }

    /// The JSON the hook prints, or nil to print nothing (no decision: the agent asks in the terminal).
    public func handle(event: String?, payload: JSONValue, caller paneID: String) async -> JSONValue? {
        let gemini = event == "gemini"
        let event = (gemini ? nil : event.flatMap { $0.isEmpty ? nil : $0 }) ?? payload["hook_event_name"]?.string ?? ""
        let transcript = payload["transcript_path"]?.string
        let tool: AgentTool? = gemini ? .gemini : Self.tool(transcriptPath: transcript, payload: payload)

        switch event {
        case "SessionStart":
            guard let tool, let id = payload["session_id"]?.string, let transcript else { return nil }
            sessions.register(.init(paneID: paneID, tool: tool, sessionID: id, transcriptPath: transcript,
                                    model: payload["model"]?.string))
            return nil
        case "SessionEnd":
            if sessions.session(paneID: paneID)?.sessionID == payload["session_id"]?.string { sessions.unregister(paneID: paneID) }
            return nil
        case "SubagentStart", "SubagentStop":
            let id = payload["agent_id"]?.string ?? payload["subagent_id"]?.string ?? UUID().uuidString
            let name = payload["agent_type"]?.string ?? payload["agent_nickname"]?.string ?? "agent"
            sessions.subagent(paneID: paneID, id: id, name: name, running: event == "SubagentStart")
            return nil
        case "statusline":
            sessions.claudeLimits(transcriptPath: transcript, windows: Self.claudeWindows(payload["rate_limits"]))
            return nil
        case "BeforeAgent", "AfterTool":
            if tool == .gemini { sessions.geminiActivity(paneID: paneID, status: .working) }
            return nil
        case "AfterAgent":
            if tool == .gemini { sessions.geminiActivity(paneID: paneID, status: .idle) }
            return nil
        case "Notification":
            if tool == .gemini, payload["notification_type"]?.string == "ToolPermission" { sessions.geminiActivity(paneID: paneID, status: .waiting) }
            return nil
        case "PostToolUse":
            // Allowed in the terminal: the tool ran, so its card is answered.
            let name = payload["tool_name"]?.string, input = payload["tool_input"]
            withdrawWaiting { $0.paneID == paneID && $0.tool == name && $0.input == input }
            return nil
        case "UserPromptSubmit", "Stop":
            // Denied in the terminal: the turn ended or the person typed instead.
            withdrawWaiting { $0.paneID == paneID }
            return nil
        case "PermissionRequest":
            guard tool != .gemini else { return nil }
            return await permission(payload, tool: tool ?? .claude, paneID: paneID)
        default:
            return nil
        }
    }

    // MARK: Permissions and questions

    private func permission(_ payload: JSONValue, tool: AgentTool, paneID: String) async -> JSONValue? {
        let toolName = payload["tool_name"]?.string ?? "a tool"
        let input = payload["tool_input"] ?? [:]
        let suggestions = payload["permission_suggestions"]?.array ?? []
        let paneTitle = manager.pane(paneID)?.title ?? "An agent"
        let timeout = tool == .claude ? Self.claudeTimeout : Self.codexTimeout

        let request: ApprovalRequest
        if tool == .claude, toolName == "AskUserQuestion", let questions = Self.questions(input), !questions.isEmpty {
            request = ApprovalRequest(paneID: paneID, title: "\(tool.name) asks", detail: paneTitle, timeout: timeout,
                                      kind: .question, agentTool: tool, options: [], questions: questions, allowsMessage: true)
        } else {
            let (detail, complete) = Self.describe(toolName, input)
            // Never allow from a device what the card cannot show in full: that answer stays in the terminal.
            var options = [ApprovalOption(id: "deny", label: "Deny", role: .deny)]
            if complete {
                options.append(ApprovalOption(id: "allow", label: "Allow once", role: .allow))
                if tool == .claude, !suggestions.isEmpty {
                    options.append(ApprovalOption(id: "always", label: "Always allow", role: .always))
                }
            }
            request = ApprovalRequest(paneID: paneID, title: "\(paneTitle): \(Self.toolLabel(toolName))",
                                      detail: detail, timeout: timeout,
                                      kind: .permission, agentTool: tool, options: options, allowsMessage: true)
        }

        sessions.permissionPending(paneID: paneID, requestID: request.id)
        if tool == .claude { waiting[request.id] = (paneID, toolName, input) }
        defer { waiting[request.id] = nil }
        let manager = self.manager
        // The agent may give up on the hook (the person answered in its own dialog): take the card down.
        let answer = await withTaskCancellationHandler {
            await manager.requestDecision(request)
        } onCancel: {
            Task { @MainActor in manager.withdraw(request.id) }
        }
        sessions.permissionSettled(paneID: paneID, requestID: request.id)
        guard let answer else { return nil }
        return Self.decision(answer, request: request, tool: tool, input: input, suggestions: suggestions)
    }

    private func withdrawWaiting(_ matches: ((paneID: String, tool: String, input: JSONValue)) -> Bool) {
        for (id, card) in waiting where matches(card) { manager.withdraw(id) }
    }

    /// The hook output for an answer, in the shape each agent expects.
    static func decision(_ answer: ApprovalAnswer, request: ApprovalRequest, tool: AgentTool, input: JSONValue,
                         suggestions: [JSONValue]) -> JSONValue {
        var decision: [String: JSONValue]
        if request.kind == .question {
            var answers = answer.answers
            if let text = answer.message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                for q in request.questions where answers[q.question] == nil { answers[q.question] = text }
            }
            guard !answers.isEmpty else {
                return wrap(["behavior": "deny", "message": "The person dismissed the question from XTermX."])
            }
            var updated = input.object ?? [:]
            updated["answers"] = .object(answers.mapValues { .string($0) })
            decision = ["behavior": "allow", "updatedInput": .object(updated)]
        } else {
            switch request.options.first(where: { $0.id == answer.optionID })?.role {
            case .always?:
                decision = ["behavior": "allow"]
                if tool == .claude { decision["updatedPermissions"] = .array(suggestions) }
            case .allow?:
                decision = ["behavior": "allow"]
            case .deny?, nil:
                let reason = answer.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                decision = ["behavior": "deny",
                            "message": .string(reason.flatMap { $0.isEmpty ? nil : $0 } ?? "The person denied this from XTermX.")]
            }
        }
        return wrap(.object(decision))
    }

    private static func wrap(_ decision: JSONValue) -> JSONValue {
        ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    }

    static func questions(_ input: JSONValue) -> [ApprovalQuestion]? {
        input["questions"]?.array?.compactMap { q in
            guard let text = q["question"]?.string else { return nil }
            let options = q["options"]?.array?.compactMap { $0["label"]?.string ?? $0.string } ?? []
            return ApprovalQuestion(question: text, header: q["header"]?.string, options: options,
                                    multiSelect: q["multiSelect"]?.bool ?? false)
        }
    }

    static func toolLabel(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            return parts.count >= 3 ? "\(parts[1]) · \(parts.dropFirst(2).joined(separator: "_"))" : name
        }
        return name
    }

    static let detailLimit = 600

    /// The part of a tool call the person needs to judge it: the command, the file, the URL —
    /// and whether it fits on the card whole. Long runs of blank space are shown, not hidden.
    static func describe(_ tool: String, _ input: JSONValue) -> (text: String, complete: Bool) {
        let command: String? = input["command"]?.string
            ?? input["command"]?.array?.compactMap(\.string).joined(separator: " ")
            ?? input["cmd"]?.string
        var text = command
            ?? input["file_path"]?.string.map(tildePath)
            ?? input["path"]?.string.map(tildePath)
            ?? input["url"]?.string
            ?? input["pattern"]?.string
            ?? input["prompt"]?.string
            ?? input.prettyText.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: #"[ \t]{8,}"#, with: " ⟨…blank…⟩ ", options: .regularExpression)
        guard text.count > detailLimit else { return (text, true) }
        return (String(text.prefix(detailLimit)) + "\n… \(text.count - detailLimit) more characters: answer in the terminal to allow.", false)
    }

    // MARK: Telling the agents apart

    static func tool(transcriptPath: String?, payload: JSONValue) -> AgentTool? {
        if transcriptPath?.contains("/.gemini/") == true { return .gemini }
        if payload["turn_id"] != nil { return .codex }
        if let path = transcriptPath {
            if (path as NSString).lastPathComponent.hasPrefix("rollout-") { return .codex }
            if path.contains("/projects/") { return .claude }
        }
        if payload["permission_mode"] != nil { return .claude }
        return nil
    }

    /// `rate_limits.five_hour.used_percentage` / `.resets_at` (epoch seconds), and `seven_day`.
    nonisolated static func claudeWindows(_ limits: JSONValue?) -> [UsageWindow] {
        guard let limits else { return [] }
        return [("five_hour", UsageWindow.Kind.fiveHour), ("seven_day", .weekly)].compactMap { key, kind in
            guard let w = limits[key], let used = w["used_percentage"]?.double else { return nil }
            return UsageWindow(kind: kind, usedPercent: used, resetsAt: w["resets_at"]?.double.map { Date(timeIntervalSince1970: $0) })
        }
    }
}
#endif
