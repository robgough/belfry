import Foundation
#if os(iOS)
import UIKit
#endif

/// One upload or download. Owned by `TransferCenter` (which also retains the
/// running Task), so it survives the file pane closing, selection changes and
/// host reconnects — the UI only ever *observes* a transfer.
@MainActor
@Observable
final class Transfer: Identifiable {
    enum Direction: Sendable { case download, upload }
    enum State: Equatable {
        case queued
        case running
        case finished
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .queued, .running: return false
            case .finished, .failed, .cancelled: return true
            }
        }
    }

    let id = UUID()
    let hostID: String
    let displayName: String
    let direction: Direction
    let remotePath: String
    /// Destination (download) or source (upload) on this device.
    let localURL: URL?
    var totalBytes: Int64?
    /// On failure this is also the resume offset a future retry-with-resume
    /// would pass to `download(offset:)`.
    var bytesTransferred: Int64 = 0
    var state: State = .queued

    /// The actual work, kept so `retry` can re-run it. Not observed.
    @ObservationIgnored fileprivate var work: (@Sendable (Transfer) async throws -> Void)?
    @ObservationIgnored fileprivate var task: Task<Void, Never>?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesTransferred) / Double(totalBytes))
    }

    /// Await a terminal state — for follow-on work like refreshing a listing
    /// after an upload. Poll-based at UI cadence; callers are views.
    func completion() async -> State {
        while !state.isTerminal {
            try? await Task.sleep(for: .milliseconds(120))
        }
        return state
    }

    init(hostID: String, displayName: String, direction: Direction,
         remotePath: String, localURL: URL?) {
        self.hostID = hostID
        self.displayName = displayName
        self.direction = direction
        self.remotePath = remotePath
        self.localURL = localURL
    }
}

/// App-lifetime registry of file transfers (owned by `AppModel`). Starting a
/// transfer here — never in a view — is what makes "tap away and it keeps
/// going" true: the Task belongs to the center, and views merely watch.
@MainActor
@Observable
final class TransferCenter {
    private(set) var transfers: [Transfer] = []

    /// Per host, so one slow box can't starve the others; capped well below
    /// sshd's default MaxSessions and low enough to keep the link responsive.
    private let maxConcurrentPerHost = 3

    var active: [Transfer] { transfers.filter { !$0.state.isTerminal } }
    var hasActive: Bool { transfers.contains { !$0.state.isTerminal } }
    var failedCount: Int {
        transfers.filter { if case .failed = $0.state { return true } else { return false } }.count
    }

    /// Aggregate fraction across non-terminal transfers for the toolbar gauge;
    /// nil (indeterminate) until at least one active transfer knows its total.
    var overallFraction: Double? {
        let sized = active.filter { $0.totalBytes != nil }
        guard !sized.isEmpty else { return nil }
        let total = sized.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        guard total > 0 else { return nil }
        let done = sized.reduce(Int64(0)) { $0 + $1.bytesTransferred }
        return min(1, Double(done) / Double(total))
    }

    // MARK: Starting transfers

    @discardableResult
    func download(entry: FileEntry, hostID: String, browser: any FileBrowsing,
                  to localURL: URL) -> Transfer {
        let transfer = Transfer(hostID: hostID, displayName: entry.name,
                                direction: .download, remotePath: entry.path,
                                localURL: localURL)
        transfer.totalBytes = entry.size > 0 ? entry.size : nil
        transfer.work = { [weak self] transfer in
            // Fresh runs (and v1 retries) start over: a stale .part from a
            // previous attempt must not pollute the byte count.
            try? FileManager.default.removeItem(at: localURL.appendingPathExtension("part"))
            let progress = await self?.progressReporter(for: transfer)
            try await browser.download(entry, to: localURL, offset: 0,
                                       progress: progress ?? { _, _ in })
        }
        enqueue(transfer)
        return transfer
    }

    @discardableResult
    func upload(localURL: URL, hostID: String, browser: any FileBrowsing,
                toDirectory directory: String) -> Transfer {
        let transfer = Transfer(hostID: hostID, displayName: localURL.lastPathComponent,
                                direction: .upload, remotePath: directory,
                                localURL: localURL)
        transfer.totalBytes = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init)
        transfer.work = { [weak self] transfer in
            let progress = await self?.progressReporter(for: transfer)
            _ = try await browser.upload(localURL: localURL, toDirectory: directory,
                                         progress: progress ?? { _, _ in })
        }
        enqueue(transfer)
        return transfer
    }

    func cancel(_ transfer: Transfer) {
        guard !transfer.state.isTerminal else { return }
        if transfer.task == nil {
            transfer.state = .cancelled   // never started; nothing to unwind
            pump()
        } else {
            transfer.task?.cancel()       // the task's catch marks it .cancelled
        }
    }

    /// v1 retry restarts from zero (resume-from-offset is a planned follow-up;
    /// the model already records the offset it would need).
    func retry(_ transfer: Transfer) {
        guard case .failed = transfer.state else { return }
        transfer.bytesTransferred = 0
        transfer.task = nil
        transfer.state = .queued
        pump()
    }

    func clearFinished() {
        transfers.removeAll { $0.state.isTerminal }
        updateBackgroundAssertion()
    }

    // MARK: Scheduling

    private func enqueue(_ transfer: Transfer) {
        transfers.append(transfer)
        pump()
    }

    private func pump() {
        updateBackgroundAssertion()
        var runningPerHost: [String: Int] = [:]
        for transfer in transfers where transfer.state == .running {
            runningPerHost[transfer.hostID, default: 0] += 1
        }
        for transfer in transfers where transfer.state == .queued {
            guard runningPerHost[transfer.hostID, default: 0] < maxConcurrentPerHost else { continue }
            runningPerHost[transfer.hostID, default: 0] += 1
            start(transfer)
        }
    }

    private func start(_ transfer: Transfer) {
        guard let work = transfer.work else {
            transfer.state = .failed("Nothing to run.")
            return
        }
        transfer.state = .running
        transfer.task = Task { [weak self] in
            do {
                try await work(transfer)
                if transfer.state == .running { transfer.state = .finished }
            } catch is CancellationError {
                if transfer.state == .running { transfer.state = .cancelled }
            } catch {
                // A cancelled channel often surfaces as a stream error rather
                // than CancellationError — honour the task's cancellation flag.
                if Task.isCancelled {
                    if transfer.state == .running { transfer.state = .cancelled }
                } else if transfer.state == .running {
                    transfer.state = .failed(error.localizedDescription)
                }
            }
            self?.pump()
        }
    }

    /// Progress callbacks arrive on transfer worker threads per chunk —
    /// hundreds per second. Throttle *before* hopping to the main actor so
    /// observation churn can't jank the terminal.
    private func progressReporter(for transfer: Transfer) -> TransferProgress {
        let throttle = ProgressThrottle()
        return { bytes, total in
            guard throttle.shouldReport(bytes: bytes, total: total) else { return }
            Task { @MainActor in
                transfer.bytesTransferred = bytes
                if let total { transfer.totalBytes = total }
            }
        }
    }

    // MARK: iOS background continuation

    #if os(iOS)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Hold a background-task assertion while anything is in flight, so a
    /// backgrounded app keeps transferring through the system's grace window.
    /// Independent of the connection lifecycle: BackgroundGrace suspends the
    /// tmux control plane, but the file connection is owned by the transport
    /// and keeps running under this assertion.
    private func updateBackgroundAssertion() {
        #if os(iOS)
        if hasActive && backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "belfry.transfers") {
                [weak self] in
                Task { @MainActor in self?.backgroundTimeExpired() }
            }
        } else if !hasActive && backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        #endif
    }

    #if os(iOS)
    private func backgroundTimeExpired() {
        // iOS is about to suspend us mid-stream. Fail (not cancel) so the UI
        // offers Retry, and record stays at the byte offset a future resume
        // could pick up from.
        for transfer in transfers where !transfer.state.isTerminal {
            transfer.state = .failed("Interrupted when the app was suspended.")
            transfer.task?.cancel()
        }
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    #endif
}

/// Lock-guarded throttle deciding which progress callbacks are worth a
/// main-actor hop: every ~100 ms or MiB, plus anything that looks final.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime = ContinuousClock.now
    private var lastBytes: Int64 = -1

    func shouldReport(bytes: Int64, total: Int64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        let isFinal = total != nil && bytes >= total!
        if isFinal || bytes - lastBytes >= 1 << 20 || now - lastTime >= .milliseconds(100) {
            lastTime = now
            lastBytes = bytes
            return true
        }
        return false
    }
}
