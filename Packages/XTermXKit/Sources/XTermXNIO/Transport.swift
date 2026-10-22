import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import XTermXKit

// Networking shared by every XTermX node, macOS and Linux alike: a WebSocket server and
// client carrying binary frames, and a one-request-per-connection HTTP server.

// MARK: - HTTP request

/// Just enough HTTP/1.1 to read one request with a Content-Length body.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init?(_ data: Data) {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = end.upperBound
        guard length >= 0, data.count - bodyStart >= length else { return nil }
        method = String(start[0])
        path = String(start[1].split(separator: "?").first ?? start[1])
        self.headers = headers
        body = Data(data[bodyStart..<(bodyStart + length)])
    }
}

// MARK: - WebSocket connection

/// One WebSocket, server or client side. Every message is one binary frame.
public final class WSConnection: @unchecked Sendable {
    public let id = UUID()
    public let remoteAddress: String
    private let channel: Channel
    private let isClient: Bool
    private let lock = NIOLock()
    private var frameHandler: (@Sendable (Data) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var pending: [Data] = []
    private var closed = false

    init(channel: Channel, isClient: Bool) {
        self.channel = channel
        self.isClient = isClient
        self.remoteAddress = channel.remoteAddress?.ipAddress ?? "?"
    }

    /// Frames that arrived before a handler was set are delivered as soon as it is.
    public func onFrame(_ handler: @escaping @Sendable (Data) -> Void) {
        let queued: [Data] = lock.withLock {
            frameHandler = handler
            defer { pending.removeAll() }
            return pending
        }
        queued.forEach(handler)
    }

    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        let alreadyClosed: Bool = lock.withLock {
            closeHandler = handler
            return closed
        }
        if alreadyClosed { handler() }
    }

    /// `written` runs once the frame has left for the socket, or failed to, so callers can pace what they send.
    public func send(_ data: Data, written: (@Sendable () -> Void)? = nil) {
        let channel = self.channel
        let mask: WebSocketMaskingKey? = isClient ? .random() : nil
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let promise = written.map { written in
                let promise = channel.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { _ in written() }
                return promise
            }
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, maskKey: mask, data: buffer), promise: promise)
        }
    }

    public func close() {
        channel.close(promise: nil)
    }

    fileprivate func deliver(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)? = lock.withLock {
            if frameHandler == nil { pending.append(data) }
            return frameHandler
        }
        handler?(data)
    }

    fileprivate func didClose() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            return closeHandler
        }
        handler?()
    }

    fileprivate var masksFrames: Bool { isClient }
}

/// Turns WebSocket frames into `WSConnection` callbacks and answers pings and closes.
private final class WSFrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let connection: WSConnection
    private var closing = false

    init(connection: WSConnection) {
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text:
            var payload = frame.unmaskedData
            connection.deliver(Data(payload.readBytes(length: payload.readableBytes) ?? []))
        case .ping:
            let mask: WebSocketMaskingKey? = connection.masksFrames ? .random() : nil
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, maskKey: mask, data: frame.unmaskedData)), promise: nil)
        case .connectionClose:
            guard !closing else { context.close(promise: nil); return }
            closing = true
            let mask: WebSocketMaskingKey? = connection.masksFrames ? .random() : nil
            let reply = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: mask, data: context.channel.allocator.buffer(capacity: 0))
            context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in context.close(promise: nil) }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection.didClose()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Plain HTTP on the WebSocket port: anything that is not an upgrade gets a 426.
private final class UpgradeRequiredHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .upgradeRequired, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}

// MARK: - WebSocket server

public final class WSServer: @unchecked Sendable {
    public static let maxFrame = 16 << 20
    private let group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    private var channel: Channel?
    private let onConnect: @Sendable (WSConnection) -> Void

    public init(onConnect: @escaping @Sendable (WSConnection) -> Void) {
        self.onConnect = onConnect
    }

    /// Binds and returns the port (useful with port 0).
    public func start(host: String, port: Int) throws -> Int {
        let onConnect = self.onConnect
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                let fallback = UpgradeRequiredHandler()
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: WSServer.maxFrame,
                    shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                    upgradePipelineHandler: { channel, _ in
                        let connection = WSConnection(channel: channel, isClient: false)
                        return channel.pipeline.addHandlers([
                            NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 1 << 16,
                                                         maxAccumulatedFrameSize: WSServer.maxFrame),
                            WSFrameHandler(connection: connection),
                        ]).map { onConnect(connection) }
                    }
                )
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { context in context.pipeline.removeHandler(fallback, promise: nil) }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
                    channel.pipeline.addHandler(fallback)
                }
            }
        let channel = try bootstrap.bind(host: host, port: port).wait()
        self.channel = channel
        return channel.localAddress?.port ?? port
    }

    public func stop() {
        channel?.close(promise: nil)
        channel = nil
    }
}

// MARK: - WebSocket client

public enum WSClientError: Error, CustomStringConvertible {
    case refused(String)
    case timedOut

    public var description: String {
        switch self {
        case .refused(let why): "The host refused the WebSocket: \(why)"
        case .timedOut: "The host did not answer in time."
        }
    }
}

/// Completes a promise once; later attempts are ignored (NIO promises crash on double completion).
private final class Once<Value>: @unchecked Sendable {
    private let lock = NIOLock()
    private var done = false
    let promise: EventLoopPromise<Value>
    init(_ promise: EventLoopPromise<Value>) { self.promise = promise }
    func succeed(_ v: Value) { if claim() { promise.succeed(v) } }
    func fail(_ e: Error) { if claim() { promise.fail(e) } }
    private func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// Sends the upgrade request and reports any answer that is not a 101.
private final class UpgradeRequester: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    let host: String
    let path: String
    let result: Once<WSConnection>

    init(host: String, path: String, result: Once<WSConnection>) {
        self.host = host
        self.path = path
        self.result = result
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        headers.add(name: "Content-Length", value: "0")
        context.write(wrapOutboundOut(.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: path, headers: headers))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data) {
            result.fail(WSClientError.refused("HTTP \(head.status.code)"))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        result.fail(error)
        context.close(promise: nil)
    }
}

public enum WSClient {
    /// Opens a WebSocket to `ws://host:port/path` and returns it once the upgrade succeeded.
    public static func connect(host: String, port: Int, path: String = "/v1", timeout: TimeAmount = .seconds(10)) async throws -> WSConnection {
        let group = MultiThreadedEventLoopGroup.singleton
        let result = Once<WSConnection>(group.next().makePromise(of: WSConnection.self))
        let hostHeader = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                let requester = UpgradeRequester(host: hostHeader, path: path, result: result)
                let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                let upgrader = NIOWebSocketClientUpgrader(
                    requestKey: key,
                    maxFrameSize: WSServer.maxFrame,
                    upgradePipelineHandler: { channel, _ in
                        let connection = WSConnection(channel: channel, isClient: true)
                        return channel.pipeline.addHandlers([
                            NIOWebSocketFrameAggregator(minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 1 << 16,
                                                         maxAccumulatedFrameSize: WSServer.maxFrame),
                            WSFrameHandler(connection: connection),
                        ]).map { result.succeed(connection) }
                    }
                )
                let config: NIOHTTPClientUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { context in context.pipeline.removeHandler(requester, promise: nil) }
                )
                return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
                    channel.pipeline.addHandler(requester)
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            result.fail(error) // the promise must always complete
            throw error
        }
        channel.eventLoop.scheduleTask(in: timeout) { result.fail(WSClientError.timedOut) }
        channel.closeFuture.whenComplete { _ in result.fail(WSClientError.refused("connection closed")) }
        return try await result.promise.futureResult.get()
    }
}

// MARK: - One-shot HTTP server

/// Reads one HTTP request per connection, answers with the raw response bytes the handler builds, closes.
public final class RawHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> Data
    private let group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    private var channel: Channel?
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start(host: String, port: Int) throws -> Int {
        let handler = self.handler
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(RawHTTPHandler(handler: handler))
            }
        let channel = try bootstrap.bind(host: host, port: port).wait()
        self.channel = channel
        return channel.localAddress?.port ?? port
    }

    public func stop() {
        channel?.close(promise: nil)
        channel = nil
    }
}

private final class RawHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let handler: RawHTTPServer.Handler
    private var buffer = Data()
    private var answered = false
    /// The handler's work; cancelled if the client hangs up first (e.g. an agent killed its hook).
    private var work: Task<Void, Never>?

    init(handler: @escaping RawHTTPServer.Handler) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered else { return }
        var bytes = unwrapInboundIn(data)
        buffer.append(contentsOf: bytes.readBytes(length: bytes.readableBytes) ?? [])
        if buffer.count > 8 << 20 { context.close(promise: nil); return }
        guard let request = HTTPRequest(buffer) else { return }
        answered = true
        let channel = context.channel
        let handler = self.handler
        work = Task {
            let response = await handler(request)
            channel.eventLoop.execute {
                guard channel.isActive else { return }
                var out = channel.allocator.buffer(capacity: response.count)
                out.writeBytes(response)
                channel.writeAndFlush(out).whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        work?.cancel()
        work = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - Client transport for HostConnection

/// `HostConnection`'s transport over a NIO WebSocket (Linux nodes, command-line clients).
public final class NIOFrameTransport: FrameTransport, @unchecked Sendable {
    private let connection: WSConnection
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

    public init(connection: WSConnection) {
        self.connection = connection
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        iterator = stream.makeAsyncIterator()
        connection.onFrame { continuation.yield($0) }
        connection.onClose { continuation.finish(throwing: WSClientError.refused("connection closed")) }
    }

    public func send(_ frame: Data) async throws { connection.send(frame) }

    /// Called from one task at a time (HostConnection's receive loop).
    public func receive() async throws -> Data {
        guard let frame = try await iterator.next() else { throw WSClientError.refused("connection closed") }
        return frame
    }

    public func close() { connection.close() }

    /// A `TransportFactory` that dials `ws://host:port/v1`.
    public static let factory: TransportFactory = { host, port in
        NIOFrameTransport(connection: try await WSClient.connect(host: host, port: Int(port)))
    }
}
