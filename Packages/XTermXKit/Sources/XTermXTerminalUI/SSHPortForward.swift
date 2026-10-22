#if os(macOS) || os(iOS)
import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// `ssh -L`: a listener on this machine's loopback whose connections travel to a port on the SSH server's side.
public final class SSHLocalForward: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let localPort: Int
    public let remoteHost: String
    public let remotePort: Int
    private let channel: Channel

    public var localURL: URL? { URL(string: "http://127.0.0.1:\(localPort)/") }
    public var label: String { localPort == remotePort ? ":\(remotePort)" : ":\(localPort) → \(remotePort)" }

    private init(channel: Channel, localPort: Int, remoteHost: String, remotePort: Int) {
        self.channel = channel; self.localPort = localPort; self.remoteHost = remoteHost; self.remotePort = remotePort
    }

    /// Listens on 127.0.0.1 only, at the remote port number if it is free there, otherwise at any free port.
    static func start(client: SSHClient, remoteHost: String = "localhost", remotePort: Int) async throws -> SSHLocalForward {
        func bootstrap() -> ServerBootstrap {
            ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelInitializer { inbound in
                    let promise = inbound.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        let (local, remote) = GlueHandler.matchedPair()
                        let originator = try inbound.remoteAddress ?? SocketAddress(ipAddress: "127.0.0.1", port: 0)
                        let settings = SSHChannelType.DirectTCPIP(targetHost: remoteHost, targetPort: remotePort, originatorAddress: originator)
                        _ = try await client.createDirectTCPIPChannel(using: settings) { $0.pipeline.addHandler(remote) }
                        try await inbound.pipeline.addHandler(local).get()
                        inbound.setOption(ChannelOptions.autoRead, value: true).whenSuccess { inbound.read() }
                    }
                    return promise.futureResult
                }
        }
        let channel: Channel
        do { channel = try await bootstrap().bind(host: "127.0.0.1", port: remotePort).get() }
        catch { channel = try await bootstrap().bind(host: "127.0.0.1", port: 0).get() }
        let port = channel.localAddress?.port ?? remotePort
        return SSHLocalForward(channel: channel, localPort: port, remoteHost: remoteHost, remotePort: remotePort)
    }

    public func stop() { channel.close(promise: nil) }
}

/// Passes bytes between two channels: the local TCP connection and the SSH direct-tcpip channel.
private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler(), second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { self.context = nil; partner = nil }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerClose() { context?.close(promise: nil) }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }
    private func partnerBecameWritable() {
        if pendingRead { pendingRead = false; context?.read() }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerClose() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }
    func read(context: ChannelHandlerContext) {
        if partner?.partnerWritable ?? false { context.read() } else { pendingRead = true }
    }
}

extension SSHSession {
    /// Forwards a port on the server (its `localhost`) to this machine's loopback, like `ssh -L`.
    public func addLocalForward(remotePort: Int) async throws -> SSHLocalForward {
        guard (1...65_535).contains(remotePort) else { throw ForwardFailure("Choose a port from 1 to 65535.") }
        if let existing = forwards.first(where: { $0.remotePort == remotePort }) { return existing }
        guard let client, status == .connected else { throw ForwardFailure("Connect to the server first.") }
        let forward = try await SSHLocalForward.start(client: client, remotePort: remotePort)
        forwards.append(forward)
        return forward
    }

    public func removeLocalForward(_ forward: SSHLocalForward) {
        forward.stop()
        forwards.removeAll { $0.id == forward.id }
    }

    func stopForwards() {
        for forward in forwards { forward.stop() }
        forwards = []
    }

    public struct ForwardFailure: LocalizedError {
        public var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
#endif
