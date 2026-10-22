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
    @Test func workspaceGridsAreBalancedAndFitTheLimits() {
        let limits = PaneGridLimits()
        #expect(limits.shape(for: 4, vertical: false)! == (2, 2))
        #expect(limits.shape(for: 8, vertical: false)! == (4, 2))
        #expect(limits.shape(for: 20, vertical: false)! == (5, 4))
        #expect(limits.shape(for: 2, vertical: true)! == (1, 2))
        #expect(limits.shape(for: 20, vertical: true)! == (5, 4), "5 rows do not fit, so the grid turns")
        #expect(PaneGridLimits(columns: 12, rows: 1).shape(for: 4, vertical: false)! == (4, 1))
        #expect(limits.shape(for: 30, vertical: false) == nil)
        #expect(limits.shape(for: 0, vertical: false) == nil)

        let ids = (1...10).map(String.init)
        let tree = SplitNode.grid(ids, lines: 3, vertical: false)!
        #expect(tree.leaves == ids)
        #expect(tree.gridSize.columns == 4 && tree.gridSize.rows == 3)
        guard case .split(true, let rows) = tree else { Issue.record("rows should be stacked"); return }
        #expect(rows.map(\.leaves.count) == [4, 3, 3])
        let columns = SplitNode.grid(Array(ids.prefix(4)), lines: 2, vertical: true)!
        #expect(columns == .split(vertical: false, [.split(vertical: true, [.leaf("1"), .leaf("2")]), .split(vertical: true, [.leaf("3"), .leaf("4")])]))
        #expect(SplitNode.grid(["a"], lines: 3, vertical: false) == .leaf("a"))
        #expect(SplitNode.grid(["a", "b"], lines: 1, vertical: false) == .split(vertical: false, [.leaf("a"), .leaf("b")]))
        #expect(SplitNode.grid([], lines: 1, vertical: false) == nil)
    }
}
