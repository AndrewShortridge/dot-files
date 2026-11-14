# kittens/which_key_nav.py
# Pure navigation + layout core for the which-key kitten (issue 03).
#
# This module holds the STICKY half of the popup FSM as a pure function over an
# explicit path-stack (`nav_step`), plus the minimal single-column layout
# (`layout_block`) and the key<->display helpers. It is the testable core of
# the sticky-popup slice: the driver in which_key.py imports it, and the unit
# tests import it directly.
#
# PURE: no kitty imports, no terminal, no I/O. Stdlib only, so it imports under
# plain python3 and the unit tests run with zero third-party deps.
#
# Slice boundaries (per PRD):
#   - The WAIT_FIRST / 100ms timing half of the FSM is issue 04; this module is
#     only the STICKY descent reducer (shown immediately).
#   - The richer wcwidth / multi-column grid layout is issue 06; `layout_block`
#     here is a deliberately minimal single-column block.

# Same dual import idiom as which_key.py: top-level when path-launched as a
# custom kitten, package-qualified under the test sys.path.
try:
    from chord_trie import navigate, Leaf, Prefix, NO_MATCH
except ImportError:  # imported as kittens.* under the test sys.path
    from kittens.chord_trie import navigate, Leaf, Prefix, NO_MATCH


# --- normalized control-key tokens -----------------------------------------
# The driver passes these in directly from on_key for Esc / Backspace, distinct
# from any printable trie key name. They are intentionally not valid trie keys.
KEY_ESC = "<esc>"
KEY_BACKSPACE = "<backspace>"


# --- STICKY decision result tags -------------------------------------------
# Distinct from chord_trie's Prefix/Leaf so the driver branches on INTENT
# (descend / dispatch / pop / cancel / stay), not on raw trie shape.

class Descend:
    """nav_step result: key led into a sub-prefix; driver pushes + redraws."""
    __slots__ = ("node",)

    def __init__(self, node):
        self.node = node


class Dispatch:
    """nav_step result: key chose a leaf; driver dispatches the action+exits."""
    __slots__ = ("action",)

    def __init__(self, action):
        self.action = action


class Pop:
    """nav_step result: Backspace above root; driver pops to `node` + redraws."""
    __slots__ = ("node",)

    def __init__(self, node):
        self.node = node


class _Cancel:
    """Singleton: Esc, or Backspace at root -> close popup with no action."""
    __slots__ = ()

    def __repr__(self):
        return "CANCEL"


class _Stay:
    """Singleton: unbound key -> ignore, popup stays open (no redraw needed)."""
    __slots__ = ()

    def __repr__(self):
        return "STAY"


CANCEL = _Cancel()
STAY = _Stay()


# --- nav_step (the testable STICKY reducer) --------------------------------

def nav_step(stack, key):
    """Pure STICKY-state transition.

    `stack` is a non-empty list of trie Nodes: stack[0] is the root and
    stack[-1] is the current node. `key` is a normalized token — a trie key
    name (already through char_to_key), KEY_ESC, or KEY_BACKSPACE.

    Returns one of: Descend(child) / Dispatch(action) / Pop(parent) / CANCEL /
    STAY. PURE — it does NOT mutate `stack`; the driver applies the push/pop
    based on the result.
    """
    if key == KEY_ESC:
        return CANCEL
    if key == KEY_BACKSPACE:
        if len(stack) == 1:
            return CANCEL  # Backspace at root cancels
        return Pop(stack[-2])  # pop one level back to the parent

    result = navigate(stack[-1], key)
    if isinstance(result, Prefix):
        return Descend(result.node)
    if isinstance(result, Leaf):
        return Dispatch(result.action)
    # NO_MATCH: unbound key — popup stays open, nothing happens.
    return STAY


# --- spawn-window buffered-key decision (issue 07) -------------------------
# When the overlay launches, a key the user typed before the Loop grabbed the
# tty may already sit in the kitten's input buffer. The driver drains it on
# startup and asks this PURE function what to do with each buffered token,
# BEFORE the 100ms deadline is armed. The rule: a buffered key is honored only
# if it maps to a real transition at the current (root) level — a Descend,
# Dispatch, Pop, or an explicit cancel (Esc/Backspace). An unbound key (STAY)
# is DROPPED rather than fed in, so a stray/garbled byte from the spawn race
# never mis-dispatches into the wrong action or leaves a half-consumed chord.

HONOR = "honor"   # apply this key through the normal _apply path
DROP = "drop"     # discard this buffered key (unbound / unsafe)


def buffered_key_decision(stack, key):
    """Pure: decide the fate of a key found already buffered at spawn time.

    Returns (HONOR, result) where result is the nav_step() outcome to apply,
    or (DROP, STAY) when the key is unbound at the current level and must be
    discarded rather than mis-dispatched.

    Esc / Backspace are always honored (they are unambiguous control intents).
    A bound key (Descend/Dispatch/Pop) is honored. NO_MATCH (STAY) -> DROP.
    PURE — does NOT mutate `stack`; it only inspects via nav_step.
    """
    result = nav_step(stack, key)
    if result is STAY:           # unbound at this level -> unsafe to apply
        return (DROP, STAY)
    return (HONOR, result)


# --- soft-bell policy (issue 07) -------------------------------------------
# An unbound key at the current level (once the popup is the active surface)
# emits a soft (audible/visible) bell and leaves the popup open. A single tuned
# constant, not runtime-configurable (same stance as DELAY_S). The driver
# writes BEL ("\a") to the tty when this is on.
SOFT_BELL = True
BEL = "\a"


# --- key <-> display helpers (pure, table-driven) --------------------------

# Map a printable character read from the tty to a trie key name (the spec uses
# kitty key names like `bar`/`minus`).
#
# This map (plus the uppercase-letter rule in char_to_key) is the GLYPH path's
# only chance to name a shifted key. It matters because a shifted key typed
# WITHOUT the kitty keyboard protocol arrives as its shifted GLYPH via on_text
# (e.g. Shift+/ -> '?', Shift+h -> 'H'), NOT as an on_key event that
# matches("shift+slash"/"shift+h") could resolve. Without these entries '?' and
# 'H' fall through to themselves, miss the trie ('shift+slash'/'shift+h'), and
# the chord silently no-ops — every shift chord broken on terminals/sessions
# where the progressive keyboard protocol isn't active. '?' -> 'shift+slash' is
# the US-layout shifted form of the 'slash' key; add sibling shifted symbols
# here if the spec grows them.
_CHAR_TO_KEY = {
    "|": "bar",
    "-": "minus",
    "?": "shift+slash",
}

# Inverse, for rendering the key column: the glyph the key produces. Built from
# _CHAR_TO_KEY so the two tables can't drift, plus the named keys that only
# reach the trie via KeyEvent.matches (never through char_to_key).
_KEY_TO_DISPLAY = {name: ch for ch, name in _CHAR_TO_KEY.items()}
_KEY_TO_DISPLAY["slash"] = "/"


def char_to_key(ch):
    """Pure: a printable character -> normalized trie key name.

    '|' -> 'bar', '-' -> 'minus', '?' -> 'shift+slash'. A single uppercase
    ASCII letter is the glyph a shifted letter produces without the keyboard
    protocol (Shift+h -> 'H'), so it maps to 'shift+<letter>' ('H' ->
    'shift+h'). Anything else passes through literally. Empty / falsy input ->
    "" (treated as cancel/no-op by the driver).
    """
    if not ch:
        return ""
    if ch in _CHAR_TO_KEY:
        return _CHAR_TO_KEY[ch]
    if len(ch) == 1 and ch.isascii() and ch.isalpha() and ch.isupper():
        return "shift+" + ch.lower()
    return ch


def display_key(key_name):
    """Pure inverse of char_to_key for rendering: the glyph a key produces.
    'bar' -> '|', 'minus' -> '-', 'slash' -> '/', 'shift+slash' -> '?', and a
    shifted ASCII letter is its uppercase form ('shift+s' -> 'S'). Anything
    else (plain letters, unknown chord names) passes through verbatim."""
    if key_name in _KEY_TO_DISPLAY:
        return _KEY_TO_DISPLAY[key_name]
    if key_name.startswith("shift+"):
        rest = key_name[len("shift+"):]
        if len(rest) == 1 and rest.isascii() and rest.isalpha():
            return rest.upper()
    return key_name


# --- filter_tab_entries (popup shows only the tabs that exist) --------------
# The spec binds `1`..`9` -> goto_tab N and `0` -> goto_tab -1 (last-visited
# tab) unconditionally; the trie is static and cached, so those chords always
# dispatch. The POPUP, however, should only list the tabs the OS window really
# has. This is a pure display filter over chord_trie.entries() rows; the driver
# feeds it the live tab count (fetched over remote control in the background
# capture thread) and passes the result to layout(). Unknown count (None, e.g.
# the socket query failed) -> show everything rather than hide valid chords.

_TAB_DIGITS = frozenset("123456789")


def filter_tab_entries(rows, tab_count):
    """Pure: drop numbered-tab rows that cannot target an existing tab.

    `rows` is chord_trie.entries() output ([(key, desc, is_group), ...]).
    A `1`..`9` row survives iff int(key) <= tab_count; the `0` (last-visited
    tab) row survives iff tab_count >= 2 (with one tab there is nothing to
    toggle to). Every other row is kept verbatim, in order. tab_count None
    -> rows unchanged.
    """
    if tab_count is None:
        return list(rows)
    out = []
    for row in rows:
        key = row[0]
        if key in _TAB_DIGITS:
            if int(key) > tab_count:
                continue
        elif key == "0" and tab_count < 2:
            continue
        out.append(row)
    return out


# --- resolve_key (key-event -> spec key name; issue 08 cutover) -------------
# The full migrated spec (issue 08) introduces shifted/named keys —
# shift+h/j/k/l, shift+n/p/r/s, slash, shift+slash — that the plain glyph map
# (char_to_key) cannot name. kitty's KeyEvent.matches("shift+h") /
# matches("slash") DOES recognise those, but matches() is unreliable for
# bar/minus typed as shift+\ etc., which the glyph map handles correctly.
#
# resolve_key bridges both: given the candidate key names valid at the current
# node and a matches_fn (injected — the real driver passes key_event.matches,
# tests pass a fake), it returns the first candidate whose matches_fn is True,
# else falls back to char_to_key(text). Keeping the impure KeyEvent OUT of this
# function makes the resolution unit-testable with a plain callable.

def resolve_key(candidates, matches_fn, text):
    """Pure: resolve a key-event to a spec key name.

    `candidates` is the ordered list of key names valid at the current node
    (node.order). `matches_fn(candidate) -> bool` reports whether the live
    key-event matches that kitty key name (the driver injects
    key_event.matches). `text` is the key-event's printable text, used for the
    glyph fallback.

    Resolution order:
      1. The first `candidate` in declared order for which matches_fn(candidate)
         is True (handles shift+h, slash, shift+slash, plain letters typed with
         no glyph remap).
      2. Otherwise char_to_key(text) (handles '|' -> bar, '-' -> minus, and any
         plain printable not surfaced via matches).

    Returns the resolved key name, or "" when nothing resolves (unbound key
    with no usable text) — the driver treats "" as STAY/no-op.
    """
    for candidate in candidates:
        try:
            if matches_fn(candidate):
                return candidate
        except Exception:
            # A malformed candidate name must not abort resolution; skip it.
            continue
    return char_to_key(text)


# --- layout_block (minimal single-column layout; issue 06 replaces) --------

_SEP = "->"  # plain ASCII separator; wcwidth concerns are deferred to issue 06


def layout_block(entries):
    """Render trie `entries` (chord_trie.entries(node) -> [(key, desc,
    is_group)]) into an aligned single-column block: list[str].

    - Plain (leaf) rows come first in declared order, then `+group` rows in
      declared order. Stable partition: order within each class is preserved.
      (Full groups-last grid layout is issue 06; this is the minimal version.)
    - The key column renders display_key(key); group rows prefix it with '+'.
      The label column is the description for leaves, the group name for groups.
    - The key column is left-aligned/padded to the max key-cell width so the
      separators line up. No truncation / multi-column logic (issue 06).
    """
    # Stable partition: plain rows first, then group rows, order preserved.
    plain = [(k, d, g) for (k, d, g) in entries if not g]
    groups = [(k, d, g) for (k, d, g) in entries if g]
    ordered = plain + groups

    # Build the key cell for each row (group rows get a leading '+').
    cells = []
    for key, desc, is_group in ordered:
        keycell = ("+" + display_key(key)) if is_group else display_key(key)
        cells.append((keycell, desc))

    width = max((len(kc) for kc, _ in cells), default=0)
    lines = []
    for keycell, label in cells:
        lines.append("%s  %s  %s" % (keycell.ljust(width), _SEP, label))
    return lines
