import Foundation
import NIOCore
@preconcurrency import NIOSSH

// MARK: Sessionator patch — additional exec channels on a live SSH connection.
//
// Upstream `TerminiSSHSession` opens exactly one session channel (the shell /
// tmux exec). SSH multiplexes arbitrarily many session channels over one
// authenticated connection, and Belfry's file browsing needs exactly that:
// run `ls`/`cat` style scripts next to the long-lived channel without a second
// TCP connect or re-auth. This file adds `exec(_:)` — a no-PTY exec request on
// a fresh child channel — plus the streaming process handle it returns.
// Everything here is additive; existing call sites are untouched.

extension TerminiSSHSession {
    public enum ExecError: LocalizedError {
        case notConnected
        case channelOpenFailed(String)
        case connectionLost

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to the SSH host."
            case .channelOpenFailed(let detail): return "Couldn't start the remote command: \(detail)"
            case .connectionLost: return "The SSH connection was lost."
            }
        }
    }

    /// Run `command` as an exec request on a new child channel of the current
    /// connection (no PTY — clean byte streams and a real exit status).
    /// Returns once the remote has accepted the exec request.
    public func exec(_ command: String) async throws -> TerminiSSHExecProcess {
        guard let connectionChannel = currentConnectionChannel(), connectionChannel.isActive else {
            throw ExecError.notConnected
        }
        let state = ExecSharedState()
        let channel = try await connectionChannel.pipeline
            .handler(type: NIOSSHHandler.self)
            .flatMap { sshHandler in
                let promise = connectionChannel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise) { childChannel, channelType in
                    guard channelType == .session else {
                        return connectionChannel.eventLoop.makeFailedFuture(
                            ExecError.channelOpenFailed("unexpected channel type"))
                    }
                    return childChannel.pipeline.addHandler(
                        ExecChannelHandler(command: command, state: state))
                }
                return promise.futureResult
            }
            .get()
        try await state.waitUntilStarted()
        return TerminiSSHExecProcess(channel: channel, state: state)
    }
}

/// Handle for one running exec channel. Usable from any thread/actor: channel
/// operations hop to the event loop themselves, and shared state is
/// lock-guarded.
public final class TerminiSSHExecProcess: @unchecked Sendable {
    private let channel: Channel
    private let state: ExecSharedState

    fileprivate init(channel: Channel, state: ExecSharedState) {
        self.channel = channel
        self.state = state
    }

    /// Stdout bytes as they arrive. Single-consumer; finishes at remote EOF,
    /// throws `ExecError.connectionLost` if the connection dies first.
    public var stdout: AsyncThrowingStream<Data, Error> { state.stdoutStream }

    /// Streaming stdin. Awaits the flush — this is the backpressure; feed
    /// 64–256 KiB chunks.
    public func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    /// Half-close stdin (SSH channel EOF) so a remote `cat > file` completes.
    public func finishInput() async throws {
        try await channel.close(mode: .output).get()
    }

    /// Hard-stop the channel. Idempotent.
    public func cancel() {
        channel.close(mode: .all, promise: nil)
    }

    /// Wait for the command to finish. nil when the remote reported a signal
    /// (or closed without a status); throws if the connection died mid-run.
    public func exitStatus() async throws -> Int32? {
        try await state.waitForExit()
    }

    /// Trailing stderr (capped) for diagnostics; meaningful after exit.
    public func stderrTail() -> Data {
        state.stderrTail()
    }
}

// MARK: - Channel handler (no PTY)

/// Sibling of the upstream `ChannelHandler`, minus the PTY request: exec
/// straight away, split stdout/stderr, surface exit status and EOF. All
/// callbacks run on the event loop and only touch the lock-guarded state.
private final class ExecChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let state: ExecSharedState

    init(command: String, state: ExecSharedState) {
        self.command = command
        self.state = state
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Required in both directions: the remote half-closes after exit, and
        // our own `.output` close (stdin EOF) must not tear the channel down.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { [state] error in state.fail(error) }
    }

    func channelActive(context: ChannelHandlerContext) {
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenSuccess { [state] in state.markStarted() }
        promise.futureResult.whenFailure { [state] error in
            state.fail(TerminiSSHSession.ExecError.channelOpenFailed(String(describing: error)))
        }
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
            promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else { return }
        let payload = Data(bytes.readableBytesView)
        guard !payload.isEmpty else { return }
        switch message.type {
        case .channel: state.yieldStdout(payload)
        case .stdErr: state.appendStderr(payload)
        default: break
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))),
                      promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exit as SSHChannelRequestEvent.ExitStatus:
            state.recordExit(Int32(exit.exitStatus))
        case is SSHChannelRequestEvent.ExitSignal:
            state.recordExit(nil)
        case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
            state.remoteClosedInput()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.channelClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state.fail(error)
        context.close(promise: nil)
    }
}

// MARK: - Shared state

/// Lock-guarded rendezvous between the event-loop handler and the async
/// consumer: start signal, stdout stream, stderr tail, exit status.
private final class ExecSharedState: @unchecked Sendable {
    private let lock = NSLock()

    let stdoutStream: AsyncThrowingStream<Data, Error>
    private let stdoutContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private var started = false
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private var exitStatus: Int32??          // outer nil = still running
    private var exitWaiters: [CheckedContinuation<Int32?, Error>] = []
    private var stdoutFinished = false
    private var stderr = Data()
    private let stderrCap = 16 << 10

    init() {
        (stdoutStream, stdoutContinuation) = AsyncThrowingStream.makeStream()
    }

    // Consumer side

    func waitUntilStarted() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
            } else if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiter = continuation
                lock.unlock()
            }
        }
    }

    func waitForExit() async throws -> Int32? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32?, Error>) in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func stderrTail() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stderr
    }

    // Handler side (event loop)

    func markStarted() {
        lock.lock()
        started = true
        let waiter = startWaiter
        startWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func yieldStdout(_ data: Data) {
        stdoutContinuation.yield(data)
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderr.append(data)
        if stderr.count > stderrCap { stderr = stderr.suffix(stderrCap) }
        lock.unlock()
    }

    func recordExit(_ status: Int32?) {
        lock.lock()
        guard exitStatus == nil else { lock.unlock(); return }
        exitStatus = .some(status)
        let waiters = exitWaiters
        exitWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume(returning: status) }
    }

    func remoteClosedInput() {
        finishStdout()
    }

    /// Channel fully closed. With an exit status recorded this is the normal
    /// end; without one the connection died under us.
    func channelClosed() {
        lock.lock()
        let sawExit = exitStatus != nil
        lock.unlock()
        if sawExit {
            finishStdout()
            // exit waiters already resolved by recordExit
        } else {
            fail(TerminiSSHSession.ExecError.connectionLost)
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        let start = startWaiter
        startWaiter = nil
        let waiters = exitWaiters
        exitWaiters = []
        let effective = failure!
        lock.unlock()
        start?.resume(throwing: effective)
        waiters.forEach { $0.resume(throwing: effective) }
        stdoutContinuation.finish(throwing: effective)
    }

    private func finishStdout() {
        lock.lock()
        let alreadyDone = stdoutFinished
        stdoutFinished = true
        lock.unlock()
        if !alreadyDone { stdoutContinuation.finish() }
    }
}
