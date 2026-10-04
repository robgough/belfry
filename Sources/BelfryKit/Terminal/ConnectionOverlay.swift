import SwiftUI

/// Dims the selected terminal while its link is down and says what's happening:
/// reconnecting (with a countdown and "Retry now"), waiting for a network,
/// failed (with the reason), or — host fine, this one surface dropped —
/// re-attaching. The frozen last frame stays visible underneath (it's often
/// what you wanted to read), but taps stop reaching a terminal that can't
/// receive them.
///
/// Appears only after `showDelay` of continuous trouble, so a fast resume or a
/// sub-second blip never flashes it; clears the instant the link is back.
struct ConnectionOverlay: View {
    let host: HostModel
    let sessionID: String

    private static let showDelay: Duration = .milliseconds(1500)
    @State private var isShown = false

    var body: some View {
        let problem = currentProblem
        ZStack {
            if isShown, let problem {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture {}   // swallow taps meant for the dead terminal
                card(for: problem)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: isShown)
        .allowsHitTesting(isShown && problem != nil)
        .task(id: problem?.kind) {
            guard problem != nil else {
                isShown = false
                return
            }
            // Already up (one problem turned into another): stay up.
            guard !isShown else { return }
            try? await Task.sleep(for: Self.showDelay)
            guard !Task.isCancelled else { return }
            isShown = true
        }
    }

    // MARK: State

    private enum Problem {
        case connecting
        case reconnecting(attempt: Int)
        case waitingForNetwork
        case failed(String)
        case surfaceAttaching
        case surfaceDown

        /// Identity for the show-delay task: changes in the attempt count or
        /// reason don't restart the delay.
        var kind: Int {
            switch self {
            case .connecting: 0
            case .reconnecting: 1
            case .waitingForNetwork: 2
            case .failed: 3
            case .surfaceAttaching: 4
            case .surfaceDown: 5
            }
        }
    }

    private var currentProblem: Problem? {
        switch host.store.status {
        case .connecting: return .connecting
        case .reconnecting(let attempt): return .reconnecting(attempt: attempt)
        case .waitingForNetwork: return .waitingForNetwork
        case .disconnected(let reason):
            // Background suspension resumes on its own; don't call it a failure.
            return reason == "suspended" ? .connecting : .failed(reason)
        case .offline: return .failed("Disconnected")
        case .connected:
            switch host.surfaceStore.workspace(for: sessionID)?.linkState {
            case .attaching: return .surfaceAttaching
            case .down: return .surfaceDown
            case .attached, .idle, nil: return nil
            }
        }
    }

    // MARK: Card

    @ViewBuilder
    private func card(for problem: Problem) -> some View {
        VStack(spacing: 10) {
            switch problem {
            case .connecting:
                ProgressView().controlSize(.small)
                title("Connecting to \(host.displayName)…")
            case .reconnecting(let attempt):
                Image(systemName: "bolt.horizontal.circle").font(.title2).foregroundStyle(.orange)
                title("Connection to \(host.displayName) lost")
                countdown(attempt: attempt)
                HStack(spacing: 8) {
                    Button("Retry Now") { host.retryNow() }
                        .buttonStyle(.borderedProminent)
                    disconnectButton
                }
            case .waitingForNetwork:
                Image(systemName: "wifi.slash").font(.title2).foregroundStyle(.secondary)
                title("Waiting for network")
                detail("Belfry will reconnect to \(host.displayName) as soon as you're back online.")
                disconnectButton
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                title("Can't reach \(host.displayName)")
                detail(reason).lineLimit(4)
                Button("Reconnect") { host.reconnect() }
                    .buttonStyle(.borderedProminent)
            case .surfaceAttaching:
                ProgressView().controlSize(.small)
                title("Attaching…")
            case .surfaceDown:
                Image(systemName: "rectangle.portrait.slash").font(.title2).foregroundStyle(.secondary)
                title("This terminal was detached")
                detail("The session is still running on \(host.displayName).")
                Button("Reattach") { host.surfaceStore.restart(sessionID: sessionID) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .padding(16)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    /// "Retrying in 8s", ticking once a second — only while this card is up.
    private func countdown(attempt: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let next = host.nextRetryAt {
                let seconds = max(0, Int(next.timeIntervalSince(context.date).rounded(.up)))
                detail(seconds > 0 ? "Retrying in \(seconds)s (attempt \(attempt))" : "Retrying…")
                    .monospacedDigit()
            } else {
                detail("Retrying…")
            }
        }
    }

    @ViewBuilder
    private var disconnectButton: some View {
        if host.canDisconnect {
            Button("Disconnect") { host.disconnect() }
                .buttonStyle(.bordered)
        }
    }
}
