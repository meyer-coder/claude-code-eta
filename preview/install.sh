#!/bin/bash
# preview installer: an arrow-key menu of your 5 most recently used folders and repos, for zsh.
#
#   curl -fsSL https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main/preview/install.sh | bash
#
# Installs ~/.config/preview/preview.zsh and adds one loader line to ~/.zshrc (backed up first).
set -euo pipefail
REPO_RAW="${ETA_REPO_RAW:-https://raw.githubusercontent.com/meyer-coder/claude-code-eta/main}"
DIR="$HOME/.config/preview"
ZSHRC="$HOME/.zshrc"
stop_install() { printf '\nInstall stopped: %s\n' "$*" >&2; exit 1; }

command -v zsh >/dev/null 2>&1 || stop_install "preview needs zsh, which was not found."
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
self="${BASH_SOURCE[0]:-}"
if [ -n "$self" ] && [ -f "$self" ] && [ -f "$(dirname "$self")/preview.zsh" ]; then
  cp "$(dirname "$self")/preview.zsh" "$work/preview.zsh"
else
  curl -fsSL "$REPO_RAW/preview/preview.zsh" -o "$work/preview.zsh" || stop_install "could not download preview.zsh. Nothing was changed."
fi
zsh -n "$work/preview.zsh" || stop_install "preview.zsh did not pass a syntax check. Nothing was changed."

mkdir -p "$DIR"
install -m 644 "$work/preview.zsh" "$DIR/preview.zsh"
if grep -qF '.config/preview/preview.zsh' "$ZSHRC" 2>/dev/null; then
  note="It was already loaded from $ZSHRC."
else
  [ -f "$ZSHRC" ] && cp "$ZSHRC" "$ZSHRC.bak-preview-$(date +%Y%m%d-%H%M%S)"
  printf '\n# >>> preview (claude-code-eta) >>>\nsource "$HOME/.config/preview/preview.zsh"\n# <<< preview (claude-code-eta) <<<\n' >> "$ZSHRC"
  note="Added one line to $ZSHRC to load it."
fi
case "${SHELL:-}" in */zsh) ;; *) note="$note Your shell is not zsh, so preview works after you switch to zsh." ;; esac
cat <<DONE

preview installed. $note
  Open a new Terminal window and type  preview
  Remove it any time:
    curl -fsSL $REPO_RAW/preview/uninstall.sh | bash
DONE
