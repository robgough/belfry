import SwiftUI
import Highlightr

/// Belfry's own quick-look for code: Quick Look renders images and PDFs
/// beautifully but shows a bare icon for most source files, so text-like
/// files route here instead — syntax-highlighted, line-numbered, in the
/// terminal's palette. Git diffs share the same viewer ("diff" is just
/// another language to the highlighter).

/// How a git-modified file is being looked at.
enum DiffPreviewMode: String, CaseIterable, Identifiable {
    case latest = "Latest"
    case split = "Split"
    case inline = "Inline"
    var id: String { rawValue }
}

/// What the pane wants previewed.
struct PreviewRequest: Identifiable {
    enum Source {
        /// A local file (downloaded to cache first when remote).
        case file(URL)
        /// Text already in hand (whole-repo diffs, error text).
        case text(String)
        /// A tracked, modified file: current content + its diff vs HEAD —
        /// the viewer offers the Latest/Split/Inline toggle.
        case gitFile(latest: URL, diff: String)
    }

    let id = UUID()
    let title: String
    let subtitle: String?
    let source: Source
    /// highlight.js language name; nil = detect from title's extension,
    /// falling back to plain text.
    let language: String?
    /// Starting mode for `.gitFile` sources: Changes-list taps open on the
    /// diff, Files-list previews open on the file itself.
    var initialMode: DiffPreviewMode = .inline
    /// Set for HTML files: the viewer gains a Rendered/Source toggle and
    /// renders through WebKit (see HTMLPreview.swift).
    var web: WebPreviewContext?
}

enum PreviewRouter {
    /// Extensions Quick Look genuinely handles well — never intercepted.
    private static let quickLookNative: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp",
        "ico", "icns", "svg", "pdf", "mp4", "mov", "m4v", "avi", "mkv",
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff",
        "key", "pages", "numbers", "docx", "xlsx", "pptx", "rtf",
    ]

    /// Known-binary formats with no useful text rendering; QL at least shows
    /// an icon and metadata.
    private static let knownBinary: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "dmg", "iso",
        "sqlite", "sqlite3", "db", "bin", "exe", "dylib", "so", "o", "a",
        "class", "jar", "war", "beam", "pyc", "wasm",
        "woff", "woff2", "ttf", "otf", "eot",
    ]

    /// Should this file open in the code viewer (true) or Quick Look (false)?
    static func wantsCodePreview(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if quickLookNative.contains(ext) || knownBinary.contains(ext) { return false }
        if HighlightEngine.language(forExtension: ext) != nil { return true }
        // Unknown extension: sniff. NUL bytes in the head mean binary.
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 8192)
        else { return false }
        try? handle.close()
        if head.isEmpty { return true }   // empty file: harmless as text
        return !head.contains(0)
    }
}

// MARK: - Highlighting

#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformFont = UIFont
#endif

/// Serialises Highlightr (JavaScriptCore-backed, not thread-safe) off the
/// main actor and owns the extension → highlight.js language map.
actor HighlightEngine {
    static let shared = HighlightEngine()

    struct Rendered {
        let lines: [AttributedString]
        /// Content itself was cut (the hard cap) — the banner case.
        let truncated: Bool
        /// Line index where syntax colouring stopped (highlighting has a
        /// budget; the content doesn't). nil = fully highlighted.
        let highlightCutoff: Int?
        let background: Color
    }

    /// The *content* caps — generous, they only guard against accidentally
    /// previewing something enormous. Scrolling is lazy; big is fine.
    private static let maxBytes = 10 << 20
    private static let maxLines = 50_000
    /// The *highlighting* budget: highlight.js parses eagerly through
    /// JavaScriptCore, so colouring stops here and the rest renders plain.
    private static let highlightMaxBytes = 1 << 20
    private static let highlightMaxLines = 5000
    /// Auto-detection runs the code through every grammar — only worth it
    /// for small files.
    private static let maxAutoDetectBytes = 64 << 10

    private var highlightr: Highlightr?

    private static let languageByExtension: [String: String] = [
        "swift": "swift", "m": "objectivec", "mm": "objectivec",
        "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp",
        "hpp": "cpp", "hh": "cpp",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "javascript", "ts": "typescript", "tsx": "typescript",
        "py": "python", "go": "go", "rs": "rust",
        "rb": "ruby", "rake": "ruby", "gemspec": "ruby", "ru": "ruby",
        "erb": "erb",
        "ex": "elixir", "exs": "elixir", "erl": "erlang",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "scala": "scala",
        "cs": "csharp", "php": "php", "pl": "perl", "lua": "lua",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash",
        "yml": "yaml", "yaml": "yaml", "json": "json", "toml": "ini",
        "ini": "ini", "conf": "ini", "env": "ini",
        "md": "markdown", "markdown": "markdown",
        "html": "xml", "htm": "xml", "xml": "xml", "plist": "xml",
        "svelte": "xml", "vue": "xml",
        "css": "css", "scss": "scss", "less": "less",
        "sql": "sql", "graphql": "graphql", "gql": "graphql",
        "dockerfile": "dockerfile", "makefile": "makefile", "mk": "makefile",
        "cmake": "cmake", "gradle": "gradle", "groovy": "groovy",
        "r": "r", "jl": "julia", "hs": "haskell", "elm": "elm",
        "clj": "clojure", "cljs": "clojure", "nix": "nix", "zig": "zig",
        "proto": "protobuf", "tf": "ini", "diff": "diff", "patch": "diff",
        "gitignore": "ini", "gitattributes": "ini",
        "yml.lock": "yaml", "lock": "yaml", "resolved": "json",
    ]

    static func language(forExtension ext: String) -> String? {
        languageByExtension[ext.lowercased()]
    }

    static func language(forFileName name: String) -> String? {
        let lowered = name.lowercased()
        // Extension-less staples first.
        if lowered == "dockerfile" { return "dockerfile" }
        if lowered == "makefile" || lowered == "gnumakefile" { return "makefile" }
        if lowered == "gemfile" || lowered == "rakefile" { return "ruby" }
        return language(forExtension: (name as NSString).pathExtension)
    }

    /// Render `text` as per-line attributed strings for the viewer's lazy
    /// list. The whole (hard-capped) content is shown; syntax colouring runs
    /// over the leading budget only, in one pass so multi-line constructs
    /// keep their colours, and the tail renders plain.
    func render(text: String, language: String?) -> Rendered {
        var content = text
        var truncated = false
        if content.utf8.count > Self.maxBytes {
            content = String(decoding: Array(content.utf8.prefix(Self.maxBytes)), as: UTF8.self)
            truncated = true
        }
        var rawLines = content.components(separatedBy: "\n")
        if rawLines.count > Self.maxLines {
            rawLines = Array(rawLines.prefix(Self.maxLines))
            truncated = true
        }

        // How much of the head gets real highlighting.
        var highlightLineCount = min(rawLines.count, Self.highlightMaxLines)
        var budget = Self.highlightMaxBytes
        for (index, line) in rawLines.prefix(highlightLineCount).enumerated() {
            budget -= line.utf8.count + 1
            if budget < 0 {
                highlightLineCount = index
                break
            }
        }

        let engine = engineInstance()
        var background = Color(red: 0.11, green: 0.11, blue: 0.15)
        var attributed: NSAttributedString?
        if let engine, highlightLineCount > 0 {
            #if os(macOS)
            background = Color(nsColor: engine.theme.themeBackgroundColor)
            #else
            background = Color(uiColor: engine.theme.themeBackgroundColor)
            #endif
            let head = rawLines.prefix(highlightLineCount).joined(separator: "\n")
            if let language {
                attributed = engine.highlight(head, as: language, fastRender: true)
            } else if head.utf8.count <= Self.maxAutoDetectBytes {
                attributed = engine.highlight(head)
            }
        }

        var lines: [AttributedString] = []
        lines.reserveCapacity(rawLines.count)
        if let attributed {
            // Split the highlighted head back into lines, preserving runs.
            let full = attributed.string as NSString
            var location = 0
            while location <= full.length {
                let remaining = NSRange(location: location, length: full.length - location)
                let newline = full.range(of: "\n", options: [], range: remaining)
                let lineRange = newline.location == NSNotFound
                    ? remaining
                    : NSRange(location: location, length: newline.location - location)
                lines.append(AttributedString(attributed.attributedSubstring(from: lineRange)))
                if newline.location == NSNotFound { break }
                location = newline.location + 1
            }
        }
        let highlightedCount = lines.count
        // The plain tail (everything past the budget, or the whole file when
        // the language is unknown / the engine failed).
        for line in rawLines.dropFirst(highlightedCount) {
            var plain = AttributedString(line)
            plain.font = .system(size: 12, design: .monospaced)
            lines.append(plain)
        }
        let cutoff = highlightedCount < rawLines.count && highlightedCount > 0
            ? highlightedCount : nil
        return Rendered(lines: lines, truncated: truncated,
                        highlightCutoff: cutoff, background: background)
    }

    private func engineInstance() -> Highlightr? {
        if let highlightr { return highlightr }
        guard let fresh = Highlightr() else { return nil }
        // Closest bundled theme to the app's Catppuccin-flavoured dark look.
        fresh.setTheme(to: "atom-one-dark")
        fresh.theme.setCodeFont(PlatformFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        highlightr = fresh
        return fresh
    }
}

// MARK: - Viewer

struct CodePreviewView: View {
    let request: PreviewRequest
    @Environment(\.dismiss) private var dismiss

    @State private var rendered: HighlightEngine.Rendered?
    @State private var splitRows: [UnifiedDiff.Row]?
    @State private var loadError: String?
    @State private var fullText = ""
    @State private var mode: DiffPreviewMode = .inline
    @State private var webMode: WebPreviewMode = .rendered
    @FocusState private var viewerFocused: Bool

    enum WebPreviewMode: String, CaseIterable, Identifiable {
        case rendered = "Rendered"
        case source = "Source"
        var id: String { rawValue }
    }

    private var isGitFile: Bool {
        if case .gitFile = request.source { return true }
        return false
    }

    private var showsWebPreview: Bool {
        request.web != nil && webMode == .rendered
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        #if os(macOS)
        // Previews are often long files — open at most-of-the-screen, not a
        // dinky default sheet. SheetResizer flips the sheet window's
        // resizable bit; SwiftUI's flexible-frame hint alone doesn't.
        .frame(minWidth: 640, idealWidth: Self.idealSize.width, maxWidth: .infinity,
               minHeight: 440, idealHeight: Self.idealSize.height, maxHeight: .infinity)
        .background(SheetResizer())
        #endif
        // Quick Look manners: space closes the preview too. The root holds
        // focus (invisibly) so the key lands here, not on the Copy button.
        .focusable()
        .focusEffectDisabled()
        .focused($viewerFocused)
        .onKeyPress(.space) {
            dismiss()
            return .handled
        }
        .onChange(of: request.id, initial: true) {
            mode = request.initialMode
            viewerFocused = true
        }
        .task(id: "\(request.id)|\(mode.rawValue)|\(webMode.rawValue)") { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(request.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = request.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if request.web != nil {
                Picker("", selection: $webMode) {
                    ForEach(WebPreviewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else if isGitFile {
                Picker("", selection: $mode) {
                    ForEach(DiffPreviewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if rendered?.truncated == true {
                Text("Truncated at 10 MB")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.yellow.opacity(0.2), in: Capsule())
                    .help("Only the first 10 MB / 50,000 lines are shown")
            }
            Button {
                copyAll()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            // The sheet hands this button initial keyboard focus, which drew
            // a permanent focus ring around it.
            .focusEffectDisabled()
            .disabled(fullText.isEmpty)
            .help("Copy contents")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if showsWebPreview, let web = request.web {
            HTMLPreviewView(web: web)
        } else if let loadError {
            ContentUnavailableView(
                "Can't Preview", systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if isGitFile, mode == .split, let splitRows {
            SplitDiffView(rows: splitRows)
        } else if let rendered {
            // A two-axis ScrollView centres content smaller than the
            // viewport; pin it top-leading by giving it the viewport as a
            // minimum size.
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rendered.lines.enumerated()), id: \.offset) { index, line in
                            if index == rendered.highlightCutoff {
                                Text("— syntax colouring stops here (large file) —")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, gutterWidth + 10)
                                    .padding(.vertical, 3)
                            }
                            HStack(alignment: .top, spacing: 0) {
                                Text(String(index + 1))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: gutterWidth, alignment: .trailing)
                                    .padding(.trailing, 10)
                                Text(line)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 12)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height,
                           alignment: .topLeading)
                }
            }
            .background(rendered.background)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var gutterWidth: CGFloat {
        let digits = max(3, String(rendered?.lines.count ?? 0).count)
        return CGFloat(digits) * 8 + 12
    }

    #if os(macOS)
    private static var idealSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
        return CGSize(width: screen.width * 0.72, height: screen.height * 0.82)
    }
    #endif

    private func load() async {
        guard !showsWebPreview else { return }   // WebKit owns rendering
        loadError = nil
        let text: String
        let language: String?
        switch request.source {
        case .text(let string):
            text = string
            language = request.language ?? HighlightEngine.language(forFileName: request.title)
        case .file(let url):
            guard let contents = Self.readText(url) else {
                loadError = "Couldn't read the file."
                return
            }
            text = contents
            language = request.language ?? HighlightEngine.language(forFileName: request.title)
        case .gitFile(let latest, let diff):
            switch mode {
            case .latest:
                guard let contents = Self.readText(latest) else {
                    loadError = "Couldn't read the file."
                    return
                }
                text = contents
                language = HighlightEngine.language(forFileName: request.title)
            case .inline:
                text = diff
                language = "diff"
            case .split:
                fullText = diff
                if splitRows == nil { splitRows = UnifiedDiff.splitRows(diff) }
                return
            }
        }
        fullText = text
        if text.isEmpty {
            loadError = "The file is empty."
            return
        }
        rendered = await HighlightEngine.shared.render(text: text, language: language)
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(decoding: data.prefix(2 << 20), as: UTF8.self)
    }

    private func copyAll() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullText, forType: .string)
        #else
        UIPasteboard.general.string = fullText
        #endif
    }
}

#if os(macOS)
/// SwiftUI's flexible-frame hint alone doesn't make a macOS sheet
/// user-resizable — flip the bit on the hosting window directly.
private struct SheetResizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.styleMask.insert(.resizable) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.styleMask.insert(.resizable)
    }
}
#endif

// MARK: - Split (side-by-side) diff view

private struct SplitDiffView: View {
    let rows: [UnifiedDiff.Row]

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "No Difference", systemImage: "checkmark.seal",
                description: Text("This file matches HEAD."))
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: UnifiedDiff.Row) -> some View {
        switch row {
        case .hunk(let header):
            Text(header)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5))
        case .pair(let left, let right):
            HStack(alignment: .top, spacing: 0) {
                cell(left, missingKind: .removed)
                Divider()
                cell(right, missingKind: .added)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One half of a pair. `missingKind` tints the empty filler opposite an
    /// unpaired add/remove so the columns read as aligned.
    private func cell(_ cell: UnifiedDiff.Cell?, missingKind: UnifiedDiff.Cell.Kind) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(cell.map { String($0.number) } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)
            Text(cell?.text ?? "")
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(background(for: cell?.kind))
    }

    private func background(for kind: UnifiedDiff.Cell.Kind?) -> Color {
        switch kind {
        case .removed: .red.opacity(0.16)
        case .added: .green.opacity(0.16)
        case .context: .clear
        case nil: .primary.opacity(0.04)
        }
    }
}
