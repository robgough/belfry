import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Invisible drop target layered over the terminal pane. The libghostty
/// surface view never registers for dragged types, so drags route to this
/// overlay instead; mouse events pass straight through (`hitTest` → nil —
/// AppKit resolves drag destinations from registered types, not hitTest).
///
/// Accepts, in order of preference:
/// 1. File URLs (Finder, most apps) — handed over as-is.
/// 2. File promises (Photos, Safari, Mail, the screenshot thumbnail) —
///    received into a temp directory first.
/// 3. Raw image data (image dragged out of a web page) — written to a temp
///    PNG.
struct FileDropCatcher: NSViewRepresentable {
    var isEnabled: Bool
    var onTargeted: (Bool) -> Void
    var onFiles: ([URL]) -> Void

    func makeNSView(context: Context) -> DropCatcherNSView {
        DropCatcherNSView()
    }

    func updateNSView(_ nsView: DropCatcherNSView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onTargeted = onTargeted
        nsView.onFiles = onFiles
    }
}

final class DropCatcherNSView: NSView {
    var isEnabled = false
    var onTargeted: ((Bool) -> Void)?
    var onFiles: (([URL]) -> Void)?

    /// Serial queue file-promise receivers write on (per Apple's sample code).
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, canAccept(sender.draggingPasteboard) else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        guard isEnabled else { return false }
        let pasteboard = sender.draggingPasteboard

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: Self.fileURLReadingOptions
        ) as? [URL], !urls.isEmpty {
            onFiles?(urls)
            return true
        }

        if let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self], options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            receivePromises(receivers)
            return true
        }

        if let url = writeImageDataToTemp(pasteboard) {
            onFiles?([url])
            return true
        }
        return false
    }

    private func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLReadingOptions)
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    // MARK: File promises

    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        let dropDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BelfryDrop-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)

        // One reader callback fires per promised file; fileTypes gives the
        // expected count per receiver. The timeout covers a promiser that
        // never delivers (fires with whatever arrived).
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileTypes.count) }
        let collector = PromiseCollector(expected: expected, timeout: 30) { [weak self] urls in
            guard !urls.isEmpty else { return }
            self?.onFiles?(urls)
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: dropDir, options: [:], operationQueue: promiseQueue
            ) { url, error in
                collector.add(error == nil ? url : nil)
            }
        }
    }

    // MARK: Raw image data

    private func writeImageDataToTemp(_ pasteboard: NSPasteboard) -> URL? {
        let png: Data?
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let tiff = pasteboard.data(forType: .tiff) {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("belfry-image-\(UUID().uuidString.prefix(8)).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// Gathers file-promise results and fires `done` on the main queue exactly
/// once — when all expected files arrived, or at the timeout with whatever did.
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []
    private var fired = false
    private let done: ([URL]) -> Void

    init(expected: Int, timeout: TimeInterval, done: @escaping ([URL]) -> Void) {
        self.remaining = max(1, expected)
        self.done = done
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fire()
        }
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        let complete = remaining <= 0
        lock.unlock()
        if complete { fire() }
    }

    private func fire() {
        lock.lock()
        let shouldFire = !fired
        fired = true
        let collected = urls
        lock.unlock()
        guard shouldFire else { return }
        DispatchQueue.main.async { self.done(collected) }
    }
}
