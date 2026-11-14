# kittens/which_key_layout.py
# Pure popup layout core for the which-key kitten (issue 06).
#
# This module is the full grid layout: it takes a node's rows grouped into
# sections (chord_trie.sections(node) -> [(label, [(key, desc, is_group)])])
# plus the terminal width and returns the rendered popup lines. It replaces the
# minimal single-column `layout_block` (issue 03) at the renderer —
# which_key.py::draw() calls `layout_sections(sections(node), term_width)`;
# `layout(entries, term_width)` is the flat (headerless) special case.
#
# Design (combining Helix + which-key.nvim):
#   - Display widths are computed with a wcwidth-equivalent width (`str_width`),
#     so wide / East-Asian / combining characters in keys and descriptions stay
#     aligned. Padding is by DISPLAY width, never str.ljust (which counts code
#     points and would break the separator column on wide glyphs).
#   - Entries pack into multiple columns when numerous: a single rendered box
#     width is computed, then box_count / height / column-first fill per the
#     which-key.nvim formula.
#   - Sections: a labeled section renders as a header line followed by its rows
#     and is never split across columns (the column height grows to the tallest
#     labeled section instead). Sections stacked in one column are separated by
#     a blank line. Unlabeled rows (label None) are headerless filler that may
#     split column-first exactly like the flat layout. Each column is as wide
#     as its own widest box, so a column of short rows stays narrow.
#   - `+group` rows sort after plain rows within a section; declared order is
#     otherwise preserved.
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


# --- the public entry points -------------------------------------------------

# Column line kinds (internal): what one row of one packed column holds.
_HEADER = 0   # payload: section label
_CELL = 1     # payload: (key_cell, desc, is_group)
_BLANK = 2    # separator between two sections stacked in the same column


def layout(entries, term_width, key_sgr=None):
    """Render flat trie `entries` with no section headers. Equivalent to
    layout_sections([(None, entries)], ...): plain rows then '+group' rows,
    column-first packing into as many columns as fit."""
    return layout_sections([(None, entries)], term_width, key_sgr)


def layout_sections(sections, term_width, key_sgr=None, header_sgr=None):
    """Render `sections` ([(label, entries)], as chord_trie.sections() emits)
    into bottom-anchored popup lines for a terminal `term_width` columns wide.
    Returns list[str].

    Pure function of (sections, term_width). Within a section plain rows come
    first then '+group' rows (declared order preserved within each). A labeled
    section is one header line plus its rows and never splits across columns;
    unlabeled rows pack column-first. Descriptions truncate (never wrap) on
    narrow terminals; no produced line exceeds `term_width` display columns.

    `key_sgr` / `header_sgr`, when given, are `(on, off)` escape-string pairs
    wrapped around each key cell / header label in the emitted lines. They are
    zero-width for every layout decision: padding, packing and truncation are
    computed on the plain text, so the escapes never shift a column.
    """
    units = []
    for label, rows in sections:
        cells = format_cells(sort_entries(rows))
        if cells:
            units.append((label, cells))
    if not units:
        return []

    if term_width < 1:
        term_width = 1

    all_cells = [c for _, cells in units for c in cells]
    n = len(all_cells)
    sep_w = str_width(SEP)
    key_w = max(str_width(kc) for kc, _, _ in all_cells)
    # Columns consumed by everything except the description in one box.
    fixed = key_w + _PAD + sep_w + _PAD
    header_w = max((str_width(lb) for lb, _ in units if lb is not None),
                   default=0)

    # Cap the description column so a single box never exceeds the terminal.
    max_desc = term_width - fixed
    if max_desc < 1:
        # Narrow-terminal regime: force a single column and truncate each desc
        # to whatever room is left (possibly 0 -> key column + separator only).
        max_desc = max(max_desc, 0)
        desc_w = max_desc
        box_count = 1
    else:
        natural_desc = max(str_width(d) for _, d, _ in all_cells)
        desc_w = min(natural_desc, max_desc)
        # Widest possible column: a box, or a header label if that is wider.
        box_width_full = max(fixed + desc_w, min(header_w, term_width))
        # which-key.nvim packing: how many boxes fit across the terminal.
        box_count = max(1, (term_width + SPACING) // (box_width_full + SPACING))
        box_count = min(box_count, n)

    # When there is no room for any description (extreme narrowness), drop the
    # separator + its padding entirely and show only the key column — the
    # genuine narrow floor. Otherwise each box is "<key>  <SEP>  <desc>".
    show_desc = desc_w > 0

    # Column height: the smallest H at which the sections pack into box_count
    # columns. Lower bound is the flat column-first height (so a single
    # unlabeled section reproduces the flat layout exactly) or the tallest
    # labeled section (header + rows), whichever is larger, since a labeled
    # section is never split. Grows until the greedy pack fits; it always
    # does by the time one column holds everything.
    total = sum(len(cells) + (label is not None) for label, cells in units)
    height = max(
        1, math.ceil(total / box_count),
        max((len(cells) + 1 for label, cells in units if label is not None),
            default=0),
    )
    while True:
        columns = _pack(units, height)
        if len(columns) <= box_count:
            break
        height += 1

    # Per-column geometry: each column is as wide as its own widest box (or
    # header), never wider than the global box width that sized box_count.
    widths = []
    for col in columns:
        cells = [p for kind, p in col if kind == _CELL]
        kw = max((str_width(kc) for kc, _, _ in cells), default=0)
        if show_desc:
            dw = min(max((str_width(d) for _, d, _ in cells), default=0),
                     desc_w)
            bw = kw + _PAD + sep_w + _PAD + dw
        else:
            dw = 0
            bw = kw
        hw = max((str_width(p) for kind, p in col if kind == _HEADER),
                 default=0)
        widths.append((kw, dw, max(bw, min(hw, term_width))))

    k_on, k_off = key_sgr if key_sgr else ("", "")
    h_on, h_off = header_sgr if header_sgr else ("", "")
    lines = []
    for row in range(max(len(col) for col in columns)):
        # boxes[col] = (plain, styled) — plain drives width math only.
        boxes = []
        for ci, col in enumerate(columns):
            kw, dw, _ = widths[ci]
            if row >= len(col):
                boxes.append(None)
                continue
            kind, payload = col[row]
            if kind == _BLANK:
                boxes.append(("", ""))
            elif kind == _HEADER:
                text = truncate(payload, widths[ci][2])
                boxes.append((text, h_on + text + h_off))
            else:
                kc, desc, _ = payload
                pad = " " * (kw - str_width(kc))
                if show_desc:
                    rest = "%s%s%s%s%s" % (
                        pad, " " * _PAD, SEP, " " * _PAD, truncate(desc, dw),
                    )
                else:
                    rest = pad
                boxes.append((kc + rest, k_on + kc + k_off + rest))
        # Pad every box but the row's last present one to its column width, so
        # the next column's keys line up and the gutter rule stays continuous
        # past short columns; strip trailing space at the line end.
        last = max(
            (c for c in range(len(columns)) if boxes[c] is not None),
            default=-1,
        )
        parts = []
        for ci in range(last + 1):
            plain, styled = boxes[ci] if boxes[ci] is not None else ("", "")
            if ci != last:
                styled += " " * (widths[ci][2] - str_width(plain)) + COL_SEP
            parts.append(styled)
        lines.append("".join(parts).rstrip())
    return lines


def _pack(units, height):
    """Greedy column packing at a fixed column `height`. Returns a list of
    columns, each a list of (kind, payload) lines. Sections are placed in
    order; a labeled section (header + rows) moves whole to the next column
    when it does not fit below what is already there, while unlabeled rows
    flow column-first. Two sections stacked in one column get a _BLANK between
    them. Never produces a column taller than `height` unless a single
    labeled section is itself taller (the caller's lower bound prevents that).
    """
    columns = [[]]

    def put(line, first_of_section):
        col = columns[-1]
        gap = 1 if (col and first_of_section) else 0
        if col and len(col) + gap + 1 > height:
            columns.append([])
            col = columns[-1]
        elif gap:
            col.append((_BLANK, None))
        col.append(line)

    for label, cells in units:
        if label is None:
            for i, cell in enumerate(cells):
                put((_CELL, cell), i == 0)
            continue
        col = columns[-1]
        if col and len(col) + 1 + 1 + len(cells) > height:
            columns.append([])
        put((_HEADER, label), True)
        for cell in cells:
            put((_CELL, cell), False)
    return columns
