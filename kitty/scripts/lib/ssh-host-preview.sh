#!/usr/bin/env bash
# ssh-host-preview - emit a colorized rendering of one Host's block from
# ~/.ssh/config (or any given ssh-config path). Used as the fzf preview
# command for session-picker.sh's ssh rows.
#
# Usage: ssh-host-preview.sh <ssh-config-path> <host-alias>
#
# Colors (ANSI-16, theme-safe):
#   "Host <name>"        -> bold green keyword, bold name
#   directive keywords   -> bold cyan (HostName, User, Port, IdentityFile,
#                                      ProxyJump, ProxyCommand, etc.)
#   numbers              -> magenta (e.g. Port 22)
#   quoted strings       -> yellow
#   trailing comments    -> dim
#
# Missing/unreadable config emits a dim "<no preview>" line.

set -eu

config="${1:-}"
host="${2:-}"

if [[ -z "$config" || -z "$host" || ! -r "$config" ]]; then
  printf '\033[2m<no preview>\033[0m\n'
  exit 0
fi

awk -v h="$host" '
  BEGIN {
    R   = "\033[0m"
    B   = "\033[1m"
    D   = "\033[2m"
    GR  = "\033[32m"
    YL  = "\033[33m"
    MG  = "\033[35m"
    CY  = "\033[36m"
    p = 0
  }
  function paint_value(v,    out) {
    if (v ~ /^"[^"]*"$/) return YL v R
    if (v ~ /^-?[0-9]+$/) return MG v R
    return v
  }
  /^[[:space:]]*#/ {
    if (p) print D $0 R
    next
  }
  {
    line = $0
    # Strip a trailing # comment for keyword detection but remember it.
    trailing = ""
    if (match(line, /[ \t]+#.*$/)) {
      trailing = substr(line, RSTART, RLENGTH)
      line = substr(line, 1, RSTART - 1)
    }
    # Normalize for keyword detection.
    norm = line
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", norm)
    if (norm == "") {
      if (p) print
      next
    }
    nf = split(norm, t, /[ \t]+/)
    kw = tolower(t[1])
    if (kw == "host") {
      # Begin/end block based on whether `h` is in this Host line.
      p = 0
      for (i = 2; i <= nf; i++) if (t[i] == h) p = 1
      if (p) {
        # Bold green "Host", bold names.
        out = B GR t[1] R
        for (i = 2; i <= nf; i++) out = out " " B t[i] R
        if (trailing != "") out = out D trailing R
        print out
      }
      next
    }
    if (kw == "match") { p = 0; next }
    if (!p) next

    # Inside the matched block: keyword cyan-bold, values painted.
    # Preserve original leading whitespace from the source line.
    match($0, /^[[:space:]]*/)
    indent = substr($0, RSTART, RLENGTH)
    out = indent B CY t[1] R
    for (i = 2; i <= nf; i++) out = out " " paint_value(t[i])
    if (trailing != "") out = out D trailing R
    print out
  }
' "$config"
