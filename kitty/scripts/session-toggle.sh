#!/usr/bin/env bash
# Alternate-session toggle: focuses the second-most-recently-focused kitty
# OS window across every running kitty process. Pressing the chord twice
# in a row returns to the original session because by then the previous
# window has become current.
#
# Bound from kitty.conf via ctrl+space>l. Launched with
# `launch --type=background` so this script itself does not create an
# overlay window that pollutes the MRU ranking.
set -euo pipefail

# Kitty launches this directly (not via an interactive shell), so .bashrc
# isn't sourced and miniconda/local paths are missing. Add them explicitly.
export PATH="$PATH:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin"

LOG="${HOME}/.cache/kitty-session-picker.log"
RANKER="/home/andrew/.config/kitty/scripts/lib/mru-rank.jq"
mkdir -p "$(dirname "$LOG")"

if ! command -v jq >/dev/null; then
  echo "session-toggle needs jq on PATH." >&2
  exit 1
fi

# Build the ranker input: one JSON object per live socket, of the shape
#   { "socket": "<path>", "ls": <kitty @ ls output> }
# Stale sockets (kitty exited but socket file lingers) make `kitty @ ls`
# return non-zero — skip them and continue.
ranker_input=""
for sock in /tmp/kitty-*; do
  [[ -S "$sock" ]] || continue
  if ls_json=$(kitty @ --to "unix:$sock" ls 2>/dev/null); then
    entry=$(jq -nc --arg s "$sock" --argjson ls "$ls_json" '{socket: $s, ls: $ls}')
    ranker_input+="${entry}"$'\n'
  fi
done

if [[ -z "$ranker_input" ]]; then
  # No live kitty processes — silent no-op.
  exit 0
fi

# Run the ranker. Output is TSV: socket \t osw_id \t win_id \t last_focused_at
ranked=$(printf '%s' "$ranker_input" | jq -rs -f "$RANKER")

line_count=$(printf '%s' "$ranked" | grep -c '^' || true)
if (( line_count <= 1 )); then
  # Zero or one focusable OS window — nothing to toggle to.
  exit 0
fi

# Second line is the runner-up — our toggle target.
target=$(printf '%s\n' "$ranked" | sed -n '2p')
target_sock=$(printf '%s' "$target" | cut -f1)
target_osw=$(printf  '%s' "$target" | cut -f2)
target_win=$(printf  '%s' "$target" | cut -f3)
target_lfa=$(printf  '%s' "$target" | cut -f4)

echo "--- $(date -Is) session-toggle sock=$target_sock osw=$target_osw win=$target_win lfa=$target_lfa ---" >>"$LOG"

# Focus the kitty-internal window. kitty's focus-window also raises the
# containing OS window, mirroring the working session-picker.sh pattern.
# (focus-os-window was added in a later kitty; we can't rely on it.)
kitty @ --to "unix:$target_sock" focus-window --match "id:$target_win" >>"$LOG" 2>&1 || true
