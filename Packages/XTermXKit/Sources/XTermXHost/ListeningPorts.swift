#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Observation
import XTermXKit

/// Finds TCP ports that programs started from a pane's shell listen on (dev servers).
///
/// On macOS it reads the process table and each descendant's sockets through libproc; elsewhere,
/// or if libproc yields nothing, it falls back to parsing `lsof -F`.
public enum ListeningPorts {
    public struct Listener: Hashable, Sendable {
        public var pid: Int32
        public var port: UInt16
        public var command: String?
        public init(pid: Int32, port: UInt16, command: String? = nil) { self.pid = pid; self.port = port; self.command = command }
    }

    // MARK: Pure parts

    /// Every process below `root` (not `root` itself), given each process's parent.
    public static func descendants(of root: Int32, parents: [Int32: Int32]) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for (child, parent) in parents where child != parent { children[parent, default: []].append(child) }
        var found: Set<Int32> = []
        var queue = children[root] ?? []
        while let pid = queue.popLast() {
            guard found.insert(pid).inserted else { continue }
            queue += children[pid] ?? []
        }
        return found
    }

    /// Parses `lsof -nP -iTCP -sTCP:LISTEN -F pcn`: `p<pid>`, `c<command>`, then one `n<address>:<port>` per socket.
    public static func parseLsof(_ output: String) -> [Listener] {
        var result: [Listener] = []
        var seen: Set<Listener> = []
        var pid: Int32?
        var command: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); command = nil
            case "c": command = value
            case "n":
                // A listening socket has no peer ("->"); the port follows the last colon ("*:3000", "[::1]:5173").
                guard let pid, !value.contains("->"), let colon = value.lastIndex(of: ":"),
                      let port = UInt16(value[value.index(after: colon)...]), port > 0 else { continue }
                let listener = Listener(pid: pid, port: port, command: command)
                if seen.insert(listener).inserted { result.append(listener) }
            default: continue
            }
        }
        return result
    }

    /// Assigns listeners to the pane whose shell they descend from, one entry per pane and port, sorted by port.
    public static func assign(_ listeners: [Listener], shells: [String: Int32], parents: [Int32: Int32]) -> [DevServerPort] {
        var result: [DevServerPort] = []
        for (paneID, shell) in shells.sorted(by: { $0.key < $1.key }) {
            let tree = descendants(of: shell, parents: parents).union([shell])
            var ports: [UInt16: String?] = [:]
            for listener in listeners where tree.contains(listener.pid) {
                if ports[listener.port] == nil || ports[listener.port]! == nil { ports[listener.port] = listener.command }
            }
            result += ports.keys.sorted().map { DevServerPort(port: $0, paneID: paneID, process: ports[$0] ?? nil) }
        }
        return result
    }

    // MARK: System

    /// Listening ports of the descendants of each pane's shell.
    public static func scan(shells: [String: Int32]) -> [DevServerPort] {
        guard !shells.isEmpty else { return [] }
        let parents = processParents()
        var wanted: Set<Int32> = []
        for shell in shells.values { wanted.formUnion(descendants(of: shell, parents: parents)); wanted.insert(shell) }
        let listeners: [Listener]
        #if canImport(Darwin)
        // libproc sees the sockets of this user's processes; lsof only when the process table itself could not be read.
        listeners = parents.isEmpty ? lsofListeners().filter { wanted.contains($0.pid) } : wanted.flatMap(socketListeners(of:))
        #else
        listeners = lsofListeners().filter { wanted.contains($0.pid) }
        #endif
        return assign(listeners, shells: shells, parents: parents)
    }

    static func processParents() -> [Int32: Int32] {
        var parents: [Int32: Int32] = [:]
        #if canImport(Darwin)
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size { parents[pid] = Int32(info.pbi_ppid) }
        }
        #else
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        for entry in entries {
            guard let pid = Int32(entry), let parent = ProcessTree.parent(of: pid) else { continue }
            parents[pid] = parent
        }
        #endif
        return parents
    }

    #if canImport(Darwin)
    static func socketListeners(of pid: Int32) -> [Listener] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var result: [Listener] = []
        var name: String?
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let raw = UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            let port = UInt16(bigEndian: raw)
            guard port > 0 else { continue }
            if name == nil { name = processName(pid) }
            let listener = Listener(pid: pid, port: port, command: name)
            if !result.contains(listener) { result.append(listener) }
        }
        return result
    }

    static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
    #endif

    static func lsofListeners() -> [Listener] {
        let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseLsof(String(decoding: data, as: UTF8.self))
    }
}

/// Keeps the listening ports of every local pane current, checking every few seconds.
@MainActor
@Observable
public final class DevServerMonitor {
    public private(set) var ports: [DevServerPort] = []
    @ObservationIgnored public var onChange: (([DevServerPort]) -> Void)?
    @ObservationIgnored private weak var manager: PaneManager?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let interval: Duration

    public init(manager: PaneManager, interval: Duration = .seconds(3)) {
        self.manager = manager
        self.interval = interval
    }

    public func ports(for paneID: String) -> [DevServerPort] { ports.filter { $0.paneID == paneID } }

    /// Whether `port` is listening in some pane right now.
    public func isListening(_ port: UInt16) -> Bool { ports.contains { $0.port == port } }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func refresh() async {
        guard let manager else { return }
        var shells: [String: Int32] = [:]
        for pane in manager.panes where pane.state != .exited {
            if let pid = manager.session(pane.id)?.shellPID, pid > 0 { shells[pane.id] = pid }
        }
        let found = await Task.detached(priority: .utility) { ListeningPorts.scan(shells: shells) }.value
        guard found != ports else { return }
        ports = found
        onChange?(found)
    }
}
#endif
