import Testing
import XTermXKit

struct RecentPaneListTests {
    @Test func recentPanesKeepFocusOrderAndExcludeClosedPanes() {
        #expect(RecentPaneList.ids(history: ["closed", "b", "a", "b", "c"], live: ["a", "b", "c", "unvisited"], limit: 2) == ["b", "a"])
        #expect(RecentPaneList.ids(history: [], live: ["a"]).isEmpty)
        #expect(RecentPaneList.ids(history: ["a"], live: ["a"], limit: -1).isEmpty)
    }
}
