import AppKit
import SwiftUI

extension View {
    /// Adds file-sending to the detail pane: drag-and-drop onto the terminal,
    /// and a paperclip toolbar button with an open panel. Both stage the file
    /// on the selected session's host (see `AttachmentStaging`) and paste its
    /// escaped path into the terminal input — which is how Claude Code takes
    /// images and documents.
    func terminalAttachments(hosts: [HostModel], selection: WindowSelection?) -> some View {
        modifier(TerminalAttachments(hosts: hosts, selection: selection))
    }
}

private struct TerminalAttachments: ViewModifier {
    let hosts: [HostModel]
    let selection: WindowSelection?

    @State private var isDropTargeted = false
    @State private var sendsInFlight = 0
    @State private var errorText: String?
    @State private var errorGeneration = 0

    private var targetHost: HostModel? {
        hosts.first { $0.id == selection?.hostID }
    }

    private var targetSession: TmuxSession? {
        guard let sel = selection, let host = targetHost else { return nil }
        return host.store.sessions.first { $0.windows.contains { $0.id == sel.windowID } }
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                FileDropCatcher(
                    isEnabled: targetSession != nil,
                    onTargeted: { isDropTargeted = $0 },
                    onFiles: { urls in Task { await send(urls) } }
                )
            }
            .overlay {
                if isDropTargeted, let session = targetSession {
                    dropHint(sessionName: session.name)
                }
            }
            .overlay(alignment: .bottom) {
                statusToast
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentOpenPanel()
                    } label: {
                        Label("Attach File…", systemImage: "paperclip")
                    }
                    .disabled(targetSession == nil)
                    .help("Send a file to this session: it's staged on the host and its path is pasted into the prompt")
                }
            }
    }

    // MARK: Pipeline

    @MainActor
    private func send(_ urls: [URL]) async {
        guard let host = targetHost, let session = targetSession,
              let workspace = host.surfaceStore.workspace(for: session.id),
              let transport = host.transport as? TmuxTransport else { return }
        sendsInFlight += 1
        defer { sendsInFlight -= 1 }
        do {
            var paths: [String] = []
            for url in urls {
                paths.append(try await AttachmentStaging.stage(fileURL: url, transport: transport))
            }
            // Bracketed paste: tmux marks the insertion as a paste and only
            // forwards the markers to panes that asked for them, so Claude
            // Code sees a paste while a plain shell just sees the path.
            let text = paths.map(AttachmentStaging.shellEscaped).joined(separator: " ") + " "
            workspace.sendInput(Data("\u{1b}[200~\(text)\u{1b}[201~".utf8))
            workspace.focus()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @MainActor
    private func presentOpenPanel() {
        guard let session = targetSession else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Send files to “\(session.name)” — each file's path is pasted into the terminal."
        panel.prompt = "Send"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { await send(urls) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    @MainActor
    private func showError(_ message: String) {
        errorText = message
        errorGeneration += 1
        let generation = errorGeneration
        Task {
            try? await Task.sleep(for: .seconds(6))
            if errorGeneration == generation { errorText = nil }
        }
    }

    // MARK: Chrome

    private func dropHint(sessionName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(AppTheme.accent.opacity(0.08))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(AppTheme.accent, lineWidth: 2)
            Label("Send to \(sessionName)", systemImage: "arrow.down.doc")
                .font(.title3)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(8)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusToast: some View {
        if sendsInFlight > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending…")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
            .allowsHitTesting(false)
        } else if let errorText {
            Text(errorText)
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .onTapGesture { self.errorText = nil }
        }
    }
}
