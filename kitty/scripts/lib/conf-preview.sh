#!/usr/bin/env bash
# conf-preview - emit a colorized rendering of a kitty session .conf file
# to stdout. Used as the fzf preview command for session/.conf rows in
# session-picker.sh, project-loader.sh, and ksession-save-prompt.sh.
#
# Usage: conf-preview.sh <path-to-.conf>
#
# Colors (ANSI-16, theme-safe):
#   # comments           -> dim
#   directive keywords   -> bold green (new_tab, launch, cd, layout, focus,
#                                       focus_os_window, new_os_window, …)
#   --flag arguments     -> yellow
#   numbers              -> magenta
#   quoted strings       -> cyan
#
# Missing/unreadable files emit a dim "<no preview>" line, never error.

set -eu

path="${1:-}"
if [[ -z "$path" || ! -r "$path" ]]; then
  printf '\033[2m<no preview>\033[0m\n'
  exit 0
fi

awk '
  BEGIN {
    R   = "\033[0m"
    B   = "\033[1m"
    D   = "\033[2m"
    GR  = "\033[32m"   # green
    YL  = "\033[33m"   # yellow
    BL  = "\033[34m"   # blue
    MG  = "\033[35m"   # magenta
    CY  = "\033[36m"   # cyan

    # Recognized kitty session directives.
    n = split("new_tab launch cd layout focus focus_os_window new_os_window os_window_class os_window_title os_window_size enabled_layouts watcher tab_title startup_session", a, " ")
    for (i = 1; i <= n; i++) kw[a[i]] = 1
  }
  function paint_token(tok) {
    if (tok ~ /^"[^"]*"$/ || tok ~ /^'\''[^'\'']*'\''$/) return CY tok R
    if (tok ~ /^--[A-Za-z0-9-]+(=.*)?$/) return YL tok R
    if (tok ~ /^-?[0-9]+(\.[0-9]+)?$/)    return MG tok R
    return tok
  }
  # Comment lines (entire line dim).
  /^[[:space:]]*#/ { print D $0 R; next }
  # Blank lines pass through.
  /^[[:space:]]*$/ { print; next }
  {
    # Preserve leading whitespace.
    match($0, /^[[:space:]]*/)
    indent = substr($0, RSTART, RLENGTH)
    rest = substr($0, RLENGTH + 1)

    # Tokenize on runs of whitespace.
    nf = split(rest, t, /[ \t]+/)
    out = indent
    for (i = 1; i <= nf; i++) {
      if (t[i] == "") continue
      if (i == 1 && (t[i] in kw)) {
        out = out B GR t[i] R
      } else {
        out = out paint_token(t[i])
      }
      if (i < nf) out = out " "
    }
    print out
  }
' "$path"
