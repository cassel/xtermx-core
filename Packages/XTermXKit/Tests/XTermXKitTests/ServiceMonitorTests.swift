#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost
import XTermXNIO

@Suite struct ServiceTargetTests {
    @Test func parsesWebAddressesAndHostPorts() throws {
        #expect(ServiceTarget(name: "web", address: "https://example.com/health")?.endpoint == .http(URL(string: "https://example.com/health")!))
        #expect(ServiceTarget(name: "db", address: "localhost:5432")?.endpoint == .tcp(host: "localhost", port: 5432))
        #expect(ServiceTarget(name: "v6", address: "[::1]:8080")?.endpoint == .tcp(host: "::1", port: 8080))
        #expect(ServiceTarget(name: "x", address: "localhost") == nil)
        #expect(ServiceTarget(name: "x", address: "host:99999") == nil)
        #expect(ServiceTarget(name: "x", address: "ftp://example.com") == nil)
        #expect(ServiceTarget(name: "x", address: "") == nil)
    }

    @Test func intervalIsClampedBetweenFifteenSecondsAndTenMinutes() {
        #expect(ServiceRules.clampInterval(1) == 15)
        #expect(ServiceRules.clampInterval(60) == 60)
        #expect(ServiceRules.clampInterval(10_000) == 600)
    }

    @Test func healthFollowsStatusAndLatency() {
        #expect(ServiceRules.health(.init(latency: 0.05, httpStatus: 200)).health == .up)
        #expect(ServiceRules.health(.init(latency: 0.05, httpStatus: 302)).health == .up)
        #expect(ServiceRules.health(.init(latency: 3, httpStatus: 200)).health == .degraded)
        #expect(ServiceRules.health(.init(latency: 0.05, httpStatus: 404)).health == .degraded)
        #expect(ServiceRules.health(.init(latency: 0.05, httpStatus: 503)).health == .down)
        #expect(ServiceRules.health(.init(latency: 0.01)).health == .up)
        let failed = ServiceRules.health(.init(error: "refused\r\nX-Evil: 1"))
        #expect(failed.health == .down)
        #expect(failed.error == "refused  X-Evil: 1")
    }

    @Test func chipSummaryAndOpenableAddress() throws {
        let id = UUID()
        let statuses = [ServiceStatus(id: id, name: "a", address: "localhost:3000", health: .up),
                        ServiceStatus(id: UUID(), name: "b", address: "https://x.dev/health", health: .degraded)]
        #expect(ServiceSummary(statuses).text == "1/2 up")
        #expect(!ServiceSummary(statuses).allUp)
        #expect(statuses[0].openURL == URL(string: "http://localhost:3000"))
        #expect(statuses[1].openURL == URL(string: "https://x.dev/health"))
        #expect(ServiceStatus(id: id, name: "v6", address: "[::1]:80").openURL == URL(string: "http://[::1]:80"))
    }

    @Test func statusRoundTripsAndDecodesTolerantly() throws {
        let status = ServiceStatus(id: UUID(), name: "web", address: "https://x.dev", health: .degraded,
                                   latencyMilliseconds: 12, lastError: "slow", checkedAt: Date(timeIntervalSince1970: 1000))
        let back = try WireCoding.decoder().decode(ServiceStatus.self, from: WireCoding.encoder().encode(status))
        #expect(back == status)
        let newer = #"{"id":"\#(UUID().uuidString)","name":"a","address":"b:1","health":"sleeping","extra":1}"#
        let decoded = try WireCoding.decoder().decode(ServiceStatus.self, from: Data(newer.utf8))
        #expect(decoded.health == .unknown)
        #expect(decoded.latencyMilliseconds == nil)
    }
}

@Suite(.serialized) @MainActor struct ServiceMonitorTests {
    private func server(status: String = "200 OK") throws -> (RawHTTPServer, Int) {
        let server = RawHTTPServer { _ in Data("HTTP/1.1 \(status)\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8) }
        let port = try server.start(host: "127.0.0.1", port: 0)
        return (server, port)
    }

    private func defaults() -> UserDefaults {
        let name = "ServiceMonitorTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func portCheckGoesUpThenDownAndTellsOnce() async throws {
        let (server, port) = try server()
        let monitor = ServiceMonitor(defaults: defaults())
        var downs: [ServiceStatus] = []
        monitor.onDown = { downs.append($0) }
        monitor.setTargets([try #require(ServiceTarget(name: "api", address: "127.0.0.1:\(port)"))])
        #expect(monitor.statuses.first?.health == .unknown)
        await monitor.checkNow()
        #expect(monitor.statuses.first?.health == .up)
        #expect(monitor.statuses.first?.latencyMilliseconds != nil)
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        await monitor.checkNow()
        #expect(monitor.statuses.first?.health == .down)
        #expect(monitor.statuses.first?.lastError?.isEmpty == false)
        await monitor.checkNow()
        #expect(downs.count == 1)
        #expect(downs.first?.name == "api")
        #expect(monitor.summary == ServiceSummary(up: 0, total: 1))
    }

    @Test func httpCheckReadsTheStatusCode() async throws {
        let (ok, okPort) = try server()
        let (broken, brokenPort) = try server(status: "503 Service Unavailable")
        defer { ok.stop(); broken.stop() }
        let monitor = ServiceMonitor(defaults: defaults())
        monitor.setTargets([try #require(ServiceTarget(name: "ok", address: "http://127.0.0.1:\(okPort)/")),
                            try #require(ServiceTarget(name: "broken", address: "http://127.0.0.1:\(brokenPort)/"))])
        await monitor.checkNow()
        #expect(monitor.statuses.map(\.health) == [.up, .down])
        #expect(monitor.statuses[1].lastError == "HTTP 503")
        #expect(monitor.summary == ServiceSummary(up: 1, total: 2))
    }

    @Test func targetsAndIntervalPersist() throws {
        let d = defaults()
        let monitor = ServiceMonitor(defaults: d)
        monitor.setTargets([try #require(ServiceTarget(name: "db", address: "localhost:5432"))])
        monitor.setInterval(5)
        let again = ServiceMonitor(defaults: d)
        #expect(again.targets.map(\.address) == ["localhost:5432"])
        #expect(again.interval == 15)
        #expect(again.statuses.count == 1)
    }

    @Test func removingATargetDropsItsStatus() async throws {
        let monitor = ServiceMonitor(defaults: defaults(), probe: { _ in .init(latency: 0.01) })
        let a = try #require(ServiceTarget(name: "a", address: "a:1"))
        let b = try #require(ServiceTarget(name: "b", address: "b:2"))
        monitor.setTargets([a, b])
        await monitor.checkNow()
        monitor.setTargets([b])
        #expect(monitor.statuses.map(\.name) == ["b"])
        #expect(monitor.statuses.first?.health == .up)
    }
}
#endif
