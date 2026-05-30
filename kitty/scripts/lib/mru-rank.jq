# MRU ranker for kitty OS windows across multiple sockets.
#
# Input: a JSON array (use `jq -s` when streaming). Each element has shape
#   { "socket": "<sock-path>", "ls": [ <kitty @ ls OS-window objects> ] }
#
# Output: TSV rows, one per (non-overlay) OS window, sorted by
# last_focused_at descending. Ties break by (socket asc, os_window_id asc)
# for stability. Each row:
#   socket \t os_window_id \t window_id \t last_focused_at
#
# `last_focused_at` is a float seconds-since-boot value emitted by kitty.
# Null values (window never focused) sort to the bottom.
#
# Filtering rules:
# - Skip OS windows whose wm_class contains "kitty-overlay".
# - Per OS window, pick the active tab (or first tab as fallback).
# - From that tab, drop overlay children (overlay_parent set & nonzero)
#   and is_self windows. Pick the active remaining window, or the first
#   non-overlay remaining window as fallback.
# - If no non-overlay window remains in the active tab, drop the OS window.

def is_overlay_window:
  (.is_self == true)
  or ((.overlay_parent // 0) != 0)
;

def pick_window(tab):
  ( [ tab.windows[] | select(is_overlay_window | not) ] ) as $candidates
  | if ($candidates | length) == 0 then null
    else
      ( [ $candidates[] | select(.is_active == true) ][0] )
      // $candidates[0]
    end
;

def pick_tab(osw):
  ( [ osw.tabs[] | select(.is_active == true) ][0] )
  // osw.tabs[0]
;

# Sort key for last_focused_at where null means "never" (sorts below all
# real timestamps when sorted descending).
def lfa_key(v): if v == null then -1e308 else v end;

[ .[]
  | . as $entry
  | $entry.ls[]
  | . as $osw
  | select((($osw.wm_class // "") | test("kitty-overlay")) | not)
  | pick_tab($osw) as $tab
  | select($tab != null)
  | pick_window($tab) as $win
  | select($win != null)
  | {
      socket: $entry.socket,
      osw_id: $osw.id,
      win_id: $win.id,
      lfa: $win.last_focused_at
    }
]
| sort_by([ -(lfa_key(.lfa)), .socket, .osw_id ])
| .[]
| [ .socket, (.osw_id | tostring), (.win_id | tostring),
    (if .lfa == null then "null" else (.lfa | tostring) end) ]
| @tsv
