# Improvement Dependency Graph (36–41)

## Visual Dependency Graph

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 1                              │
                    │              Independent Refactoring                    │
                    │                                                         │
                    │  ┌──────────────┐                                       │
                    │  │ #39 Slug     │  Zero-dep leaf module extraction      │
                    │  │ Dedup        │  Enables cleaner base for all others  │
                    │  │   [Small]    │                                       │
                    │  └──────────────┘                                       │
                    └─────────────────────────────────────────────────────────┘

                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 2                              │
                    │         Core Resolution & Embed Improvements            │
                    │         (share wikilinks.resolve_link pipeline)         │
                    │                                                         │
                    │  ┌──────────────┐       ┌──────────────┐               │
                    │  │ #38 Relative │       │ #36 Embed    │               │
                    │  │ Path Embeds  │       │ Cycle/Depth  │               │
                    │  │   [Medium]   │       │   [Medium]   │               │
                    │  └──────┬───────┘       └──────┬───────┘               │
                    │         │                       │                       │
                    │     modifies              modifies                      │
                    │   resolve_link()         embed.lua                      │
                    │         │                       │                       │
                    │  ┌──────┴───────┐               │                      │
                    │  │ #37 Temporal │               │                      │
                    │  │ Aliases      │  ◄── benefits from #38's             │
                    │  │   [Medium]   │      resolve_link() changes          │
                    │  └──────────────┘               │                      │
                    │         │                       │                      │
                    │     modifies                    │                      │
                    │   resolve_link()                │                      │
                    │         │                       │                      │
                    │         └───── both enhance ────┘                      │
                    │               resolve_link() pipeline                   │
                    │               (#36 consumes it via resolve_embed)       │
                    └─────────────────────────────────────────────────────────┘

                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 3                              │
                    │            Index Quality & Graph Visualization          │
                    │            (independent from Phase 2)                   │
                    │                                                         │
                    │  ┌──────────────┐       ┌──────────────┐               │
                    │  │ #40 Alias    │       │ #41 Unresolvd│               │
                    │  │ Collision    │       │ Graph Nodes  │               │
                    │  │ Warnings     │       │   [Medium]   │               │
                    │  │   [Small]    │       └──────────────┘               │
                    │  └──────────────┘        synergizes with               │
                    │   vault_index.lua        #37 + #38 (fewer              │
                    │   only                   unresolved links)              │
                    └─────────────────────────────────────────────────────────┘
```

### Resolution Pipeline After All Improvements

```
  [[link_name]]  or  ![[link_name]]
        │
        ▼
  ┌─ is_path_like(name)?  (#38) ──────────────┐
  │   starts with ./ or ../ or contains /      │
  │        │ YES                               │ NO
  │        ▼                                   │
  │   resolve_relative(name, bufnr)            │
  │        │                                   │
  │   ┌────┴────┐                              │
  │   │ Found?  │                              │
  │   │ YES → ◉ │  (return abs path)          │
  │   │ NO  → ──┼──────────────────────────────┤
  │   └─────────┘                              │
  │                                            ▼
  │                              vault_index:resolve_name(name)
  │                                     │
  │                               ┌─────┴─────┐
  │                               │  Found?   │
  │                               │  YES → ◉  │  pick_closest()
  │                               │  NO  → ───┼──────────┐
  │                               └───────────┘          │
  │                                                      ▼
  │                                        resolve_temporal(name)  (#37)
  │                                               │
  │                                         ┌─────┴─────┐
  │                                         │  Match?   │
  │                                         │  YES → ◉  │  daily log path
  │                                         │  NO  → nil│  (trigger create)
  │                                         └───────────┘
  │
  │  If embed (![[...]]):
  │        │
  │        ▼
  │   resolve_embed_lines()  (#36)
  │     ├─ depth > max_depth?  → "⋯ (max embed depth)"
  │     ├─ path in visited?    → "↻ cycle: A → B → A"
  │     └─ recurse into nested ![[...]] patterns
  └────────────────────────────────────────────────────────
```

---

## Shared File Conflict Matrix

| Shared File | #36 | #37 | #38 | #39 | #40 | #41 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `lua/andrew/vault/wikilinks.lua` | | **W** | **W** | | | |
| `lua/andrew/vault/embed.lua` | **W** | | | | | |
| `lua/andrew/vault/config.lua` | W | W | | | W | |
| `lua/andrew/vault/vault_index.lua` | | | | W | **W** | |
| `lua/andrew/vault/link_utils.lua` | | | | W | | |
| `lua/andrew/vault/graph.lua` | | | | | | **W** |
| `lua/andrew/vault/navigate.lua` | | W | | | | |
| `lua/andrew/vault/init.lua` | | | | | W | |
| `lua/andrew/vault/slug.lua` | | | | **C** | | |

**W** = writes/modifies, **C** = creates, **bold** = primary target

### Key Conflicts

| Files | Improvements | Risk | Resolution |
|-------|-------------|------|------------|
| `wikilinks.lua` | **#37 + #38** | **Medium** | Both modify `resolve_link()`. #38 adds path detection at top, #37 adds temporal fallback at bottom. Apply #38 first, then #37 layers underneath. |
| `config.lua` | #36 + #37 + #40 | **Low** | Each adds a separate config section (`embed.max_depth`, `temporal_aliases`, `index.warn_collisions`). No overlapping keys. |
| `vault_index.lua` | #39 + #40 | **Low** | #39 adds a require + replaces local function. #40 adds methods after `_rebuild_name_index()`. Non-overlapping regions. |

---

## Per-Improvement Detail

### #36 — Transclusion Cycle & Depth Detection `[Medium]`
- **Creates:** Nothing new (modifies existing)
- **Modifies:** `embed.lua`, `config.lua`
- **Hard deps:** None
- **Soft deps:** Benefits from #37 + #38 (recursive embeds resolve temporal/relative links)
- **Builds on:** Existing `render_embeds()`, `get_embed_content()`, `resolve_embed()`
- **Risk:** Low (additive change; cycle detection is defensive)

### #37 — Temporal Wikilink Aliases `[Medium]`
- **Creates:** Nothing new
- **Modifies:** `wikilinks.lua`, `config.lua`, `navigate.lua`
- **Hard deps:** None
- **Soft deps:** Apply after #38 if both are implemented (coordinated `resolve_link()` modification)
- **Builds on:** `navigate.open_daily()`, `engine.date_offset()`, vault index resolution
- **Risk:** Low (fallback-only; real files always take priority)

### #38 — Relative Path Resolution `[Medium]`
- **Creates:** Nothing new
- **Modifies:** `wikilinks.lua`
- **Hard deps:** None
- **Soft deps:** Apply before #37 (both modify `resolve_link()`)
- **Builds on:** `resolve_link()`, `vim.fs.normalize()`
- **Risk:** Low (early-exit pattern; non-path-like names skip entirely)

### #39 — Deduplicate heading_to_slug `[Small]`
- **Creates:** `lua/andrew/vault/slug.lua` (15 lines, zero deps)
- **Modifies:** `vault_index.lua`, `link_utils.lua`
- **Hard deps:** None
- **Soft deps:** None (pure refactoring)
- **Builds on:** Existing duplicated `heading_to_slug()` implementations
- **Risk:** Very Low (identical logic extraction; no behavioral change)

### #40 — Alias Collision Warnings `[Small]`
- **Creates:** Nothing new
- **Modifies:** `vault_index.lua`, `config.lua`, `init.lua`
- **Hard deps:** None
- **Soft deps:** None
- **Builds on:** `_rebuild_name_index()`, `vim.notify()`, `ui.create_float_display()`
- **Risk:** Very Low (read-only detection after index build; no mutation)

### #41 — Unresolved Graph Link Nodes `[Medium]`
- **Creates:** Nothing new
- **Modifies:** `graph.lua`
- **Hard deps:** None
- **Soft deps:** Synergizes with #37 + #38 (fewer false-unresolved links after implementation)
- **Builds on:** Existing `render_graph()`, `collect_forward_links()`, `graph_filter.state`
- **Risk:** Low (extends existing rendering; unresolved entries already in data)

---

## Recommended Implementation Order

```
Phase 1 ─ Independent Refactoring (no conflicts, safe baseline)
  1. #39  Deduplicate heading_to_slug    [Small]    ~30min
  2. #40  Alias Collision Warnings       [Small]    ~1-2h

Phase 2 ─ Resolution Pipeline (coordinated wikilinks.lua changes)
  3. #38  Relative Path Resolution       [Medium]   ~2-3h   (modifies resolve_link first)
  4. #37  Temporal Wikilink Aliases       [Medium]   ~2-3h   (layers on resolve_link after #38)
  5. #36  Transclusion Cycle/Depth        [Medium]   ~3-4h   (consumes improved resolve_link)

Phase 3 ─ Graph Visualization (independent, benefits from Phase 2)
  6. #41  Unresolved Graph Link Nodes    [Medium]   ~2-3h   (benefits from #37+#38 resolution)
```

### Rationale

1. **#39 first** — pure refactoring with zero risk, establishes clean code baseline
2. **#40 next** — independent index improvement, no impact on resolution pipeline
3. **#38 before #37** — both modify `resolve_link()` in `wikilinks.lua`; #38 adds the `is_path_like()` early-exit at the TOP of the function, #37 adds `resolve_temporal()` fallback at the BOTTOM. Implementing #38 first creates the layered structure that #37 plugs into cleanly
4. **#36 after #37/#38** — embed cycle detection calls `resolve_embed()` → `resolve_link()`, so it automatically benefits from the improved resolution pipeline without additional changes
5. **#41 last** — graph visualization of unresolved links benefits from all resolution improvements; fewer false-positives in the "unresolved" category after #37/#38

### Parallelization Opportunities

These groups can be implemented **concurrently** (no shared files):

| Group A | Group B | Group C |
|---------|---------|---------|
| #39 (slug.lua, vault_index, link_utils) | #40 (vault_index, config, init) | #41 (graph.lua) |

**Caveat:** #39 and #40 both touch `vault_index.lua` but in non-overlapping regions (top-level require vs. post-`_rebuild_name_index` methods). Safe to parallelize with care.

Sequential requirement: **#38 → #37 → #36** (all touch the resolve pipeline).

---

## Conflict Resolution Notes

### `wikilinks.lua` (#37 + #38)
Both add logic to `resolve_link()`. Structure after both are applied:
```lua
function resolve_link(link_name, bufnr)
  -- [#38] Relative path resolution (early exit)
  if is_path_like(link_name) then
    local path = resolve_relative(link_name, bufnr)
    if path then return path end
  end

  -- [existing] Vault index resolution (primary)
  local idx = vault_index.current()
  if idx then
    local paths = idx:resolve_name(link_name)
    if paths and #paths > 0 then return pick_closest(paths) end
  end

  -- [#37] Temporal alias resolution (fallback)
  local temporal_path = resolve_temporal(link_name)
  if temporal_path then return temporal_path end

  return nil
end
```

### `config.lua` (#36 + #37 + #40)
Each adds a separate section. Use comment headers:
```lua
-- [36] Embed depth/cycle detection
M.embed.max_depth = 5

-- [37] Temporal wikilink aliases
M.temporal_aliases = { ... }

-- [40] Index collision warnings
M.index.warn_collisions = true
```

### `vault_index.lua` (#39 + #40)
- #39: Adds `require("andrew.vault.slug")` at line ~7, replaces local function at line ~196
- #40: Adds `_detect_collisions()` method after `_rebuild_name_index()` at line ~670+, adds `get_collisions()` and `show_collisions()` at line ~1100+
- Non-overlapping edits; safe to apply in either order
