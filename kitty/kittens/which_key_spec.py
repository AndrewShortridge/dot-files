# kittens/which_key_spec.py
# Declarative chord spec — single source of truth for the ctrl+space leader.
# Pure data, stdlib-only, importable under plain python3 and kitty's python.
#
# Each entry is a dict:
#   leaf   -> {"key", "action", "desc"}
#   prefix -> {"key", "group", "children": [ ...entries... ]}
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

SPEC = [
    # -- splits / close (| vertical, - horizontal, c close) ------------------
    {"key": "bar",   "action": "launch --location=vsplit --cwd=current",
     "desc": "split vertical"},
    {"key": "minus", "action": "launch --location=hsplit --cwd=current",
     "desc": "split horizontal"},
    {"key": "c",     "action": "close_window", "desc": "close window"},

    # -- window navigation (mirrors alt+hjkl on the keyd Tab layer) ----------
    {"key": "h", "action": "neighboring_window left", "desc": "focus left"},
    {"key": "j", "action": "neighboring_window down", "desc": "focus down"},
    {"key": "k", "action": "neighboring_window up",   "desc": "focus up"},
    {"key": "l", "action": "neighboring_window right", "desc": "focus right"},

    # -- window swaps (shift+hjkl, mirrors bare ctrl+shift+hjkl) -------------
    {"key": "shift+h", "action": "move_window left",  "desc": "swap left"},
    {"key": "shift+j", "action": "move_window down",  "desc": "swap down"},
    {"key": "shift+k", "action": "move_window up",    "desc": "swap up"},
    {"key": "shift+l", "action": "move_window right", "desc": "swap right"},

    # -- maximize / unmaximize (stack layout toggle) -------------------------
    {"key": "m", "action": "toggle_layout stack", "desc": "toggle maximize"},

    # -- pick a pane by overlay label (mirrors alt+w) ------------------------
    {"key": "w", "action": "focus_visible_window", "desc": "pick window"},

    # -- interactive resize mode (arrows nudge, Enter commits, Esc cancels) --
    {"key": "r", "action": "start_resizing_window", "desc": "resize mode"},

    # -- tabs ----------------------------------------------------------------
    {"key": "t", "action": "new_tab_with_cwd",   "desc": "new tab"},
    {"key": "x", "action": "close_tab",          "desc": "close tab"},
    {"key": "n", "action": "next_tab",           "desc": "next tab"},
    {"key": "p", "action": "previous_tab",       "desc": "previous tab"},
    {"key": "shift+n", "action": "move_tab_forward",  "desc": "move tab forward"},
    {"key": "shift+p", "action": "move_tab_backward", "desc": "move tab backward"},
    {"key": "shift+r", "action": "set_tab_title",     "desc": "rename tab"},

    # -- scrollback in nvim (expanded alias — see _SCROLLBACK_NVIM) ----------
    {"key": "slash", "action": _SCROLLBACK_NVIM, "desc": "scrollback in nvim"},

    # -- command palette (leader+?) ------------------------------------------
    {"key": "shift+slash", "action": "command_palette", "desc": "command palette"},

    # -- pickers / sessions (overlay launches of helper scripts) -------------
    {"key": "s", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/session-picker.sh",
     "desc": "session picker"},
    {"key": "shift+s", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/ksession-save-prompt.sh",
     "desc": "save session"},
    {"key": "f", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/tab-picker.sh",
     "desc": "tab/split picker"},
    {"key": "v", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/scrollback-viewer.sh",
     "desc": "view saved scrollback"},
    {"key": "o", "action": "launch --type=overlay --cwd=current "
                           "/home/andrew/.config/kitty/scripts/project-loader.sh",
     "desc": "load project session"},
]
