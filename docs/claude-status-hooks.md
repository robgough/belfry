# Claude Code status in the Belfry sidebar

Belfry shows a per-window status chip (icon **and** word) for what Claude Code is doing:

| Chip | Meaning |
|---|---|
| grey `✦ Idle` | Claude is **running** in this window (best-effort, no setup) |
| blue `⠋ Working` (braille spinner) | Claude is **working** (needs hooks, below) |
| purple `⠋ Agents` (braille spinner) | Claude's turn ended but **background tasks or agents are still running** — it will resume on its own, so it's *not* your turn (needs hooks) |
| amber `? Waiting` (pulsing) | Claude is **waiting for you** — finished its turn or needs input (needs hooks) |
| — | no Claude here |

When any window is *waiting for you*, Belfry also shows a count on its Dock icon.
**Agents** windows deliberately don't badge the Dock — nothing needs you there yet.

## How it works

Belfry's control connection reads two things per window over tmux:

- `pane_current_command` — if the foreground process is `claude`, Belfry shows the
  dim "running" sparkle. (It deliberately does **not** match a bare `node`, which is
  too ambiguous — so if your Claude launches as `node`, you'll only get the precise
  states below.)
- a `@claude_state` window option — set precisely by Claude Code **hooks**. When
  present it wins, giving the exact **working** / **waiting** states.

## Enabling the precise states (recommended)

**Easiest:** right-click a host in Belfry's sidebar → **Install Claude Status Hooks…**.
Belfry merges the hooks below into that host's `~/.claude/settings.json` (local or over
SSH), preserving your other settings/hooks, idempotently, with a backup at
`settings.json.belfry-bak`. The same menu shows whether they're already installed, and offers
**Remove Claude Status Hooks** to strip just Belfry's entries again (your other settings and
hooks are left untouched). Hooks apply to **new** Claude sessions, so restart any running
`claude` after installing or removing.

Or add them by hand — these stamp the current tmux window with Claude's state; Belfry
reads it. They no-op when you're not inside tmux.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] && tmux set -w @claude_state working" } ] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] && tmux set -w @claude_state working" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] && tmux set -w @claude_state waiting" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; s=$(cat); c=$(printf '%s' \"$s\" | tr -d '[:space:]'); case \"$c\" in *'\"background_tasks\":[]'*) st=waiting;; *'\"background_tasks\":['*) st=background;; *) st=waiting;; esac; tmux set -w @claude_state \"$st\"" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] && tmux set -uw @claude_state" } ] }
    ]
  }
}
```

- **UserPromptSubmit / PreToolUse** → `working` (you sent a prompt / Claude is running a tool).
- **Notification** → `waiting` (Claude wants input or a permission).
- **Stop** → `waiting` when Claude finished its turn, **or `background`** if its stdin JSON
  still lists `background_tasks` (a background bash command or background agent is running and
  will auto-resume Claude). This is detected in pure POSIX `sh` — no `jq`/Python — so it works
  over plain SSH too.
- **SessionEnd** → clears the option when Claude exits (so the badge disappears).
  (Belfry also clears the badge on its own if the window drops back to a plain shell,
  in case `SessionEnd` doesn't fire.)

## Remote hosts

The hook runs wherever Claude runs, so add the same hooks to the Claude settings on
each **remote** machine you connect to. It sets `@claude_state` on that host's tmux
window, which Belfry reads over that host's control connection — so remote sessions
get the same badges.

## Notes

- Belfry polls window state ~every 1.5s, so a state change shows within a second or two.
- Detection is per **window**, from its active pane. If you run Claude in a background
  split pane, the precise states still work (the option is window-level) but the
  "running" fallback only sees the active pane.
