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
  if ! jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1; then
    echo "Uninstall stopped: $SETTINGS is not valid JSON. Fix it, then run this again." >&2; exit 1
  fi
  backup="$SETTINGS.bak-eta-uninstall-$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS" "$backup"
  prev='null'
  if [ -f "$DATA/previous-statusline.json" ] && jq -e . "$DATA/previous-statusline.json" >/dev/null 2>&1; then
    prev=$(cat "$DATA/previous-statusline.json")
  fi
  tmp=$(mktemp)
  jq --argjson prev "$prev" '
    def mine: (.hooks // []) | any(.[]; (.command // "") | tostring | contains("hooks/eta/"));
    (if (.hooks | type) == "object" then
       .hooks |= (with_entries(.value |= (if type == "array" then map(select(mine | not)) else . end))
                  | with_entries(select((.value | type) != "array" or (.value | length) > 0)))
     else . end)
    | (if .hooks == {} then del(.hooks) else . end)
    | (if ((.statusLine.command // "") | tostring | contains("hooks/eta/statusline.sh"))
       then (if $prev != null then .statusLine = $prev else del(.statusLine) end) else . end)
  ' "$SETTINGS" > "$tmp"
  jq -e 'type == "object"' "$tmp" >/dev/null && cp "$tmp" "$SETTINGS"
  rm -f "$tmp"
  echo "Removed the ETA hooks and status line from $SETTINGS (backup: $backup)."
fi

rm -rf "$DEST"
echo "Removed $DEST."
if [ "$purge" = 1 ]; then
  rm -rf "$DATA"
  echo "Removed $DATA."
else
  echo "Kept your ETA history in $DATA. Run with --purge to delete it."
fi
