#!/bin/bash
# Workflow ETA: status line (refreshes every second).
#   first line   countdown for the task Claude is working on, or the background work it waits on
#   ↳ lines      one per background workflow, agent or command, each with its own countdown
#   last line    battery bars: how much of the 5-hour, weekly and Fable limits is used
# It also starts, detached and rate limited, the Haiku updates that keep those ETAs current and
# the Fable limit check while you are working.
. "$HOME/.claude/hooks/eta/lib.sh" 2>/dev/null || { echo "⏱ ETA scripts missing (~/.claude/hooks/eta/lib.sh)"; exit 0; }
input=$(cat)
B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
US=$'\037'
now=$(date +%s)

{ read -r sid; read -r tpath; read -r rl; } < <(printf '%s' "$input" | jq -r '
  (.session_id // ""), (.transcript_path // ""),
  ((.rate_limits // {}) | to_entries
   | map(select((.value.used_percentage | type) == "number" and (.value.resets_at | type) == "number")
         | {key, value: {pct: (.value.used_percentage | round), resets_at: .value.resets_at}})
   | from_entries | tojson)' 2>/dev/null)
case "$sid" in */*|.*) sid="" ;; esac
[ -n "$rl" ] && [ "$rl" != "{}" ] && merge_limits "$rl"
dir="$STATE_DIR/$sid"

# Start a Haiku update for a task or job when its estimate is due for one.
maybe_update() {  # $1 task|job, $2 id, $3 estimated_at, $4 est_min, $5 elapsed seconds
  local lock="$dir/.lock-$1-$2" interval
  [ -n "$(find "$dir/.fail-$1-$2" -mmin -5 2>/dev/null)" ] && return 0     # back off after a failed update
  if [ -z "$4" ]; then
    [ "$1" = job ] && [ "$5" -ge 20 ] || return 0                           # first job estimate went missing
  else
    is_num "$3" || return 0
    interval=$(awk -v m="$4" 'BEGIN { i = m * 60 / 5; if (i < 120) i = 120; if (i > 600) i = 600; printf "%d", i }')
    [ $(( now - ${3%.*} )) -ge "$interval" ] && [ "$5" -ge 60 ] || return 0
  fi
  take_lock "$lock" 3 || return 0
  spawn_detached env ETA_LOCK_HELD=1 bash "$HOOK_DIR/reestimate.sh" "$1" "$sid" "$2"
}

countdown() {  # $1 started, $2 est_min, $3 high_min, $4 elapsed -> sets cd_txt, cd_due, cd_ontime
  local est_secs remaining high_secs
  est_secs=$(awk -v m="$2" 'BEGIN { printf "%d", m * 60 + 0.5 }')
  cd_due=$(( $1 + est_secs )); remaining=$(( cd_due - now )); cd_ontime=0
  if [ "$remaining" -ge 0 ]; then
    cd_ontime=1
    cd_txt="${GRN}ETA ~$(fmt_min "$2")${R} ${D}· done by $(clock_at "$cd_due") · $(fmt_clock "$remaining") left${R}"
  else
    high_secs=""; is_num "$3" && high_secs=$(awk -v m="$3" 'BEGIN { printf "%d", m * 60 + 0.5 }')
    if [ -n "$high_secs" ] && [ "$4" -le "$high_secs" ]; then
      cd_txt="${YEL}running long: $(fmt_clock $(( -remaining ))) past ~$(fmt_min "$2")${R} ${D}· likely done by $(clock_at $(( $1 + high_secs )))${R}"
    else
      cd_txt="${RED}$(fmt_clock $(( -remaining ))) past the ~$(fmt_min "$2") ETA${R}"
    fi
  fi
}
ago() { local s=$(( now - ${1%.*} )); if [ "$s" -lt 60 ]; then printf 'just now'; else printf '%dm ago' $(( s / 60 )); fi; }

# ---------- which task to show ----------
pick=""; cur=""
if [ -n "$sid" ] && [ -d "$dir" ]; then
  cur=$(cat "$dir/current" 2>/dev/null)
  if [ -n "$cur" ] && [ -f "$dir/$cur.task.json" ] && [ ! -f "$dir/$cur.stop.json" ]; then
    pick="$cur"                                                     # Claude is working on it now
  else
    r=$(ls "$dir"/*.resumed.json 2>/dev/null | sort | tail -n 1)    # resumed by its background job
    w=$(grep -l '"outcome":"waiting"' "$dir"/*.stop.json 2>/dev/null | sort | tail -n 1)
    if [ -n "$r" ]; then pick=$(basename "$r" .resumed.json)
    elif [ -n "$w" ]; then pick=$(basename "$w" .stop.json)         # waiting on background jobs
    else                                                            # nothing running: latest finish
      recent=$(ls "$dir"/*.stop.json 2>/dev/null | sort | tail -n 10)
      [ -n "$recent" ] && pick=$(printf '%s\n' "$recent" | tr '\n' '\0' | xargs -0 jq -rs 'max_by(.stopped_at) | .task_id // empty' 2>/dev/null)
      [ -z "$pick" ] && pick="$cur"
    fi
  fi
fi

# ---------- background jobs ----------
job_lines=(); jobs_due_max=0; running_jobs_for_pick=0; hidden_jobs=0
if [ -n "$sid" ] && [ -d "$dir/jobs" ]; then
  rows=$(jq -rn --argjson now "$now" --arg sep "$US" '
    [inputs | {id: (input_filename | split("/") | last | split(".") | .[0]), part: (input_filename | split("/") | last | split(".") | .[1]), v: .}]
    | group_by(.id) | map(reduce .[] as $x ({}; .[$x.part] = $x.v))
    | map(select(.job != null and (.job.started_at | type) == "number"))
    | map(select((.done == null and ($now - .job.started_at) < 86400) or (.done != null and ($now - (.done.finished_at // 0)) < 120)))
    | sort_by([(if .done == null then 0 else 1 end), .job.started_at]) | .[]
    | [.job.tool_use_id, .job.kind, .job.label, .job.started_at, (.job.task_id // ""),
       (.est.est_min // ""), (.est.high_min // ""), (.est.estimated_at // ""), (.est.revisions // 0),
       (.done.finished_at // ""), (.done.status // ""), (.job.output_file // ""), (.job.run_dir // ""), (.job.agent_transcript // "")]
    | map(tostring | gsub("[\n]"; " ")) | join($sep)' "$dir/jobs"/*.json 2>/dev/null)
  shown=0
  while IFS="$US" read -r jid kind label jstart jtask jest jhigh jestat jrev jfin jstatus jout jrun jat; do
    [ -n "$jid" ] && is_num "$jstart" || continue
    # Finished? Commands append an exit line to their output; workflows write a result file.
    if [ -z "$jfin" ]; then
      if [ "$kind" = command ] && [ -f "$jout" ]; then
        last=$(tail -n 1 "$jout" 2>/dev/null)
        if [[ "$last" =~ ^\[exited\ with\ code\ (-?[0-9]+)\]$ ]]; then
          jstatus=completed; [ "${BASH_REMATCH[1]}" != "0" ] && jstatus=failed
          jfin=$(stat -f %m "$jout" 2>/dev/null); mark_job_done "$sid" "$jid" "$jstatus" "$jfin"
        fi
      elif [ "$kind" = workflow ] && [ -s "$jout" ] && jq -e '.summary or .result' "$jout" >/dev/null 2>&1; then
        jstatus=completed; jfin=$(stat -f %m "$jout" 2>/dev/null); mark_job_done "$sid" "$jid" "$jstatus" "$jfin"
      fi
    fi
    case "$kind" in workflow) kn="Workflow" ;; agent) kn="Agent" ;; command) kn="Command" ;; *) kn="Job" ;; esac
    jel=$(( now - jstart ))
    if [ -n "$jfin" ] && is_num "$jfin"; then
      [ $(( now - jfin )) -lt 120 ] || continue
      if [ "$jstatus" = failed ]; then
        line="  ↳ ${RED}✗${R} ${kn}: ${label} ${D}· stopped after $(fmt_clock $(( jfin - jstart )))${R}"
      else
        was=""; is_num "$jest" && was=" · ETA was ~$(fmt_min "$jest")"
        line="  ↳ ${GRN}✓${R} ${kn}: ${label} ${D}· done in $(fmt_clock $(( jfin - jstart )))${was}${R}"
      fi
    else
      [ "$jtask" = "$pick" ] && running_jobs_for_pick=$(( running_jobs_for_pick + 1 ))
      prog=""
      case "$kind" in
        workflow) [ -f "$jrun/journal.jsonl" ] && prog=$(jq -rRn '[inputs | fromjson? | .type] | "\(map(select(. == "result" or . == "failed")) | length) of \(map(select(. == "started")) | length) agents finished"' "$jrun/journal.jsonl" 2>/dev/null) ;;
        agent) [ -f "$jat" ] && prog="$(grep -o '"type":"tool_use"' "$jat" 2>/dev/null | wc -l | tr -d ' ') tool calls" ;;
      esac
      if is_num "$jest"; then
        countdown "$jstart" "$jest" "$jhigh" "$jel"
        [ "$jtask" = "$pick" ] && [ "$cd_due" -gt "$jobs_due_max" ] && jobs_due_max=$cd_due
        upd=""; [ "${jrev:-0}" != "0" ] && is_num "$jestat" && upd=" · updated $(ago "$jestat")"
        line="  ↳ ${kn}: ${B}${label}${R} ${D}·${R} ${cd_txt} ${D}· $(fmt_clock "$jel") in${prog:+ · $prog}${upd}${R}"
      else
        line="  ↳ ${kn}: ${B}${label}${R} ${D}·${R} ${YEL}estimating…${R} ${D}· $(fmt_clock "$jel") in${prog:+ · $prog}${R}"
      fi
      maybe_update job "$jid" "$jestat" "$jest" "$jel"
    fi
    if [ "$shown" -lt 3 ]; then job_lines+=("$line"); shown=$(( shown + 1 )); else hidden_jobs=$(( hidden_jobs + 1 )); fi
  done <<< "$rows"
fi
if [ "$hidden_jobs" -gt 0 ]; then
  s="s"; [ "$hidden_jobs" = 1 ] && s=""
  job_lines+=("  ${D}↳ +$hidden_jobs more background job$s${R}")
fi

# ---------- line 1: the task ----------
line1="${D}⏱ ETA appears here when you send a prompt${R}"
if [ -n "$pick" ] && [ -f "$dir/$pick.task.json" ]; then
  args=(--slurpfile t "$dir/$pick.task.json")
  for k in est stop acct resumed; do
    if [ -f "$dir/$pick.$k.json" ]; then args+=(--slurpfile "$k" "$dir/$pick.$k.json"); else args+=(--argjson "$k" '[]'); fi
  done
  vars=$(jq -rn "${args[@]}" '
    $t[0] as $t | ($est[0] // {}) as $e | ($stop[0] // {}) as $s | ($acct[0] // {}) as $a | ($resumed[0] // null) as $r
    | {started: $t.started_at, transcript: ($t.transcript // ""),
       est: ($e.est_min // ""), low: ($e.low_min // ""), high: ($e.high_min // ""),
       etok: ($e.est_tokens // ""), epct: ($e.est_five_hour_pct // ""), label: ($e.label // ""),
       estimated: (if $e.task_id then 1 else 0 end), efailed: (if $e.failed then 1 else 0 end),
       estat: ($e.estimated_at // ""), erev: ($e.revisions // 0),
       outcome: (if $r != null then "running" else ($s.outcome // "running") end),
       stopped: ($s.stopped_at // ""), pending: (($s.pending // []) | length),
       interrupted_at: ($s.interrupted_at // ""),
       tokens: (if $a.stopped_at != null and $a.stopped_at == $s.stopped_at then $a.tokens else "" end)}
    | to_entries | map("\(.key)=\(.value | tostring | @sh)") | join("\n")' 2>/dev/null)
  started=""; eval "$vars"

  if is_num "$started"; then
    elapsed=$(( now - started ))
    if [ "$outcome" = "running" ] && [ "$pick" = "$cur" ] && [ -f "$transcript" ]; then
      # Esc or Ctrl+C never fires the Stop hook: look for the interrupt marker in the transcript.
      last=$(tail -c 262144 "$transcript" 2>/dev/null | grep -E '"type":"assistant"|(^|[^\\])"text":"\[Request interrupted by user' | tail -n 1)
      case "$last" in
        *'"text":"[Request interrupted by user'*)
          its=$(printf '%s' "$last" | jq -r "$JQ_DEFS"' ts' 2>/dev/null)
          if is_num "$its" && [ "$its" -ge "$started" ]; then outcome="interrupted"; interrupted_at="$its"; fi ;;
      esac
      # No activity for 15 minutes and nothing in the background: the finish was not recorded.
      if [ "$outcome" = "running" ] && [ "$elapsed" -gt 900 ] && [ "$running_jobs_for_pick" = 0 ]; then
        tm=$(stat -f %m "$transcript" 2>/dev/null || echo "$now")
        if [ $(( now - tm )) -gt 900 ] && [ -z "$(find "${transcript%.jsonl}/subagents" -name '*.jsonl' -mmin -15 2>/dev/null | head -n 1)" ]; then
          outcome="stalled"; stalled_at=$tm
        fi
      fi
    fi
    [ "$outcome" = "done" ] && [ -n "$interrupted_at" ] && outcome="interrupted"

    name=""; [ -n "$label" ] && name="${B}${label}${R} ${D}·${R} "
    tok=""
    if [ -n "$etok" ]; then tok=" ${D}·${R} ~$(fmt_tok "$etok") tokens"; [ -n "$epct" ] && tok="$tok ${D}(≈ ${epct}% of 5h)${R}"; fi
    case "$outcome" in
      running|waiting)
        if [ "$elapsed" -le 43200 ]; then
          wait_txt=""
          if [ "$outcome" = "waiting" ]; then s="s"; [ "$pending" = "1" ] && s=""; wait_txt="${YEL}waiting on $pending background job$s${R} ${D}·${R} "; fi
          if [ "$estimated" = "0" ]; then
            line1="⏱ ${wait_txt}${YEL}Estimating…${R} ${D}· $(fmt_clock "$elapsed") in${R}"
          elif [ "$efailed" = "1" ] || ! is_num "$est"; then
            line1="⏱ ${wait_txt}${YEL}ETA unavailable${R} ${D}· $(fmt_clock "$elapsed") in${R}"
          else
            show_est="$est"
            # The task is not done until its background jobs are: stretch its ETA to cover them.
            if [ "$jobs_due_max" -gt 0 ]; then
              jm=$(awk -v d="$(( jobs_due_max - started ))" 'BEGIN { printf "%.2f", d / 60 }')
              awk -v a="$jm" -v b="$est" 'BEGIN { exit !(a > b) }' && show_est="$jm"
            fi
            countdown "$started" "$show_est" "$high" "$elapsed"
            range=""
            [ "$show_est" = "$est" ] && [ "$cd_ontime" = 1 ] && is_num "$low" && is_num "$high" && range=" ${D}($(fmt_min "$low") to $(fmt_min "$high"))${R}"
            upd=""; [ "${erev:-0}" != "0" ] && is_num "$estat" && upd=" ${D}· updated $(ago "$estat")${R}"
            line1="⏱ ${name}${wait_txt}${cd_txt}${range} ${D}· $(fmt_clock "$elapsed") in${R}${tok}${upd}"
            maybe_update task "$pick" "$estat" "$est" "$elapsed"
          fi
        fi ;;
      stalled)
        line1="⏱ ${name}${D}no activity since $(clock_at "$stalled_at"), the finish was not recorded${R}" ;;
      interrupted)
        if is_num "$interrupted_at" && [ $(( now - interrupted_at )) -le 43200 ]; then
          line1="⏱ ${name}${YEL}Interrupted after $(fmt_clock $(( interrupted_at - started )))${R}"
        fi ;;
      done)
        if is_num "$stopped" && [ $(( now - stopped )) -le 43200 ]; then
          extra=""; is_num "$est" && extra=" ${D}· ETA was ~$(fmt_min "$est")${R}"
          if is_num "$tokens"; then
            extra="$extra ${D}·${R} used $(fmt_tok "$tokens") tokens"
            is_num "$etok" && extra="$extra ${D}(est ~$(fmt_tok "$etok"))${R}"
          fi
          line1="⏱ ${name}${GRN}Done in $(fmt_clock $(( stopped - started )))${R}${extra}"
        fi ;;
      error)
        if is_num "$stopped" && [ $(( now - stopped )) -le 43200 ]; then
          line1="⏱ ${name}${RED}Stopped by an API error after $(fmt_clock $(( stopped - started )))${R}"
        fi ;;
    esac
  fi
fi

# ---------- battery ----------
bar() {  # $1 percent used -> 10-cell bar, colored by how full it is
  local p=$1 n c i fill="" empty=""
  [ "$p" -gt 100 ] && p=100; [ "$p" -lt 0 ] && p=0
  n=$(( (p + 5) / 10 ))
  if [ "$p" -ge 85 ]; then c=$RED; elif [ "$p" -ge 60 ]; then c=$YEL; else c=$GRN; fi
  for (( i = 0; i < 10; i++ )); do if [ "$i" -lt "$n" ]; then fill="${fill}█"; else empty="${empty}░"; fi; done
  printf '%s%s%s%s%s%s' "$c" "${fill}" "$R" "$D" "${empty}" "$R"
}
gauge() {  # $1 name, $2 pct, $3 resets_at -> "5h ███░░░░░░░ 30%"
  local p="$2"
  if ! is_num "$p" || ! is_num "$3"; then printf '%s%s ░░░░░░░░░░ …%s' "$D" "$1" "$R"; return; fi
  [ "$3" -le "$now" ] && p=0
  printf '%s %s %s%s%%%s' "$1" "$(bar "$p")" "$B" "$p" "$R"
}
lim=$(cat "$LIMITS" 2>/dev/null)
h5_pct=""; h5_rs=""; wk_pct=""; wk_rs=""; fb_pct=""; fb_rs=""; fb_up=""; fb_label="Fable"
eval "$(jq -rn --arg lim "$lim" '
  ($lim | try fromjson catch {}) as $l
  | {h5_pct: $l.five_hour.pct, h5_rs: $l.five_hour.resets_at, wk_pct: $l.seven_day.pct, wk_rs: $l.seven_day.resets_at,
     fb_pct: $l.fable_week.pct, fb_rs: $l.fable_week.resets_at, fb_up: $l.fable_week.updated_at, fb_label: ($l.fable_week.label // "Fable")}
  | to_entries | map("\(.key)=\(.value // "" | tostring | @sh)") | join("\n")' 2>/dev/null)"

when5=""
if is_num "$h5_rs"; then
  if [ "$h5_rs" -le "$now" ]; then when5=" ${D}(reset)${R}"; else when5=" ${D}(resets $(clock_at "$h5_rs"))${R}"; fi
fi
fstale=""; is_num "$fb_up" && [ $(( now - fb_up )) -gt 1800 ] && fstale=" ${D}as of $(clock_at "$fb_up")${R}"
weekly=""
if is_num "$wk_rs" && [ "$wk_rs" -gt "$now" ]; then
  weekly="  ${D}(weekly resets $(date -r "$wk_rs" '+%a %-I %p' 2>/dev/null))${R}"
  if is_num "$fb_rs" && [ "$fb_rs" -gt "$now" ] && { [ $(( fb_rs - wk_rs )) -gt 3600 ] || [ $(( wk_rs - fb_rs )) -gt 3600 ]; }; then
    weekly="$weekly ${D}(${fb_label} resets $(date -r "$fb_rs" '+%a %-I %p' 2>/dev/null))${R}"
  fi
fi
battery="🔋 $(gauge 5h "$h5_pct" "$h5_rs")${when5}  $(gauge Week "$wk_pct" "$wk_rs")  $(gauge "$fb_label" "$fb_pct" "$fb_rs")${fstale}${weekly}"

# Fable has no status line data: check it (detached, at most every 10 minutes) while you are working.
if ! is_num "$fb_up" || [ $(( now - fb_up )) -ge 600 ]; then
  if [ -n "$tpath" ] && [ -n "$(find "$tpath" -mmin -30 2>/dev/null)" ] && [ -z "$(find "$ETA_DIR/probe.last" -mmin -10 2>/dev/null)" ]; then
    spawn_detached bash "$HOOK_DIR/probe.sh"
  fi
fi

printf '%s\n' "$line1"
for l in "${job_lines[@]}"; do printf '%s\n' "$l"; done
printf '%s\n' "$battery"
exit 0
