#!/bin/bash
# Workflow ETA: SubagentStop hook (async). A background agent finished: mark its job done right away.
[ -n "$CLAUDE_ETA_HOOK" ] && exit 0
. "$HOME/.claude/hooks/eta/lib.sh" || exit 0
input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
aid=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
[ -n "$sid" ] && [ -n "$aid" ] || exit 0
case "$sid$aid" in */*|.*) exit 0 ;; esac
jd="$STATE_DIR/$sid/jobs"
[ -d "$jd" ] || exit 0
f=$(grep -l -F "\"bg_id\":\"$aid\"" "$jd"/*.job.json 2>/dev/null | head -n 1)
[ -n "$f" ] || exit 0          # workflow agents and foreground agents are not tracked as jobs
mark_job_done "$sid" "$(basename "$f" .job.json)" completed "$(date +%s)"
exit 0
