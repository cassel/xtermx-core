#if os(macOS) || os(Linux)
import Foundation
import Testing
import XTermXHost
import XTermXKit

struct NetworkDiagnosticsTests {
    typealias Probe = NetworkReport.Probe
    typealias Lookup = NetworkReport.Lookup

    @Test func resolvConfKeepsNameserversInOrder() {
        let text = """
        # generated
        search lan
        nameserver 192.168.1.1
        nameserver\t1.1.1.1 # cloudflare
        ;nameserver 9.9.9.9
        nameserver 192.168.1.1
        nameserver fe80::1%en0
        """
        #expect(NetworkDiagnostics.parseResolvConf(text) == ["192.168.1.1", "1.1.1.1", "fe80::1%en0"])
    }

    @Test func procNetRouteFindsDefaultGateway() {
        let table = """
        Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
        eth0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0
        eth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0
        """
        let route = NetworkDiagnostics.parseProcNetRoute(table)
        #expect(route.interface == "eth0")
        #expect(route.gateway == "192.168.1.1")
        #expect(NetworkDiagnostics.parseProcNetRoute("Iface\tDestination\tGateway\n").gateway == nil)
    }

    private let fastLookups = [Lookup(name: "a", milliseconds: 20, addresses: ["1.2.3.4"]), Lookup(name: "b", milliseconds: 30, addresses: ["5.6.7.8"])]

    @Test func verdictOk() {
        let (v, reasons) = NetworkReport.judge(gateway: Probe(label: "", host: "", port: 80, milliseconds: 3),
                                              internet: Probe(label: "", host: "", port: 443, milliseconds: 20), lookups: fastLookups)
        #expect(v == .ok)
        #expect(reasons.isEmpty)
    }

    @Test func verdictSlow() {
        let (v, reasons) = NetworkReport.judge(gateway: Probe(label: "", host: "", port: 80, milliseconds: 120),
                                              internet: Probe(label: "", host: "", port: 443, milliseconds: 400), lookups: fastLookups)
        #expect(v == .slow)
        #expect(reasons.count == 2)
    }

    @Test func verdictDNSFailing() {
        let failed = [Lookup(name: "a", error: "nodename nor servname provided"), Lookup(name: "b", error: "Timed out")]
        let (v, _) = NetworkReport.judge(gateway: nil, internet: Probe(label: "", host: "", port: 443, milliseconds: 20), lookups: failed)
        #expect(v == .dnsFailing)
    }

    @Test func verdictOffline() {
        let failed = [Lookup(name: "a", error: "x")]
        let down = Probe(label: "", host: "", port: 443, error: "Timed out")
        #expect(NetworkReport.judge(gateway: nil, internet: down, lookups: failed).0 == .offline)
        #expect(NetworkReport.judge(gateway: Probe(label: "", host: "", port: 80, milliseconds: 2), internet: down, lookups: failed).0 == .offline)
    }

    @Test func silentRouterDoesNotMeanOffline() {
        let (v, _) = NetworkReport.judge(gateway: Probe(label: "", host: "", port: 80, error: "Timed out"),
                                        internet: Probe(label: "", host: "", port: 443, milliseconds: 20), lookups: fastLookups)
        #expect(v == .ok)
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let report = NetworkReport(interface: "en0", gateway: "10.0.0.1", dnsServers: ["10.0.0.1"], lookups: fastLookups)
        let decoded = try JSONDecoder().decode(NetworkReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.verdict == report.verdict)
        #expect(decoded.gateway == "10.0.0.1")
        #expect(try String(decoding: JSONEncoder().encode(NetworkReport()), as: UTF8.self).contains("\"offline\""))
    }

    @Test func refusedLocalPortCountsAsReachable() {
        // Nothing listens on port 1 of loopback, so the kernel refuses at once.
        guard case .success(let ms) = NetworkDiagnostics.connectTime(host: "127.0.0.1", port: 1, timeout: 1) else {
            Issue.record("loopback should answer")
            return
        }
        #expect(ms < 1000)
        if case .success = NetworkDiagnostics.connectTime(host: "not-an-ip", port: 80, timeout: 1) { Issue.record("names are refused") }
    }

    @Test func lsofFieldOutputParses() {
        let text = """
        p812
        cControlCe
        Lcassel
        f9
        n*:7000
        f10
        n[::]:7000
        p4401
        cnode
        Lcassel
        f23
        n127.0.0.1:7000
        """
        let holders = PortHolders.parseLsof(text)
        #expect(holders.map(\.pid) == [812, 4401])
        #expect(holders[0].command == "ControlCe")
        #expect(holders[0].user == "cassel")
        #expect(holders[0].endpoints == ["*:7000", "[::]:7000"])
        #expect(holders[1].endpoints == ["127.0.0.1:7000"])
        #expect(holders.allSatisfy { !$0.isOurs })
    }

    @Test func addressInUseIsRecognized() {
        #expect(PortHolders.isAddressInUse("bind(descriptor:ptr:bytes:): Address already in use (errno: 48)"))
        #expect(!PortHolders.isAddressInUse("bind(descriptor:ptr:bytes:): Permission denied (errno: 13)"))
    }

    @Test func terminateRefusesProcessesWeDidNotStart() {
        #expect(!PortHolders.terminate(PortHolder(pid: 1, command: "launchd", isOurs: true)))
        #expect(!PortHolders.terminate(PortHolder(pid: getppid(), command: "parent", isOurs: true)))
    }
}

struct HostRouteTests {
    @Test func classifiesAddresses() {
        #expect(HostRoute.classify("192.168.1.20") == .lan)
        #expect(HostRoute.classify("172.20.0.3") == .lan)
        #expect(HostRoute.classify("172.40.0.3") == .internet)
        #expect(HostRoute.classify("mac-mini.local") == .lan)
        #expect(HostRoute.classify("[fe80::1]") == .lan)
        #expect(HostRoute.classify("100.101.2.3") == .tailscale)
        #expect(HostRoute.classify("mac.tail1234.ts.net") == .tailscale)
        #expect(HostRoute.classify("127.0.0.1") == .loopback)
        #expect(HostRoute.classify("8.8.8.8") == .internet)
        #expect(HostRoute.classify("example.com") == .internet)
    }
}
#endif
