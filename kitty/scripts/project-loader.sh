#!/usr/bin/env bash
# Pick a project session file and load its layout INTO the current
# kitty OS window: new tabs added (with splits, layouts, cwd as the
# session file specifies), old tabs closed except the one you invoked
# the picker from. Same kitty process throughout.
# Bound from kitty.conf via ctrl+space>o.
# Modal: insert mode by default (type to filter); Esc → normal mode
# (j/k to navigate, i back to insert, q/Esc to quit). See lib/modal_fsm.sh.
set -euo pipefail

# Kitty launches this directly (not via an interactive shell), so .bashrc isn't
# sourced and miniconda/local paths are missing. Add them explicitly. /opt/nvim
# is PREPENDED so the restored nvim is the user's primary 0.12.x — not an older
# nvim elsewhere on PATH (e.g. miniconda's 0.11), whose :mksession scripts fail
# with "E216: No such group or event: SessionLoadPre". ksession forwards this
# PATH to each restored window via `kitten @ launch --env PATH=...`.
# (A `bash -lc` lookup can't be used here: .bashrc's non-interactive guard skips
#  the dirs we need, e.g. miniconda's fzf, breaking the jq/fzf check below.)
export PATH="/opt/nvim-linux-x86_64/bin:$PATH:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin"

SESSIONS_DIR="${KITTY_PROJECT_SESSIONS_DIR:-$HOME/.config/kitty/sessions}"
LOG="${HOME}/.cache/kitty-project-loader.log"
mkdir -p "$(dirname "$LOG")"

if ! command -v jq >/dev/null || ! command -v fzf >/dev/null; then
  echo "project-loader needs jq and fzf on PATH." >&2
  read -rp "press enter to close..."
  exit 1
fi

# shellcheck source=lib/modal_fsm.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/modal_fsm.sh"
# shellcheck source=lib/running-sessions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/running-sessions.sh"

# --- Build the picker row buffer ---------------------------------------------
shopt -s nullglob
files=( "$SESSIONS_DIR"/*.conf )
shopt -u nullglob

if (( ${#files[@]} == 0 )); then
  echo "No project session files in $SESSIONS_DIR" >&2
  read -rp "press enter to close..."
  exit 0
fi

# ANSI palette + display layout mirrors session-picker.sh verbatim.
# Per-row format:
#   running: "<mark> ● [pid.osw]  <name>  ·  <title>  ·  <N tabs>  ·  <cwd>"
#   saved  : "<mark> ○ <name>  ·  <desc>"
# Where <mark> is bold-magenta "*" when the row IS the current session,
# else a single space. Only bullets, the "[pid.osw]" tag, the "*" marker,
# and the " · " separators are colored — names and metadata are plain
# default terminal text. See lib/running-sessions.sh for cross-process
# detection.
_ANSI_RESET=$'\033[0m'
_ANSI_DIM=$'\033[2m'
_ANSI_BOLD=$'\033[1m'
_ANSI_BLUE=$'\033[34m'        # blue (saved bullet)
_ANSI_GREEN=$'\033[32m'       # green (running bullet)
_ANSI_MAGENTA_B=$'\033[1;35m' # bold magenta (current marker)

# Build a name -> "pid|osw|title|num_tabs|cwd" map from the cross-process
# detail probe. Only project rows we recognize end up here; SSH-prefixed
# ones are filtered out by the helper.
declare -A _running_meta=()
while IFS=$'\t' read -r _n _pid _osw _title _ntabs _cwd; do
  [[ -z "$_n" ]] && continue
  _running_meta["$_n"]="${_pid}|${_osw}|${_title}|${_ntabs}|${_cwd}"
done < <(running_session_details || true)

_current_name="$(current_session_name || true)"

all_rows=""
for f in "${files[@]}"; do
  name=$(basename "$f" .conf)
  desc=$(grep -m1 -iE '^# *Description:' "$f" 2>/dev/null \
         | sed -E 's/^# *[Dd]escription: *//' || true)

  if [[ -n "$_current_name" && "$name" == "$_current_name" ]]; then
    mark="${_ANSI_MAGENTA_B}*${_ANSI_RESET}"
  else
    mark=" "
  fi

  if [[ -n "${_running_meta[$name]:-}" ]]; then
    # Running row: rich metadata from kitty @ ls.
    IFS='|' read -r r_pid r_osw r_title r_ntabs r_cwd <<<"${_running_meta[$name]}"
    [[ "$r_ntabs" == "1" ]] && tabs_word="tab" || tabs_word="tabs"
    bullet="${_ANSI_GREEN}●${_ANSI_RESET}"
    tag="${_ANSI_BOLD}[${r_pid}.${r_osw}]${_ANSI_RESET}"
    sep="  ${_ANSI_DIM}·${_ANSI_RESET}  "
    display="${mark} ${bullet} ${tag}  ${name}${sep}${r_title}${sep}${r_ntabs} ${tabs_word}${sep}${r_cwd}"
  else
    # Saved-only row: matches session-picker.sh's ○ spawn format.
    bullet="${_ANSI_BLUE}○${_ANSI_RESET}"
    if [[ -n "$desc" ]]; then
      desc_part="  ${_ANSI_DIM}·${_ANSI_RESET}  ${desc}"
    else
      desc_part=""
    fi
    display="${mark} ${bullet} ${name}${desc_part}"
  fi

  all_rows+="${name}"$'\t'"${f}"$'\t'"${display}"$'\n'
done

# --- Modal loop --------------------------------------------------------------
# See session-picker.sh for the rationale behind this structure.

# Colorize the .conf preview via the shared session-conf renderer.
_SCRIPTS_LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
preview_cmd="\"$_SCRIPTS_LIB/conf-preview.sh\" {2}"

_cursor_supported() {
  case "${TERM:-}" in
    screen*|dumb|"") return 1 ;;
    *)               return 0 ;;
  esac
}
_cursor_bar()   { _cursor_supported && printf '\e[6 q' >&2 || true; }
_cursor_block() { _cursor_supported && printf '\e[2 q' >&2 || true; }
trap '_cursor_bar' EXIT

_fzf_supports_pos() {
  local v major minor
  v=$(fzf --version 2>/dev/null | awk '{print $1}')
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%.*}
  [[ -z "$major" || -z "$minor" ]] && return 1
  if (( major > 0 )); then return 0; fi
  (( minor >= 43 ))
}

if _fzf_supports_pos; then POS_BIND_SUPPORTED=1; else POS_BIND_SUPPORTED=0; fi

_row_index_of() {
  local needle="$1"
  [[ -z "$needle" ]] && { printf '0\n'; return 0; }
  printf '%s' "$all_rows" | awk -v n="$needle" '
    $0 == n { print NR - 1; found = 1; exit }
    END { if (!found) print 0 }
  '
}

_run_fzf() {
  local pos_bind
  if (( POS_BIND_SUPPORTED )); then
    pos_bind="load:pos(${cursor_index:-0})"
  else
    pos_bind="load:pos(0)"
  fi
  if [[ "$mode" == "insert" ]]; then
    _cursor_bar
    printf '%s' "$all_rows" | fzf \
        --ansi \
        --with-nth=3.. \
        --delimiter=$'\t' \
        --prompt='load project into this kitty> ' \
        --height=85% \
        --reverse \
        --no-sort \
        --preview="$preview_cmd" \
        --preview-window='right:55%:wrap' \
        --expect=enter,esc \
        --bind="$pos_bind"
  else
    _cursor_block
    printf '%s' "$all_rows" | fzf \
        --ansi \
        --with-nth=3.. \
        --delimiter=$'\t' \
        --prompt='LOAD PROJECT> ' \
        --height=85% \
        --reverse \
        --no-sort \
        --disabled \
        --no-clear \
        --sync \
        --preview="$preview_cmd" \
        --preview-window='right:55%:wrap' \
        --bind='j:down,k:up,ctrl-d:half-page-down,ctrl-u:half-page-up,g:first,G:last' \
        --bind="$pos_bind" \
        --expect=enter,i,esc,q,d
  fi
}

# --- Session-file loader (called on `open`) ----------------------------------
# Now uses the Rust implementation via ksession restore --into-current
_load_session_file() {
  local file="$1" name="$2"

  echo "--- $(date -Is) load '$name' from $file ---" >>"$LOG"

  # Find current OS window + the tab containing this overlay.
  local ls_json my_win current_osw my_tab
  ls_json=$(kitty @ ls)
  my_win="${KITTY_WINDOW_ID:-}"
  if [[ -z "$my_win" ]]; then
    echo "KITTY_WINDOW_ID unset" >>"$LOG"
    read -rp "press enter to close..."
    exit 1
  fi

  current_osw=$(echo "$ls_json" | jq --arg w "$my_win" '
    .[] | select(any(.tabs[].windows[]; .id == ($w|tonumber))) | .id
  ' | head -n1)

  my_tab=$(echo "$ls_json" | jq --arg w "$my_win" --arg osw "$current_osw" '
    .[] | select(.id == ($osw|tonumber))
        | .tabs[] | select(any(.windows[]; .id == ($w|tonumber))) | .id
  ' | head -n1)

  if [[ -z "$current_osw" || -z "$my_tab" ]]; then
    echo "couldn't determine current osw/tab" >>"$LOG"
    read -rp "press enter to close..."
    exit 1
  fi
  echo "current_osw=$current_osw, my_tab=$my_tab" >>"$LOG"

  local old_tabs=()
  mapfile -t old_tabs < <(echo "$ls_json" | jq -r --arg osw "$current_osw" --arg me "$my_tab" '
    .[] | select(.id == ($osw|tonumber))
        | .tabs[] | select(.id != ($me|tonumber)) | .id
  ')
  echo "tabs to close: ${old_tabs[*]:-<none>}" >>"$LOG"

  # Use the Rust implementation (ksession-rs) for restore.
  # No bash fallback - if Rust fails, we exit with error.
  # Priority: KSESSION_IMPL env > ~/.local/bin/ksession > hardcoded path
  local ksession_bin
  if [[ -n "${KSESSION_IMPL:-}" ]]; then
    ksession_bin="$KSESSION_IMPL"
  elif [[ -x "${HOME}/.local/bin/ksession" ]]; then
    ksession_bin="${HOME}/.local/bin/ksession"
  else
    ksession_bin="${HOME}/.config/kitty/scripts/ksession-rs/target/release/ksession"
  fi
  if [[ ! -x "$ksession_bin" ]]; then
    echo "ksession-rs binary not found at: $ksession_bin" >>"$LOG"
    echo "ERROR: ksession-rs binary not found at: $ksession_bin" >&2
    echo "ERROR: Please build and install ksession-rs: cd scripts/ksession-rs && cargo build --release && cp target/release/ksession ~/.local/bin/" >&2
    return 1
  fi

  # Load into THIS kitty instance (new tabs added, old tabs replaced) rather
  # than spawning a separate OS window. See ksession-rs run_into_current.
  echo "+ $ksession_bin restore '$name' --into-current" >>"$LOG"
  if "$ksession_bin" restore "$name" --into-current >>"$LOG" 2>&1; then
    echo "ksession-rs restore completed successfully" >>"$LOG"
  else
    local rc=$?
    echo "ksession-rs restore failed with exit code $rc" >>"$LOG"
    echo "ERROR: ksession-rs restore failed (exit code: $rc)." >&2
    echo "ERROR: See ~/.cache/ksession/ksession.log for details." >&2
    return $rc
  fi

  echo "--- done ---" >>"$LOG"
}

# Rust-only implementation - no bash fallback

_open_and_exit() {
  local name file
  name=$(printf '%s' "$selection" | cut -f1)
  file=$(printf '%s' "$selection" | cut -f2)
  _load_session_file "$file" "$name"
  exit 0
}

mode="insert"
cursor_index=0
fzf_out=""
selection=""

while true; do
  set +e
  fzf_out="$(_run_fzf)"
  fzf_rc=$?
  set -e

  key=$(printf '%s' "$fzf_out" | sed -n '1p')
  selection=$(printf '%s' "$fzf_out" | sed -n '2p')

  if [[ -z "$key" && -z "$selection" && $fzf_rc -ne 0 ]]; then
    exit 0
  fi
  if [[ -z "$key" && -n "$selection" ]]; then
    key="enter"
  fi
  if [[ -n "$selection" ]]; then
    cursor_index=$(_row_index_of "$selection")
  fi

  trans_out=$(picker_transition "$mode" "$key")
  next_mode=$(printf '%s' "$trans_out" | sed -n '1p')
  side_effect=$(printf '%s' "$trans_out" | sed -n '2p')

  case "$side_effect" in
    open)
      if [[ -z "$selection" ]]; then
        mode="$next_mode"
        [[ "$mode" == "quit" ]] && exit 0
        continue
      fi
      _open_and_exit
      ;;
    quit)
      exit 0
      ;;
    delete)
      # `(normal, d)` returns `delete` from the shared FSM. project-loader
      # doesn't own the saved-session files (session-picker.sh handles
      # delete-in-place on those), so we treat it as a no-op here to
      # avoid duplicating the destructive surface in two pickers.
      mode="$next_mode"
      [[ "$mode" == "quit" ]] && exit 0
      continue
      ;;
    noop|*)
      mode="$next_mode"
      [[ "$mode" == "quit" ]] && exit 0
      continue
      ;;
  esac
done
