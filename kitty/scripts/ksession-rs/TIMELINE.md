#: 5.5
Step: shell hooks + adapter::shell user_vars precedence [C.2]
Est.: ~0.5d
Notes: Bash/zsh ksession-shell-hook.sh + nvim VimEnter Lua snippet that emit OSC 1337 SetUserVar;
adapter::shell reads ctx.kitty_window.user_varsfirst, /proc fallback. The lookup_env helper landed
in
Step 5 already has the slot. Saves 5-15ms/shell + ~20-50ms/nvim per save.
────────────────────────────────────────

# 6

Step: nvim_rpc + adapter::nvim
Est.: ~2d
Notes: Critical path. socket_for_pid 4-tier discovery, NvimConn::{connect, mksession,
dump_modified_buffers} over persistent RPC, JSON manifest sidecar + Lua loader
(ksession_restore.lua).
Eliminates the bash polling loop.
────────────────────────────────────────
#: 6.5
Step: kitty/rpc.rs — direct DCS socket client [B.3.1]
Est.: ~1d
Notes: Replaces the subprocess kitty @ ls shellout with direct DCS socket transport. Big perf win +
pipelining (no_response).
────────────────────────────────────────
#: 6.75
Step: conf rewrite via ls --output-format=session[C.1]
Est.: 1d
Notes: Deletes 150 LOC of from-scratch render — replaces it with parse-then-patch. Picks up exact
split
geometry via set_layout_state. Wires UUID tagging into conf output via `--var=ksession_id=<uuid>`
[C.3 conf side]; the live `set-user-vars` RC writes are performed by `session::tag_windows_uuids`
and called from the save orchestration in Step 8. Gated on 6.5.
────────────────────────────────────────
#: 7
Step: tmux_rpc + adapter::tmux
Est.: 2d
Notes: Critical path. Field-per-call interrogation, restore.sh codegen with shell-escape,
KSESSION_FORCE
collision semantics, recursive pane→registry dispatch (uses ctx.registry from Step 5).
────────────────────────────────────────
#: 7.5
Step: tmux/control.rs [B.3.2]
Est.: 1.5d
Notes: Direct tmux -C (control mode) socket transport. Like 6.5 but for tmux.
────────────────────────────────────────
#: 8
Step: session::save orchestration [B.2]
Est.: 1d
Notes: Phase 1-4 wiring per §5.7, flat join_all fan-out, fsx::write_atomic for .conf + manifest.
────────────────────────────────────────
#: 9
Step: cli + clap subcommands  
 Est.: 0.5d
Notes: save, restore, list, show, rm. Restore is mostly kitty --detach --session <conf> exec.
────────────────────────────────────────
#: 10
Step: Diff runner + regression suite
Est.: 1d
Notes: Port every known bash bug as a regression test.
────────────────────────────────────────
#: 11
Step: Patch ksession-save-prompt.sh with KSESSION_IMPL env var
Est.: 0.5d
Notes: Shadow-mode trial against the bash version.

Total remaining: ~11 dev days. Critical path is steps 6 + 7 (the RPC-heavy ones).

The starred steps (5.5*, 6.5*, 7.5\*) are Appendix-C/B perf-and-correctness additions inserted into the
original §10 order — all additive (the port workswithout them) but each delivers measurable wins.

Logical next moves:

- 5.5 is the smallest unit, additive, and unlocksreal wall-clock savings now that adapter::shell
  exists
- 6 is the critical-path nvim work that everything downstream depends on
- Going 5.5 → 6 → 6.5 → 6.75 → 7 → 7.5 → 8 → 9 → 10 → 11 in order matches the plan's gating
