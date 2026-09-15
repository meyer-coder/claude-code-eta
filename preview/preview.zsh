# preview — arrow-key menu of your most recently used directories/repos.
# Usage: type `preview`, use ↑/↓ (or j/k), Enter to cd + launch Claude Code, Esc/q to cancel.
# PREVIEW_AUTO_CLAUDE=0 to only cd; PREVIEW_CLAUDE_PROMPT to change the kickoff prompt.

PREVIEW_HISTORY="${PREVIEW_HISTORY:-$HOME/.config/preview/history}"
PREVIEW_COUNT="${PREVIEW_COUNT:-5}"

# Prompt Claude Code is started with after you pick a repo.
PREVIEW_CLAUDE_PROMPT="${PREVIEW_CLAUDE_PROMPT:-Kick off this session by figuring out where this repo stands and what to do next. \
Look at: the last 15-20 commits (git log --stat), uncommitted changes (git status, git diff --stat), the current branch vs main, \
CLAUDE.md / README / any TODO, NOTES or roadmap files, and open TODO/FIXME comments in recently touched files. \
Then give me: (1) a short summary of what we were most recently working on and where it was left, \
(2) anything half-done, broken, or uncommitted that needs attention first, and \
(3) a prioritized list of 3-5 concrete things to get done in this session. Keep it brief, then ask me which one to start on.}"

# Record every directory you cd into (most recent first, deduped).
_preview_record() {
  local dir="$PWD"
  [[ "$dir" == "$HOME" ]] && return
  local tmp="$PREVIEW_HISTORY.tmp"
  { print -r -- "$dir"; [[ -f "$PREVIEW_HISTORY" ]] && grep -vxF -- "$dir" "$PREVIEW_HISTORY"; } \
    | head -n 100 > "$tmp" && mv "$tmp" "$PREVIEW_HISTORY"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _preview_record

# Collect candidates: history first, then any git repos under ~/projects as fallback.
_preview_candidates() {
  local -a seen
  local d
  if [[ -f "$PREVIEW_HISTORY" ]]; then
    while IFS= read -r d; do
      [[ -d "$d" && "$d" != "$PWD" ]] || continue
      (( ${seen[(Ie)$d]} )) && continue
      seen+=("$d"); print -r -- "$d"
    done < "$PREVIEW_HISTORY"
  fi
  for d in "$HOME"/projects/*(N/om); do
    d="${d%/}"
    [[ -d "$d/.git" && "$d" != "$PWD" ]] || continue
    (( ${seen[(Ie)$d]} )) && continue
    seen+=("$d"); print -r -- "$d"
  done
}

preview() {
  local -a items
  items=("${(@f)$(_preview_candidates | head -n "$PREVIEW_COUNT")}")
  items=("${(@)items:#}")
  if (( ${#items} == 0 )); then
    print "preview: no recent directories yet — cd somewhere first."
    return 1
  fi

  # Pad empty slots with N/A so the list is always PREVIEW_COUNT rows.
  local real=${#items}
  while (( ${#items} < PREVIEW_COUNT )); do items+=("N/A"); done

  local sel=1 key label k2 k3 seq
  local n=${#items}

  _preview_draw() {
    local i
    for (( i = 1; i <= n; i++ )); do
      if [[ "${items[$i]}" == "N/A" ]]; then
        print -P -- "    %F{8}N/A%f"
        continue
      fi
      label="${items[$i]/#$HOME/~}"
      [[ -d "${items[$i]}/.git" ]] && label="$label  (git)"
      if (( i == sel )); then
        print -P -- "  %F{cyan}%B❯ $label%b%f"
      else
        print -- "    $label"
      fi
    done
  }

  print -P "%F{yellow}Recent:%f  ↑/↓ move · Enter open · Esc quit"
  _preview_draw
  tput civis 2>/dev/null

  while true; do
    read -sk1 key || { key=ESC; }
    case "$key" in
      $'\e')
        # Escape sequence: read the rest of it (CSI "\e[...X" / SS3 "\eOX").
        # A bare Esc with nothing after it quits.
        if read -sk1 -t 0.05 k2; then
          seq="$k2"
          if [[ "$k2" == "[" || "$k2" == "O" ]]; then
            while read -sk1 -t 0.05 k3; do
              seq+="$k3"
              (( #k3 >= 64 && #k3 <= 126 )) && break   # final byte of the sequence
            done
          fi
          case "$seq" in
            "["*A|OA)        key=UP ;;
            "["*B|OB)        key=DOWN ;;
            OM|"[13"*u)      key=ENTER ;;   # keypad Enter / CSI-u Return
            *)               key=NONE ;;    # anything else: ignore
          esac
        else
          key=ESC
        fi ;;
      k) key=UP ;;
      j) key=DOWN ;;
      q) key=ESC ;;
      $'\n'|$'\r') key=ENTER ;;   # Return, Enter, Ctrl-M, Ctrl-J
    esac

    # Cursor only moves across real entries; N/A rows are skipped.
    case "$key" in
      UP)   (( sel = sel > 1 ? sel - 1 : real )) ;;
      DOWN) (( sel = sel < real ? sel + 1 : 1 )) ;;
      ENTER|ESC) break ;;
      *) continue ;;
    esac

    # redraw in place
    tput cuu "$n" 2>/dev/null
    _preview_draw
  done

  tput cnorm 2>/dev/null
  unfunction _preview_draw

  if [[ "$key" == ENTER ]]; then
    cd -- "${items[$sel]}" || return 1
    print -P "%F{green}→%f ${PWD/#$HOME/~}"
    # Launch Claude Code in the repo with a session-kickoff prompt.
    # Set PREVIEW_AUTO_CLAUDE=0 to just cd without launching.
    if [[ "${PREVIEW_AUTO_CLAUDE:-1}" == 1 ]] && command -v claude >/dev/null; then
      command claude "$PREVIEW_CLAUDE_PROMPT"
    fi
  fi
}
