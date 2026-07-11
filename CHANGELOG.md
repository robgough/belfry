# Changelog

All notable changes to Belfry are documented here.

## [2026.07.11] — 2026-07-11

macOS release.

### Added

- **Pin sessions and windows.** Hover a session or window row (or right-click
  it) to pin it to a new Pinned section at the top of the sidebar — the
  working set, above the host tree. Pinned rows carry their own context:
  machine name, session, and the active pane's working directory, plus the
  Claude Code session name when Claude is running there. Pins persist across
  restarts and survive tmux-server restarts; a pinned target that goes away
  stays in place dimmed (with the reason) and re-lights when it returns.
  Click the pin glyph to unpin.
- **Claude Code session names.** The status hooks (now v3 — existing installs
  upgrade automatically on connect) mirror the running session's name into
  tmux, so it shows on pinned rows, in tree-row tooltips, and in the title
  bar. Applies to Claude sessions started after the new hooks are in place.
- **Now-playing title bar.** The title bar shows what you're attached to:
  session/window (or Claude session name), host, working directory, and the
  live Claude status chip.

### Changed

- **A finished Claude turn now shows a calm green "Idle", not "Waiting".**
  The amber pulsing "Waiting" chip (and the Dock badge) is reserved for
  turns genuinely blocked on your input, like permission prompts. Running
  Claude sessions pick the fix up on their next restart.

### Fixed

- **New local sessions and windows opened in `/` instead of your home
  directory.** The local tmux server is started by a launchd agent, and
  launchd GUI jobs default their working directory to `/`; the agent plist
  didn't override it, so every detached `new-session`/`new-window` that didn't
  carry its own start directory inherited `/`. The plist now sets
  `WorkingDirectory` to `$HOME`, and the new-session/new-window commands pass an
  explicit `-c` (home for a fresh session, the active pane's path for a new
  window) so they land in the right place even against an already-running
  server.

## [2026.07.10] — 2026-07-08

macOS release.

### Added

- **Install with Homebrew**: `brew tap robgough/belfry && brew install --cask
  belfry` — a notarized, universal cask. Sparkle auto-updates keep working
  alongside `brew upgrade`.

### Fixed

- **Local sessions could hang on "Connecting…" when tmux came from somewhere
  other than Homebrew.** The local control client hard-coded
  `/opt/homebrew/bin/tmux`; if the running tmux server was a different build
  (e.g. a Nix or MacPorts tmux), control mode attached but never completed its
  handshake — an endless spinner. Belfry now drives the local server with *its
  own* binary, the one that started it, so client and server always match.
- **A stalled connect surfaces a reason instead of spinning forever**: if the
  first session list doesn't arrive within a few seconds, the host reports that
  control mode didn't respond — and that Belfry's tmux may be a different build
  than the one running your sessions — rather than an endless "Connecting…".

## [2026.07.9] — 2026-07-04

iPadOS/iOS-only TestFlight release:

### Fixed

- **Bigger touch targets in the sidebar**: window rows are 40pt tall and the
  inline action buttons have finger-sized hit areas (the flattened tree in
  2026.07.8 had left both at pointer sizes).

## [2026.07.8] — 2026-07-04

iPadOS/iOS-only TestFlight release:

### Fixed

- **The sidebar tree looks like a sidebar again on iOS**: session headers no
  longer render as dark rounded cards, the separators between windows are
  gone, and row spacing is compact — one dense host → session → window tree,
  matching the Mac. The selected window gets the same soft theme-accent
  highlight as macOS.

## [2026.07.7] — 2026-07-04

iPadOS/iOS-only TestFlight release fixing two regressions the sidebar rework
(2026.07.5/6) introduced on touch devices:

### Fixed

- **iPhone: selecting a window shows its terminal again.** The reworked
  sidebar broke navigation on compact screens, leaving the terminal
  unreachable from the window list.
- **iPad/iPhone: host header actions are visible.** New-session and
  connect/disconnect buttons were hover-only, which never shows on touch;
  they're now always present on iOS (splits and kills remain in the
  long-press menus).

## [2026.07.6] — 2026-07-04

iPadOS/iOS-only TestFlight release: the 2026.07.4 output-feed deadlock fix
for the terminal view, plus the 2026.07.5 sidebar improvements (machine
grouping, tmux-following selection, session-selector drift recovery).

## [2026.07.5] — 2026-07-04

### Added

- **Sidebar actions on hover** (macOS): hosts get new-session and
  connect/disconnect buttons, sessions get new-window and kill, and windows
  get split left/right, split top/bottom (both open in the pane's current
  directory) and kill — kills always confirm first. Everything is mirrored in
  the right-click menus, where the splits are new too.
- **Collapsible machine groups**: each host is a full-width header band with
  a live session/window count — click anywhere on the band to collapse or
  expand that machine's sessions.

### Fixed

- **Scrolling was far too fast** (macOS): trackpad deltas were fed to the
  terminal engine as whole wheel ticks — one line per pixel of finger travel,
  roughly 30× too fast (and holding ⇧ while scrolling randomly changed the
  speed). Trackpad scrolling is now pixel-accurate with proper inertial
  decay, matching Ghostty; physical mouse wheels still scroll by lines.
- **Sidebar selection follows tmux**: switching windows with tmux keys
  (prefix-n, status-bar clicks) now moves the sidebar highlight along with
  the active-window indicator, instead of leaving it stale — including when
  the selected window is killed.
- **The tmux session selector no longer confuses the app**: choosing another
  session with prefix-s inside a terminal used to leave the surface showing
  one session while the sidebar pointed at another. Belfry now detects the
  move and follows you to the session you picked.
- Sessions with two or more attached clients were shown as detached (tmux
  reports a client *count*, which was read as a yes/no flag).

### Changed

- **Sidebar polish**: window rows show the tmux window index in a small chip
  (the active window's chip is accent-tinted), the selection highlight is a
  soft theme-matched pill instead of the loud system one, and every status
  colour in the chrome now comes from the terminal theme's own palette — one
  green and one amber everywhere. The per-session attach dot is gone (it
  reflected Belfry's internal state, not anything actionable).

## [2026.07.4] — 2026-07-04

### Fixed

- **Permanent beachball (force-quit required) when terminal output flooded
  the app** (macOS): splitting a tmux pane on a fast connection — the local
  host especially — could freeze Belfry for good. Terminal output was handed
  to the embedded terminal engine on the main thread, and one large redraw
  burst carrying many host notifications (tmux with `mouse on` toggles mouse
  modes around every redraw; title/colour changes count too) overflowed the
  engine's 64-slot notification mailbox. That mailbox is only drained on the
  main thread, which was the thread stuck waiting for space: a self-deadlock.
  Output is now fed to the engine from a background queue (its intended
  threading model), so a full mailbox simply waits out the next engine tick.
  The same fix is in the iOS terminal view and ships with the next iOS build.

## [2026.07.3] — 2026-07-03

iPadOS/iOS-only TestFlight release: the on-screen keyboard stays hidden
until explicitly summoned, instead of popping up whenever a session is
selected.

## [2026.07.2] — 2026-07-03

macOS release carrying the changes listed under 2026.07.1: sending files to
Claude Code (drag & drop or the paperclip button) and the clipboard-copy
fix.

## [2026.07.1] — 2026-07-03

First calendar-versioned release (`YYYY.MM.N`, one counter shared by macOS
and iPadOS/iOS) — and the first to ship through TestFlight. This release is
iPadOS/iOS only; the macOS items below reach Mac users with the next macOS
release.

### Added

- **iPadOS/iOS via TestFlight**: the iPad/iPhone app now ships as a
  TestFlight build (previously build-from-source only), with a signed
  archive + upload pipeline to App Store Connect.
- **Send files to Claude Code** (macOS): drag images — or any file — onto the
  terminal, or click the new paperclip toolbar button. The file's path is
  pasted into the prompt (as a bracketed paste, so Claude Code treats it as
  one insertion); on SSH hosts the file is first uploaded over the existing
  multiplexed connection into `~/.cache/belfry/drops/` (self-cleaning after a
  week) and the remote path is pasted instead. Drops accept Finder files,
  file promises (Photos, Safari, the screenshot thumbnail), and raw image
  data from web pages.

### Fixed

- **Copying out of the terminal works** (macOS): ⌘C and Edit ▸ Copy now copy
  the selection, and tmux copy-mode clipboard writes (OSC 52) reach the
  system clipboard. The embedded terminal's clipboard-write path was
  previously a stub, so nothing selected in a Belfry terminal could be
  copied at all.

## [0.3.1] — 2026-07-03

### Fixed

- The menu bar showed two View menus: the font-size commands now live in the
  system View menu (alongside Enter Full Screen) instead of a duplicate.

## [0.3.0] — 2026-07-03

### Added

- **Automatic updates** (macOS): Belfry now updates itself via
  [Sparkle](https://sparkle-project.org). It checks the feed at
  `belfry.robgough.net/appcast.xml`, updates are EdDSA-signed on top of
  notarization, and there's a "Check for Updates…" item in the app menu.
  This is the first release with the updater on board, so 0.2.0 users need
  to grab this one manually — everything after arrives on its own.

## [0.2.0] — 2026-07-02

First public release: a notarized, universal (Apple Silicon + Intel) `Belfry.app`
for macOS 14+. iPadOS/iOS remains build-from-source for now — see the
[README](README.md#ipados--ios-17).

### macOS app

- Sidebar of hosts → sessions → windows, driven by tmux control mode
  (`tmux -C`). On tmux ≥ 3.2 updates arrive by server push (format
  subscriptions); older servers fall back to a light poll.
- One live libghostty terminal surface per visited session; switching sessions
  is a visibility toggle, not a re-attach. Your Ghostty colour theme is applied
  to the terminal *and* the app chrome (Catppuccin Mocha fallback).
- Remote hosts over the system `ssh`: ControlMaster connection sharing (one
  auth per host), keepalives, and a native askpass dialog for passwords,
  passphrases and first-connect host-key fingerprints.
- Claude Code status badges per window (Working / Waiting), with one-click
  install/removal of the optional status hooks per host; the Dock badge counts
  windows waiting for input.
- Sessions outlive the app: the local tmux server runs under launchd, so even
  a force-quit can't take it down. Quit cleans up Belfry's own hidden control
  sessions and nothing else.
- Battery-conscious: hidden surfaces absorb output without rendering, badge
  animations run outside the app process, idle CPU measures ~0%.

### iPadOS / iOS (build from source)

- Same sidebar + terminal UI over in-process SSH (SwiftNIO); tmux runs as SSH
  exec channels — no remote agent to install.
- SwiftTerm rendering with bundled Maple Mono NF for nerd-font glyphs; touch
  scrollback (swipe = tmux copy-mode wheel); key bar with esc/ctrl/arrows.
- Credentials (password or ed25519 key) live in the Keychain and are removed
  with the host. Quick app switches keep connections alive via a background
  grace period; longer absences resync on return.

### Fixed in this release

- Remote hosts whose tmux lives outside the non-interactive shell PATH
  (Homebrew on a Mac host, most commonly) failed with
  `zsh:1: command not found: tmux`. All remote tmux invocations now resolve
  the binary with sensible fallbacks and report a clear "tmux not found on
  this host" when it's genuinely absent.
- Connection-failure reasons in the sidebar are no longer truncated to one
  line — they wrap, with the full diagnostic in a hover tooltip.
