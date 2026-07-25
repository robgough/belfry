import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import NIOTransportServices

// MARK: Belfry patch — local TCP forwards over a live SSH connection.
//
// `openLocalForward(targetHost:targetPort:)` starts a listener on
// 127.0.0.1:<ephemeral> and bridges every accepted connection to a
// `direct-tcpip` child channel on the already-authenticated connection —
// the SSH-native equivalent of `ssh -L`. Belfry uses it to preview
// `localhost:<port>` dev servers from terminal output in a WKWebView:
// requests ride the forward, so WebSockets/HMR work. Additive; nothing
// upstream is touched.

extension TerminiSSHSession {
    /// Open a local forward to `targetHost:targetPort` as seen from the
    /// remote host (usually "127.0.0.1" — the dev server on its loopback).
    /// Returns once the local listener is bound.
    public func openLocalForward(targetHost: String, targetPort: Int) async throws -> TerminiSSHLocalForward {
        guard let connection = currentConnectionChannel(), connection.isActive else {
            throw ExecError.notConnected
        }
        // NIOPosix, not NIOTS, for the loopback listener: Network.framework
        // delivers a phantom EOF (isComplete) after the first read on
        // loopback-accepted connections, which reads as a client half-close
        // and poisons the tunnel. Plain BSD sockets have no such behavior,
        // and a 127.0.0.1-only listener gains nothing from NIOTS anyway.
        let server = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { local in
                local.eventLoop.makeCompletedFuture {
                    try local.pipeline.syncOperations.addHandler(
                        LocalForwardBridgeHandler(
                            connection: connection,
                            targetHost: targetHost,
                            targetPort: targetPort))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = server.localAddress?.port else {
            try? await server.close().get()
            throw ExecError.channelOpenFailed("local listener has no port")
        }
        return TerminiSSHLocalForward(serverChannel: server, localPort: port)
    }
}

/// Handle to a running local forward. Close it when the preview goes away;
/// closing stops the listener and tears down every bridged connection.
public final class TerminiSSHLocalForward: @unchecked Sendable {
    private let serverChannel: Channel
    public let localPort: Int

    fileprivate init(serverChannel: Channel, localPort: Int) {
        self.serverChannel = serverChannel
        self.localPort = localPort
    }

    public func close() {
        serverChannel.close(promise: nil)
    }

    deinit {
        serverChannel.close(promise: nil)
    }
}

// MARK: - Bridge plumbing

/// Sits in each accepted local connection. On activation it opens the
/// direct-tcpip child channel, glues the two pipelines together, then
/// re-enables reads (autoRead was off so no bytes race the SSH side).
private final class LocalForwardBridgeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let connection: Channel
    private let targetHost: String
    private let targetPort: Int

    init(connection: Channel, targetHost: String, targetPort: Int) {
        self.connection = connection
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    func channelActive(context: ChannelHandlerContext) {
        let local = context.channel
        let originator: SocketAddress = local.remoteAddress
            ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let channelType = SSHChannelType.directTCPIP(.init(
            targetHost: targetHost,
            targetPort: targetPort,
            originatorAddress: originator))

        let (localGlue, sshGlue) = GlueHandler.matchedPair()
        let connection = connection

        connection.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            switch result {
            case .failure(let error):
                local.close(promise: nil)
            case .success(let sshHandler):
                let promise = connection.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: channelType) { child, _ in
                    child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandlers([
                                SSHInboundUnwrapper(),
                                SSHOutboundWrapper(),
                                sshGlue,
                            ])
                        }
                    }
                }
                promise.futureResult.whenComplete { result in
                    switch result {
                    case .failure(let error):
                        local.close(promise: nil)
                    case .success:
                        local.pipeline.addHandler(localGlue).whenComplete { added in
                            switch added {
                            case .failure:
                                local.close(promise: nil)
                            case .success:
                                local.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in
                                    local.read()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// SSHChannelData → ByteBuffer for inbound direct-tcpip traffic.
private final class SSHInboundUnwrapper: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data, message.type == .channel else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }
}

/// ByteBuffer → SSHChannelData for outbound direct-tcpip traffic.
private final class SSHOutboundWrapper: ChannelOutboundHandler {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// The classic NIO glue pair: everything read on one side is written to the
/// other (flushed per write), with half-close propagation. Backpressure rides
/// the SSH channel window and TCP; explicit cross-channel read gating was
/// removed because the two channels live on different event loops (local =
/// NIOPosix, ssh = NIOTS) and peeking at the partner's channel state
/// cross-loop trips dispatch queue assertions.
private final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
        partner = nil
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            // Half-close propagates: our read side ended, their write side ends.
            partner?.partnerWriteEOF()
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
        context.close(promise: nil)
    }


    // MARK: Partner-facing (always called on our own event loop context via
    // the partner's context executor)

    private func partnerWrite(_ buffer: ByteBuffer) {
        // Flush per write: channelReadComplete doesn't reliably propagate out
        // of NIOSSH child channels, so batching flushes there leaves the
        // final response bytes parked in the outbound buffer forever.
        run { $0.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil) }
    }

    private func partnerFlush() {
        run { $0.flush() }
    }

    private func partnerWriteEOF() {
        run { $0.close(mode: .output, promise: nil) }
    }

    private func partnerCloseFull() {
        run { $0.close(promise: nil) }
    }

    private func run(_ body: @escaping (ChannelHandlerContext) -> Void) {
        guard let context else { return }
        if context.eventLoop.inEventLoop {
            body(context)
        } else {
            context.eventLoop.execute { body(context) }
        }
    }
}
