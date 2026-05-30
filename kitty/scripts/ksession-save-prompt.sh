#!/usr/bin/env bash
# ksession-save-prompt - overlay that asks for a session name, then saves
# the current OS window via ksession.sh. Bound from kitty.conf.
#
# Behavior:
#   - Shows existing sessions in fzf for autocompletion / overwrite picking.
#   - User types a name and hits Enter (or selects an existing entry to overwrite).
#   - Empty input or Esc aborts.

set -euo pipefail

export PATH="${PATH}:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin"

SESSIONS_DIR="${KITTY_PROJECT_SESSIONS_DIR:-$HOME/.config/kitty/sessions}"
# KSESSION_IMPL can point at ksession-rs (or any alternate impl) so users
# can switch the save keybinding without renaming ksession.sh.
# Priority: explicit KSESSION_IMPL > ksession-rs binary > ksession.sh
if [[ -n "${KSESSION_IMPL:-}" ]]; then
  KSESSION="$KSESSION_IMPL"
elif [[ -x "$HOME/.local/bin/ksession-rs" ]]; then
  KSESSION="$HOME/.local/bin/ksession-rs"
elif [[ -x "${HOME}/.config/kitty/scripts/ksession-rs/target/release/ksession" ]]; then
  KSESSION="${HOME}/.config/kitty/scripts/ksession-rs/target/release/ksession"
else
  KSESSION="$(dirname "$0")/ksession.sh"
fi

# Guard against a fat-fingered KSESSION_IMPL pointing at a bare shell name,
# which would silently misroute saves to /bin/bash etc.
if [[ "$(basename "$KSESSION")" =~ ^(bash|sh|zsh|dash|fish)$ ]]; then
  echo "ksession-save-prompt: KSESSION_IMPL='$KSESSION' looks like a bare shell name; refusing to dispatch." >&2
  read -rp "press enter to close..."
  exit 1
fi

if [[ ! -x "$KSESSION" ]]; then
  echo "ksession-save-prompt: KSESSION='$KSESSION' is not executable." >&2
  read -rp "press enter to close..."
  exit 1
fi

if ! command -v fzf >/dev/null; then
  echo "ksession-save-prompt: fzf is required." >&2
  read -rp "press enter to close..."
  exit 1
fi

# shellcheck source=lib/running-sessions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/running-sessions.sh"

# Build the list of existing sessions.
# Schema: "<name>\t<description>\t<file_path>\t<colored display>"
# Column 1 is the clean name (parsed back out via cut -f1 below); column 3
# is the file path used by the preview command; column 4 is what fzf shows
# (--with-nth=4, --ansi).
#
# Display layout mirrors session-picker.sh verbatim so the same session
# reads identically across pickers:
#   running: "<mark> ● [pid.osw]  <name>  ·  <title>  ·  <N tabs>  ·  <cwd>"
#   saved  : "<mark> ○ <name>  ·  <desc>"
# Where <mark> is bold-magenta "*" when the row IS the current session,
# else a single space. Running detection walks /tmp/kitty-* sockets via
# lib/running-sessions.sh.
# Only bullets, the "[pid.osw]" tag, the "*" marker, and the " · "
# separators are colored — names and metadata are plain default terminal
# text, matching session-picker.sh's colorize_rows pass.
_ANSI_RESET=$'\033[0m'
_ANSI_DIM=$'\033[2m'
_ANSI_BOLD=$'\033[1m'
_ANSI_BLUE=$'\033[34m'
_ANSI_GREEN=$'\033[32m'
_ANSI_MAGENTA_B=$'\033[1;35m'

declare -A _running_meta=()
while IFS=$'\t' read -r _n _pid _osw _title _ntabs _cwd; do
  [[ -z "$_n" ]] && continue
  _running_meta["$_n"]="${_pid}|${_osw}|${_title}|${_ntabs}|${_cwd}"
done < <(running_session_details || true)

_current_name="$(current_session_name || true)"

shopt -s nullglob
rows=""
for f in "$SESSIONS_DIR"/*.conf; do
  name=$(basename "$f" .conf)
  desc=$(grep -m1 -iE '^# *Description:' "$f" 2>/dev/null \
         | sed -E 's/^# *[Dd]escription: *//' || true)

  if [[ -n "$_current_name" && "$name" == "$_current_name" ]]; then
    mark="${_ANSI_MAGENTA_B}*${_ANSI_RESET}"
  else
    mark=" "
  fi

  if [[ -n "${_running_meta[$name]:-}" ]]; then
    IFS='|' read -r r_pid r_osw r_title r_ntabs r_cwd <<<"${_running_meta[$name]}"
    [[ "$r_ntabs" == "1" ]] && tabs_word="tab" || tabs_word="tabs"
    bullet="${_ANSI_GREEN}●${_ANSI_RESET}"
    tag="${_ANSI_BOLD}[${r_pid}.${r_osw}]${_ANSI_RESET}"
    sep="  ${_ANSI_DIM}·${_ANSI_RESET}  "
    display="${mark} ${bullet} ${tag}  ${name}${sep}${r_title}${sep}${r_ntabs} ${tabs_word}${sep}${r_cwd}"
  else
    bullet="${_ANSI_BLUE}○${_ANSI_RESET}"
    if [[ -n "$desc" ]]; then
      desc_part="  ${_ANSI_DIM}·${_ANSI_RESET}  ${desc}"
    else
      desc_part=""
    fi
    display="${mark} ${bullet} ${name}${desc_part}"
  fi

  rows+="${name}"$'\t'"${desc}"$'\t'"${f}"$'\t'"${display}"$'\n'
done
shopt -u nullglob

# Preview: colorized .conf of the currently-highlighted existing session,
# so the user can see what they're about to overwrite. Empty when typing a
# fresh name (no row highlighted -> fzf doesn't invoke the preview command).
_SCRIPTS_LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
preview_cmd="\"$_SCRIPTS_LIB/conf-preview.sh\" {3}"

# Show fzf: type a new name OR pick existing to overwrite.
# --print-query echoes the typed query as the first line of output.
# --bind 'enter:accept-or-print-query' accepts the highlighted match, else the query.
selection=$(printf '%s' "$rows" \
  | fzf --print-query \
        --ansi \
        --prompt='save session as> ' \
        --height=60% --reverse \
        --header='Type a name and press Enter to save (Esc to cancel).' \
        --delimiter=$'\t' \
        --with-nth=4 \
        --preview="$preview_cmd" \
        --preview-window='right:55%:wrap' \
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

# Validate (mirror ksession.sh's rule for a friendlier message).
if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ksession-save: invalid name '$name' (use letters, digits, dot, underscore, dash)." >&2
  read -rp "press enter to close..."
  exit 1
fi

# Reserve the 'ssh-' prefix for ephemeral SSH sessions, which live in
# /tmp/kitty-ssh-sessions/ and are not snapshot-able via ksession save.
if [[ "$name" == ssh-* ]]; then
  echo "ksession-save: name '$name' starts with 'ssh-', which is reserved for ephemeral SSH sessions" >&2
  echo "  (those live in /tmp/kitty-ssh-sessions/, not in $SESSIONS_DIR; remote shell state can't be snapshotted)." >&2
  echo "  Pick a different name." >&2
  read -rp "press enter to close..."
  exit 1
fi

# If overwriting, confirm.
if [[ -e "$SESSIONS_DIR/$name.conf" ]]; then
  read -rp "overwrite existing session '$name'? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted."; exit 0; }
fi

echo "saving '$name'..."
# Redirect stderr to log file to suppress verbose logging during save
# Keep stdout for user feedback messages
if "$KSESSION" save "$name" 2>>"${HOME}/.cache/ksession.log"; then
  echo
  echo "✔ saved. Press Enter (or wait 2s) to close."
  read -rt 2 -rp "" _ || true
else
  echo
  echo "✘ save failed. See ~/.cache/ksession.log for details."
  read -rp "press enter to close..."
  exit 1
fi
