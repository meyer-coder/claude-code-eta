#!/bin/bash
# Claude Code ETA installer.
# Adds a live ETA for every task and background job, plus a usage battery, to the Claude Code status line.
#
#   curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/install.sh | bash
#
# Running it again updates the scripts. Your other hooks and settings are kept, and
# ~/.claude/settings.json is backed up before anything changes.
set -euo pipefail

REPO_RAW="${ETA_REPO_RAW:-https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main}"
CLAUDE_DIR="$HOME/.claude"
DEST="$CLAUDE_DIR/hooks/eta"
DATA="$CLAUDE_DIR/eta"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPTS="lib.sh task-start.sh estimate.sh stop.sh account.sh job-start.sh job-done.sh reestimate.sh probe.sh statusline.sh"

stop_install() { printf '\nInstall stopped: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || stop_install "this version runs on macOS only. It relies on the macOS versions of stat, date and md5."
for tool in jq perl curl claude; do
  command -v "$tool" >/dev/null 2>&1 || stop_install "'$tool' was not found. Install it (for jq: brew install jq), then run the installer again."
done

echo "Installing Claude Code ETA into $DEST"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# From a cloned copy, use its files. Piped from curl, download them.
local_src=""
self="${BASH_SOURCE[0]:-}"
if [ -n "$self" ] && [ -f "$self" ] && [ -f "$(dirname "$self")/hooks/eta/lib.sh" ]; then
  local_src="$(cd "$(dirname "$self")" && pwd)/hooks/eta"
fi
for s in $SCRIPTS; do
  if [ -n "$local_src" ]; then
    cp "$local_src/$s" "$work/$s"
  else
    curl -fsSL "$REPO_RAW/hooks/eta/$s" -o "$work/$s" || stop_install "could not download $s from $REPO_RAW. Nothing was changed."
  fi
  bash -n "$work/$s" || stop_install "$s did not pass a syntax check. Nothing was changed."
done

mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
  || stop_install "$SETTINGS is not valid JSON. Fix it, then run the installer again. Nothing was changed."

mkdir -p "$DEST" "$DATA"
for s in $SCRIPTS; do install -m 755 "$work/$s" "$DEST/$s"; done

stamp=$(date +%Y%m%d-%H%M%S)
backup="$SETTINGS.bak-eta-$stamp"
cp "$SETTINGS" "$backup"

# Keep a status line you already had, so uninstall.sh can put it back.
if jq -e '.statusLine != null and (((.statusLine.command // "") | contains("hooks/eta/statusline.sh")) | not)' "$SETTINGS" >/dev/null 2>&1; then
  jq '.statusLine' "$SETTINGS" > "$DATA/previous-statusline.json"
  echo "Your existing status line was saved to $DATA/previous-statusline.json. Uninstalling puts it back."
fi

jq '
  def mine: (.hooks // []) | any(.[]; (.command // "") | tostring | contains("hooks/eta/"));
  def keep_others: if type == "array" then map(select(mine | not)) else [] end;
  def cmd(file; extra): {type: "command", command: ("bash \"$HOME/.claude/hooks/eta/" + file + "\"")} + extra;
  .hooks = (.hooks // {})
  | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit | keep_others)
      + [{hooks: [cmd("task-start.sh"; {timeout: 10})]}, {hooks: [cmd("estimate.sh"; {async: true, timeout: 120})]}])
  | .hooks.Stop = ((.hooks.Stop | keep_others) + [{hooks: [cmd("stop.sh"; {timeout: 30})]}])
  | .hooks.StopFailure = ((.hooks.StopFailure | keep_others) + [{hooks: [cmd("stop.sh"; {timeout: 30})]}])
  | .hooks.PostToolUse = ((.hooks.PostToolUse | keep_others)
      + [{matcher: "Workflow|Agent|Task|Bash", hooks: [cmd("job-start.sh"; {async: true, timeout: 120})]}])
  | .hooks.SubagentStop = ((.hooks.SubagentStop | keep_others) + [{hooks: [cmd("job-done.sh"; {async: true, timeout: 10})]}])
  | .statusLine = {type: "command", command: "bash \"$HOME/.claude/hooks/eta/statusline.sh\"", refreshInterval: 1}
' "$SETTINGS" > "$work/settings.json" || stop_install "could not update settings. Your settings were not changed."
jq -e 'type == "object"' "$work/settings.json" >/dev/null || stop_install "could not update settings. Your settings were not changed."
cp "$work/settings.json" "$SETTINGS"

if jq -e '.disableAllHooks == true' "$SETTINGS" >/dev/null 2>&1; then
  echo "Note: disableAllHooks is on in $SETTINGS, so the ETA will not run until you turn hooks back on."
fi

cat <<DONE

Installed.
  Open Claude Code and send a prompt. Sessions that are already open pick this up on
  their own; if the status line does not change, restart Claude Code.
  Settings backup: $backup
  Remove it any time:
    curl -fsSL $REPO_RAW/uninstall.sh | bash
DONE
