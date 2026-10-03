# kittens/which_key_layout.py
# Pure popup layout core for the which-key kitten (issue 06).
#
# This module is the full grid layout: it takes a node's entries
# (chord_trie.entries(node) -> [(key, desc, is_group)]) plus the terminal width
# and returns the rendered popup lines. It replaces the minimal single-column
# `layout_block` (issue 03) at the renderer — which_key.py::draw() now calls
# `layout(entries(node), term_width)` instead.
#
# Design (combining Helix + which-key.nvim):
#   - Display widths are computed with a wcwidth-equivalent width (`str_width`),
#     so wide / East-Asian / combining characters in keys and descriptions stay
#     aligned. Padding is by DISPLAY width, never str.ljust (which counts code
#     points and would break the separator column on wide glyphs).
#   - Entries pack into multiple columns when numerous: a single rendered box
#     width is computed, then box_count / height / column-first fill per the
#     which-key.nvim formula.
#   - `+group` rows sort after plain rows; declared order is otherwise preserved.
#   - Descriptions are truncated (with an ellipsis) on narrow terminals rather
#     than wrapped chaotically — no line ever exceeds the terminal width.
#
# PURE: no kitty imports, no terminal, no I/O. Stdlib only (`unicodedata`,
# `math`), so it imports under plain python3 / kitty's bundled python alike and
# the unit tests run with zero third-party deps. In particular the display
# width is derived from `unicodedata` (combining/control -> 0, East-Asian W|F
# -> 2, else 1), which is column-equivalent to the `wcwidth` package for the
# relevant cases but needs no third-party dependency (PRD: pure-stdlib).

import math
import unicodedata

# Same dual import idiom as the sibling modules: top-level when path-launched as
# a custom kitten, package-qualified under the test sys.path.
try:
    from which_key_nav import display_key
except ImportError:  # imported as kittens.* under the test sys.path
    from kittens.which_key_nav import display_key


# --- constants -------------------------------------------------------------

SEP = "→"           # separator glyph between the key cell and the description
COL_SEP = " │ "     # gutter between packed grid columns: a vertical rule
SPACING = len(COL_SEP)  # gutter display width (COL_SEP is all width-1 chars)
GROUP_PREFIX = "+"  # leading marker on group key cells

# Fixed inner padding inside one box: "<keycell>  <SEP>  <desc>".
_PAD = 2            # two spaces on each side of the separator


# --- display width (wcwidth-equivalent, pure stdlib) -----------------------

def char_width(ch):
    """Display width of a single character, in terminal columns.

    Combining marks and C0/C1 control characters (incl. NUL) occupy 0 columns;
    East-Asian Wide/Fullwidth characters occupy 2; everything else 1. This is
    column-equivalent to wcwidth.wcwidth for the cases this layout meets, with
    no third-party dependency."""
    o = ord(ch)
    if o == 0:
        return 0
    if o < 32 or 0x7F <= o < 0xA0:  # C0 / DEL / C1 controls
        return 0
    if unicodedata.combining(ch):
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def str_width(s):
    """Display width of a string in terminal columns (the wcwidth-equivalent
    sum of per-character widths). This is the alignment unit the whole layout
    pads and truncates by."""
    return sum(char_width(c) for c in s)


assert str_width(COL_SEP) == SPACING, "COL_SEP must be width-1 characters only"


def truncate(s, max_width):
    """Cut `s` to at most `max_width` DISPLAY columns.

    If the string is cut, the result ends with '…' (width 1) and the whole
    result (including the ellipsis) still fits within `max_width`. Width-aware,
    so a wide glyph is never half-emitted. `max_width <= 0` -> "".
    """
    if max_width <= 0:
        return ""
    if str_width(s) <= max_width:
        return s
    # Need room for the trailing ellipsis (width 1).
    budget = max_width - 1
    out = []
    used = 0
    for ch in s:
        w = char_width(ch)
        if used + w > budget:
            break
        out.append(ch)
        used += w
    return "".join(out) + "…"


# --- entry sorting / cell formatting ---------------------------------------

def sort_entries(entries):
    """STABLE partition: plain (is_group False) rows first in declared order,
    then group (is_group True) rows in declared order. Identical behavior to
    the issue-03 layout_block partition."""
    plain = [(k, d, g) for (k, d, g) in entries if not g]
    groups = [(k, d, g) for (k, d, g) in entries if g]
    return plain + groups


def format_cells(entries):
    """Turn sorted entries into render cells: [(key_cell, desc, is_group)].

    The key cell is display_key(key), with a leading GROUP_PREFIX ('+') for
    group rows. The description is passed through as-is; truncation happens
    later in layout() once the column budget is known."""
    cells = []
    for key, desc, is_group in entries:
        kc = (GROUP_PREFIX + display_key(key)) if is_group else display_key(key)
        cells.append((kc, desc if desc is not None else "", is_group))
    return cells


# --- the public entry point ------------------------------------------------

def layout(entries, term_width, key_sgr=None):
    """Render trie `entries` into bottom-anchored popup lines for a terminal
    `term_width` columns wide. Returns list[str].

    Pure function of (entries, term_width). Plain rows come first then '+group'
    rows (declared order preserved within each); cells pack column-first into
    as many columns as fit; descriptions truncate (never wrap) on narrow
    terminals; no produced line exceeds `term_width` display columns.

    `key_sgr`, when given, is an `(on, off)` pair of escape strings wrapped
    around each key cell in the emitted lines (e.g. bold). It is zero-width for
    every layout decision: padding, packing and truncation are computed on the
    plain text, so the escapes never shift a column.
    """
    rows = sort_entries(entries)
    cells = format_cells(rows)
    n = len(cells)
    if n == 0:
        return []

    if term_width < 1:
        term_width = 1

    sep_w = str_width(SEP)
    key_w = max(str_width(kc) for kc, _, _ in cells)
    # Columns consumed by everything except the description in one box.
    fixed = key_w + _PAD + sep_w + _PAD

    # Cap the description column so a single box never exceeds the terminal.
    max_desc = term_width - fixed
    if max_desc < 1:
        # Narrow-terminal regime: force a single column and truncate each desc
        # to whatever room is left (possibly 0 -> key column + separator only).
        max_desc = max(max_desc, 0)
        desc_w = max_desc
        box_count = 1
    else:
        natural_desc = max(str_width(d) for _, d, _ in cells)
        desc_w = min(natural_desc, max_desc)
        box_width_full = fixed + desc_w
        # which-key.nvim packing: how many boxes fit across the terminal.
        box_count = max(1, (term_width + SPACING) // (box_width_full + SPACING))
        box_count = min(box_count, n)

    # When there is no room for any description (extreme narrowness), drop the
    # separator + its padding entirely and show only the key column — the
    # genuine narrow floor. Otherwise each box is "<key>  <SEP>  <desc>".
    show_desc = desc_w > 0
    box_width = (fixed + desc_w) if show_desc else key_w

    height = math.ceil(n / box_count)

    # Column-first fill: cell i -> col = i // height, row = i % height.
    grid = [[None] * box_count for _ in range(height)]
    for i, cell in enumerate(cells):
        col = i // height
        row = i % height
        grid[row][col] = cell

    on, off = key_sgr if key_sgr else ("", "")
    lines = []
    for row in range(height):
        # boxes[col] = (plain, styled) — plain drives width math only.
        boxes = []
        for col in range(box_count):
            cell = grid[row][col]
            if cell is None:
                boxes.append(None)
                continue
            kc, desc, _ = cell
            pad = " " * (key_w - str_width(kc))
            if show_desc:
                rest = "%s%s%s%s%s" % (
                    pad, " " * _PAD, SEP, " " * _PAD, truncate(desc, desc_w),
                )
            else:
                rest = pad
            boxes.append((kc + rest, on + kc + off + rest))
        # Pad every box but the row's last present one to box_width, so the
        # next column's keys line up; strip trailing space at the line end.
        last = max(
            (c for c in range(box_count) if boxes[c] is not None),
            default=-1,
        )
        parts = []
        for col in range(box_count):
            box = boxes[col]
            if box is None:
                continue
            plain, styled = box
            if col != last:
                styled += " " * (box_width - str_width(plain)) + COL_SEP
            parts.append(styled)
        lines.append("".join(parts).rstrip())
    return lines
