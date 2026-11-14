# kittens/which_key_spec.py
# Declarative chord spec — single source of truth for the ctrl+space leader.
# Pure data, stdlib-only, importable under plain python3 and kitty's python.
#
# Each entry is a dict:
#   leaf   -> {"key", "action", "desc", "section"}
#   prefix -> {"key", "group", "children": [ ...entries... ], "section"}
#
# "section" is a DISPLAY-ONLY label: the popup groups rows under a header per
# section (chord_trie.sections -> which_key_layout.layout_sections). It never
# changes a keystroke -- every chord here is still ctrl+space><key>. Rows with
# the same label are shown together under one header, in declared order.
#
# Declared order here IS the popup display order. The chord-trie preserves this
# order verbatim (groups-last sorting is the layout module's job, issue 06).
#
# ISSUE 08 — FULL CUTOVER. This is the complete migration of every
# ctrl+space>... chord that used to live natively in kitty.conf. The spec is
# kept deliberately FLAT (every entry a top-level leaf, no synthetic groups):
# the native chords were all flat (ctrl+space>h, never ctrl+space>w>h), and
# issue 08's acceptance criterion is "matching today's behavior exactly".
# Introducing a `w`/`t` group would change the physical keystrokes (turning
# ctrl+space>h into ctrl+space>w>h) and violate that, so grouping is left as a
# deliberate later relabel. The flat multi-column popup is fine — the layout
# module (issue 06) packs many flat entries into columns.
#
# Order mirrors kitty.conf's old leader section so the popup reads like the
# KEYBINDS table did. Action strings are stored EXACTLY as `kitty @ action`
# will dispatch them (handle_result does answer.split() -> call_remote_control
# (window, ("action", *parts))). Two consequences encoded here:
#   * The scrollback chord ('slash') stores the EXPANDED kitten invocation, NOT
#     the `kitty_scrollback_nvim` action_alias — `kitty @ action` does not
#     expand action_alias, so the alias must be pre-resolved here.
#   * No action path contains spaces, so the naive answer.split() is safe.

# Pre-expanded form of the `kitty_scrollback_nvim` action_alias (kitty.conf):
#   action_alias kitty_scrollback_nvim kitten <path>
# `kitty @ action` will not expand the alias, so we store the kitten call.
_SCROLLBACK_NVIM = (
    "kitten "
    "/home/andrew/.local/share/nvim/lazy/kitty-scrollback.nvim/"
    "python/kitty_scrollback_nvim.py"
)

_WINDOWS = "Windows"
_NAVIGATE = "Navigate"
_TABS = "Tabs"
_GOTO_TAB = "Go to tab"
_SESSIONS = "Sessions"
_TOOLS = "Tools"

SPEC = [
    # -- Windows: splits / close / maximize / pick / resize -------------------
    {"key": "bar",   "action": "launch --location=vsplit --cwd=current",
     "desc": "split vertical", "section": _WINDOWS},
    {"key": "minus", "action": "launch --location=hsplit --cwd=current",
     "desc": "split horizontal", "section": _WINDOWS},
    {"key": "c", "action": "close_window", "desc": "close window",
     "section": _WINDOWS},
    # maximize / unmaximize (stack layout toggle)
    {"key": "m", "action": "toggle_layout stack", "desc": "toggle maximize",
     "section": _WINDOWS},
    # pick a pane by overlay label (mirrors alt+w)
    {"key": "w", "action": "focus_visible_window", "desc": "pick window",
     "section": _WINDOWS},
    # interactive resize mode (arrows nudge, Enter commits, Esc cancels)
    {"key": "r", "action": "start_resizing_window", "desc": "resize mode",
     "section": _WINDOWS},

    # -- Navigate: focus (hjkl, mirrors alt+hjkl on the keyd Tab layer) and
    #    swap (shift+hjkl, mirrors bare ctrl+shift+hjkl) ----------------------
    {"key": "h", "action": "neighboring_window left", "desc": "focus left",
     "section": _NAVIGATE},
    {"key": "j", "action": "neighboring_window down", "desc": "focus down",
     "section": _NAVIGATE},
    {"key": "k", "action": "neighboring_window up",   "desc": "focus up",
     "section": _NAVIGATE},
    {"key": "l", "action": "neighboring_window right", "desc": "focus right",
     "section": _NAVIGATE},
    {"key": "shift+h", "action": "move_window left",  "desc": "swap left",
     "section": _NAVIGATE},
    {"key": "shift+j", "action": "move_window down",  "desc": "swap down",
     "section": _NAVIGATE},
    {"key": "shift+k", "action": "move_window up",    "desc": "swap up",
     "section": _NAVIGATE},
    {"key": "shift+l", "action": "move_window right", "desc": "swap right",
     "section": _NAVIGATE},

    # -- Tabs ----------------------------------------------------------------
    {"key": "t", "action": "new_tab_with_cwd", "desc": "new tab",
     "section": _TABS},
    {"key": "x", "action": "close_tab", "desc": "close tab",
     "section": _TABS},
    {"key": "n", "action": "next_tab", "desc": "next tab",
     "section": _TABS},
    {"key": "p", "action": "previous_tab", "desc": "previous tab",
     "section": _TABS},
    {"key": "shift+n", "action": "move_tab_forward", "desc": "move tab forward",
     "section": _TABS},
    {"key": "shift+p", "action": "move_tab_backward",
     "desc": "move tab backward", "section": _TABS},
    {"key": "shift+r", "action": "set_tab_title", "desc": "rename tab",
     "section": _TABS},

    # -- Go to tab N (mirrors alt+1..9 / alt+0 on the keyd Tab layer).
    #    Tab titles are prefixed "N:" so the target is visible in the bar.
    #    0 = last-visited tab (goto_tab -1), toggling between two tabs. The
    #    popup lists only the tabs that exist (which_key_nav.filter_tab_entries).
    {"key": "1", "action": "goto_tab 1", "desc": "tab 1", "section": _GOTO_TAB},
    {"key": "2", "action": "goto_tab 2", "desc": "tab 2", "section": _GOTO_TAB},
    {"key": "3", "action": "goto_tab 3", "desc": "tab 3", "section": _GOTO_TAB},
    {"key": "4", "action": "goto_tab 4", "desc": "tab 4", "section": _GOTO_TAB},
    {"key": "5", "action": "goto_tab 5", "desc": "tab 5", "section": _GOTO_TAB},
    {"key": "6", "action": "goto_tab 6", "desc": "tab 6", "section": _GOTO_TAB},
    {"key": "7", "action": "goto_tab 7", "desc": "tab 7", "section": _GOTO_TAB},
    {"key": "8", "action": "goto_tab 8", "desc": "tab 8", "section": _GOTO_TAB},
    {"key": "9", "action": "goto_tab 9", "desc": "tab 9", "section": _GOTO_TAB},
    {"key": "0", "action": "goto_tab -1", "desc": "last tab",
     "section": _GOTO_TAB},

    # -- Sessions / pickers (overlay launches of helper scripts) -------------
    {"key": "s", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/session-picker.sh",
     "desc": "session picker", "section": _SESSIONS},
    {"key": "shift+s", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/ksession-save-prompt.sh",
     "desc": "save session", "section": _SESSIONS},
    {"key": "f", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/tab-picker.sh",
     "desc": "tab/split picker", "section": _SESSIONS},
    {"key": "v", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/scrollback-viewer.sh",
     "desc": "view saved scrollback", "section": _SESSIONS},
    {"key": "o", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/project-loader.sh",
     "desc": "load project session", "section": _SESSIONS},

    # -- Tools ---------------------------------------------------------------
    # scrollback in nvim (expanded alias -- see _SCROLLBACK_NVIM)
    {"key": "slash", "action": _SCROLLBACK_NVIM, "desc": "scrollback in nvim",
     "section": _TOOLS},
    # command palette (leader+?)
    {"key": "shift+slash", "action": "command_palette",
     "desc": "command palette", "section": _TOOLS},
]
