#!/usr/bin/env bash
# Fuzzy-pick any tab or split (window) within the CURRENT kitty OS window.
# Bound from kitty.conf via a `launch --type=overlay` chord.
# Modal: insert mode by default (type to filter); Esc → normal mode
# (j/k to navigate, i back to insert, q/Esc to quit). See lib/modal_fsm.sh.
set -euo pipefail

# Kitty launches this directly (not via an interactive shell), so .bashrc
# isn't sourced and miniconda/local paths are missing. Add them explicitly.
export PATH="$PATH:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin"

if ! command -v jq >/dev/null || ! command -v fzf >/dev/null; then
  echo "tab-picker needs jq and fzf on PATH." >&2
  read -rp "press enter to close..."
  exit 1
fi

# shellcheck source=lib/modal_fsm.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/modal_fsm.sh"

ls_json=$(kitty @ ls 2>/dev/null) || {
  echo "kitty remote control failed. Check 'allow_remote_control' in kitty.conf." >&2
  read -rp "press enter to close..."
  exit 1
}

# Find which OS window we're in. KITTY_WINDOW_ID is set by kitty for child
# processes (including overlays) — look up which OS window contains it.
my_win="${KITTY_WINDOW_ID:-}"

if [[ -n "$my_win" ]]; then
  current_osw=$(echo "$ls_json" | jq --arg w "$my_win" '
    .[] | select(any(.tabs[].windows[]; .id == ($w|tonumber))) | .id
  ' | head -n1)
else
  current_osw=$(echo "$ls_json" | jq '.[] | select(.is_focused) | .id' | head -n1)
fi

if [[ -z "$current_osw" ]]; then
  echo "couldn't determine current OS window." >&2
  read -rp "press enter to close..."
  exit 1
fi

# One row per split. Mark the window the user invoked the picker from
# with is_self=1 so the display can flag it with a leading "*".
#   <window_id>\t<tab_id>\t<tab_title>\t<window_title>\t<cwd>\t<is_self>
my_win="${KITTY_WINDOW_ID:-}"
rows=$(echo "$ls_json" | jq -r --arg osw "$current_osw" --arg me "${my_win:-0}" '
  .[] | select(.id == ($osw|tonumber)) | .tabs[] as $tab |
  $tab.windows[] as $w |
  [
    ($w.id|tostring),
    ($tab.id|tostring),
    $tab.title,
    ($w.title // ""),
    ($w.cwd // "?"),
    (if ($w.id|tostring) == $me then "1" else "" end)
  ] | @tsv
')

if [[ -z "$rows" ]]; then
  echo "no tabs/windows found in current OS window." >&2
  exit 0
fi

# Display: "<mark> ● [tab.win]  <tab_title>  ·  <window_title>  ·  cwd"
# Mirrors session-picker.sh's running-row schema verbatim: green "●" live
# bullet, bold "[id.id]" tag, dim "·" separators; everything else (titles,
# cwd) is plain default text. Field 1 (window_id) hidden via --with-nth=2..
all_rows=$(printf '%s\n' "$rows" | awk -F'\t' '
  BEGIN {
    R   = "\033[0m"
    B   = "\033[1m"
    D   = "\033[2m"
    GR  = "\033[32m"      # green (live bullet)
    MB  = "\033[1;35m"    # bold magenta (current marker)
  }
  {
    win_title = ($4 == "") ? "(window)" : $4
    mark = ($6 == "1") ? (MB "*" R) : " "
    # Format: <mark> ● [tab.win]  tab_title  ·  window_title  ·  cwd
    printf "%s\t%s %s\xe2\x97\x8f%s %s[%s.%s]%s  %s  %s\xc2\xb7%s  %s  %s\xc2\xb7%s  %s\n", \
      $1, \
      mark, \
      GR, R, \
      B, $2, $1, R, \
      $3, \
      D, R, \
      win_title, \
      D, R, \
      $5
  }
')

# ----- Modal loop ------------------------------------------------------------
# Mirrors the structure used in session-picker.sh. See the comments there for
# rationale; this picker is the simpler 1-action variant.

# --ansi preserves real terminal colors from the target window in the preview.
preview_cmd='kitty @ get-text --ansi --match id:{1} --extent screen 2>/dev/null'

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
        --with-nth=2.. \
        --delimiter=$'\t' \
        --prompt='tab/window> ' \
        --height=90% \
        --reverse \
        --no-sort \
        --preview="$preview_cmd" \
        --preview-window='right:60%:wrap' \
        --expect=enter,esc \
        --bind="$pos_bind"
  else
    _cursor_block
    printf '%s' "$all_rows" | fzf \
        --ansi \
        --with-nth=2.. \
        --delimiter=$'\t' \
        --prompt='TAB/WINDOW> ' \
        --height=90% \
        --reverse \
        --no-sort \
        --disabled \
        --no-clear \
        --sync \
        --preview="$preview_cmd" \
        --preview-window='right:60%:wrap' \
        --bind='j:down,k:up,ctrl-d:half-page-down,ctrl-u:half-page-up,g:first,G:last' \
        --bind="$pos_bind" \
        --expect=enter,i,esc,q,d
  fi
}

_open_and_exit() {
  local window_id
  window_id=$(printf '%s' "$selection" | cut -f1)
  kitty @ focus-window --match "id:$window_id"
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
      # `(normal, d)` returns `delete` from the shared FSM. This picker
      # has nothing to delete (rows are live kitty splits, not artifacts
      # on disk), so we treat it as a no-op. See session-picker.sh for
      # the actual delete dispatch.
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
