/// Most recently focused open panes, without duplicates or closed entries.
public enum RecentPaneList {
    public static func ids(history: [String], live: [String], limit: Int = 8) -> [String] {
        let available = Set(live)
        var seen = Set<String>()
        return Array(history.filter { available.contains($0) && seen.insert($0).inserted }.prefix(max(0, limit)))
    }
}
