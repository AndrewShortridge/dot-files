#!/usr/bin/env bash
# Fuzzy-pick a project session file and either focus its OS window
# (if already open) or spawn it. Bound from kitty.conf via ctrl+space>o.
#
# Each project spawns its own kitty process tagged with --class
# kitty-project-<name>. Detection works by enumerating /tmp/kitty-*
# sockets and matching wm_class across all running kitty processes.
set -euo pipefail

# Kitty launches this directly (not via an interactive shell), so .bashrc
# isn't sourced and miniconda/local paths are missing. Add them explicitly.
export PATH="$PATH:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin"

SESSIONS_DIR="${KITTY_PROJECT_SESSIONS_DIR:-$HOME/.config/kitty/sessions}"
LOG="${HOME}/.cache/kitty-project-launcher.log"
mkdir -p "$(dirname "$LOG")"

if ! command -v jq >/dev/null || ! command -v fzf >/dev/null; then
  echo "project-launcher needs jq and fzf on PATH." >&2
  read -rp "press enter to close..."
  exit 1
fi

shopt -s nullglob
files=( "$SESSIONS_DIR"/*.conf )
shopt -u nullglob

if (( ${#files[@]} == 0 )); then
  echo "No project session files in $SESSIONS_DIR" >&2
  echo "Create e.g. myproject.conf to get started." >&2
  read -rp "press enter to close..."
  exit 0
fi

# Build map of running project class → (socket, first_window_id) by
# enumerating every kitty remote-control socket on the system.
declare -A running_sock
declare -A running_wid
for sock in /tmp/kitty-*; do
  [[ -S "$sock" ]] || continue   # skip non-sockets (e.g. log files)
  ls_json=$(kitty @ --to "unix:$sock" ls 2>/dev/null) || continue
  # Pull (wm_class, first window id) tuples for any OS window whose
  # class starts with "kitty-project-".
  while IFS=$'\t' read -r cls wid; do
    [[ -z "$cls" || "$cls" == "kitty" ]] && continue
    [[ "$cls" == kitty-project-* ]] || continue
    running_sock["$cls"]="$sock"
    running_wid["$cls"]="$wid"
  done < <(echo "$ls_json" | jq -r '.[] | [.wm_class, (.tabs[0].windows[0].id|tostring)] | @tsv')
done

# Per file build: <name>\t<file>\t<socket>\t<window_id>\t<description>
rows=""
for f in "${files[@]}"; do
  name=$(basename "$f" .conf)
  cls="kitty-project-${name}"
  sock="${running_sock[$cls]:-}"
  wid="${running_wid[$cls]:-}"

  desc=$(grep -m1 -iE '^# *Description:' "$f" 2>/dev/null \
         | sed -E 's/^# *[Dd]escription: *//' || true)

  rows+="${name}"$'\t'"${f}"$'\t'"${sock}"$'\t'"${wid}"$'\t'"${desc}"$'\n'
done

# Display: "<status> <name>   <description>"
# Hidden:  1=name 2=file 3=sock 4=wid    Shown: 5 onwards
selection=$(printf '%s' "$rows" | awk -F'\t' '
  NF {
    status = ($3 == "") ? "\xe2\x97\x8b" : "\xe2\x97\x8f"   # ○ or ●
    desc   = ($5 == "") ? "" : "  \xc2\xb7  " $5           # · separator
    printf "%s\t%s\t%s\t%s\t%s  %s%s\n", $1, $2, $3, $4, status, $1, desc
  }
' | fzf \
    --with-nth=5.. \
    --delimiter='\t' \
    --prompt='project> ' \
    --height=85% \
    --reverse \
    --no-sort \
    --preview='cat -- {2}' \
    --preview-window='right:55%:wrap')

[[ -z "$selection" ]] && exit 0

name=$(printf '%s' "$selection" | cut -f1)
file=$(printf '%s' "$selection" | cut -f2)
sock=$(printf '%s' "$selection" | cut -f3)
wid=$(printf  '%s' "$selection" | cut -f4)

echo "--- $(date -Is) launch '$name' ---" >>"$LOG"

if [[ -n "$sock" && -n "$wid" ]]; then
  echo "focusing existing project via $sock window=$wid" >>"$LOG"
  kitty @ --to "unix:$sock" focus-window --match "id:$wid" >>"$LOG" 2>&1
else
  echo "spawning new kitty for '$name' from $file" >>"$LOG"
  kitty --detach --class "kitty-project-${name}" --session "$file" \
        >>"$LOG" 2>&1 || echo "kitty exited non-zero" >>"$LOG"
fi
