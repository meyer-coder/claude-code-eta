#!/bin/bash
# Workflow ETA: count the tokens one task used and how far the 5-hour limit moved.
# Tokens = new input + cache writes + output (cached re-reads are not counted): the main session
# during the task's own turns, plus the subagents the task started (background jobs and
# foreground agents). Usage: account.sh <session id> <task id>
. "$HOME/.claude/hooks/eta/lib.sh" || exit 0
sid="$1"; tid="$2"
[ -n "$sid" ] && [ -n "$tid" ] || exit 0
case "$sid$tid" in */*|.*) exit 0 ;; esac
dir="$STATE_DIR/$sid"; tf="$dir/$tid.task.json"; sf="$dir/$tid.stop.json"
[ -f "$tf" ] && [ -f "$sf" ] || exit 0

transcript=$(jq -r '.transcript // empty' "$tf" 2>/dev/null)
offset=$(jq -r '.offset // 0' "$tf" 2>/dev/null); is_num "$offset" || offset=0
started=$(jq -r '.started_at // 0' "$tf" 2>/dev/null); is_num "$started" || exit 0
stopped=$(jq -r '.stopped_at // 0' "$sf" 2>/dev/null); is_num "$stopped" || exit 0
turns=$(jq -c '.turns // []' "$sf" 2>/dev/null); [ -z "$turns" ] && turns="[[$started,$stopped]]"
calls=$(jq -c '.agent_calls // []' "$sf" 2>/dev/null); [ -z "$calls" ] && calls='[]'

files=$(owned_subagent_files "$sid" "$tid" "$transcript" "$calls")
read -r main sub < <(count_tokens "$transcript" "$offset" "$turns" "$files")
is_num "$main" || main=0; is_num "$sub" || sub=0

# 5-hour limit movement: only meaningful when the window did not reset during the task.
# Other sessions running at the same time also move it, so this is an upper bound.
five_delta=$(jq -rn --slurpfile t "$tf" --arg lim "$(cat "$LIMITS" 2>/dev/null)" '
  ($t[0].limits_start.five_hour // null) as $s
  | ($lim | try fromjson catch {} | .five_hour // null) as $e
  | if $s != null and $e != null and ((($e.resets_at - $s.resets_at) | if . < 0 then -. else . end) <= 60)
    then ([($e.pct - $s.pct), 0] | max) else "null" end' 2>/dev/null)

jq -cn --arg tid "$tid" --argjson stopped "$stopped" --argjson main "$main" --argjson sub "$sub" \
  --arg fd "$five_delta" --argjson now "$(date +%s)" '
  {task_id: $tid, stopped_at: $stopped, main_tokens: $main, sub_tokens: $sub, tokens: ($main + $sub),
   five_hour_delta: ($fd | tonumber? // null), computed_at: $now}' | write_atomic "$dir/$tid.acct.json"

append_history_if_ready "$sid" "$tid"
for hf in "$HISTORY" "$JOBS_HISTORY"; do
  if [ -f "$hf" ] && [ "$(wc -l < "$hf" | tr -d ' ')" -gt 1000 ]; then tail -n 500 "$hf" | write_atomic "$hf"; fi
done
exit 0
