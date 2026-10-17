#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ProcessMemoryRecord: Sendable {
    public var pid: Int32
    public var parent: Int32
    public var residentBytes: UInt64?
    public init(pid: Int32, parent: Int32, residentBytes: UInt64?) { self.pid = pid; self.parent = parent; self.residentBytes = residentBytes }
}
public struct ProcessMemorySummary: Sendable {
    public var appBytes: UInt64?
    public var paneBytes: UInt64
    public var paneProcesses: Int
    public var unreadable: Int
}

public enum ProcessMemory {
    /// Includes descendants once even when two roots overlap; unrelated system processes stay out.
    public static func summarize(_ records: [ProcessMemoryRecord], appPID: Int32, panePIDs: [Int32]) -> ProcessMemorySummary {
        let table = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: records, by: \.parent)
        var queue = panePIDs, selected = Set<Int32>(), index = 0
        while index < queue.count {
            let pid = queue[index]; index += 1
            guard pid > 0, selected.insert(pid).inserted else { continue }
            queue += (children[pid] ?? []).map(\.pid)
        }
        selected.remove(appPID)
        let bytes = selected.compactMap { table[$0]?.residentBytes }
        return ProcessMemorySummary(appBytes: table[appPID]?.residentBytes, paneBytes: bytes.reduce(0, +),
                                    paneProcesses: selected.count, unreadable: selected.count - bytes.count)
    }

    public static func sample(appPID: Int32, panePIDs: [Int32]) -> ProcessMemorySummary {
        var records: [ProcessMemoryRecord] = []
        #if canImport(Darwin)
        var pids = [Int32](repeating: 0, count: max(1, Int(proc_listallpids(nil, 0)) + 128))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(max(0, min(Int(count), pids.count))) where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
            records.append(ProcessMemoryRecord(pid: pid, parent: Int32(bsd.pbi_ppid), residentBytes: read ? task.pti_resident_size : nil))
        }
        #else
        let pids = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        for name in pids {
            guard let pid = Int32(name), let parent = ProcessTree.parent(of: pid) else { continue }
            let statm = try? String(contentsOfFile: "/proc/\(pid)/statm", encoding: .utf8)
            let fields = statm?.split(separator: " ") ?? []
            let pages = fields.count > 1 ? UInt64(fields[1]) : nil
            records.append(ProcessMemoryRecord(pid: pid, parent: parent,
                                               residentBytes: pages.map { $0 * UInt64(sysconf(Int32(_SC_PAGESIZE))) }))
        }
        #endif
        return summarize(records, appPID: appPID, panePIDs: panePIDs)
    }
}
#endif
