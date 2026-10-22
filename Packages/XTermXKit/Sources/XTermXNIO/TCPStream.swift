import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// A plain TCP connection carrying bytes both ways, used to tunnel a device's request to a local dev server.
///
/// Reads are pulled, not pushed: after a chunk is delivered nothing more is read until `readNext()`,
/// so a slow consumer slows the server instead of piling bytes up in memory. Writes that the socket
/// cannot take yet wait in a queue; once more than `maximumPendingBytes` wait, the stream closes.
public final class TCPStream: @unchecked Sendable {
    /// Bytes that may wait to be written before the stream gives up.
    public static let defaultMaximumPendingBytes = 4 << 20

    private let channel: Channel
    private let maximumPendingBytes: Int
    private let lock = NIOLock()
    private var dataHandler: (@Sendable (Data) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var pending: [Data] = []
    private var closed = false
    private var queuedBytes = 0
    // Event-loop only.
    private var writeQueue: [ByteBuffer] = []

    fileprivate init(channel: Channel, maximumPendingBytes: Int) {
        self.channel = channel
        self.maximumPendingBytes = maximumPendingBytes
    }

    /// Connects to `host:port`; "localhost" tries IPv4 and IPv6, so a server bound only to `::1` is reached too.
    public static func connect(host: String = "localhost", port: Int, timeout: TimeAmount = .seconds(5),
                               maximumPendingBytes: Int = defaultMaximumPendingBytes) async throws -> TCPStream {
        let box = NIOLockedValueBox<TCPStream?>(nil)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .channelInitializer { channel in
                let stream = TCPStream(channel: channel, maximumPendingBytes: maximumPendingBytes)
                box.withLockedValue { $0 = stream }
                return channel.pipeline.addHandler(StreamHandler(stream: stream))
            }
            .connect(host: host, port: port).get()
        guard let stream = box.withLockedValue({ $0 }) else { channel.close(promise: nil); throw ChannelError.ioOnClosedChannel }
        return stream
    }

    /// Sets the handler and reads the first chunk; bytes read before a handler was set are delivered as soon as it is.
    public func onData(_ handler: @escaping @Sendable (Data) -> Void) {
        let queued: [Data] = lock.withLock {
            dataHandler = handler
            defer { pending.removeAll() }
            return pending
        }
        queued.forEach(handler)
        if queued.isEmpty { readNext() }
    }

    /// Asks for the next chunk; call it once the previous one has been passed on.
    public func readNext() { channel.read() }

    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        let alreadyClosed: Bool = lock.withLock {
            closeHandler = handler
            return closed
        }
        if alreadyClosed { handler() }
    }

    /// Bytes accepted by `write` that the socket has not taken yet.
    public var pendingWriteBytes: Int { lock.withLock { queuedBytes } }

    /// Queues `data`; returns false (and closes) when that would leave more than the limit waiting.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        let accepted: Bool = lock.withLock {
            guard !closed, queuedBytes + data.count <= maximumPendingBytes else { return false }
            queuedBytes += data.count
            return true
        }
        guard accepted else { close(); return false }
        let channel = self.channel
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            self.writeQueue.append(buffer)
            self.drain()
        }
        return true
    }

    public func close() { channel.close(promise: nil) }

    /// Writes queued buffers while the socket is writable; the rest wait for `channelWritabilityChanged`.
    fileprivate func drain() {
        var wrote = false
        while channel.isWritable, !writeQueue.isEmpty {
            let buffer = writeQueue.removeFirst()
            let count = buffer.readableBytes
            let promise = channel.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { [weak self] _ in self?.lock.withLock { self?.queuedBytes -= count } }
            channel.write(buffer, promise: promise)
            wrote = true
        }
        if wrote { channel.flush() }
    }

    fileprivate func deliver(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)? = lock.withLock {
            if dataHandler == nil { pending.append(data) }
            return dataHandler
        }
        handler?(data)
    }

    fileprivate func didClose() {
        writeQueue.removeAll()
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            return closeHandler
        }
        handler?()
    }
}

private final class StreamHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let stream: TCPStream
    init(stream: TCPStream) { self.stream = stream }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty { stream.deliver(Data(bytes)) }
        else { context.read() } // nothing to pass on, so nothing will ask for more
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        stream.drain()
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        stream.didClose()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
