# Partial captures degrade silently instead of aborting the save

`ksession-rs save` is invoked interactively from a kitty keybinding via the
`ksession-save-prompt.sh` fzf overlay. RUST_PORT_PLAN.md §5.7 F#18 originally
specified that when `degraded > max(1, total / 4)` (any nvim/tmux adapter
failure on small sessions, or ≥25% degraded on large ones), `session::save`
returns `KError::PartialCapture`, the `StateTmpdir` Drop guard `rm -rf`s the
state dir, and no `.conf` is written.

We diverge from the plan: the threshold is no longer enforced. Every save
that produces *any* surviving windows commits. Each degraded window is
written as `Program::BareShell` in the manifest, every `AdapterError` is
emitted to stderr, and the process exits non-zero (code 2) so
`ksession-save-prompt.sh` can surface "saved with N degradations" to the
user.

The plan's worry about silently masking data loss assumes a batched or
scripted save context. For an interactive one-shot tool, throwing away the
user's typed session name because two of four nvim sockets timed out is
worse than committing a partial save the user can audit via `ksession show`
and re-run if unsatisfied. `KError::PartialCapture` is removed from the
error enum.
