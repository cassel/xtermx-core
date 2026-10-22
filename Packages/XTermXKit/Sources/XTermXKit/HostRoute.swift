import Foundation

/// How a device reaches its host, judged from the address in use. It explains latency: the same
/// Wi‑Fi is a few milliseconds, Tailscale or the internet can be ten times that.
public enum HostRoute: String, Codable, Sendable, Hashable {
    case loopback, lan, tailscale, internet

    public static func classify(_ address: String) -> HostRoute {
        let host = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return .loopback }
        if host.hasSuffix(".local") || host.hasSuffix(".local.") { return .lan }
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return .tailscale }
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return host.contains(":") ? .lan : .internet }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return .internet }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): return .lan
        case (172, 16...31): return .lan
        case (100, 64...127): return .tailscale
        default: return .internet
        }
    }

    /// Below this a terminal feels local.
    public static let snappyMilliseconds = 40.0
}

/// The addresses a host announces while connected, so a saved pairing follows it across networks.
public enum HostAddresses {
    public static let maximumCount = 8

    /// Host names and IP literals only: no spaces, slashes or control characters, a sane length, no repeats.
    public static func valid(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in list {
            let a = raw.trimmingCharacters(in: .whitespaces)
            // Only what a host name or IP literal can hold: "x@evil.com" would make the URL's host evil.com.
            guard (1...253).contains(a.utf8.count),
                  a.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-:[]%".unicodeScalars.contains($0)) }),
                  seen.insert(a).inserted else { continue }
            out.append(a)
            if out.count == maximumCount { break }
        }
        return out
    }

    /// Tailscale first (it works at home and away), the rest in the host's order.
    public static func ordered(_ list: [String]) -> [String] {
        list.filter { HostRoute.classify($0) == .tailscale } + list.filter { HostRoute.classify($0) != .tailscale }
    }

    /// The saved pairing with the host's live addresses as its alternates. The first address stays,
    /// so the pairing keeps its identity (and its place on the Watch).
    public static func merge(_ pairing: PairingInfo, live: [String]) -> PairingInfo {
        let live = valid(live)
        guard !live.isEmpty else { return pairing }
        var updated = pairing
        updated.alternates = ordered(live).filter { $0 != pairing.address }
        return updated
    }
}
