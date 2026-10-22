#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import XTermXKit
@testable import XTermXHost

@Suite struct DevServerTests {
    @Test func tunnelFramesRoundTrip() throws {
        let id = UUID()
        let bytes = Data([0, 1, 2, 255])
        let client: [ClientMessage] = [.tunnelOpen(streamID: id, port: 3000), .tunnelOpen(streamID: id, port: 3000, paneID: "p1"), .tunnelData(streamID: id, data: bytes), .tunnelClose(streamID: id)]
        for message in client {
            let decoded = try WireCoding.decoder().decode(ClientMessage.self, from: WireCoding.encoder().encode(message))
            switch (message, decoded) {
            case (.tunnelOpen(let a, let p, let x), .tunnelOpen(let b, let q, let y)): #expect(a == b && p == q && x == y)
            case (.tunnelData(let a, let d), .tunnelData(let b, let e)): #expect(a == b && d == e)
            case (.tunnelClose(let a), .tunnelClose(let b)): #expect(a == b)
            default: Issue.record("Decoded \(decoded) from \(message)")
            }
        }
        let ports = [DevServerPort(port: 5173, paneID: "p1", process: "node")]
        let host: [HostMessage] = [.devServers(ports), .tunnelOpened(streamID: id), .tunnelData(streamID: id, data: bytes),
                                   .tunnelClosed(streamID: id, reason: "gone"), .tunnelClosed(streamID: id, reason: nil)]
        for message in host {
            let decoded = try WireCoding.decoder().decode(HostMessage.self, from: WireCoding.encoder().encode(message))
            switch (message, decoded) {
            case (.devServers(let a), .devServers(let b)): #expect(a == b)
            case (.tunnelOpened(let a), .tunnelOpened(let b)): #expect(a == b)
            case (.tunnelData(let a, let d), .tunnelData(let b, let e)): #expect(a == b && d == e)
            case (.tunnelClosed(let a, let r), .tunnelClosed(let b, let s)): #expect(a == b && r == s)
            default: Issue.record("Decoded \(decoded) from \(message)")
            }
        }
    }

    @Test func olderClientsSkipTunnelMessagesInRPCReplies() throws {
        let reply = RPCResponse(requestID: Data([1]), messages: [.devServers([]), .pong(Date(timeIntervalSince1970: 0))])
        let json = try WireCoding.encoder().encode(reply)
        #expect(try WireCoding.decoder().decode(RPCResponse.self, from: json).messages.count == 2)
    }

    @Test func sharingDevServersStartsOffAndOldSettingsDecode() throws {
        #expect(!RemotePermissions().shareDevServers)
        let old = Data(#"{"openSessions":true,"manageRooms":false,"sendFiles":true}"#.utf8)
        let decoded = try JSONDecoder().decode(RemotePermissions.self, from: old)
        #expect(decoded.sendFiles && !decoded.shareDevServers)
        let on = RemotePermissions(shareDevServers: true)
        #expect(try JSONDecoder().decode(RemotePermissions.self, from: JSONEncoder().encode(on)) == on)
    }

    @Test func chunksSplitLargeReads() {
        #expect(DevServerTunnelRules.chunks(Data()).isEmpty)
        let data = Data((0..<10).map { UInt8($0) })
        let parts = DevServerTunnelRules.chunks(data, size: 4)
        #expect(parts.map(\.count) == [4, 4, 2])
        #expect(parts.reduce(Data(), +) == data)
        #expect(parts[1].startIndex == 0)
    }

    @Test func lsofOutputParses() {
        let output = """
        p501
        cnode
        f23
        n*:3000
        f24
        n[::1]:3000
        f25
        n127.0.0.1:9229
        p777
        cPython
        f3
        n[fe80::1%lo0]:8000
        f4
        n127.0.0.1:52000->127.0.0.1:443
        p888
        n*:*
        """
        let listeners = ListeningPorts.parseLsof(output)
        #expect(listeners == [
            .init(pid: 501, port: 3000, command: "node"),
            .init(pid: 501, port: 9229, command: "node"),
            .init(pid: 777, port: 8000, command: "Python"),
        ])
        #expect(ListeningPorts.parseLsof("").isEmpty)
    }

    @Test func listenersBelongToThePaneWhoseShellStartedThem() {
        // 100 → 101 (npm) → 102 (node :3000); 200 → 201 (python :8000); 300 is unrelated (:5432).
        let parents: [Int32: Int32] = [100: 1, 101: 100, 102: 101, 200: 1, 201: 200, 300: 1, 1: 0]
        #expect(ListeningPorts.descendants(of: 100, parents: parents) == [101, 102])
        #expect(ListeningPorts.descendants(of: 102, parents: parents).isEmpty)
        let listeners: [ListeningPorts.Listener] = [
            .init(pid: 102, port: 3000, command: "node"), .init(pid: 102, port: 3000, command: "node"),
            .init(pid: 201, port: 8000, command: "python3"), .init(pid: 300, port: 5432, command: "postgres"),
            .init(pid: 100, port: 7000, command: nil),
        ]
        let ports = ListeningPorts.assign(listeners, shells: ["a": 100, "b": 200], parents: parents)
        #expect(ports == [DevServerPort(port: 3000, paneID: "a", process: "node"), DevServerPort(port: 7000, paneID: "a"),
                          DevServerPort(port: 8000, paneID: "b", process: "python3")])
    }

    @Test func descendantsSurviveParentCycles() {
        #expect(ListeningPorts.descendants(of: 1, parents: [2: 3, 3: 2, 4: 1]) == [4])
    }

    @Test func libprocSeesThisProcesssListeningSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0 && listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let port = UInt16(bigEndian: address.sin_port)
        let mine = ListeningPorts.socketListeners(of: getpid())
        #expect(mine.contains { $0.port == port })
        #expect(ListeningPorts.processParents()[getpid()] == getppid())
    }
}
#endif
