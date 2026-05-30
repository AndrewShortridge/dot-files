Already Implemented (6)

┌──────┬───────────────────────────┬───────────────────────────────────────────────────────────────┐
│ PRD │ Title │ Status │
├──────┼───────────────────────────┼───────────────────────────────────────────────────────────────┤
│ 0001 │ V1 Finish Line │ DONE — all 17 user stories implemented and tested │
├──────┼───────────────────────────┼───────────────────────────────────────────────────────────────┤
│ 0002 │ Observability │ DONE — full chrome-trace layer, L0–L5 spans, ksession trace │
│ │ Infrastructure │ CLI │
├──────┼───────────────────────────┼───────────────────────────────────────────────────────────────┤
│ 0004 │ Tmux Control Mode │ DONE — persistent tmux -C attach pipe, protocol parsing, │
│ │ │ concurrent demux │
├──────┼───────────────────────────┼───────────────────────────────────────────────────────────────┤
│ 0005 │ Kitty RC Connection Pool │ DONE — N-way pool, pre-spawn, three-way concurrent discover │
├──────┼───────────────────────────┼───────────────────────────────────────────────────────────────┤
│ 0006 │ Pre-Spawn Kitty LS │ DONE — merged into PRD-0005, pre-spawn thread overlaps clap │
│ │ │ parsing │
├──────┼───────────────────────────┼───────────────────────────────────────────────────────────────┤
│ 0009 │ Mimalloc │ NOT STARTED — but this is a 2-line change, not really │
│ │ │ "remaining work" │
└──────┴───────────────────────────┴───────────────────────────────────────────────────────────────┘

Needs Implementation (9)

┌───────┬────────────────────┬──────────┬──────────────────────────────────────────────────────────┐
│ PRD │ Title │ Status │ Notes │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ │ Restore │ NOT │ No baseline test, no fixtures (W1-W5), no findings doc. │
│ 0003 │ Measurement Deep │ STARTED │ ~20% ready (tracing infra exists). Blocks PRD-0011. │
│ │ Dive │ │ │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ 0007 │ Proc Cache │ NOT │ No ProcCache struct, no ProcField enum, no WindowCtx │
│ │ │ STARTED │ integration. Adapters still read /proc directly. │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ 0008 │ Parallel Nvim │ NOT │ Still sequential for loop in nvim_rpc/conn.rs. │
│ │ Buffer Dumps │ STARTED │ Conditional on PRD-0002 data showing a win. │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ 0009 │ Mimalloc │ NOT │ 2-line change (Cargo.toml + #[global_allocator]), but │
│ │ │ STARTED │ needs validation of >= 0.5ms p50 improvement. │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ │ │ PARTIAL │ Watcher, nvim plugin, and cache-read path done. Blocker: │
│ 0010 │ Nvim Watcher Cache │ (~85%) │ save orchestration never sets ksession_cache_path │
│ │ │ │ user-var, so watcher can't write cache files. │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ │ Restore │ NOT │ Placeholder reserving slots 0012-0014. Blocked on │
│ 0011 │ Optimizations │ STARTED │ PRD-0003 findings. │
│ │ Placeholder │ │ │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ 0012a │ Parallel Tmux │ NOT │ Restore still generates serial bash scripts. No │
│ │ Restore │ STARTED │ tmux_restore module. │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ 0012b │ Save-Prompt │ NOT │ No instrumentation in ksession-save-prompt.sh, no │
│ │ Overlay Latency │ STARTED │ findings doc, no tests. │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ │ Skip Unmodified │ │ Capture side done (modified field in BufferDump). │
│ 0013 │ Nvim Buffers │ PARTIAL │ Restore Lua loader still unconditionally reloads all │
│ │ │ │ buffers. │
├───────┼────────────────────┼──────────┼──────────────────────────────────────────────────────────┤
│ 0014 │ Skip Orphan Sweep │ NOT │ restore.rs unconditionally sweeps. No threshold, no │
│ │ │ STARTED │ maybe_sweep_orphans(), no spans. │
└───────┴────────────────────┴──────────┴──────────────────────────────────────────────────────────┘

Summary

6 done, 2 partial, 7 not started. The critical path is:

1. PRD-0003 (restore measurement) — unblocks the restore optimization PRDs (0011, 0012a, 0014)
2. PRD-0010 (nvim watcher cache) — 85% done, just needs the set_user_vars bridge in save orchestration
3. PRD-0013 (skip unmodified buffers) — capture side done, needs the Lua restore-side skip logic
