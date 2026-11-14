# Restore Latency Baseline — W5_mixed (2 OS windows, 3 tabs, nvim+tmux+shell)

## Methodology

- Workload: W5_mixed (2 OS windows, 3 tabs, nvim+tmux+shell)
- Iterations: 30 (first discarded as warm-up)
- Hardware: AMD Ryzen 7 4800H with Radeon Graphics, 65191648 kB
- kitty: kitty 0.47.0 created by Kovid Goyal
- nvim: NVIM v0.12.2
- tmux: tmux 3.4

## Results

| Span | p50 (ms) | p95 (ms) | min (ms) | max (ms) | stddev (ms) | count | contribution % |
|------|----------|----------|----------|----------|-------------|-------|----------------|
| **restore.dispatch** | 4.5 | 5.1 | 2.1 | 5.2 | 1.0 | 30 | 100.0% |
| **kitty.launch** | 0.2 | 0.2 | 0.1 | 0.2 | 0.0 | 30 | 3.9% |
| **nvim.spawn** | 0.1 | 0.1 | 0.1 | 0.1 | 0.0 | 30 | 2.7% |
| **tmux.restore** | 0.1 | 0.1 | 0.1 | 0.1 | 0.0 | 30 | 2.6% |
| **tmux.spawn** | 0.1 | 0.1 | 0.1 | 0.1 | 0.0 | 30 | 2.6% |
| nvim.source_session | 0.1 | 0.1 | 0.1 | 0.1 | 0.0 | 30 | 2.6% |
| restore.sweep_orphans | 0.0 | 0.1 | 0.0 | 0.1 | 0.0 | 30 | 0.9% |
| ready.wait | 0.0 | 0.0 | 0.0 | 0.1 | 0.0 | 30 | 0.6% |
