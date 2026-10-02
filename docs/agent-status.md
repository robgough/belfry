# Coding-agent status in the Belfry sidebar

Belfry shows what the coding agents in your tmux panes are doing — **Claude Code,
Codex, OpenCode, pi and oh-my-pi** — as a status glyph on each window row, and in an
**Agents** section at the top of the sidebar that lists every agent on every
connected host.

| Glyph | Meaning |
|---|---|
| grey still cell | an agent is **running** here (detected without hooks; live state unknown) |
| blue spinner | the agent is **working** |
| purple spinner | its turn ended but **background tasks or sub-agents are still running** — it will resume on its own, so it's *not* your turn |
| green still cell | it **finished its turn** — nothing pending |
| orange pulsing cell | it's **waiting for you** — a permission prompt, a question |
| red still cell | its turn **ended on an error** (rate limit, API failure…) |

When any agent is waiting for you (or stopped on an error), Belfry also shows a count
on its Dock icon. Working, background and idle agents deliberately don't badge the
Dock — nothing is blocked on you there.

## The Agents section and the Agents window

**In the sidebar**, the **Agents** section sits below
**Pinned** and above your hosts whenever at least one agent is running — agents that
need you first, then ones that finished while you weren't looking, then working, then
quiet ones. Each row is two lines: the task (Claude Code's own summary of it, or your
latest prompt), then one live line — what it's doing right now in plain words
(`Run the test suite`, `Editing SessionTreeView.swift`; approvals show the real command
in orange, `Approve Bash: git push`), or for a quiet agent where it lives
(`belfry ⎇ main · belfry`). Uncommitted `+84 −12` and time in state sit on the right.
An agent that just moved up or into a more urgent group glows briefly. ⌘1–⌘9 jump to
the agents in order; clicking one shows its window and focuses its pane.

**The Agents window** (⇧⌘A, or the toolbar's list button) shows every agent on every
host at once in a sortable table, Activity Monitor style: status, task, agent and
session name, folder and branch, host and tmux location, what it's doing now,
sub-agents (hover for their descriptions), permission mode, context in use, tool steps
this turn, uncommitted changes and time in state. Double-click a row to jump the main
window to it.

## Setting it up

Right-click a host in the sidebar → **Install Agent Status Hooks…**. Belfry installs
(locally, or over SSH):

| What | Where | When |
|---|---|---|
| the shared hook script | `~/.belfry/bin/belfry-agent-hook` | always |
| Claude Code hooks | merged into `~/.claude/settings.json` | always |
| Codex hooks | merged into `~/.codex/hooks.json` | if `~/.codex` exists |
| OpenCode plugin | `~/.config/opencode/plugin/belfry-status.js` | if `~/.config/opencode` exists |
| pi extension | `~/.pi/agent/extensions/belfry-status.ts` | if `~/.pi/agent` exists |
| oh-my-pi extension | `~/.omp/agent/extensions/belfry-status.ts` | if `~/.omp/agent` exists |

JSON merges preserve your other settings and hooks, are idempotent, and back the file
up to `<file>.belfry-bak` first. **Remove Agent Status Hooks** in the same menu strips
just Belfry's entries and files again. Hooks apply to **new** agent sessions, so
restart running agents after installing. Installed hooks carry a versioned marker
(`# belfry-status-v5`); when a newer Belfry connects and finds older ones, it silently
reinstalls, so improvements roll out on the next connect.

**Codex** reviews hooks before running them: after installing, approve Belfry's hooks
when Codex asks (or via `/hooks`). Their command text never changes between Belfry
versions — the logic lives in the script — so you only approve them once.

**Without hooks**, Belfry still spots agents from the pane's foreground process (Claude
Code shows up as its version number, e.g. `2.1.284`; `codex`, `opencode`, `pi`, `omp`…)
and reads Claude Code's terminal title — its task summary, and a braille spinner while
it's streaming — so you get the grey "running" glyph, a summary and a coarse working
signal for free.

## How it works

Every integration funnels into one POSIX shell script, `belfry-agent-hook <agent>
<event>`, with the event's JSON on stdin. It maps the event to a state and stamps tmux
**pane options** on the agent's own pane (`$TMUX_PANE`):

| Option | Contents |
|---|---|
| `@agent_kind` | `claude`, `codex`, `opencode`, `pi`, `omp` |
| `@agent_state` | `working`, `waiting`, `background`, `idle`, `error` |
| `@agent_ts` | when the current state began (unix time) |
| `@agent_activity` | the current tool and its target, or what it's waiting on |
| `@agent_summary` | the start of the latest prompt |
| `@agent_name` | the agent's session name (Claude Code's, from `~/.claude/sessions/`) |
| `@agent_diff` | `<insertions> <deletions> <files>` uncommitted vs `HEAD` |
| `@agent_steps` | tool calls so far this turn |
| `@agent_subagents` | sub-agents currently running |
| `@agent_tasks` | running sub-agents as `type: description`, `|`-separated |
| `@agent_mode` | permission mode (`default`, `acceptEdits`, `plan`, `auto`, `bypassPermissions`) |
| `@agent_branch` | git branch of the agent's working directory |
| `@agent_context` | tokens of context in use (Claude Code, read from the transcript's latest usage) |

Belfry's control connection lists every pane with those options and watches them with
a tmux format subscription, so changes arrive within about a second — for local and SSH
hosts alike, with no socket, daemon or extra dependency (the script needs only `sh`,
`sed`, `tr`, `cut`, `head`, `date` and, for the diff, `git`). Because the state is per
**pane**, two agents in one window no longer overwrite each other; the window's glyph
shows whichever needs you most.

Event mapping:

| Harness | working | waiting | idle / done | other |
|---|---|---|---|---|
| Claude Code | UserPromptSubmit, PreToolUse, PostToolUse | PermissionRequest (immediate), Notification `permission_prompt` / elicitation | Stop, Notification `idle_prompt` | Stop with `background_tasks` → background; StopFailure → error; SessionEnd clears |
| Codex | UserPromptSubmit, PreToolUse, PostToolUse | PermissionRequest | Stop, Interrupt | SessionEnd clears |
| OpenCode | `session.status` busy, `tool.execute.before` | `permission.asked`, `question.asked` | `session.status` idle / `session.idle` | `session.error` → error |
| pi / omp | `agent_start`, `tool_execution_start` | `ui_prompt_start` | `agent_settled` | `session_shutdown` clears |

### Reliability notes

- **Esc in Claude Code** fires no `Stop`. Claude's `idle_prompt` notification ~60s
  later resets the pane to idle, so a stuck "working" heals itself; the next prompt
  also resets it. (Codex has a real `Interrupt` event.)
- **Approving a permission** used to leave the pane "waiting" for the whole approved
  command; `PostToolUse` now flips it back to working.
- **API errors** fire `StopFailure`, not `Stop`; they now show as a red error instead
  of a stuck "working".
- **Stale state** — an agent killed without its end event leaves options on the pane.
  Belfry ignores them once a shell (or, for Claude, anything that isn't Claude) is back
  in the foreground, and they vanish with the pane.
- Hooks never block or fail an agent: every command exits 0, bails out immediately
  outside tmux or if the script is missing, has a 10s timeout, and the git diff runs
  detached in the background.

### Compatibility

The script also keeps the pre-v4 window options (`@claude_state`, `@claude_title`)
updated for Claude Code, so older Belfry builds (e.g. an older iOS build) keep their
badges; and this Belfry still reads those options from Claude sessions started before
the hooks were upgraded.
