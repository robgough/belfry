# Claude Code status in the Belfry sidebar

Belfry shows a per-window status chip (icon **and** word) for what Claude Code is doing:

| Chip | Meaning |
|---|---|
| grey `✦ Claude` | Claude is **running** in this window (best-effort, no setup) |
| blue `⠋ Working` (braille spinner) | Claude is **working** (needs hooks, below) |
| purple `⠋ Agents` (braille spinner) | Claude's turn ended but **background tasks or agents are still running** — it will resume on its own, so it's *not* your turn (needs hooks) |
| green `✓ Idle` | Claude **finished its turn** — nothing pending (needs hooks) |
| amber `? Waiting` (pulsing) | Claude is **actively waiting for your input** — e.g. a permission prompt (needs hooks) |
| — | no Claude here |

When any window is *waiting for your input*, Belfry also shows a count on its Dock
icon. **Agents** and **Idle** windows deliberately don't badge the Dock — nothing
is blocked on you there.

## How it works

Belfry's control connection reads two things per window over tmux:

- `pane_current_command` — if the foreground process is `claude`, Belfry shows the
  dim "running" sparkle. (It deliberately does **not** match a bare `node`, which is
  too ambiguous — so if your Claude launches as `node`, you'll only get the precise
  states below.)
- a `@claude_state` window option — set precisely by Claude Code **hooks**. When
  present it wins, giving the exact **working** / **idle** / **waiting** states.

The same hooks also mirror the Claude Code **session name** (e.g. `belfry-60`, or
whatever you named the session) into a `@claude_title` window option, looked up in
Claude Code's session registry (`~/.claude/sessions/<pid>.json`) by the `session_id`
each hook payload carries. Belfry shows it on pinned rows and in the status chip's
tooltip. Older Claude Codes without the registry simply never set it.

## Enabling the precise states (recommended)

**Easiest:** right-click a host in Belfry's sidebar → **Install Claude Status Hooks…**.
Belfry merges the hooks below into that host's `~/.claude/settings.json` (local or over
SSH), preserving your other settings/hooks, idempotently, with a backup at
`settings.json.belfry-bak`. The same menu shows whether they're already installed, and offers
**Remove Claude Status Hooks** to strip just Belfry's entries again (your other settings and
hooks are left untouched). Hooks apply to **new** Claude sessions, so restart any running
`claude` after installing or removing.

Belfry tags each installed command with a versioned marker (`# belfry-status-v3`). When a
newer Belfry connects and finds hooks tagged with an older marker, it silently reinstalls
them, so command changes roll out to existing installs on the next connect.

Or add them by hand — these stamp the current tmux window with Claude's state; Belfry
reads it. They no-op when you're not inside tmux.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; s=$(cat); tmux set -w @claude_state working; sid=$(printf '%s' \"$s\" | tr -d '[:space:]' | sed -n 's/.*\"session_id\":\"\\([^\"]*\\)\".*/\\1/p'); if [ -n \"$sid\" ]; then t=$(grep -h \"\\\"sessionId\\\":\\\"$sid\\\"\" \"$HOME\"/.claude/sessions/*.json 2>/dev/null | sed -n 's/.*\"name\":\"\\([^\"]*\\)\".*/\\1/p' | head -1 | tr -d '\\\\\\t\\r\\n' | cut -c1-80); if [ -n \"$t\" ]; then tmux set -w @claude_title \"$t\"; fi; fi;" } ] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; s=$(cat); tmux set -w @claude_state working; sid=$(printf '%s' \"$s\" | tr -d '[:space:]' | sed -n 's/.*\"session_id\":\"\\([^\"]*\\)\".*/\\1/p'); if [ -n \"$sid\" ]; then t=$(grep -h \"\\\"sessionId\\\":\\\"$sid\\\"\" \"$HOME\"/.claude/sessions/*.json 2>/dev/null | sed -n 's/.*\"name\":\"\\([^\"]*\\)\".*/\\1/p' | head -1 | tr -d '\\\\\\t\\r\\n' | cut -c1-80); if [ -n \"$t\" ]; then tmux set -w @claude_title \"$t\"; fi; fi;" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; s=$(cat); c=$(printf '%s' \"$s\" | tr -d '[:space:]'); case \"$c\" in *'\"notification_type\":\"idle_prompt\"'*) st=idle;; *) st=waiting;; esac; tmux set -w @claude_state \"$st\"; sid=$(printf '%s' \"$s\" | tr -d '[:space:]' | sed -n 's/.*\"session_id\":\"\\([^\"]*\\)\".*/\\1/p'); if [ -n \"$sid\" ]; then t=$(grep -h \"\\\"sessionId\\\":\\\"$sid\\\"\" \"$HOME\"/.claude/sessions/*.json 2>/dev/null | sed -n 's/.*\"name\":\"\\([^\"]*\\)\".*/\\1/p' | head -1 | tr -d '\\\\\\t\\r\\n' | cut -c1-80); if [ -n \"$t\" ]; then tmux set -w @claude_title \"$t\"; fi; fi;" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; s=$(cat); c=$(printf '%s' \"$s\" | tr -d '[:space:]'); case \"$c\" in *'\"background_tasks\":[]'*) st=idle;; *'\"background_tasks\":['*) st=background;; *) st=idle;; esac; tmux set -w @claude_state \"$st\"; sid=$(printf '%s' \"$s\" | tr -d '[:space:]' | sed -n 's/.*\"session_id\":\"\\([^\"]*\\)\".*/\\1/p'); if [ -n \"$sid\" ]; then t=$(grep -h \"\\\"sessionId\\\":\\\"$sid\\\"\" \"$HOME\"/.claude/sessions/*.json 2>/dev/null | sed -n 's/.*\"name\":\"\\([^\"]*\\)\".*/\\1/p' | head -1 | tr -d '\\\\\\t\\r\\n' | cut -c1-80); if [ -n \"$t\" ]; then tmux set -w @claude_title \"$t\"; fi; fi;" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "[ -n \"$TMUX\" ] || exit 0; tmux set -uw @claude_state; tmux set -uw @claude_title" } ] }
    ]
  }
}
```

- **UserPromptSubmit / PreToolUse** → `working` (you sent a prompt / Claude is running a tool).
- **Notification** → `waiting` (Claude wants input or a permission) — **except** the
  `idle_prompt` nudge that fires ~60s after a finished turn (detected via
  `"notification_type":"idle_prompt"` in its stdin JSON), which (re)sets `idle`:
  the turn is simply over, nothing is blocked on you.
- **Stop** → `idle` when Claude finished its turn (nothing pending), **or `background`**
  if its stdin JSON still lists `background_tasks` (a background bash command or background
  agent is running and will auto-resume Claude). This is detected in pure POSIX `sh` —
  no `jq`/Python — so it works over plain SSH too.
- Every state hook also looks up the session's `name` in `~/.claude/sessions/*.json`
  by the payload's `session_id` and mirrors it into `@claude_title` (backslashes,
  tabs and newlines stripped, capped at 80 bytes, so it can't break Belfry's
  TAB-separated window parsing). Nothing is set if the lookup finds nothing.
- **SessionEnd** → clears both options when Claude exits (so the badge disappears).
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
