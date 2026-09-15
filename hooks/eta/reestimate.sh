#!/bin/bash
# Workflow ETA: keep an estimate current from live progress, with Haiku.
#   reestimate.sh task <session> <task id>       remaining time and tokens for a running task
#   reestimate.sh job  <session> <tool_use_id>   first estimate, or an update, for a background job
# One run per target at a time. ETA_LOCK_HELD=1 means the caller (the status line) took the lock.
export CLAUDE_ETA_HOOK=1
. "$HOME/.claude/hooks/eta/lib.sh" || exit 0
what="$1"; sid="$2"; id="$3"
[ -n "$what" ] && [ -n "$sid" ] && [ -n "$id" ] || exit 0
case "$sid$id" in */*|.*) exit 0 ;; esac
dir="$STATE_DIR/$sid"; lock="$dir/.lock-$what-$id"; fail="$dir/.fail-$what-$id"
[ -d "$dir" ] || exit 0
if [ -z "$ETA_LOCK_HELD" ]; then take_lock "$lock" 3 || exit 0; fi
trap 'rm -rf "$lock"' EXIT
now=$(date +%s)

num() { jq -rn --arg j "$1" --arg k "$2" '($j | try fromjson catch {}) | .[$k] | if type == "number" then . elif type == "string" then (tonumber? // empty) else empty end' 2>/dev/null; }
clamp_factor() { awk -v f="$1" 'BEGIN { if (f < 0.75) f = 0.75; if (f > 2) f = 2; printf "%.4f", f }'; }

UPDATE_PROMPT='You update the time estimate for work already running in Claude Code, using its live progress. Estimate the REMAINING wall-clock minutes from now, not the total.
Read the progress evidence. Workflows: compare agents finished with agents started, and the phases still to come; a workflow is not done until its last phase finishes. Agents: judge how far through its task the agent is. Commands: judge from the output how far along it is. A main task: compare what Claude has done with what the request needs; it is not done until its background jobs finish.'

if [ "$what" = task ]; then
  tf="$dir/$id.task.json"; ef="$dir/$id.est.json"; sf="$dir/$id.stop.json"
  [ -f "$tf" ] && [ -f "$ef" ] || exit 0
  jq -e '(.failed != true) and (.est_min != null)' "$ef" >/dev/null 2>&1 || exit 0
  if [ -f "$sf" ] && ! grep -q '"outcome":"waiting"' "$sf"; then exit 0; fi
  started=$(jq -r '.started_at // empty' "$tf"); is_num "$started" || exit 0
  transcript=$(jq -r '.transcript // empty' "$tf"); offset=$(jq -r '.offset // 0' "$tf"); prompt=$(jq -r '.prompt // empty' "$tf")
  elapsed=$(( now - started ))
  calls=$(scan_transcript "$tf" "$started" "$now" | jq -c '.agent_calls // []' 2>/dev/null); [ -z "$calls" ] && calls='[]'
  files=$(owned_subagent_files "$sid" "$id" "$transcript" "$calls")
  read -r main sub < <(count_tokens "$transcript" "$offset" "[[$started,$now]]" "$files")
  used=$(( ${main:-0} + ${sub:-0} ))
  activity=$(transcript_activity "$transcript" "$offset" "$started")
  jobs_txt=""
  if [ -d "$dir/jobs" ]; then
    jobs_txt=$(grep -l -F "\"task_id\":\"$id\"" "$dir/jobs"/*.job.json 2>/dev/null | while IFS= read -r jf; do
      j=$(basename "$jf" .job.json)
      jq -rn --slurpfile jj "$jf" --arg e "$(cat "$dir/jobs/$j.est.json" 2>/dev/null)" --arg d "$(cat "$dir/jobs/$j.done.json" 2>/dev/null)" \
        --arg p "$(job_progress "$jf")" --argjson now "$now" '
        $jj[0] as $j | ($e | try fromjson catch {}) as $e | ($d | try fromjson catch null) as $d
        | "- \($j.kind) \"\($j.label)\": "
          + (if $d then "finished after \((($d.finished_at - $j.started_at) / 6 | round) / 10) min"
             else "running \((($now - $j.started_at) / 6 | round) / 10) min so far, estimated \($e.est_min // "?") min in total, progress \($p)" end)'
    done)
  fi
  sys="$UPDATE_PROMPT
Also estimate the tokens the task will still use (new input plus cache writes plus output, including its subagents).
Reply with exactly one line of JSON and nothing else: {\"remaining\": <minutes>, \"low\": <minutes>, \"high\": <minutes>, \"tokens_remaining\": <integer>}"
  msg=$(printf 'THE REQUEST:\n%s\n\nRunning for %s minutes. Current estimate: %s\nTokens used so far: %s\n\nWhat Claude has done so far (oldest first):\n%s\n\nBackground jobs this task launched:\n%s\n' \
    "$prompt" "$(awk -v s="$elapsed" 'BEGIN { printf "%.1f", s / 60 }')" "$(jq -c '{est_min, low_min, high_min, est_tokens}' "$ef")" "$used" \
    "${activity:-(nothing recorded yet)}" "${jobs_txt:-(none)}")
  json=$(ask_haiku "$sys" "$msg") || { touch "$fail"; exit 0; }
  rem=$(num "$json" remaining); rlow=$(num "$json" low); rhigh=$(num "$json" high); trem=$(num "$json" tokens_remaining)
  is_num "$rem" || { touch "$fail"; exit 0; }
  f=$(clamp_factor "$(bias_factor "$HISTORY" "" raw_est_min actual_min "$(jq -r '.raw_est_min // empty' "$ef")" 5 30)")
  ft=$(clamp_factor "$(bias_factor "$HISTORY" "" raw_est_tokens actual_tokens "$(jq -r '.raw_est_tokens // empty' "$ef")" 50000 500000)")
  jq -c --argjson el "$elapsed" --argjson rem "$rem" --arg rlow "$rlow" --arg rhigh "$rhigh" --arg trem "$trem" \
    --argjson f "$f" --argjson ft "$ft" --argjson used "$used" --argjson now "$now" '
    ($el / 60) as $e
    | ($e + $rem * $f) as $m
    | .est_min = ($m * 100 | round / 100)
    | .low_min = (if ($rlow | tonumber? // null) != null then ([$e + ($rlow | tonumber) * $f, $m] | min) else null end)
    | .high_min = (if ($rhigh | tonumber? // null) != null then ([$e + ($rhigh | tonumber) * $f, $m] | max) else null end)
    | .est_tokens = (if ($trem | tonumber? // null) != null then ($used + ($trem | tonumber) * $ft | round) else .est_tokens end)
    | .est_five_hour_pct = (if .pct_per_token != null and .est_tokens != null then ((.est_tokens * .pct_per_token * 10 | round) / 10) else .est_five_hour_pct end)
    | .tokens_used_at_update = $used | .revisions = ((.revisions // 0) + 1) | .estimated_at = $now | .basis = "progress"' "$ef" 2>/dev/null \
    | write_atomic "$ef"
  rm -f "$fail"
  exit 0
fi

if [ "$what" = job ]; then
  jd="$dir/jobs"; jf="$jd/$id.job.json"; ef="$jd/$id.est.json"
  [ -f "$jf" ] && [ ! -f "$jd/$id.done.json" ] || exit 0
  kind=$(jq -r '.kind // empty' "$jf")
  started=$(jq -r '.started_at // empty' "$jf"); is_num "$started" || exit 0
  elapsed=$(( now - started ))
  refs=""
  [ -f "$JOBS_HISTORY" ] && refs=$(jq -rs --arg k "$kind" 'map(select(.kind == $k and .actual_min != null)) | sort_by(.started_at) | .[-10:] | .[]
    | "\(.label) | took \(.actual_min) min" + (if .agents then " | \(.agents) agents" else "" end)' "$JOBS_HISTORY" 2>/dev/null)
  desc=$(jq -r '"Kind: \(.kind)\nLabel: \(.label)\nModel: \(.model // "default")\nDetail (script, prompt or command):\n\(.detail // "")"' "$jf")

  if [ ! -f "$ef" ] && [ "$elapsed" -lt 90 ]; then
    sys='You estimate how long a background job that Claude Code just launched will take, in wall-clock minutes.
Kinds. "workflow": a script that spawns subagents. Read the script: count the agents it will start, its phases, and whether stages run in parallel (up to about 10 at once) or one after another. A typical agent takes 1 to 4 minutes; reviews and implementations take longer, quick checks 1 to 2. "agent": one subagent doing the task in its prompt; lookups take 1 to 3 minutes, reviews and implementations 5 to 20. "command": a shell command; read it: test suites, builds, data runs and backtests can take many minutes, small scripts take seconds.
If similar past jobs are listed with how long they took, use them as a reference.
Reply with exactly one line of JSON and nothing else: {"minutes": <best estimate>, "low": <optimistic>, "high": <pessimistic>}'
    msg=$(printf '%s\n\nSimilar past jobs (label | actual time):\n%s\n' "$desc" "${refs:-(none yet)}")
    json=$(ask_haiku "$sys" "$msg") || { touch "$fail"; exit 0; }
    raw=$(num "$json" minutes); is_num "$raw" || { touch "$fail"; exit 0; }
    f=$(bias_factor "$JOBS_HISTORY" "$kind" raw_est_min actual_min "$raw" 5 30)
    jq -cn --arg id "$id" --argjson raw "$raw" --arg low "$(num "$json" low)" --arg high "$(num "$json" high)" --argjson f "$f" --argjson now "$now" '
      ([$raw, 0.1] | max) as $raw | ($raw * $f) as $m
      | {tool_use_id: $id, raw_est_min: $raw, bias: $f, est_min: ($m * 100 | round / 100),
         low_min: (if ($low | tonumber? // null) != null then ([($low | tonumber) * $f, $m] | min) else null end),
         high_min: (if ($high | tonumber? // null) != null then ([($high | tonumber) * $f, $m] | max) else null end),
         initial_est_min: ($m * 100 | round / 100), revisions: 0, estimated_at: $now, basis: "initial"}' | write_atomic "$ef"
  else
    progress=$(job_progress "$jf")
    sys="$UPDATE_PROMPT
Reply with exactly one line of JSON and nothing else: {\"remaining\": <minutes>, \"low\": <minutes>, \"high\": <minutes>}"
    msg=$(printf '%s\n\nRunning for %s minutes. Current estimate: %s\nLive progress: %s\n\nSimilar past jobs (label | actual time):\n%s\n' \
      "$(printf '%s' "$desc" | head -c 2000)" "$(awk -v s="$elapsed" 'BEGIN { printf "%.1f", s / 60 }')" \
      "$(jq -c '{est_min, low_min, high_min}' "$ef" 2>/dev/null || echo none)" "$progress" "${refs:-(none yet)}")
    json=$(ask_haiku "$sys" "$msg") || { touch "$fail"; exit 0; }
    rem=$(num "$json" remaining); is_num "$rem" || { touch "$fail"; exit 0; }
    f=$(clamp_factor "$(bias_factor "$JOBS_HISTORY" "$kind" raw_est_min actual_min "$(jq -r '.raw_est_min // empty' "$ef" 2>/dev/null)" 5 30)")
    prev=$(cat "$ef" 2>/dev/null); [ -z "$prev" ] && prev='{}'
    jq -cn --arg id "$id" --argjson prev "$prev" --argjson el "$elapsed" --argjson rem "$rem" --arg low "$(num "$json" low)" --arg high "$(num "$json" high)" \
      --argjson f "$f" --argjson now "$now" '
      ($el / 60) as $e | ($e + $rem * $f) as $m
      | $prev + {tool_use_id: $id, est_min: ($m * 100 | round / 100),
          low_min: (if ($low | tonumber? // null) != null then ([$e + ($low | tonumber) * $f, $m] | min) else null end),
          high_min: (if ($high | tonumber? // null) != null then ([$e + ($high | tonumber) * $f, $m] | max) else null end),
          revisions: (($prev.revisions // 0) + 1), estimated_at: $now, basis: "progress"}' | write_atomic "$ef"
  fi
  rm -f "$fail"
fi
exit 0
