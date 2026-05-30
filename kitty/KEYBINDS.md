# Kitty Keybind Reference

Generated from `~/.config/kitty/kitty.conf` and kitty's built-in defaults
(extracted via `kitty +runpy` against the installed version). `kitty_mod` =
`ctrl+shift`.

Reload after editing config: `ctrl+shift+f5` (or `kitty @ load-config`).

---

## Conventions used below

- **Leader** = `ctrl+space` chord prefix. Tap and release `ctrl+space`, then
  tap the next key. No need to hold.
- "Shadowed" = a default kitty binding that this config replaces with
  something else. The default action is no longer reachable on that key.

---

## Custom bindings

### Leader chord (`ctrl+space > …`)

| Chord | Action |
|---|---|
| `ctrl+space > \|` (`bar`) | Vertical split |
| `ctrl+space > -` (`minus`) | Horizontal split |
| `ctrl+space > c` | Close window (split) |
| `ctrl+space > h` / `j` / `k` / `l` | Focus neighbor left/down/up/right |
| `ctrl+space > H` / `J` / `K` / `L` | Swap window left/down/up/right |
| `ctrl+space > m` | Toggle maximize (stack layout) |
| `ctrl+space > r` | Interactive resize mode (arrows nudge, Enter commits, Esc cancels) |
| `ctrl+space > t` | New tab in current cwd |
| `ctrl+space > x` | Close tab |
| `ctrl+space > n` | Next tab |
| `ctrl+space > p` | Previous tab |
| `ctrl+space > N` | Move tab forward |
| `ctrl+space > P` | Move tab backward |
| `ctrl+space > R` | Rename current tab |
| `ctrl+space > s` | Fuzzy session picker (fzf across all OS windows) |
| `ctrl+space > f` | Fuzzy tab/split picker (fzf inside current OS window) |
| `ctrl+space > /` | Scrollback in nvim (kitty-scrollback.nvim) |
| `ctrl+space > ?` (`shift+/`) | Command palette |

### Direct bindings — window navigation & splits

| Key | Action |
|---|---|
| `ctrl+h` / `j` / `k` / `l` | Focus neighbor left/down/up/right |
| `ctrl+shift+h` / `j` / `k` / `l` | Swap window left/down/up/right |
| `ctrl+shift+\` (i.e. `ctrl+\|`) | Vertical split |
| `ctrl+shift+-` | Horizontal split |
| `ctrl+shift+w` | Close window |
| `ctrl+shift+r` | Rotate split orientation |
| `ctrl+shift+z` | Toggle stack (zoom/unzoom) |

### Direct bindings — resize (held-modifier)

| Key | Action |
|---|---|
| `ctrl+alt+h` / `l` | Narrower / wider |
| `ctrl+alt+k` / `j` | Taller / shorter |
| `ctrl+alt+0` | Reset size |

### Direct bindings — tabs

| Key | Action |
|---|---|
| `ctrl+shift+t` | New tab in current cwd |
| `ctrl+shift+q` | Close tab |
| `ctrl+tab` | Next tab |
| `ctrl+shift+tab` | Previous tab |

### Direct bindings — quality of life

| Key | Action |
|---|---|
| `ctrl+shift+x` | Clear terminal (reset active) |

### Scrollback (kitty-scrollback.nvim)

| Key | Action |
|---|---|
| `ctrl+shift+f1` | Browse full scrollback in nvim |
| `ctrl+shift+f2` | Browse last command's output in nvim |
| `ctrl+shift+right-click` on a prompt | Open that command's output in nvim |

---

## Helper scripts (invoked by leader bindings)

Located in `~/.config/kitty/scripts/`. Both require `jq` and `fzf` on PATH
and use kitty's remote control socket.

- **`session-picker.sh`** — bound to `ctrl+space > s`. Lists every kitty
  OS window with its active tab title, tab count, and cwd. fzf preview
  shows the active window's screen. Selection runs
  `kitty @ focus-window` (which also raises the containing tab and OS
  window).
- **`tab-picker.sh`** — bound to `ctrl+space > f`. Lists every tab + split
  inside the **current** OS window, formatted as `[tab.win] tab_title ›
  window_title · cwd`. Same fzf preview pattern. Detects current OS window
  via `KITTY_WINDOW_ID`.

---

## Kitty defaults (still active)

These are kitty's built-in bindings that this config does **not** override,
so they still work.

### Clipboard

| Key | Action |
|---|---|
| `ctrl+shift+c` | Copy to clipboard |
| `ctrl+shift+v` | Paste from clipboard |
| `ctrl+shift+s` | Paste from selection |
| `shift+insert` | Paste from selection |
| `ctrl+shift+o` | Pass selection to program |

### Scrolling (in the kitty pager / terminal)

| Key | Action |
|---|---|
| `ctrl+shift+up` | Scroll one line up |
| `ctrl+shift+down` | Scroll one line down |
| `ctrl+shift+page_up` | Scroll one page up |
| `ctrl+shift+page_down` | Scroll one page down |
| `ctrl+shift+home` | Scroll to top |
| `ctrl+shift+end` | Scroll to bottom |
| `ctrl+shift+g` | Show last command output |
| `ctrl+shift+/` | Search scrollback |

### Window / OS-window

| Key | Action |
|---|---|
| `ctrl+shift+enter` | New kitty window in current tab |
| `ctrl+shift+n` | New OS window |
| `ctrl+shift+]` / `[` | Next / previous window |
| `ctrl+shift+f` / `b` | Move window forward / backward |
| `` ctrl+shift+` `` | Move window to top |
| `ctrl+shift+1` … `9` / `0` | Focus 1st … 9th / 10th window |
| `ctrl+shift+F7` | Focus visible window (picker) |
| `ctrl+shift+F8` | Swap with window (picker) |

### Tabs

| Key | Action |
|---|---|
| `ctrl+shift+right` / `left` | Next / previous tab |
| `ctrl+shift+.` / `,` | Move tab forward / backward |
| `ctrl+shift+alt+t` | Rename current tab |

### Font size

| Key | Action |
|---|---|
| `ctrl+shift+=` / `+` / `kp_add` | Font size +2 |
| `ctrl+shift+kp_subtract` | Font size −2 (see shadow note below) |
| `ctrl+shift+backspace` | Reset font size |

### Hints / picker

| Key | Action |
|---|---|
| `ctrl+shift+e` | Open URL with hints |
| `ctrl+shift+p` | Hints menu — path/line/word/hash/linenum/hyperlink, choose-files, choose-dir |

### Miscellaneous

| Key | Action |
|---|---|
| `ctrl+shift+F1` | Show kitty docs (overview) |
| `ctrl+shift+F2` | Edit config file |
| `ctrl+shift+F3` | Command palette |
| `ctrl+shift+F5` | Reload config file |
| `ctrl+shift+F6` | Show debug config |
| `ctrl+shift+F10` | Toggle maximized |
| `ctrl+shift+F11` | Toggle fullscreen |
| `ctrl+shift+u` | Unicode input |
| `ctrl+shift+escape` | Open kitty shell in new window |
| `ctrl+shift+a` | Background opacity submenu (`+0.1` / `−0.1` / `1` / default) |
| `ctrl+shift+delete` | Clear terminal (full reset) |

---

## Defaults shadowed by this config

| Key | What it used to do | What it does now |
|---|---|---|
| `ctrl+h` | (no default) | Focus neighbor left |
| `ctrl+l` | (clear screen — terminal-level) | Focus neighbor right; use `ctrl+shift+x` to clear |
| `ctrl+shift+h` | Show scrollback in pager (`less`) | Swap window left |
| `ctrl+shift+j` | Scroll line down | Swap window down |
| `ctrl+shift+k` | Scroll line up | Swap window up |
| `ctrl+shift+l` | Next layout | Swap window right |
| `ctrl+shift+r` | Start interactive resize | Rotate split orientation (use `ctrl+space > r` for resize) |
| `ctrl+shift+z` | Scroll to previous prompt | Toggle stack layout |
| `ctrl+shift+x` | Scroll to next prompt | Clear terminal |
| `ctrl+shift+\` | (no default) | Vertical split |
| `ctrl+shift+-` (`minus`) | Font size −2 | Horizontal split (use `ctrl+shift+kp_subtract` to decrement font) |
| `ctrl+shift+t` | New tab | New tab in current cwd |
| `ctrl+shift+q` | Close tab (same) | Close tab |

---

## Mental model

- **Single-tap `ctrl+hjkl`** = move focus between splits (most common, no leader).
- **`ctrl+shift+hjkl`** = swap splits.
- **`ctrl+alt+hjkl`** = resize splits (hold to repeat).
- **`ctrl+space` leader** = everything tab-related, command palette, pickers,
  and a mirror of split/window actions for when single-tap chords feel
  awkward.
- **`ctrl+space > ?`** opens the command palette — searchable list of every
  action kitty knows, even those without a keybinding.
