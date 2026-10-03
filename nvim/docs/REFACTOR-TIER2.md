# Refactor Tier 2 — Highlight-Helper Extraction

## Summary

Tier-2 consolidates the repeated `nvim_buf_set_extmark` highlight pattern that
was duplicated inline across the vault UI modules into a single shared helper,
`lua/andrew/vault/hl_util.lua`. Every call site builds the **same** opts table
via `build_opts()`, so the resulting extmark options are byte-identical to the
inline tables they replaced. Each caller still passes its **own** namespace —
namespaces are never merged.

## `hl_util.lua` API

| Function | Signature | Behavior |
| --- | --- | --- |
| `M.add` | `add(buf, ns, group, row, col_start, col_end, extra?)` | Applies a highlight extmark raw; errors propagate as with a direct API call. Returns `extmark_id`. |
| `M.add_safe` | `add_safe(buf, ns, group, row, col_start, col_end, extra?)` | `pcall`-wrapped variant for sites that guarded the call. Returns `(ok, result)` so callers keep their own error logging. |

Both delegate to the private `build_opts(group, row, col_end, extra)`, which
reproduces the original inline conditional exactly:

- **RANGE** (`col_end ~= -1`): `{ end_row = row, end_col = col_end, hl_group = group }`
- **WHOLE-LINE** (`col_end == -1`): `{ end_row = row + 1, end_col = 0, hl_group = group }`

The optional `extra` table is merged in for forward-compatibility (unused today).

## Call Sites Routed Through `hl_util`

**11 call sites across 8 modules:**

| Module | Call sites |
| --- | --- |
| `vault_index_collisions.lua` | 2 |
| `task_kanban.lua` | 2 |
| `ui.lua` | 2 |
| `graph.lua` | 1 |
| `graph/search_graph.lua` | 1 |
| `task_hierarchy.lua` | 1 |
| `task_timeline.lua` | 1 |
| `stats.lua` | 1 |

## Confirmation

| Check | Status |
| --- | --- |
| v1 confirmation | passed |
| v2 confirmation | passed |
| End-to-end confirmation | passed |

- **Attempts:** 1
- All confirmation passes were clean on the first attempt; no re-work required.

## Final Suite Result

**928 passed, 0 failed across 19 specs.**
