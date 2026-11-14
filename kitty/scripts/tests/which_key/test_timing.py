#!/usr/bin/env python3
# Fixture-table unit tests for the pure WAIT_FIRST -> STICKY timing core
# (issue 04). Drives which_key_timing.run with a fake clock (the deadline
# modeled as an explicit ("deadline",) event) and scripted key streams, so no
# real-time wait or terminal is needed. Covers:
#   - fast path: key before the deadline -> nav_step result, NO SHOW;
#   - deadline elapsed -> SHOW, then STICKY for the rest of the chord;
#   - descend after SHOW -> no second delay (exactly one SHOW);
#   - a fast Descend stays invisible (no SHOW), then STICKY;
#   - Esc / Backspace / no-match delegation to nav_step after SHOW;
#   - the 100ms applies only to level 1 (no second SHOW, deadline-in-STICKY
#     is a no-op);
#   - the injectable-clock helpers (is_expired / deadline_at, DELAY_S == 0.100);
#   - purity: run() does not mutate the caller's stack.
#
# Asserts only via the public interface of which_key_timing + which_key_nav +
# chord_trie. Stdlib unittest, no terminal / socket / real-time wait, so it
# runs under both miniconda python3 and kitty's bundled python.
import os
import sys
import unittest

# repo root on sys.path so `from kittens.* import ...` works.
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "..", "..")
)

from kittens.chord_trie import build  # noqa: E402
from kittens.which_key_nav import (  # noqa: E402
    Descend, Dispatch, Pop, CANCEL, STAY, KEY_ESC, KEY_BACKSPACE,
)
from kittens.which_key_timing import (  # noqa: E402
    run, SHOW, DELAY_S, BUDGET_S, deadline_at, is_expired, remaining_delay,
)

# Self-contained fixture spec (mirrors test_nav.py): leaves + one nested group
# with second-level leaves, in deliberately non-alphabetical order.
FIXTURE_SPEC = [
    {"key": "c",     "action": "close_window", "desc": "close window"},
    {"key": "bar",   "action": "launch --location=vsplit --cwd=current",
     "desc": "split vertical"},
    {"key": "minus", "action": "launch --location=hsplit --cwd=current",
     "desc": "split horizontal"},
    {"key": "w", "group": "window", "children": [
        {"key": "h", "action": "neighboring_window left", "desc": "focus left"},
        {"key": "j", "action": "neighboring_window down", "desc": "focus down"},
        {"key": "k", "action": "neighboring_window up",   "desc": "focus up"},
    ]},
]


def _root_stack():
    return [build(FIXTURE_SPEC)]


def _key(k):
    return ("key", k)


_DEADLINE = ("deadline",)


class FastPath(unittest.TestCase):
    def test_key_before_deadline_no_show_dispatch(self):
        # A leaf key before the deadline: fast path -> Dispatch, NO SHOW.
        decisions = run([_key("c")], _root_stack())
        self.assertNotIn(SHOW, decisions)
        self.assertEqual(len(decisions), 1)
        self.assertIsInstance(decisions[0], Dispatch)
        self.assertEqual(decisions[0].action, "close_window")

    def test_fast_descend_then_leaf_no_show(self):
        # A fast multi-key chord (w then h) stays invisible: Descend, then the
        # second-level leaf Dispatch, and NO SHOW the whole way.
        decisions = run([_key("w"), _key("h")], _root_stack())
        self.assertNotIn(SHOW, decisions)
        self.assertEqual(len(decisions), 2)
        self.assertIsInstance(decisions[0], Descend)
        self.assertIsInstance(decisions[1], Dispatch)
        self.assertEqual(decisions[1].action, "neighboring_window left")

    def test_unbound_before_deadline_keeps_waiting(self):
        # A mis-typed unbound key before the deadline -> STAY, deadline still
        # honored -> SHOW. (The popup is NOT suppressed by the mis-type.)
        decisions = run([_key("z"), _DEADLINE], _root_stack())
        self.assertIs(decisions[0], STAY)
        self.assertIs(decisions[1], SHOW)
        self.assertEqual(decisions.count(SHOW), 1)

    def test_fast_esc_cancels_no_show(self):
        # Esc before the deadline cancels with the popup never drawn.
        decisions = run([_key(KEY_ESC)], _root_stack())
        self.assertEqual(decisions, [CANCEL])
        self.assertNotIn(SHOW, decisions)


class DeadlineShow(unittest.TestCase):
    def test_deadline_emits_show_then_sticky(self):
        # Deadline first -> SHOW; then a leaf key in STICKY -> Dispatch.
        decisions = run([_DEADLINE, _key("c")], _root_stack())
        self.assertIs(decisions[0], SHOW)
        self.assertIsInstance(decisions[1], Dispatch)
        self.assertEqual(decisions[1].action, "close_window")
        self.assertEqual(decisions.count(SHOW), 1)

    def test_show_then_descend_no_second_delay(self):
        # SHOW, then descend w->h with NO further deadline/SHOW: exactly one
        # SHOW and the post-SHOW Descend/Dispatch carry no second delay.
        decisions = run([_DEADLINE, _key("w"), _key("h")], _root_stack())
        self.assertEqual(decisions.count(SHOW), 1)
        self.assertIs(decisions[0], SHOW)
        self.assertIsInstance(decisions[1], Descend)
        self.assertIsInstance(decisions[2], Dispatch)
        self.assertEqual(decisions[2].action, "neighboring_window left")

    def test_deadline_in_sticky_is_noop(self):
        # A second ("deadline",) after we are STICKY produces no decision and
        # never re-fires SHOW (level 1 only, never re-arms/times out).
        decisions = run(
            [_DEADLINE, _key("w"), _DEADLINE, _key("h")], _root_stack()
        )
        self.assertEqual(decisions.count(SHOW), 1)
        # SHOW, Descend(w), Dispatch(h) — the middle deadline added nothing.
        self.assertEqual(len(decisions), 3)
        self.assertIs(decisions[0], SHOW)
        self.assertIsInstance(decisions[1], Descend)
        self.assertIsInstance(decisions[2], Dispatch)


class StickyDecisions(unittest.TestCase):
    # Delegation to nav_step after SHOW: proves wiring, not re-implementation.
    def test_esc_cancels_after_show(self):
        decisions = run([_DEADLINE, _key(KEY_ESC)], _root_stack())
        self.assertEqual(decisions, [SHOW, CANCEL])

    def test_backspace_pops_then_root_backspace_cancels(self):
        # SHOW, descend into the group, Backspace pops to root, Backspace at
        # root cancels.
        decisions = run(
            [_DEADLINE, _key("w"), _key(KEY_BACKSPACE), _key(KEY_BACKSPACE)],
            _root_stack(),
        )
        self.assertIs(decisions[0], SHOW)
        self.assertIsInstance(decisions[1], Descend)
        self.assertIsInstance(decisions[2], Pop)
        self.assertIs(decisions[3], CANCEL)

    def test_nomatch_ignored_after_show(self):
        decisions = run([_DEADLINE, _key("z")], _root_stack())
        self.assertEqual(decisions, [SHOW, STAY])


class Level1Only(unittest.TestCase):
    def test_deadline_only_applies_to_level1(self):
        # After the first SHOW, an arbitrarily long STICKY stream — including
        # stray deadline events — never emits a second SHOW.
        events = [
            _DEADLINE,
            _key("w"), _DEADLINE, _key(KEY_BACKSPACE),
            _DEADLINE, _key("w"), _key("j"),
        ]
        decisions = run(events, _root_stack())
        self.assertEqual(decisions.count(SHOW), 1)
        # Final decision dispatches the level-2 leaf with no extra delay.
        self.assertIsInstance(decisions[-1], Dispatch)
        self.assertEqual(decisions[-1].action, "neighboring_window down")


class ClockHelpers(unittest.TestCase):
    def test_is_expired_boundary(self):
        self.assertFalse(is_expired(0.0, 0.099))
        self.assertTrue(is_expired(0.0, 0.100))
        self.assertTrue(is_expired(0.0, 0.250))

    def test_deadline_at(self):
        self.assertAlmostEqual(deadline_at(5.0), 5.1)
        self.assertAlmostEqual(deadline_at(0.0), DELAY_S)

    def test_delay_constant_pinned(self):
        # The single tuned constant; not runtime-configurable (PRD).
        self.assertEqual(DELAY_S, 0.100)

    def test_remaining_delay_counts_spawn_against_budget(self):
        # The live driver anchors its deadline at process start: a slow spawn
        # eats into the budget rather than stacking on top of it.
        self.assertAlmostEqual(remaining_delay(0.0), BUDGET_S)
        self.assertAlmostEqual(remaining_delay(0.05), BUDGET_S - 0.05)

    def test_remaining_delay_never_negative(self):
        # Spawn slower than the whole budget -> show immediately, never a
        # negative timer.
        self.assertEqual(remaining_delay(BUDGET_S), 0.0)
        self.assertEqual(remaining_delay(BUDGET_S + 1.0), 0.0)

    def test_budget_exceeds_abstract_delay(self):
        # BUDGET_S is measured from process start and must cover at least the
        # abstract DELAY_S the pure machine reasons about.
        self.assertGreaterEqual(BUDGET_S, DELAY_S)


class Purity(unittest.TestCase):
    def test_run_does_not_mutate_caller_stack(self):
        # run() navigates on a LOCAL copy; the caller's stack is untouched
        # whatever the event stream does (descends, pops, dispatch).
        for events in [
            [_key("c")],                              # fast Dispatch
            [_key("w"), _key("h")],                   # fast Descend
            [_DEADLINE, _key("w"), _key(KEY_BACKSPACE)],  # SHOW, Descend, Pop
        ]:
            with self.subTest(events=events):
                stack = _root_stack()
                before_len = len(stack)
                before_ids = [id(n) for n in stack]
                run(events, stack)
                self.assertEqual(len(stack), before_len)
                self.assertEqual([id(n) for n in stack], before_ids)


if __name__ == "__main__":
    unittest.main()
