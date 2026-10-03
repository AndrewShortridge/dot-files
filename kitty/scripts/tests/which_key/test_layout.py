#!/usr/bin/env python3
# Fixture-table unit tests for the pure popup layout core (issue 06).
# Covers which_key_layout: the wcwidth-equivalent display width (char_width /
# str_width — asserted WITHOUT importing the wcwidth package, since the kitten
# runs under kitty's bundled python which has no wcwidth), width-aware
# truncation with an ellipsis, the groups-after-plain stable partition, and the
# public layout(entries, term_width) grid: column-first multi-column packing &
# thresholds, wcwidth alignment of the separator column, group-sort-last,
# declared-order preservation, and narrow-terminal truncation (no line wider
# than the terminal).
#
# Asserts only via the public interface of which_key_layout + chord_trie.
# Stdlib unittest, no terminal / socket / real-time wait, so it runs under both
# miniconda python3 and kitty's bundled python.
import math
import os
import sys
import unittest

# repo root on sys.path so `from kittens.* import ...` works.
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "..", "..")
)

from kittens.chord_trie import build, entries  # noqa: E402
from kittens.which_key_layout import (  # noqa: E402
    layout, str_width, char_width, truncate, sort_entries, format_cells,
    SEP, SPACING,
)

# Same fixture shape as test_nav.py: plain leaves c / | / - in a deliberately
# non-alphabetical order, plus one nested group `w` (declared last here so the
# group already trails — interleaved order is exercised separately below).
FIXTURE_SPEC = [
    {"key": "c",     "action": "close_window", "desc": "close window"},
    {"key": "bar",   "action": "split v", "desc": "split vertical"},
    {"key": "minus", "action": "split h", "desc": "split horizontal"},
    {"key": "w", "group": "window", "children": [
        {"key": "h", "action": "neighboring_window left", "desc": "focus left"},
        {"key": "j", "action": "neighboring_window down", "desc": "focus down"},
        {"key": "k", "action": "neighboring_window up",   "desc": "focus up"},
    ]},
]

# A wide-character entry list (East-Asian key + description) to prove the
# alignment / truncation logic is display-width aware, not code-point counting.
WIDE_ENTRIES = [
    ("你", "宽字符描述", False),
    ("a", "ascii", False),
]


def _fixture_entries():
    return entries(build(FIXTURE_SPEC))


class CharWidth(unittest.TestCase):
    def test_char_width(self):
        cases = [
            ("a", 1), ("你", 2), ("→", 1), ("Ａ", 2),
            ("\x00", 0), ("\x07", 0),
        ]
        for ch, expected in cases:
            with self.subTest(ch=repr(ch)):
                self.assertEqual(char_width(ch), expected)

    def test_combining_is_zero(self):
        # Combining acute accent occupies 0 columns; the base 'e' + accent
        # together read as one column.
        self.assertEqual(char_width("́"), 0)
        self.assertEqual(str_width("é"), 1)


class StrWidth(unittest.TestCase):
    def test_str_width(self):
        # wcwidth-equivalence asserted by literal expected columns (no wcwidth
        # import): ascii=len, CJK=2 each, fullwidth=2 each, combining=0.
        cases = [
            ("abc", 3),
            ("你好", 4),
            ("café", 4),         # precomposed é, width 1
            ("ＡＢ", 4),         # fullwidth letters
            ("é", 1),      # decomposed é -> base + combining
            ("→", 1),
            ("", 0),
        ]
        for s, expected in cases:
            with self.subTest(s=s):
                self.assertEqual(str_width(s), expected)


class Truncate(unittest.TestCase):
    def test_no_truncation_when_it_fits(self):
        self.assertEqual(truncate("hello", 10), "hello")
        self.assertEqual(truncate("hello", 5), "hello")

    def test_truncates_with_ellipsis(self):
        out = truncate("hello", 3)
        self.assertTrue(out.endswith("…"))
        self.assertLessEqual(str_width(out), 3)

    def test_wide_char_truncation_no_half_glyph(self):
        # 你好世界 is 8 columns; into 3 it must end with … and stay <= 3 columns
        # (i.e. never emit a half / overrunning wide glyph).
        out = truncate("你好世界", 3)
        self.assertTrue(out.endswith("…"))
        self.assertLessEqual(str_width(out), 3)

    def test_zero_and_negative(self):
        self.assertEqual(truncate("x", 0), "")
        self.assertEqual(truncate("x", -5), "")


class SortEntries(unittest.TestCase):
    def test_declared_order_within_classes(self):
        ents = _fixture_entries()  # c, |, -, +w(group)
        ordered = sort_entries(ents)
        keys = [k for k, _, _ in ordered]
        self.assertEqual(keys, ["c", "bar", "minus", "w"])

    def test_group_declared_first_lands_after_plain(self):
        interleaved = [
            ("w", "window", True),
            ("c", "close window", False),
            ("bar", "split vertical", False),
        ]
        ordered = sort_entries(interleaved)
        self.assertEqual([k for k, _, _ in ordered], ["c", "bar", "w"])
        # group flag preserved, group is last.
        self.assertTrue(ordered[-1][2])


def _sep_column(line):
    """Display-column index of the SEP glyph on a line (first occurrence)."""
    return str_width(line[: line.index(SEP)])


class LayoutAlignment(unittest.TestCase):
    def test_separator_aligned_wide_width(self):
        # At a wide width every entry packs in one column; the SEP glyph must
        # land at the same DISPLAY column on every line.
        lines = layout(_fixture_entries(), 80)
        cols = {_sep_column(ln) for ln in lines if SEP in ln}
        self.assertEqual(len(cols), 1)

    def test_separator_aligned_with_wide_keys(self):
        # Mixed wide ('你', 2 cols) and narrow ('a', 1 col) key cells: the SEP
        # must still align by display width (proves width-aware padding, not
        # str.ljust which would mis-place it after the wide glyph).
        lines = layout(WIDE_ENTRIES, 80)
        cols = {_sep_column(ln) for ln in lines if SEP in ln}
        self.assertEqual(len(cols), 1)
        # Key column is padded to the widest cell (你 = 2 columns).
        self.assertEqual(min(cols), 2 + 2)  # key_w(2) + 2 spaces before SEP


class LayoutPacking(unittest.TestCase):
    def _many(self, n):
        # n plain leaves with identical short descriptions -> uniform box width.
        return [("k%d" % i, "desc", False) for i in range(n)]

    def _box_width(self, ents):
        # The single-box display width = width of one rendered entry. Force a
        # one-column render by giving exactly enough width for one box but not
        # two, via a binary search on the smallest width yielding n lines.
        cells = format_cells(sort_entries(ents))
        key_w = max(str_width(kc) for kc, _, _ in cells)
        desc_w = max(str_width(d) for _, d, _ in cells)
        # fixed = key_w + 2 + str_width(SEP) + 2  (mirrors layout()).
        return key_w + 2 + str_width(SEP) + 2 + desc_w

    def test_single_column_when_only_one_fits(self):
        ents = self._many(5)
        bw = self._box_width(ents)
        lines = layout(ents, bw)  # exactly one box fits
        self.assertEqual(len(lines), 5)  # height == n, one column

    def test_packing_threshold(self):
        ents = self._many(6)
        bw = self._box_width(ents)
        # Just below two boxes -> still 1 column.
        narrow = bw * 2 + SPACING - 1
        self.assertEqual(len(layout(ents, narrow)), 6)
        # Exactly two boxes -> 2 columns, height = ceil(6/2) = 3.
        wide = bw * 2 + SPACING
        lines = layout(ents, wide)
        self.assertEqual(len(lines), 3)

    def test_box_count_formula(self):
        ents = self._many(12)
        bw = self._box_width(ents)
        for box_count in (1, 2, 3, 4):
            term_width = bw * box_count + SPACING * (box_count - 1)
            expected = max(1, (term_width + SPACING) // (bw + SPACING))
            expected = min(expected, 12)
            height = math.ceil(12 / expected)
            with self.subTest(box_count=box_count):
                self.assertEqual(len(layout(ents, term_width)), height)

    def test_column_first_fill_order(self):
        # 6 entries into 2 columns (height 3): col1 = k0,k1,k2 top-to-bottom,
        # col2 = k3,k4,k5. Read the key cell at the start of each line and the
        # cell after the column gap.
        ents = self._many(6)
        bw = self._box_width(ents)
        lines = layout(ents, bw * 2 + SPACING)
        self.assertEqual(len(lines), 3)
        # First column: the leading key on each line.
        first_col = [ln.split()[0] for ln in lines]
        self.assertEqual(first_col, ["k0", "k1", "k2"])
        # Second column begins after the first box + SPACING; its key follows
        # the SEP+desc of column 1. Just assert k3..k5 appear, in order, after
        # k0..k2 on their respective rows.
        for row, expected in enumerate(["k3", "k4", "k5"]):
            self.assertIn(expected, lines[row])
            self.assertGreater(lines[row].index(expected), lines[row].index("k%d" % row))


class LayoutGroupSort(unittest.TestCase):
    def test_group_row_last_in_reading_order(self):
        # +w group row must come after all plain rows in the column-first
        # reading order. At a wide width it's one column -> last line.
        lines = layout(_fixture_entries(), 80)
        group_lines = [ln for ln in lines if "+w" in ln]
        self.assertEqual(len(group_lines), 1)
        self.assertIs(group_lines[0], lines[-1])

    def test_groups_last_even_when_multicolumn(self):
        # Mix several plain + several groups; pack into 2 columns; the group
        # cells must all come AFTER the plain cells in column-first order.
        ents = [("p%d" % i, "d", False) for i in range(4)]
        ents += [("g%d" % i, "grp", True) for i in range(2)]
        ordered = sort_entries(ents)
        flat = [k for k, _, _ in ordered]
        # plain keys all precede group keys in the flattened order.
        last_plain = max(flat.index("p%d" % i) for i in range(4))
        first_group = min(flat.index("g%d" % i) for i in range(2))
        self.assertLess(last_plain, first_group)


class LayoutOrderPreserved(unittest.TestCase):
    def test_declared_order_in_traversal(self):
        # Declared order c, |, - (plain) then +w (group), read in column-first
        # order regardless of how many columns the layout packs into. We assert
        # via the module's own sort, which IS the column-first cell order.
        ordered = sort_entries(_fixture_entries())
        from kittens.which_key_nav import display_key
        keys = [
            ("+" + display_key(k)) if g else display_key(k)
            for k, _, g in ordered
        ]
        self.assertEqual(keys, ["c", "|", "-", "+w"])
        # And every declared key cell appears in the rendered output.
        lines = layout(_fixture_entries(), 80)
        joined = "\n".join(lines)
        for kc in keys:
            self.assertIn(kc, joined)


class LayoutNarrowTruncation(unittest.TestCase):
    def test_narrow_terminal_truncates_not_wraps(self):
        width = 12
        lines = layout(_fixture_entries(), width)
        # No line exceeds the terminal width (no chaotic wrap).
        for ln in lines:
            with self.subTest(line=ln):
                self.assertLessEqual(str_width(ln), width)
        # Single column under narrowness: one entry per line == 6 rows.
        self.assertEqual(len(lines), len(_fixture_entries()))
        # At least one description is truncated with an ellipsis.
        self.assertTrue(any("…" in ln for ln in lines))

    def test_extreme_narrow_floors_to_keys(self):
        # At width 1 the descriptions and separator are dropped to the key-only
        # floor (keys themselves are never truncated, so the floor is the key
        # column width). One line per entry, single column, no SEP rendered.
        ents = _fixture_entries()
        lines = layout(ents, 1)
        self.assertEqual(len(lines), len(ents))
        for ln in lines:
            self.assertNotIn(SEP, ln)         # separator dropped
            self.assertNotIn("…", ln)         # no truncated descriptions left
        # Floor width == widest key cell ('+w' == 2 columns); never wider.
        self.assertTrue(all(str_width(ln) <= 2 for ln in lines))


class LayoutEmpty(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(layout([], 80), [])


class LayoutKeySgr(unittest.TestCase):
    ON, OFF = "\x1b[1m", "\x1b[22m"

    def _strip(self, s):
        return s.replace(self.ON, "").replace(self.OFF, "")

    def test_default_has_no_escapes(self):
        for ln in layout(_fixture_entries(), 80):
            self.assertNotIn("\x1b", ln)

    def test_escapes_wrap_each_key_only(self):
        ents = _fixture_entries()
        lines = layout(ents, 80, key_sgr=(self.ON, self.OFF))
        plain = layout(ents, 80)
        self.assertEqual([self._strip(ln) for ln in lines], plain)
        joined = "".join(lines)
        # One ON/OFF pair per entry, each line starts with ON, and every
        # wrapped span is exactly a key cell (never a description).
        self.assertEqual(joined.count(self.ON), len(ents))
        self.assertEqual(joined.count(self.OFF), len(ents))
        key_cells = {kc for kc, _, _ in format_cells(ents)}
        for ln in lines:
            with self.subTest(line=ln):
                self.assertTrue(ln.startswith(self.ON))
                for chunk in ln.split(self.ON)[1:]:
                    self.assertIn(chunk.split(self.OFF, 1)[0], key_cells)

    def test_escapes_are_width_neutral_in_grid(self):
        # Multi-column packing: columns, line count and the separator column
        # must be identical with and without the escapes (padding is computed
        # on plain text, not on the styled string).
        ents = [("k%d" % i, "desc", False) for i in range(6)]
        key_w = max(str_width(k) for k, _, _ in ents)
        bw = key_w + 2 + str_width(SEP) + 2 + 4
        width = bw * 2 + SPACING
        plain = layout(ents, width)
        styled = layout(ents, width, key_sgr=(self.ON, self.OFF))
        self.assertEqual(len(styled), 3)
        self.assertEqual([self._strip(ln) for ln in styled], plain)
        self.assertEqual(styled[0].count(self.ON), 2)
        for ln in styled:
            self.assertLessEqual(str_width(self._strip(ln)), width)


class FormatCells(unittest.TestCase):
    def test_group_prefix_and_display_key(self):
        cells = format_cells([
            ("bar", "split vertical", False),
            ("w", "window", True),
        ])
        self.assertEqual(cells[0][0], "|")     # display_key(bar) -> |
        self.assertEqual(cells[1][0], "+w")    # group gets '+' prefix


if __name__ == "__main__":
    unittest.main()
