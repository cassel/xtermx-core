import Foundation

/// A service the Mac keeps an eye on: a web address (`https://…`) or a `host:port` that should accept connections.
public struct ServiceTarget: Codable, Sendable, Hashable, Identifiable {
    public enum Endpoint: Sendable, Hashable {
        case http(URL)
        case tcp(host: String, port: UInt16)
    }

    public var id: UUID
    public var name: String
    public var address: String

    /// Nil when the address is neither an http(s) URL with a host nor `host:port`.
    public init?(id: UUID = UUID(), name: String, address: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.endpoint(address) != nil else { return nil }
        self.id = id
        self.address = address
        let name = ServiceRules.clean(name.trimmingCharacters(in: .whitespacesAndNewlines))
        self.name = name.isEmpty ? address : String(name.prefix(60))
    }

    public var endpoint: Endpoint? { Self.endpoint(address) }

    /// The address a browser can open: the URL itself, or `http://host:port` for a port.
    public var openURL: URL? {
        switch endpoint {
        case .http(let url): url
        case .tcp(let host, let port): URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)")
        case nil: nil
        }
    }

    static func endpoint(_ address: String) -> Endpoint? {
        guard !address.isEmpty, !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if address.contains("://") {
            guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else { return nil }
            return .http(url)
        }
        let host: Substring
        let portText: Substring
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            host = address[address.index(after: address.startIndex)..<close]
            let rest = address[address.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            portText = rest.dropFirst()
        } else {
            let parts = address.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            host = parts[0]
            portText = parts[1]
        }
        guard !host.isEmpty, !host.contains(where: \.isWhitespace), let port = UInt16(portText), port > 0 else { return nil }
        return .tcp(host: String(host), port: port)
    }
}

public enum ServiceHealth: String, Codable, Sendable {
    case unknown, up, degraded, down

    /// A state from a newer host reads as unknown.
    public init(from decoder: Decoder) throws {
        self = ServiceHealth(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// What the last check of one service found.
public struct ServiceStatus: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var address: String
    public var health: ServiceHealth
    public var latencyMilliseconds: Double?
    public var lastError: String?
    public var checkedAt: Date?

    public init(id: UUID, name: String, address: String, health: ServiceHealth = .unknown,
                latencyMilliseconds: Double? = nil, lastError: String? = nil, checkedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.health = health
        self.latencyMilliseconds = latencyMilliseconds
        self.lastError = lastError
        self.checkedAt = checkedAt
    }

    public init(_ target: ServiceTarget) {
        self.init(id: target.id, name: target.name, address: target.address)
    }

    private enum CodingKeys: String, CodingKey { case id, name, address, health, latencyMilliseconds, lastError, checkedAt }

    /// Fields a newer host adds are ignored; missing optional ones read as nil.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        health = (try? c.decodeIfPresent(ServiceHealth.self, forKey: .health)) ?? .unknown
        latencyMilliseconds = try? c.decodeIfPresent(Double.self, forKey: .latencyMilliseconds)
        lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        checkedAt = try? c.decodeIfPresent(Date.self, forKey: .checkedAt)
    }

    public var openURL: URL? { ServiceTarget(id: id, name: name, address: address)?.openURL }
}

/// "n/m up" for the title bar chip and the phone.
public struct ServiceSummary: Sendable, Hashable {
    public var up: Int
    public var total: Int
    public init(up: Int, total: Int) { self.up = up; self.total = total }
    public init(_ statuses: [ServiceStatus]) {
        self.init(up: statuses.filter { $0.health == .up }.count, total: statuses.count)
    }
    public var text: String { "\(up)/\(total) up" }
    public var allUp: Bool { up == total }
}

/// One probe's raw result.
public struct ServiceProbeResult: Sendable, Hashable {
    public var latency: TimeInterval?
    public var httpStatus: Int?
    public var error: String?
    public init(latency: TimeInterval? = nil, httpStatus: Int? = nil, error: String? = nil) {
        self.latency = latency
        self.httpStatus = httpStatus
        self.error = error
    }
}

public enum ServiceRules {
    public static let intervalRange: ClosedRange<TimeInterval> = 15...600
    public static let defaultInterval: TimeInterval = 60
    /// Slower answers than this count as degraded.
    public static let slowLatency: TimeInterval = 2
    public static let httpTimeout: TimeInterval = 10
    public static let connectTimeout: TimeInterval = 5
    public static let maximumTargets = 50

    public static func clampInterval(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, intervalRange.lowerBound), intervalRange.upperBound)
    }

    /// 2xx/3xx up, 4xx degraded, 5xx or no answer down; a slow answer is degraded.
    public static func health(_ result: ServiceProbeResult) -> (health: ServiceHealth, error: String?) {
        if let error = result.error { return (.down, clean(error)) }
        if let code = result.httpStatus {
            if code >= 500 { return (.down, "HTTP \(code)") }
            if code >= 400 { return (.degraded, "HTTP \(code)") }
        }
        if let latency = result.latency, latency > slowLatency {
            return (.degraded, "Slow: \(Int((latency * 1000).rounded())) ms")
        }
        return (.up, nil)
    }

    /// Control characters (from a server's answer, a name, a terminal) become spaces, so the text is safe in headers and notices.
    public static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        })).prefix(200).description
    }
}
