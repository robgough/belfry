import Testing
@testable import Belfry

/// The crux of the tmux socket-hijack fix lives in `LaunchdTmux.runOutcome`: it
/// must tell a command that *exited* (with its status) apart from one that *timed
/// out*. `probeServer` leans entirely on that split — a fast-failing `tmux ls`
/// ("no server running on …") is `.absent` and safe to start a server on, but a
/// `tmux ls` that *hangs* means the server is alive-but-wedged (classically the
/// box thrashing under memory pressure), which must map to `.unresponsive` so we
/// wait rather than unlink the live socket and orphan its sessions. These pin
/// that behaviour with hermetic commands (no real tmux server required).
struct LaunchdTmuxRunOutcomeTests {
    @Test func cleanZeroExitReportsExitedZero() {
        // Mirrors `tmux ls` succeeding → probeServer .up.
        #expect(LaunchdTmux.runOutcome("/bin/sh", ["-c", "exit 0"], timeout: 5) == .exited(0))
    }

    @Test func fastNonzeroExitPreservesStatus() {
        // Mirrors `tmux ls` failing fast with "no server running" → probeServer
        // .absent (the only state in which it's safe to start a new server).
        #expect(LaunchdTmux.runOutcome("/bin/sh", ["-c", "exit 3"], timeout: 5) == .exited(3))
    }

    @Test func hangingCommandTimesOutRatherThanExiting() {
        // The wedged-server signal: a command that outlives the timeout must be
        // reported as `.timedOut`, never as a (spurious) exit. `sleep 5` under a
        // 0.3s budget is our stand-in for a `tmux ls` that never answers.
        #expect(LaunchdTmux.runOutcome("/bin/sleep", ["5"], timeout: 0.3) == .timedOut)
    }

    @Test func missingBinaryIsSpawnFailure() {
        #expect(LaunchdTmux.runOutcome("/nonexistent/definitely-not-here", [], timeout: 1) == .spawnFailed)
    }
}
