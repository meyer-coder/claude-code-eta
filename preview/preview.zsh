# preview: arrow-key menu of your most recently used git repos (your projects).
# Usage: type `preview`, use ↑/↓ (or j/k), Enter to cd + launch Claude Code, Esc/q to cancel.
#
# Settings (set them in ~/.zshrc before the line that loads this file):
#   PREVIEW_COUNT=5             how many projects to list
#   PREVIEW_AUTO_CLAUDE=1       0 to only cd, without starting Claude Code
#   PREVIEW_CLAUDE_PROMPT="..." the prompt Claude Code starts with
#   PREVIEW_GIT_ONLY=1          0 to also list recent folders that are not git repos
#   PREVIEW_ROOTS="..."         folders whose git repos are projects even before you cd into them

zmodload zsh/datetime 2>/dev/null
zmodload -F zsh/stat b:zstat 2>/dev/null

PREVIEW_HISTORY="${PREVIEW_HISTORY:-$HOME/.config/preview/history}"
PREVIEW_COUNT="${PREVIEW_COUNT:-5}"
PREVIEW_GIT_ONLY="${PREVIEW_GIT_ONLY:-1}"
PREVIEW_ROOTS="${PREVIEW_ROOTS:-$HOME/projects $HOME/code $HOME/dev $HOME/src $HOME/repos $HOME/Developer $HOME/GitHub $HOME/Documents/GitHub}"

# Prompt Claude Code is started with after you pick a project.
PREVIEW_CLAUDE_PROMPT="${PREVIEW_CLAUDE_PROMPT:-Kick off this session by figuring out where this repo stands and what to do next. \
Look at: the last 15-20 commits (git log --stat), uncommitted changes (git status, git diff --stat), the current branch vs main, \
CLAUDE.md / README / any TODO, NOTES or roadmap files, and open TODO/FIXME comments in recently touched files. \
Then give me: (1) a short summary of what we were most recently working on and where it was left, \
(2) anything half-done, broken, or uncommitted that needs attention first, and \
(3) a prioritized list of 3-5 concrete things to get done in this session. Keep it brief, then ask me which one to start on.}"

# Record every directory you cd into, newest first, as "<epoch> <dir>".
_preview_record() {
  local dir="$PWD"
  [[ "$dir" == "$HOME" ]] && return
  mkdir -p "${PREVIEW_HISTORY:h}" 2>/dev/null
  local tmp="$PREVIEW_HISTORY.tmp.$$"
  { print -r -- "$EPOCHSECONDS $dir"
    [[ -f "$PREVIEW_HISTORY" ]] && awk -v d="$dir" '{ p = $0; sub(/^[0-9]+ /, "", p); if (p != d) print }' "$PREVIEW_HISTORY"
  } | head -n 200 > "$tmp" && mv "$tmp" "$PREVIEW_HISTORY"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _preview_record

# The git repo that contains $1 (stops below $HOME, so a dotfiles repo in ~ is not every folder). Sets REPLY.
_preview_repo_root() {
  local d="$1"
  while [[ -n "$d" && "$d" != "/" && "$d" != "$HOME" ]]; do
    if [[ -e "$d/.git" ]]; then REPLY="$d"; return 0; fi
    d="${d:h}"
  done
  return 1
}

# When git last recorded work in repo $1: the newest of its index, HEAD, reflog and fetch files. Sets REPLY.
_preview_git_time() {
  local g="$1/.git" f line best=0
  local -a t
  if [[ -f "$g" ]]; then   # worktree or submodule: .git is a file that points at the real git folder
    read -r line < "$g"; g="${line#gitdir: }"; [[ "$g" != /* ]] && g="$1/$g"
  fi
  for f in "$g/index" "$g/HEAD" "$g/logs/HEAD" "$g/FETCH_HEAD"; do
    [[ -e "$f" ]] || continue
    zstat -A t +mtime -- "$f" 2>/dev/null || continue
    (( t[1] > best )) && best=${t[1]}
  done
  REPLY=$best
}

# Projects, newest first, as "<epoch> <dir>".
_preview_candidates() {
  local -A when
  local line t d root hist_time=0 i=0
  local -a mt
  if [[ -f "$PREVIEW_HISTORY" ]]; then
    zstat -A mt +mtime -- "$PREVIEW_HISTORY" 2>/dev/null && hist_time=${mt[1]}
    while IFS= read -r line; do
      (( i++ ))
      if [[ "$line" == <->" "* ]]; then t="${line%% *}"; d="${line#* }"
      else t=$(( hist_time - i )); d="$line"; fi      # older lines have no time: keep their order
      [[ -d "$d" ]] || continue
      if _preview_repo_root "$d"; then d="$REPLY"
      elif [[ "$PREVIEW_GIT_ONLY" == 1 ]]; then continue; fi
      (( ${when[$d]:-0} < t )) && when[$d]=$t
    done < "$PREVIEW_HISTORY"
  fi
  for root in ${=PREVIEW_ROOTS}; do
    for d in "$root"/*(N/); do
      [[ -e "$d/.git" ]] && when[$d]=${when[$d]:-0}
    done
  done
  for d in ${(k)when}; do                               # work in a repo without cd (for example in Claude Code) counts too
    [[ -e "$d/.git" ]] || continue
    _preview_git_time "$d"
    (( REPLY > ${when[$d]} )) && when[$d]=$REPLY
  done
  for d in ${(k)when}; do
    [[ "$d" == "$PWD" ]] && continue
    print -r -- "${when[$d]} $d"
  done | sort -rn
}

# "~/projects/app  · main · 2h ago". Sets REPLY.
_preview_label() {
  local d="$1" t="$2" head label s
  label="${d/#$HOME/~}"
  if [[ -f "$d/.git/HEAD" ]]; then
    read -r head < "$d/.git/HEAD"
    if [[ "$head" == "ref: refs/heads/"* ]]; then label+="  · ${head#ref: refs/heads/}"; else label+="  · detached"; fi
  fi
  if (( t > 0 )); then
    s=$(( EPOCHSECONDS - t ))
    if (( s < 3600 )); then label+=" · $(( s / 60 ))m ago"
    elif (( s < 86400 )); then label+=" · $(( s / 3600 ))h ago"
    else label+=" · $(( s / 86400 ))d ago"; fi
  fi
  REPLY="$label"
}

preview() {
  local -a rows items labels
  local row
  rows=("${(@f)$(_preview_candidates | head -n "$PREVIEW_COUNT")}")
  rows=("${(@)rows:#}")
  for row in "${rows[@]}"; do
    items+=("${row#* }")
    _preview_label "${row#* }" "${row%% *}"; labels+=("$REPLY")
  done
  if (( ${#items} == 0 )); then
    print "preview: no git projects found yet. cd into a repo, or set PREVIEW_ROOTS to the folders that hold your repos."
    return 1
  fi

  # Pad empty slots with N/A so the list is always PREVIEW_COUNT rows.
  local real=${#items}
  while (( ${#items} < PREVIEW_COUNT )); do items+=("N/A"); labels+=("N/A"); done

  local sel=1 key k2 k3 seq
  local n=${#items}

  _preview_draw() {
    local i
    for (( i = 1; i <= n; i++ )); do
      if [[ "${items[$i]}" == "N/A" ]]; then
        print -P -- "    %F{8}N/A%f"
        continue
      fi
      if (( i == sel )); then
        print -rP -- "  %F{cyan}%B❯ ${labels[$i]//\%/%%}%b%f"
      else
        print -r -- "    ${labels[$i]}"
      fi
    done
  }

  print -P "%F{yellow}Projects:%f  ↑/↓ move · Enter open · Esc quit"
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
