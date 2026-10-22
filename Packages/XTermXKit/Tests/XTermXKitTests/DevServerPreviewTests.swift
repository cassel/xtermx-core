#if os(macOS)
import Foundation
import Testing
@testable import XTermXKit
import XTermXNIO

@Suite struct DevServerPreviewTests {
    @Test func previewURLsNameAPortAndKeepPathAndQuery() throws {
        let url = try #require(DevServerPreviewURL.url(port: 5173, path: "/src/main.ts"))
        #expect(url.absoluteString == "xtermx-dev://5173/src/main.ts")
        #expect(DevServerPreviewURL.port(of: url) == 5173)
        #expect(DevServerPreviewURL.target(of: URL(string: "xtermx-dev://5173/a%20b?x=1&y=2")!) == "/a%20b?x=1&y=2")
        #expect(DevServerPreviewURL.target(of: URL(string: "xtermx-dev://5173")!) == "/")
        #expect(DevServerPreviewURL.port(of: URL(string: "http://5173/")!) == nil)
        #expect(DevServerPreviewURL.port(of: URL(string: "xtermx-dev://localhost:5173/")!) == nil)
    }

    @Test func requestsAreOneShotUncompressedAndCannotSmuggleHeaders() {
        let data = DevServerHTTP.request(method: "POST", target: "/api?q=1", port: 3000,
                                         headers: ["Host": "evil", "Connection": "keep-alive", "Accept-Encoding": "gzip",
                                                   "X-Test": "a\r\nInjected: yes", "Origin": "xtermx-dev://3000",
                                                   "Referer": "xtermx-dev://3000/page", "Bad:Name": "x"],
                                         body: Data("hi".utf8))
        let text = String(decoding: data, as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        #expect(head[0] == "POST /api?q=1 HTTP/1.1")
        #expect(head.contains("Host: localhost:3000") && !head.contains("Host: evil"))
        #expect(head.contains("Connection: close") && head.contains("Accept-Encoding: identity"))
        #expect(head.contains("X-Test: aInjected: yes") && !head.contains { $0.hasPrefix("Injected") })
        #expect(head.contains("Origin: http://localhost:3000") && head.contains("Referer: http://localhost:3000/page"))
        #expect(head.contains("Content-Length: 2") && !text.contains("Bad:Name"))
        #expect(text.hasSuffix("\r\n\r\nhi"))
    }

    @Test func allowsMatchesThePaneWhenNamed() {
        let shared = [DevServerPort(port: 3000, paneID: "a")]
        #expect(DevServerTunnelRules.allows(port: 3000, paneID: nil, in: shared))
        #expect(DevServerTunnelRules.allows(port: 3000, paneID: "a", in: shared))
        #expect(!DevServerTunnelRules.allows(port: 3000, paneID: "b", in: shared))
        #expect(!DevServerTunnelRules.allows(port: 3001, paneID: nil, in: shared))
    }

    /// Feeds `response` one byte at a time, as the slowest network would.
    func parse(_ response: String, expectsBody: Bool = true, close: Bool = false) throws -> (DevServerHTTP.ResponseHead?, Data, Bool) {
        var parser = DevServerHTTP.ResponseParser(expectsBody: expectsBody)
        var head: DevServerHTTP.ResponseHead?, body = Data(), ended = false
        func take(_ events: [DevServerHTTP.Event]) {
            for event in events {
                switch event {
                case .head(let h): head = h
                case .body(let d): body.append(d)
                case .end: ended = true
                }
            }
        }
        for byte in Data(response.utf8) where !ended { take(try parser.feed(Data([byte]))) }
        if close { take(try parser.finish()) }
        return (head, body, ended)
    }

    @Test func parsesContentLengthChunkedAndCloseDelimitedBodies() throws {
        let fixed = try parse("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhello")
        #expect(fixed.0?.status == 200 && fixed.0?.value("content-type") == "text/html")
        #expect(String(decoding: fixed.1, as: UTF8.self) == "hello" && fixed.2)

        let chunked = try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: 1\r\n\r\n")
        #expect(String(decoding: chunked.1, as: UTF8.self) == "Wikipedia" && chunked.2)

        let untilClose = try parse("HTTP/1.0 200 OK\r\n\r\nstreamed", close: true)
        #expect(String(decoding: untilClose.1, as: UTF8.self) == "streamed" && untilClose.2)

        let continued = try parse("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n")
        #expect(continued.0?.status == 201 && continued.1.isEmpty && continued.2)

        let head = try parse("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n", expectsBody: false)
        #expect(head.0?.status == 200 && head.2)
        #expect(try parse("HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n").2)
    }

    @Test func rejectsBrokenResponses() {
        #expect(throws: DevServerHTTP.ParseError.self) { try parse("SSH-2.0-OpenSSH\r\n\r\n") }
        #expect(throws: DevServerHTTP.ParseError.self) { try parse("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort", close: true) }
        #expect(throws: DevServerHTTP.ParseError.self) { try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n") }
        var parser = DevServerHTTP.ResponseParser()
        #expect(throws: DevServerHTTP.ParseError.self) {
            _ = try parser.feed(Data(repeating: 65, count: DevServerHTTP.ResponseParser.maximumHeadBytes + 1))
        }
    }

    @Test func previewHeadersDropFramingAndKeepRedirectsInside() {
        let head = DevServerHTTP.ResponseHead(status: 302, headers: [("Location", "http://localhost:3000/login?next=/"),
                                                                     ("Transfer-Encoding", "chunked"), ("Content-Length", "9"),
                                                                     ("Connection", "close"), ("Set-Cookie", "a=1"), ("Set-Cookie", "b=2")])
        let fields = DevServerHTTP.previewHeaders(head, port: 3000)
        #expect(fields["Location"] == "xtermx-dev://3000/login?next=/")
        #expect(fields["Transfer-Encoding"] == nil && fields["Content-Length"] == nil && fields["Connection"] == nil)
        #expect(fields["Set-Cookie"] == "a=1, b=2")
        let other = DevServerHTTP.previewHeaders(.init(status: 302, headers: [("Location", "https://example.com/")]), port: 3000)
        #expect(other["Location"] == "https://example.com/")
    }
}

/// The host's side of a tunnel: it reads a dev server only as fast as the device takes the bytes.
@Suite(.serialized) struct TCPStreamFlowTests {
    final class Received: @unchecked Sendable {
        let lock = NSLock()
        var chunks = 0, bytes = 0, closed = false
        func add(_ data: Data) { lock.lock(); chunks += 1; bytes += data.count; lock.unlock() }
        var snapshot: (Int, Int, Bool) { lock.lock(); defer { lock.unlock() }; return (chunks, bytes, closed) }
    }

    func waitUntil(_ timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func readsOneChunkAtATimeUntilAskedForMore() async throws {
        let size = 2 << 20
        let server = RawHTTPServer { _ in
            Data("HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\n\r\n".utf8) + Data(repeating: 7, count: size)
        }
        let port = try server.start(host: "127.0.0.1", port: 0)
        defer { server.stop() }
        let stream = try await TCPStream.connect(host: "127.0.0.1", port: port)
        let received = Received()
        stream.onClose { received.lock.lock(); received.closed = true; received.lock.unlock() }
        stream.onData { received.add($0) }
        #expect(stream.write(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)))
        #expect(await waitUntil { received.snapshot.0 >= 1 }, "\(received.snapshot)")
        try await Task.sleep(for: .milliseconds(300))
        #expect(received.snapshot.0 == 1) // nothing more until the consumer asks
        #expect(received.snapshot.1 < size)
        // Ask for the rest one chunk at a time.
        #expect(await waitUntil(20) {
            stream.readNext()
            return received.snapshot.2
        })
        #expect(received.snapshot.1 > size)
    }

    @Test func closesWhenTooManyBytesWaitToBeWritten() async throws {
        let server = RawHTTPServer { _ in Data() }
        let port = try server.start(host: "127.0.0.1", port: 0)
        defer { server.stop() }
        let stream = try await TCPStream.connect(host: "127.0.0.1", port: port, maximumPendingBytes: 1024)
        let received = Received()
        stream.onClose { received.lock.lock(); received.closed = true; received.lock.unlock() }
        #expect(!stream.write(Data(repeating: 1, count: 2048)))
        #expect(await waitUntil { received.snapshot.2 })
    }
}
#endif
