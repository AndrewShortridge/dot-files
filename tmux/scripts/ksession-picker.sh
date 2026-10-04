#!/usr/bin/env bash
# ksession-picker: fzf picker for tmux, run inside `tmux display-popup`
# from tmux.conf (prefix s / prefix f). The tmux counterpart of kitty's
# session-picker.sh and tab-picker.sh.
#
#   ksession-picker.sh          running tmux sessions (●) plus saved
#                               `ksession tmux` sessions whose tmux session
#                               is not running (○). Enter switches to or
#                               restores the row; d (normal mode) kills the
#                               tmux session or removes the saved one.
#   ksession-picker.sh --panes  every pane on the server. Enter jumps to it.
#
# Modal: insert mode by default (type to filter); Esc -> normal mode
# (j/k navigate, d delete, i back to insert, q/Esc quit). The FSM and the
# frecency store are the kitty picker's libs (lib/modal_fsm.sh,
# lib/frecency.sh), so the two surfaces behave identically.
set -euo pipefail

# shellcheck source=lib/ksession-tmux-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ksession-tmux-common.sh"
ksession_tmux_init ksession-picker

case "${1:-}" in
  "")      PICKER_KIND=sessions ;;
  --panes) PICKER_KIND=panes ;;
  *)       fail_and_close "usage: ksession-picker.sh [--panes]" ;;
esac

require_inside_tmux
require_cmd fzf
source_shared_lib modal_fsm.sh

# Row schema (5 tab-separated fields):
#   1 action   ∈ {switch, restore, pane}
#   2 target   switch: tmux session name; restore: saved session name;
#              pane: tmux pane id (%N)
#   3 key      switch: frecency key `running:<session>`; restore:
#              `saved:<name>`. The namespaces keep a running session and a
#              saved session that merely share a name from pooling one
#              score (bumping one would promote the other, deleting one
#              would erase the other's history). Pane rows carry the
#              owning session name here instead (used by switch-client).
#   4 display  what fzf shows (--with-nth=4); already colourised
#   5 activity #{session_activity} epoch seconds (switch rows only) — the
#              recency proxy for the sort; empty elsewhere
#
# ALL_ROWS holds the newline-terminated buffer fed to every fzf call; a
# delete splices the row out in place rather than re-enumerating.
ALL_ROWS=""

# ---- Sessions mode ----------------------------------------------------------

# Running sessions first, then saved sessions whose tmux session is not
# running. Both append to ALL_ROWS directly (no command substitution: the
# subshell would lose the RUNNING/LIVE_KEYS bookkeeping). LIVE_KEYS
# collects every running and saved key — including saved sessions hidden
# by the dedup — so the frecency prune below never forgets a session that
# merely happens to be open right now.
declare -A RUNNING=()
LIVE_KEYS=""

enumerate_running_sessions() {
  local name windows clients activity mark display
  while IFS=$'\t' read -r name windows clients activity; do
    RUNNING[$name]=1
    LIVE_KEYS+="running:${name}"$'\n'
    mark="$MARK_NONE"
    [[ "$name" == "$CURRENT_SESSION" ]] && mark="$MARK_CURRENT"
    display="$(running_session_display "$mark" "$name" "$windows" "$clients")"
    ALL_ROWS+="switch"$'\t'"${name}"$'\t'"running:${name}"$'\t'"${display}"$'\t'"${activity}"$'\n'
  done < <(tmux list-sessions -F '#{session_name}	#{session_windows}	#{session_attached}	#{session_activity}')
}

# A blank or truncated porcelain line is skipped rather than trusted: an
# empty name would be a fatal `RUNNING[]` subscript under bash.
enumerate_saved_sessions() {
  local name session windows panes _created display
  while IFS=$'\t' read -r name session windows panes _created; do
    if [[ -z "$name" || -z "$session" ]]; then
      log_line "ignoring malformed list row: '${name}'"
      continue
    fi
    LIVE_KEYS+="saved:${name}"$'\n'
    [[ -n "${RUNNING[$session]:-}" ]] && continue
    display="$(saved_session_display "$MARK_NONE" "$BULLET_SAVED" "$name" "$session" "$windows" "$panes")"
    ALL_ROWS+="restore"$'\t'"${name}"$'\t'"saved:${name}"$'\t'"${display}"$'\t'$'\n'
  done < <(list_saved_sessions)
}

# One `frecency_dump` (a single jq run) serves both the orphan prune and
# the sort; scoring each key separately would spawn three jq processes
# per key and make popup latency grow with the session count.
FRECENCY_SCORES=""

load_frecency_scores() {
  FRECENCY_SCORES="$(frecency_dump 2>>"$LOG" || true)"
}

# Drop frecency entries whose key is neither a running nor a saved
# session so stale keys stop skewing the order. Best-effort (ADR 0001):
# flock contention or a malformed store must never block the picker.
prune_orphan_frecency_keys() {
  local key _score
  local -A live=()
  while IFS= read -r key; do
    [[ -n "$key" ]] && live[$key]=1
  done <<<"$LIVE_KEYS"
  while IFS=$'\t' read -r key _score; do
    if [[ -n "$key" && -z "${live[$key]:-}" ]]; then
      frecency_remove "$key" 2>>"$LOG" || true
    fi
  done <<<"$FRECENCY_SCORES"
}

# Frecency sort: composite desc, ties by kind (running first) then name.
#   switch : max(frecency_score(key), exp(-age/3600)) where age is measured
#            against the newest session_activity seen (kitty's recency
#            proxy): a session you were just in beats cold frecency entries
#            but loses to anything used often.
#   restore: frecency_score(key)
#   current session: -inf, so it always sits at the bottom.
# Keys absent from the dump score 0. Names travel through ENVIRON rather
# than awk -v, which would reinterpret backslashes in them.
sort_session_rows() {
  printf '%s' "$ALL_ROWS" | current="$CURRENT_SESSION" scores="$FRECENCY_SCORES" awk -F'\t' '
    BEGIN {
      n = split(ENVIRON["scores"], lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue
        split(lines[i], pair, "\t")
        score_of[pair[1]] = pair[2] + 0
      }
    }
    $1 == "switch" && ($5 + 0) > max_activity { max_activity = $5 + 0 }
    { rows[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        split(rows[i], f, "\t")
        score = (f[3] in score_of) ? score_of[f[3]] : 0
        rank = 1
        if (f[1] == "switch") {
          rank = 0
          proxy = exp(-(max_activity - (f[5] + 0)) / 3600.0)
          if (proxy > score) score = proxy
          if (f[2] == ENVIRON["current"]) score = -1e308
        }
        # %.10f keeps enough precision for proxy differences to order.
        printf "%.10f\t%d\t%s\t%s\n", score, rank, f[2], rows[i]
      }
    }
  ' | LC_ALL=C sort -t $'\t' -k1,1gr -k2,2n -k3,3 | cut -f4-
}

build_session_rows() {
  require_cmd jq            # frecency.sh is jq-backed
  require_ksession_binary
  source_shared_lib frecency.sh
  # Separate store from the kitty picker's: the key spaces (kitty session
  # names vs tmux session names) are unrelated and would pollute each other.
  export FRECENCY_STORE="${FRECENCY_STORE:-$HOME/.cache/ksession-tmux-frecency.json}"
  export FRECENCY_LOG="${FRECENCY_LOG:-$LOG}"

  CURRENT_SESSION="$(current_tmux_session)"
  enumerate_running_sessions
  enumerate_saved_sessions
  if [[ -z "$ALL_ROWS" ]]; then
    fail_and_close "no tmux sessions and no saved sessions."
  fi

  load_frecency_scores
  prune_orphan_frecency_keys
  ALL_ROWS="$(sort_session_rows)"$'\n'

  PROMPT_LABEL="session"
  # Live screen of the session's active pane (capture-pane -e keeps the
  # colours); `=name:` is tmux's exact-match form for a pane target. The
  # binary's stderr goes to the log so its diagnostics never open the
  # preview pane.
  printf -v PREVIEW_CMD \
    'if [ {1} = switch ]; then tmux capture-pane -ep -t ={2}:; else %q tmux show {2} 2>>%q; fi' \
    "$KSESSION" "$LOG"
}

# ---- Panes mode --------------------------------------------------------------

# pane_display <mark> <session> <window-index> <pane-index> <window-name> <command> <path>
#   "<mark> ● [sess:win.pane]  <window name>  ·  <command>  ·  <~/path>"
pane_display() {
  local mark="$1" tag="${ANSI_BOLD}[$2:$3.$4]${ANSI_RESET}" path="${7/#"$HOME"/"~"}"
  printf '%s %s %s  %s%s%s%s%s' "$mark" "$BULLET_RUNNING" "$tag" "$5" "$SEP" "$6" "$SEP" "$path"
}

enumerate_panes() {
  local pane_id session window_index pane_index window_name command path mark display
  while IFS=$'\t' read -r pane_id session window_index pane_index window_name command path; do
    mark="$MARK_NONE"
    [[ "$pane_id" == "$CURRENT_PANE" ]] && mark="$MARK_CURRENT"
    display="$(pane_display "$mark" "$session" "$window_index" "$pane_index" "$window_name" "$command" "$path")"
    ALL_ROWS+="pane"$'\t'"${pane_id}"$'\t'"${session}"$'\t'"${display}"$'\t'$'\n'
  done < <(tmux list-panes -a -F '#{pane_id}	#{session_name}	#{window_index}	#{pane_index}	#{window_name}	#{pane_current_command}	#{pane_current_path}')
}

build_pane_rows() {
  CURRENT_PANE="$(tmux display-message -p '#{pane_id}')"
  enumerate_panes
  if [[ -z "$ALL_ROWS" ]]; then
    fail_and_close "no panes."
  fi
  PROMPT_LABEL="pane"
  PREVIEW_CMD='tmux capture-pane -ep -t {2}'
}

# ---- Actions -----------------------------------------------------------------

# Dispatch the current selection and exit. Frecency is bumped on success;
# a failure is shown and keeps the popup open so it can be read.
open_selection() {
  local action target key rc=0
  IFS=$'\t' read -r action target key _ <<<"$selection"
  log_line "open action=$action target='$target'"
  case "$action" in
    switch)  tmux switch-client -t "=$target" >>"$LOG" 2>&1 || rc=$? ;;
    restore) "$KSESSION" tmux restore "$target" >>"$LOG" 2>&1 || rc=$? ;;
    pane)
      { tmux switch-client -t "=$key" \
          && tmux select-window -t "$target" \
          && tmux select-pane -t "$target"; } >>"$LOG" 2>&1 || rc=$?
      ;;
  esac
  if (( rc != 0 )); then
    fail_and_close "$action '$target' failed (rc=$rc), see $LOG"
  fi
  if [[ "$action" != pane ]]; then
    frecency_bump "$key" 2>>"$LOG" || true
  fi
  exit 0
}

delete_prompt() {
  case "$1" in
    switch)  printf "kill tmux session '%s'?" "$2" ;;
    restore) printf "remove saved session '%s'?" "$2" ;;
  esac
}

# Destroy the selected row's target. Returns the dispatch rc; the
# frecency entry only goes with a successful delete, since on failure the
# row (and the session behind it) is still there.
delete_selection() {
  local action="$1" target="$2" key="$3" rc=0
  case "$action" in
    switch)  tmux kill-session -t "=$target" >>"$LOG" 2>&1 || rc=$? ;;
    restore) "$KSESSION" tmux rm "$target" >>"$LOG" 2>&1 || rc=$? ;;
  esac
  log_line "delete action=$action target='$target' rc=$rc"
  if (( rc == 0 )); then
    frecency_remove "$key" 2>>"$LOG" || true
  fi
  return $rc
}

# Rows are identified by (action, target) — fields 1 and 2 — because fzf
# --ansi strips the colour codes from the line it prints back, so the
# display field can't be matched verbatim.
row_identity() {
  printf '%s' "$1" | cut -f1,2
}

# Splice one row out of ALL_ROWS in place. ENVIRON avoids awk -v, which
# would reinterpret backslashes in names. The trailing newline is
# re-added with `||` so an emptied buffer doesn't trip errexit (a bare
# `[[ -n ]] &&` as the last statement would return 1).
remove_row() {
  ALL_ROWS="$(printf '%s' "$ALL_ROWS" | needle="$(row_identity "$1")" awk -F'\t' '
    ($1 "\t" $2) == ENVIRON["needle"] && !done { done = 1; next }
    { print }
  ')"
  [[ -z "$ALL_ROWS" ]] || ALL_ROWS+=$'\n'
}

# Handle the `delete` side effect for $selection: confirm, dispatch,
# drop the row, and land the cursor on the row that took its slot (or
# the new last row). Pane rows have nothing to delete (tab-picker
# precedent) and are left alone.
#
# The current session is refused outright: tmux's default
# detach-on-destroy would drop the client to its parent shell and SIGHUP
# this popup mid-flow. A consequence is that its row always survives, so
# the buffer never empties through a delete.
#
# A failed kill/rm keeps the row (the target still exists) and holds the
# message on screen until Enter so it can be read before fzf redraws.
delete_flow() {
  local action target key deleted_index row_count rc=0
  IFS=$'\t' read -r action target key _ <<<"$selection"
  [[ "$action" == pane ]] && return 0
  if [[ "$action" == switch && "$target" == "$CURRENT_SESSION" ]]; then
    notify_and_hold "refusing to kill the current session '$target' (switch away first)."
    return 0
  fi
  confirm_yes_no "$(delete_prompt "$action" "$target")" || return 0

  deleted_index="$cursor_index"
  delete_selection "$action" "$target" "$key" || rc=$?
  if (( rc != 0 )); then
    notify_and_hold "delete '$target' failed (rc=$rc), see $LOG"
    return 0
  fi
  remove_row "$selection"

  row_count="$(printf '%s' "$ALL_ROWS" | wc -l)"
  if (( deleted_index > row_count )); then
    cursor_index="$row_count"
  else
    cursor_index="$deleted_index"
  fi
  selection=""
}

# ---- fzf driver --------------------------------------------------------------
# Mirror of the driver in ~/.config/kitty/scripts/session-picker.sh (cursor
# shape, pos() probe, run_fzf flag sets, modal loop); keep the two in sync.

# Cursor shape: bar = insert, block = normal (DECSCUSR). Skipped under
# terminals that don't honour it.
cursor_supported() {
  case "${TERM:-}" in
    screen*|dumb|"") return 1 ;;
    *)               return 0 ;;
  esac
}
cursor_bar()   { if cursor_supported; then printf '\e[6 q' >&2; fi; }
cursor_block() { if cursor_supported; then printf '\e[2 q' >&2; fi; }
trap 'cursor_bar' EXIT

# `pos(N)` needs fzf >= 0.43; older versions degrade to the top row.
fzf_supports_pos() {
  local v major minor
  v="$(fzf --version 2>/dev/null | awk '{print $1}')"
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%.*}"
  [[ -z "$major" || -z "$minor" ]] && return 1
  if (( major > 0 )); then return 0; fi
  (( minor >= 43 ))
}
if fzf_supports_pos; then POS_BIND_SUPPORTED=1; else POS_BIND_SUPPORTED=0; fi

# 1-based index of the row matching the selection (fzf's pos() is
# 1-based: pos(1) and pos(0) are both the first row). 1 if none.
row_index_of() {
  printf '%s' "$ALL_ROWS" | needle="$(row_identity "$1")" awk -F'\t' '
    ($1 "\t" $2) == ENVIRON["needle"] { print NR; found = 1; exit }
    END { if (!found) print 1 }
  '
}

# One fzf invocation for the current $mode, restoring the cursor to
# $cursor_index. Prints fzf's two --expect lines; returns its exit code.
run_fzf() {
  local pos_bind="load:pos(1)"
  (( POS_BIND_SUPPORTED )) && pos_bind="load:pos(${cursor_index})"

  if [[ "$mode" == insert ]]; then
    cursor_bar
    printf '%s' "$ALL_ROWS" | fzf \
        --ansi \
        --with-nth=4 \
        --delimiter=$'\t' \
        --prompt="${PROMPT_LABEL}> " \
        --height=100% \
        --reverse \
        --no-sort \
        --preview="$PREVIEW_CMD" \
        --preview-window='right:60%:wrap' \
        --expect=enter,esc \
        --bind="$pos_bind"
  else
    cursor_block
    printf '%s' "$ALL_ROWS" | fzf \
        --ansi \
        --with-nth=4 \
        --delimiter=$'\t' \
        --prompt="${PROMPT_LABEL^^}> " \
        --height=100% \
        --reverse \
        --no-sort \
        --disabled \
        --no-clear \
        --sync \
        --preview="$PREVIEW_CMD" \
        --preview-window='right:60%:wrap' \
        --bind='j:down,k:up,ctrl-d:half-page-down,ctrl-u:half-page-up,g:first,G:last' \
        --bind="$pos_bind" \
        --expect=enter,i,esc,q,d
  fi
}

# ---- Main --------------------------------------------------------------------

case "$PICKER_KIND" in
  sessions) build_session_rows ;;
  panes)    build_pane_rows ;;
esac

# Modal loop: each iteration runs fzf in the current mode, feeds the
# --expect key to picker_transition (lib/modal_fsm.sh) and acts on the
# side effect: open dispatches and exits, delete mutates the buffer and
# stays in normal mode, quit exits, noop re-enters fzf in the new mode.
mode="insert"
cursor_index=1
selection=""

while true; do
  # fzf exits 130 on Ctrl-C / Esc-without-selection; inspect it ourselves.
  set +e
  fzf_out="$(run_fzf)"
  fzf_rc=$?
  set -e

  key="$(sed -n '1p' <<<"$fzf_out")"
  selection="$(sed -n '2p' <<<"$fzf_out")"

  # No key, no selection, non-zero rc: the user bailed out.
  if [[ -z "$key" && -z "$selection" && $fzf_rc -ne 0 ]]; then
    exit 0
  fi
  # rc=0 without an --expect key cannot happen with our lists; treat as Enter.
  [[ -z "$key" && -n "$selection" ]] && key="enter"
  [[ -n "$selection" ]] && cursor_index="$(row_index_of "$selection")"

  trans_out="$(picker_transition "$mode" "$key")"
  next_mode="$(sed -n '1p' <<<"$trans_out")"
  side_effect="$(sed -n '2p' <<<"$trans_out")"

  case "$side_effect" in
    open)   [[ -n "$selection" ]] && open_selection ;;
    delete) [[ -n "$selection" ]] && delete_flow ;;
  esac

  mode="$next_mode"
  [[ "$mode" == quit ]] && exit 0
done
