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
#   @agent_tasks     running sub-agents, "<id> <model>,<effort> type: description|…"
#                    (<id> "+" until started; model/effort "-" until known)
#   @agent_tasks_gone recently stopped sub-agents, kept to relabel one that resumes
#   @agent_mode      permission mode (default, acceptEdits, plan, auto, …)
#   @agent_branch    git branch of its cwd
#   @agent_context   tokens of context in use (Claude Code, from the transcript)
#   @agent_model     model of its latest reply ("claude-opus-5-5")
#   @agent_effort    thinking effort of its latest reply (low/medium/high/max)
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
# jhead KEY — like jget, but only among the event's own fields, before any
# tool input/response (whose arguments can carry a "model" of their own).
jhead() {
  h=${c%%'"tool_input"'*}; h=${h%%'"tool_response"'*}
  printf '%s' "$h" | sed -n -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n 1
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

st= act= sum= diff= keepact= step= reset= taskadd= taskdel= tasksclear= ctx= seen= gone= lid= mdl= eff=
# Sub-agent launches: the Task/Agent tool call carries the job's description
# and type ("general-purpose: Audit the parser"), which SubagentStart doesn't.
tn=$(jget tool_name)
case $tn in Task|Agent|task|agent|spawn_agent)
  x=$(clean "$(jget description)" 70 | tr '|' '/'); y=$(jget subagent_type)
  [ -n "$x" ] && task=$(clean "${y:-general-purpose}: $x" 90 | tr '|' '/') ;;
esac
# Claude Code stamps agent_id (and agent_type) on every event that fires
# inside a sub-agent, so any sign of life (re)lists it — including one that
# resumes after its own background work woke it, which fires no SubagentStart.
aid=$(jget agent_id | tr -cd 'A-Za-z0-9_-')
tp=$(jget transcript_path)
# Model and effort, when the event carries them: Claude Code's SessionStart,
# every Codex hook (model), the OpenCode / pi / omp plugins (both; effort "-"
# for "none"). On a sub-agent's event they're the sub-agent's (below).
if [ -z "$aid" ]; then mdl=$(jhead model); eff=$(jhead effort); fi
atype=$(clean "$(jget agent_type)" 40 | tr -d '|:')
[ -n "$aid" ] && seen=1
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
    keepact=1 ;;
  SubagentStop)
    # Also fires when a sub-agent pauses on background work of its own; if it
    # resumes, its next tool call lists it again (description from @agent_tasks_gone).
    keepact=1; seen=; [ -n "$aid" ] && gone=1 ;;
  PermissionRequest)
    st=waiting; act="Approve $(describe)" ;;
  PostToolUse|PostToolUseFailure)
    # Re-describe the tool: after an approval the activity still read
    # "Approve …" while the approved tool ran.
    st=working; act=$(human); ctx=1
    editlike && diff=1
    # A foreground sub-agent's tool call returns when it finishes; a background
    # one returns at launch, with its agent id — which pins the description to
    # the right id when several of one type launched at once.
    if [ -n "$task" ]; then
      case $(printf '%s' "$c" | tr -d ' ') in
        *'"status":"async_launched"'*|*'"run_in_background":true'*)
          lid=$(jget agentId | tr -cd 'A-Za-z0-9_-') ;;
        *) taskdel=1 ;;
      esac
    fi ;;
  Notification)
    case $(jget notification_type) in
      idle_prompt) st=idle; act=-; tasksclear=1 ;;  # ~60s after a turn ends (also heals a missed Stop)
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
    [ "$st" = idle ] && { act=-; tasksclear=1; }
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
  meta)          # a plugin reporting a model / effort change, nothing more
    keepact=1 ;;
  SessionEnd|end)
    tmux set -pu -t "$p" @agent_kind \; set -pu -t "$p" @agent_state \; \
         set -pu -t "$p" @agent_ts \; set -pu -t "$p" @agent_activity \; \
         set -pu -t "$p" @agent_summary \; set -pu -t "$p" @agent_name \; \
         set -pu -t "$p" @agent_diff \; set -pu -t "$p" @agent_steps \; \
         set -pu -t "$p" @agent_subagents \; set -pu -t "$p" @agent_tasks \; \
         set -pu -t "$p" @agent_tasks_gone \; set -pu -t "$p" @agent_model \; \
         set -pu -t "$p" @agent_effort \; \
         set -pu -t "$p" @agent_mode \; set -pu -t "$p" @agent_branch \; \
         set -pu -t "$p" @agent_context >/dev/null 2>&1
    [ "$agent" = claude ] && tmux set -uw -t "$p" @claude_state \; set -uw -t "$p" @claude_title >/dev/null 2>&1
    exit 0 ;;
  *) exit 0 ;;
esac

# Accumulate every option write into ONE tmux invocation (fewer forks on the
# hot PreToolUse path, and the pane's options change together).
#
# Hooks for one pane run concurrently (parallel tool calls, sub-agents working
# side by side), and below is a read-modify-write of its counters and sub-agent
# list — so it holds a per-pane lock, or two launches at once leave one
# unlisted. mkdir is the portable atomic test-and-set; a lock left by a killed
# hook is broken after ~1s rather than wedging the agent.
lk="${TMPDIR:-/tmp}/belfry-agent-hook-$(id -u)-$(printf '%s' "$TMUX" | cut -d, -f2)-${p#%}.lock"
i=0
until mkdir "$lk" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 50 ]; then rmdir "$lk" 2>/dev/null; mkdir "$lk" 2>/dev/null; break; fi
  sleep 0.02 2>/dev/null || i=$((i + 10))
done
trap 'rmdir "$lk" 2>/dev/null' EXIT

# One read of the pane's current state, counters and sub-agent lists (TAB-
# separated; the running list, last, is "<id> type: description|…").
tab=$(printf '\t')
cur=$(tmux display -p -t "$p" "#{@agent_state}$tab#{@agent_steps}$tab#{@agent_subagents}$tab#{@agent_tasks_gone}$tab#{@agent_tasks}" 2>/dev/null)
old=${cur%%"$tab"*}; rest=${cur#*"$tab"}; steps=${rest%%"$tab"*}; rest=${rest#*"$tab"}
subs=${rest%%"$tab"*}; rest=${rest#*"$tab"}; gonel=${rest%%"$tab"*}; tasks=${rest#*"$tab"}
[ "$tasks" = "$rest" ] && tasks=
case $steps in ''|*[!0-9]*) steps=0 ;; esac

set -- set -p -t "$p" @agent_kind "$agent"
if [ -n "$st" ]; then
  [ "$old" = "$st" ] || set -- "$@" \; set -p -t "$p" @agent_ts "$(date +%s)"
  set -- "$@" \; set -p -t "$p" @agent_state "$st"
fi
# Tool steps this turn.
if [ -n "$reset" ]; then steps=0; set -- "$@" \; set -p -t "$p" @agent_steps 0; fi
if [ -n "$step" ]; then set -- "$@" \; set -p -t "$p" @agent_steps "$((steps + 1))"; fi

# Running sub-agents: "<id> <model>,<effort> <type>: <description>|…", where
# <id> is Claude Code's agent_id, or "+" from the Agent tool call until
# SubagentStart (which lacks the description) claims it, and <model> /
# <effort> are "-" until known. @agent_subagents is the list's length.
# @agent_tasks_gone keeps the last few stopped entries, for one that resumes.
#
# entry E — split an entry into $eid, $em ("model,effort") and $b ("type: description").
entry() {
  case $1 in *' '*) eid=${1%% *}; r=${1#* } ;; *) eid=:; r=$1 ;; esac
  case $eid in *:*) eid=+; r=$1 ;; esac          # pre-v7: "type: description"
  em=${r%% *}
  case $em in *:*|"$r") em=-,-; b=$r ;; *,*) b=${r#* } ;; *) em=-,-; b=$r ;; esac
}
# safe TEXT — a model id or effort, reduced to characters that need no care.
safe() { printf '%s' "$1" | sed -e 's/\[/-/g' -e 's#[^A-Za-z0-9._/-]##g' | cut -c1-64; }
# A sub-agent's model and effort: what its own transcript's latest reply used,
# else (before its first reply) the model it was launched with.
sm= se= sb=
if [ -n "$aid" ] && [ "$agent" != claude ]; then
  sm=$(safe "$(jhead model)"); se=$(safe "$(jhead effort)")
elif [ -n "$aid" ]; then
  case $tp in */agent-"$aid".jsonl) sf=$tp ;; *) sf=${tp%.jsonl}/subagents/agent-$aid.jsonl ;; esac
  if [ -f "$sf" ]; then
    l=$(tail -n 30 "$sf" 2>/dev/null | grep '"message":{"model":"' | tail -n 1)
    sm=$(safe "$(printf '%s' "$l" | sed -n 's/.*"message":{"model":"\([^"]*\)".*/\1/p')")
    se=$(safe "$(printf '%s' "$l" | sed -n 's/.*"effort":"\([^"]*\)".*/\1/p')")
  fi
  # Claude Code's record of the launch: the exact type and description (so
  # the entry needn't be guessed from the pending launches), and its model.
  mj=$(head -c 8192 "${sf%.jsonl}.meta.json" 2>/dev/null | tr '\n\r\t' '   ')
  if [ -n "$mj" ]; then
    mget() { printf '%s' "$mj" | sed -n -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | head -n 1; }
    x=$(clean "$(mget description)" 70 | tr '|' '/'); y=$(clean "$(mget agentType)" 40 | tr -d '|:')
    [ -n "$x" ] && sb=$(clean "${y:-${atype:-general-purpose}}: $x" 90 | tr '|' '/')
    [ -n "$sm" ] || sm=$(safe "$(mget model)")
  fi
fi
# The Agent tool call's own model choice ("haiku"), for the pending entry.
pm=; [ -n "$taskadd" ] && pm=$(safe "$(jget model)")
# meta — $em with whatever $sm/$se now know.
meta() { em="${sm:-${em%%,*}},${se:-${em#*,}}"; }

nt= gl=$gonel present= pt= paired= dropped=
if [ -n "$tasksclear" ]; then
  gl=
else
  oifs=$IFS; IFS='|'
  # Is the sub-agent listed yet, and is a launch of its type waiting for it?
  # And a background launch whose id SubagentStart already paired, perhaps
  # with a sibling's description: swap the descriptions back below.
  ptm= lold= lhit= claimed=
  for e in $tasks; do
    entry "$e"
    [ -n "$aid" ] && [ "$eid" = "$aid" ] && present=1
    [ "$eid" = + ] && { [ "$b" = "$atype" ] || [ "${b%%:*}" = "$atype" ]; } && ptm=1
    [ -n "$sb" ] && [ "$eid" = + ] && [ "$b" = "$sb" ] && ptm=1
    [ -n "$lid" ] && [ "$eid" = "$lid" ] && { lhit=1; lold=$b; }
  done
  if [ -n "$seen" ] && [ -z "$present" ]; then
    if [ -n "$sb" ]; then pt=$sb                      # its own launch, exactly
    elif [ -n "$ptm" ]; then pt=$atype; elif [ "$ev" = SubagentStart ]; then pt='*'; fi
  fi
  for e in $tasks; do
    entry "$e"
    if [ -n "$gone" ] && [ "$eid" = "$aid" ]; then gl="$eid $em $b${gl:+|$gl}"; continue; fi
    if [ -n "$taskdel" ] && [ -z "$dropped" ] && [ "$eid" = + ] && [ "$b" = "$task" ]; then dropped=1; continue; fi
    if [ -n "$lid" ]; then
      if [ "$eid" = "$lid" ]; then
        b=$task
      elif [ -z "$claimed" ] && [ "$eid" = + ] && [ "$b" = "$task" ]; then
        # This launch's own pending entry: it becomes the agent, or — when
        # SubagentStart already listed the agent — goes. (The description
        # that agent was wrongly given is fixed by its rightful owner's claim.)
        claimed=1
        if [ -n "$lhit" ]; then continue; fi
        eid=$lid; lhit=1
      fi
    fi
    if [ -n "$pt" ] && [ -z "$paired" ] && [ "$eid" = + ]; then
      if [ -n "$sb" ]; then [ "$b" = "$sb" ] && { eid=$aid; paired=1; }
      else case $b in $pt|$pt:*) eid=$aid; paired=1 ;; esac; fi
    elif [ -n "$sb" ] && [ -n "$present" ] && [ "$eid" = + ] && [ "$b" = "$sb" ] && [ -z "$paired" ]; then
      paired=1; continue   # a leftover of its launch: it's already listed
    fi
    if [ -n "$seen" ] && [ "$eid" = "$aid" ]; then meta; [ -n "$sb" ] && b=$sb; fi
    nt="${nt:+$nt|}$eid $em $b"
  done
  if [ -n "$seen" ] && [ -z "$present" ] && [ -z "$paired" ]; then
    eid=$aid em=-,- b=${atype:-agent}
    for e in $gl; do entry "$e"; [ "$eid" = "$aid" ] && break; eid=$aid em=-,- b=${atype:-agent}; done
    meta; [ -n "$sb" ] && b=$sb
    nt="${nt:+$nt|}$aid $em $b"
  fi
  IFS=$oifs
  [ -n "$lid" ] && [ -z "$lhit" ] && nt="${nt:+$nt|}$lid -,- $task"
  [ -n "$taskadd" ] && nt="${nt:+$nt|}+ ${pm:--},- $task"
  [ -n "$gone" ] && gl=$(printf '%s' "$gl" | cut -d'|' -f1-6)
fi
if [ "$nt" != "$tasks" ]; then
  if [ -n "$nt" ]; then set -- "$@" \; set -p -t "$p" @agent_tasks "$nt"
  else set -- "$@" \; set -pu -t "$p" @agent_tasks; fi
fi
n=0; oifs=$IFS; IFS='|'; for e in $nt; do n=$((n + 1)); done; IFS=$oifs
[ "$n" = "$subs" ] || set -- "$@" \; set -p -t "$p" @agent_subagents "$n"
if [ "$gl" != "$gonel" ]; then
  if [ -n "$gl" ]; then set -- "$@" \; set -p -t "$p" @agent_tasks_gone "$gl"
  else set -- "$@" \; set -pu -t "$p" @agent_tasks_gone; fi
fi
# Permission mode (default / acceptEdits / plan / auto / bypassPermissions).
m=$(jget permission_mode)
[ -n "$m" ] && set -- "$@" \; set -p -t "$p" @agent_mode "$m"
mdl=$(safe "$mdl"); eff=$(safe "$eff")
[ -n "$mdl" ] && set -- "$@" \; set -p -t "$p" @agent_model "$mdl"
if [ "$eff" = - ]; then set -- "$@" \; set -pu -t "$p" @agent_effort
elif [ -n "$eff" ]; then set -- "$@" \; set -p -t "$p" @agent_effort "$eff"
fi
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
rmdir "$lk" 2>/dev/null; trap - EXIT

# Context in use: the latest main-thread token usage in the transcript
# (input + cache reads + cache writes), off the hook's critical path.
if [ "$agent" = claude ] && [ -n "$ctx" ] && [ -f "$tp" ]; then
  (
    u=$(tail -n 60 "$tp" 2>/dev/null | grep '"usage"' | grep -v '"isSidechain":true' | tail -n 1 | tr -d ' ')
    [ -n "$u" ] || exit 0
    n(){ printf '%s' "$u" | sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p" | head -n 1; }
    a=$(n input_tokens); b=$(n cache_read_input_tokens); c2=$(n cache_creation_input_tokens)
    mo=$(safe "$(printf '%s' "$u" | sed -n 's/.*"message":{"model":"\([^"]*\)".*/\1/p')")
    ef=$(safe "$(printf '%s' "$u" | sed -n 's/.*"effort":"\([^"]*\)".*/\1/p')")
    set -- set -p -t "$p" @agent_context "$(( ${a:-0} + ${b:-0} + ${c2:-0} ))"
    [ -n "$mo" ] && set -- "$@" \; set -p -t "$p" @agent_model "$mo"
    if [ -n "$ef" ]; then set -- "$@" \; set -p -t "$p" @agent_effort "$ef"
    else set -- "$@" \; set -pu -t "$p" @agent_effort; fi
    tmux "$@"
  ) </dev/null >/dev/null 2>&1 &
fi

# Codex: effort (and model) from the rollout's latest turn_context, which it
# writes as each turn starts — read once a turn, off the critical path.
if [ "$agent" = codex ] && [ -z "$aid" ] && [ -f "$tp" ]; then
  case $ev in SessionStart|UserPromptSubmit|Stop)
    (
      [ "$ev" = UserPromptSubmit ] && sleep 1   # its turn_context lands just after
      l=$(grep '"type":"turn_context"' "$tp" 2>/dev/null | tail -n 1)
      [ -n "$l" ] || exit 0
      mo=$(safe "$(printf '%s' "$l" | sed -n 's/.*"model":"\([^"]*\)".*/\1/p')")
      ef=$(safe "$(printf '%s' "$l" | sed -n 's/.*"effort":"\([^"]*\)".*/\1/p')")
      set -- set -p -t "$p" @agent_kind codex
      [ -n "$mo" ] && set -- "$@" \; set -p -t "$p" @agent_model "$mo"
      [ -n "$ef" ] && set -- "$@" \; set -p -t "$p" @agent_effort "$ef"
      tmux "$@"
    ) </dev/null >/dev/null 2>&1 &
  esac
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
  // Child sessions are sub-agents (the task tool's): id → type ("explore").
  // They're reported as such, with their own model, and stop on going idle.
  const children = new Map()
  const child = (sid) => children.has(sid) ? { agent_id: sid, agent_type: children.get(sid) } : null
  const stopChild = (sid) => {
    const c = child(sid)
    if (c) { children.delete(sid); report("SubagentStop", c) }
  }
  // The model and effort ("variant": low / high / max …; "-" when none).
  const meta = (input) => ({ model: input?.model?.modelID ?? "", effort: input?.variant ?? "-" })
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
      const c = child(input?.sessionID)
      if (c) { report("meta", { ...c, ...meta(input) }); return }
      if (text) { last = "working"; report("prompt", { prompt: text, ...meta(input) }) }
      else { report("meta", meta(input)); publish() }
    },
    "tool.execute.before": async (input, output) => {
      if (input?.sessionID) busy.add(input.sessionID)
      const a = output?.args ?? {}
      last = "working"
      report("tool", { tool_name: input?.tool ?? "tool", file_path: a.filePath ?? a.path ?? "", command: a.command ?? "",
                       description: a.description ?? "", url: a.url ?? "", subagent_type: a.subagent_type ?? "",
                       ...(child(input?.sessionID) ?? {}) })
    },
    "tool.execute.after": async (input) => {
      if (/edit|write|patch/i.test(input?.tool ?? "")) report("edited", { tool_name: input.tool })
    },
    event: async ({ event }) => {
      const props = event?.properties ?? {}
      const sid = props.sessionID ?? props.info?.id
      switch (event?.type) {
        case "session.created": {
          const info = props.info ?? {}
          if (!info.id || !info.parentID) break
          // The task tool titles them "<description> (@<agent> subagent)".
          const type = /\(@([^)\s]+) subagent\)\s*$/.exec(info.title ?? "")?.[1] ?? "subagent"
          children.set(info.id, type)
          report("SubagentStart", { agent_id: info.id, agent_type: type })
          break
        }
        case "session.status": {
          const kind = typeof props.status === "string" ? props.status : props.status?.type
          if (!sid || !kind) break
          if (kind === "idle") { busy.delete(sid); stopChild(sid) } else busy.add(sid)
          publish()
          break
        }
        case "session.idle":
          if (sid) { busy.delete(sid); blocked.delete(sid); stopChild(sid) }
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
          if (sid) { busy.delete(sid); blocked.delete(sid); stopChild(sid) }
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
  // The model and thinking level, sent with every report ("-": thinking off).
  const level = (ctx) => {
    try { return ctx?.thinkingLevel ?? pi.getThinkingLevel?.() } catch { return undefined }
  }
  const meta = (ctx, model = ctx?.model, lvl = level(ctx)) => {
    const f = {}
    if (model?.id) f.model = String(model.id)
    if (lvl) f.effort = lvl === "off" ? "-" : String(lvl)
    return f
  }

  pi.on("session_start", (_event, ctx) => {
    tui = ctx?.mode === undefined || ctx?.mode === "tui"
    if (tui) report(ctx?.isIdle?.() === false ? "working" : "idle", meta(ctx))
  })
  pi.on("input", (event, ctx) => {
    if (tui && typeof event?.text === "string" && event.text.trim()) report("prompt", { prompt: event.text, ...meta(ctx) })
  })
  pi.on("agent_start", (_event, ctx) => { if (tui) report("working", meta(ctx)) })
  pi.on("tool_execution_start", (event, ctx) => {
    if (!tui) return
    const a = event?.args ?? {}
    report("tool", { tool_name: event?.toolName ?? "tool", file_path: a.path ?? a.file_path ?? "", command: a.command ?? "", description: a.description ?? "", url: a.url ?? "", ...meta(ctx) })
  })
  // Switching model or thinking level mid-session (not every build has these).
  try { pi.on("model_select", (event, ctx) => { if (tui) report("meta", meta(ctx, event?.model)) }) } catch {}
  try { pi.on("thinking_level_select", (event, ctx) => { if (tui) report("meta", meta(ctx, ctx?.model, event?.level)) }) } catch {}
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
