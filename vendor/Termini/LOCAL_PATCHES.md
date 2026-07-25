# Vendored Termini — local patches

Vendored from https://github.com/arach/Termini at commit
`ccd0d17e883d1af93fce002d204860184f2a9bad`.

Upstream added an MIT LICENSE (and completed THIRD_PARTY_NOTICES with
Ghostty's MIT text) in July 2026 at our request — both files are
backported here from upstream so this vendored copy is redistributable.

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

- **`TerminiSurfaceView.swift` + `TerminiSurfaceView_iOS.swift` — terminal
  output fed to libghostty off the main thread (deadlock fix).**
  `processRemoteOutput` called `ghostty_surface_process_output` on the main
  thread. Inside ghostty, escape sequences that notify the host — `set_title`,
  `set_mouse_shape` (one per DEC mouse-mode toggle 1000/1002/1003/1006),
  pwd/color changes — are pushed onto the app-wide 64-slot mailbox
  (`BlockingQueue(Message, 64)` in ghostty's `App.zig`); when it fills, the
  push blocks until `ghostty_app_tick` drains it, and that tick only runs on
  the main thread. One coalesced output burst carrying >64 such sequences
  (easy on a local PTY with 128 KB coalescing: a tmux pane-split redraw with
  `mouse on` toggles mouse modes around every redraw cycle) blocked the main
  thread forever — beachball, force-quit required. Upstream ghostty never
  hits this because it feeds output from a dedicated read thread while the
  apprt main thread keeps ticking. We now do the same: each surface hands
  output to `ghostty_surface_process_output` on a private serial
  `outputFeedQueue` (byte order preserved; the feed block retains the view so
  `deinit` can't free the surface mid-call), then hops back to the main
  thread for the existing refresh/draw gating (`drawAfterRemoteOutput`). A
  full mailbox now merely stalls the feed queue until the next tick drains
  it. This generalizes the `surfaceIOReady` startup buffering (same deadlock
  class at surface creation), which stays as-is. Evidenced by
  `Belfry_2026-07-04-*.hang` reports: main thread parked in `__ulock_wait2`
  under `processRemoteOutput` with ghostty's io/renderer threads idle.

- **`TerminiLocalPTYProcess.swift` — terminate() safe on its own queue (silent
  wake-crash fix).** A dispatch-source handler running on the process's private
  serial `queue` can end up holding the last strong reference to the object (the
  handler's `guard let self` temporary), so `deinit` — which calls `terminate()` —
  runs *on* `queue`. Upstream's `terminate()` unconditionally did `queue.sync`,
  a same-queue dispatch_sync that libdispatch traps as a client bug
  (EXC_BREAKPOINT in `__DISPATCH_WAIT_FOR_QUEUE__`). GhosttyKit's bundled
  Sentry/Breakpad handler then swallowed the crash (minidump to
  `~/.local/state/ghostty/crash/`, `_exit(6)`) — no macOS crash report, the app
  just vanished. Triggered reliably after wake/DarkWake, when dead SSH control
  channels made every host tear down its PTY process at once. Fix: the queue is
  tagged with an instance-owned `DispatchSpecificKey`; `terminate()` runs its
  body inline when already on the queue. Search for `queueKey`.

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

- **`TerminiSurfaceView.swift` — correct scroll-event semantics (scrolling was
  far too fast).** `ghostty_surface_mouse_scroll`'s last argument is a scroll
  mods bitmask — bit 0 = precision flag, bits 1–3 = momentum phase (ghostty
  `src/input/mouse.zig`) — but upstream passed the *keyboard* modifier
  bitmask and never set precision. Ghostty therefore treated trackpad pixel
  deltas as discrete wheel ticks, multiplying each by the cell height: one
  line scrolled per pixel of finger travel, and holding shift while
  scrolling flipped the precision bit. Now mirrors ghostty's own AppKit
  surface view: `hasPreciseScrollingDeltas` sets the precision flag (deltas
  are pixels, with ghostty's 2x feel multiplier), discrete wheel ticks pass
  through unscaled, and `momentumPhase` is forwarded so inertial scrolling
  decays properly.

- **`TerminiRuntime.swift` + `TerminiSurfaceView.swift` — clipboard copy.**
  Upstream's `write_clipboard_cb` was an empty stub and the surface view only
  implemented paste, so nothing could get *out* of the terminal: ⌘C did
  nothing (Edit ▸ Copy stayed disabled — no `copy(_:)` on the responder
  chain), and OSC 52 clipboard writes (tmux copy-mode with `set-clipboard`)
  were silently dropped. The callback now writes its (mime, data) entries to
  the surface's pasteboard (`text/plain` → `.string`, `text/html` → `.html`,
  anything else via `UTType(mimeType:)`), and the view implements `copy(_:)`
  plus ⌘C in `performKeyEquivalent`, both driving ghostty's
  `copy_to_clipboard` binding action.

- **`Sources/TerminiSSH/TerminiSSHExec.swift` (new) + `TerminiSSHSession.swift` —
  exec channels on a live connection.** Upstream opens exactly one session
  channel per connection (the shell / tmux exec) and exposes no way to run
  further commands over it. SSH multiplexes arbitrarily many session channels
  over one authenticated connection, and Belfry's file browsing needs that:
  directory listings, `cat`-style downloads and streamed uploads next to the
  long-lived channel with no second connect and no re-auth. Added
  `TerminiSSHSession.exec(_:)` — a **no-PTY** exec request on a fresh child
  channel — returning a `TerminiSSHExecProcess` handle: streamed stdout
  (`AsyncThrowingStream`), backpressured stdin `write`, stdin half-close
  (`finishInput()` → SSH channel EOF, so a remote `cat > file` completes),
  capped stderr tail, real exit status, and `cancel()`. Also added
  `TerminiSSHConfiguration.opensPrimaryChannel` (default true): when false,
  `connect()` opens no shell channel at all — the session is a pure
  connection host for exec channels; auth is validated eagerly by probing
  `exec("true")`. Handler callbacks stay on the event loop and meet the async
  consumer only through lock-guarded state, so transfers are immune to
  main-thread stalls. Additive; existing call sites are untouched.

## Patches added 2026-07-25 (ghostty-on-iOS + touch UX)

- **`vendor/ghostty` `build.zig.zon` — libxev bumped for iOS mach-port
  wakeups (THE blank-terminal fix).** The pinned libxev snapshot never
  delivered wakeups to ghostty's renderer thread on iOS, so surfaces drew
  their background and no cells — the long-standing "empty glyph atlas"
  symptom that kept Belfry iOS on SwiftTerm. Bumped to libxev 7bf2b2f9 (the
  same revision Remux's ghostty fork ships). Rebuild with
  `scripts/build-ghosttykit.sh` — requires zig 0.15.2 exactly (ghostty's
  pinned toolchain; Homebrew's 0.16 refuses).

- **`TerminiRuntime.swift` — HOME/XDG_* pointed at the app container before
  `ghostty_init` (iOS).** Without them ghostty logs `error.NoHomeDir` and has
  no writable config/cache/state dirs. Same setup Ghostty's own iOS app does.

- **`TerminiRuntime.swift` — renderer-health action handled (iOS).**
  `GHOSTTY_ACTION_RENDERER_HEALTH` unhealthy → the surface view rebuilds its
  GPU surface over the same UIView (`rendererHealthChanged`); the host's
  `onRendererRebuild` asks tmux for a repaint (winsize nudge). Terminal state
  doesn't survive (libghostty couples terminal to surface) but the session
  recovers instead of freezing.

- **`TerminiSurfaceView_iOS.swift` — host-owned view support.** The class is
  now `open` with a public designated `init()` (shared runtime) and public
  `bind(controller:)`, so Belfry can subclass it (gestures, focus discipline,
  UITextInput shim) and keep one persistent view per session re-parented
  across SwiftUI remounts. `autoFocusOnAttach` (default true) lets hosts stop
  `didMoveToWindow` from summoning the keyboard.

- **`TerminiSurfaceView_iOS.swift` — render gating (iOS twin of the macOS
  `isRenderVisible` patch).** Hidden warm surfaces pause their CADisplayLink,
  mark the renderer occluded, skip per-output draws, and do one catch-up draw
  on reveal.

- **`TerminiSurfaceView_iOS.swift` — synthesized keys, touch scroll, row
  readback, prewarm.** `sendKey(TerminiTerminalKey)` synthesizes HID-keycode
  press/release pairs through `ghostty_surface_key` (mode-correct arrows/esc/
  tab/etc for the on-screen dock and cursor trackpad); `scrollWheel(deltaY:at:)`
  sends precision wheel deltas at a touch position (single-finger scrollback);
  `rowText(at:)` reads the touched viewport row + column via
  `ghostty_surface_read_text` (long-press link/path detection — iOS builds
  don't export `quicklook_word`); `SurfaceContainerView.prewarmRenderer()`
  warms Metal + font atlas at launch on a throwaway offscreen surface.

- **`Sources/TerminiSSH/TerminiSSHForward.swift` (new) — SSH local forwards
  (`ssh -L` equivalent).** `openLocalForward(targetHost:targetPort:)` binds a
  NIOPosix listener on 127.0.0.1:0 and bridges each accepted connection to a
  `direct-tcpip` child channel with half-close propagation. Two hard-won
  details: the listener must be NIOPosix, not NIOTS (Network.framework
  delivers a phantom EOF after the first read on loopback accepts, poisoning
  the tunnel), and forwarded writes flush per-write (channelReadComplete
  doesn't reliably propagate out of NIOSSH child channels). Live-verified by
  `Tests/TerminiSSHTests/LocalForwardLiveTests.swift` (env-gated; skips
  without TERMINI_LIVE_SSH_* configuration).
