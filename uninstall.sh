#!/bin/bash
# Claude Code ETA uninstaller. Removes the ETA hooks and status line, and puts back the status line
# you had before installing.
#
#   curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/uninstall.sh | bash
#
# To also delete the ETA history and state in ~/.claude/eta, add --purge:
#   curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/uninstall.sh | bash -s -- --purge
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
DEST="$CLAUDE_DIR/hooks/eta"
DATA="$CLAUDE_DIR/eta"
SETTINGS="$CLAUDE_DIR/settings.json"
purge=0; [ "${1:-}" = "--purge" ] && purge=1

command -v jq >/dev/null 2>&1 || { echo "Uninstall stopped: jq was not found (brew install jq)." >&2; exit 1; }

if [ -f "$SETTINGS" ]; then
  if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "Uninstall stopped: $SETTINGS is not valid JSON. Fix it, then run this again." >&2; exit 1
  fi
  if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
    echo "Uninstall stopped: $SETTINGS must be a JSON object (it should start with {). Fix it, then run this again." >&2; exit 1
  fi
  backup="$SETTINGS.bak-eta-uninstall-$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS" "$backup"
  prev='null'
  if [ -f "$DATA/previous-statusline.json" ] && jq -e . "$DATA/previous-statusline.json" >/dev/null 2>&1; then
    prev=$(cat "$DATA/previous-statusline.json")
  fi
  tmp=$(mktemp)
  jq --argjson prev "$prev" '
    # Remove only our own hook commands; a group that also holds any other hook in it stays.
    def is_ours: type == "object" and ((.command // "") | tostring | contains("hooks/eta/"));
    def strip_ours: map(if type == "object" and (.hooks | type) == "array"
                        then ((.hooks | length) as $n | .hooks |= map(select(is_ours | not))
                              | if $n > 0 and (.hooks | length) == 0 then empty else . end)
                        else . end);
    (if (.hooks | type) == "object" then
       .hooks |= with_entries(if (.value | type) == "array"
                              then ((.value | length) as $n | .value |= strip_ours
                                    | if $n > 0 and (.value | length) == 0 then empty else . end)
                              else . end)
     else . end)
    | (if .hooks == {} then del(.hooks) else . end)
    | (if (.statusLine | type) == "object" and ((.statusLine.command // "") | tostring | contains("hooks/eta/statusline.sh"))
       then (if $prev != null then .statusLine = $prev else del(.statusLine) end) else . end)
  ' "$SETTINGS" > "$tmp"
  if jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    cp "$tmp" "$SETTINGS"
    echo "Removed the ETA hooks and status line from $SETTINGS (backup: $backup)."
  else
    echo "Could not update $SETTINGS, so it was left unchanged. Backup: $backup" >&2
  fi
  rm -f "$tmp"
fi

if [ -d "$DEST" ]; then rm -rf "$DEST"; echo "Removed $DEST."; fi
if [ -d "$DATA" ]; then
  if [ "$purge" = 1 ]; then rm -rf "$DATA"; echo "Removed $DATA."
  else echo "Kept your ETA history in $DATA. Run with --purge to delete it."; fi
fi
