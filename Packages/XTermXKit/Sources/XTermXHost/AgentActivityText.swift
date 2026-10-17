#if os(macOS) || os(Linux)
import Foundation
import XTermXKit

/// Tool calls in words, for the activity feed: an SF Symbol and a short line.
enum AgentActivityText {
    static func claude(tool: String, input: [String: Any]) -> (symbol: String, text: String) {
        func s(_ key: String) -> String? { (input[key] as? String).flatMap(oneLine) }
        switch tool {
        case "Bash": return ("terminal", s("description") ?? s("command").map { "$ " + $0 } ?? "Running a command")
        case "Read": return ("doc.text", "Reading " + file(s("file_path")))
        case "Edit", "MultiEdit": return ("pencil", "Editing " + file(s("file_path")))
        case "NotebookEdit": return ("pencil", "Editing " + file(s("notebook_path")))
        case "Write": return ("square.and.pencil", "Writing " + file(s("file_path")))
        case "Grep": return ("magnifyingglass", s("pattern").map { "Searching for “\($0)”" } ?? "Searching")
        case "Glob": return ("magnifyingglass", s("pattern").map { "Finding \($0)" } ?? "Finding files")
        case "WebSearch": return ("globe", s("query").map { "Searching the web: \($0)" } ?? "Searching the web")
        case "WebFetch": return ("globe", "Reading " + (s("url").flatMap { URL(string: $0)?.host } ?? "a web page"))
        case "Agent", "Task":
            let kind = s("subagent_type") ?? "agent"
            return ("person.2", s("description").map { "Started \(kind): \($0)" } ?? "Started \(kind)")
        case "SendMessage": return ("bubble.left", s("to").map { "Messaging \($0)" } ?? "Sending a message")
        case "AskUserQuestion": return ("questionmark.bubble", "Asking you a question")
        case "TodoWrite", "TaskCreate", "TaskUpdate": return ("checklist", "Updating tasks")
        case "Skill": return ("sparkles", s("skill").map { "Using \($0)" } ?? "Using a skill")
        case "ToolSearch": return ("wrench.and.screwdriver", "Loading tools")
        case "Monitor": return ("eye", s("description") ?? "Watching a command")
        case "ScheduleWakeup": return ("alarm", "Scheduling a wake-up")
        case "TaskStop", "KillShell", "KillBash": return ("stop.circle", "Stopping a background task")
        case "EnterPlanMode", "ExitPlanMode": return ("list.bullet.clipboard", "Planning")
        default: return mcp(tool) ?? ("wrench", tool)
        }
    }

    static func codex(tool: String, arguments: [String: Any], input: String?) -> (symbol: String, text: String) {
        func s(_ key: String) -> String? { (arguments[key] as? String).flatMap(oneLine) }
        switch tool {
        case _ where codexShellTools.contains(tool):
            return ("terminal", command(arguments).map { "$ " + $0 } ?? "Running a command")
        case "exec", "js": return ("chevron.left.forwardslash.chevron.right", s("title") ?? "Running code")
        case "apply_patch": return ("pencil", patchFiles(input ?? arguments["input"] as? String) ?? "Editing files")
        case "update_plan": return ("checklist", "Updating the plan")
        case "spawn_agent": return ("person.2", s("task_name").map { "Started agent \($0)" } ?? "Started an agent")
        case "send_message", "followup_task": return ("bubble.left", s("target").map { "Messaging \($0)" } ?? "Sending a message")
        case "wait", "wait_agent", "sleep": return ("hourglass", "Waiting")
        case "request_user_input", "request_user_input_async": return ("questionmark.bubble", "Asking you a question")
        case "web_search": return ("globe", s("query").map { "Searching the web: \($0)" } ?? "Searching the web")
        case "view_image": return ("photo", "Looking at an image")
        default: return mcp(tool) ?? ("wrench", s("title") ?? tool)
        }
    }

    static let codexShellTools: Set<String> = ["exec_command", "shell", "shell_command", "local_shell_call", "container.exec"]

    /// A Codex command: `cmd` or `command`, a string or an argv (`bash -lc "…"` unwrapped).
    static func command(_ arguments: [String: Any]) -> String? {
        if let text = (arguments["cmd"] ?? arguments["command"]) as? String { return oneLine(text) }
        guard var argv = (arguments["command"] ?? arguments["cmd"]) as? [String], !argv.isEmpty else { return nil }
        if argv.count >= 3, ["bash", "sh", "zsh"].contains((argv[0] as NSString).lastPathComponent), argv[1].hasPrefix("-") {
            argv = Array(argv[2...])
        }
        return oneLine(argv.joined(separator: " "))
    }

    /// `mcp__server__tool` → "server: tool".
    static func mcp(_ tool: String) -> (symbol: String, text: String)? {
        let parts = tool.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        var server = parts[1]
        for prefix in ["plugin_", "claude_ai_"] where server.hasPrefix(prefix) { server.removeFirst(prefix.count) }
        let name = parts[2...].joined(separator: "__").replacingOccurrences(of: "_", with: " ")
        return ("puzzlepiece", "\(server.replacingOccurrences(of: "_", with: " ")): \(name)")
    }

    /// "Editing Models.swift and 2 more", from a patch's `*** Update File:` lines.
    static func patchFiles(_ patch: String?) -> String? {
        guard let patch else { return nil }
        let files = patch.split(separator: "\n").compactMap { line -> String? in
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                return (String(line.dropFirst(marker.count)) as NSString).lastPathComponent
            }
            return nil
        }
        guard let first = files.first else { return nil }
        return files.count == 1 ? "Editing \(first)" : "Editing \(first) and \(files.count - 1) more"
    }

    static func file(_ path: String?) -> String {
        path.map { ($0 as NSString).lastPathComponent } ?? "a file"
    }

    /// First non-empty line, trimmed and cut to 100 characters.
    static func oneLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 100 ? String(line.prefix(99)) + "…" : line
    }
}
#endif
