#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// A process listening on a TCP port: shown when the remote-access listener cannot bind.
public struct PortHolder: Codable, Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var command: String
    public var user: String?
    public var endpoints: [String]
    /// Started by this app (a pane's shell or something it ran). Only these may be offered to quit.
    public var isOurs: Bool
    public var id: Int32 { pid }

    public init(pid: Int32, command: String, user: String? = nil, endpoints: [String] = [], isOurs: Bool = false) {
        self.pid = pid
        self.command = command
        self.user = user
        self.endpoints = endpoints
        self.isOurs = isOurs
    }
}

/// Who holds a port, from `lsof`. Read-only: nothing here ends a process on its own.
public enum PortHolders {
    /// The listeners on `port`; empty when none or when lsof is missing.
    public static func listeners(on port: UInt16) async -> [PortHolder] {
        await Task.detached(priority: .userInitiated) {
            guard let tool = ["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof"].first(where: FileManager.default.isExecutableFile),
                  let output = run(tool, ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pcLn"]) else { return [] }
            let me = getpid()
            return parseLsof(output).map { holder in
                var h = holder
                h.isOurs = h.pid != me && descends(h.pid, from: me)
                return h
            }
        }.value
    }

    /// lsof `-F pcLn` output: a `p` line starts each process, then `c`ommand, `L`ogin, and one
    /// `f`ile/`n`ame pair per socket.
    public static func parseLsof(_ text: String) -> [PortHolder] {
        var out: [PortHolder] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": if let pid = Int32(value) { out.append(PortHolder(pid: pid, command: "")) }
            case "c": if !out.isEmpty { out[out.count - 1].command = value }
            case "L": if !out.isEmpty { out[out.count - 1].user = value }
            case "n": if !out.isEmpty, !out[out.count - 1].endpoints.contains(value) { out[out.count - 1].endpoints.append(value) }
            default: continue
            }
        }
        return out
    }

    /// Whether the bind error means another process already has the port.
    public static func isAddressInUse(_ error: String) -> Bool {
        error.contains("Address already in use") || error.contains("EADDRINUSE")
            || error.contains("errno: \(EADDRINUSE)")
    }

    /// Walks up the parent chain; a holder we started may have been reparented to launchd, which
    /// makes it not ours — the safe answer.
    static func descends(_ pid: Int32, from ancestor: Int32) -> Bool {
        var current = pid
        for _ in 0..<32 {
            guard let parent = ProcessTree.parent(of: current), parent > 1 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    /// Asks one of our own holders to quit (SIGTERM). Refuses anything not started by this app.
    @discardableResult
    public static func terminate(_ holder: PortHolder) -> Bool {
        guard holder.pid > 1, holder.pid != getpid(), descends(holder.pid, from: getpid()) else { return false }
        #if os(macOS)
        // The list may be minutes old by the time the person confirms: a reused pid is someone else.
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(holder.pid, &name, UInt32(name.count)) > 0,
              holder.command.hasPrefix(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        else { return false }
        #endif
        return kill(holder.pid, SIGTERM) == 0
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
