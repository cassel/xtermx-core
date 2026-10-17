import Testing
@testable import XTermXKit

@Suite struct PaneGridLimitsTests {
    @Test func limitsApplyBeforeSplittingAndAutoSplitCanUseTheOtherAxis() {
        let row = SplitNode.split(vertical: false, (1...6).map { .leaf("\($0)") })
        let limits = PaneGridLimits()
        #expect(row.gridSize.columns == 6 && row.gridSize.rows == 1)
        #expect(!limits.allows(row, after: "1", vertical: false))
        #expect(limits.allows(row, after: "1", vertical: true))
        #expect(limits.direction(false, tree: row, target: "1") == true)
        #expect(!limits.allows(row, after: "missing", vertical: true))
        let full = SplitNode.split(vertical: true, (1...4).map { r in
            .split(vertical: false, (1...6).map { .leaf("\(r)-\($0)") })
        })
        #expect(full.gridSize.columns == 6 && full.gridSize.rows == 4)
        #expect(limits.direction(false, tree: full, target: "1-1") == nil)
        #expect(limits.direction(true, tree: full, target: "1-1") == nil)
    }
    @Test func nestedFootprintsRespectBothDirectionsAndClampPreferences() {
        let nested = SplitNode.split(vertical: true, [.split(vertical: false, [.leaf("a"), .leaf("b")]), .leaf("c")])
        #expect(nested.gridSize.columns == 2 && nested.gridSize.rows == 2)
        #expect(!PaneGridLimits(columns: 2, rows: 2).allows(nested, after: "c", vertical: true))
        #expect(PaneGridLimits(columns: 2, rows: 2).allows(nested, after: "c", vertical: false))
        let clamped = PaneGridLimits(columns: -1, rows: 200)
        #expect(clamped.columns == 1 && clamped.rows == 12)
        #expect(!clamped.allows(.leaf("a"), after: "a", vertical: false))
    }
}
