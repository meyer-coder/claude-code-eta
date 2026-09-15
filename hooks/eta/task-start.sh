#!/bin/bash
# Workflow ETA: UserPromptSubmit hook (sync, fast; runs before Claude starts on the prompt).
# A new prompt starts a task, so the Stop hook always finds it. A <task-notification> marks that
# background job finished and resumes the task that launched it, or updates that task in place
# when a different task is mid-turn (so the other task's turn is never booked to it).
[ -n "$CLAUDE_ETA_HOOK" ] && exit 0
. "$HOME/.claude/hooks/eta/lib.sh" || exit 0

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$sid" ] || [ -z "$prompt" ]; then exit 0; fi
case "$sid" in */*|.*) exit 0 ;; esac
dir="$STATE_DIR/$sid"
mkdir -p "$dir" 2>/dev/null || exit 0
now=$(date +%s)

case "$(prompt_kind "$prompt")" in
  skip) exit 0 ;;
  notification)
    tuid=$(printf '%s' "$prompt" | sed -n 's/.*<tool-use-id>\([^<]*\)<\/tool-use-id>.*/\1/p' | head -n 1)
    [ -z "$tuid" ] && exit 0
    case "$tuid" in */*|.*) exit 0 ;; esac
    status=$(printf '%s' "$prompt" | sed -n 's/.*<status>\([^<]*\)<\/status>.*/\1/p' | head -n 1)
    job_status=completed
    case "$status" in failed*|killed*|error*|cancel*) job_status=failed ;; esac
    printf '%s' "$prompt" | grep -Eq 'exit code [1-9][0-9]*\)' && job_status=failed
    mark_job_done "$sid" "$tuid" "$job_status" "$now"

    cur=$(cat "$dir/current" 2>/dev/null); busy=0
    if [ -n "$cur" ] && [ -f "$dir/$cur.task.json" ] && [ ! -f "$dir/$cur.stop.json" ] && [ ! -f "$dir/$cur.resumed.json" ]; then busy=1; fi
    open_resume=$(ls "$dir"/*.resumed.json 2>/dev/null | head -n 1)   # a resumed task's turn is still open
    for sf in "$dir"/*.stop.json; do
      [ -f "$sf" ] || continue
      tid=$(basename "$sf" .stop.json)
      jq -e --arg u "$tuid" '(.pending // []) | index($u) != null' "$sf" >/dev/null 2>&1 || continue
      if { [ "$busy" = 1 ] && [ "$tid" != "$cur" ]; } || [ -n "$open_resume" ]; then
        complete_waiting "$sid" "$tid" "$tuid" "$now"
      else
        jq -c --arg u "$tuid" --argjson now "$now" '{prev: ., resume_ids: [$u], resumed_at: $now}' "$sf" \
          | write_atomic "$dir/$tid.resumed.json" && rm -f "$sf"
      fi
    done
    for rf in "$dir"/*.resumed.json; do   # several jobs of one task finishing close together
      [ -f "$rf" ] || continue
      if jq -e --arg u "$tuid" '(.prev.pending // []) | index($u) != null' "$rf" >/dev/null 2>&1; then
        jq -c --arg u "$tuid" '.resume_ids = ((.resume_ids + [$u]) | unique)' "$rf" | write_atomic "$rf"
      fi
    done
    exit 0 ;;
esac

tid="$now-$(printf '%s' "$input" | md5 | cut -c1-8)"    # estimate.sh finds its task by this input hash
offset=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  size=$(stat -f %z "$transcript" 2>/dev/null || echo 0)
  [ "$size" -gt 65536 ] && offset=$(( size - 65536 ))
fi
jq -cn --arg tid "$tid" --arg sid "$sid" --argjson t "$now" --arg p "$prompt" --arg tp "$transcript" \
  --argjson off "$offset" --arg lim "$(cat "$LIMITS" 2>/dev/null)" '
  {task_id: $tid, session_id: $sid, started_at: $t, prompt: ($p | gsub("\\s+"; " ") | .[0:120]),
   transcript: $tp, offset: $off, limits_start: ($lim | try fromjson catch {})}' \
  | write_atomic "$dir/$tid.task.json" || exit 0
printf '%s' "$tid" | write_atomic "$dir/current"

# Keep each session to its newest 50 tasks, and drop anything older than a week.
ls "$dir"/*.task.json 2>/dev/null | sort -r | tail -n +51 | while IFS= read -r old; do
  t=$(basename "$old" .task.json); rm -f "$dir/$t".*.json
done
if [ -d "$dir/jobs" ]; then
  find "$dir/jobs" -name '*.done.json' -mmin +60 2>/dev/null | while IFS= read -r df; do
    j=$(basename "$df" .done.json); rm -f "$dir/jobs/$j.job.json" "$dir/jobs/$j.est.json" "$df"
  done
fi
find "$STATE_DIR" -mindepth 2 -type f \( -name '*.json' -o -name 'current' \) -mtime +7 -delete 2>/dev/null
find "$STATE_DIR" -mindepth 2 -type f -name '*.tmp.*' -mmin +10 -delete 2>/dev/null
find "$STATE_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null
exit 0
