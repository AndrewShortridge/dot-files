#!/usr/bin/env bash
# ksession-save-prompt: popup that asks for a name, then saves the current
# tmux session via `ksession tmux save`. Bound from tmux.conf (prefix S);
# the tmux counterpart of kitty's ksession-save-prompt.sh.
#
# Behaviour:
#   - The query is pre-filled with the current tmux session name; existing
#     saved sessions are listed for Tab-completion / overwrite picking.
#   - Enter saves under the typed name (Tab completes it from the
#     highlighted row). With an empty query, Enter saves under the
#     highlighted row's name. Overwriting an existing name asks y/N.
#   - Empty input or Esc aborts.
set -euo pipefail

# shellcheck source=lib/ksession-tmux-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ksession-tmux-common.sh"
ksession_tmux_init ksession-save-prompt

require_inside_tmux
require_cmd fzf
require_ksession_binary

current_session="$(current_tmux_session)"

declare -A running=()
while IFS= read -r name; do
  running[$name]=1
done < <(tmux list-sessions -F '#{session_name}')

# Rows: "<name>\t<display>". fzf shows field 2; field 1 feeds the preview
# and the dispatch. Same display shape as the picker: ● when the saved
# session's tmux session is running, ○ otherwise, * on the current one.
declare -A saved=()
rows=""
while IFS=$'\t' read -r name session windows panes _created; do
  saved[$name]=1
  mark="$MARK_NONE"
  [[ "$session" == "$current_session" ]] && mark="$MARK_CURRENT"
  bullet="$BULLET_SAVED"
  [[ -n "${running[$session]:-}" ]] && bullet="$BULLET_RUNNING"
  rows+="${name}"$'\t'"$(saved_session_display "$mark" "$bullet" "$name" "$session" "$windows" "$panes")"$'\n'
done < <(list_saved_sessions)

# Preview: what the highlighted saved session contains, so the user can
# see what they are about to overwrite. The binary's stderr goes to the
# log so its diagnostics never open the preview pane.
printf -v preview_cmd '%q tmux show {1} 2>>%q' "$KSESSION" "$LOG"

# --print-query makes line 1 the typed query and line 2 the highlighted
# row (if any). Tab copies the highlighted name into the query; with no
# highlighted row (empty or filtered-out list) it keeps the query as is
# instead of wiping the pre-filled default.
selection="$(printf '%s' "$rows" \
  | fzf --print-query \
        --ansi \
        --prompt='save session as> ' \
        --query="$current_session" \
        --height=100% --reverse \
        --header='Enter: save as typed  ·  Tab: complete from list  ·  Esc: cancel' \
        --delimiter=$'\t' \
        --with-nth=2 \
        --preview="$preview_cmd" \
        --preview-window='right:55%:wrap' \
        --bind='tab:transform-query([ -n {1} ] && printf %s {1} || printf %s {q})' \
  || true)"

query="$(sed -n '1p' <<<"$selection")"
chosen="$(sed -n '2p' <<<"$selection" | cut -f1)"

# The typed name wins; the highlighted row only applies to an empty query.
# (Letting the row win, as kitty does, would make the pre-filled current
# session name overwrite any saved session it fuzzy-matches.)
name="${query#"${query%%[![:space:]]*}"}"   # trim leading whitespace
name="${name%"${name##*[![:space:]]}"}"     # trim trailing whitespace
[[ -z "$name" ]] && name="$chosen"

if [[ -z "$name" ]]; then
  echo "$TOOL: aborted."
  sleep 0.6
  exit 0
fi

# Mirror ksession's name rule for a friendlier message.
if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
  fail_and_close "invalid name '$name' (use letters, digits, dot, underscore, dash)."
fi

if [[ -n "${saved[$name]:-}" ]]; then
  confirm_yes_no "overwrite existing session '$name'?" || { echo "aborted."; exit 0; }
fi

echo "saving '$name'..."
# The binary's diagnostics go to the log; stdout stays for user feedback.
# Exit 2 means saved-but-degraded (ADR 0001): still a success, but worth
# a look at the log, so hold the popup open for that case.
rc=0
"$KSESSION" tmux save "$name" 2>>"$LOG" || rc=$?
case "$rc" in
  0)
    echo
    echo "✔ saved. Press Enter (or wait 2s) to close."
    read -rt 2 _ || true
    ;;
  2)
    echo
    echo "✔ saved with warnings (some panes degraded). See $LOG for details."
    wait_for_enter
    ;;
  *)
    echo
    echo "✘ save failed. See $LOG for details."
    wait_for_enter
    exit 1
    ;;
esac
