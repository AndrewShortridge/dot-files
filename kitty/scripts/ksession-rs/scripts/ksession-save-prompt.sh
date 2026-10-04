#!/usr/bin/env bash
# ksession-save-prompt - overlay that asks for a session name, then saves
# the current OS window via the ksession Rust binary. Bound from kitty.conf.
#
# Behavior:
#   - Shows existing sessions in fzf for autocompletion / overwrite picking.
#   - User types a name and hits Enter (or selects an existing entry to overwrite).
#   - Empty input or Esc aborts.

set -euo pipefail

export PATH="${PATH}:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin"

SESSIONS_DIR="${KITTY_PROJECT_SESSIONS_DIR:-$HOME/.config/kitty/sessions}"
# KSESSION_IMPL can point at an alternate ksession binary (kitty.conf pins
# it to the installed Rust binary). No fallback: if the binary is missing,
# we fail loudly below rather than silently dispatching elsewhere.
# Priority: explicit KSESSION_IMPL > ~/.local/bin/ksession
KSESSION="${KSESSION_IMPL:-$HOME/.local/bin/ksession}"

# Guard against a fat-fingered KSESSION_IMPL pointing at a bare shell name,
# which would silently misroute saves to /bin/bash etc.
if [[ "$(basename "$KSESSION")" =~ ^(bash|sh|zsh|dash|fish)$ ]]; then
  echo "ksession-save-prompt: KSESSION_IMPL='$KSESSION' looks like a bare shell name; refusing to dispatch." >&2
  read -rp "press enter to close..."
  exit 1
fi

if [[ ! -x "$KSESSION" ]]; then
  echo "ksession-save-prompt: ksession binary '$KSESSION' is missing or not executable." >&2
  echo "ksession-save-prompt: run 'make install' in ~/.config/kitty/scripts/ksession-rs to install it." >&2
  read -rp "press enter to close..."
  exit 1
fi

if ! command -v fzf >/dev/null; then
  echo "ksession-save-prompt: fzf is required." >&2
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

# Show fzf: type a new name OR pick existing to overwrite.
# --print-query echoes the typed query as the first line of output.
# --bind 'enter:accept-or-print-query' accepts the highlighted match, else the query.
selection=$(printf '%s' "$rows" \
  | fzf --print-query \
        --prompt='save session as> ' \
        --height=60% --reverse \
        --header='Type a name and press Enter to save (Esc to cancel).' \
        --delimiter=$'\t' \
        --with-nth=1,2 \
        --preview-window=hidden \
        --bind='enter:accept' \
  || true)

# fzf with --print-query prints up to 2 lines:
#   line 1: the typed query
#   line 2: the selected row (may be empty)
query=$(printf '%s\n' "$selection" | sed -n '1p')
chosen=$(printf '%s\n' "$selection" | sed -n '2p' | cut -f1)

# Resolve final name: explicit selection beats query; empty -> abort.
name="$chosen"
[[ -z "$name" ]] && name="$query"
name="${name#"${name%%[![:space:]]*}"}"   # trim leading whitespace
name="${name%"${name##*[![:space:]]}"}"   # trim trailing whitespace

if [[ -z "$name" ]]; then
  echo "ksession-save: aborted."
  sleep 0.6
  exit 0
fi

# Validate (mirror ksession's name rule for a friendlier message).
if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ksession-save: invalid name '$name' (use letters, digits, dot, underscore, dash)." >&2
  read -rp "press enter to close..."
  exit 1
fi

# If overwriting, confirm.
if [[ -e "$SESSIONS_DIR/$name.conf" ]]; then
  read -rp "overwrite existing session '$name'? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted."; exit 0; }
fi

echo "saving '$name'..."
if "$KSESSION" save "$name"; then
  echo
  echo "✔ saved. Press Enter (or wait 2s) to close."
  read -rt 2 -rp "" _ || true
else
  echo
  echo "✘ save failed. See ~/.cache/ksession.log for details."
  read -rp "press enter to close..."
  exit 1
fi
