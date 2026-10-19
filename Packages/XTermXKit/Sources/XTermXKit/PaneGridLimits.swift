import Foundation

/// Counts the largest row/column footprint conservatively for nested split trees.
public struct PaneGridLimits: Sendable {
    public let columns: Int
    public let rows: Int
    public init(columns: Int = 6, rows: Int = 4) {
        self.columns = min(12, max(1, columns)); self.rows = min(12, max(1, rows))
    }
    public func allows(_ tree: SplitNode, after target: String, vertical: Bool) -> Bool {
        guard tree.leaves.contains(target) else { return false }
        let size = tree.inserting("preview-" + UUID().uuidString, after: target, vertical: vertical).gridSize
        return size.columns <= columns && size.rows <= rows
    }
    /// Columns × rows for `count` panes, as square as possible; `vertical` puts the longer side down.
    /// Falls back to the other orientation, then a single line; nil when nothing fits.
    public func shape(for count: Int, vertical: Bool) -> (columns: Int, rows: Int)? {
        guard count > 0 else { return nil }
        let short = max(1, Int(Double(count).squareRoot())), long = (count + short - 1) / short
        let preferred = vertical ? (columns: short, rows: long) : (columns: long, rows: short)
        let candidates = [preferred, (columns: preferred.rows, rows: preferred.columns), (columns: count, rows: 1), (columns: 1, rows: count)]
        return candidates.first { $0.columns <= columns && $0.rows <= rows }
    }
    public func direction(_ preferred: Bool, tree: SplitNode, target: String) -> Bool? {
        if allows(tree, after: target, vertical: preferred) { return preferred }
        if allows(tree, after: target, vertical: !preferred) { return !preferred }
        return nil
    }
}

extension SplitNode {
    public var gridSize: (columns: Int, rows: Int) {
        switch self {
        case .leaf: (1, 1)
        case .split(let vertical, let children):
            vertical ? (children.map { $0.gridSize.columns }.max() ?? 1, children.reduce(0) { $0 + $1.gridSize.rows })
                : (children.reduce(0) { $0 + $1.gridSize.columns }, children.map { $0.gridSize.rows }.max() ?? 1)
        }
    }
}
