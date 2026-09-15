#!/bin/bash
# Workflow ETA: PostToolUse hook (async) for Workflow, Agent and Bash.
# When Claude launches background work, record it as a job and ask Haiku how long it will take.
[ -n "$CLAUDE_ETA_HOOK" ] && exit 0
export CLAUDE_ETA_HOOK=1
. "$HOME/.claude/hooks/eta/lib.sh" || exit 0

input=$(cat)
case "$input" in
  *'"tool_name":"Bash"'*) case "$input" in *'"run_in_background":true'*) ;; *) exit 0 ;; esac ;;   # foreground commands are part of the main task
esac
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
tuid=$(printf '%s' "$input" | jq -r '.tool_use_id // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$sid" ] && [ -n "$tuid" ] || exit 0
case "$sid$tuid" in */*|.*) exit 0 ;; esac
dir="$STATE_DIR/$sid"; jd="$dir/jobs"
[ -f "$jd/$tuid.job.json" ] && exit 0
tasks_dir="/private/tmp/claude-$(id -u)/$(basename "$(dirname "$transcript")")/$sid/tasks"

# The job belongs to the task whose turn is running: a task resumed by its job, else the current task.
# If this hook runs late and the launching task already finished, its stop record lists the launch.
parent=""
owner=$(grep -l -F "\"$tuid\"" "$dir"/*.stop.json "$dir"/*.resumed.json 2>/dev/null | head -n 1)
if [ -n "$owner" ]; then parent=$(basename "$owner"); parent="${parent%%.*}"; fi
if [ -z "$parent" ]; then
  parent=$(ls "$dir"/*.resumed.json 2>/dev/null | sort | tail -n 1)
  if [ -n "$parent" ]; then parent=$(basename "$parent" .resumed.json); else parent=$(cat "$dir/current" 2>/dev/null); fi
fi
now=$(date +%s)
job=$(printf '%s' "$input" | jq -c --argjson now "$now" --arg tasks "$tasks_dir" --arg tp "$transcript" --arg cur "$parent" '
  def short: gsub("\\s+"; " ") | sub("^ "; "") | if length > 40 then (.[0:40] | sub(" [^ ]*$"; "")) + "…" else . end;
  . as $in | ($in.tool_response // {}) as $r
  | ([$r | .. | strings] | join("\n")) as $rt
  | if $in.tool_name == "Bash" and $in.tool_input.run_in_background == true then
      ((if ($r | type) == "object" then $r.backgroundTaskId else null end) // ($rt | capture("with ID: (?<id>[A-Za-z0-9_-]+)") | .id) // null) as $bid
      | select($bid != null)
      | {kind: "command", label: (($in.tool_input.description // $in.tool_input.command // "command") | tostring | short),
         detail: (($in.tool_input.command // "") | tostring | .[0:1500]), bg_id: $bid, output_file: ($tasks + "/" + $bid + ".output")}
    elif ($in.tool_name == "Agent" or $in.tool_name == "Task")
         and ((($r | type) == "object" and ($r.isAsync == true or $r.status == "async_launched")) or ($rt | test("Async agent launched"))) then
      ((if ($r | type) == "object" then $r.agentId else null end) // ($rt | capture("agentId: (?<id>[A-Za-z0-9]+)") | .id) // null) as $bid
      | select($bid != null)
      | {kind: "agent", label: (($in.tool_input.description // "agent") | tostring | short),
         detail: (($in.tool_input.prompt // "") | tostring | .[0:1500]),
         model: ((if ($r | type) == "object" then $r.resolvedModel else null end) // $in.tool_input.model // null), bg_id: $bid,
         agent_transcript: (($tp | sub("\\.jsonl$"; "")) + "/subagents/agent-" + $bid + ".jsonl")}
    elif $in.tool_name == "Workflow" and ($rt | test("launched in background"; "i")) then
      ((if ($r | type) == "object" then $r.taskId else null end) // ($rt | capture("Task ID: (?<id>[A-Za-z0-9_-]+)") | .id) // null) as $bid
      | select($bid != null)
      | {kind: "workflow",
         label: ((($rt | capture("Summary: (?<s>[^\n]+)") | .s) // "workflow") | short),
         detail: (($in.tool_input.script // "") | tostring | .[0:3000]),
         script_path: ($in.tool_input.scriptPath // null), bg_id: $bid,
         run_dir: (((if ($r | type) == "object" then $r.transcriptDir else null end) // ($rt | capture("Transcript dir: (?<d>[^\n]+)") | .d) // null) | if . then sub("\\s+$"; "") else . end),
         output_file: ($tasks + "/" + $bid + ".output")}
    else empty end
  | . + {tool_use_id: $in.tool_use_id, session_id: $in.session_id, task_id: $cur, started_at: $now}' 2>/dev/null)
[ -n "$job" ] || exit 0

# A workflow started from a script file: read the script for the estimator.
sp=$(printf '%s' "$job" | jq -r '.script_path // empty')
if [ -n "$sp" ] && [ -f "$sp" ]; then
  job=$(printf '%s' "$job" | jq -c --arg s "$(head -c 3000 "$sp")" '.detail = $s')
fi
mkdir -p "$jd" 2>/dev/null || exit 0
printf '%s' "$job" | write_atomic "$jd/$tuid.job.json" || exit 0
bash "$HOOK_DIR/reestimate.sh" job "$sid" "$tuid" </dev/null >/dev/null 2>&1
exit 0
