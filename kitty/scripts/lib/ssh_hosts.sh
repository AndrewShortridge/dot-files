#!/usr/bin/env bash
# ssh_hosts: enumerate concrete Host aliases from an ssh-config file.
#
# Usage: source this file, then call:
#   ssh_hosts [config_path]
#
# Behavior:
#   - Defaults config_path to ~/.ssh/config.
#   - Recursively expands `Include` directives (with glob support).
#     Relative includes resolve against the *including file's* directory
#     first (matches ssh's behavior for non-default config files), then
#     fall back to ~/.ssh/ (per ssh_config(5) for the default config).
#   - Tokenizes `Host` lines (multiple aliases per line: `Host a b c`).
#   - Drops tokens containing `*`, `?`, or starting with `!`.
#   - Ignores `Match` blocks entirely.
#   - Outputs a deduped, sorted host list, one alias per line.
#   - Missing config file → empty output, exit 0.

# Recursive worker that emits raw (unsorted, undeduped) host tokens.
# Each invocation parses ONE file. Globs/missing files are handled by
# the caller before recursing.
_ssh_hosts_emit_file() {
  local config_path="$1"
  [[ -f "$config_path" ]] || return 0

  # Directory of the file we're parsing — used to resolve relative
  # `Include` paths (matches what ssh does when invoked with `-F`).
  local config_dir
  config_dir="$(dirname -- "$config_path")"

  # Note: a `Match` block in ssh_config terminates at the next `Host`
  # or `Match` line. We don't need explicit block-state tracking because
  # we only emit on `Host` lines (which themselves end any Match block)
  # and recurse on `Include` lines (textual expansion, same as ssh).
  # Everything else is silently consumed.
  local line keyword rest tok inc_path glob_path candidate

  # We need glob expansion ONLY at the `Include` step. Everywhere else
  # we tokenize via `set --` against ssh-config text that may contain
  # `*` or `?` (a `Host *` catch-all, for example), which would otherwise
  # expand against the filesystem. Disable globbing for the duration of
  # this function and re-enable it locally inside the `include` branch.
  local _had_noglob=1
  case "$-" in *f*) _had_noglob=1 ;; *) _had_noglob=0 ;; esac
  set -f

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip trailing comment (`#` after content; ssh's own parser only
    # treats `#` at the start of a line as a comment, but the common
    # convention in real configs is trailing comments — handle both).
    line="${line%%#*}"

    # Trim leading/trailing whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    # First token = keyword (case-insensitive per ssh_config(5)).
    keyword="${line%%[[:space:]]*}"
    if [[ "$line" == "$keyword" ]]; then
      rest=""
    else
      rest="${line#"$keyword"}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
    fi

    # Normalize keyword to lowercase for matching. Also tolerate
    # `Host=foo` style (ssh allows `=` as separator).
    if [[ "$keyword" == *=* ]]; then
      rest="${keyword#*=}${rest:+ }$rest"
      keyword="${keyword%%=*}"
    fi
    local kw_lc
    kw_lc="${keyword,,}"

    case "$kw_lc" in
      host)
        # Tokenize the rest on whitespace. Word-splitting is intentional.
        # shellcheck disable=SC2086
        set -- $rest
        for tok in "$@"; do
          # Filter wildcards & negation.
          [[ "$tok" == *"*"* ]] && continue
          [[ "$tok" == *"?"* ]] && continue
          [[ "$tok" == "!"* ]] && continue
          [[ -z "$tok" ]] && continue
          printf '%s\n' "$tok"
        done
        ;;
      match)
        # Acknowledged but ignored — block ends at the next Host/Match.
        ;;
      include)
        # Includes are valid in any block. We honor them regardless of
        # whether we're inside a Match (mirrors ssh's own behavior of
        # textually expanding includes).
        # shellcheck disable=SC2086
        set -- $rest
        for inc_path in "$@"; do
          # Strip surrounding quotes if any.
          inc_path="${inc_path%\"}"
          inc_path="${inc_path#\"}"

          # Build the candidate path. For relative paths, try the
          # including file's directory first (works for both ~/.ssh/
          # configs and -F-style custom configs); if no glob matches
          # there, fall back to ~/.ssh/-relative.
          case "$inc_path" in
            "~/"*) candidate="$HOME/${inc_path#~/}" ;;
            /*)    candidate="$inc_path" ;;
            *)     candidate="$config_dir/$inc_path" ;;
          esac

          # Enable globbing locally so the unquoted expansion below
          # actually globs; nullglob makes missing/unmatched globs
          # silently produce nothing.
          set +f
          local _had_nullglob=0
          shopt -q nullglob && _had_nullglob=1
          shopt -s nullglob

          local matched=0
          for glob_path in $candidate; do
            matched=1
            _ssh_hosts_emit_file "$glob_path"
          done

          # Fallback to ~/.ssh/ for relative paths if nothing matched.
          if (( matched == 0 )); then
            case "$inc_path" in
              "~/"*|/*) : ;;
              *)
                for glob_path in "$HOME/.ssh/$inc_path"; do
                  _ssh_hosts_emit_file "$glob_path"
                done
                ;;
            esac
          fi

          [[ "$_had_nullglob" -eq 0 ]] && shopt -u nullglob
          set -f
        done
        ;;
      *)
        # Any other keyword inside a Match block is just consumed.
        # Outside, we don't care about it either.
        :
        ;;
    esac
  done < "$config_path"

  # Restore globbing if we changed it.
  [[ "$_had_noglob" -eq 0 ]] && set +f
}

ssh_hosts() {
  local config_path="${1:-$HOME/.ssh/config}"
  [[ -f "$config_path" ]] || return 0
  _ssh_hosts_emit_file "$config_path" | LC_ALL=C sort -u
}
