import Foundation

/// Dev server previews load from `xtermx-dev://<port>/<path>`: each request goes to the host as an HTTP/1.1
/// request over its own tunnel stream, so no socket on the device is ever opened for another app to find.
public enum DevServerPreviewURL {
    public static let scheme = "xtermx-dev"

    public static func url(port: UInt16, path: String = "/") -> URL? {
        URL(string: "\(scheme)://\(port)\(path.hasPrefix("/") ? path : "/" + path)")
    }

    /// The host port a preview URL names, or nil when it is not one.
    public static func port(of url: URL) -> UInt16? {
        guard url.scheme?.lowercased() == scheme, let host = url.host, url.port == nil else { return nil }
        return UInt16(host)
    }

    /// The request target sent to the server: path and query, never empty.
    public static func target(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "/" }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return components.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }
}

public enum DevServerHTTP {
    /// Headers the preview sets itself, or that only make sense hop by hop.
    static let ownHeaders: Set<String> = ["host", "connection", "keep-alive", "proxy-connection", "proxy-authorization",
                                          "te", "trailer", "transfer-encoding", "upgrade", "content-length", "accept-encoding"]

    /// An HTTP/1.1 request for a dev server on `port` of the host: one request per stream (`Connection: close`),
    /// uncompressed, with Origin and Referer pointed back at `localhost` as the browser on the host would send them.
    public static func request(method: String, target: String, port: UInt16, headers: [String: String], body: Data?) -> Data {
        func clean(_ value: String) -> String { String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" })) }
        let origin = "http://localhost:\(port)"
        let method = clean(method).filter { !$0.isWhitespace }
        let target = clean(target).filter { !$0.isWhitespace }
        var lines = ["\(method.isEmpty ? "GET" : method) \(target.hasPrefix("/") ? target : "/") HTTP/1.1",
                     "Host: localhost:\(port)", "Connection: close", "Accept-Encoding: identity"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let name = clean(name)
            guard !name.isEmpty, !name.contains(":"), !ownHeaders.contains(name.lowercased()) else { continue }
            var value = clean(value)
            switch name.lowercased() {
            case "origin": value = origin
            case "referer": value = value.replacingOccurrences(of: "\(DevServerPreviewURL.scheme)://\(port)", with: origin)
            default: break
            }
            lines.append("\(name): \(value)")
        }
        if let body, !body.isEmpty || method != "GET" { lines.append("Content-Length: \(body.count)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body { data.append(body) }
        return data
    }

    /// Response headers as the web view should see them: no hop-by-hop framing, and redirects to the
    /// server's own `localhost` address kept inside the preview.
    public static func previewHeaders(_ head: ResponseHead, port: UInt16) -> [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in head.headers {
            let lower = name.lowercased()
            guard !["transfer-encoding", "connection", "keep-alive", "proxy-connection", "upgrade", "trailer"].contains(lower) else { continue }
            if lower == "content-length", head.isChunked { continue }
            var value = value
            if lower == "location" {
                for local in ["http://localhost:\(port)", "http://127.0.0.1:\(port)", "http://[::1]:\(port)"] where value.hasPrefix(local) {
                    value = "\(DevServerPreviewURL.scheme)://\(port)" + value.dropFirst(local.count)
                }
            }
            fields[name] = fields[name].map { "\($0), \(value)" } ?? value
        }
        return fields
    }

    public struct ResponseHead: Equatable, Sendable {
        public var status: Int
        public var headers: [(String, String)]
        public func value(_ name: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }
        var isChunked: Bool { value("Transfer-Encoding")?.lowercased().contains("chunked") ?? false }
        public static func == (a: Self, b: Self) -> Bool { a.status == b.status && a.headers.elementsEqual(b.headers) { $0 == $1 } }
    }

    public enum Event: Equatable, Sendable {
        case head(ResponseHead)
        case body(Data)
        case end
    }

    public struct ParseError: Error, Equatable { public var message: String }

    /// Reads an HTTP/1.1 response as it arrives: the head, then the body framed by Content-Length,
    /// chunked encoding, or the end of the stream.
    public struct ResponseParser {
        public static let maximumHeadBytes = 64 * 1024
        private enum State { case head, fixed(Int), chunkSize, chunkData(Int), chunkDataEnd, trailers, untilClose, done }
        private var state = State.head
        private var buffer = Data()
        private let expectsBody: Bool

        /// `expectsBody` is false for answers to HEAD requests.
        public init(expectsBody: Bool = true) { self.expectsBody = expectsBody }

        public var isDone: Bool { if case .done = state { return true } else { return false } }

        public mutating func feed(_ data: Data) throws -> [Event] {
            buffer.append(data)
            var events: [Event] = []
            while let event = try step() {
                events.append(event)
                if event == .end { break }
            }
            return events
        }

        /// The stream ended: a body read until close ends here; anything else unfinished is an error.
        public mutating func finish() throws -> [Event] {
            switch state {
            case .done: return []
            case .untilClose:
                state = .done
                return [.end]
            default: throw ParseError(message: "The server closed the connection mid-response.")
            }
        }

        private mutating func line() throws -> String? {
            guard let range = buffer.range(of: Data("\r\n".utf8)) else {
                if buffer.count > Self.maximumHeadBytes { throw ParseError(message: "The server sent an oversized header.") }
                return nil
            }
            let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            return line
        }

        private mutating func step() throws -> Event? {
            switch state {
            case .head:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > Self.maximumHeadBytes { throw ParseError(message: "The server sent an oversized header.") }
                    return nil
                }
                let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                var lines = text.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
                guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]), (100...999).contains(status) else {
                    throw ParseError(message: "The server did not answer with HTTP/1.1.")
                }
                let headers: [(String, String)] = lines.compactMap { line in
                    guard let colon = line.firstIndex(of: ":") else { return nil }
                    return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                }
                if (100..<200).contains(status) { return try step() } // 100 Continue and friends: the real answer follows
                let head = ResponseHead(status: status, headers: headers)
                if !expectsBody || status == 204 || status == 304 { state = .done }
                else if head.isChunked { state = .chunkSize }
                else if let length = head.value("Content-Length") {
                    guard let count = Int(length), count >= 0 else { throw ParseError(message: "The server sent a bad Content-Length.") }
                    state = count == 0 ? .done : .fixed(count)
                } else { state = .untilClose }
                return .head(head)
            case .fixed(let remaining):
                guard !buffer.isEmpty else { return nil }
                let take = min(remaining, buffer.count)
                let piece = Data(buffer.prefix(take))
                buffer.removeFirst(take)
                state = remaining == take ? .done : .fixed(remaining - take)
                return .body(piece)
            case .chunkSize:
                guard let line = try line() else { return nil }
                let hex = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let size = Int(hex, radix: 16), size >= 0 else { throw ParseError(message: "The server sent a bad chunk.") }
                state = size == 0 ? .trailers : .chunkData(size)
                return try step()
            case .chunkData(let remaining):
                guard !buffer.isEmpty else { return nil }
                let take = min(remaining, buffer.count)
                let piece = Data(buffer.prefix(take))
                buffer.removeFirst(take)
                state = remaining == take ? .chunkDataEnd : .chunkData(remaining - take)
                return .body(piece)
            case .chunkDataEnd:
                guard let line = try line() else { return nil }
                guard line.isEmpty else { throw ParseError(message: "The server sent a bad chunk.") }
                state = .chunkSize
                return try step()
            case .trailers:
                guard let line = try line() else { return nil }
                if line.isEmpty { state = .done }
                return try step()
            case .untilClose:
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return .body(buffer)
            case .done:
                return .end
            }
        }
    }
}

/// One preview request carried over a tunnel stream: sends the request, parses the answer as it arrives.
@MainActor
public final class DevServerFetch {
    public struct Handlers {
        public var response: @MainActor (DevServerHTTP.ResponseHead) -> Void
        public var data: @MainActor (Data) -> Void
        public var finished: @MainActor (String?) -> Void
        public init(response: @escaping @MainActor (DevServerHTTP.ResponseHead) -> Void, data: @escaping @MainActor (Data) -> Void,
                    finished: @escaping @MainActor (String?) -> Void) {
            self.response = response; self.data = data; self.finished = finished
        }
    }

    private weak var connection: HostConnection?
    private var streamID: UUID?
    private var parser: DevServerHTTP.ResponseParser
    private var handlers: Handlers?

    /// Starts the request; `finished` gets nil after a complete response, or a reason it failed.
    public init(connection: HostConnection, port: UInt16, paneID: String?, method: String, target: String,
                headers: [String: String], body: Data?, handlers: Handlers) {
        self.connection = connection
        self.handlers = handlers
        self.parser = DevServerHTTP.ResponseParser(expectsBody: method.uppercased() != "HEAD")
        let request = DevServerHTTP.request(method: method, target: target, port: port, headers: headers, body: body)
        let events = HostConnection.TunnelEvents(
            opened: { [weak self] in
                guard let self, let id = self.streamID else { return }
                self.connection?.writeTunnel(id, request)
            },
            received: { [weak self] data in self?.receive(data) },
            closed: { [weak self] reason in self?.streamClosed(reason) })
        streamID = connection.openTunnel(port: port, paneID: paneID, events: events)
        if streamID == nil {
            let finished = handlers.finished
            self.handlers = nil
            DispatchQueue.main.async { MainActor.assumeIsolated { finished("The host does not share port \(port).") } }
        }
    }

    /// Stops the request without calling the handlers again.
    public func cancel() {
        handlers = nil
        if let id = streamID { connection?.closeTunnel(id) }
        streamID = nil
    }

    private func receive(_ data: Data) {
        guard handlers != nil else { return }
        do { deliver(try parser.feed(data)) } catch { fail((error as? DevServerHTTP.ParseError)?.message) }
    }

    private func streamClosed(_ reason: String?) {
        streamID = nil
        guard handlers != nil else { return }
        do { deliver(try parser.finish()) } catch { fail(reason ?? (error as? DevServerHTTP.ParseError)?.message) }
    }

    private func deliver(_ events: [DevServerHTTP.Event]) {
        for event in events {
            guard let handlers else { return }
            switch event {
            case .head(let head): handlers.response(head)
            case .body(let data): handlers.data(data)
            case .end:
                self.handlers = nil
                if let id = streamID { connection?.closeTunnel(id) }
                streamID = nil
                handlers.finished(nil)
            }
        }
    }

    private func fail(_ reason: String?) {
        let finished = handlers?.finished
        cancel()
        finished?(reason ?? "The preview stopped.")
    }
}
