import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import QRCodeGenerator
import XTermXHost
import XTermXKit
import XTermXNIO

// `xtermx`: an XTermX node without a window. `serve` shares this machine's terminals with paired
// devices and other nodes; the other commands reach terminals on other nodes (Macs or Linux).

struct XTermXCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xtermx",
        abstract: "XTermX node: share this machine's terminals, or reach terminals on other XTermX machines.",
        version: "1.0.0",
        subcommands: [Serve.self, Pair.self, Rotate.self, Add.self, Machines.self, Remove.self, List.self, New.self, Send.self, Screen.self, Attach.self,
                      Hooks.self, Hook.self]
    )
}

// MARK: - Agent hooks

extension XTermXCLI {
    struct Hooks: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add or remove XTermX's Claude Code and Codex hooks: agent status, tokens, plan limits, and answering permissions from your devices. They do nothing outside XTermX panes.")
        @Argument(help: "install, uninstall or status.") var action: String = "status"

        func run() throws {
            switch action {
            case "install":
                try AgentHookInstaller.writeLauncher(executable: Self.executablePath)
                let changed = try AgentHookInstaller.install()
                print(changed.isEmpty ? "Already installed." : "Updated (each with a .xtermx-backup copy):\n" + changed.map { "  " + tildePath($0) }.joined(separator: "\n"))
                if changed.contains(where: { $0.hasSuffix("hooks.json") }) {
                    print("Codex asks you to trust new hooks once: open codex and run /hooks.")
                }
            case "uninstall":
                let changed = try AgentHookInstaller.uninstall()
                print(changed.isEmpty ? "Nothing to remove." : "Removed from:\n" + changed.map { "  " + tildePath($0) }.joined(separator: "\n"))
            default:
                let targets = AgentHookInstaller.targets()
                if targets.isEmpty { print("No Claude Code or Codex account found.") }
                for t in targets { print("\(t.installed ? "✓" : "·") \(t.tool.name)  \(t.folder)") }
            }
        }

        static var executablePath: String {
            let path = CommandLine.arguments[0]
            if path.contains("/") { return URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
            return Bundle.main.executablePath ?? path
        }
    }

    /// What Claude Code and Codex run; reads the hook JSON on stdin.
    struct Hook: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run by Claude Code and Codex hooks (internal).", shouldDisplay: false)
        @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

        func run() throws {
            throw ExitCode(AgentHookClient.run(arguments))
        }
    }
}

// MARK: - Shared options and storage

struct NodeOptions: ParsableArguments {
    @Option(help: "Name devices see for this machine.") var name: String?
    @Option(help: "WebSocket port.") var port: UInt16 = XTermXProtocol.defaultPort
    @Option(name: .customLong("http-port"), help: "HTTP port for the Apple Watch.") var httpPort: UInt16 = XTermXProtocol.defaultHTTPPort
    @Option(name: .customLong("address"), help: "Address to put in the pairing code (repeat: Tailscale name, public IP or domain…). Default: every address this machine has.")
    var addresses: [String] = []
    @Option(name: .customLong("config"), help: "Folder for the secret and the paired machines.") var config: String?

    var directory: URL { config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? FileSecretStore.defaultDirectory }
    var store: FileSecretStore { FileSecretStore(directory: directory) }
    var displayName: String { name ?? HostIdentity.hostName }
    var pairingAddresses: [String] { addresses.isEmpty ? HostIdentity.addresses() : addresses }
}

/// Machines this node has paired with, as a client: a 0600 JSON file next to the secret.
struct MachineBook {
    let url: URL

    init(directory: URL) { url = directory.appendingPathComponent("machines.json") }

    func load() -> [PairingInfo] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PairingInfo].self, from: data)) ?? []
    }

    func save(_ machines: [PairingInfo]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileManager.default.createFile(atPath: url.path, contents: try encoder.encode(machines), attributes: [.posixPermissions: 0o600])
    }

    /// By exact name, then by case-insensitive prefix.
    func find(_ name: String?) throws -> PairingInfo {
        let all = load()
        guard !all.isEmpty else { throw ValidationError("No machines yet. Pair one with: xtermx add 'xtermx://pair?…'") }
        guard let name else {
            if all.count == 1 { return all[0] }
            throw ValidationError("Several machines; name one: \(all.map(\.hostName).joined(separator: ", "))")
        }
        if let exact = all.first(where: { $0.hostName == name }) { return exact }
        let matches = all.filter { $0.hostName.lowercased().hasPrefix(name.lowercased()) }
        guard matches.count == 1 else { throw ValidationError("No single machine matches “\(name)”. Known: \(all.map(\.hostName).joined(separator: ", "))") }
        return matches[0]
    }
}

struct ClientOptions: ParsableArguments {
    @Option(name: .customLong("config"), help: "Folder for the secret and the paired machines.") var config: String?
    var book: MachineBook {
        MachineBook(directory: config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? FileSecretStore.defaultDirectory)
    }
}

// MARK: - Running on the main thread

/// Runs `body` on the main actor and keeps the run loop going (PTYs, timers and the network
/// all deliver there) until `finish` is called.
func runMain(_ body: @escaping @MainActor (_ finish: @escaping @MainActor (Int32) -> Void) -> Void) -> Never {
    nonisolated(unsafe) var exitCode: Int32?
    MainActor.assumeIsolated {
        body { code in exitCode = code }
    }
    while exitCode == nil {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    exit(exitCode!)
}

@MainActor
func connect(_ pairing: PairingInfo) async -> HostConnection? {
    let connection = HostConnection(pairing: pairing, deviceName: HostIdentity.hostName, platform: .macOS,
                                    transport: NIOFrameTransport.factory)
    connection.connect()
    guard await connection.waitUntilReady() else {
        let reason: String
        if case .failed(let why) = connection.status { reason = why } else { reason = "no answer" }
        printErr("Could not reach \(pairing.hostName): \(reason)")
        connection.disconnect()
        return nil
    }
    return connection
}

func printErr(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

// MARK: - QR code in the terminal

enum TerminalQR {
    /// Two modules per character cell (▀ ▄ █), black on white with a quiet zone, so phone cameras read it.
    static func render(_ text: String) -> String {
        guard let qr = try? QRCode.encode(text: text, ecl: .medium) else { return "" }
        let quiet = 2
        let size = qr.size
        func dark(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < size && y < size && qr.getModule(x: x, y: y)
        }
        var out = ""
        var y = -quiet
        while y < size + quiet {
            out += "\u{1b}[30;107m"
            for x in -quiet..<(size + quiet) {
                switch (dark(x, y), dark(x, y + 1)) {
                case (true, true): out += "█"
                case (true, false): out += "▀"
                case (false, true): out += "▄"
                case (false, false): out += " "
                }
            }
            out += "\u{1b}[0m\n"
            y += 2
        }
        return out
    }

    static func show(_ pairing: PairingInfo) {
        print(render(pairing.url.absoluteString))
        print("Scan with XTermX on iPhone, or on another node:\n  xtermx add '\(pairing.url.absoluteString)'")
        print("Addresses: \(pairing.addresses.joined(separator: ", "))   port \(pairing.port), watch \(pairing.httpPort)")
        print("Keep this code private: it lets a device control this machine's terminals.")
    }
}

// MARK: - Commands: this node

extension XTermXCLI {
    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Share this machine's terminals (run under systemd or Docker).")
        @OptionGroup var node: NodeOptions
        @Flag(help: "Let agents in panes open other panes (each one still needs approval on a device).") var allowAgentPanes = false
        @Flag(help: "Do not let devices open new panes.") var noSpawn = false
        @Flag(help: "Do not print the pairing code at start.") var quiet = false

        func run() throws {
            let node = node, allowAgentPanes = allowAgentPanes, noSpawn = noSpawn, quiet = quiet
            signal(SIGPIPE, SIG_IGN)
            runMain { finish in
                let manager = PaneManager()
                manager.hostName = node.displayName
                let server = RemoteServer(manager: manager, port: node.port, httpPort: node.httpPort, secretStore: node.store)
                server.allowRemoteSpawn = !noSpawn
                server.start()
                guard server.isRunning else {
                    printErr("Could not listen on port \(node.port)/\(node.httpPort): \(server.lastError ?? "unknown error")")
                    return finish(1)
                }
                let tools = MCPServer(manager: manager, agentHistory: FileSecretStore.defaultDirectory.appendingPathComponent("agent-history.json"),
                                      watchMachine: true)
                tools.tools.allowAgentPanes = allowAgentPanes
                tools.tools.connectedPlatforms = { server.devices.map(\.platform) }
                ServeState.shared.keep(manager, server, tools)
                Task {
                    try? await tools.start()
                    print("XTermX node “\(node.displayName)” listening on port \(server.port) (watch \(server.httpPort)); agent tools \(tools.url?.absoluteString ?? "off")")
                    if !quiet { TerminalQR.show(server.pairing(addresses: node.pairingAddresses)) }
                    fflush(nil)
                }
            }
        }
    }

    struct Pair: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the pairing code for this machine.")
        @OptionGroup var node: NodeOptions

        func run() throws {
            let secret = HostIdentity.secret(node.store)
            let addresses = node.pairingAddresses
            let pairing = PairingInfo(hostName: node.displayName, address: addresses.first ?? "", alternates: Array(addresses.dropFirst()),
                                      port: node.port, httpPort: node.httpPort, secret: secret)
            TerminalQR.show(pairing)
        }
    }

    struct Rotate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Make a new secret: every paired device must pair again.")
        @OptionGroup var node: NodeOptions

        func run() throws {
            HostIdentity.rotate(node.store)
            print("New secret made. Restart `xtermx serve`, then pair your devices again with `xtermx pair`.")
        }
    }
}

// MARK: - Commands: other nodes

extension XTermXCLI {
    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pair with another XTermX machine using its link.")
        @Argument(help: "The xtermx://pair?… link (from the Mac's QR, or `xtermx pair` on that machine).") var link: String
        @OptionGroup var client: ClientOptions

        func run() throws {
            guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let pairing = PairingInfo(url: url) else {
                throw ValidationError("That is not an XTermX pairing link.")
            }
            var all = client.book.load().filter { $0.hostName != pairing.hostName }
            all.append(pairing)
            try client.book.save(all)
            print("Paired with “\(pairing.hostName)” (\(pairing.addresses.joined(separator: ", "))). Try: xtermx ls \"\(pairing.hostName)\"")
        }
    }

    struct Machines: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the machines this node is paired with.")
        @OptionGroup var client: ClientOptions

        func run() throws {
            let all = client.book.load()
            if all.isEmpty { print("No machines yet. Pair one with: xtermx add 'xtermx://pair?…'") }
            for m in all { print("\(m.hostName)\t\(m.addresses.joined(separator: ", "))\tport \(m.port)") }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Forget a paired machine.")
        @Argument var machine: String
        @OptionGroup var client: ClientOptions

        func run() throws {
            let target = try client.book.find(machine)
            try client.book.save(client.book.load().filter { $0.hostName != target.hostName })
            print("Forgot “\(target.hostName)”.")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "List the terminals on a machine (or on all of them).")
        @Argument var machine: String?
        @OptionGroup var client: ClientOptions

        func run() throws {
            let targets = try machine.map { [try client.book.find($0)] } ?? client.book.load()
            runMain { finish in
                Task {
                    for pairing in targets {
                        guard let c = await connect(pairing) else { continue }
                        print("\(c.hostName)  (\(c.activeAddress))")
                        if c.panes.isEmpty { print("  no terminals — open one with: xtermx new \"\(c.hostName)\"") }
                        for p in c.panes {
                            let agent = p.agentID.map { " [\($0)]" } ?? ""
                            print("  \(p.id.prefix(8).lowercased())  \(p.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(p.title)\(agent)  \(p.cwd)")
                        }
                        c.disconnect()
                    }
                    finish(0)
                }
            }
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a terminal (or an agent) on a machine.")
        @Argument var machine: String?
        @Option(help: "Agent id, e.g. claude-code or codex.") var agent: String?
        @Option(help: "Folder on that machine.") var cwd: String?
        @Option(help: "First message for the agent.") var prompt: String?
        @Flag(help: "Attach right away.") var attach = false
        @OptionGroup var client: ClientOptions

        func run() throws {
            let pairing = try client.book.find(machine)
            let request = SpawnRequest(kind: agent == nil ? .shell : .agent, agentID: agent, cwd: cwd, initialInput: prompt)
            let attach = attach
            runMain { finish in
                Task {
                    guard let c = await connect(pairing) else { return finish(1) }
                    let before = Set(c.panes.map(\.id))
                    c.spawn(request)
                    let deadline = Date.now.addingTimeInterval(10)
                    while Date.now < deadline, c.panes.allSatisfy({ before.contains($0.id) }) {
                        if let error = c.lastError { printErr(error); return finish(1) }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard let pane = c.panes.first(where: { !before.contains($0.id) }) else {
                        printErr("The machine did not open a terminal.")
                        return finish(1)
                    }
                    print("Opened \(pane.id.prefix(8).lowercased()) on \(c.hostName): \(pane.title)")
                    if attach {
                        AttachSession(connection: c, pane: pane, finish: finish).start()
                    } else {
                        c.disconnect()
                        finish(0)
                    }
                }
            }
        }
    }

    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Type a line into a terminal on a machine.")
        @Argument var machine: String
        @Argument var pane: String
        @Argument var text: String
        @OptionGroup var client: ClientOptions

        func run() throws {
            let pairing = try client.book.find(machine)
            let paneHandle = pane.lowercased(), text = text
            runMain { finish in
                Task {
                    guard let c = await connect(pairing) else { return finish(1) }
                    guard let p = c.panes.first(where: { $0.id.lowercased().hasPrefix(paneHandle) }) else {
                        printErr("No terminal \(paneHandle) on \(c.hostName). See: xtermx ls \"\(c.hostName)\"")
                        return finish(1)
                    }
                    c.sendLine(paneID: p.id, text: text)
                    try? await Task.sleep(for: .milliseconds(300))
                    c.disconnect()
                    finish(0)
                }
            }
        }
    }

    struct Screen: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print what a terminal on a machine shows right now.")
        @Argument var machine: String
        @Argument var pane: String
        @Option(help: "Lines from the bottom.") var lines = 40
        @OptionGroup var client: ClientOptions

        func run() throws {
            let pairing = try client.book.find(machine)
            let paneHandle = pane.lowercased(), lines = lines
            runMain { finish in
                Task {
                    guard let c = await connect(pairing) else { return finish(1) }
                    guard let p = c.panes.first(where: { $0.id.lowercased().hasPrefix(paneHandle) }) else {
                        printErr("No terminal \(paneHandle) on \(c.hostName).")
                        return finish(1)
                    }
                    c.requestScreen(paneID: p.id, lines: lines)
                    for _ in 0..<50 where c.screens[p.id] == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    print((c.screens[p.id] ?? []).joined(separator: "\n"))
                    c.disconnect()
                    finish(0)
                }
            }
        }
    }

    struct Attach: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Use a terminal on another machine right here. Ctrl-] detaches.")
        @Argument var machine: String?
        @Argument(help: "Terminal id from `xtermx ls` (default: the most recent one).") var pane: String?
        @OptionGroup var client: ClientOptions

        func run() throws {
            let pairing = try client.book.find(machine)
            let paneHandle = pane?.lowercased()
            runMain { finish in
                Task {
                    guard let c = await connect(pairing) else { return finish(1) }
                    let candidates = c.panes.filter { $0.state != .exited }
                    let chosen = paneHandle.map { h in c.panes.first { $0.id.lowercased().hasPrefix(h) } }
                        ?? candidates.max(by: { $0.lastActivity < $1.lastActivity })
                    guard let target = chosen else {
                        printErr(paneHandle == nil ? "No terminals on \(c.hostName). Open one: xtermx new \"\(c.hostName)\" --attach"
                                                   : "No terminal \(paneHandle!) on \(c.hostName).")
                        return finish(1)
                    }
                    AttachSession(connection: c, pane: target, finish: finish).start()
                }
            }
        }
    }
}

// MARK: - Interactive attach

/// Puts the local terminal in raw mode and wires it to a remote pane until Ctrl-] or the pane exits.
@MainActor
final class AttachSession {
    let connection: HostConnection
    let pane: PaneInfo
    let finish: @MainActor (Int32) -> Void
    private var original = termios()
    private var stdinSource: DispatchSourceRead?
    private var winchSource: DispatchSourceSignal?
    private var token: UUID?
    private var watch: Task<Void, Never>?
    static var current: AttachSession?

    init(connection: HostConnection, pane: PaneInfo, finish: @escaping @MainActor (Int32) -> Void) {
        self.connection = connection
        self.pane = pane
        self.finish = finish
    }

    func start() {
        AttachSession.current = self
        FileHandle.standardError.write(Data("Attached to \(pane.title) on \(connection.hostName). Ctrl-] detaches.\r\n".utf8))
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)

        let paneID = pane.id
        token = connection.attach(paneID: paneID) { data in
            data.withUnsafeBytes { _ = write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        }
        sendSize()

        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let n = read(STDIN_FILENO, &buffer, buffer.count)
                guard n > 0 else { return self.stop(0) }
                let bytes = Array(buffer[0..<n])
                if bytes.contains(0x1d) { return self.stop(0) } // Ctrl-]
                self.connection.input(paneID: paneID, bytes: Data(bytes))
            }
        }
        source.resume()
        stdinSource = source

        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        winch.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.sendSize() } }
        winch.resume()
        winchSource = winch

        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if !self.connection.panes.contains(where: { $0.id == paneID && $0.state != .exited }) {
                    return self.stop(0, note: "The terminal ended.")
                }
                if case .failed(let why) = self.connection.status { return self.stop(1, note: "Connection lost: \(why)") }
            }
        }
    }

    private func sendSize() {
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 {
            connection.resize(paneID: pane.id, cols: Int(size.ws_col), rows: Int(size.ws_row))
        }
    }

    func stop(_ code: Int32, note: String? = nil) {
        watch?.cancel()
        stdinSource?.cancel()
        winchSource?.cancel()
        if let token { connection.detach(paneID: pane.id, token: token) }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        FileHandle.standardError.write(Data("\r\n\(note ?? "Detached.") The terminal keeps running on \(connection.hostName).\n".utf8))
        connection.disconnect()
        AttachSession.current = nil
        finish(code)
    }
}

/// Holds the serving objects for the life of the process.
@MainActor
final class ServeState {
    static let shared = ServeState()
    private var objects: [AnyObject] = []
    func keep(_ items: AnyObject...) { objects += items }
}

XTermXCLI.main()
