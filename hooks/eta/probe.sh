#!/bin/bash
# Workflow ETA: refresh the Fable weekly limit reading.
# Claude Code's status line data has no Fable window, but a tiny Fable request reports every
# usage window, including the weekly one that covers Fable models. Runs at most once every
# 10 minutes across all sessions, and only when estimate.sh calls it (you sent a prompt).
. "$HOME/.claude/hooks/eta/lib.sh" || exit 0
export CLAUDE_ETA_HOOK=1

stamp="$ETA_DIR/probe.last"
[ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ] && exit 0
lock="$ETA_DIR/probe.lock"
if ! mkdir "$lock" 2>/dev/null; then
  [ -n "$(find "$lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] || exit 0   # another probe is running
  rm -rf "$lock"; mkdir "$lock" 2>/dev/null || exit 0                    # stale lock from a crash
fi
trap 'rmdir "$lock" 2>/dev/null' EXIT
touch "$stamp"

out=$(printf 'Reply with exactly: OK' | perl -e 'alarm shift; exec @ARGV' 60 claude -p \
  --model claude-fable-5-1 --effort low --system-prompt "Reply tersely." \
  --output-format stream-json --verbose --tools "" --no-session-persistence \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources "" \
  --settings '{"disableClaudeAiConnectors":true}' --disable-slash-commands 2>>"$LOG")

# Name the extra weekly window after the models Claude Code lists for it (currently Fable).
label=$(jq -r '(.cachedGrowthBookFeatures.tengu_usage_overage_included_models // [])
  | if any(.[]; tostring | test("fable"; "i")) then "Fable" else "Extra" end' "$HOME/.claude.json" 2>/dev/null)
windows=$(printf '%s\n' "$out" | jq -cR 'fromjson? | select(.type == "rate_limit_event") | .rate_limit_info.unifiedWindows // empty' 2>/dev/null \
  | tail -n 1 | jq -c --arg label "${label:-Fable}" '
    to_entries
    | map(select((.value.utilization | type) == "number" and (.value.resetsAt | type) == "number")
          | if .key == "seven_day_overage_included"
            then {key: "fable_week", value: {pct: (.value.utilization * 100 | round), resets_at: .value.resetsAt, label: $label}}
            else {key: .key, value: {pct: (.value.utilization * 100 | round), resets_at: .value.resetsAt}} end)
    | from_entries' 2>/dev/null)
if [ -z "$windows" ] || [ "$windows" = "{}" ]; then
  eta_log "probe: no usage windows in Fable response: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  exit 0
fi
merge_limits "$windows" wait
