import SwiftUI
import Termini

/// Detail pane: every visited session (across all hosts) keeps a live surface
/// mounted in a ZStack; only the selected one is visible, so switching is an
/// instant visibility toggle. Selecting a window issues `select-window` to that
/// window's host, which its surface follows.
struct TerminalDetailView: View {
    let hosts: [HostModel]
    let selection: WindowSelection?
    let fontSize: Double?

    private var selectedHost: HostModel? {
        hosts.first { $0.id == selection?.hostID }
    }

    private var selectedSession: TmuxSession? {
        guard let sel = selection, let host = selectedHost else { return nil }
        return host.store.sessions.first { $0.windows.contains { $0.id == sel.windowID } }
    }

    var body: some View {
        ZStack {
            ForEach(hosts) { host in
                ForEach(host.surfaceStore.activatedSessionIDs, id: \.self) { sessionID in
                    if let workspace = host.surfaceStore.workspace(for: sessionID) {
                        WarmSurface(
                            workspace: workspace,
                            fontSize: fontSize,
                            isVisible: host.id == selection?.hostID && sessionID == selectedSession?.id
                        )
                    }
                }
            }
            if selectedSession == nil {
                Text("Select a window")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selection, initial: true) { _, sel in
            // Defer the side-effects: this fires from the List's selection change,
            // and mutating observed state (activating a surface) synchronously here
            // can re-enter the NSTableView delegate. One tick later is safe.
            DispatchQueue.main.async {
                guard let sel, let host = selectedHost, let session = selectedSession else { return }
                host.surfaceStore.activate(sessionID: session.id, sessionName: session.name)
                host.client.selectWindow(sel.windowID)
                host.surfaceStore.workspace(for: session.id)?.focus()
            }
        }
    }
}

/// A single warm terminal surface. Stays mounted while its session is activated,
/// so it never re-attaches; only its visibility changes when switching.
private struct WarmSurface: View {
    let workspace: any TerminalWorkspace
    let fontSize: Double?
    let isVisible: Bool

    var body: some View {
        workspace.makeSurfaceView(fontSize: fontSize, isVisible: isVisible)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .task {
                workspace.start()
                // Clean up the first-attach redraw (tmux drew at the initial PTY
                // size, then reflowed) with a one-shot winsize nudge.
                try? await Task.sleep(for: .milliseconds(350))
                guard let size = workspace.terminalSize else { return }
                workspace.resize(columns: size.columns, rows: max(1, size.rows - 1))
                try? await Task.sleep(for: .milliseconds(40))
                workspace.resize(columns: size.columns, rows: size.rows)
            }
    }
}
