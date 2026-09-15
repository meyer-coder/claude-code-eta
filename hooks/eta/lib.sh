#!/bin/bash
# Workflow ETA: shared paths and helpers, sourced by every ETA script.
#
# Layout (one directory per session, one set of files per task or job, so writers never overwrite each other):
#   state/<session>/current                       id of the newest task
#   state/<session>/<task>.task.json              start, prompt, transcript offset, limits at start   (task-start.sh)
#   state/<session>/<task>.est.json               Haiku estimate, bias-corrected, updated while running (estimate.sh, reestimate.sh)
#   state/<session>/<task>.stop.json              finish: done | waiting | error, launches, interrupt  (stop.sh, task-start.sh)
#   state/<session>/<task>.resumed.json           a waiting task resumed by its job's notification    (task-start.sh)
#   state/<session>/<task>.acct.json              tokens used, 5-hour limit movement                  (account.sh)
#   state/<session>/jobs/<tool_use_id>.job.json   a background workflow, agent or command             (job-start.sh)
#   state/<session>/jobs/<tool_use_id>.est.json   its estimate, updated while it runs                 (reestimate.sh)
#   state/<session>/jobs/<tool_use_id>.done.json  when it finished                                    (first detector wins)
#   history.jsonl, jobs-history.jsonl             finished tasks and jobs, for calibration
#   limits.json                                   5-hour, weekly and Fable readings

# Claude Code opened from the Dock may not have your shell PATH: add the usual install locations.
export PATH="$PATH:$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin"

ETA_DIR="$HOME/.claude/eta"
STATE_DIR="$ETA_DIR/state"
HISTORY="$ETA_DIR/history.jsonl"
JOBS_HISTORY="$ETA_DIR/jobs-history.jsonl"
LIMITS="$ETA_DIR/limits.json"
LOG="$ETA_DIR/estimate.log"
HOOK_DIR="$HOME/.claude/hooks/eta"
ETA_MODEL="claude-haiku-4-5-20251001"
EMPTY_SCAN='{"launched":[],"agent_calls":[],"notified":[],"interrupted_at":null}'
mkdir -p "$STATE_DIR" 2>/dev/null

eta_log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
is_num() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# Write stdin to a file atomically. An empty result never replaces an existing file.
write_atomic() {
  local tmp="$1.tmp.$$.$RANDOM"
  if cat > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then mv -f "$tmp" "$1"; else rm -f "$tmp"; return 1; fi
}

# jq definitions: ts turns a transcript timestamp into epoch seconds; text flattens message content.
JQ_DEFS='
def ts: (.timestamp // "") | (try (sub("\\.[0-9]+Z$"; "Z") | fromdate) catch 0);
def text:
  if type == "string" then .
  elif type == "array" then
    map(if type == "string" then .
        elif type == "object" then
          (if (.text | type) == "string" then .text
           elif (.content | type) == "string" then .content
           elif (.content | type) == "array" then (.content | map(if type == "object" then (.text // "") else "" end) | join(" "))
           else "" end)
        else "" end) | join(" ")
  else "" end;
'

take_lock() {  # $1 lock directory, $2 minutes after which a leftover lock is stale
  mkdir "$1" 2>/dev/null && return 0
  [ -n "$(find "$1" -maxdepth 0 -mmin +"${2:-3}" 2>/dev/null)" ] || return 1
  rm -rf "$1"; mkdir "$1" 2>/dev/null
}

# Run a command fully detached (new session, no inherited pipes), so the caller never waits on it.
spawn_detached() {
  [ -n "$ETA_SPAWN_LOG" ] && printf '%s\n' "$*" >> "$ETA_SPAWN_LOG"
  [ -n "$ETA_SPAWN_DRYRUN" ] && return 0   # rehearsal only: record the launch, do not start it
  perl -MPOSIX -e '
    my $pid = fork(); exit 0 if !defined($pid) || $pid;
    POSIX::setsid();
    $pid = fork(); exit 0 if !defined($pid) || $pid;
    open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">>", "$ENV{HOME}/.claude/eta/estimate.log");
    exec { $ARGV[0] } @ARGV; exit 1;' "$@" </dev/null >/dev/null 2>&1
}

# ask_haiku <system prompt> <user message>: prints the first JSON object in Haiku's reply.
ask_haiku() {
  local out json
  out=$(printf '%s' "$2" | perl -e 'alarm shift; exec @ARGV' 90 claude -p \
    --model "$ETA_MODEL" --output-format text --tools "" --no-session-persistence \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources "" \
    --settings '{"disableClaudeAiConnectors":true}' --disable-slash-commands \
    --system-prompt "$1" 2>>"$LOG")
  json=$(printf '%s' "$out" | tr -d '\n' | grep -o '{[^{}]*}' | head -n 1)
  if [ -z "$json" ]; then eta_log "haiku: unparseable reply: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; return 1; fi
  printf '%s' "$json"
}

# ---------- limits ----------
# Merge readings {"window": {"pct", "resets_at", "label"?}} into limits.json under a lock, so two
# sessions writing at once cannot drop each other's windows. Within one window usage only grows,
# so the higher reading wins; a later resets_at starts a new window; an earlier one is stale.
merge_limits() {  # $1 readings JSON, $2 "wait" to wait for the lock instead of skipping this refresh
  local incoming="$1" now cur merged lock="$ETA_DIR/.limits.lock" tries=0
  [ -z "$incoming" ] && return 0
  until mkdir "$lock" 2>/dev/null; do
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "$lock"; continue; fi
    [ "$2" = "wait" ] || return 0
    tries=$(( tries + 1 )); [ "$tries" -gt 60 ] && return 0
    perl -e 'select(undef, undef, undef, 0.05)'
  done
  now=$(date +%s)
  cur=$(cat "$LIMITS" 2>/dev/null)
  merged=$(jq -cn --argjson inc "$incoming" --argjson now "$now" --arg cur "$cur" '
    ($cur | try fromjson catch {} | if type == "object" then . else {} end) as $c
    | reduce ($inc | to_entries[]) as $e ($c;
        $e.value as $n | .[$e.key] as $o
        | if ($n.pct | type) != "number" or ($n.resets_at | type) != "number" then .
          elif $o == null or $n.resets_at > (($o.resets_at // 0) + 60) then
            .[$e.key] = ($n + {updated_at: $now})
          elif $n.resets_at >= (($o.resets_at // 0) - 60) then
            .[$e.key] = ($o + {pct: ([$o.pct, $n.pct] | max)}
              + (if $n.pct > $o.pct or ($now - ($o.updated_at // 0)) >= 60 then {updated_at: $now} else {} end)
              + (if $n.label then {label: $n.label} else {} end))
          else . end)' 2>/dev/null)
  if [ -n "$merged" ] && [ "$merged" != "$cur" ]; then printf '%s' "$merged" | write_atomic "$LIMITS"; fi
  rmdir "$lock" 2>/dev/null
  return 0
}

# ---------- transcript reading ----------
transcript_from_offset() {  # $1 transcript, $2 byte offset: JSONL from about the offset (partial first line dropped)
  local size off="$2"
  [ -n "$1" ] && [ -f "$1" ] || return 0
  is_num "$off" || off=0
  size=$(stat -f %z "$1" 2>/dev/null || echo 0); [ "$size" -lt "$off" ] && off=0
  if [ "$off" -gt 0 ]; then tail -c +$(( off + 1 )) "$1" | tail -n +2; else cat "$1"; fi 2>/dev/null
}

# scan_transcript <task.json> <from> <to>: background launches, Agent calls and interrupts inside the
# task's own turn window; job notifications since the task started.
scan_transcript() {
  local tf="$1" from="$2" to="$3" transcript offset started
  transcript=$(jq -r '.transcript // empty' "$tf" 2>/dev/null)
  offset=$(jq -r '.offset // 0' "$tf" 2>/dev/null)
  started=$(jq -r '.started_at // 0' "$tf" 2>/dev/null); is_num "$started" || started=0
  is_num "$from" || from=0; is_num "$to" || to=$(date +%s)
  if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then printf '%s' "$EMPTY_SCAN"; return; fi
  transcript_from_offset "$transcript" "$offset" \
  | jq -cRn --argjson from "$from" --argjson to "$to" --argjson since "$started" "$JQ_DEFS"'
      [inputs | (try fromjson catch null) | select(type == "object") | . + {_ts: ts}] as $all
      | ($all | map(select(._ts >= $from and ._ts <= ($to + 5)))) as $win
      | {launched: [$win[] | select(.type == "user") | .message.content | arrays | .[]
                    | select(type == "object" and .type == "tool_result")
                    | select(.content | text | test("^\\s*(Command running in background with ID:|Async agent launched successfully|Workflow launched in background)"))
                    | .tool_use_id] | unique,
         agent_calls: [$win[] | select(.type == "assistant") | .message.content[]?
                    | select(type == "object" and .type == "tool_use" and (.name == "Agent" or .name == "Task")) | .id] | unique,
         notified: [$all[] | select(._ts >= $since and .type == "user" and (.origin.kind // "") == "task-notification")
                    | .message.content | text | capture("<tool-use-id>(?<id>[^<]+)</tool-use-id>") | .id] | unique,
         interrupted_at: ([$win[] | select(.type == "user" and (.message.content | type) == "array")
                    | select(any(.message.content[]; type == "object" and .type == "text" and ((.text // "") | startswith("[Request interrupted by user"))))
                    | ._ts] | min)}' 2>/dev/null
}

# What Claude has been doing since <since>: the last 25 things it said or ran.
transcript_activity() {  # $1 transcript, $2 offset, $3 since
  is_num "$3" || return 0
  transcript_from_offset "$1" "$2" | jq -rRn --argjson since "$3" "$JQ_DEFS"'
      inputs | (try fromjson catch null) | select(type == "object" and .type == "assistant") | select(ts >= $since)
      | .message.content[]? | select(type == "object")
      | if .type == "text" then "said: " + (.text | gsub("\\s+"; " ") | .[0:160])
        elif .type == "tool_use" then "ran " + .name + ": " + ((.input.description // .input.file_path // .input.command // .input.pattern // .input.prompt // "") | tostring | gsub("\\s+"; " ") | .[0:100])
        else empty end' 2>/dev/null | tail -n 25
}

# ---------- tokens ----------
# count_tokens <transcript> <offset> <turns JSON [[from,to],...]> <subagent files, one per line>
# Prints "<main> <sub>". Tokens = new input + cache writes + output, deduplicated by message id.
# Main-session tokens come from the task's own turns; subagent tokens from the files it owns.
count_tokens() {
  local SUM='| unique_by(.id) | map((.u.input_tokens // 0) + (.u.cache_creation_input_tokens // 0) + (.u.output_tokens // 0)) | add // 0'
  local main=0 sub=0
  if [ -n "$1" ] && [ -f "$1" ]; then
    main=$(transcript_from_offset "$1" "$2" | jq -Rn --argjson turns "$3" "$JQ_DEFS"'
        [inputs | (try fromjson catch null) | select(type == "object" and .type == "assistant" and .message.usage != null)
         | ts as $x | select(any($turns[]; $x >= (.[0] - 2) and $x <= (.[1] + 5)))
         | {id: (.message.id // .uuid), u: .message.usage}] '"$SUM" 2>/dev/null)
  fi
  if [ -n "$4" ]; then
    sub=$(printf '%s\n' "$4" | while IFS= read -r f; do [ -f "$f" ] && printf '%s\0' "$f"; done | xargs -0 cat 2>/dev/null \
      | jq -Rn '[inputs | (try fromjson catch null) | select(type == "object" and .type == "assistant" and .message.usage != null)
                | {id: (.message.id // .uuid), u: .message.usage}] '"$SUM" 2>/dev/null)
  fi
  is_num "$main" || main=0; is_num "$sub" || sub=0
  printf '%s %s' "$main" "$sub"
}

# owned_subagent_files <session> <task id> <transcript> <agent call ids JSON>: transcripts of the
# subagents this task started (its background jobs, plus agents it ran in the foreground).
owned_subagent_files() {
  local jd="$STATE_DIR/$1/jobs" subdir="${3%.jsonl}/subagents"
  {
    if [ -d "$jd" ]; then
      grep -l -F "\"task_id\":\"$2\"" "$jd"/*.job.json 2>/dev/null | while IFS= read -r jf; do
        jq -r '.agent_transcript // empty' "$jf" 2>/dev/null
        rd=$(jq -r '.run_dir // empty' "$jf" 2>/dev/null)
        [ -n "$rd" ] && [ -d "$rd" ] && find "$rd" -name 'agent-*.jsonl' 2>/dev/null
      done
    fi
    if [ -n "$4" ] && [ "$4" != "[]" ] && [ -d "$subdir" ]; then
      find "$subdir" -maxdepth 1 -name 'agent-*.meta.json' -print0 2>/dev/null \
        | xargs -0 jq -r --argjson ids "$4" 'select((.toolUseId // "") as $t | $ids | index($t)) | input_filename | sub("\\.meta\\.json$"; ".jsonl")' 2>/dev/null
    fi
  } | sort -u
}

# ---------- jobs ----------
task_jobs() {  # $1 session, $2 task id: {"launched": [ids], "done": [ids]} for the jobs this task launched
  local jd="$STATE_DIR/$1/jobs" l="" d="" f id
  if [ -d "$jd" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      id=$(basename "$f" .job.json); l="$l$id "
      [ -f "$jd/$id.done.json" ] && d="$d$id "
    done < <(grep -l -F "\"task_id\":\"$2\"" "$jd"/*.job.json 2>/dev/null)
  fi
  jq -cn --arg l "$l" --arg d "$d" '{launched: ($l | split(" ") | map(select(length > 0))), done: ($d | split(" ") | map(select(length > 0)))}'
}

# Live progress of a background job, as JSON.
job_progress() {  # $1 job.json
  local jf="$1" kind rd at of size idle
  kind=$(jq -r '.kind // empty' "$jf" 2>/dev/null)
  case "$kind" in
    workflow)
      rd=$(jq -r '.run_dir // empty' "$jf" 2>/dev/null)
      if [ -n "$rd" ] && [ -f "$rd/journal.jsonl" ]; then
        jq -cRn '[inputs | fromjson? | select(type == "object")] as $e
          | {started: ([$e[] | select(.type == "started")] | length),
             finished: ([$e[] | select(.type == "result")] | length),
             failed: ([$e[] | select(.type == "failed")] | length),
             phases: ([$e[] | select(.type == "started") | (.phase // "main")] | group_by(.) | map({key: .[0], value: length}) | from_entries),
             latest: ([$e[] | select(.type == "started") | (.label // "")] | .[-5:])}' "$rd/journal.jsonl" 2>/dev/null || echo '{}'
      else echo '{}'; fi ;;
    agent)
      at=$(jq -r '.agent_transcript // empty' "$jf" 2>/dev/null)
      if [ -n "$at" ] && [ -f "$at" ]; then
        idle=$(( $(date +%s) - $(stat -f %m "$at" 2>/dev/null || date +%s) ))
        tail -c 3000000 "$at" 2>/dev/null | tail -n +2 | jq -cRn --argjson idle "$idle" '
          [inputs | fromjson? | select(type == "object" and .type == "assistant") | .message.content[]? | select(type == "object")] as $b
          | {tool_calls: ([$b[] | select(.type == "tool_use")] | length),
             last_text: ([$b[] | select(.type == "text") | .text] | last // "" | gsub("\\s+"; " ") | .[0:240]),
             idle_seconds: $idle}' 2>/dev/null || echo '{}'
      else echo '{}'; fi ;;
    command)
      of=$(jq -r '.output_file // empty' "$jf" 2>/dev/null)
      if [ -n "$of" ] && [ -f "$of" ]; then
        size=$(stat -f %z "$of" 2>/dev/null || echo 0)
        tail -n 15 "$of" 2>/dev/null | cut -c1-200 | jq -Rsc --argjson size "$size" '{output_bytes: $size, output_tail: .}' 2>/dev/null || echo '{}'
      else echo '{}'; fi ;;
    *) echo '{}' ;;
  esac
}

# Mark a background job finished exactly once, and record it for calibration.
mark_job_done() {  # $1 session, $2 tool_use_id, $3 completed | failed, $4 finished_at epoch
  local jd="$STATE_DIR/$1/jobs" body row
  [ -f "$jd/$2.job.json" ] && [ ! -f "$jd/$2.done.json" ] || return 0
  is_num "$4" || return 0
  body=$(jq -cn --arg id "$2" --arg st "$3" --argjson t "$4" '{tool_use_id: $id, status: $st, finished_at: $t}') || return 0
  ( set -C; printf '%s' "$body" > "$jd/$2.done.json" ) 2>/dev/null || return 0   # exclusive create: first detector wins
  row=$(jq -cn --slurpfile j "$jd/$2.job.json" --argjson d "$body" --arg est "$(cat "$jd/$2.est.json" 2>/dev/null)" --arg prog "$(job_progress "$jd/$2.job.json")" '
    $j[0] as $j | ($est | try fromjson catch {}) as $e | ($prog | try fromjson catch {}) as $p
    | select($d.status == "completed" and $d.finished_at > $j.started_at)
    | {tool_use_id: $j.tool_use_id, kind: $j.kind, label: $j.label, started_at: $j.started_at,
       actual_min: ((($d.finished_at - $j.started_at) / 60 * 10 | round) / 10),
       raw_est_min: $e.raw_est_min, initial_est_min: $e.initial_est_min, revisions: ($e.revisions // 0),
       agents: $p.started}' 2>/dev/null)
  [ -n "$row" ] && printf '%s\n' "$row" >> "$JOBS_HISTORY"
  return 0
}

# ---------- finishing tasks ----------
run_account() {  # $1 session, $2 task id, $3 sync | detached
  if [ "$3" = detached ]; then spawn_detached bash "$HOOK_DIR/account.sh" "$1" "$2"
  else perl -e 'alarm shift; exec @ARGV' 20 bash "$HOOK_DIR/account.sh" "$1" "$2" </dev/null >/dev/null 2>&1; fi
}

# finalize_task <session> <task id> <resumed.json or ""> <event> <sync | detached>
# Records how a turn of this task ended. Launches count only from the task's own turn window (and
# from jobs it launched), so another task's turn can never be booked to it.
finalize_task() {
  local sid="$1" tid="$2" rf="$3" event="${4:-Stop}" mode="${5:-sync}"
  local dir="$STATE_DIR/$1" tf now from to prev scan jobs nxt
  tf="$dir/$tid.task.json"; [ -f "$tf" ] || return 0
  now=$(date +%s); to=$now
  if [ -n "$rf" ]; then
    from=$(jq -r '.resumed_at // 0' "$rf" 2>/dev/null); prev=$(cat "$rf" 2>/dev/null)
    is_num "$from" || from=0
    # A task that started after the resume owns the rest of the time: stop this window there.
    nxt=$(cat "$dir"/*.task.json 2>/dev/null | jq -rs --argjson f "$from" '[.[] | .started_at | select(type == "number" and . > $f)] | min // empty' 2>/dev/null)
    is_num "$nxt" && [ "$nxt" -lt "$to" ] && to=$nxt
  else
    from=$(jq -r '.started_at // 0' "$tf" 2>/dev/null); prev=""
    is_num "$from" || from=0
  fi
  [ -z "$prev" ] && prev=null
  scan=$(scan_transcript "$tf" "$from" "$to"); [ -z "$scan" ] && scan="$EMPTY_SCAN"
  jobs=$(task_jobs "$sid" "$tid")
  jq -cn --slurpfile t "$tf" --argjson s "$scan" --argjson r "$prev" --argjson j "$jobs" \
    --argjson from "$from" --argjson to "$to" --arg ev "$event" '
    $t[0] as $t | (($r // {}).prev // {}) as $p
    | ((($p.launched // []) + $s.launched + $j.launched) | unique) as $launched
    | (($s.notified + (($r // {}).resume_ids // []) + $j.done) | unique) as $notified
    | ($launched - $notified) as $pending
    | ($p.interrupted_at // $s.interrupted_at) as $int
    | {task_id: $t.task_id, started_at: $t.started_at, prompt: $t.prompt, stopped_at: $to,
       turns: (($p.turns // []) + [[$from, $to]]),
       launched: $launched, agent_calls: ((($p.agent_calls // []) + $s.agent_calls) | unique),
       pending: $pending, interrupted_at: $int, interrupted: ($int != null),
       outcome: (if $ev == "StopFailure" then "error" elif ($pending | length) > 0 then "waiting" else "done" end)}' 2>/dev/null \
    | write_atomic "$dir/$tid.stop.json" || return 0
  [ -n "$rf" ] && rm -f "$rf"
  run_account "$sid" "$tid" "$mode"
}

# A waiting task whose job finished while a different task is mid-turn: update it in place
# (no resume, so that other task's turn is never booked to it). Done once no jobs remain.
complete_waiting() {  # $1 session, $2 task id, $3 finished job id, $4 now
  local sf="$STATE_DIR/$1/$2.stop.json" jobs
  [ -f "$sf" ] || return 0
  jobs=$(task_jobs "$1" "$2")
  jq -c --arg u "$3" --argjson j "$jobs" --argjson now "$4" '
    ((.pending // []) - [$u] - $j.done) as $rest
    | .pending = $rest
    | if ($rest | length) == 0 and .outcome == "waiting" then .outcome = "done" | .stopped_at = $now else . end' "$sf" 2>/dev/null \
    | write_atomic "$sf" || return 0
  grep -q '"outcome":"done"' "$sf" && run_account "$1" "$2" detached
  return 0
}

# ---------- calibration ----------
# Append one row once a task has an estimate, a clean finish and a token count. The row keeps the
# first estimates (raw and corrected), so later updates never flatter the calibration.
append_history_if_ready() {  # $1 session id, $2 task id
  local dir="$STATE_DIR/$1" tid="$2" row last
  [ -f "$dir/$tid.est.json" ] && [ -f "$dir/$tid.stop.json" ] && [ -f "$dir/$tid.acct.json" ] || return 0
  row=$(jq -cn --arg tid "$tid" --slurpfile e "$dir/$tid.est.json" --slurpfile s "$dir/$tid.stop.json" --slurpfile a "$dir/$tid.acct.json" '
    $e[0] as $e | $s[0] as $s | $a[0] as $a
    | select($e.task_id == $tid and $s.task_id == $tid and $a.task_id == $tid and $e.est_min != null)
    | select($s.outcome == "done" and ($s.interrupted | not) and $a.stopped_at == $s.stopped_at)
    | {task_id: $tid, label: $e.label, prompt: $s.prompt, started_at: $s.started_at,
       est_min: ($e.initial_est_min // $e.est_min), actual_min: ((($s.stopped_at - $s.started_at) / 60 * 10 | round) / 10),
       est_tokens: ($e.initial_est_tokens // $e.est_tokens), actual_tokens: $a.tokens, five_hour_delta: $a.five_hour_delta,
       raw_est_min: $e.raw_est_min, raw_est_tokens: $e.raw_est_tokens, revisions: ($e.revisions // 0)}' 2>/dev/null)
  [ -n "$row" ] || return 0
  last=$(grep -F "\"task_id\":\"$tid\"" "$HISTORY" 2>/dev/null | tail -n 1)
  [ "$last" = "$row" ] && return 0
  printf '%s\n' "$row" >> "$HISTORY"
}

# bias_factor <history file> <kind or ""> <raw estimate field> <actual field> <new raw estimate> <bucket 1> <bucket 2>
# Median of actual / raw-estimate over the last 20 finished rows of similar size, shrunk toward 1
# while there are few rows, clamped to 0.5..4. Prints 1 when there is nothing to learn from.
bias_factor() {
  local out
  [ -f "$1" ] && is_num "$5" || { echo 1; return; }
  out=$(jq -rs --arg kind "$2" --arg ef "$3" --arg af "$4" --argjson est "$5" --argjson t1 "$6" --argjson t2 "$7" '
    def bucket: if . < $t1 then 0 elif . < $t2 then 1 else 2 end;
    group_by(.task_id // .tool_use_id) | map(last)
    | map(select(($kind == "" or .kind == $kind) and ((.[$ef] // 0) > 0) and ((.[$af] // 0) > 0)))
    | map(select((.[$ef] | bucket) == ($est | bucket)))
    | sort_by(.started_at) | .[-20:]
    | map((.[$af] / .[$ef]) | log) | sort | length as $n
    | if $n == 0 then 1
      else (if $n % 2 == 1 then .[(($n - 1) / 2) | floor] else ((.[($n / 2 - 1) | floor] + .[($n / 2) | floor]) / 2) end) as $m
        | ($m * $n / ($n + 3)) | exp | if . < 0.5 then 0.5 elif . > 4 then 4 else . end end' "$1" 2>/dev/null)
  if is_num "$out"; then echo "$out"; else echo 1; fi
}

# ---------- formatting ----------
fmt_clock() {  # seconds -> m:ss or h:mm:ss
  local s=${1:-0}; [ "$s" -lt 0 ] && s=$(( -s ))
  local h=$(( s / 3600 )) m=$(( (s % 3600) / 60 )) x=$(( s % 60 ))
  if [ "$h" -gt 0 ]; then printf '%d:%02d:%02d' "$h" "$m" "$x"; else printf '%d:%02d' "$m" "$x"; fi
}
fmt_min() {  # minutes (decimal) -> 45s, 12m, 1h, 1h 5m
  local secs mins
  secs=$(awk -v m="$1" 'BEGIN { printf "%d", m * 60 + 0.5 }')
  if [ "$secs" -lt 60 ]; then printf '%ds' "$secs"; return; fi
  mins=$(( (secs + 30) / 60 ))
  if [ "$mins" -lt 60 ]; then printf '%dm' "$mins"
  elif [ $(( mins % 60 )) -eq 0 ]; then printf '%dh' $(( mins / 60 ))
  else printf '%dh %dm' $(( mins / 60 )) $(( mins % 60 )); fi
}
fmt_tok() {  # 850 -> 850, 184000 -> 184k, 2040000 -> 2.0M
  awk -v n="$1" 'BEGIN { if (n < 1000) printf "%d", n; else if (n < 999500) printf "%dk", int(n / 1000 + 0.5); else printf "%.1fM", n / 1000000 }'
}
clock_at() { date -r "$1" '+%-I:%M %p' 2>/dev/null; }

# prompt_kind <prompt>: task | notification | skip
prompt_kind() {
  case "$1" in
    "<task-notification>"*) echo notification; return ;;
    "<local-command-stdout>"*|"<local-command-caveat>"*|"<command-name>"*|"<command-message>"*|"<system-reminder>"*|"<bash-input>"*|"<bash-stdout>"*|"<bash-stderr>"*|"<ide_"*) echo skip; return ;;
  esac
  case "${1%%[[:space:]]*}" in   # first word, so /statusline is a task while /status is housekeeping
    /login|/logout|/help|/clear|/rename|/config|/model|/effort|/usage|/context|/hooks|/status|/cost|/exit|/quit|/compact|/resume|/theme|/permissions|/mcp|/doctor|/memory|/artifacts|/tasks|/workflows|/fast|/agents|/plugin|/plugins|/export|/vim|/ide) echo skip ;;
    *) echo task ;;
  esac
}
