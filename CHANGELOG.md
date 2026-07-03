# Changelog

All notable changes to Belfry are documented here.

## [Unreleased]

### Added

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
