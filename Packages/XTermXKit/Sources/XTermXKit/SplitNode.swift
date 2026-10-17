import Foundation

/// A workspace's split layout: leaves are pane ids.
public indirect enum SplitNode: Hashable, Codable, Sendable {
    case leaf(String)
    /// `vertical` stacks children top to bottom (Split Down); otherwise side by side (Split Right).
    case split(vertical: Bool, [SplitNode])

    public var id: String {
        switch self {
        case .leaf(let p): p
        case .split(let v, let c): (v ? "v:" : "h:") + c.map(\.id).joined(separator: ",")
        }
    }

    public var leaves: [String] {
        switch self {
        case .leaf(let p): [p]
        case .split(_, let c): c.flatMap(\.leaves)
        }
    }

    /// Ids of every split inside this tree, itself included.
    public var splitIDs: [String] {
        switch self {
        case .leaf: []
        case .split(_, let c): [id] + c.flatMap(\.splitIDs)
        }
    }

    /// Puts `new` after `target`, in a split of the given direction.
    public func inserting(_ new: String, after target: String, vertical: Bool) -> SplitNode {
        switch self {
        case .leaf(let p):
            return p == target ? .split(vertical: vertical, [.leaf(p), .leaf(new)]) : self
        case .split(let v, let children):
            if v == vertical, let i = children.firstIndex(of: .leaf(target)) {
                var c = children
                c.insert(.leaf(new), at: i + 1)
                return .split(vertical: v, c)
            }
            return .split(vertical: v, children.map { $0.inserting(new, after: target, vertical: vertical) })
        }
    }

    /// Same tree with panes `a` and `b` trading places.
    public func swapping(_ a: String, _ b: String) -> SplitNode {
        switch self {
        case .leaf(let p): .leaf(p == a ? b : p == b ? a : p)
        case .split(let v, let c): .split(vertical: v, c.map { $0.swapping(a, b) })
        }
    }

    /// Where each pane sits inside `rect`, with split sizes from `fractions(splitID, childCount)`.
    public func frames(in rect: CGRect, fractions: (String, Int) -> [CGFloat]) -> [String: CGRect] {
        switch self {
        case .leaf(let p):
            return [p: rect]
        case .split(let v, let children):
            let f = fractions(id, children.count)
            var out: [String: CGRect] = [:]
            var offset: CGFloat = 0
            for (i, child) in children.enumerated() {
                let share = i < f.count ? f[i] : 1 / CGFloat(children.count)
                let r = v
                    ? CGRect(x: rect.minX, y: rect.minY + offset * rect.height, width: rect.width, height: share * rect.height)
                    : CGRect(x: rect.minX + offset * rect.width, y: rect.minY, width: share * rect.width, height: rect.height)
                out.merge(child.frames(in: r, fractions: fractions)) { a, _ in a }
                offset += share
            }
            return out
        }
    }

    /// Removes a pane; nil when nothing is left. Single-child splits collapse.
    public func removing(_ target: String) -> SplitNode? {
        switch self {
        case .leaf(let p):
            return p == target ? nil : self
        case .split(let v, let children):
            let c = children.compactMap { $0.removing(target) }
            if c.isEmpty { return nil }
            if c.count == 1 { return c[0] }
            return .split(vertical: v, c)
        }
    }
}
