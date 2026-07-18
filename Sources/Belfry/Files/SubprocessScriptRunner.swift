import Foundation

/// `RemoteScriptRunning` backed by a subprocess with streaming stdio. The ssh
/// form rides the shared ControlMaster socket (exactly like AttachmentStaging's
/// uploads), so each script is a new channel on the existing connection — no
/// re-auth, near-instant startup.
struct SubprocessScriptRunner: RemoteScriptRunning {
    /// argv prefix; the script is appended as the final argument.
    let argv: [String]
    let environment: [String: String]?

    static func ssh(alias: String) -> SubprocessScriptRunner {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in SSHControl.askpassEnvironment() {
            environment[key] = value
        }
        return SubprocessScriptRunner(
            argv: ["/usr/bin/ssh"] + SSHControl.options + [alias],
            environment: environment)
    }

    /// Runs the script against this Mac's own /bin/sh. Exists for the unit
    /// tests, which exercise the shared remote scripts (including the BSD
    /// stat branch) without any ssh in the loop.
    static func localShell() -> SubprocessScriptRunner {
        SubprocessScriptRunner(argv: ["/bin/sh", "-c"], environment: nil)
    }

    func run(script: String) async throws -> any RemoteScriptProcess {
        try SubprocessScriptProcess(argv: argv + [script], environment: environment)
    }
}

/// One running subprocess. Stdout is bridged to an AsyncThrowingStream via the
/// pipe's readabilityHandler; stdin writes block on a private queue, which is
/// the backpressure (a full pipe parks the writer, not the UI).
final class SubprocessScriptProcess: RemoteScriptProcess, @unchecked Sendable {
    let stdout: AsyncThrowingStream<Data, Error>

    private let process: Process
    private let stdinHandle: FileHandle
    private let writeQueue = DispatchQueue(label: "belfry.script.stdin")
    private let stderrBuffer = CappedBuffer(cap: 16 << 10)
    private let exitBox = ExitBox()

    init(argv: [String], environment: [String: String]?) throws {
        // Writing to a pipe whose reader died raises SIGPIPE, which kills the
        // whole app unless ignored; with it ignored, FileHandle surfaces EPIPE
        // as a catchable error instead.
        Self.ignoreSigpipe

        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        if let environment { process.environment = environment }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.stdout = stream
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        let stderrBuffer = self.stderrBuffer
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrBuffer.append(data)
            }
        }
        let exitBox = self.exitBox
        process.terminationHandler = { process in
            exitBox.fulfill(process.terminationReason == .exit ? process.terminationStatus : nil)
        }
        try process.run()
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [stdinHandle] in
                do {
                    try stdinHandle.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func finishInput() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async { [stdinHandle] in
                try? stdinHandle.close()
                continuation.resume()
            }
        }
    }

    func cancel() {
        try? stdinHandle.close()
        if process.isRunning { process.terminate() }
    }

    func exitStatus() async throws -> Int32? {
        await exitBox.value()
    }

    func stderrTail() async -> String {
        String(decoding: stderrBuffer.contents(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One-time, process-wide. See init.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()
}

/// Last-N-bytes accumulator, lock-guarded (appends arrive on pipe queues).
private final class CappedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let cap: Int
    private var data = Data()

    init(cap: Int) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > cap { data = data.suffix(cap) }
    }

    func contents() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// A write-once exit status that any number of tasks can await.
private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Int32??
    private var waiters: [CheckedContinuation<Int32?, Never>] = []

    func fulfill(_ status: Int32?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .some(status)
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: status) }
    }

    func value() async -> Int32? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
