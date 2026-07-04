import Foundation
import Termini

/// Keeps one live libghostty surface (tmux attach) per *visited* session so
/// switching back is instant — no re-attach, no redraw. Surfaces are created
/// lazily on first selection and pruned when their session disappears.
@MainActor
@Observable
final class SessionSurfaceStore {
    /// Builds a platform workspace attached to the named tmux session.
    private let makeWorkspace: (String) -> any TerminalWorkspace
    /// Ordered list of activated session ids, for a stable ForEach in the detail.
    private(set) var activatedSessionIDs: [String] = []
    private var workspaces: [String: any TerminalWorkspace] = [:]

    init(makeWorkspace: @escaping (String) -> any TerminalWorkspace) {
        self.makeWorkspace = makeWorkspace
    }

    func workspace(for sessionID: String) -> (any TerminalWorkspace)? {
        workspaces[sessionID]
    }

    /// Ensure a warm surface exists for this session (no-op if already warm).
    /// The surface is *started* by its view's `.task` (tied to view lifecycle).
    func activate(sessionID: String, sessionName: String) {
        guard workspaces[sessionID] == nil else { return }
        workspaces[sessionID] = makeWorkspace(sessionName)
        activatedSessionIDs.append(sessionID)
    }

    /// Tear down every surface (used when the host disconnects).
    func teardownAll() {
        for (_, workspace) in workspaces { workspace.stop() }
        workspaces.removeAll()
        activatedSessionIDs.removeAll()
    }

    /// Tear down one session's surface. Used when the surface's tmux client
    /// can no longer be trusted to be showing this session (the user moved it
    /// with the tmux session selector); the next visit re-attaches cleanly.
    func deactivate(sessionID: String) {
        guard let workspace = workspaces[sessionID] else { return }
        workspace.stop()
        workspaces[sessionID] = nil
        activatedSessionIDs.removeAll { $0 == sessionID }
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
