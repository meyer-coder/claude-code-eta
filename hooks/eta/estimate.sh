#!/bin/bash
# Workflow ETA: UserPromptSubmit hook (async).
# Asks one Haiku agent how long the new task will take and how many tokens it will use, corrects
# that for past bias, and refreshes the Fable limit reading when stale. task-start.sh (sync)
# creates the task itself.
[ -n "$CLAUDE_ETA_HOOK" ] && exit 0      # never re-trigger from the nested claude calls
export CLAUDE_ETA_HOOK=1
. "$HOME/.claude/hooks/eta/lib.sh" || exit 0

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$sid" ] || [ -z "$prompt" ]; then exit 0; fi
case "$sid" in */*|.*) exit 0 ;; esac
[ "$(prompt_kind "$prompt")" = task ] || exit 0
dir="$STATE_DIR/$sid"

# Hooks of one event start together, so wait briefly for task-start.sh to create this task.
h=$(printf '%s' "$input" | md5 | cut -c1-8)
tid=""
for _ in $(seq 1 50); do
  for f in $(ls "$dir"/*-"$h".task.json 2>/dev/null | sort -r); do
    t=$(basename "$f" .task.json)
    if [ ! -f "$dir/$t.est.json" ]; then tid="$t"; break; fi
  done
  [ -n "$tid" ] && break
  perl -e 'select(undef, undef, undef, 0.1)'
done
[ -z "$tid" ] && exit 0

bash "$HOOK_DIR/probe.sh" </dev/null >/dev/null 2>&1 &
probe_pid=$!

recent=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  recent=$(tail -c 400000 "$transcript" 2>/dev/null | tail -n +2 | jq -rR '
    fromjson? | select(type == "object" and (.type == "user" or .type == "assistant"))
    | select((.origin.kind // "") != "task-notification")
    | .type as $t
    | (.message.content | if type == "string" then .
        elif type == "array" then (map(select(type == "object" and .type == "text") | .text) | join(" "))
        else "" end | gsub("\\s+"; " ")) as $x
    | select(($x | length) > 0 and ($x | startswith("<") | not))
    | "\($t): \($x[0:300])"' 2>/dev/null | tail -n 8)
fi

# Reference class: how long this user's recent tasks actually took. Bias is corrected separately
# below, so Haiku sees outcomes only, not its own past misses (that would correct twice).
refs=""; ratio=""
if [ -f "$HISTORY" ]; then
  refs=$(jq -rs 'group_by(.task_id) | map(last) | map(select(.actual_min != null))
    | sort_by(.started_at) | .[-15:] | .[]
    | "\(.label // "task") | took \(.actual_min) min | used \(.actual_tokens // "unknown") tokens"' "$HISTORY" 2>/dev/null)
  ratio=$(jq -rs 'group_by(.task_id) | map(last) | map(select((.actual_tokens // 0) > 0 and (.five_hour_delta | type) == "number"))
    | sort_by(.started_at) | .[-20:]
    | if length >= 3 and ((map(.actual_tokens) | add) > 0) then ((map(.five_hour_delta) | add) / (map(.actual_tokens) | add)) else empty end' "$HISTORY" 2>/dev/null)
fi

system_prompt='You estimate a Claude Code task before it runs: how long it will take in wall-clock minutes, and how many tokens it will use.
Claude Code is an autonomous coding agent. It reads and edits files, runs shell commands and tests, and for big jobs launches subagents or background workflows that run many agents in parallel. Background work counts toward the task until it finishes.
Time scale: a short answer or quick question 0.5 to 1 minute. A small edit or single bug fix 2 to 5. A multi-file feature or refactor 8 to 20. A large build with subagents, workflows, agent teams, test suites, migrations or data runs 20 to 60 or more.
Token scale (new input tokens plus cache writes plus output, across the main session and every subagent; cached re-reads do not count): a quick answer 3k to 15k. A small edit 20k to 80k. A multi-file feature 100k to 400k. A background workflow with dozens of agents 1M to 3M or more; a 76-agent review workflow used about 2M.
If the user'"'"'s recent tasks are listed with how long they took, use them as a reference for similar work.
Reply with exactly one line of JSON and nothing else:
{"minutes": <best estimate>, "low": <optimistic minutes>, "high": <pessimistic minutes>, "tokens": <best token estimate as an integer>, "label": "<task label, 5 words maximum>"}'

user_msg=$(printf 'Working directory: %s\n\nRecent conversation (oldest first):\n%s\n\nThis user'"'"'s recent tasks (label | actual time | actual tokens):\n%s\n\nNEW PROMPT FROM THE USER:\n%s\n' \
  "$cwd" "${recent:-(none)}" "${refs:-(none yet)}" "$(printf '%s' "$prompt" | jq -Rrs '.[0:4000]')")

json=$(ask_haiku "$system_prompt" "$user_msg")
raw_min=$(jq -rn --arg j "$json" '($j | try fromjson catch {}) | .minutes | if type == "string" then (tonumber? // empty) elif type == "number" then . else empty end' 2>/dev/null)
raw_tok=$(jq -rn --arg j "$json" '($j | try fromjson catch {}) | .tokens | if type == "string" then (tonumber? // empty) elif type == "number" then . else empty end' 2>/dev/null)
f_min=$(bias_factor "$HISTORY" "" raw_est_min actual_min "${raw_min:-x}" 5 30)
f_tok=$(bias_factor "$HISTORY" "" raw_est_tokens actual_tokens "${raw_tok:-x}" 50000 500000)

est=$(jq -cn --arg j "$json" --arg tid "$tid" --argjson t "$(date +%s)" --arg ratio "$ratio" --argjson fm "$f_min" --argjson ft "$f_tok" '
  def num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
  ($j | try fromjson catch null) as $o
  | if $o == null or ((($o.minutes | num) // 0) <= 0) then {task_id: $tid, estimated_at: $t, failed: true}
    else
      ([($o.minutes | num), 0.25] | max) as $raw
      | ($raw * $fm) as $m
      | ($o.low | num) as $l | ($o.high | num) as $h | ($o.tokens | num) as $k
      | ($ratio | tonumber? // null) as $r
      | {task_id: $tid, estimated_at: $t,
         raw_est_min: $raw, bias_min: $fm, est_min: ($m * 100 | round / 100),
         low_min: (if $l != null and $l > 0 then ([$l * $fm, $m] | min) else null end),
         high_min: (if $h != null and $h > 0 then ([$h * $fm, $m] | max) else null end),
         raw_est_tokens: (if $k != null and $k > 0 then ($k | round) else null end),
         bias_tokens: $ft,
         est_tokens: (if $k != null and $k > 0 then ($k * $ft | round) else null end),
         pct_per_token: $r,
         label: (($o.label // "") | tostring | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")
                 | if length > 40 then (.[0:40] | sub(" [^ ]*$"; "")) + "…" else . end
                 | if . == "" then null else . end),
         revisions: 0}
      | . + {initial_est_min: .est_min, initial_est_tokens: .est_tokens,
             est_five_hour_pct: (if $r != null and .est_tokens != null then ((.est_tokens * $r * 10 | round) / 10) else null end)}
    end' 2>/dev/null)
[ -z "$est" ] && est=$(jq -cn --arg tid "$tid" --argjson t "$(date +%s)" '{task_id: $tid, estimated_at: $t, failed: true}')
printf '%s' "$est" | write_atomic "$dir/$tid.est.json"
append_history_if_ready "$sid" "$tid"
wait "$probe_pid" 2>/dev/null
exit 0
