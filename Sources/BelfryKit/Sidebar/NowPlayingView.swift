import SwiftUI

/// iTunes-style "now playing" readout for the title bar: a compact two-line
/// lozenge describing the currently selected window — what's running (the
/// Claude Code session name when the window hosts Claude, otherwise the
/// session/window name) over where it's running (host · working directory,
/// ~-abbreviated). Live Claude status rides along as the same chip the
/// sidebar uses, so Working/Idle/Waiting reads identically everywhere.
///
/// Renders nothing when no window is selected (or the selection can't be
/// resolved against live tmux state), so the plain window title shows as
/// before. Sized to sit inside a `.principal` toolbar item without exceeding
/// the standard toolbar height.
struct NowPlayingView: View {
    let hosts: [HostModel]
    let selection: WindowSelection?

    var body: some View {
        if let current = resolved {
            lozenge(for: current)
        }
    }

    // MARK: Resolution

    /// The selection joined against live state; nil hides the readout (host
    /// removed, store cleared on disconnect, window killed, …).
    private var resolved: (host: HostModel, session: TmuxSession, window: TmuxWindow)? {
        guard let sel = selection,
              let host = hosts.first(where: { $0.id == sel.hostID }),
              let session = host.store.sessions.first(where: { $0.windows.contains { $0.id == sel.windowID } }),
              let window = session.windows.first(where: { $0.id == sel.windowID })
        else { return nil }
        return (host, session, window)
    }

    // MARK: Rendering

    @ViewBuilder
    private func lozenge(for current: (host: HostModel, session: TmuxSession, window: TmuxWindow)) -> some View {
        let window = current.window
        HStack(spacing: 8) {
            VStack(spacing: 1) {
                Text(primaryLine(for: current))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(secondaryLine(for: current))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if window.claudeState != .none {
                ClaudeBadge(state: window.claudeState, title: window.claudeTitle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
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
        .frame(minWidth: 160, maxWidth: 460)
        .fixedSize(horizontal: false, vertical: true)
        .hoverHint(hint(for: current))
        .accessibilityElement(children: .combine)
    }

    /// What's running: the Claude Code session name when this window hosts
    /// Claude and the hooks reported one; otherwise the window's name (with
    /// its session for context when the two differ).
    private func primaryLine(for current: (host: HostModel, session: TmuxSession, window: TmuxWindow)) -> String {
        let window = current.window
        if window.claudeState != .none, !window.claudeTitle.isEmpty {
            return window.claudeTitle
        }
        let windowName = window.name.isEmpty ? "window \(window.index)" : window.name
        return windowName == current.session.name
            ? windowName
            : "\(current.session.name) · \(windowName)"
    }

    /// Where it's running: "host · ~/path" (just the host while the working
    /// directory is unknown).
    private func secondaryLine(for current: (host: HostModel, session: TmuxSession, window: TmuxWindow)) -> String {
        var parts = [current.host.displayName]
        if !current.window.currentPath.isEmpty {
            parts.append(abbreviateHomePath(current.window.currentPath))
        }
        return parts.joined(separator: " · ")
    }

    /// Tooltip with the untruncated details (long paths middle-truncate in
    /// the lozenge itself).
    private func hint(for current: (host: HostModel, session: TmuxSession, window: TmuxWindow)) -> String {
        var lines = ["Session “\(current.session.name)” on \(current.host.displayName)"]
        if !current.window.currentPath.isEmpty {
            lines.append(current.window.currentPath)
        }
        return lines.joined(separator: "\n")
    }
}
