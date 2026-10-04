# Stamp kitty version into the manifest for restore-time diagnostics

The conf-patcher round-trips kitty's `set_layout_state <base64>` directive
verbatim per RUST_PORT_PLAN.md §C.1. Kitty's own docs label this directive
"for internal use only" and we have no contract that the encoding is stable
across releases. Decoding it ourselves would resurrect ~150 LOC of
from-scratch layout rendering the plan deliberately deleted; dual-writing
both `set_layout_state` and a from-scratch `layout` directive risks
two-sources-of-truth bugs.

We instead capture `kitty --version` at save time into `manifest.json`'s
new `kitty_version` field. `list`/`show`/`restore` compare the captured
version against the currently running kitty's major.minor and emit a CLI
warning when they differ. The restore itself proceeds unchanged — this is
a diagnostic, not a gate. The cost is ~10 LOC; the win is that a silently
broken `set_layout_state` after a kitty upgrade comes with a visible
"saved on kitty 0.42, running on 0.43 — restore may behave unexpectedly"
warning the user can correlate with weird tab layouts.

`kitty_version` is captured as `String` to round-trip whatever `kitty
--version` emits, including dev-build suffixes (`kitty 0.42.1-rc1`).
Comparison is on the parsed major.minor pair; patch versions are ignored.
