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
