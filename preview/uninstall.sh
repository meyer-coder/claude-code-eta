#!/bin/bash
# preview uninstaller. Removes the loader lines the installer added to ~/.zshrc and the script.
# Keeps your recent-folder history unless you add --purge:
#   curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/preview/uninstall.sh | bash -s -- --purge
set -euo pipefail
ZSHRC="$HOME/.zshrc"
purge=0; [ "${1:-}" = "--purge" ] && purge=1
if [ -f "$ZSHRC" ] && grep -qF '# >>> preview (claude-code-eta) >>>' "$ZSHRC"; then
  cp "$ZSHRC" "$ZSHRC.bak-preview-uninstall-$(date +%Y%m%d-%H%M%S)"
  tmp=$(mktemp)
  awk '/^# >>> preview \(claude-code-eta\) >>>$/ {skip=1; next} /^# <<< preview \(claude-code-eta\) <<<$/ {skip=0; next} !skip' "$ZSHRC" > "$tmp" && cat "$tmp" > "$ZSHRC"
  rm -f "$tmp"
  echo "Removed preview from $ZSHRC."
elif [ -f "$ZSHRC" ] && grep -qF '.config/preview/preview.zsh' "$ZSHRC"; then
  echo "Note: $ZSHRC loads preview with a line the installer did not add; remove it yourself if you no longer want preview."
fi
if [ -f "$HOME/.config/preview/preview.zsh" ]; then rm -f "$HOME/.config/preview/preview.zsh"; echo "Removed $HOME/.config/preview/preview.zsh."; fi
if [ "$purge" = 1 ] && [ -d "$HOME/.config/preview" ]; then rm -rf "$HOME/.config/preview"; echo "Removed preview history."; fi
