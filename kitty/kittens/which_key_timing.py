# kittens/which_key_timing.py
# Pure WAIT_FIRST -> STICKY timing core for the which-key kitten (issue 04).
#
# This module adds the level-1 show-delay / fast-path layer on top of the
# STICKY descent reducer (`nav_step`, from which_key_nav). It does NOT
# re-implement navigation: every key is fed to `nav_step` and its result
# (Descend/Dispatch/Pop/CANCEL/STAY) is emitted unchanged. Issue 04 is solely
# about WHEN the first popup appears and the invisible fast path.
#
# The two-state machine (PRD):
#   WAIT_FIRST  (level 1, with a 100ms deadline)
#     key before deadline -> run nav_step, NEVER emit SHOW (fast path). On a
#                            leaf Dispatch the popup is never drawn; on a
#                            Descend we go STICKY (level 2+ has no delay).
#     deadline elapsed     -> emit SHOW, go STICKY.
#   STICKY  (no deadline, indefinite)
#     every key -> nav_step result; never another SHOW, never a deadline.
#
# The 100ms deadline applies ONLY to level 1: once SHOW (or a fast Descend)
# moves us to STICKY, no further delay and no timeout — the deliberate
# divergence from Helix's per-level idle-timer re-arm.
#
# PURE: no kitty imports, no terminal, no real-time sleeps. The clock is
# injectable; for tests the deadline is modeled as an explicit ("deadline",)
# event so the test decides exactly when it fires relative to keys (the
# "fake clock + scripted key stream" the PRD mandates). `deadline_at` /
# `is_expired` are the thin real-time helpers the live driver uses.

# Same dual import idiom as the sibling modules: top-level when path-launched
# as a custom kitten, package-qualified under the test sys.path.
try:
    from which_key_nav import (
        nav_step, Descend, Dispatch, Pop, CANCEL, STAY,
    )
except ImportError:  # imported as kittens.* under the test sys.path
    from kittens.which_key_nav import (
        nav_step, Descend, Dispatch, Pop, CANCEL, STAY,
    )


# --- the tuned constants ----------------------------------------------------
# Not runtime-configurable (PRD Out of Scope).
#
# DELAY_S is the abstract level-1 deadline the pure machine (run / is_expired /
# deadline_at) reasons about: "100ms with no key -> SHOW".
DELAY_S = 0.100

# BUDGET_S is what the LIVE driver actually arms, measured from the kitten
# PROCESS START rather than from the moment the kitten is ready to read keys.
# Spawning `kitty +kitten` costs ~150ms on its own (python + kitty's asyncio
# TUI runner), so a deadline armed only once the handler initializes would
# land at spawn + DELAY_S ~= 250ms+ after the leader press. Anchoring at process
# start makes the popup land at a predictable BUDGET_S after the press no
# matter how slow the spawn was: remaining_delay() hands the driver whatever is
# left of the budget (0 if the spawn already ate it all -> show immediately).
# The fast path is unaffected: keys typed during the spawn sit in the pty
# buffer and are delivered before any timer fires.
BUDGET_S = 0.200


def remaining_delay(process_age_s):
    """Seconds the live driver should still wait before SHOW, given how long
    the kitten process has already been alive. Never negative."""
    return max(0.0, BUDGET_S - process_age_s)


# --- emitted decision: SHOW ------------------------------------------------
# Distinct singleton from nav_step's results. Emitted exactly once, when the
# level-1 deadline elapses with no key: the popup must be drawn now and the
# machine has entered STICKY.

class _Show:
    """Singleton: the 100ms deadline elapsed -> draw the popup, go STICKY."""
    __slots__ = ()

    def __repr__(self):
        return "SHOW"


SHOW = _Show()


# --- real-time clock helpers (used by the live driver only) ----------------

def deadline_at(start_now):
    """The absolute time the level-1 deadline fires, given the start time."""
    return start_now + DELAY_S


def is_expired(start_now, now):
    """True once DELAY_S has elapsed since start_now (deadline reached)."""
    return (now - start_now) >= DELAY_S


# --- pure driver of the WAIT_FIRST -> STICKY machine -----------------------

def run(events, stack):
    """Pure driver of the WAIT_FIRST->STICKY machine over a finite, scripted
    `events` stream. Returns the list of emitted decisions in order, suitable
    for asserting in tests.

    Each event is one of:
      ("key", key_token)  a key arrived (already normalized via char_to_key /
                          KEY_ESC / KEY_BACKSPACE).
      ("deadline",)       the level-1 100ms deadline fired with no key.

    Decisions emitted are SHOW (once, on the deadline in WAIT_FIRST) plus, for
    each key, the corresponding `nav_step` result (Descend / Dispatch / Pop /
    CANCEL / STAY).

    `stack` starts as [root]. run() applies pushes/pops to a LOCAL copy so it
    can keep navigating after SHOW (it must, to prove "descend after show -> no
    second delay"). It does NOT mutate the caller's `stack`.

    State machine:
      - WAIT_FIRST (level 1 only):
          ("key", k):  fast path. Run nav_step, emit its result, NEVER SHOW.
                       * Descend  -> push, go STICKY (level 2+ has no delay; a
                                     fast first key stays invisible).
                       * Pop       -> apply (cannot happen at level 1: root
                                     Backspace yields CANCEL, not Pop) — handled
                                     defensively, stay WAIT_FIRST.
                       * Dispatch  -> chord ends (popup never drawn).
                       * CANCEL    -> chord ends (popup never drawn).
                       * STAY      -> mis-typed unbound key. The deadline stays
                                     armed (the live driver does not cancel it),
                                     so the popup still appears at 100ms; here
                                     we stay WAIT_FIRST.
          ("deadline",): emit SHOW, go STICKY.
      - STICKY:
          ("key", k):  run nav_step, emit its result; apply Descend/Pop to the
                       local stack. Never another SHOW.
          ("deadline",): no-op (defensive — the driver won't emit one; the core
                       must not double-fire / re-time-out).
    """
    local = list(stack)  # local copy: do not mutate the caller's stack
    sticky = False
    decisions = []

    for event in events:
        kind = event[0]

        if kind == "deadline":
            if not sticky:
                decisions.append(SHOW)
                sticky = True
            # In STICKY a deadline is a no-op: level 1 only, never re-arms.
            continue

        # kind == "key"
        key = event[1]
        result = nav_step(local, key)
        decisions.append(result)

        if isinstance(result, Descend):
            local.append(result.node)
            # First descent leaves WAIT_FIRST: deeper levels are STICKY with no
            # further delay. (In WAIT_FIRST this is the fast-descend path; in
            # STICKY we were already sticky.)
            sticky = True
        elif isinstance(result, Pop):
            local.pop()
            # Pop only occurs in STICKY (root Backspace -> CANCEL, not Pop).
        # Dispatch / CANCEL: the chord ends; STAY: nothing changes.

    return decisions
