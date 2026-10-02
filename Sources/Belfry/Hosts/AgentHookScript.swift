import Foundation

/// The files Belfry installs on a host so coding agents report their live state
/// (see docs/agent-status.md). Every harness integration funnels into one POSIX
/// shell script, `belfry-agent-hook`, which stamps tmux *pane* options that the
/// control connection already watches — so status works identically for local
/// and SSH hosts (and the iOS app) with no socket, daemon or extra dependency.
///
/// Kept as Swift string literals (not bundle resources) so installing is just
/// "write these bytes" over the same local/SSH transport as the settings merge.
enum AgentHookFiles {
    /// Home-relative install locations.
    static let scriptRelPath = ".belfry/bin/belfry-agent-hook"
    static let openCodePluginRelPath = ".config/opencode/plugin/belfry-status.js"
    static let piExtensionRelPath = ".pi/agent/extensions/belfry-status.ts"
    static let ompExtensionRelPath = ".omp/agent/extensions/belfry-status.ts"

    /// The shared hook script. `AgentHooks.versionedMarker` is spliced into its
    /// header so `check()` can tell an outdated script from a current one.
    static func script(marker: String) -> String {
        scriptTemplate.replacingOccurrences(of: "@MARKER@", with: marker)
    }

    // Notes for editing the script:
    // - POSIX sh + sed/tr/cut/head/date/git only: remote hosts need nothing else.
    // - It must ALWAYS exit 0 quickly — Claude/Codex hooks run synchronously, so
    //   a slow or failing hook stalls or nags the agent. The git diff runs
    //   detached in the background for the same reason.
    // - Values are written as single tmux argv elements, so quoting is safe, but
    //   they must not contain TAB/newline (Belfry's control-mode lines are
    //   TAB-separated) and must not END in ';' (tmux treats a trailing ';' on an
    //   argument as a command separator) — `clean` handles both.
    // - Pane options (`set -p`, tmux ≥ 3.0) are scoped to the agent's own pane,
    //   so two agents in one window no longer overwrite each other, and they
    //   vanish with the pane.
    private static let scriptTemplate = #"""
#!/bin/sh
# belfry-agent-hook — installed by Belfry (@MARKER@). Reinstalling from Belfry
# overwrites this file; remove it via Belfry's host menu ("Remove Agent Status Hooks").
#
# Maps coding-agent lifecycle events onto tmux pane options Belfry's sidebar reads:
#   @agent_kind      claude | codex | opencode | pi | omp
#   @agent_state     working | waiting | background | idle | error
#   @agent_ts        unix time the current state began
#   @agent_activity  what it's doing now ("Edit Foo.swift", "Bash: npm test")
#   @agent_summary   the task (start of the latest prompt)
#   @agent_name      the agent's session name, when it has one
#   @agent_diff      "<insertions> <deletions> <files>" uncommitted vs HEAD in its cwd
#   @agent_steps     tool calls so far this turn
#   @agent_subagents sub-agents currently running
#   @agent_tasks     running sub-agents, "type: description|type: description"
#   @agent_mode      permission mode (default, acceptEdits, plan, auto, …)
#   @agent_branch    git branch of its cwd
#   @agent_context   tokens of context in use (Claude Code, from the transcript)
#
# Usage: belfry-agent-hook <agent> <event>   with the event's JSON on stdin.
# <event> is a Claude Code / Codex hook name (PreToolUse, Stop, …) or a generic
# verb used by the OpenCode / pi plugins: prompt, tool, working, waiting, idle,
# error, edited, end.

agent=$1
ev=$2
s=$(cat 2>/dev/null)   # always drain stdin fully, so the agent never sees EPIPE
[ -n "$TMUX" ] && [ -n "$TMUX_PANE" ] || exit 0
p=$TMUX_PANE
# Field lookups scan a flattened, size-capped copy (Write/Edit payloads carry
# whole files; the fields we want sit near the front).
c=$(printf '%s' "$s" | head -c 65536 | tr '\n\r\t' '   ')

# jget KEY — the (raw, still-escaped) string value of KEY in the event JSON.
jget() {
  printf '%s' "$c" | sed -n -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n 1
}
# clean TEXT [MAX] — unescape the common JSON escapes, drop control characters,
# backslashes and ';', squeeze spaces, cap the length (default 90 bytes).
clean() {
  printf '%s' "$1" | sed -e 's/\\[nrt]/ /g' -e 's/\\"/"/g' \
    | tr -d '\000-\037\\' | tr ';' ',' | tr -s ' ' | sed -e 's/^ //' | cut -c1-"${2:-90}"
}
# describe — a short "Tool target" label for the tool in the event.
describe() {
  t=$(jget tool_name); [ -n "$t" ] || t=$(jget tool); [ -n "$t" ] || t=tool
  f=$(jget file_path); [ -n "$f" ] || f=$(jget filePath); [ -n "$f" ] || f=$(jget notebook_path)
  if [ -n "$f" ]; then clean "$t ${f##*/}"; return; fi
  x=$(jget command); [ -n "$x" ] || x=$(jget pattern); [ -n "$x" ] || x=$(jget url)
  [ -n "$x" ] || x=$(jget description); [ -n "$x" ] || x=$(jget query)
  if [ -n "$x" ]; then clean "$t: $x"; else clean "$t"; fi
}
# human — what the agent is doing, in words ("Run the test suite", "Editing
# Foo.swift") rather than the raw command line, which is noise at a glance.
# Bash-style tools carry a model-written `description`; the rest get a verb.
human() {
  t=$(jget tool_name); [ -n "$t" ] || t=$(jget tool); [ -n "$t" ] || t=tool
  f=$(jget file_path); [ -n "$f" ] || f=$(jget filePath); [ -n "$f" ] || f=$(jget notebook_path)
  [ -n "$f" ] || f=$(jget path)
  f=${f##*/}
  case $t in
    Bash|bash|shell|exec_command|local_shell|BashOutput)
      x=$(jget description)
      if [ -z "$x" ]; then x=$(jget command); x=${x%% *}; x="Running ${x##*/}"; fi
      clean "$x" ;;
    Edit|MultiEdit|edit|multiedit|NotebookEdit|apply_patch|*atch*)
      clean "Editing ${f:-files}" ;;
    Write|write|create) clean "Writing ${f:-a file}" ;;
    Read|read|view|cat) clean "Reading ${f:-files}" ;;
    Grep|Glob|grep|glob|find|search|ls|LS|list) clean "Searching the code" ;;
    WebFetch|webfetch|fetch)
      x=$(jget url | sed -e 's#^[a-zA-Z]*://##' -e 's#/.*##'); clean "Reading ${x:-the web}" ;;
    WebSearch|websearch) clean "Searching the web" ;;
    Task|Agent|task|agent|spawn_agent)
      x=$(jget description); clean "Delegating${x:+: $x}" ;;
    TodoWrite|todowrite|todoread|update_plan) echo "Planning" ;;
    mcp__*) x=${t#mcp__}; clean "Using ${x%%__*}" ;;
    *) clean "Using $t" ;;
  esac
}
editlike() {
  case $(jget tool_name)$(jget tool) in
    *Edit*|*edit*|*Write*|*write*|*atch*|*Notebook*) return 0 ;;
  esac
  return 1
}

st= act= sum= diff= keepact= step= sub= reset= taskadd= taskdel= tasksclear= ctx=
# Sub-agent launches: the Task/Agent tool call carries the job's description
# and type ("general-purpose: Audit the parser"), which SubagentStart doesn't.
tn=$(jget tool_name)
case $tn in Task|Agent|task|agent|spawn_agent)
  x=$(clean "$(jget description)" 70 | tr '|' '/'); y=$(jget subagent_type)
  [ -n "$x" ] && task=$(clean "${y:-agent}: $x" 90 | tr '|' '/') ;;
esac
case $ev in
  SessionStart)
    case $(jget source) in
      compact) keepact=1 ;;          # auto-compaction mid-task: Claude carries on
      clear) st=idle; act=-; sum=- ;;
      *) st=idle; act=- ;;
    esac
    diff=1 ;;
  UserPromptSubmit|prompt)
    st=working; act=Thinking; reset=1; diff=1
    x=$(jget prompt); [ -n "$x" ] || x=$(jget text)
    x=$(clean "$x" 120); [ -n "$x" ] && sum=$x ;;
  PreToolUse|tool)
    st=working; act=$(human); step=1
    [ -n "$task" ] && taskadd=1 ;;
  SubagentStart)
    sub=1; keepact=1 ;;
  SubagentStop)
    sub=-1; keepact=1 ;;
  PermissionRequest)
    st=waiting; act="Approve $(describe)" ;;
  PostToolUse|PostToolUseFailure)
    # Re-describe the tool: after an approval the activity still read
    # "Approve …" while the approved tool ran.
    st=working; act=$(human); ctx=1
    editlike && diff=1
    # A foreground sub-agent's tool call returns when it finishes; a background
    # one returns at launch (it's cleared when the turn ends with nothing left).
    if [ -n "$task" ]; then
      case $(printf '%s' "$c" | tr -d ' ') in *'"run_in_background":true'*) ;; *) taskdel=1 ;; esac
    fi ;;
  Notification)
    case $(jget notification_type) in
      idle_prompt) st=idle; act=- ;;       # ~60s after a turn ends (also heals a missed Stop)
      permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input)
        st=waiting; act=$(clean "$(jget message)") ;;
      elicitation_complete|elicitation_response) st=working; keepact=1 ;;
      '') st=waiting; act=$(clean "$(jget message)") ;;  # older Claude Code: no type
      *) exit 0 ;;                                         # informational only
    esac ;;
  Stop|idle)
    case $(printf '%s' "$s" | tr -d '[:space:]') in
      *'"background_tasks":[]'*) st=idle ;;
      *'"background_tasks":['*) st=background; act="Background tasks running" ;;
      *) st=idle ;;
    esac
    [ "$st" = idle ] && { act=-; sub=0; tasksclear=1; }
    diff=1; ctx=1 ;;
  Interrupt)
    st=idle; act=Interrupted ;;
  StopFailure|error)
    st=error
    x=$(jget error_type); [ -n "$x" ] || x=$(jget message)
    act=$(clean "Error${x:+: $x}") ;;
  working)
    st=working; x=$(clean "$(jget activity)"); if [ -n "$x" ]; then act=$x; else keepact=1; fi ;;
  waiting)
    st=waiting; x=$(clean "$(jget activity)"); act=${x:-"Needs your input"} ;;
  edited)
    diff=1 ;;
  SessionEnd|end)
    tmux set -pu -t "$p" @agent_kind \; set -pu -t "$p" @agent_state \; \
         set -pu -t "$p" @agent_ts \; set -pu -t "$p" @agent_activity \; \
         set -pu -t "$p" @agent_summary \; set -pu -t "$p" @agent_name \; \
         set -pu -t "$p" @agent_diff \; set -pu -t "$p" @agent_steps \; \
         set -pu -t "$p" @agent_subagents \; set -pu -t "$p" @agent_tasks \; \
         set -pu -t "$p" @agent_mode \; set -pu -t "$p" @agent_branch \; \
         set -pu -t "$p" @agent_context >/dev/null 2>&1
    [ "$agent" = claude ] && tmux set -uw -t "$p" @claude_state \; set -uw -t "$p" @claude_title >/dev/null 2>&1
    exit 0 ;;
  *) exit 0 ;;
esac

# Accumulate every option write into ONE tmux invocation (fewer forks on the
# hot PreToolUse path, and the pane's options change together).
# One read of the pane's current state, counters and sub-agent list (TAB-
# separated; the list, last, is "type: description|type: description").
tab=$(printf '\t')
cur=$(tmux display -p -t "$p" "#{@agent_state}$tab#{@agent_steps}$tab#{@agent_subagents}$tab#{@agent_tasks}" 2>/dev/null)
old=${cur%%"$tab"*}; rest=${cur#*"$tab"}; steps=${rest%%"$tab"*}; rest=${rest#*"$tab"}
subs=${rest%%"$tab"*}; tasks=${rest#*"$tab"}
[ "$tasks" = "$rest" ] && tasks=
case $steps in ''|*[!0-9]*) steps=0 ;; esac
case $subs in ''|*[!0-9]*) subs=0 ;; esac

set -- set -p -t "$p" @agent_kind "$agent"
if [ -n "$st" ]; then
  [ "$old" = "$st" ] || set -- "$@" \; set -p -t "$p" @agent_ts "$(date +%s)"
  set -- "$@" \; set -p -t "$p" @agent_state "$st"
fi
# Counters: tool steps this turn, sub-agents in flight.
if [ -n "$reset" ]; then steps=0; set -- "$@" \; set -p -t "$p" @agent_steps 0; fi
if [ -n "$step" ]; then set -- "$@" \; set -p -t "$p" @agent_steps "$((steps + 1))"; fi
case $sub in
  1) set -- "$@" \; set -p -t "$p" @agent_subagents "$((subs + 1))" ;;
  -1) [ "$subs" -gt 0 ] && subs=$((subs - 1)); set -- "$@" \; set -p -t "$p" @agent_subagents "$subs" ;;
  0) set -- "$@" \; set -p -t "$p" @agent_subagents 0 ;;
esac
# Running sub-agents' descriptions.
if [ -n "$tasksclear" ]; then
  [ -n "$tasks" ] && set -- "$@" \; set -pu -t "$p" @agent_tasks
elif [ -n "$taskadd" ] || [ -n "$taskdel" ]; then
  nt= found=
  oifs=$IFS; IFS='|'
  for e in $tasks; do
    if [ "$e" = "$task" ] && [ -z "$found" ]; then found=1; [ -n "$taskadd" ] || continue; fi
    nt=${nt:+$nt|}$e
  done
  IFS=$oifs
  [ -n "$taskadd" ] && [ -z "$found" ] && nt=${nt:+$nt|}$task
  if [ -n "$nt" ]; then set -- "$@" \; set -p -t "$p" @agent_tasks "$nt"
  else set -- "$@" \; set -pu -t "$p" @agent_tasks; fi
fi
# Permission mode (default / acceptEdits / plan / auto / bypassPermissions).
m=$(jget permission_mode)
[ -n "$m" ] && set -- "$@" \; set -p -t "$p" @agent_mode "$m"
if [ "$act" = - ]; then set -- "$@" \; set -pu -t "$p" @agent_activity
elif [ -n "$act" ]; then set -- "$@" \; set -p -t "$p" @agent_activity "$act"
elif [ -z "$keepact" ] && [ -n "$st" ]; then set -- "$@" \; set -pu -t "$p" @agent_activity
fi
if [ "$sum" = - ]; then set -- "$@" \; set -pu -t "$p" @agent_summary
elif [ -n "$sum" ]; then set -- "$@" \; set -p -t "$p" @agent_summary "$sum"
fi

if [ "$agent" = claude ]; then
  # Session name from Claude Code's live-session registry (~/.claude/sessions/<pid>.json).
  sid=$(printf '%s' "$s" | tr -d '[:space:]' | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')
  if [ -n "$sid" ]; then
    n=$(grep -h "\"sessionId\":\"$sid\"" "$HOME"/.claude/sessions/*.json 2>/dev/null \
        | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -n 1)
    n=$(clean "$n" 80)
    [ -n "$n" ] && set -- "$@" \; set -p -t "$p" @agent_name "$n" \; set -w -t "$p" @claude_title "$n"
  fi
  # Legacy window-level state, still read by older Belfry builds (e.g. the iOS app).
  if [ -n "$st" ]; then
    case $st in error) l=idle ;; *) l=$st ;; esac
    set -- "$@" \; set -w -t "$p" @claude_state "$l"
  fi
fi

tmux "$@" >/dev/null 2>&1

# Context in use: the latest main-thread token usage in the transcript
# (input + cache reads + cache writes), off the hook's critical path.
tp=$(jget transcript_path)
if [ -n "$ctx" ] && [ -f "$tp" ]; then
  (
    u=$(tail -n 60 "$tp" 2>/dev/null | grep '"usage"' | grep -v '"isSidechain":true' | tail -n 1 | tr -d ' ')
    [ -n "$u" ] || exit 0
    n(){ printf '%s' "$u" | sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p" | head -n 1; }
    a=$(n input_tokens); b=$(n cache_read_input_tokens); c2=$(n cache_creation_input_tokens)
    tmux set -p -t "$p" @agent_context "$(( ${a:-0} + ${b:-0} + ${c2:-0} ))"
  ) </dev/null >/dev/null 2>&1 &
fi

# Uncommitted change size and branch, computed off the hook's critical path.
if [ -n "$diff" ]; then
  d=$(jget cwd); [ -d "$d" ] || d=$PWD
  (
    cd "$d" 2>/dev/null || exit 0
    x=$(git diff --shortstat HEAD 2>/dev/null) || { tmux set -pu -t "$p" @agent_diff \; set -pu -t "$p" @agent_branch; exit 0; }
    br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\t;')
    [ -n "$br" ] && tmux set -p -t "$p" @agent_branch "$br"
    fl=$(printf '%s' "$x" | sed -n 's/^ *\([0-9][0-9]*\) file.*/\1/p')
    ad=$(printf '%s' "$x" | sed -n 's/.* \([0-9][0-9]*\) insertion.*/\1/p')
    de=$(printf '%s' "$x" | sed -n 's/.* \([0-9][0-9]*\) deletion.*/\1/p')
    un=$(git ls-files --others --exclude-standard 2>/dev/null | head -n 201 | wc -l | tr -d ' ')
    ul=0
    if [ "${un:-0}" -gt 0 ] && [ "$un" -le 20 ]; then
      ul=$(git ls-files -z --others --exclude-standard 2>/dev/null | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')
    fi
    tmux set -p -t "$p" @agent_diff "$(( ${ad:-0} + ${ul:-0} )) ${de:-0} $(( ${fl:-0} + ${un:-0} ))"
  ) </dev/null >/dev/null 2>&1 &
fi
exit 0
"""#

    /// OpenCode plugin (loaded from ~/.config/opencode/plugin/). Tracks every
    /// session it sees — busy if any is busy, waiting if any is blocked on a
    /// permission/question — so a sub-agent's child session finishing can't
    /// flip the pane to idle while its parent is still working.
    static func openCodePlugin(marker: String) -> String {
        openCodeTemplate.replacingOccurrences(of: "@MARKER@", with: marker)
    }

    private static let openCodeTemplate = #"""
// belfry-status — installed by Belfry (@MARKER@); reinstalling overwrites this file.
// Reports OpenCode's live state to Belfry's sidebar via ~/.belfry/bin/belfry-agent-hook.
import { spawn, spawnSync } from "node:child_process"

const HOOK = `${process.env.HOME}/.belfry/bin/belfry-agent-hook`

// Reports run strictly one after another: separate processes racing to set
// the pane's state could land out of order and leave it wrong.
let chain = Promise.resolve()
function report(event, fields = {}) {
  chain = chain.then(() => new Promise((resolve) => {
    try {
      const child = spawn(HOOK, ["opencode", event], { stdio: ["pipe", "ignore", "ignore"] })
      child.on("error", resolve)
      child.on("exit", resolve)
      child.stdin.on("error", () => {})
      child.stdin.end(JSON.stringify(fields))
      setTimeout(resolve, 3000).unref?.()
    } catch { resolve() }
  }))
}

const BelfryStatus = async () => {
  if (!process.env.TMUX || !process.env.TMUX_PANE) return {}
  const busy = new Set()
  const blocked = new Set()
  let last = ""
  const publish = (fields) => {
    const state = blocked.size ? "waiting" : busy.size ? "working" : "idle"
    if (state === last && !fields) return
    last = state
    report(state, fields ?? {})
  }
  process.once("exit", () => {
    try { spawnSync(HOOK, ["opencode", "end"], { input: "{}", stdio: ["pipe", "ignore", "ignore"], timeout: 1000 }) } catch {}
  })
  report("idle")
  return {
    "chat.message": async (input, output) => {
      const text = (output?.parts ?? []).map((p) => (p?.type === "text" ? p.text : "")).join(" ").trim()
      if (input?.sessionID) busy.add(input.sessionID)
      if (text) { last = "working"; report("prompt", { prompt: text }) } else publish()
    },
    "tool.execute.before": async (input, output) => {
      if (input?.sessionID) busy.add(input.sessionID)
      const a = output?.args ?? {}
      last = "working"
      report("tool", { tool_name: input?.tool ?? "tool", file_path: a.filePath ?? a.path ?? "", command: a.command ?? "", description: a.description ?? "", url: a.url ?? "" })
    },
    "tool.execute.after": async (input) => {
      if (/edit|write|patch/i.test(input?.tool ?? "")) report("edited", { tool_name: input.tool })
    },
    event: async ({ event }) => {
      const props = event?.properties ?? {}
      const sid = props.sessionID ?? props.info?.id
      switch (event?.type) {
        case "session.status": {
          const kind = typeof props.status === "string" ? props.status : props.status?.type
          if (!sid || !kind) break
          if (kind === "idle") busy.delete(sid); else busy.add(sid)
          publish()
          break
        }
        case "session.idle":
          if (sid) { busy.delete(sid); blocked.delete(sid) }
          publish()
          break
        case "permission.asked":
        case "permission.updated":
        case "question.asked":
          if (sid) blocked.add(sid)
          last = "waiting"
          report("waiting", { activity: props.title ?? props.permission ?? "Needs your input" })
          break
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
          if (sid) blocked.delete(sid)
          publish()
          break
        case "session.error":
          if (sid) { busy.delete(sid); blocked.delete(sid) }
          last = "error"
          report("error", { message: props.error?.name ?? "session error" })
          break
        case "file.edited":
          report("edited")
          break
        case "session.deleted":
          if (sid) { busy.delete(sid); blocked.delete(sid) }
          publish()
          break
      }
    },
  }
}

export default { id: "belfry.status", server: BelfryStatus }
"""#

    /// pi / oh-my-pi extension (same extension API). TUI sessions only — RPC
    /// and print modes have no pane to report into.
    static func piExtension(agent: String, marker: String) -> String {
        piTemplate
            .replacingOccurrences(of: "@MARKER@", with: marker)
            .replacingOccurrences(of: "@AGENT@", with: agent)
    }

    private static let piTemplate = #"""
// belfry-status — installed by Belfry (@MARKER@); reinstalling overwrites this file.
// Reports @AGENT@'s live state to Belfry's sidebar via ~/.belfry/bin/belfry-agent-hook.
// @ts-nocheck
import { spawn, spawnSync } from "node:child_process"

const HOOK = `${process.env.HOME}/.belfry/bin/belfry-agent-hook`

// Reports run strictly one after another: separate processes racing to set
// the pane's state could land out of order and leave it wrong.
let chain: Promise<unknown> = Promise.resolve()
function report(event: string, fields: Record<string, unknown> = {}) {
  chain = chain.then(() => new Promise((resolve) => {
    try {
      const child = spawn(HOOK, ["@AGENT@", event], { stdio: ["pipe", "ignore", "ignore"] })
      child.on("error", resolve)
      child.on("exit", resolve)
      child.stdin.on("error", () => {})
      child.stdin.end(JSON.stringify(fields))
      setTimeout(resolve, 3000).unref?.()
    } catch { resolve(undefined) }
  }))
}

export default function (pi) {
  if (!process.env.TMUX || !process.env.TMUX_PANE) return
  // A nested agent launched from the parent's shell tool inherits this marker
  // and must not report over the pane's root agent (a reload in the same
  // process still passes: the pid matches).
  const root = process.env.BELFRY_AGENT_ROOT_PID
  if (root && root !== String(process.pid)) return
  process.env.BELFRY_AGENT_ROOT_PID = String(process.pid)
  let tui = false
  let prompts = 0
  let ended = false
  let endDelivered = false

  pi.on("session_start", (_event, ctx) => {
    tui = ctx?.mode === undefined || ctx?.mode === "tui"
    if (tui) report(ctx?.isIdle?.() === false ? "working" : "idle")
  })
  pi.on("input", (event) => {
    if (tui && typeof event?.text === "string" && event.text.trim()) report("prompt", { prompt: event.text })
  })
  pi.on("agent_start", () => { if (tui) report("working") })
  pi.on("tool_execution_start", (event) => {
    if (!tui) return
    const a = event?.args ?? {}
    report("tool", { tool_name: event?.toolName ?? "tool", file_path: a.path ?? a.file_path ?? "", command: a.command ?? "", description: a.description ?? "", url: a.url ?? "" })
  })
  pi.on("tool_execution_end", (event) => {
    if (tui && /edit|write|patch/i.test(event?.toolName ?? "")) report("edited", { tool_name: event.toolName })
  })
  pi.on("ui_prompt_start", (event) => {
    if (!tui) return
    prompts += 1
    report("waiting", { activity: event?.title ?? "Needs your input" })
  })
  pi.on("ui_prompt_end", (_event, ctx) => {
    if (!tui) return
    prompts = Math.max(0, prompts - 1)
    if (prompts === 0) report(ctx?.isIdle?.() === true ? "idle" : "working")
  })
  pi.on("agent_settled", (_event, ctx) => {
    if (tui && prompts === 0 && ctx?.isIdle?.() !== false) report("idle")
  })
  pi.on("session_shutdown", (event) => {
    if (!tui || event?.reason !== "quit") return
    ended = true
    report("end")   // queued behind any in-flight report, so it lands last
    chain.then(() => { endDelivered = true })
  })
  // Fallback if the process exits before the queue drains (Belfry also drops
  // a pane's agent once a shell is back in the foreground).
  process.once("exit", () => {
    if (!tui || !ended || endDelivered) return
    try { spawnSync(HOOK, ["@AGENT@", "end"], { input: "{}", stdio: ["pipe", "ignore", "ignore"], timeout: 1000 }) } catch {}
  })
}
"""#
}
