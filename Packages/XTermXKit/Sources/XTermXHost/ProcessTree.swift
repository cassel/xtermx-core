#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Parent processes, to tell which pane an agent process runs in.
enum ProcessTree {
    static func parent(of pid: Int32) -> Int32? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
        #else
        // /proc/<pid>/stat: "pid (comm) state ppid …"; comm may hold spaces and parentheses.
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 1 ? Int32(fields[1]) : nil
        #endif
    }

    /// The folder a process is in now (a shell after `cd`).
    static func currentDirectory(of pid: Int32) -> String? {
        #if canImport(Darwin)
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd")
        #endif
    }
}
#endif
