import Foundation
import Termini

/// Keeps one live libghostty surface (tmux attach) per *visited* session so
/// switching back is instant — no re-attach, no redraw. Surfaces are created
/// lazily on first selection and pruned when their session disappears.
@MainActor
@Observable
final class SessionSurfaceStore {
    private let transport: TmuxTransport
    /// Ordered list of activated session ids, for a stable ForEach in the detail.
    private(set) var activatedSessionIDs: [String] = []
    private var workspaces: [String: TerminiLocalPTYWorkspace] = [:]

    init(transport: TmuxTransport) {
        self.transport = transport
    }

    func workspace(for sessionID: String) -> TerminiLocalPTYWorkspace? {
        workspaces[sessionID]
    }

    /// Ensure a warm surface exists for this session (no-op if already warm).
    /// The surface is *started* by its view's `.task` (tied to view lifecycle).
    func activate(sessionID: String, sessionName: String) {
        guard workspaces[sessionID] == nil else { return }
        let workspace = TerminiLocalPTYWorkspace(
            processSpec: transport.tmuxProcessSpec(["new-session", "-A", "-s", sessionName])
        )
        workspaces[sessionID] = workspace
        activatedSessionIDs.append(sessionID)
    }

    /// Tear down every surface (used when the host disconnects).
    func teardownAll() {
        for (_, workspace) in workspaces { workspace.stop() }
        workspaces.removeAll()
        activatedSessionIDs.removeAll()
    }

    /// Tear down surfaces whose session no longer exists in tmux.
    func prune(livingSessionIDs: Set<String>) {
        let dead = activatedSessionIDs.filter { !livingSessionIDs.contains($0) }
        guard !dead.isEmpty else { return }
        for id in dead {
            workspaces[id]?.stop()
            workspaces[id] = nil
        }
        activatedSessionIDs.removeAll { dead.contains($0) }
    }
}
