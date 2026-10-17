#if os(macOS)
import Foundation
import Testing
@testable import XTermXHost

@Suite struct ProcessMemoryTests {
    @Test func sumsOnlyPaneTreesWithoutCountingAnOverlappingRootTwice() {
        let records = [ProcessMemoryRecord(pid: 1, parent: 0, residentBytes: 900),
                       .init(pid: 10, parent: 1, residentBytes: 100),
                       .init(pid: 11, parent: 10, residentBytes: 20),
                       .init(pid: 12, parent: 11, residentBytes: 30),
                       .init(pid: 13, parent: 12, residentBytes: nil),
                       .init(pid: 20, parent: 1, residentBytes: 500),
                       .init(pid: 30, parent: 1, residentBytes: 40)]
        let result = ProcessMemory.summarize(records, appPID: 10, panePIDs: [11, 12, 30, 30])
        #expect(result.appBytes == 100)
        #expect(result.paneBytes == 90)
        #expect(result.paneProcesses == 4)
        #expect(result.unreadable == 1)
        let empty = ProcessMemory.summarize(records, appPID: 10, panePIDs: [])
        #expect(empty.appBytes == 100 && empty.paneBytes == 0)
        let missing = ProcessMemory.summarize(records, appPID: 99, panePIDs: [98])
        #expect(missing.appBytes == nil && missing.unreadable == 1)
    }
    @Test func cyclesCannotLoopAndNativeCaptureReadsTheCurrentProcess() {
        let cyclic = ProcessMemory.summarize([.init(pid: 1, parent: 2, residentBytes: 10), .init(pid: 2, parent: 1, residentBytes: 20)],
                                             appPID: 9, panePIDs: [1])
        #expect(cyclic.paneBytes == 30 && cyclic.paneProcesses == 2)
        let native = ProcessMemory.sample(appPID: ProcessInfo.processInfo.processIdentifier, panePIDs: [])
        #expect((native.appBytes ?? 0) > 0)
        #expect(native.paneBytes == 0)
    }
}
#endif
