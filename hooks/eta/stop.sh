#!/bin/bash
# Workflow ETA: Stop and StopFailure hook (sync, fast).
# Finishes the turn that just ended: tasks resumed by one of their background jobs, and the current
# task (done, waiting on background jobs it launched, or failed), then counts their tokens.
[ -n "$CLAUDE_ETA_HOOK" ] && exit 0
. "$HOME/.claude/hooks/eta/lib.sh" || exit 0

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // "Stop"' 2>/dev/null)
[ -z "$sid" ] && exit 0
case "$sid" in */*|.*) exit 0 ;; esac
dir="$STATE_DIR/$sid"
[ -d "$dir" ] || exit 0

for rf in "$dir"/*.resumed.json; do
  [ -f "$rf" ] || continue
  finalize_task "$sid" "$(basename "$rf" .resumed.json)" "$rf" "$event" sync
done

# The current task's first Stop is final. A later Stop with no new prompt is a wake-up for
# something else (another task's job, an artifact comment) and must not re-time this task.
cur=$(cat "$dir/current" 2>/dev/null)
if [ -n "$cur" ] && [ -f "$dir/$cur.task.json" ] && [ ! -f "$dir/$cur.stop.json" ] && [ ! -f "$dir/$cur.resumed.json" ]; then
  finalize_task "$sid" "$cur" "" "$event" sync
fi
exit 0
