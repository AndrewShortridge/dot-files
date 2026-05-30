#!/usr/bin/env bash
# running-sessions - cross-process detection of which named kitty project
# sessions are currently live.
#
# A "project session" is any OS window whose wm_class matches
# `kitty-project-<name>` (the convention used by session-picker.sh's spawn
# path and by ksession.sh restore output). This helper enumerates every
# kitty process by walking /tmp/kitty-* sockets, queries each via
# `kitty @ ls`, and emits the deduped set of project names.
#
# Sourceable. Requires `jq` on PATH.
#
# Exposed functions:
#
#   running_session_names
#       Prints one project name per line to stdout (sorted, deduped).
#       Excludes the `ssh-*` ephemeral namespace (those windows count as
#       running for session-picker.sh's dedup, but ksession.sh / .conf
#       files never reference them; surfacing them here would just add
#       noise).
#
#   current_session_name [kitty_window_id]
#       Prints the project name of the OS window that contains the given
#       kitty-internal window id (defaults to $KITTY_WINDOW_ID). Empty
#       output if not found or if the containing OS window has no
#       `kitty-project-*` wm_class.
#
# Both functions are read-only; failures are silent (stale sockets,
# missing jq, no matches → empty output, exit 0).

running_session_names() {
  running_session_details | awk -F'\t' 'NF { print $1 }' | LC_ALL=C sort -u
}

# Emits one TSV line per running `kitty-project-<name>` OS window:
#   <name>\t<pid>\t<osw_id>\t<active_tab_title>\t<num_tabs>\t<active_cwd>
#
# Fields match the metadata that session-picker.sh's Pass 1 renders in the
# running-row display column, so the other pickers can mirror the format
# verbatim. `ssh-*` ephemeral sessions are excluded (same rationale as
# running_session_names).
running_session_details() {
  command -v jq >/dev/null 2>&1 || return 0
  local sock ls_json pid
  for sock in /tmp/kitty-*; do
    [[ -S "$sock" ]] || continue
    ls_json=$(kitty @ --to "unix:$sock" ls 2>/dev/null) || continue
    pid="${sock##*/kitty-}"
    printf '%s\n' "$ls_json" | jq -r --arg pid "$pid" '
      .[] as $osw
      | ($osw.wm_class // "") as $cls
      | select($cls | startswith("kitty-project-"))
      | select($cls | startswith("kitty-project-ssh-") | not)
      | ( ($osw.tabs[] | select(.is_active)) // $osw.tabs[0] ) as $tab
      | ( ($tab.windows[] | select(.is_active)) // $tab.windows[0] ) as $aw
      | [
          ($cls | sub("^kitty-project-"; "")),
          $pid,
          ($osw.id | tostring),
          $tab.title,
          ($osw.tabs | length | tostring),
          ($aw.cwd // "?")
        ] | @tsv
    '
  done
}

current_session_name() {
  command -v jq >/dev/null 2>&1 || return 0
  local target="${1:-${KITTY_WINDOW_ID:-}}"
  [[ -z "$target" ]] && return 0
  local sock="${KITTY_LISTEN_ON:-}"
  local ls_json wm_class
  if [[ -n "$sock" ]]; then
    ls_json=$(kitty @ --to "$sock" ls 2>/dev/null) || return 0
  else
    ls_json=$(kitty @ ls 2>/dev/null) || return 0
  fi
  wm_class=$(printf '%s\n' "$ls_json" | jq -r --arg w "$target" '
    .[]
    | select(any(.tabs[].windows[]; .id == ($w|tonumber)))
    | (.wm_class // "")
  ' | head -n1)
  [[ "$wm_class" == kitty-project-* ]] || return 0
  [[ "$wm_class" == kitty-project-ssh-* ]] && return 0
  printf '%s\n' "${wm_class#kitty-project-}"
}
