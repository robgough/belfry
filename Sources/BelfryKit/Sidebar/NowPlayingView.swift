import SwiftUI

/// The display-ready description of the selected window: what's running (the
/// Claude Code session name when the window hosts Claude and the hooks
/// reported one, otherwise the session/window name) and where it's running
/// (host · working directory, ~-abbreviated). One value shared by every
/// header readout — the iPhone/iPad's now-playing lozenge and the Mac's
/// native window title/subtitle — so the two stay word-for-word identical.
///
/// The failable init returns nil when there is no selection or it can't be
/// joined against live tmux state (host removed, store cleared on disconnect,
/// window killed, …); callers fall back to their plain app-title state.
struct WindowReadout: Equatable {
    /// What's running: the Claude Code session name, or the window's name
    /// (with its session for context when the two differ).
    let primary: String
    /// Where it's running: "host · ~/path" (just the host while the working
    /// directory is unknown). `host` and `path` are the same line split so
    /// displays can tint the machine name by local/remote.
    let secondary: String
    let host: String
    /// ~-abbreviated working directory ("" while unknown).
    let path: String
    /// Untruncated details for tooltips (long paths middle-truncate in the
    /// compact displays).
    let hint: String
    let claudeState: ClaudeState
    let claudeTitle: String
    /// Absolute working directory of the active pane ("" when unknown).
    let currentPath: String
    /// Whether the window lives on the local host — only then can the Mac
    /// offer the working directory as a title-bar proxy icon.
    let isLocalHost: Bool

    @MainActor
    init?(hosts: [HostModel], selection: WindowSelection?) {
        guard let sel = selection,
              let host = hosts.first(where: { $0.id == sel.hostID }),
              let session = host.store.sessions.first(where: { $0.windows.contains { $0.id == sel.windowID } }),
              let window = session.windows.first(where: { $0.id == sel.windowID })
        else { return nil }

        if window.claudeState != .none, !window.claudeTitle.isEmpty {
            primary = window.claudeTitle
        } else {
            let windowName = window.name.isEmpty ? "window \(window.index)" : window.name
            primary = windowName == session.name
                ? windowName
                : "\(session.name) · \(windowName)"
        }

        self.host = host.displayName
        path = window.currentPath.isEmpty ? "" : abbreviateHomePath(window.currentPath)
        secondary = path.isEmpty ? self.host : "\(self.host) · \(path)"

        var lines = ["Session “\(session.name)” on \(host.displayName)"]
        if !window.currentPath.isEmpty {
            lines.append(window.currentPath)
        }
        hint = lines.joined(separator: "\n")

        claudeState = window.claudeState
        claudeTitle = window.claudeTitle
        currentPath = window.currentPath
        isLocalHost = host.transport.isLocal
    }

    /// `secondary` as styled Text: the machine name tinted local/remote, the
    /// path left to the surrounding style. Used by the lozenge and the Mac's
    /// title-bar subtitle alike.
    var secondaryText: Text {
        let tinted = Text(host).foregroundStyle(AppTheme.hostTint(isLocal: isLocalHost))
        return path.isEmpty ? tinted : tinted + Text(" · \(path)")
    }
}

/// iTunes-style "now playing" readout for the iOS/iPad navigation bar: a
/// compact two-line lozenge showing the `WindowReadout` for the selected
/// window. Live Claude status rides along as the same chip the sidebar uses,
/// so Working/Idle/Waiting reads identically everywhere. (The Mac shows the
/// same two lines as its native window title/subtitle instead.)
///
/// Renders nothing when no window is selected (or the selection can't be
/// resolved against live tmux state), so the plain title shows as before.
/// Sized to sit inside a `.principal` toolbar item without exceeding the
/// standard toolbar height.
struct NowPlayingView: View {
    let hosts: [HostModel]
    let selection: WindowSelection?
    /// Larger type and a wider minimum, for the roomier iPad toolbar. The
    /// iPhone uses the compact default.
    var prominent: Bool = false

    var body: some View {
        if let readout = WindowReadout(hosts: hosts, selection: selection) {
            lozenge(for: readout)
        }
    }

    @ViewBuilder
    private func lozenge(for readout: WindowReadout) -> some View {
        HStack(spacing: 8) {
            VStack(spacing: 1) {
                Text(readout.primary)
                    .font(.system(size: prominent ? 15 : 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                readout.secondaryText
                    .font(.system(size: prominent ? 12 : 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if readout.claudeState != .none {
                ClaudeBadge(state: readout.claudeState, title: readout.claudeTitle)
            }
        }
        .padding(.horizontal, prominent ? 16 : 12)
        .padding(.vertical, prominent ? 5 : 3)
        // The LCD: slightly inset against the toolbar material, same rounded
        // panel treatment as the sidebar's host bands and chips.
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppTheme.sidebarPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .frame(minWidth: prominent ? 240 : 160, maxWidth: 460)
        .fixedSize(horizontal: false, vertical: true)
        .hoverHint(readout.hint)
        .accessibilityElement(children: .combine)
    }
}
