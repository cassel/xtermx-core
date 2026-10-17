#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XTermXKit

/// `xtermx hook [statusline <own status line file>]`: what Claude Code and Codex run for XTermX's hooks
/// when `curl` is missing (the launcher script does the same with curl). It forwards the hook's JSON to
/// the XTermX that owns the pane and prints the answer. Outside an XTermX pane (no `XTERMX_SESSION`)
/// it does nothing, so the global hooks stay inert there.
public enum AgentHookClient {
    public static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if arguments.first == "statusline" { return statusline(input, ownFile: arguments.dropFirst().first, environment) }
        guard let request = request(event: nil, body: input, environment) else { return 0 }
        let event = (try? JSONDecoder().decode(JSONValue.self, from: input))?["hook_event_name"]?.string ?? ""
        // A permission waits for the person; everything else is a quick notice.
        let wait: TimeInterval = event == "PermissionRequest" ? 86_400 : 5
        if let reply = send(request, timeout: wait), !reply.isEmpty { try? FileHandle.standardOutput.write(contentsOf: reply) }
        return 0
    }

    static func request(event: String?, body: Data, _ env: [String: String]) -> URLRequest? {
        guard let token = env["XTERMX_SESSION"], !token.isEmpty,
              let mcp = env["XTERMX_MCP_URL"].flatMap(URL.init(string:)) else { return nil }
        var request = URLRequest(url: mcp.deletingLastPathComponent().appendingPathComponent("hook"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let event { request.setValue(event, forHTTPHeaderField: "X-XTermX-Hook") }
        return request
    }

    private final class Box: @unchecked Sendable { var data: Data? }

    /// The 200 response body, or nil (XTermX closed, timed out, refused).
    static func send(_ request: URLRequest, timeout: TimeInterval) -> Data? {
        var request = request
        request.timeoutInterval = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { box.data = data }
            done.signal()
        }.resume()
        done.wait()
        session.finishTasksAndInvalidate()
        return box.data
    }

    /// Runs the person's own status line unchanged, leaves the plan limits for XTermX (from any session),
    /// and inside a pane hands them over at once.
    static func statusline(_ input: Data, ownFile: String?, _ env: [String: String]) -> Int32 {
        if input.range(of: Data("\"rate_limits\"".utf8)) != nil {
            let file = AgentHookInstaller.limitsFile(configDir: env["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? input.write(to: file, options: .atomic)
        }
        let group = DispatchGroup()
        if let request = request(event: "statusline", body: input, env) {
            group.enter()
            DispatchQueue.global().async {
                _ = send(request, timeout: 1)
                group.leave()
            }
        }
        var status: Int32 = 0
        if let ownFile, FileManager.default.fileExists(atPath: ownFile) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [ownFile]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            if (try? process.run()) != nil {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
                process.waitUntilExit()
                status = process.terminationStatus
            }
        }
        _ = group.wait(timeout: .now() + 1)
        return status
    }
}

// MARK: - Installing the hooks

/// Adds XTermX's hooks to every Claude Code and Codex account on this machine, next to whatever
/// hooks are already there, and removes them again. Each file is backed up before it changes,
/// and a file that is not plain JSON is left alone.
public enum AgentHookInstaller {
    public struct Failure: LocalizedError {
        public var errorDescription: String?
    }

    /// Where the accounts live; tests point it at a scratch folder.
    nonisolated(unsafe) static var home = NSHomeDirectory()
    public static var directory: URL { URL(fileURLWithPath: home).appendingPathComponent(".xtermx") }
    /// The hook script the agents call; it never moves, so their configs stay valid across app updates.
    public static var launcher: URL { directory.appendingPathComponent("bin/xtermx-hook") }
    static var statusLineStore: URL { directory.appendingPathComponent("statusline.json") }
    /// `claude-<account folder>.json`: the last status line input of each Claude Code account, which carries
    /// its plan limits; written by every session, in a pane or not.
    public static var limitsDirectory: URL { directory.appendingPathComponent("limits") }

    /// The file name the hook script gives an account folder: every byte that isn't a letter or digit becomes "_".
    static func limitsFile(configDir: String) -> URL {
        let name = String(decoding: configDir.utf8.map { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) ? b : UInt8(ascii: "_")
        }, as: UTF8.self)
        return limitsDirectory.appendingPathComponent("claude-\(name).json")
    }

    static let geminiEvents: [(String, Int?)] = ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "AfterTool", "Notification"].map { ($0, 3000) }
    static let claudeEvents: [(String, Int?)] = [("SessionStart", nil), ("SessionEnd", nil), ("PermissionRequest", 86_400)]
    static let codexEvents: [(String, Int?)] = [("SessionStart", 10), ("SessionEnd", 3), ("PermissionRequest", 120),
                                                ("SubagentStart", 10), ("SubagentStop", 10)]

    public struct Target: Sendable, Hashable, Identifiable {
        public var id: String { file }
        public var tool: AgentTool
        /// The account folder, `~`-abbreviated.
        public var folder: String
        public var file: String
        public var installed: Bool
    }

    /// The hook script: plain `sh` + `curl`, so a status line refresh or a hook costs milliseconds, not an
    /// app launch. The pane token travels on curl's stdin, never in its arguments (which `ps` shows).
    /// Without curl it hands over to `executable hook` (the Mac app binary or the `xtermx` CLI).
    /// Rewritten only when it changed.
    public static func writeLauncher(executable: String) throws {
        let script = """
        #!/bin/sh
        # XTermX hooks for Claude Code and Codex. Outside XTermX panes they do nothing
        # (for the status line: only your own status line runs).
        command -v curl >/dev/null 2>&1 || exec \(shellQuote(executable)) hook "$@"
        body=$(mktemp "${TMPDIR:-/tmp}/xtermx-hook.XXXXXX") || exit 0
        trap 'rm -f "$body"' EXIT
        cat >"$body"
        post() {
          [ -n "$XTERMX_SESSION" ] && [ -n "$XTERMX_MCP_URL" ] || return 0
          printf 'header = "Authorization: Bearer %s"\\nheader = "X-XTermX-Hook: %s"\\n' "$XTERMX_SESSION" "$2" |
            curl -sf -m "$1" -K - -X POST -H "Content-Type: application/json" --data-binary @"$body" \\
              "${XTERMX_MCP_URL%/mcp}/hook" 2>/dev/null
        }
        if [ "$1" = statusline ]; then
          # Every session, in a pane or not, leaves its account's plan limits for XTermX to read.
          if grep -q '"rate_limits"' "$body"; then
            limits=\(shellQuote(limitsDirectory.path))
            name=$(printf %s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" | tr -c 'A-Za-z0-9' '_')
            mkdir -p "$limits" && cp "$body" "$limits/.claude-$name.tmp" && mv -f "$limits/.claude-$name.tmp" "$limits/claude-$name.json"
          fi
          post 1 statusline >/dev/null &
          status=0
          if [ -n "$2" ] && [ -f "$2" ]; then sh "$2" <"$body"; status=$?; fi
          wait
          exit $status
        fi
        if grep -q '"hook_event_name"[[:space:]]*:[[:space:]]*"PermissionRequest"' "$body"; then
          post 86400 ""
        else
          post 5 ""
        fi
        exit 0

        """
        if (try? String(contentsOf: launcher, encoding: .utf8)) == script { return }
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
    }

    static var command: String { shellQuote(launcher.path) }

    public static func claudeFolders(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        folders(prefix: ".claude", needs: ["projects", "sessions"], extra: env["CLAUDE_CONFIG_DIR"]?.split(separator: ",").map(String.init) ?? [])
    }

    public static func codexFolders(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        folders(prefix: ".codex", needs: ["sessions"], extra: env["CODEX_HOME"].map { [$0] } ?? [])
    }

    public static func geminiFolders(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        folders(prefix: ".gemini", needs: ["settings.json", "tmp"], extra: env["GEMINI_CLI_HOME"].map { [$0 + "/.gemini"] } ?? [])
    }

    /// Account folders, each once even when reached through a symlink.
    private static func folders(prefix: String, needs: [String], extra: [String]) -> [String] {
        let fm = FileManager.default
        var found = (try? fm.contentsOfDirectory(atPath: home))?.filter { $0.hasPrefix(prefix) }.map { home + "/" + $0 } ?? []
        found += extra.map { ($0 as NSString).expandingTildeInPath }
        var seen = Set<String>()
        var isDir: ObjCBool = false
        return found.sorted().filter { path in
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard fm.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue,
                  needs.contains(where: { fm.fileExists(atPath: real + "/" + $0) }), !seen.contains(real) else { return false }
            seen.insert(real)
            return true
        }
    }

    public static func targets() -> [Target] {
        claudeFolders().map { f in
            let file = f + "/settings.json"
            return Target(tool: .claude, folder: tildePath(f), file: file, installed: hasOurHooks(file))
        } + codexFolders().map { f in
            let file = f + "/hooks.json"
            return Target(tool: .codex, folder: tildePath(f), file: file, installed: hasOurHooks(file))
        } + geminiFolders().map { f in
            let file = f + "/settings.json"
            return Target(tool: .gemini, folder: tildePath(f), file: file, installed: hasOurHooks(file))
        }
    }

    public static var isInstalled: Bool {
        let t = targets()
        return !t.isEmpty && t.allSatisfy(\.installed)
    }

    /// Adds the hooks to every account; returns the files it changed.
    @discardableResult
    public static func install(manageStatusLine: Bool = true) throws -> [String] {
        var changed: [String] = []
        var store = try readStore()
        for folder in claudeFolders() {
            let file = folder + "/settings.json"
            var json = try read(file)
            var hooks = json["hooks"] as? [String: Any] ?? [:]
            let hooksChanged = add(claudeEvents, to: &hooks, matcherFor: ["PermissionRequest"])
            json["hooks"] = hooks
            let statusChanged = try changeStatusLine(&json, folder: folder, enabled: manageStatusLine, store: &store)
            if hooksChanged || statusChanged {
                try write(json, to: file)
                if statusChanged { try finishStatusLineChange(folder: folder, enabled: manageStatusLine, store: &store) }
                changed.append(file)
            }
        }
        for folder in codexFolders() {
            let file = folder + "/hooks.json"
            var json = try read(file)
            var hooks = json["hooks"] as? [String: Any] ?? [:]
            if add(codexEvents, to: &hooks, matcherFor: []) {
                json["hooks"] = hooks
                try write(json, to: file)
                changed.append(file)
            }
        }
        for folder in geminiFolders() {
            let file = folder + "/settings.json"
            var json = try read(file)
            var hooks = json["hooks"] as? [String: Any] ?? [:]
            if add(geminiEvents, to: &hooks, matcherFor: [], commandOverride: command + " gemini") {
                json["hooks"] = hooks
                try write(json, to: file); changed.append(file)
            }
        }
        return Array(Set(changed)).sorted()
    }

    /// Changes only Claude's status line, leaving lifecycle/permission hooks intact.
    public static var isStatusLineManaged: Bool {
        claudeFolders().contains { folder in
            let line = (try? read(folder + "/settings.json"))?["statusLine"] as? [String: Any]
            return isOurs(command: line?["command"] as? String)
        }
    }

    @discardableResult
    public static func setStatusLineManaged(_ enabled: Bool) throws -> [String] {
        var changed: [String] = []
        var store = try readStore()
        for folder in claudeFolders() {
            let file = folder + "/settings.json"
            var json = try read(file)
            guard try changeStatusLine(&json, folder: folder, enabled: enabled, store: &store) else { continue }
            try write(json, to: file)
            try finishStatusLineChange(folder: folder, enabled: enabled, store: &store)
            changed.append(file)
        }
        return changed
    }

    private static func changeStatusLine(_ json: inout [String: Any], folder: String, enabled: Bool,
                                         store: inout [String: Any]) throws -> Bool {
        let current = json["statusLine"] as? [String: Any]
        let ours = isOurs(command: current?["command"] as? String)
        let own = ownStatusLineFile(folder: folder)
        if enabled {
            guard !ours else { return false }
            store[folder] = current ?? [:]
            try writeStore(store)
            try writeOwnStatusLine(own, command: current?["command"] as? String)
            var line = current ?? ["type": "command"]
            line["command"] = command + " statusline " + shellQuote(own.path)
            json["statusLine"] = line
        } else {
            guard ours else { return false }
            var original = store[folder] as? [String: Any] ?? [:]
            if original.isEmpty, let text = try? String(contentsOf: own, encoding: .utf8) {
                let cmd = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cmd.isEmpty { original = (current ?? [:]).merging(["command": cmd]) { $1 } }
            }
            json["statusLine"] = original.isEmpty ? nil : original
        }
        return true
    }
    private static func finishStatusLineChange(folder: String, enabled: Bool, store: inout [String: Any]) throws {
        if !enabled {
            try? FileManager.default.removeItem(at: ownStatusLineFile(folder: folder))
            store[folder] = nil
            try writeStore(store)
        }
    }

    /// Takes XTermX's hooks out again and gives back the person's status line.
    @discardableResult
    public static func uninstall() throws -> [String] {
        var changed: [String] = []
        var store = try readStore()
        for (folder, name) in claudeFolders().map({ ($0, "settings.json") }) + codexFolders().map({ ($0, "hooks.json") }) + geminiFolders().map({ ($0, "settings.json") }) {
            let file = folder + "/" + name
            var json = try read(file)
            var touched = false
            if var hooks = json["hooks"] as? [String: Any] {
                for (event, value) in hooks {
                    guard let groups = value as? [[String: Any]] else { continue }
                    let kept = groups.filter { !isOurs($0) }
                    if kept.count != groups.count {
                        touched = true
                        hooks[event] = kept.isEmpty ? nil : kept
                    }
                }
                json["hooks"] = hooks
            }
            if let line = json["statusLine"] as? [String: Any], isOurs(command: line["command"] as? String) {
                let own = ownStatusLineFile(folder: folder)
                // The saved original, else rebuilt from the command file kept beside it.
                var original = store[folder] as? [String: Any] ?? [:]
                if original.isEmpty, let text = try? String(contentsOf: own, encoding: .utf8) {
                    let cmd = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cmd.isEmpty { original = line.merging(["command": cmd]) { $1 } }
                }
                json["statusLine"] = original.isEmpty ? nil : original
                try? FileManager.default.removeItem(at: own)
                store[folder] = nil
                touched = true
            }
            if touched { try write(json, to: file); changed.append(file) }
        }
        try writeStore(store)
        return changed
    }

    /// `~/.xtermx/statusline/<folder, percent-encoded>.sh`: the person's own status line command,
    /// run by the launcher with the same stdin.
    static func ownStatusLineFile(folder: String) -> URL {
        let name = folder.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? folder.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("statusline/" + name + ".sh")
    }

    private static func writeOwnStatusLine(_ file: URL, command: String?) throws {
        guard let command, !command.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (command + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: JSON files

    private static func add(_ events: [(String, Int?)], to hooks: inout [String: Any], matcherFor: [String], commandOverride: String? = nil) -> Bool {
        var touched = false
        for (event, timeout) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard !groups.contains(where: isOurs) else { continue }
            var handler: [String: Any] = ["type": "command", "command": commandOverride ?? command]
            if let timeout { handler["timeout"] = timeout }
            var group: [String: Any] = ["hooks": [handler]]
            if matcherFor.contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
            touched = true
        }
        return touched
    }

    private static func isOurs(command: String?) -> Bool {
        guard let command else { return false }
        return command == Self.command || command.hasPrefix(Self.command + " ")
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { isOurs(command: $0["command"] as? String) } == true
    }

    private static func hasOurHooks(_ file: String) -> Bool {
        guard let hooks = (try? read(file))?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: isOurs) == true }
    }

    /// The file's JSON object; empty when the file does not exist. Throws rather than guess when the
    /// file is there but not a JSON object, so nothing of the person's is overwritten.
    private static func read(_ file: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: file),
              !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure(errorDescription: "\(tildePath(file)) is not plain JSON; XTermX left it unchanged.")
        }
        return object
    }

    /// Writes through symlinks (dotfiles setups), after a backup copy that must succeed.
    private static func write(_ json: [String: Any], to file: String) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: file).resolvingSymlinksInPath()
        if fm.fileExists(atPath: target.path) {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
            stamp.locale = Locale(identifier: "en_US_POSIX")
            var backup = target.path + ".xtermx-backup-" + stamp.string(from: .now)
            if fm.fileExists(atPath: backup) { backup += "-" + UUID().uuidString.prefix(6) }
            try fm.copyItem(atPath: target.path, toPath: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target, options: .atomic)
    }

    private static func readStore() throws -> [String: Any] { try read(statusLineStore.path) }

    private static func writeStore(_ store: [String: Any]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: statusLineStore, options: .atomic)
    }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
