#!/usr/bin/env bash
# Combined session picker: lists every running kitty OS window (across
# all kitty processes) AND every project session file that isn't open
# yet. Running entries focus on Enter; project entries spawn.
# Bound from kitty.conf via ctrl+space>s.
set -euo pipefail

# Kitty launches this directly (not via an interactive shell), so .bashrc
# isn't sourced and miniconda/local paths are missing. Add them explicitly.
export PATH="$PATH:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin"

SESSIONS_DIR="${KITTY_PROJECT_SESSIONS_DIR:-$HOME/.config/kitty/sessions}"
LOG="${HOME}/.cache/kitty-session-picker.log"
mkdir -p "$(dirname "$LOG")"

# --- Page-cache pre-warming ----------------------------------------------------
# Read kitty's binary and shared libraries into the OS page cache so the
# real restore launch avoids cold disk reads.  No window, no flash.
WARM_CACHE_PID=""

warm_page_cache() {
  (
    kitty_bin="$(command -v kitty 2>/dev/null)" || return
    kitty_real="$(readlink -f "$kitty_bin")"
    kitty_app="${kitty_real%/bin/kitty}"
    cat "$kitty_real" > /dev/null 2>&1
    if [[ -d "$kitty_app/lib" ]]; then
      find "$kitty_app/lib" -name '*.so' -o -name '*.so.*' 2>/dev/null \
        | xargs cat > /dev/null 2>&1
    fi
  ) &
  WARM_CACHE_PID=$!
}

cleanup_warm_cache() {
  if [[ -n "${WARM_CACHE_PID:-}" ]]; then
    kill "$WARM_CACHE_PID" 2>/dev/null || true
    wait "$WARM_CACHE_PID" 2>/dev/null || true
    WARM_CACHE_PID=""
  fi
}

if ! command -v jq >/dev/null || ! command -v fzf >/dev/null; then
  echo "session-picker needs jq and fzf on PATH." >&2
  read -rp "press enter to close..."
  exit 1
fi

current_sock_url="${KITTY_LISTEN_ON:-}"

# Row schema (8 tab-separated fields):
#   1 action  ∈ {focus, spawn, ssh}
#   2 sock_url   (focus only)   e.g. unix:/tmp/kitty-12345
#   3 window_id  (focus only)   kitty-internal active-window id (used by
#                               focus-window / get-text --match id:)
#   4 file_path  (spawn only) — for ssh rows we stash the host alias here
#                so the preview pane can dispatch off field {4}.
#   5 frecency_key — the key used for frecency bumps & scoring:
#                  - spawn:  saved session basename (e.g. "rust-kitty-sessionizer")
#                  - ssh:    "ssh-<host>"
#                  - focus:  "<project-name>" when wm_class matches
#                            kitty-project-<name>, else "__adhoc_<pid>_<osw_id>"
#   6 display string (what fzf shows — pinned via --with-nth=6 so trailing
#                    fields can be added without leaking into the UI)
#   7 last_focused_at — kitty's float seconds-since-boot (focus rows only;
#                       empty for spawn/ssh). Used by the sort step.
#   8 osw_id     (focus only)   kitty OS-window id (used by
#                               close-os-window --match id: for delete-in-place;
#                               empty for spawn/ssh).

# Source the ssh-config host enumerator (Pass 3), the frecency lib, and
# the modal FSM that drives the insert/normal mode loop.
# shellcheck source=lib/ssh_hosts.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ssh_hosts.sh"
# shellcheck source=lib/frecency.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/frecency.sh"
# shellcheck source=lib/modal_fsm.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/modal_fsm.sh"
SSH_CONFIG_PATH="${SSH_CONFIG_PATH:-$HOME/.ssh/config}"

# ----- Pass 1: enumerate every running kitty OS window via /tmp/kitty-* -----
declare -A proj_running   # wm_class -> "1" when matched, used to dedupe Pass 2
running_rows=""

for sock in /tmp/kitty-*; do
  [[ -S "$sock" ]] || continue
  ls_json=$(kitty @ --to "unix:$sock" ls 2>/dev/null) || continue
  pid="${sock##*/kitty-}"
  sock_url="unix:$sock"
  mark=$([[ "$sock_url" == "$current_sock_url" ]] && printf '*' || printf ' ')

  while IFS=$'\t' read -r aw_id osw_id num_tabs title cwd cls lfa; do
    [[ -z "$aw_id" ]] && continue
    s=$([[ "$num_tabs" == "1" ]] && printf "tab" || printf "tabs")
    if [[ "$cls" == kitty-project-* ]]; then
      frec_key="${cls#kitty-project-}"
      proj_running["$cls"]=1
      display="${mark} ● [${pid}.${osw_id}]  ${frec_key}  ·  ${title}  ·  ${num_tabs} ${s}  ·  ${cwd}"
    else
      # Synthetic key for ad-hoc windows: scored as 0 (unseen).
      frec_key="__adhoc_${pid}_${osw_id}"
      display="${mark} ● [${pid}.${osw_id}]  ${title}  ·  ${num_tabs} ${s}  ·  ${cwd}"
    fi
    running_rows+="focus"$'\t'"${sock_url}"$'\t'"${aw_id}"$'\t'$'\t'"${frec_key}"$'\t'"${display}"$'\t'"${lfa}"$'\t'"${osw_id}"$'\n'
  done < <(echo "$ls_json" | jq -r '
    .[] as $osw |
    ( ($osw.tabs[] | select(.is_active)) // $osw.tabs[0] ) as $tab |
    ( ($tab.windows[] | select(.is_active)) // $tab.windows[0] ) as $aw |
    [
      ($aw.id|tostring),
      ($osw.id|tostring),
      (($osw.tabs|length)|tostring),
      $tab.title,
      ($aw.cwd // "?"),
      ($osw.wm_class // ""),
      ((($aw.last_focused_at // 0) | tostring))
    ] | @tsv
  ')
done

# ----- Pass 2: project session files not currently running -----
spawn_rows=""
shopt -s nullglob
for f in "$SESSIONS_DIR"/*.conf; do
  name=$(basename "$f" .conf)
  cls="kitty-project-${name}"
  [[ -n "${proj_running[$cls]:-}" ]] && continue   # covered by Pass 1
  desc=$(grep -m1 -iE '^# *Description:' "$f" 2>/dev/null \
         | sed -E 's/^# *[Dd]escription: *//' || true)
  desc_part=""
  [[ -n "$desc" ]] && desc_part="  ·  ${desc}"
  display="   ○ ${name}${desc_part}"
  spawn_rows+="spawn"$'\t'$'\t'$'\t'"${f}"$'\t'"${name}"$'\t'"${display}"$'\t'$'\t'$'\n'
done
shopt -u nullglob

# ----- Pass 3: ssh-config hosts not currently running -----
# Emits one row per concrete Host alias in ~/.ssh/config (and includes).
# Dedup against Pass 1 happens via the kitty-project-ssh-<host> wm_class
# convention: such windows already populated proj_running[] in Pass 1.
ssh_rows=""
if [[ "${KSESSION_NO_SSH:-0}" != "1" ]]; then
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    cls="kitty-project-ssh-${host}"
    [[ -n "${proj_running[$cls]:-}" ]] && continue   # covered by Pass 1
    # Optional: pull HostName for the display suffix. Best-effort, awk
    # over the same config; missing or wildcard-only blocks yield "".
    hostname_line=$(awk -v h="$host" '
      BEGIN { in_block = 0 }
      /^[[:space:]]*#/ { next }
      {
        # Strip trailing comments and surrounding whitespace.
        sub(/#.*$/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0 == "") next
      }
      tolower($1) == "host" {
        in_block = 0
        for (i = 2; i <= NF; i++) if ($i == h) in_block = 1
        next
      }
      tolower($1) == "match" { in_block = 0; next }
      in_block && tolower($1) == "hostname" { print $2; exit }
    ' "$SSH_CONFIG_PATH" 2>/dev/null || true)
    suffix=""
    [[ -n "$hostname_line" ]] && suffix="  ·  ${hostname_line}"
    display="   ⚡ ssh-${host}${suffix}"
    # field 4 carries the host alias so the preview command can use it
    # without re-parsing the selection.
    ssh_rows+="ssh"$'\t'$'\t'$'\t'"${host}"$'\t'"ssh-${host}"$'\t'"${display}"$'\t'$'\t'$'\n'
  done < <(ssh_hosts "$SSH_CONFIG_PATH")
fi

all_rows="${running_rows}${spawn_rows}${ssh_rows}"
if [[ -z "$all_rows" ]]; then
  echo "no kitty sessions or project files found." >&2
  read -rp "press enter to close..."
  exit 0
fi

# ----- Orphan frecency prune -------------------------------------------------
#
# Pass 1/2/3 are now done, so `proj_running[]` is populated. Build the list
# of "currently running keys" (the values that fed frecency_key for focus
# rows in Pass 1) and ask the lib to drop any store entry that has no
# `.conf` AND isn't running AND isn't `ssh-*` AND isn't `__adhoc_*`.
#
# Best-effort: wrap in `set +e` so any failure (flock contention, jq
# weirdness) cannot block the picker. The lib also tolerates errors
# internally — this is belt-and-braces.
#
# MUST run before sort_rows, since sort_rows queries frecency_score per key
# and we don't want stale scores polluting the order.
_prune_orphan_frecency_keys() {
  local running_keys=""
  local cls
  for cls in "${!proj_running[@]}"; do
    # proj_running keys are wm_class values like "kitty-project-foo" and
    # "kitty-project-ssh-bar". Strip the "kitty-project-" prefix to get
    # the frecency key. SSH keys ("ssh-<host>") and adhoc keys are skipped
    # by the lib regardless, but emitting them in the running list is
    # cheap and slightly more accurate.
    case "$cls" in
      kitty-project-*) running_keys+="${cls#kitty-project-}"$'\n' ;;
    esac
  done
  frecency_prune_orphans "$SESSIONS_DIR" "$running_keys"
}
set +e
_prune_orphan_frecency_keys
set -e

# ----- Frecency sort ---------------------------------------------------------
# Build a `<composite>\t<display>\t<row>` line per row, sort by composite
# desc (ties broken alphabetically on display), then strip the prefix.
#
# composite per action:
#   focus: max(frecency_score(key), recency_proxy(last_focused_at))
#          where proxy = exp(-age_seconds / 3600); age_seconds is measured
#          against the most-recent last_focused_at we saw across all focus
#          rows (kitty's lfa is "seconds since boot", so this normalizes
#          to the actual "now" without needing /proc/uptime). Range (0,1]:
#          a brand-new focus scores ~1.0, which beats a stale-but-low-count
#          frecency entry (count*0.25 < 1 for count<=3) but loses cleanly
#          to any high-frequency entry (count*4 >> 1).
#   spawn, ssh: frecency_score(key).
#
# The current-session row (sock_url == current_sock_url) is forced to the
# very bottom by setting its composite to -inf.
sort_rows() {
  # Compute max(last_focused_at) across focus rows so we can build the
  # recency proxy in awk below without knowing the system uptime.
  local max_lfa
  max_lfa=$(printf '%s' "$all_rows" | awk -F'\t' '
    $1 == "focus" && $7 != "" && ($7+0) > max { max = $7+0 }
    END { if (max == "") print "0"; else print max }
  ')

  # Pre-compute frecency scores for every distinct key (cheap; bounded by
  # row count). Emit a `<key>\t<score>` map that awk can ingest.
  # NOTE: bash's `read -d $'\n' IFS=$'\t'` collapses consecutive tabs
  # because tab is whitespace in IFS. Use awk to extract field 5 instead.
  local key_scores=""
  local -A seen_keys=()
  local key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    [[ -n "${seen_keys[$key]:-}" ]] && continue
    seen_keys[$key]=1
    if [[ "$key" == __adhoc_* ]]; then
      key_scores+="${key}"$'\t'"0"$'\n'
    else
      key_scores+="${key}"$'\t'"$(frecency_score "$key")"$'\n'
    fi
  done < <(printf '%s' "$all_rows" | awk -F'\t' 'NF >= 5 && $5 != "" { print $5 }')

  printf '%s' "$all_rows" | awk -F'\t' -v OFS='\t' \
      -v cur_sock="$current_sock_url" \
      -v max_lfa="$max_lfa" \
      -v scores="$key_scores" '
    BEGIN {
      # Parse scores into score_of[key].
      n = split(scores, lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue
        split(lines[i], pair, "\t")
        score_of[pair[1]] = pair[2] + 0
      }
    }
    function recency_proxy(lfa,    age) {
      if (lfa == "" || lfa+0 == 0) return 0
      age = max_lfa - (lfa + 0)
      if (age < 0) age = 0
      # exp(-age / 3600); awk has exp().
      return exp(-age / 3600.0)
    }
    {
      action = $1; sock = $2; key = $5; display = $6; lfa = $7
      fscore = (key in score_of) ? score_of[key] : 0
      if (action == "focus") {
        prox = recency_proxy(lfa)
        composite = (fscore > prox) ? fscore : prox
      } else {
        composite = fscore
      }
      # Sink the current-session row.
      if (action == "focus" && sock == cur_sock && cur_sock != "") {
        composite = -1e308
      }
      # Emit `<composite>\t<display>\t<row>` for sorting. Use %.10f so the
      # numeric sort key has enough precision for proxy differences.
      printf "%.10f\t%s\t%s\n", composite, display, $0
    }
  ' | LC_ALL=C sort -t $'\t' -k1,1gr -k2,2 \
    | cut -f3-
}

# Add ANSI colors to field 6 (the display column) based on action type.
# fzf strips these for matching/display layout but keeps them in the output
# selection, so _row_index_of and the delete-in-place filter still match on
# the colorized line verbatim. The non-display fields (1-5, 7, 8) are
# untouched, so `cut -f1`, `cut -f2`, etc. in the dispatch still see clean
# values.
#
# Palette (terminal-theme-safe — uses ANSI-16 only):
#   running ●           : green
#   saved ○             : blue
#   ssh ⚡              : yellow
#   current-session *   : bold magenta
#   project/session name: bold (no color shift)
#   separator ·         : dim
#   trailing cwd/desc   : dim
colorize_rows() {
  awk -F'\t' -v OFS='\t' '
    BEGIN {
      reset  = "\033[0m"
      dim    = "\033[2m"
      bold   = "\033[1m"
      green  = "\033[32m"
      blue   = "\033[34m"
      yellow = "\033[33m"
      magenta_b = "\033[1;35m"
    }
    {
      action = $1
      d = $6

      # Current-session marker: leading "*" before the bullet.
      if (substr(d, 1, 1) == "*") {
        d = magenta_b "*" reset substr(d, 2)
      }

      # Action bullet.
      if      (action == "focus") sub(/●/,  green  "●"  reset, d)
      else if (action == "spawn") sub(/○/,  blue   "○"  reset, d)
      else if (action == "ssh")   sub(/⚡/, yellow "⚡" reset, d)

      # Dim the " · " separators (UTF-8 middot is C2 B7; awk handles it
      # under the default locale on this system).
      gsub(/ · /, " " dim "·" reset " ", d)

      # Bold the [pid.osw] tag on focus rows so the IDs read as a unit.
      if (action == "focus") {
        # [12345.7] -> bold
        if (match(d, /\[[0-9]+\.[0-9]+\]/)) {
          tag = substr(d, RSTART, RLENGTH)
          d = substr(d, 1, RSTART - 1) bold tag reset substr(d, RSTART + RLENGTH)
        }
      }

      $6 = d
      print
    }
  '
}

all_rows="$(sort_rows | colorize_rows)"$'\n'

# ----- Modal loop ------------------------------------------------------------
#
# The picker runs in a loop driven by `picker_transition` (lib/modal_fsm.sh).
# Each iteration calls fzf with one of two profiles (insert | normal),
# captures the user's --expect key, and consults the FSM for the next mode
# and side effect (open | quit | noop). On `open`, we dispatch to the
# existing focus/spawn/ssh case and bump frecency. On `quit`, we exit. On
# `noop`, we re-enter fzf in the new mode.
#
# Cursor position is preserved across mode switches by parsing the
# row index of the selection out of fzf's print-query output and feeding
# it back via `load:pos(<index>)`.
#
# Cursor shape changes between modes (bar = insert, block = normal). We
# skip the DECSCUSR escapes under terminals that don't honor them
# (screen, dumb).
#
# Row composition (passes 1-3 + sort) ran ONCE above; the buffer is fed
# unchanged into every fzf invocation. (Issue #02 will mutate it after a
# delete; this slice does not.)

# Shared preview command, identical in both modes. Each row's `action` (field 1)
# selects one of three preview renderers, all of which emit ANSI-colored output
# that fzf renders in the preview pane:
#   focus -> kitty @ get-text --ansi   (live terminal contents w/ real colors)
#   ssh   -> lib/ssh-host-preview.sh   (colorized Host block from ssh-config)
#   spawn -> lib/conf-preview.sh       (colorized kitty session .conf)
_SCRIPTS_LIB="$(dirname "${BASH_SOURCE[0]}")/lib"
preview_cmd="if [ {1} = focus ]; then kitty @ --to {2} get-text --ansi --match id:{3} --extent screen 2>/dev/null; elif [ {1} = ssh ]; then \"$_SCRIPTS_LIB/ssh-host-preview.sh\" \"$SSH_CONFIG_PATH\" {4}; else \"$_SCRIPTS_LIB/conf-preview.sh\" {4}; fi"

# Cursor-shape helpers. DECSCUSR sequences:
#   \e[6 q = bar (insert), \e[2 q = block (normal).
# Skipped under screen* / dumb terminals (no DECSCUSR there).
_cursor_supported() {
  case "${TERM:-}" in
    screen*|dumb|"") return 1 ;;
    *)               return 0 ;;
  esac
}
_cursor_bar()   { _cursor_supported && printf '\e[6 q' >&2 || true; }
_cursor_block() { _cursor_supported && printf '\e[2 q' >&2 || true; }

# Always restore the bar cursor and kill warm kitty on exit.
trap 'cleanup_warm_cache; _cursor_bar' EXIT

# fzf supports `pos(<index>)` from 0.43 onward. Detect once; degrade to
# `pos(0)` (cursor at top) on older fzf so the script still works.
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

if _fzf_supports_pos; then
  POS_BIND_SUPPORTED=1
else
  POS_BIND_SUPPORTED=0
fi

# Find the 1-based row index in `all_rows` whose full \t-joined content
# matches the given selection line. Returns 0 (top) if no match. Used to
# persist the cursor position across mode switches.
_row_index_of() {
  local needle="$1"
  [[ -z "$needle" ]] && { printf '0\n'; return 0; }
  # awk over $all_rows; print (NR-1) for 0-based index that pos() wants.
  printf '%s' "$all_rows" | awk -v n="$needle" '
    $0 == n { print NR - 1; found = 1; exit }
    END { if (!found) print 0 }
  '
}

# Drive one fzf invocation. Reads the global `mode` and `cursor_index`;
# writes its output to the global `fzf_out`. Returns fzf's exit code.
_run_fzf() {
  local pos_bind=""
  if (( POS_BIND_SUPPORTED )); then
    pos_bind="load:pos(${cursor_index:-0})"
  else
    pos_bind="load:pos(0)"
  fi

  if [[ "$mode" == "insert" ]]; then
    _cursor_bar
    printf '%s' "$all_rows" | fzf \
        --ansi \
        --with-nth=6 \
        --delimiter=$'\t' \
        --prompt='session> ' \
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
        --with-nth=6 \
        --delimiter=$'\t' \
        --prompt='SESSION> ' \
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

# Ask for one-character yes/no confirmation on stderr. Returns 0 on
# confirm (y/Y/Enter), 1 on cancel (anything else, including EOF). When
# KSESSION_PICKER_NO_CONFIRM=1, returns 0 immediately without prompting.
# Reads from /dev/tty so it works even when stdin is piped (the picker
# is normally invoked under `launch --type=overlay` where /dev/tty is
# the terminal).
_confirm_delete() {
  local name="$1" reply=""
  if [[ "${KSESSION_PICKER_NO_CONFIRM:-0}" == "1" ]]; then
    return 0
  fi
  printf "delete '%s'? [y/N] " "$name" >&2
  # -n1 reads one char; an empty read (Enter) confirms.
  if ! IFS= read -rsn1 reply </dev/tty 2>/dev/null; then
    printf '\n' >&2
    return 1
  fi
  printf '\n' >&2
  case "$reply" in
    y|Y|"") return 0 ;;
    *)      return 1 ;;
  esac
}

# Delete the row currently held in $selection. Writes a kind=delete log
# record (with action subtype, target identifier, and the dispatch rc).
# Also calls frecency_remove on the row's key. Returns 0 on success, 1
# on any dispatch failure (still removes the row from the buffer).
_delete_selection() {
  local action sock wid file name host target rc=0 state_dir
  action=$(printf '%s' "$selection" | cut -f1)
  sock=$(printf   '%s' "$selection"  | cut -f2)
  wid=$(printf    '%s' "$selection"  | cut -f3)
  file=$(printf   '%s' "$selection"  | cut -f4)
  name=$(printf   '%s' "$selection"  | cut -f5)
  local osw_id
  osw_id=$(printf '%s' "$selection"  | cut -f8)

  case "$action" in
    focus)
      # Close the OS window by its OS-window id (field 8). The
      # kitty-internal active-window id in field 3 wouldn't close the
      # whole window — only that one split.
      target="osw_id=${osw_id}"
      if [[ -z "$osw_id" ]]; then
        rc=2
      else
        kitty @ --to "$sock" close-os-window --match "id:${osw_id}" \
          >>"$LOG" 2>&1 || rc=$?
      fi
      ;;
    spawn)
      target="$file"
      state_dir="${file%.conf}.state"
      rm -f -- "$file" >>"$LOG" 2>&1 || rc=$?
      rm -rf -- "$state_dir" >>"$LOG" 2>&1 || rc=$?
      ;;
    ssh)
      host="$file"
      target="/tmp/kitty-ssh-sessions/ssh-${host}.kitty-session"
      rm -f -- "$target" >>"$LOG" 2>&1 || rc=$?
      ;;
    *)
      target="<unknown>"
      rc=3
      ;;
  esac

  # Drop the key from the frecency store. No-op if the key isn't present
  # or is empty.
  if [[ -n "$name" ]]; then
    frecency_remove "$name" 2>>"$LOG" || true
  fi

  printf '%s kind=delete action=%s target=%q rc=%d\n' \
    "$(date -Is)" "$action" "$target" "$rc" >>"$LOG"

  return $rc
}

# Dispatch the current selection through the existing focus/spawn/ssh
# table and bump frecency. Exits the script when done (the loop only
# calls this on the `open` side effect, which is terminal).
_open_and_exit() {
  local action sock wid file name host ssh_dir ssh_session_file action_rc
  action=$(printf '%s' "$selection" | cut -f1)
  sock=$(printf   '%s' "$selection" | cut -f2)
  wid=$(printf    '%s' "$selection" | cut -f3)
  file=$(printf   '%s' "$selection" | cut -f4)
  name=$(printf   '%s' "$selection" | cut -f5)

  echo "--- $(date -Is) action=$action name='${name}' ---" >>"$LOG"

  action_rc=0
  case "$action" in
    focus)
      kitty @ --to "$sock" focus-window --match "id:$wid" >>"$LOG" 2>&1 || action_rc=$?
      ;;
    spawn)
      # Use ksession binary for restore (spawns new window)
      # Priority: KSESSION_IMPL env > ~/.local/bin/ksession > hardcoded path
      local ksession_bin
      if [[ -n "${KSESSION_IMPL:-}" ]]; then
        ksession_bin="$KSESSION_IMPL"
      elif [[ -x "${HOME}/.local/bin/ksession" ]]; then
        ksession_bin="${HOME}/.local/bin/ksession"
      else
        ksession_bin="${HOME}/.config/kitty/scripts/ksession-rs/target/release/ksession"
      fi
      if [[ -x "$ksession_bin" ]]; then
        "$ksession_bin" restore "$name" >>"$LOG" 2>&1 || { action_rc=$?; echo "ksession restore failed with $action_rc" >>"$LOG"; }
      else
        # Fallback to direct kitty spawn
        kitty --detach --class "kitty-project-${name}" --session "$file" \
              >>"$LOG" 2>&1 || { action_rc=$?; echo "kitty exited non-zero" >>"$LOG"; }
      fi
      ;;
    ssh)
      # field 4 carries the ssh host alias (see Pass 3 emit).
      host="$file"
      ssh_dir="/tmp/kitty-ssh-sessions"
      mkdir -p "$ssh_dir"
      ssh_session_file="${ssh_dir}/ssh-${host}.kitty-session"
      {
        printf '# Ephemeral kitty session for ssh %s\n' "$host"
        printf '# Generated by session-picker.sh on %s\n' "$(date -Is)"
        printf 'launch --title "ssh-%s" ssh %s\n' "$host" "$host"
      } > "$ssh_session_file"
      kitty --detach --class "kitty-project-ssh-${host}" --session "$ssh_session_file" \
            >>"$LOG" 2>&1 || { action_rc=$?; echo "kitty exited non-zero" >>"$LOG"; }
      ;;
  esac

  # Bump frecency on successful action. The `name` field IS the frecency key
  # by construction (see row schema field 5). Ad-hoc focus rows have a
  # synthetic `__adhoc_*` key; we still bump it so frecency_dump reflects
  # real use, but those entries score as ~0 by virtue of being short-lived
  # pids — they'll naturally rot out of the store. (A future cleanup pass
  # could prune `__adhoc_*` keys for dead pids.)
  if (( action_rc == 0 )) && [[ -n "$name" ]]; then
    frecency_bump "$name"
    echo "$(date -Is) frecency_bump action=$action key='${name}'" >>"$LOG"
  fi

  exit 0
}

# Pre-warm kitty so the OS page cache is hot when the user selects a session.
warm_page_cache

# Fresh launches always start in insert mode (PRD story 18).
mode="insert"
cursor_index=0
fzf_out=""
selection=""

while true; do
  # `set -e` would kill us on fzf exit code 130 (user pressed Ctrl-C or
  # closed without selection). Run the call tolerantly and inspect $?.
  set +e
  fzf_out="$(_run_fzf)"
  fzf_rc=$?
  set -e

  # fzf with --expect prints two lines: the key (possibly empty) then the
  # selected row (possibly empty). With no selection and no expected key
  # pressed (e.g. Ctrl-C, rc=130), both lines are empty and we just quit.
  key=$(printf '%s' "$fzf_out" | sed -n '1p')
  selection=$(printf '%s' "$fzf_out" | sed -n '2p')

  # No key pressed AND no selection AND non-zero rc => user bailed out.
  if [[ -z "$key" && -z "$selection" && $fzf_rc -ne 0 ]]; then
    exit 0
  fi

  # If fzf exited "normally" (rc=0) with no --expect key (shouldn't happen
  # under our --expect lists, but be defensive), treat it as Enter.
  if [[ -z "$key" && -n "$selection" ]]; then
    key="enter"
  fi

  # Remember where the cursor was so the next iteration can restore it.
  if [[ -n "$selection" ]]; then
    cursor_index=$(_row_index_of "$selection")
  fi

  # Consult the FSM.
  trans_out=$(picker_transition "$mode" "$key")
  next_mode=$(printf '%s' "$trans_out" | sed -n '1p')
  side_effect=$(printf '%s' "$trans_out" | sed -n '2p')

  case "$side_effect" in
    open)
      # Needs a selection to act on. If the user hit Enter on an empty
      # list (no rows match the current filter), just stay put.
      if [[ -z "$selection" ]]; then
        mode="$next_mode"
        [[ "$mode" == "quit" ]] && exit 0
        continue
      fi
      _open_and_exit
      ;;
    delete)
      # No selection => nothing to delete. Stay in normal mode.
      if [[ -z "$selection" ]]; then
        mode="$next_mode"
        [[ "$mode" == "quit" ]] && exit 0
        continue
      fi
      # Confirm (unless KSESSION_PICKER_NO_CONFIRM=1). On cancel just
      # re-enter the picker with the cursor on the same row.
      _del_name=$(printf '%s' "$selection" | cut -f5)
      if ! _confirm_delete "$_del_name"; then
        mode="$next_mode"
        continue
      fi
      # Capture the deleted row's 0-based index BEFORE we drop it so the
      # cursor can land on what was the next row.
      _del_idx="${cursor_index:-0}"
      _delete_selection || true
      # Filter the deleted line out of all_rows in-place. Re-running
      # Pass 1/2/3 would re-query every kitty socket and slow successive
      # deletes; this is a pure-string mutation.
      all_rows=$(printf '%s' "$all_rows" | awk -v n="$selection" '
        $0 == n && !done { done = 1; next }
        { print }
      ')
      # Re-add the trailing newline awk strips when there is no final
      # match (printf '%s' kept it; awk discards it). Match the original
      # buffer convention: trailing newline always present.
      if [[ -n "$all_rows" && "${all_rows: -1}" != $'\n' ]]; then
        all_rows="${all_rows}"$'\n'
      fi
      # Empty buffer => nothing left to manage; close the picker.
      if [[ -z "$all_rows" ]]; then
        exit 0
      fi
      # Land on the row that took the deleted row's slot. If we deleted
      # the last row, step up one.
      _row_count=$(printf '%s' "$all_rows" | awk 'NF { c++ } END { print c+0 }')
      if (( _del_idx >= _row_count )); then
        cursor_index=$(( _row_count - 1 ))
        (( cursor_index < 0 )) && cursor_index=0
      else
        cursor_index="$_del_idx"
      fi
      # Stay in normal mode (the FSM already routed us there) so
      # successive `d` presses are one keystroke each.
      mode="$next_mode"
      selection=""
      continue
      ;;
    quit)
      exit 0
      ;;
    noop)
      mode="$next_mode"
      # `quit` is a terminal pseudo-mode the FSM can land in alongside a
      # `noop` side effect (e.g. normal+q -> (quit, noop)). Honor it.
      [[ "$mode" == "quit" ]] && exit 0
      continue
      ;;
    *)
      # Defensive: unknown side effect from the FSM. Stay put.
      mode="$next_mode"
      [[ "$mode" == "quit" ]] && exit 0
      continue
      ;;
  esac
done
