import Foundation

/// Local tabs, splits, sizes, focus, folders and agent choices. Automatic recovery opens shells;
/// explicitly opening a named layout may start the saved agents. Running processes are never resumed.
public struct SavedSession: Codable, Sendable {
    public struct Pane: Codable, Sendable {
        public var id: String
        public var kind: PaneKind
        public var agentID: String?
        public var cwd: String?
        public var customName: String?

        public init(id: String, kind: PaneKind, agentID: String? = nil, cwd: String? = nil, customName: String? = nil) {
            self.id = id; self.kind = kind; self.agentID = agentID; self.cwd = cwd; self.customName = customName
        }
    }

    public struct Tab: Codable, Sendable {
        public var name: String
        public var layout: SplitNode
        public var focused: String

        public init(name: String, layout: SplitNode, focused: String) {
            self.name = name; self.layout = layout; self.focused = focused
        }
    }

    public var tabs: [Tab]
    public var active: Int?
    public var panes: [Pane]
    public var fractions: [String: [Double]]
    public var savedAt: Date

    public init(tabs: [Tab], active: Int?, panes: [Pane], fractions: [String: [Double]], savedAt: Date = .now) {
        self.tabs = tabs; self.active = active; self.panes = panes; self.fractions = fractions; self.savedAt = savedAt
    }
}

public enum SavedLayoutError: LocalizedError {
    case emptyName, invalidSession, missingLayout
    public var errorDescription: String? {
        switch self {
        case .emptyName: "Give this layout a name."
        case .invalidSession: "This layout has missing or invalid panes or splits."
        case .missingLayout: "This layout is no longer in your library."
        }
    }
}

extension SavedSession {
    /// Check topology before creating any processes. Bounds also protect against oversized imports.
    public func validate() throws {
        guard !tabs.isEmpty, tabs.count <= 32, !panes.isEmpty, panes.count <= 256,
              Set(panes.map(\.id)).count == panes.count,
              active.map({ tabs.indices.contains($0) }) ?? true else { throw SavedLayoutError.invalidSession }
        for pane in panes { if let name = pane.customName { _ = try PaneNameRules.clean(name) } }
        var leaves = Set<String>()
        var splits: [String: Int] = [:]
        func visit(_ node: SplitNode, depth: Int) throws {
            guard depth <= 32 else { throw SavedLayoutError.invalidSession }
            switch node {
            case .leaf(let id):
                guard !id.isEmpty, leaves.insert(id).inserted else { throw SavedLayoutError.invalidSession }
            case .split(_, let children):
                guard children.count >= 2, children.count <= 256 else { throw SavedLayoutError.invalidSession }
                splits[node.id] = children.count
                for child in children { try visit(child, depth: depth + 1) }
            }
        }
        for tab in tabs {
            try visit(tab.layout, depth: 0)
            guard tab.layout.leaves.contains(tab.focused) else { throw SavedLayoutError.invalidSession }
        }
        guard leaves == Set(panes.map(\.id)) else { throw SavedLayoutError.invalidSession }
        for (id, values) in fractions {
            guard splits[id] == values.count, values.allSatisfy({ $0.isFinite && $0 > 0 }),
                  abs(values.reduce(0, +) - 1) < 0.001 else { throw SavedLayoutError.invalidSession }
        }
    }

    /// Fresh pane ids and split keys let the same layout open repeatedly beside live terminals.
    public func freshCopy() throws -> SavedSession {
        try validate()
        let ids = Dictionary(uniqueKeysWithValues: panes.map { ($0.id, UUID().uuidString) })
        var sizes: [String: [Double]] = [:]
        func copy(_ node: SplitNode) -> SplitNode {
            switch node {
            case .leaf(let id): return .leaf(ids[id]!)
            case .split(let vertical, let children):
                let new = SplitNode.split(vertical: vertical, children.map(copy))
                sizes[new.id] = fractions[node.id]
                return new
            }
        }
        let newTabs = tabs.map { Tab(name: $0.name, layout: copy($0.layout), focused: ids[$0.focused]!) }
        return SavedSession(tabs: newTabs, active: active,
                            panes: panes.map { Pane(id: ids[$0.id]!, kind: $0.kind, agentID: $0.agentID, cwd: $0.cwd, customName: $0.customName) },
                            fractions: sizes, savedAt: savedAt)
    }
}

public struct SavedLayout: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var session: SavedSession

    public init(id: UUID = UUID(), name: String, session: SavedSession) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SavedLayoutError.emptyName }
        try session.validate()
        self.id = id; self.name = name; self.session = session
    }

    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || ([name] + session.tabs.map(\.name) + session.panes.flatMap { [$0.cwd, $0.agentID].compactMap { $0 } })
            .contains { $0.localizedStandardContains(query) }
    }
}

/// Disk operations throw: a damaged library must never silently become an empty, overwritten one.
public enum SavedLayoutStore {
    public static func load(from url: URL) throws -> [SavedLayout] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let layouts = try decoder.decode([SavedLayout].self, from: Data(contentsOf: url))
        guard Set(layouts.map(\.id)).count == layouts.count else { throw SavedLayoutError.invalidSession }
        for layout in layouts { _ = try SavedLayout(name: layout.name, session: layout.session) }
        return layouts
    }

    public static func save(_ layouts: [SavedLayout], to url: URL) throws {
        for layout in layouts { _ = try SavedLayout(name: layout.name, session: layout.session) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(layouts)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// An explicit, versioned file format; importing never executes anything or replaces a saved layout.
public enum SavedLayoutTransfer {
    private struct Document: Codable {
        var format = "xtermx-layout"
        var version = 1
        var layout: SavedLayout
    }

    public enum TransferError: LocalizedError {
        case unsupported, tooLarge
        public var errorDescription: String? {
            switch self {
            case .unsupported: "Choose a supported XTermX layout file."
            case .tooLarge: "Layout files must be smaller than 5 MB."
            }
        }
    }

    public static let maximumBytes = 5_000_000

    public static func encode(_ layout: SavedLayout) throws -> Data {
        _ = try SavedLayout(name: layout.name, session: layout.session)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(layout: layout))
        guard data.count < maximumBytes else { throw TransferError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> SavedLayout {
        guard data.count < maximumBytes else { throw TransferError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        guard document.format == "xtermx-layout", document.version == 1 else { throw TransferError.unsupported }
        // A new library identity even if the file came from this library. Pane ids change on open.
        return try SavedLayout(name: document.layout.name, session: document.layout.session)
    }
}
