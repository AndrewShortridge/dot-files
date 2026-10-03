#!/usr/bin/env bash
# scrollback-viewer - overlay that shows the current window's SAVED scrollback
# (the .ansi dump captured by `ksession save`) in a pager. Bound from kitty.conf.
#
# Behavior:
#   - Resolves the invoking window's `ksession_id` user var (set on restored
#     windows via `launch --var=ksession_id=<uuid>`). The overlay is its own
#     kitty window, so we look at the parent: the window sharing our window
#     group whose user_vars carry a ksession_id.
#   - Finds that uuid in sessions/*.state/manifest.json; if it appears in
#     multiple generations, the newest gen-<timestamp> wins.
#   - Opens the matched scrollback .ansi in `less -R +G` (colors, start at end).
#
# Debug/test mode (no kitty needed):
#   scrollback-viewer.sh --lookup <ksession_id>   # print resolved .ansi path

set -euo pipefail

# Kitty launches this directly (not via an interactive shell), so .bashrc
# isn't sourced and miniconda/local paths are missing. Add them explicitly.
export PATH="$PATH:/usr/local/bin:/usr/bin:/home/andrew/miniconda3/bin:/home/andrew/.local/bin"

SESSIONS_DIR="${KITTY_PROJECT_SESSIONS_DIR:-$HOME/.config/kitty/sessions}"

fail() {
  echo "scrollback-viewer: $*" >&2
  read -rp "press enter to close..."
  exit 1
}

# lookup_scrollback <uuid>
# Scan every *.state/manifest.json under SESSIONS_DIR for a window entry whose
# ksession_id matches, and print its scrollback path. The same uuid can appear
# in several generations of the same session; the gen-<timestamp> embedded in
# the state dirname is a sortable microsecond timestamp, so the numerically
# largest one is the newest save and wins. Returns 1 if the uuid is unknown.
lookup_scrollback() {
  local uuid="$1"
  local manifest sb dir ts best_ts="" best_path=""
  shopt -s nullglob
  for manifest in "$SESSIONS_DIR"/*.state/manifest.json; do
    # Window entries carry the path both at .scrollback and .program.scrollback;
    # prefer the top-level field, fall back to the program one.
    sb=$(jq -r --arg id "$uuid" '
      [.os_windows[].tabs[].windows[]
       | select(.ksession_id == $id)
       | (.scrollback // .program.scrollback // empty)]
      | first // empty
    ' "$manifest" 2>/dev/null) || continue
    [[ -z "$sb" ]] && continue
    dir=$(dirname "$manifest")
    ts="${dir##*.gen-}"
    ts="${ts%.state}"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      if [[ -z "$best_ts" ]] || (( ts > best_ts )); then
        best_ts="$ts"
        best_path="$sb"
      fi
    elif [[ -z "$best_path" ]]; then
      # Dirname without a parseable gen timestamp: keep only as a last resort.
      best_path="$sb"
    fi
  done
  shopt -u nullglob
  [[ -n "$best_path" ]] || return 1
  printf '%s\n' "$best_path"
}

if ! command -v jq >/dev/null; then
  fail "jq is required."
fi

# ---- Debug/test entry point --------------------------------------------------
if [[ "${1:-}" == "--lookup" ]]; then
  uuid="${2:-}"
  if [[ -z "$uuid" ]]; then
    echo "usage: scrollback-viewer.sh --lookup <ksession_id>" >&2
    exit 2
  fi
  if ! lookup_scrollback "$uuid"; then
    echo "scrollback-viewer: ksession_id '$uuid' not found in any manifest under $SESSIONS_DIR" >&2
    exit 1
  fi
  exit 0
fi

# ---- Resolve the invoking window's ksession_id -------------------------------
ls_json=$(kitty @ ls 2>/dev/null) || {
  fail "kitty remote control failed. Check 'allow_remote_control' in kitty.conf."
}

# KITTY_WINDOW_ID is set by kitty for child processes — but as an overlay we
# are our own window, stacked on the parent inside the same window group.
# Find the group containing our id, then take the ksession_id user var from
# the windows in that group, preferring the parent (is_self == false).
my_win="${KITTY_WINDOW_ID:-}"
if [[ -z "$my_win" ]]; then
  fail "KITTY_WINDOW_ID is not set; run this as a kitty overlay."
fi

ksession_id=$(echo "$ls_json" | jq -r --arg me "$my_win" '
  [ .[] | .tabs[]
    | (.groups // [])[] as $grp
    | select($grp.windows | index($me | tonumber))
    | .windows[]
    | select(.id as $id | $grp.windows | index($id))
  ]
  | sort_by(.is_self)
  | map(.user_vars.ksession_id // empty)
  | first // empty
')

if [[ -z "$ksession_id" ]]; then
  fail "no saved session associated with this window (no ksession_id user var)."
fi

# ---- Find the newest saved scrollback for that id ----------------------------
if ! scrollback_path=$(lookup_scrollback "$ksession_id"); then
  fail "ksession_id '$ksession_id' not found in any manifest under $SESSIONS_DIR."
fi

if [[ ! -f "$scrollback_path" ]]; then
  fail "saved scrollback file is missing: $scrollback_path"
fi
if [[ ! -s "$scrollback_path" ]]; then
  fail "saved scrollback file is empty: $scrollback_path"
fi

# -R keeps the raw ANSI colors; +G starts at the end (most recent output).
exec less -R +G "$scrollback_path"
