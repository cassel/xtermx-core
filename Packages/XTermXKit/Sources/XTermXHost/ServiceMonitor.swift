import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import NIOCore
import XTermXKit
import XTermXNIO

/// Checks a list of web addresses and ports every `interval` seconds and keeps each one's latest state.
///
/// A service that was up or degraded and is now down is told once through `onDown`; it is told again
/// only after it came back. The list and interval are kept in `defaults`.
@MainActor
@Observable
public final class ServiceMonitor {
    public typealias Probe = @Sendable (ServiceTarget) async -> ServiceProbeResult

    public private(set) var targets: [ServiceTarget] = []
    public private(set) var interval: TimeInterval = ServiceRules.defaultInterval
    /// One per target, in the same order.
    public private(set) var statuses: [ServiceStatus] = []
    public private(set) var isChecking = false
    public var summary: ServiceSummary { ServiceSummary(statuses) }

    /// After every check and every change to the list.
    @ObservationIgnored public var onChange: (([ServiceStatus]) -> Void)?
    /// A service went down.
    @ObservationIgnored public var onDown: ((ServiceStatus) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let probe: Probe
    @ObservationIgnored private var loop: Task<Void, Never>?

    private enum Key {
        static let targets = "xtermx.services.targets"
        static let interval = "xtermx.services.interval"
    }

    public init(defaults: UserDefaults? = .standard, probe: @escaping Probe = ServiceMonitor.liveProbe) {
        self.defaults = defaults
        self.probe = probe
        if let data = defaults?.data(forKey: Key.targets),
           let saved = try? JSONDecoder().decode([ServiceTarget].self, from: data) {
            targets = saved.filter { $0.endpoint != nil }
        }
        if let saved = defaults?.object(forKey: Key.interval) as? Double { interval = ServiceRules.clampInterval(saved) }
        statuses = targets.map(ServiceStatus.init)
    }

    // MARK: Settings

    public func setTargets(_ list: [ServiceTarget]) {
        targets = Array(list.filter { $0.endpoint != nil }.prefix(ServiceRules.maximumTargets))
        let old = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        statuses = targets.map { target in
            guard var status = old[target.id], status.address == target.address else { return ServiceStatus(target) }
            status.name = target.name
            return status
        }
        defaults?.set(try? JSONEncoder().encode(targets), forKey: Key.targets)
        onChange?(statuses)
        if loop != nil { restart() }
    }

    public func setInterval(_ seconds: TimeInterval) {
        interval = ServiceRules.clampInterval(seconds)
        defaults?.set(interval, forKey: Key.interval)
        if loop != nil { restart() }
    }

    // MARK: Checking

    /// Checks every `interval` seconds, first right away. Does nothing while the list is empty.
    public func start() {
        guard loop == nil else { return }
        restart()
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.targets.isEmpty { await self.checkNow() }
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    /// Checks every target once, all at the same time.
    public func checkNow() async {
        let list = targets
        guard !list.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        let probe = self.probe
        let results = await withTaskGroup(of: (UUID, ServiceProbeResult).self) { group in
            for target in list { group.addTask { (target.id, await probe(target)) } }
            var out: [UUID: ServiceProbeResult] = [:]
            for await (id, result) in group { out[id] = result }
            return out
        }
        let now = Date()
        var wentDown: [ServiceStatus] = []
        for (index, status) in statuses.enumerated() {
            guard let target = list.first(where: { $0.id == status.id && $0.address == status.address }),
                  let result = results[target.id] else { continue }
            let (health, error) = ServiceRules.health(result)
            var next = status
            next.health = health
            next.lastError = error
            next.latencyMilliseconds = result.latency.map { ($0 * 1000).rounded() }
            next.checkedAt = now
            if health == .down, status.health == .up || status.health == .degraded { wentDown.append(next) }
            statuses[index] = next
        }
        onChange?(statuses)
        for status in wentDown { onDown?(status) }
    }

    // MARK: Probes

    public nonisolated static let liveProbe: Probe = { target in
        let started = ContinuousClock.now
        func elapsed() -> TimeInterval {
            let d = (ContinuousClock.now - started).components
            return Double(d.seconds) + Double(d.attoseconds) / 1e18
        }
        switch target.endpoint {
        case .http(let url):
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: ServiceRules.httpTimeout)
            request.httpMethod = "GET"
            do {
                let (_, response) = try await probeSession.data(for: request)
                return ServiceProbeResult(latency: elapsed(), httpStatus: (response as? HTTPURLResponse)?.statusCode)
            } catch {
                return ServiceProbeResult(error: error.localizedDescription)
            }
        case .tcp(let host, let port):
            do {
                let stream = try await TCPStream.connect(host: host, port: Int(port),
                                                         timeout: .seconds(Int64(ServiceRules.connectTimeout)))
                let latency = elapsed()
                stream.close()
                return ServiceProbeResult(latency: latency)
            } catch {
                return ServiceProbeResult(error: "Can't connect to \(host):\(port)")
            }
        case nil:
            return ServiceProbeResult(error: "Not a web address or host:port")
        }
    }

    private nonisolated static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = ServiceRules.httpTimeout
        config.timeoutIntervalForResource = ServiceRules.httpTimeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()
}
