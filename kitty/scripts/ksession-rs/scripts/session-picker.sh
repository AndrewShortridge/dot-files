#!/usr/bin/env bash
# session-picker - overlay that lists saved sessions in fzf and dispatches
# `ksession restore <name>` on selection. Bound from kitty.conf.
#
# Behavior:
#   - Shows existing sessions in fzf with descriptions.
#   - User selects a session and hits Enter to restore it.
#   - Empty selection or Esc aborts cleanly.

set -euo pipefail

export PATH="${PATH}:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin"

SESSIONS_DIR="${KITTY_PROJECT_SESSIONS_DIR:-$HOME/.config/kitty/sessions}"

# --- Warm kitty pre-warming -------------------------------------------------
# Spawn a throwaway kitty instance so the OS page cache warms kitty's binary,
# shared libraries, and GPU driver before the real restore launch.
WARM_KITTY_PID=""

spawn_warm_kitty() {
  kitty --class ksession-warming &
  WARM_KITTY_PID=$!
}

cleanup_warm_kitty() {
  if [[ -n "${WARM_KITTY_PID:-}" ]]; then
    kill "$WARM_KITTY_PID" 2>/dev/null || true
    WARM_KITTY_PID=""
  fi
}

trap cleanup_warm_kitty EXIT
# KSESSION_IMPL can point at an alternate ksession binary (kitty.conf pins
# it to the installed Rust binary). No fallback: if the binary is missing,
# we fail loudly below rather than silently dispatching elsewhere.
# Priority: explicit KSESSION_IMPL > ~/.local/bin/ksession
KSESSION="${KSESSION_IMPL:-$HOME/.local/bin/ksession}"

# Guard against a fat-fingered KSESSION_IMPL pointing at a bare shell name,
# which would silently misroute restores to /bin/bash etc.
if [[ "$(basename "$KSESSION")" =~ ^(bash|sh|zsh|dash|fish)$ ]]; then
  echo "session-picker: KSESSION_IMPL='$KSESSION' looks like a bare shell name; refusing to dispatch." >&2
  read -rp "press enter to close..."
  exit 1
fi

if [[ ! -x "$KSESSION" ]]; then
  echo "session-picker: ksession binary '$KSESSION' is missing or not executable." >&2
  echo "session-picker: run 'make install' in ~/.config/kitty/scripts/ksession-rs to install it." >&2
  read -rp "press enter to close..."
  exit 1
fi

if ! command -v fzf >/dev/null; then
  echo "session-picker: fzf is required." >&2
  read -rp "press enter to close..."
  exit 1
fi

# Build the list of existing sessions (each line: "name<TAB>description").
shopt -s nullglob
rows=""
for f in "$SESSIONS_DIR"/*.conf; do
  name=$(basename "$f" .conf)
  desc=$(grep -m1 -iE '^# *Description:' "$f" 2>/dev/null \
         | sed -E 's/^# *[Dd]escription: *//' || true)
  rows+="${name}"$'\t'"${desc}"$'\n'
done
shopt -u nullglob

if [[ -z "$rows" ]]; then
  echo "session-picker: no saved sessions found in $SESSIONS_DIR."
  sleep 1.5
  exit 0
fi

# Spawn the warm kitty now that we know we have sessions to show.
spawn_warm_kitty

# Show fzf: select a session to restore.
chosen=$(printf '%s' "$rows" \
  | fzf --prompt='restore session> ' \
        --height=60% --reverse \
        --header='Select a session and press Enter to restore (Esc to cancel).' \
        --delimiter=$'\t' \
        --with-nth=1,2 \
        --preview-window=hidden \
  || true)

# Extract the session name (first tab-delimited field).
name=$(printf '%s' "$chosen" | cut -f1)
name="${name#"${name%%[![:space:]]*}"}"   # trim leading whitespace
name="${name%"${name##*[![:space:]]}"}"   # trim trailing whitespace

if [[ -z "$name" ]]; then
  echo "session-picker: aborted."
  sleep 0.6
  exit 0
fi

echo "restoring '$name'..."
if "$KSESSION" restore "$name"; then
  echo
  echo "✔ restored. Press Enter (or wait 2s) to close."
  read -rt 2 -rp "" _ || true
else
  echo
  echo "✘ restore failed. See ~/.cache/ksession.log for details."
  read -rp "press enter to close..."
  exit 1
fi
