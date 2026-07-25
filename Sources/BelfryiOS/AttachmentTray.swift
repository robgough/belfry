import PencilKit
import PhotosUI
import SwiftUI
import TerminiSSH
import UIKit
import UniformTypeIdentifiers

// Terminal attachments: photos/files staged locally, uploaded to the host's
// ~/.cache/belfry/attachments/<session>/<transfer>/ via the existing transfer
// machinery (.part → rename, progress in the Transfers button), then typed at
// the prompt as shell-escaped paths. Images can be annotated with PencilKit
// before sending — screenshot → circle the bug → hand the path to Claude.

/// One staged attachment: a local copy in tmp (so pickers' security scopes
/// can be dropped immediately), plus a thumbnail when it's an image.
@MainActor
@Observable
final class AttachmentStaging {
    struct Item: Identifiable {
        let id = UUID()
        var localURL: URL
        var name: String
        var thumbnail: UIImage?
        var isImage: Bool { thumbnail != nil }
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private lazy var stagingDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("belfry-attachments/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func stage(data: Data, preferredName: String) {
        let name = AttachmentNaming.sanitized(preferredName)
        let url = stagingDir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(name)")
        guard (try? data.write(to: url)) != nil else { return }
        items.append(Item(localURL: url, name: name, thumbnail: UIImage(data: data)?.thumbnail()))
    }

    /// Files picker URLs are security-scoped; copy while the scope is open.
    func stage(pickedURL: URL) {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: pickedURL) else { return }
        stage(data: data, preferredName: pickedURL.lastPathComponent)
    }

    func replace(id: UUID, with data: Data, name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let sanitized = AttachmentNaming.sanitized(name)
        let url = stagingDir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(sanitized)")
        guard (try? data.write(to: url)) != nil else { return }
        items[index] = Item(localURL: url, name: sanitized,
                            thumbnail: UIImage(data: data)?.thumbnail())
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func clear() {
        items.removeAll()
        try? FileManager.default.removeItem(at: stagingDir)
    }
}

private extension UIImage {
    func thumbnail(maxDimension: CGFloat = 160) -> UIImage {
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// Everything the dock's session-aware features (attachments, previews) need
/// to reach the selected session's host.
struct DockContext {
    let hostID: String
    let sessionName: String
    /// The selected window's `pane_current_path` — anchors relative paths in
    /// long-press previews. nil when the control plane hasn't reported one.
    let currentDirectory: String?
    let browser: any FileBrowsing
    let transferCenter: TransferCenter
    let workspace: BelfrySSHWorkspace
    /// Opens an SSH local forward to (host, port) as seen from the remote.
    let openForward: (String, Int) async throws -> TerminiSSHLocalForward
}

/// The attachment sheet: add from Photos/Files/clipboard, annotate images,
/// then send — uploads stream through TransferCenter and the final remote
/// paths are typed at the prompt.
struct AttachmentTraySheet: View {
    let staging: AttachmentStaging
    let context: DockContext
    @Environment(\.dismiss) private var dismiss

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showsFilePicker = false
    @State private var markupItem: AttachmentStaging.Item?
    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Label("Add Photos", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showsFilePicker = true
                    } label: {
                        Label("Add File", systemImage: "folder")
                    }
                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!UIPasteboard.general.hasImages && !UIPasteboard.general.hasStrings)
                }
                if !staging.items.isEmpty {
                    Section("Attached") {
                        ForEach(staging.items) { item in
                            row(for: item)
                        }
                        .onDelete { offsets in
                            for offset in offsets { staging.remove(id: staging.items[offset].id) }
                        }
                    }
                }
                if let sendError {
                    Section {
                        Text(sendError).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .navigationTitle("Attachments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        send()
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Send").bold()
                        }
                    }
                    .disabled(staging.items.isEmpty || isSending)
                }
            }
            .fileImporter(isPresented: $showsFilePicker,
                          allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                for url in (try? result.get()) ?? [] {
                    staging.stage(pickedURL: url)
                }
            }
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                Task {
                    for item in items {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        let name = (item.itemIdentifier.map { String($0.prefix(8)) } ?? "photo") + ".jpg"
                        staging.stage(data: data, preferredName: "photo-\(name)")
                    }
                }
            }
            .sheet(item: $markupItem) { item in
                AttachmentMarkupSheet(item: item) { annotated, name in
                    staging.replace(id: item.id, with: annotated, name: name)
                }
            }
        }
    }

    private func row(for item: AttachmentStaging.Item) -> some View {
        HStack(spacing: 12) {
            if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "doc")
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            }
            Text(item.name).font(.callout).lineLimit(1)
            Spacer()
            if item.isImage {
                Button {
                    markupItem = item
                } label: {
                    Image(systemName: "pencil.tip.crop.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func pasteFromClipboard() {
        let pasteboard = UIPasteboard.general
        if let image = pasteboard.image, let data = image.pngData() {
            staging.stage(data: data, preferredName: "pasted.png")
        } else if let text = pasteboard.string {
            staging.stage(data: Data(text.utf8), preferredName: "pasted.txt")
        }
    }

    /// Upload every staged item into one per-transfer remote directory, wait
    /// for completion, then type the shell-escaped paths at the prompt.
    private func send() {
        isSending = true
        sendError = nil
        let directory = AttachmentNaming.remoteDirectory(
            sessionName: context.sessionName, transferID: UUID())
        let transfers = staging.items.map { item in
            context.transferCenter.upload(
                localURL: item.localURL, hostID: context.hostID,
                browser: context.browser, toDirectory: directory)
        }
        Task {
            var paths: [String] = []
            for transfer in transfers {
                let state = await transfer.completion()
                if case .failed(let message) = state {
                    sendError = message
                    isSending = false
                    return
                }
                if let path = transfer.finalRemotePath { paths.append(path) }
            }
            let typed = paths.map(AttachmentNaming.promptQuoted).joined(separator: " ")
            if !typed.isEmpty {
                context.workspace.sendInput(Data((typed + " ").utf8))
            }
            staging.clear()
            isSending = false
            dismiss()
        }
    }
}

// MARK: - PencilKit markup

/// Draw over an image (screenshot → circle the bug) and save a PNG copy named
/// `<stem>-annotated.png` back into the tray.
private struct AttachmentMarkupSheet: View {
    let item: AttachmentStaging.Item
    let onSave: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()

    var body: some View {
        NavigationStack {
            Group {
                if let image = UIImage(contentsOfFile: item.localURL.path) {
                    MarkupCanvas(canvas: canvas, image: image)
                } else {
                    ContentUnavailableView("Couldn't load image", systemImage: "photo")
                }
            }
            .navigationTitle("Annotate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() {
        guard let image = UIImage(contentsOfFile: item.localURL.path) else { return }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let rendered = renderer.image { _ in
            image.draw(at: .zero)
            let drawing = canvas.drawing.image(
                from: CGRect(origin: .zero, size: canvas.bounds.size), scale: 1)
            drawing.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let data = rendered.pngData() else { return }
        let stem = (item.name as NSString).deletingPathExtension
        onSave(data, "\(stem)-annotated.png")
    }
}

/// PKCanvasView over the image, with the system tool picker attached.
private struct MarkupCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    let image: UIImage

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.isOpaque = false
        canvas.backgroundColor = .clear
        canvas.drawingPolicy = .anyInput

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        canvas.insertSubview(imageView, at: 0)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: canvas.frameLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: canvas.frameLayoutGuide.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: canvas.frameLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: canvas.frameLayoutGuide.trailingAnchor),
        ])

        let toolPicker = PKToolPicker()
        toolPicker.setVisible(true, forFirstResponder: canvas)
        toolPicker.addObserver(canvas)
        context.coordinator.toolPicker = toolPicker
        canvas.becomeFirstResponder()
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var toolPicker: PKToolPicker?
    }
}
