# Vendored Termini — local patches

Vendored from https://github.com/arach/Termini at commit
`ccd0d17e883d1af93fce002d204860184f2a9bad`.

We vendor (rather than use the remote package) because Termini wraps libghostty's
explicitly-unstable embedding API, and we need to patch its NSView resize path.

## Patches applied on top of upstream

- **`Sources/Termini/TerminiSurfaceView.swift` — live-resize winsize throttling.**
  Upstream pushes a new PTY winsize (`TIOCSWINSZ` → `SIGWINCH`) on every AppKit
  layout pass, so a live window drag storms the child process (~60 Hz of full
  redraws — very janky under tmux with `aggressive-resize`). We keep the visual
  surface tracking the window every frame, but coalesce the PTY winsize push to
  ~12 Hz while `inLiveResize`, and do one authoritative push in
  `viewDidEndLiveResize`. Search for `MARK: Sessionator patch`.

- **`TerminiTerminalAppearance.swift` + `TerminiGhosttyConfigFactory.swift` — colour
  theme injection.** Upstream's config factory only wires font size/family into the
  per-surface ghostty config, and GhosttyKit's C API exposes no per-colour setter —
  so there was no way to set a terminal colour theme, and surfaces fell back to
  libghostty's built-in default. We added `TerminiTerminalAppearance.extraConfigFilePaths`
  and have the factory `ghostty_config_load_file(...)` each one (after fonts, before a
  single `finalize`). Belfry writes a small ghostty snippet (its Catppuccin Mocha
  palette) and passes the path, which is how the rendered terminal gets recoloured.
  Additive + default-empty, so other call sites are unaffected.

- **`TerminiLocalPTYProcess.swift` — bounded PTY write back-pressure.** Upstream's
  `send()` retries `EAGAIN`/`EWOULDBLOCK` with `usleep(5ms)` in an **unbounded** loop.
  If the reader never drains (e.g. a stalled SSH link for a remote control client),
  that block runs forever and wedges the process's serial `queue` — which then
  deadlocks any `queue.sync` caller, notably `terminate()`. That deadlocked the app's
  main thread at quit (`shutdownAll` → `client.stop()` → `terminate()`), leaving
  Belfry "still running" and forcing a hard kill that could take the daemonized tmux
  server (and the user's local sessions) with it. We cap the stall at ~1s and then
  drop the remaining bytes. Search for `stalledMicros`.

- **`TerminiRuntime.swift` — tick loop demoted from 60 Hz drive to 1 s backstop.**
  Upstream ran `ghostty_app_tick` on an unconditional 60 Hz repeating Timer (each
  fire adding a main-queue dispatch) from launch to quit — ~60 wakeups/sec while
  completely idle, blocking App Nap and draining battery. libghostty already
  requests ticks via `wakeup_cb` (wired to `scheduleWakeupTick()`), so the timer is
  pure redundancy; it's now a 1 s safety net with 0.5 s tolerance.

- **`TerminiSurfaceView.swift` (+ param plumbing in `TerminiTerminalView.swift`,
  `TerminiSurfaceView_iOS.swift`) — render/visibility gating + draw throttling.**
  Battery work for hosts that keep several surfaces mounted (Belfry's warm session
  cache keeps every visited session attached, with all but one at opacity 0):
  - New `isRenderVisible` parameter (default `true`, so other call sites are
    unaffected) marks a surface the host knows is invisible. Combined with the
    hosting window's occlusion state (`NSWindow.didChangeOcclusionStateNotification`)
    into a `canRender` gate.
  - While gated: no render timers, no per-output draws, and
    `ghostty_surface_set_occlusion(surface, false)` so libghostty's renderer idles
    too. Output is still processed (terminal state stays warm) and PTY winsize
    still tracks layout; one catch-up refresh+draw runs on reveal
    (`needsDrawOnReveal`). Previously a busy background session rendered invisibly
    at up to 30 Hz forever, and the focused surface's 2 Hz idle loop kept running
    with the window fully occluded or minimized.
  - Immediate per-output-chunk draws are capped at ~60 fps (`lastOutputDraw`);
    under an output flood the 30 Hz burst timer coalesces frames instead of
    drawing synchronously per chunk. Render timers gained tolerance so the OS can
    coalesce their wakeups.

- **`TerminiLocalPTYProcess.swift` — coalesced PTY reads.** `drainOutput()` emitted
  one `onOutput` callback (→ one main-thread hop + one terminal feed) per 4 KB
  `read()`. All bytes readable in a drain pass are now batched into a single
  callback (bounded at 128 KB per emission), collapsing hundreds of main-thread
  wakeups per second during output floods into a handful.

- **`TerminiSSHSession.swift` — exec-request mode + raw output sink** (for
  Belfry's iOS transport):
  - `TerminiSSHConfiguration.useExecRequest` (default false): runs
    `startupCommand` as an SSH *exec* channel request instead of typing it into
    an interactive shell 180 ms after connect. Exec gives a clean byte stream —
    no shell echo/prompt/rc noise, which a protocol channel (`tmux -C`) can't
    tolerate — and a real exit status when the command dies.
  - `onRawOutput: ((Data) -> Void)?`: when set, remote bytes (and `[Termini]`
    status lines, so failure diagnostics flow too) bypass the terminal
    controller entirely. Lets a control-plane client reuse the SSH session
    machinery without pretending to be a rendered terminal.
