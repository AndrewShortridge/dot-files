#!/usr/bin/env python3
# which_key kitten (issue 04: 100ms-then-sticky timing core).
#
# An overlay kitten that draws the which-key popup and drives the full chord
# descent loop. On the temporary trigger key it arms a 100ms deadline instead
# of drawing immediately (WAIT_FIRST): if the user types a known chord key
# before the deadline, the kitten takes the fast path — it runs that key
# through nav_step and, on a leaf, dispatches the action with the popup NEVER
# drawn (no flash). If the 100ms deadline elapses with no key, the popup is
# shown and the loop becomes STICKY for the rest of the chord. A fast first key
# that descends into a group also goes STICKY (level 2+ has no further delay).
#
# Once STICKY the popup lists every valid continuation key + its description,
# anchored at the bottom of the window, and stays open until the user selects a
# leaf, presses Esc, or Backspaces out at the root. Selecting a sub-prefix
# redraws immediately with that prefix's entries (sub-prefixes show as a single
# `+group` row). A leaf dispatches its action and closes. Esc cancels with no
# action. Backspace pops one level; at the root it cancels. An unbound key is
# ignored and leaves the popup open.
#
# The deadline applies ONLY to level 1; deeper levels render with no further
# delay and never time out (the deliberate divergence from Helix's per-level
# idle-timer re-arm). The pure two-state machine and the DELAY_S / BUDGET_S
# constants live in which_key_timing; the STICKY per-key reducer is nav_step.
# The live deadline is BUDGET_S from the kitten's PROCESS START (not from
# handler init), so the spawn cost counts against the budget; the background
# screen snapshot is fetched over the remote-control socket in a thread that
# overlaps that wait.
# The richer wcwidth/multi-column grid layout lives in which_key_layout.layout
# (issue 06); draw() calls it with the real screen width, replacing the issue-03
# minimal single-column which_key_nav.layout_block. The trie disk
# cache (issue 05) now backs the module-scope build via which_key_cache.
# load_or_build, so an unchanged spec is deserialized rather than re-parsed.
#
# Architecture (custom kitty kitten, two-phase):
#   main(args)            -> runs in the overlay SUBPROCESS (real tty). Draws
#                            the popup, reads keys, walks the trie via the pure
#                            nav_step reducer, and returns the chosen action
#                            string (or "" to cancel).
#   handle_result(...)    -> runs IN the kitty process. Dispatches the action
#                            against the underlying window via boss.
#
# IMPORTANT: no kitty imports at module scope, so the pure core (the trie +
# nav reducer + layout) imports cleanly under plain python3 for the unit tests.
# All kitty imports live inside main()/handle_result().

# --- pure core (imported by tests; NO kitty imports) ----------------------

# Two import paths (same idiom as the sibling modules):
#  - path-launched as a custom kitten (`kitten .../which_key.py`): kitty puts
#    the kitten's own directory on sys.path, so the siblings resolve as
#    top-level names.
#  - imported as `kittens.which_key` (the unit tests prepend repo root): the
#    package-qualified path resolves.
# kitty 0.47 path-launches a custom kitten via runpy.run_path WITHOUT putting
# the kitten's own directory on sys.path (sys.path[0] is just the cwd, which is
# `--cwd=current` here — not the kittens dir). So the bare `from chord_trie ...`
# below cannot resolve, and the `from kittens.chord_trie ...` fallback binds to
# kitty's BUNDLED kittens package, which has no chord_trie. Put this file's own
# directory on sys.path first so the sibling top-level imports resolve. (Under
# the unit tests the modules are imported as kittens.* with repo root on the
# path, so the second branch still covers that case.)
import os as _os
import sys as _sys
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))

try:
    from chord_trie import build, entries
    import which_key_spec as _spec_mod
    from which_key_cache import load_or_build
    from which_key_nav import (
        nav_step, char_to_key, display_key, resolve_key,
        Descend, Dispatch, Pop, CANCEL, STAY, KEY_ESC, KEY_BACKSPACE,
        buffered_key_decision, HONOR, SOFT_BELL, BEL,
    )
    from which_key_layout import layout
    from which_key_timing import DELAY_S, remaining_delay
except ImportError:  # imported as kittens.* under the test sys.path
    from kittens.chord_trie import build, entries
    from kittens import which_key_spec as _spec_mod
    from kittens.which_key_cache import load_or_build
    from kittens.which_key_nav import (
        nav_step, char_to_key, display_key, resolve_key,
        Descend, Dispatch, Pop, CANCEL, STAY, KEY_ESC, KEY_BACKSPACE,
        buffered_key_decision, HONOR, SOFT_BELL, BEL,
    )
    from kittens.which_key_layout import layout
    from kittens.which_key_timing import DELAY_S, remaining_delay

# Build the trie once at import time, via the mtime-keyed disk cache (issue 05):
# on an unchanged which_key_spec.py the trie is deserialized from
# ~/.cache/which_key/which_key_trie.pickle instead of re-running build(SPEC), so
# repeated leader presses skip re-parsing. build is the injected build_fn; the
# spec module's __file__ is stat'd for the mtime key. The surrounding interface
# (_TRIE consumed by main()) is unchanged.
_TRIE = load_or_build(_spec_mod.__file__, _spec_mod.SPEC, build)

# Popup styling: key cells bold in the active theme's magenta (ANSI palette
# slot 5 via SGR 35), descriptions in the default foreground. Palette-indexed
# on purpose: kitty resolves the slot from the live theme, so switching themes
# (themes kitten / `kitty @ set-colors`) restyles the popup with no code or
# lookup here. Passed to layout() as a width-neutral (on, off) pair so the
# grid math never sees the escapes; off = bold off (22) + default fg (39).
_KEY_SGR = ("\x1b[1;35m", "\x1b[22;39m")


# --- interactive main (runs in the overlay subprocess, has a tty) ----------

def main(args):
    # kitty imports kept local so the module imports under plain python3.
    from kittens.tui.loop import Loop
    from kittens.tui.handler import Handler
    from kittens.tui.operations import clear_screen, set_cursor_visible

    class WhichKeyDriver(Handler):
        def __init__(self):
            super().__init__()
            # stack[0] is root, stack[-1] is the current node. The breadcrumb
            # tracks the group keys descended through, for the header line.
            self.stack = [_TRIE]
            self.breadcrumb = []
            self.action = ""
            # WAIT_FIRST until the deadline fires (or a fast key descends):
            # _shown is False, the popup has not been drawn. Once True we are
            # STICKY — no timer, every key goes straight through nav_step.
            self._shown = False
            self._timer_id = None
            # Snapshot of the underlying window's screen (list of ANSI row
            # strings) so the popup floats OVER the live terminal content like
            # nvim/Helix which-key instead of blanking the overlay. Captured in
            # a background thread started from initialize() so it overlaps the
            # WAIT_FIRST delay instead of adding to it; _bg_ready is set when
            # the thread finishes. [] = capture failed -> blank background.
            self._bg_lines = []
            self._bg_ready = None
            # Set once the chord has resolved (a leaf dispatched, Esc/Backspace
            # cancelled) and the loop is quitting — used to stop draining
            # spawn-window keys after one of them already ended the chord.
            self._done = False

        def initialize(self):
            _wk_test_log("t_init %.6f" % __import__("time").time())
            self.write(set_cursor_visible(False))
            self._start_background_capture()
            # Spawn-window guard (issue 07 / story 30): consume any key the user
            # typed before the overlay grabbed the tty. Honor it where it maps
            # to a real transition at this level; otherwise drop it rather than
            # misfire. This runs BEFORE the deadline is armed, so a fast
            # pre-buffered chord key takes the same invisible fast path a
            # normally-timed one would.
            self._drain_buffered_keys()
            if self._done or self._shown:
                # A honored buffered leaf already ended the chord, or a buffered
                # group key descended us into STICKY — no WAIT_FIRST deadline to
                # arm in either case.
                return
            # WAIT_FIRST: do NOT draw yet. Arm the deadline; if a known chord
            # key arrives first, _apply cancels this timer and takes the
            # invisible fast path. If the deadline fires, _on_deadline draws the
            # popup and we go STICKY. The deadline is BUDGET_S measured from
            # this process's start (see which_key_timing.remaining_delay), so
            # the ~150ms kitten spawn counts against it instead of stacking on
            # top; where /proc is unavailable fall back to DELAY_S from now.
            # kitty 0.47's TUI Handler is asyncio-based (there is no add_timer);
            # asyncio_loop.call_later schedules the callback on the SAME event
            # loop that drives on_key/on_text, so it runs cooperatively with
            # input — no concurrency. It returns a TimerHandle whose .cancel()
            # disarms it (see _cancel_timer).
            age = _process_age_s()
            delay = DELAY_S if age is None else remaining_delay(age)
            _wk_test_log("age %r delay %r" % (age, delay))
            self._timer_id = self.asyncio_loop.call_later(
                delay, self._on_deadline)

        # -- spawn-window buffered-key drain (issue 07) ---------------------
        def _drain_buffered_keys(self):
            # Pull any keys the Loop has already parsed from the spawn-window
            # race and run each through the PURE buffered_key_decision: HONOR a
            # bound key / explicit cancel via the normal _apply path, DROP an
            # unbound key silently (never mis-dispatch). Stop as soon as a
            # honored key descended (STICKY) or ended the chord.
            for key in self._take_pending_keys():
                decision, _ = buffered_key_decision(self.stack, key)
                if decision == HONOR:
                    self._apply(key)  # same path as a typed key (may quit)
                # DROP: discard silently.
                if self._done or self._shown:
                    break

        def _take_pending_keys(self):
            # Thin, version-guarded adapter over kitty's Loop input buffer: the
            # ONLY non-pure, platform-dependent seam here. kitty 0.47 ships its
            # tui as a compiled module with no stable public accessor for
            # already-parsed-but-undelivered input, and where the platform has
            # already discarded the spawn-window byte there is nothing to read.
            # Both cases degrade to the "otherwise dropped" path the AC permits,
            # so this returns [] defensively. All HONOR/DROP *decision* logic
            # lives in the pure buffered_key_decision, which is unit-tested; if a
            # future kitty exposes a safe accessor, only this method changes.
            return []

        # -- timing (WAIT_FIRST deadline) -----------------------------------
        def _on_deadline(self):
            # The level-1 deadline elapsed with no key -> SHOW: draw the popup
            # and become STICKY. Idempotent: if a key already resolved the
            # chord (fast path), _shown is True and we do nothing.
            if self._shown:
                return
            self._timer_id = None
            self._shown = True  # enter STICKY
            self.draw()

        def _cancel_timer(self):
            # Disarm the WAIT_FIRST deadline (a key arrived first). The asyncio
            # TimerHandle's .cancel() is idempotent and safe even if the timer
            # already fired; guarded so a missing handle is safe too.
            if self._timer_id is not None:
                try:
                    self._timer_id.cancel()
                except Exception:
                    pass
                self._timer_id = None

        # -- rendering ------------------------------------------------------
        def _dimensions(self):
            # (rows, cols) of the overlay window. kitty 0.47 exposes the size as
            # self.screen_size, a ScreenSize with .rows/.cols (NOT .columns —
            # accessing .columns raises AttributeError, which previously dropped
            # us into the fallback: width 80 and a top-anchored band). It can
            # still read 0 before the first resize event, so fall back to the
            # controlling tty, then a 24x80 default. Used for BOTH the grid width
            # and the bottom-anchor row math so they always agree.
            try:
                ss = self.screen_size
                if ss.rows and ss.cols:
                    return ss.rows, ss.cols
            except Exception:
                pass
            import os
            for fd in (1, 2, 0):
                try:
                    ts = os.get_terminal_size(fd)
                    if ts.lines and ts.columns:
                        return ts.lines, ts.columns
                except Exception:
                    pass
            return 24, 80

        def _term_width(self):
            # Grid width in columns (see _dimensions for the size sourcing).
            return self._dimensions()[1]

        def _start_background_capture(self):
            # Snapshot the UNDERLYING window's screen so the popup can float over
            # the live terminal content (nvim/Helix look) instead of blanking the
            # opaque overlay. A kitten overlay is a separate opaque kitty window —
            # kitty never blends it with the window beneath — so the only way to
            # "see through" is to repaint a copy of that window's cells here.
            #
            # `state:overlay_parent` matches the window THIS overlay sits over —
            # the window the leader was pressed in — deterministically, via the
            # overlay relationship (kitty knows `self` from KITTY_WINDOW_ID). Do
            # NOT use `recent:N`: that tracks the most-recently-active window in
            # the focused os-window, so it resolves to whatever is focused, not
            # our parent (verified: recent:1 grabbed an unrelated window).
            # ansi preserves SGR colors, extent=screen returns exactly the
            # visible rows.
            #
            # Runs in a daemon thread so the socket roundtrip (~10ms, plus
            # focus-settle retries: state:overlay_parent only resolves once
            # kitty has focused this overlay, which can lag the spawn) overlaps
            # the WAIT_FIRST delay. draw() waits on _bg_ready with a bound.
            # Best-effort: any failure leaves _bg_lines == [] -> blank background.
            import threading
            import time
            self._bg_ready = threading.Event()

            def capture():
                rows = []
                t0 = time.time()
                for _attempt in range(8):
                    resp = _rc("get-text", {"match": "state:overlay_parent",
                                            "ansi": True, "extent": "screen"})
                    if resp is None:
                        break  # transport failure: retrying cannot help
                    if resp.get("ok") and resp.get("data"):
                        # One row per newline; drop a trailing empty split.
                        rows = resp["data"].split("\n")
                        if rows and rows[-1] == "":
                            rows.pop()
                        break
                    # Typically "No matching windows": kitty has not focused
                    # this overlay yet, so state:overlay_parent is unresolvable.
                    time.sleep(0.02)
                _wk_test_log("capture rows=%d attempts=%d %.1fms" % (
                    len(rows), _attempt + 1, (time.time() - t0) * 1000))
                self._bg_lines = rows
                self._bg_ready.set()

            threading.Thread(target=capture, daemon=True).start()

        def draw(self):
            """Paint a snapshot of the underlying window as the background, then
            draw the which-key band anchored at the bottom over it: a breadcrumb
            header (if descended) followed by the wcwidth-aware multi-column grid
            block, last line on the bottom row. The band rows are cleared first
            so the snapshot never bleeds through them."""
            node = self.stack[-1]
            total_rows, total_cols = self._dimensions()
            # Keys bold (SGR 1 / 22 = bold off), descriptions in normal weight.
            block = layout(entries(node), total_cols, key_sgr=_KEY_SGR)

            # Band: a full-width rule separates the snapshot from the header +
            # entries, so the popup reads as a distinct panel at the bottom.
            band = ["─" * total_cols]
            if self.breadcrumb:
                trail = " ".join(display_key(k) for k in self.breadcrumb)
                band.append("which-key: %s" % trail)
            else:
                band.append("which-key")
            band.extend(block)

            self.write(clear_screen())

            # Background snapshot: paint the captured rows top-down. Normally
            # the capture thread finished during the WAIT_FIRST delay; bound the
            # wait so a dead socket can only cost a blank background, never a
            # hung popup. Reset SGR after each row so a trailing color can't
            # tint the next row or the band.
            if self._bg_ready is not None:
                self._bg_ready.wait(0.3)
            for i, line in enumerate(self._bg_lines[:total_rows]):
                self.write("\x1b[%d;1H" % (i + 1))
                self.write(line)
                self.write("\x1b[0m")

            # Anchor so the last band line sits on the bottom row of the window.
            top = max(0, total_rows - len(band))
            self.write("\x1b[0m")
            for offset, text in enumerate(band):
                row = top + offset + 1  # 1-based for the cursor move op
                self.write("\x1b[%d;1H" % row)  # CSI row;1 H -> move cursor
                self.write("\x1b[2K")           # clear row: drop snapshot beneath
                self.write(text)
            _wk_test_log("t_draw %.6f" % __import__("time").time())

        # -- input ----------------------------------------------------------
        def on_text(self, text, in_bracketed_paste=False):
            # Plain printable typed with no modifier kitty surfaces here.
            # on_key is the primary path (it can resolve shifted/named keys via
            # resolve_key); this stays as a glyph fallback for plain text.
            self._apply(char_to_key(text))

        def on_key(self, key_event):
            if key_event.matches("esc"):
                self._apply(KEY_ESC)
            elif key_event.matches("backspace"):
                self._apply(KEY_BACKSPACE)
            else:
                # Resolve the live key-event against the key names valid at the
                # CURRENT node. resolve_key tries key_event.matches(candidate)
                # first (handles shift+h, slash, shift+slash, plain letters),
                # then falls back to char_to_key(key_event.text) (| -> bar,
                # - -> minus). An empty result means nothing resolved — a
                # function/arrow/modifier key — which _apply treats as
                # STAY/no-op (popup stays open).
                candidates = self.stack[-1].order
                resolved = resolve_key(
                    candidates, key_event.matches, key_event.text
                )
                if resolved:
                    self._apply(resolved)

        def _apply(self, key):
            # WAIT_FIRST: this key arrived before the 100ms deadline -> fast
            # path. Per the timing core, a fast Descend goes STICKY (level 2+
            # has no delay) and draws immediately; a fast leaf Dispatch / Esc
            # cancel ends the chord with the popup NEVER drawn (no flash); an
            # unbound key (STAY) is a mis-type that leaves the deadline armed so
            # the popup still appears at 100ms. This mirrors which_key_timing.run.
            if not self._shown:
                result = nav_step(self.stack, key)
                if isinstance(result, Descend):
                    self._cancel_timer()
                    self._shown = True  # enter STICKY
                    self.stack.append(result.node)
                    self.breadcrumb.append(key)
                    self.draw()
                elif isinstance(result, Dispatch):
                    self._cancel_timer()
                    self.action = result.action
                    self._done = True
                    self.quit_loop(0)
                elif result is CANCEL:
                    self._cancel_timer()
                    self.action = ""
                    self._done = True
                    self.quit_loop(0)
                else:
                    # STAY (unbound mis-type) or Pop (cannot happen at root):
                    # leave the deadline armed; the popup still shows at 100ms.
                    pass
                return

            # STICKY: no timer involvement; behaves exactly as issue 03.
            result = nav_step(self.stack, key)
            if isinstance(result, Descend):
                self.stack.append(result.node)
                self.breadcrumb.append(key)
                self.draw()
            elif isinstance(result, Pop):
                self.stack.pop()
                if self.breadcrumb:
                    self.breadcrumb.pop()
                self.draw()
            elif isinstance(result, Dispatch):
                self.action = result.action
                self._done = True
                self.quit_loop(0)
            elif result is CANCEL:
                self.action = ""
                self._done = True
                self.quit_loop(0)
            elif result is STAY:
                # Unbound key while the popup is the active surface: ring an
                # optional soft bell and leave the popup open (issue 07). NOTE:
                # the bell fires only here in STICKY, never on the WAIT_FIRST
                # fast-path STAY above — a fast mis-type before the 100ms
                # deadline stays silent because the popup may yet appear and the
                # keystroke is about to be reconsidered; a beep belongs only
                # once the popup is the surface the user is acting against.
                self._soft_bell()

        def _soft_bell(self):
            # Optional soft bell on an unbound key; the popup stays open either
            # way. Gated by the single SOFT_BELL policy constant in
            # which_key_nav (the emission itself is terminal-interactive and
            # verified manually).
            if SOFT_BELL:
                self.write(BEL)

        def on_interrupt(self):
            self.action = ""
            self._done = True
            self.quit_loop(0)

        def on_eot(self):
            self.action = ""
            self._done = True
            self.quit_loop(0)

    loop = Loop()
    handler = WhichKeyDriver()
    loop.loop(handler)
    # Dispatch the chosen action HERE, in the overlay subprocess, while the
    # overlay window is still alive — NOT by returning it for handle_result.
    # handle_result runs during overlay teardown, when kitty's `launch` action
    # chokes resolving the now-dead active window (a KeyError on its weakref);
    # the map form `launch --type=overlay kitten ...` does not invoke
    # handle_result at all. Dispatching from here against the parent window by
    # explicit id is the path verified to actually perform the action. Return
    # "" so handle_result (if a future kitty ever calls it) is a clean no-op.
    if handler.action:
        _dispatch_action(handler.action)
    return ""


# --- impure helpers (run in the overlay subprocess) -------------------------

def _process_age_s():
    """Seconds since this process was forked, from Linux /proc (starttime is
    stamped at fork, i.e. essentially at the leader keypress). None where
    /proc is unavailable or unparsable; the caller then falls back to DELAY_S."""
    import os
    try:
        with open("/proc/self/stat") as fh:
            stat = fh.read()
        with open("/proc/uptime") as fh:
            uptime = float(fh.read().split()[0])
        # Fields after the ")" that closes comm start at field 3; starttime is
        # field 22 -> index 19.
        start_ticks = int(stat[stat.rindex(")") + 2:].split()[19])
        return uptime - start_ticks / os.sysconf("SC_CLK_TCK")
    except Exception:
        return None


def _rc(cmd, payload, timeout=0.3):
    """One kitty remote-control roundtrip straight over the listen socket,
    bypassing a `kitty @` subprocess (~50ms spawn) and kitty.remote_control
    (~50ms import). Speaks the documented wire frame
    `ESC P @kitty-cmd <json> ESC \\`; the response uses the same framing.
    Returns the decoded response dict, or None on any failure (no socket in
    the environment, connect/timeout error, malformed reply)."""
    import json
    import os
    import socket
    addr = os.environ.get("KITTY_LISTEN_ON", "")
    if not addr.startswith("unix:"):
        return None
    try:
        from kitty.constants import version
    except Exception:
        return None
    path = addr[len("unix:"):]
    if path.startswith("@"):  # abstract socket namespace
        path = "\0" + path[1:]
    # kitty_window_id tells kitty which window is "self" — without it,
    # self-relative matches like state:overlay_parent resolve to nothing.
    cmd_obj = {"cmd": cmd, "version": list(version), "payload": payload}
    try:
        cmd_obj["kitty_window_id"] = int(os.environ["KITTY_WINDOW_ID"])
    except (KeyError, ValueError):
        pass
    prefix = b"\x1bP@kitty-cmd"
    frame = prefix + json.dumps(cmd_obj).encode("utf-8") + b"\x1b\\"
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(timeout)
            s.connect(path)
            s.sendall(frame)
            buf = b""
            while not buf.endswith(b"\x1b\\"):
                chunk = s.recv(1 << 16)
                if not chunk:
                    break
                buf += chunk
        if not buf.startswith(prefix):
            return None
        return json.loads(buf[len(prefix):-2])
    except Exception:
        return None


# --- impure dispatch (runs in the overlay subprocess) ----------------------

def _dispatch_action(action):
    """Run the chosen chord's action against the window the leader was pressed
    in. Called from main() right after the loop ends. Steps:
      1. resolve the overlay's parent window id (state:overlay_parent) NOW, while
         this overlay is still alive and the relationship resolves, then
      2. dispatch `kitty @ action -m id:<parent> <action...>` from a short-delayed
         DETACHED process, so it runs AFTER this overlay has torn down.

    The delay+detach is essential, not cosmetic: window-manipulation actions
    (close_window, close_tab, move_window, neighboring_window) resolve against
    the topmost window at the parent's slot. While the overlay is up, THAT is the
    overlay itself — so a synchronous close_window would close the overlay, not
    the user's window. Dispatching once the overlay is gone targets the real
    parent cleanly. The parent is matched by concrete id because kitty's action
    window-matching no-ops on the `state:overlay_parent` selector but works on an
    id. Best-effort — any failure leaves the chord a silent no-op."""
    import os
    import json
    import shlex
    import subprocess
    import time
    try:
        from kitty.constants import kitty_exe
        exe = kitty_exe()
    except Exception:
        exe = "kitty"
    try:
        # Resolve the overlay's parent window id. `state:overlay_parent` is
        # FOCUS-DEPENDENT in kitty 0.47: it only resolves while this overlay is
        # the focused window, and returns NO matching windows (empty stdout,
        # rc=1) otherwise — at which point json.loads("") would raise and the
        # chord would silently no-op. The dangerous window is the FAST PATH:
        # `ctrl+space` then a chord key typed within 100ms can quit the loop and
        # reach here BEFORE kitty's GUI loop has finished applying focus to the
        # freshly-launched overlay, so the very first lookup comes back empty.
        # Retry a few times with a short sleep to let focus settle; each attempt
        # tolerates empty/garbage stdout instead of crashing on it.
        ids = []
        for _attempt in range(6):
            ls = subprocess.run(
                [exe, "@", "ls", "-m", "state:overlay_parent"],
                capture_output=True, text=True, timeout=2, env=os.environ,
            )
            try:
                ids = [w["id"] for osw in json.loads(ls.stdout)
                       for tab in osw["tabs"] for w in tab["windows"]]
            except Exception:
                ids = []  # empty/non-JSON stdout (overlay not yet focused)
            if ids:
                break
            time.sleep(0.02)
        _wk_test_log("resolved action=%r parent_ids=%s attempts=%d"
                     % (action, ids, _attempt + 1))
        if not ids:
            return
        # `kitty @ action <name>` runs the mappable action on the ACTIVE window
        # and ignores -m (verified: `action -m id:X close_window` closes the
        # focused window, not X). So focus the parent FIRST, then run the action
        # on it. focus-window DOES honor --match. In normal use focus is already
        # on the parent once the overlay closes, so the focus step is a no-op;
        # it just makes targeting deterministic.
        focus = [exe, "@", "focus-window", "--match", "id:%d" % ids[0]]
        act = [exe, "@", "action", *action.split()]
        # Detached so it outlives this kitten; the short sleep lets the overlay
        # close first. start_new_session detaches from our process group.
        inner = "sleep 0.2; %s; %s" % (
            " ".join(shlex.quote(c) for c in focus),
            " ".join(shlex.quote(c) for c in act),
        )
        if os.environ.get("WK_TEST_LOG"):
            q = shlex.quote(os.environ["WK_TEST_LOG"])
            inner = "sleep 0.2; %s; %s >>%s 2>&1; echo dispatched-detached >>%s" % (
                " ".join(shlex.quote(c) for c in focus),
                " ".join(shlex.quote(c) for c in act), q, q)
        subprocess.Popen(
            ["sh", "-c", inner], start_new_session=True, env=os.environ,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        _wk_test_log("EXC %r" % e)


def _wk_test_log(msg):
    # Opt-in test hook: only writes when the WK_TEST_LOG env var names a file
    # (set by the e2e test harness via `launch --env`). No-op in normal use.
    import os
    path = os.environ.get("WK_TEST_LOG")
    if not path:
        return
    try:
        with open(path, "a") as fh:
            fh.write(msg + "\n")
    except Exception:
        pass


# handle_result must still exist + carry kitty's result-handler marker for the
# kitten framework, but the action is already dispatched in main(); this stays a
# no-op (and is not even invoked by the launch-overlay map form). The decorator
# lives in kittens.tui.handler, importable ONLY inside the kitty runtime, so we
# apply it lazily — the module still imports under plain python3 for the tests.

def handle_result(args, answer, target_window_id, boss):
    return  # action dispatched in main(); nothing to do here


try:  # only succeeds inside the kitty runtime
    from kittens.tui.handler import result_handler
    handle_result = result_handler(no_ui=False)(handle_result)
except ImportError:
    pass


if __name__ == "__main__":
    main([])
