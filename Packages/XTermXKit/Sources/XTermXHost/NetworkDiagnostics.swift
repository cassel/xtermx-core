#if os(macOS) || os(Linux)
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif
#if canImport(CoreWLAN)
import CoreWLAN
#endif

/// A snapshot of how this machine reaches its network: what the person needs to tell a slow
/// Wi‑Fi from a broken DNS from no network at all, without root (no ICMP: TCP connect timings).
public struct NetworkReport: Codable, Sendable, Hashable {
    public enum Verdict: String, Codable, Sendable, Hashable {
        case ok, slow, dnsFailing = "dns_failing", offline
    }

    /// One timed TCP connect. A refused connection still counts as reachable: the host answered.
    public struct Probe: Codable, Sendable, Hashable {
        public var label: String
        public var host: String
        public var port: UInt16
        public var milliseconds: Double?
        public var error: String?
        public var reachable: Bool { milliseconds != nil }

        public init(label: String, host: String, port: UInt16, milliseconds: Double? = nil, error: String? = nil) {
            self.label = label
            self.host = host
            self.port = port
            self.milliseconds = milliseconds
            self.error = error
        }
    }

    /// One timed name lookup through the system resolver.
    public struct Lookup: Codable, Sendable, Hashable {
        public var name: String
        public var milliseconds: Double?
        public var addresses: [String]
        public var error: String?
        public var resolved: Bool { !addresses.isEmpty }

        public init(name: String, milliseconds: Double? = nil, addresses: [String] = [], error: String? = nil) {
            self.name = name
            self.milliseconds = milliseconds
            self.addresses = addresses
            self.error = error
        }
    }

    public var interface: String?
    public var wifiName: String?
    public var gateway: String?
    public var dnsServers: [String]
    public var gatewayProbe: Probe?
    public var dnsProbes: [Probe]
    public var internetProbe: Probe?
    public var lookups: [Lookup]
    public var verdict: Verdict
    public var reasons: [String]
    public var at: Date

    public init(interface: String? = nil, wifiName: String? = nil, gateway: String? = nil, dnsServers: [String] = [],
                gatewayProbe: Probe? = nil, dnsProbes: [Probe] = [], internetProbe: Probe? = nil,
                lookups: [Lookup] = [], at: Date = .now) {
        self.interface = interface
        self.wifiName = wifiName
        self.gateway = gateway
        self.dnsServers = dnsServers
        self.gatewayProbe = gatewayProbe
        self.dnsProbes = dnsProbes
        self.internetProbe = internetProbe
        self.lookups = lookups
        self.at = at
        (verdict, reasons) = Self.judge(gateway: gatewayProbe, internet: internetProbe, lookups: lookups)
    }

    /// Above these, a link works but feels slow in a terminal (keystroke echo).
    public enum Thresholds {
        public static let gatewayMilliseconds = 50.0
        public static let internetMilliseconds = 250.0
        public static let lookupMilliseconds = 500.0
    }

    /// The verdict, worst first: no internet → offline; internet but no names → DNS failing;
    /// any slow step → slow. The gateway alone never decides offline: many routers refuse
    /// nothing and drop everything, so a silent gateway with a working internet is still ok.
    public static func judge(gateway: Probe?, internet: Probe?, lookups: [Lookup]) -> (Verdict, [String]) {
        let resolved = lookups.filter(\.resolved)
        let online = internet?.reachable == true
        if !online && resolved.isEmpty {
            if gateway == nil { return (.offline, ["No default route: not connected to a network."]) }
            if gateway?.reachable == false { return (.offline, ["The router and the internet do not answer."]) }
            return (.offline, ["The router answers but the internet does not."])
        }
        if !lookups.isEmpty && resolved.isEmpty {
            return (.dnsFailing, ["The internet answers but no name resolves: DNS is failing."])
        }
        var reasons: [String] = []
        if !online { reasons.append("Names resolve but a direct connection to the internet failed.") }
        if lookups.count > resolved.count { reasons.append("\(lookups.count - resolved.count) of \(lookups.count) names did not resolve.") }
        if let ms = gateway?.milliseconds, ms > Thresholds.gatewayMilliseconds {
            reasons.append("The router takes \(Int(ms)) ms (weak Wi‑Fi?).")
        }
        if let ms = internet?.milliseconds, ms > Thresholds.internetMilliseconds {
            reasons.append("The internet takes \(Int(ms)) ms.")
        }
        if let slowest = resolved.compactMap(\.milliseconds).max(), slowest > Thresholds.lookupMilliseconds {
            reasons.append("Name lookups take up to \(Int(slowest)) ms.")
        }
        return (reasons.isEmpty ? .ok : .slow, reasons)
    }
}

/// Collects a `NetworkReport`. Every step has a timeout so a dead network answers in seconds.
public enum NetworkDiagnostics {
    /// Answers TCP on 443 everywhere and needs no name lookup, so it separates "internet" from "DNS".
    public static let internetHost = "1.1.1.1"
    public static let lookupNames = ["apple.com", "github.com"]

    public static func run(timeout: Double = 2) async -> NetworkReport {
        let route = defaultRoute()
        let dns = dnsServers()
        // Routers rarely serve 443 but usually answer (or refuse) on 80.
        async let gateway: NetworkReport.Probe? = {
            guard let gw = route.gateway else { return nil }
            return await NetworkReport.Probe(label: "Router", host: gw, port: 80).timed(timeout: timeout)
        }()
        async let internet = NetworkReport.Probe(label: "Internet", host: internetHost, port: 443).timed(timeout: timeout)
        async let servers = withTaskGroup(of: (Int, NetworkReport.Probe).self) { group in
            for (i, server) in dns.prefix(4).enumerated() {
                group.addTask { (i, await NetworkReport.Probe(label: "DNS", host: server, port: 53).timed(timeout: timeout)) }
            }
            var out: [(Int, NetworkReport.Probe)] = []
            for await p in group { out.append(p) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        async let lookups = withTaskGroup(of: (Int, NetworkReport.Lookup).self) { group in
            for (i, name) in lookupNames.enumerated() { group.addTask { (i, await lookup(name, timeout: timeout)) } }
            var out: [(Int, NetworkReport.Lookup)] = []
            for await l in group { out.append(l) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return await NetworkReport(interface: route.interface, wifiName: wifiName(interface: route.interface), gateway: route.gateway,
                                   dnsServers: dns, gatewayProbe: gateway, dnsProbes: servers, internetProbe: internet, lookups: lookups)
    }

    // MARK: Configuration

    /// The default IPv4 route: macOS asks SystemConfiguration, Linux reads /proc/net/route.
    public static func defaultRoute() -> (interface: String?, gateway: String?) {
        #if canImport(SystemConfiguration)
        let v4 = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return (v4?["PrimaryInterface"] as? String, v4?["Router"] as? String)
        #else
        guard let table = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) else { return (nil, nil) }
        return parseProcNetRoute(table)
        #endif
    }

    /// DNS servers in use: macOS's resolver state (what `scutil --dns` shows first), else resolv.conf.
    public static func dnsServers() -> [String] {
        #if canImport(SystemConfiguration)
        let dns = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        if let servers = dns?["ServerAddresses"] as? [String], !servers.isEmpty { return servers }
        #endif
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return [] }
        return parseResolvConf(text)
    }

    /// `nameserver` lines of resolv.conf, in order, without duplicates or comments.
    public static func parseResolvConf(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "nameserver" else { continue }
            let server = String(fields[1])
            if !out.contains(server) { out.append(server) }
        }
        return out
    }

    /// The default route from /proc/net/route: destination 00000000, gateway in little-endian hex.
    public static func parseProcNetRoute(_ text: String) -> (interface: String?, gateway: String?) {
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 3, f[1] == "00000000", let raw = UInt32(f[2], radix: 16), raw != 0 else { continue }
            let bytes = [raw & 0xff, (raw >> 8) & 0xff, (raw >> 16) & 0xff, raw >> 24]
            return (String(f[0]), bytes.map(String.init).joined(separator: "."))
        }
        return (nil, nil)
    }

    /// The Wi‑Fi network name when macOS shares it (it needs Location access; nil otherwise).
    public static func wifiName(interface: String?) -> String? {
        #if canImport(CoreWLAN)
        guard let wifi = CWWiFiClient.shared().interface(), interface == nil || wifi.interfaceName == interface else { return nil }
        return wifi.ssid()
        #else
        return nil
        #endif
    }

    // MARK: Timing

    /// Resolves `name` through the system resolver (getaddrinfo), giving up after `timeout`.
    public static func lookup(_ name: String, timeout: Double) async -> NetworkReport.Lookup {
        let start = ContinuousClock.now
        // getaddrinfo can't be cancelled: whichever finishes first answers, and a stuck lookup is left
        // to end on its own thread instead of holding the report.
        let result: Result<[String], LookupError>? = await withCheckedContinuation { continuation in
            let once = Once()
            let answer: @Sendable (Result<[String], LookupError>?) -> Void = { value in
                if once.claim() { continuation.resume(returning: value) }
            }
            DispatchQueue.global().async { answer(resolve(name)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { answer(nil) }
        }
        let ms = (ContinuousClock.now - start).inMilliseconds
        switch result {
        case .success(let addresses)?: return .init(name: name, milliseconds: ms, addresses: addresses)
        case .failure(let e)?: return .init(name: name, milliseconds: ms, error: e.message)
        case nil: return .init(name: name, error: "Timed out after \(Int(timeout)) s.")
        }
    }

    public struct LookupError: Error, Sendable { public let message: String }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    private static func resolve(_ name: String) -> Result<[String], LookupError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(name, nil, &hints, &list)
        guard rc == 0, let list else { return .failure(LookupError(message: String(cString: gai_strerror(rc)))) }
        defer { freeaddrinfo(list) }
        var out: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = list
        while let n = node {
            if let address = numericHost(n.pointee.ai_addr, n.pointee.ai_addrlen), !out.contains(address) { out.append(address) }
            node = n.pointee.ai_next
        }
        return out.isEmpty ? .failure(LookupError(message: "No addresses.")) : .success(out)
    }

    private static func numericHost(_ addr: UnsafeMutablePointer<sockaddr>?, _ len: socklen_t) -> String? {
        guard let addr else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, len, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Times a non-blocking TCP connect to a numeric address. Connection refused means the host
    /// answered (with a reset), which is all a latency probe needs.
    public static func connectTime(host: String, port: UInt16, timeout: Double) -> Result<Double, LookupError> {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let info = list?.pointee else {
            return .failure(LookupError(message: "Not a numeric address."))
        }
        defer { freeaddrinfo(list) }
        let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard fd >= 0 else { return .failure(LookupError(message: String(cString: strerror(errno)))) }
        defer { close(fd) }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let start = ContinuousClock.now
        if connect(fd, info.ai_addr, info.ai_addrlen) == 0 { return .success((ContinuousClock.now - start).inMilliseconds) }
        if errno == ECONNREFUSED { return .success((ContinuousClock.now - start).inMilliseconds) }
        guard errno == EINPROGRESS else { return .failure(LookupError(message: String(cString: strerror(errno)))) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        let ms = (ContinuousClock.now - start).inMilliseconds
        guard ready > 0 else { return .failure(LookupError(message: "Timed out after \(Int(timeout)) s.")) }
        var soError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &size)
        if soError == 0 || soError == ECONNREFUSED { return .success(ms) }
        return .failure(LookupError(message: String(cString: strerror(soError))))
    }
}

extension NetworkReport.Probe {
    /// This probe with its connect time (or error) filled in, off the caller's thread.
    func timed(timeout: Double) async -> Self {
        let (host, port) = (host, port)
        var copy = self
        switch await Task.detached(operation: { NetworkDiagnostics.connectTime(host: host, port: port, timeout: timeout) }).value {
        case .success(let ms): copy.milliseconds = ms
        case .failure(let e): copy.error = e.message
        }
        return copy
    }
}

extension Duration {
    var inMilliseconds: Double {
        let (s, atto) = components
        return Double(s) * 1000 + Double(atto) / 1e15
    }
}
#endif
