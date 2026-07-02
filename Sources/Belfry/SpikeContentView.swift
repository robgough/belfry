import SwiftUI
import Termini

/// Milestone 1 spike: prove the libghostty (Termini) surface renders a live,
/// interactive real-tmux session. We attach-or-create the `marketing` session
/// (one of the user's existing sessions) inside a single Ghostty surface.
///
/// This deliberately has no sidebar yet — it only validates the riskiest
/// dependency (libghostty embedding) end to end before we build the
/// control-mode sidebar around it.
struct SpikeContentView: View {
    @State private var workspace = TerminiLocalPTYWorkspace(
        processSpec: TerminiProcessSpec(
            executableURL: URL(fileURLWithPath: Self.tmuxPath),
            arguments: ["new-session", "-A", "-s", "marketing"],
            workingDirectoryURL: URL(fileURLWithPath: NSHomeDirectory())
        )
    )

    var body: some View {
        // `appearance:` disambiguates between Termini's two overloaded inits
        // (the other takes `fontSize:`); both otherwise match `(controller:)`.
        TerminiTerminalView(controller: workspace.controller, appearance: .default)
            .task { workspace.start() }
            .onDisappear { workspace.stop() }
    }

    /// Homebrew tmux on Apple Silicon. Resolved dynamically later; hardcoded for
    /// the spike (confirmed at /opt/homebrew/bin/tmux).
    private static let tmuxPath: String = {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/tmux"
    }()
}
