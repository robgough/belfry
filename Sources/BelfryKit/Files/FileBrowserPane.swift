import SwiftUI
import QuickLook
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// The right-hand file pane: a listing rooted at the selected window's working
/// directory, on whatever host that window lives on. Browsing follows the
/// window's cwd until the user navigates away; a "return" affordance brings
/// them back. Files preview with Quick Look (space / double-click; remote
/// files fetch to a cache first), download to this device, and drops onto the
/// pane upload into the shown directory — all through `TransferCenter`, so
/// closing the pane never interrupts anything.
struct FileBrowserPane: View {
    let hosts: [HostModel]
    let selection: WindowSelection?
    let transferCenter: TransferCenter

    /// nil = follow the selected window's cwd as it changes.
    @State private var browsedDirectory: String?
    @State private var listing: DirectoryListing?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var selectedID: FileEntry.ID?
    @State private var previewURL: URL?
    @State private var codePreview: PreviewRequest?
    @State private var fetchingPreviewID: FileEntry.ID?
    @State private var isDropTargeted = false
    @State private var gitOverview: GitOverview?
    @State private var paneMode: PaneMode = .files
    @State private var diffLoadingID: String?
    @State private var actionError: String?

    private enum PaneMode { case files, changes }

    private var targetHost: HostModel? {
        hosts.first { $0.id == selection?.hostID }
    }

    private var targetWindow: TmuxWindow? {
        guard let sel = selection, let host = targetHost else { return nil }
        for session in host.store.sessions {
            if let window = session.windows.first(where: { $0.id == sel.windowID }) {
                return window
            }
        }
        return nil
    }

    private var browser: (any FileBrowsing)? {
        targetHost?.transport.makeFileBrowser()
    }

    private var windowPath: String { targetWindow?.currentPath ?? "" }
    private var rootPath: String { browsedDirectory ?? windowPath }
    /// Browsing has left the window's cwd (shows the return affordance).
    private var hasDiverged: Bool {
        browsedDirectory != nil && browsedDirectory != windowPath && !windowPath.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let git = gitOverview { gitBar(git) }
            Divider()
            // Greedy frame on whichever branch renders: empty states
            // (ContentUnavailableView sizes to fit) must still claim the
            // remaining pane height, or the whole VStack — header included —
            // floats to the vertical centre.
            Group {
                if paneMode == .changes, let git = gitOverview {
                    changesList(git)
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .quickLookPreview($previewURL)
        .sheet(item: $codePreview) { request in
            CodePreviewView(request: request)
        }
        .onDrop(of: [.fileURL, .item], isTargeted: $isDropTargeted) { providers in
            acceptDrop(providers)
        }
        .overlay {
            if isDropTargeted { dropHint }
        }
        .overlay(alignment: .bottom) { errorToast }
        // Selecting a different window snaps the pane back to following it.
        .onChange(of: selection) {
            browsedDirectory = nil
            paneMode = .files
        }
        .task(id: "\(selection?.hostID ?? "")|\(rootPath)") {
            await reload()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                navigate(to: parentPath)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(listing == nil || listing?.directory == "/")
            .help("Enclosing folder")

            Text(displayPath)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
                .help(listing?.directory ?? rootPath)

            Spacer(minLength: 4)

            if hasDiverged {
                Button {
                    browsedDirectory = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .help("Back to the window's working directory")
            }

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(browser == nil)
            .help("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var displayPath: String {
        let path = listing?.directory ?? rootPath
        if path.isEmpty { return "—" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var parentPath: String {
        ((listing?.directory ?? rootPath) as NSString).deletingLastPathComponent
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if targetHost == nil || selection == nil {
            ContentUnavailableView(
                "No Session Selected", systemImage: "folder.badge.questionmark",
                description: Text("Select a session to browse its working directory."))
        } else if let loadError {
            ContentUnavailableView {
                Label("Can't Browse Here", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("Retry") { Task { await reload() } }
            }
        } else if let listing {
            if listing.entries.isEmpty {
                ContentUnavailableView(
                    "Empty Folder", systemImage: "folder",
                    description: Text("Drop files here to copy them in."))
            } else {
                entryList(listing)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func entryList(_ listing: DirectoryListing) -> some View {
        List(selection: $selectedID) {
            ForEach(listing.entries) { entry in
                FileEntryRow(entry: entry,
                             isFetchingPreview: fetchingPreviewID == entry.id,
                             gitBadge: gitBadge(for: entry))
                    .tag(entry.id)
            }
        }
        .listStyle(.plain)
        .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
            if let entry = entry(for: ids.first) {
                contextMenu(for: entry)
            }
        } primaryAction: { ids in
            if let entry = entry(for: ids.first) {
                openOrPreview(entry)
            }
        }
        .onKeyPress(.space) {
            if let entry = entry(for: selectedID), !entry.isDirectory {
                preview(entry)
                return .handled
            }
            return .ignored
        }
        .opacity(isLoading ? 0.6 : 1)
    }

    // MARK: Git chrome

    /// Second header row, only inside a repo: Files/Changes switch + branch.
    private func gitBar(_ git: GitOverview) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $paneMode) {
                Text("Files").tag(PaneMode.files)
                Text(git.entries.isEmpty ? "Changes" : "Changes (\(git.entries.count))")
                    .tag(PaneMode.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch")
                Text(git.branch)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if git.ahead > 0 { Text("↑\(git.ahead)") }
                if git.behind > 0 { Text("↓\(git.behind)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .layoutPriority(-1)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func changesList(_ git: GitOverview) -> some View {
        if git.entries.isEmpty {
            ContentUnavailableView(
                "Working Tree Clean", systemImage: "checkmark.seal",
                description: Text("No uncommitted changes on \(git.branch)."))
        } else {
            // Rows are tap targets, not Buttons: plain buttons inside a macOS
            // List only hit-test their drawn content, leaving the row's
            // whitespace dead. contentShape + onTapGesture covers the row.
            List {
                HStack(spacing: 8) {
                    Image(systemName: "plus.forwardslash.minus")
                        .frame(width: 18)
                    Text("All Changes")
                    Spacer()
                    if diffLoadingID == "ALL" { ProgressView().controlSize(.mini) }
                }
                .contentShape(Rectangle())
                .onTapGesture { openDiff(nil, in: git) }
                ForEach(git.entries) { entry in
                    changeRow(entry)
                        .contentShape(Rectangle())
                        .onTapGesture { openDiff(entry, in: git) }
                }
            }
            .listStyle(.plain)
        }
    }

    private func changeRow(_ entry: GitStatusEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.glyph)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Self.badgeColor(for: entry.glyph))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let from = entry.renamedFrom {
                    Text("was \(from)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if diffLoadingID == entry.id {
                ProgressView().controlSize(.mini)
            }
        }
    }

    static func badgeColor(for glyph: String) -> Color {
        switch glyph {
        case "A": .green
        case "?": .green.opacity(0.7)
        case "D", "!": .red
        case "R": .purple
        case "•": .secondary
        default: .orange
        }
    }

    /// Badge for a row in the *files* list: the entry's own status, or a dot
    /// on directories containing changes.
    private func gitBadge(for entry: FileEntry) -> (glyph: String, color: Color)? {
        guard let git = gitOverview, entry.path.hasPrefix(git.root + "/") else { return nil }
        let relative = String(entry.path.dropFirst(git.root.count + 1))
        if entry.isDirectory {
            let prefix = relative + "/"
            guard git.entries.contains(where: { $0.path.hasPrefix(prefix) }) else { return nil }
            return ("•", .secondary)
        }
        // Exact match, or a file inside an untracked directory (porcelain
        // lists only "dir/" for those).
        let status = git.entries.first {
            $0.path == relative || ($0.path.hasSuffix("/") && relative.hasPrefix($0.path))
        }
        guard let status else { return nil }
        return (status.glyph, Self.badgeColor(for: status.glyph))
    }

    private func entry(for id: FileEntry.ID?) -> FileEntry? {
        guard let id else { return nil }
        return listing?.entries.first { $0.id == id }
    }

    @ViewBuilder
    private func contextMenu(for entry: FileEntry) -> some View {
        if entry.isDirectory {
            Button("Open") { navigate(to: entry.path) }
        } else {
            Button("Quick Look") { preview(entry) }
        }
        if let browser, browser.isLocal {
            #if os(macOS)
            Button("Open with Default App") {
                NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
            #endif
        } else if !entry.isDirectory {
            Button(FileDestinations.downloadActionTitle) { download(entry) }
        }
        Divider()
        Button("Copy Path") { copyToPasteboard(entry.path) }
    }

    private var dropHint: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(AppTheme.accent.opacity(0.08))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.accent, lineWidth: 2)
            Label("Copy into \(displayPath)", systemImage: "arrow.down.doc")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(6)
        .allowsHitTesting(false)
    }

    // MARK: Actions

    private func reload() async {
        guard let browser, !rootPath.isEmpty || !(targetHost?.transport.isLocal ?? true) else {
            // Local host with no known cwd: nothing sensible to show.
            listing = nil
            loadError = nil
            gitOverview = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            // Git rides alongside the listing (concurrent; both multiplex on
            // the same connection) and never fails the browse — a host
            // without git just stays a plain file pane.
            async let git = Self.safeGitOverview(browser: browser, directory: rootPath)
            let fresh = try await browser.list(directory: rootPath)
            listing = fresh
            loadError = nil
            gitOverview = await git
            if gitOverview == nil { paneMode = .files }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            listing = nil
            gitOverview = nil
            paneMode = .files
            loadError = error.localizedDescription
        }
    }

    private static func safeGitOverview(browser: any FileBrowsing,
                                        directory: String) async -> GitOverview? {
        (try? await browser.gitOverview(directory: directory)) ?? nil
    }

    private func navigate(to path: String) {
        guard !path.isEmpty else { return }
        browsedDirectory = path
        selectedID = nil
    }

    private func openOrPreview(_ entry: FileEntry) {
        if entry.isDirectory {
            navigate(to: entry.path)
        } else {
            preview(entry)
        }
    }

    /// Preview an entry: text-like files open in the in-app code viewer
    /// (Quick Look shows a bare icon for most source files), everything else
    /// goes to real Quick Look. Remote files fetch to the cache first.
    private func preview(_ entry: FileEntry) {
        guard let browser, let host = targetHost else { return }
        if browser.isLocal {
            presentPreview(of: URL(fileURLWithPath: entry.path), for: entry)
            return
        }
        let cached = FileDestinations.previewCacheURL(hostID: host.id, entry: entry)
        // Reusing the cache is only safe for files git says haven't changed —
        // a modified file's "Latest" must actually be the latest.
        let isModified = gitOverview.flatMap { gitStatus(for: entry, in: $0) }
            .map { !$0.isUntracked } ?? false
        if !isModified, FileManager.default.fileExists(atPath: cached.path) {
            presentPreview(of: cached, for: entry)
            return
        }
        try? FileManager.default.removeItem(at: cached)
        guard fetchingPreviewID != entry.id else { return }
        fetchingPreviewID = entry.id
        let transfer = transferCenter.download(
            entry: entry, hostID: host.id, browser: browser, to: cached)
        Task {
            let state = await transfer.completion()
            if fetchingPreviewID == entry.id { fetchingPreviewID = nil }
            if state == .finished { presentPreview(of: cached, for: entry) }
        }
    }

    private func presentPreview(of localURL: URL, for entry: FileEntry) {
        // HTML renders in WebKit (with a Source toggle); relative assets
        // resolve off disk locally, or on demand over the file connection
        // remotely (see HTMLPreview.swift).
        if ["html", "htm", "xhtml"].contains(localURL.pathExtension.lowercased()),
           let browser, let host = targetHost {
            codePreview = PreviewRequest(
                title: entry.name, subtitle: entry.path,
                source: .file(localURL), language: "xml",
                web: WebPreviewContext(
                    browser: browser, hostID: host.id,
                    remotePath: browser.isLocal ? nil : entry.path,
                    localURL: localURL))
            return
        }
        guard PreviewRouter.wantsCodePreview(url: localURL) else {
            previewURL = localURL
            return
        }
        // A tracked, modified file previews with the Latest/Split/Inline
        // toggle — same viewer the Changes list opens, starting on Latest.
        if let git = gitOverview, let browser,
           let status = gitStatus(for: entry, in: git), !status.isUntracked {
            Task {
                let diff = (try? await browser.gitDiff(root: git.root, path: status.path)) ?? ""
                codePreview = PreviewRequest(
                    title: entry.name, subtitle: entry.path,
                    source: diff.isEmpty ? .file(localURL)
                                         : .gitFile(latest: localURL, diff: diff),
                    language: nil, initialMode: .latest)
            }
            return
        }
        codePreview = PreviewRequest(
            title: entry.name, subtitle: entry.path,
            source: .file(localURL), language: nil)
    }

    private func gitStatus(for entry: FileEntry, in git: GitOverview) -> GitStatusEntry? {
        guard entry.path.hasPrefix(git.root + "/") else { return nil }
        let relative = String(entry.path.dropFirst(git.root.count + 1))
        return git.entries.first { $0.path == relative }
    }

    /// Show the diff for one changed file (nil = the whole repo). Untracked
    /// files have no diff — they preview as plain files instead.
    private func openDiff(_ entry: GitStatusEntry?, in git: GitOverview) {
        guard let browser else { return }
        if let entry, entry.isUntracked {
            preview(FileEntry(
                name: (entry.path as NSString).lastPathComponent,
                path: git.root + "/" + entry.path,
                isDirectory: entry.path.hasSuffix("/"),
                isSymlink: false, size: 0, modified: .now))
            return
        }
        let loadID = entry?.id ?? "ALL"
        guard diffLoadingID != loadID else { return }
        diffLoadingID = loadID
        Task {
            defer { if diffLoadingID == loadID { diffLoadingID = nil } }
            do {
                let diff = try await browser.gitDiff(root: git.root, path: entry?.path)
                let title = entry.map { ($0.path as NSString).lastPathComponent } ?? "All Changes"
                let subtitle = entry?.path ?? git.root
                // Per-file diffs of still-existing files get the full viewer
                // (Latest/Split/Inline); whole-repo and deleted-file diffs
                // are plain inline text.
                if let entry, !diff.isEmpty, !entry.glyph.contains("D"),
                   let latest = await latestLocalURL(for: entry, in: git) {
                    codePreview = PreviewRequest(
                        title: title, subtitle: subtitle,
                        source: .gitFile(latest: latest, diff: diff),
                        language: nil, initialMode: .inline)
                } else {
                    codePreview = PreviewRequest(
                        title: title, subtitle: subtitle,
                        source: .text(diff.isEmpty ? "No difference against HEAD." : diff),
                        language: "diff")
                }
            } catch {
                showActionError(error.localizedDescription)
            }
        }
    }

    /// A readable local copy of a changed file's current content: the path
    /// itself locally, a fresh cache download remotely (fresh because the
    /// file just changed — a stale preview cache would lie about "Latest").
    private func latestLocalURL(for entry: GitStatusEntry, in git: GitOverview) async -> URL? {
        guard let browser, let host = targetHost else { return nil }
        let fullPath = git.root + "/" + entry.path
        if browser.isLocal {
            return FileManager.default.fileExists(atPath: fullPath)
                ? URL(fileURLWithPath: fullPath) : nil
        }
        let fileEntry = FileEntry(
            name: (entry.path as NSString).lastPathComponent, path: fullPath,
            isDirectory: false, isSymlink: false, size: 0, modified: .now)
        let cached = FileDestinations.previewCacheURL(hostID: host.id, entry: fileEntry)
        try? FileManager.default.removeItem(at: cached)
        let transfer = transferCenter.download(
            entry: fileEntry, hostID: host.id, browser: browser, to: cached)
        guard await transfer.completion() == .finished else { return nil }
        return cached
    }

    private func showActionError(_ message: String) {
        actionError = message
        Task {
            try? await Task.sleep(for: .seconds(5))
            if actionError == message { actionError = nil }
        }
    }

    @ViewBuilder
    private var errorToast: some View {
        if let actionError {
            Text(actionError)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 10)
                .onTapGesture { self.actionError = nil }
        }
    }

    private func download(_ entry: FileEntry) {
        guard let browser, let host = targetHost else { return }
        let destination = FileDestinations.uniqueDownloadURL(for: entry.name)
        transferCenter.download(entry: entry, hostID: host.id, browser: browser, to: destination)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let browser, let host = targetHost else { return false }
        let directory = listing?.directory ?? rootPath
        guard !directory.isEmpty else { return false }
        Task {
            for url in await DroppedFiles.stage(providers) {
                let transfer = transferCenter.upload(
                    localURL: url, hostID: host.id, browser: browser, toDirectory: directory)
                Task {
                    if await transfer.completion() == .finished { await reload() }
                }
            }
        }
        return true
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Row

private struct FileEntryRow: View {
    let entry: FileEntry
    let isFetchingPreview: Bool
    var gitBadge: (glyph: String, color: Color)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? AppTheme.accent : Color.secondary)
                .frame(width: 18)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.isSymlink {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let gitBadge {
                Text(gitBadge.glyph)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(gitBadge.color)
            }
            Spacer(minLength: 6)
            if isFetchingPreview {
                ProgressView().controlSize(.mini)
            } else if !entry.isDirectory {
                Text(entry.size, format: .byteCount(style: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .help("\(entry.name)\n\(entry.modified.formatted(date: .abbreviated, time: .shortened))")
    }
}

// MARK: - Destinations

/// Where fetched files land on this device, per platform.
enum FileDestinations {
    #if os(macOS)
    static let downloadActionTitle = "Download to Downloads"
    #else
    static let downloadActionTitle = "Save to On My iPad"
    #endif

    private static var downloadsDirectory: URL {
        #if os(macOS)
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        #else
        // The app's Documents folder — surfaced in the Files app via the
        // file-sharing Info.plist keys.
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        #endif
    }

    /// "name.ext", then "name 2.ext", "name 3.ext"… like every browser.
    static func uniqueDownloadURL(for name: String) -> URL {
        let directory = downloadsDirectory
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    /// Cache slot for a remote file being Quick Looked. Keyed by host + full
    /// remote path so same-named files on different hosts/directories don't
    /// collide; keeps the original name so Quick Look shows something sane.
    static func previewCacheURL(hostID: String, entry: FileEntry) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("belfry-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reapOldPreviews(in: directory)
        var hasher = Hasher()
        hasher.combine(hostID)
        hasher.combine(entry.path)
        let slot = String(UInt(bitPattern: hasher.finalize()), radix: 36)
        return directory.appendingPathComponent("\(slot)-\(entry.name)")
    }

    /// Previews are disposable; clear anything a week old, once per launch.
    private static let reapOnce: Void = ()
    private static var didReap = false
    private static func reapOldPreviews(in directory: URL) {
        guard !didReap else { return }
        didReap = true
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}

// MARK: - Drops

/// Turn dropped item providers into local file URLs we can read at leisure.
/// Providers' own URLs (and iOS file representations) die when their callback
/// returns, so everything is staged into our tmp first when needed.
enum DroppedFiles {
    static func stage(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            #if os(macOS)
            // Finder drags hand over a directly-readable file URL.
            if let url = await loadFileURL(provider) {
                urls.append(url)
                continue
            }
            #endif
            if let staged = await stageRepresentation(provider) {
                urls.append(staged)
            }
        }
        return urls
    }

    #if os(macOS)
    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
    #endif

    /// Files-app (iOS) and promise-style drops: materialise to a temp file and
    /// copy it out before the provider reclaims it.
    private static func stageRepresentation(_ provider: NSItemProvider) async -> URL? {
        let identifier = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("belfry-drop-\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: staging, withIntermediateDirectories: true)
                    let copy = staging.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
