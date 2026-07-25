import Foundation
import Termini
import TerminiSSH

/// `RemoteScriptRunning` over a dedicated NIOSSH connection: one per host,
/// connected lazily on first use, every script an exec child channel (see the
/// Termini exec patch). Deliberately *not* the control channel's session —
/// that one is one-shot and torn down by background suspension, and transfers
/// must outlive both.
@MainActor
final class SSHFileSession: RemoteScriptRunning {
    private let makeConfiguration: @MainActor () -> TerminiSSHConfiguration
    private var session: TerminiSSHSession?

    init(makeConfiguration: @escaping @MainActor () -> TerminiSSHConfiguration) {
        self.makeConfiguration = makeConfiguration
    }

    func run(script: String) async throws -> any RemoteScriptProcess {
        do {
            return ExecScriptProcess(process: try await connectedSession().exec(script))
        } catch {
            // The idle connection can die quietly (network hop, remote
            // timeout); rebuild once and retry — exec fails before any bytes
            // flow, so the retry can't double-run anything.
            session = nil
            return ExecScriptProcess(process: try await connectedSession().exec(script))
        }
    }

    /// SSH local forward on this host connection (long-press localhost
    /// previews). Rides the same lazily-connected session as file transfers,
    /// so an open preview keeps working while the tmux plane reconnects.
    func openLocalForward(targetHost: String, targetPort: Int) async throws -> TerminiSSHLocalForward {
        do {
            return try await connectedSession().openLocalForward(
                targetHost: targetHost, targetPort: targetPort)
        } catch {
            // Same quiet-death retry as `run(script:)`.
            session = nil
            return try await connectedSession().openLocalForward(
                targetHost: targetHost, targetPort: targetPort)
        }
    }

    func shutdown() {
        let session = session
        self.session = nil
        Task { await session?.disconnect() }
    }

    private func connectedSession() async throws -> TerminiSSHSession {
        if let session, session.status == .connected { return session }
        // The controller is a required-but-unused mailbox (same pattern as
        // SSHControlChannel); connection-only mode never renders anything.
        let fresh = TerminiSSHSession(controller: TerminiTerminalController())
        await fresh.connect(configuration: makeConfiguration())
        guard fresh.status == .connected else {
            let reason: String
            if case .failed(let message) = fresh.status {
                reason = message
            } else {
                reason = "Couldn't connect to the host."
            }
            throw FileBrowsingError.remoteFailed(status: nil, detail: reason)
        }
        session = fresh
        return fresh
    }
}

/// Bridges `TerminiSSHExecProcess` onto the shared `RemoteScriptProcess` seam.
private struct ExecScriptProcess: RemoteScriptProcess {
    let process: TerminiSSHExecProcess

    var stdout: AsyncThrowingStream<Data, Error> { process.stdout }
    func write(_ data: Data) async throws { try await process.write(data) }
    func finishInput() async throws { try await process.finishInput() }
    func cancel() { process.cancel() }
    func exitStatus() async throws -> Int32? { try await process.exitStatus() }
    func stderrTail() async -> String {
        String(decoding: process.stderrTail(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
