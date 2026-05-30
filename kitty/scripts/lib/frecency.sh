#!/usr/bin/env bash
# frecency: tiny JSON-backed frecency store with zoxide-style decay.
#
# Sourceable; exposes four functions:
#   frecency_bump   <key>   record a use of <key> at now (ms).
#   frecency_score  <key>   print float score, or "0" if unseen.
#   frecency_remove <key>   drop <key> from the store.
#   frecency_dump           emit `<key>\t<score>` sorted by score desc.
#
# Backing store: $FRECENCY_STORE (default ~/.cache/ksession-frecency.json)
# Lock file:     <store>.lock
# Log file:      $FRECENCY_LOG  (default ~/.cache/kitty-session-picker.log)
#
# Behavior:
#   - Atomic writes (write-to-tmp, rename).
#   - flock with ~200ms retry; on persistent contention, falls back to
#     read-only and logs a warning.
#   - Missing store -> treated as empty; created lazily on first bump.
#   - Malformed store -> treated as empty AND NOT overwritten (recovery
#     left to the human). All four operations still work (read returns 0;
#     bump/remove no-op with a warning).
#
# Schema (JSON):
#   { "schema": 1, "entries": { "<key>": { "count": N, "last_used_ms": MS } } }
#
# No top-level side effects: nothing is created until a function runs.

# ---- internal helpers --------------------------------------------------------

# Resolve paths lazily so callers can override $FRECENCY_STORE / $FRECENCY_LOG
# at any point before invoking a function.
_frecency_store_path() {
  printf '%s\n' "${FRECENCY_STORE:-$HOME/.cache/ksession-frecency.json}"
}

_frecency_log_path() {
  printf '%s\n' "${FRECENCY_LOG:-$HOME/.cache/kitty-session-picker.log}"
}

_frecency_score_jq() {
  # Resolve once: same dir as this file.
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/score.jq"
}

_frecency_now_ms() {
  # Millisecond wall time. `date +%s%3N` is the cheapest portable option
  # on GNU coreutils; falls back to ns-truncated if %3N isn't honored.
  local t
  t=$(date +%s%3N)
  case "$t" in
    *N) t=$(($(date +%s%N) / 1000000)) ;;
  esac
  printf '%s\n' "$t"
}

_frecency_log() {
  local msg="$1"
  local logf
  logf=$(_frecency_log_path)
  mkdir -p -- "$(dirname -- "$logf")" 2>/dev/null || true
  printf '%s frecency: %s\n' "$(date -Is)" "$msg" >>"$logf" 2>/dev/null || true
}

# Validate that the store JSON is well-formed AND has the expected shape.
# Returns 0 if usable, 1 if malformed.
_frecency_validate() {
  local store="$1"
  jq -e 'type == "object" and (.entries // empty | type == "object")' \
     "$store" >/dev/null 2>&1
}

# Read the store and emit its `entries` object (or `{}` if missing/malformed).
# Never modifies the store on disk.
_frecency_read_entries() {
  local store="$1"
  if [[ ! -e "$store" ]]; then
    printf '%s\n' '{}'
    return 0
  fi
  if _frecency_validate "$store"; then
    jq -c '.entries // {}' "$store"
  else
    _frecency_log "WARN malformed store at $store, treating as empty (NOT overwriting)"
    printf '%s\n' '{}'
    # signal malformed via a sentinel return so callers can refuse to write.
    return 2
  fi
}

# Write a new entries object to disk atomically.
# Args: <store_path> <entries_json>
# Caller must already hold the flock.
_frecency_write_entries() {
  local store="$1" entries="$2"
  local dir tmp
  dir=$(dirname -- "$store")
  mkdir -p -- "$dir"
  tmp="$store.tmp.$$"
  if ! printf '%s' "$entries" \
       | jq --argjson e_unused 0 \
            '{ schema: 1, entries: . }' >"$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    _frecency_log "ERROR failed to serialize entries to $tmp"
    return 1
  fi
  mv -- "$tmp" "$store"
}

# Run a closure with the flock held. Returns:
#   0 if the closure ran with the lock,
#   1 if we gave up and the closure was skipped (read-only fallback).
# Usage: _frecency_with_lock <store> <fn-name> [args...]
_frecency_with_lock() {
  local store="$1"; shift
  local fn="$1"; shift
  local dir lock
  dir=$(dirname -- "$store")
  mkdir -p -- "$dir"
  lock="$store.lock"
  # Open FD 9 to the lockfile, attempt non-blocking flock with retries.
  exec 9>"$lock" || {
    _frecency_log "WARN could not open lockfile $lock"
    return 1
  }
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if flock -n 9; then
      "$fn" "$@"
      local rc=$?
      flock -u 9
      exec 9>&-
      return $rc
    fi
    # ~20ms × 10 = ~200ms total before giving up.
    sleep 0.02
  done
  exec 9>&-
  _frecency_log "WARN flock contention on $lock, falling back to read-only"
  return 1
}

# ---- public API --------------------------------------------------------------

# frecency_bump <key>
frecency_bump() {
  local key="${1:-}"
  [[ -z "$key" ]] && return 2
  local store
  store=$(_frecency_store_path)

  _frecency_bump_locked() {
    local entries new now
    # If validate fails, _frecency_read_entries logs + returns 2 and we
    # refuse to overwrite the malformed file.
    entries=$(_frecency_read_entries "$store")
    local read_rc=$?
    if (( read_rc == 2 )); then
      return 0
    fi
    now=$(_frecency_now_ms)
    new=$(printf '%s' "$entries" | jq -c \
            --arg k "$key" --argjson now "$now" '
              . as $e
              | ($e[$k] // {count:0,last_used_ms:0}) as $cur
              | .[$k] = {
                  count: (($cur.count // 0) + 1),
                  last_used_ms: $now
                }
            ') || {
      _frecency_log "ERROR jq bump failed for key=$key"
      return 1
    }
    _frecency_write_entries "$store" "$new"
  }

  _frecency_with_lock "$store" _frecency_bump_locked
}

# frecency_score <key>  -> prints a float score (or "0").
frecency_score() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    printf '0\n'
    return 0
  fi
  local store entries now score
  store=$(_frecency_store_path)
  if [[ ! -e "$store" ]] || ! _frecency_validate "$store"; then
    printf '0\n'
    return 0
  fi
  entries=$(jq -c '.entries // {}' "$store" 2>/dev/null || printf '{}')
  now=$(_frecency_now_ms)
  score=$(printf '%s' "$entries" | jq -r \
            --arg k "$key" --argjson now "$now" '
              . as $e
              | ($e[$k] // null) as $v
              | if $v == null then 0
                else
                  ($v.count // 0) *
                  ( (($now - ($v.last_used_ms // 0))) as $d
                    | if   $d <       3600000 then 4.0
                      elif $d <      86400000 then 2.0
                      elif $d <     604800000 then 0.5
                      else                         0.25
                      end )
                end
            ' 2>/dev/null) || score=0
  printf '%s\n' "${score:-0}"
}

# frecency_remove <key>
frecency_remove() {
  local key="${1:-}"
  [[ -z "$key" ]] && return 2
  local store
  store=$(_frecency_store_path)

  _frecency_remove_locked() {
    local entries new
    entries=$(_frecency_read_entries "$store")
    local read_rc=$?
    if (( read_rc == 2 )); then
      return 0
    fi
    if [[ ! -e "$store" ]] && [[ "$entries" == "{}" ]]; then
      return 0
    fi
    new=$(printf '%s' "$entries" | jq -c --arg k "$key" 'del(.[$k])') || {
      _frecency_log "ERROR jq remove failed for key=$key"
      return 1
    }
    _frecency_write_entries "$store" "$new"
  }

  _frecency_with_lock "$store" _frecency_remove_locked
}

# frecency_prune_orphans <sessions_dir> [running_keys_nl]
#
# Best-effort cleanup: walk the store's entries and drop any key that meets
# ALL of the following:
#   - No `<sessions_dir>/<key>.conf` exists on disk.
#   - The key is NOT in $running_keys_nl (newline-separated list).
#   - The key does NOT start with "ssh-" (ephemeral, managed elsewhere).
#   - The key does NOT start with "__adhoc_" (synthetic; rot naturally).
#
# Always succeeds (returns 0) and logs a summary line. flock contention
# inside frecency_remove is already handled gracefully by the lib — a
# missed prune just means stale keys live one more picker invocation,
# never a broken picker. The caller (session-picker.sh) wraps this in
# `set +e` for defence-in-depth, but the function itself never exits
# non-zero by design.
#
# Args:
#   $1  sessions_dir  (e.g. ~/.config/kitty/sessions)
#   $2  running_keys  (optional; newline-separated, blank lines ignored)
frecency_prune_orphans() {
  local sessions_dir="${1:-}"
  local running_keys="${2:-}"

  if [[ -z "$sessions_dir" ]]; then
    _frecency_log "prune: sessions_dir not provided, skipping"
    return 0
  fi

  # Build an awk-friendly lookup of the running keys. Trim blanks.
  local -A is_running=()
  if [[ -n "$running_keys" ]]; then
    local rk
    while IFS= read -r rk; do
      [[ -z "$rk" ]] && continue
      is_running["$rk"]=1
    done <<<"$running_keys"
  fi

  local dropped=0 kept=0 key score
  # Iterate every entry currently in the store. frecency_dump emits
  # `<key>\t<score>` lines; we only need the key. Missing/malformed
  # store -> empty output -> the loop body never runs.
  while IFS=$'\t' read -r key score; do
    [[ -z "$key" ]] && continue
    # Apply the four predicates. Any single "keep" reason wins.
    if [[ "$key" == ssh-* ]]; then
      kept=$((kept + 1)); continue
    fi
    if [[ "$key" == __adhoc_* ]]; then
      kept=$((kept + 1)); continue
    fi
    if [[ -n "${is_running[$key]:-}" ]]; then
      kept=$((kept + 1)); continue
    fi
    if [[ -f "$sessions_dir/$key.conf" ]]; then
      kept=$((kept + 1)); continue
    fi
    # Orphan. Drop it. frecency_remove tolerates flock contention by
    # logging + falling back to read-only, so the worst case is a
    # one-cycle-later retry.
    if frecency_remove "$key" 2>/dev/null; then
      dropped=$((dropped + 1))
    else
      _frecency_log "prune: frecency_remove failed for key=$key (will retry next picker open)"
    fi
  done < <(frecency_dump 2>/dev/null)

  _frecency_log "pruned $dropped orphan frecency keys (kept $kept)"
  return 0
}

# frecency_dump  -> emit `<key>\t<score>` lines, sorted by score desc.
frecency_dump() {
  local store entries now jqf
  store=$(_frecency_store_path)
  jqf=$(_frecency_score_jq)
  if [[ ! -e "$store" ]] || ! _frecency_validate "$store"; then
    return 0
  fi
  entries=$(jq -c '.entries // {}' "$store" 2>/dev/null || printf '{}')
  now=$(_frecency_now_ms)
  printf '%s' "$entries" | jq -r -f "$jqf" --argjson now "$now"
}
