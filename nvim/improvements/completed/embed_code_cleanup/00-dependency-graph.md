# Embed Code Cleanup: Dependency Graph & Execution Order

## Plan Summary

| # | Short Name | File(s) | Functions Modified |
|---|-----------|---------|-------------------|
| 01 | IMAGE_EXTS consolidation | config, embed, export | `M.embed`, `is_image_embed`, `is_image` |
| 02 | Remove redundant requires | embed | `on_index_update`, TextChanged autocmd |
| 03 | Optimize recursion tables | embed | `resolve_embed_lines` (visited tracking) |
| 04 | Fix error reporting | colors, embed | `render_embeds` (content loop, not-found border) |
| 05 | Extract border helpers | embed | `render_embeds` (4 border sites) |
| 06 | EMBED_PAT constant | embed | Module-level + 5 pattern call sites |
| 07 | Basename helper | link_utils, embed | `get_basename`, `format_cycle_path` |
| 08 | Hoist highlight locals | embed | `render_embeds` (move hl decls to function scope) |
| 09 | Cache buf name | embed | `resolve_image`, `resolve_embed`, `resolve_embed_lines`, `render_embeds` |
| 10 | Optimize pattern matching | embed | `resolve_embed_lines` (~55 line rewrite) |
| 11 | Fix minor issues | embed | `resolve_embed_lines`, `render_embeds`, `debug_info`, new helper |

## Dependency Graph

```
01 --> 06 --> 10 --> 03 --> 09
                \-> 11 -/

04 --> 08 --> 05

02  (independent, any time)
07  (independent, any time)
```

### Hard Dependencies

| Upstream | Downstream | Reason |
|----------|-----------|--------|
| 01 | 06 | 01 removes IMAGE_EXTS lines near where 06 inserts EMBED_PAT constant |
| 06 | 10 | 10's replacement code uses `EMBED_PAT` introduced by 06 |
| 10 | 03 | 10 rewrites lines 244-299; 03 modifies visited tracking + recursive call inside that zone |
| 10 | 11 | 10 rewrites the region containing 11's issue 11 (line 281) and issue 13 (line 269) targets |
| 03, 11 | 09 | 09 threads `bufpath` through function signatures/call sites that 03 and 11 also modify |
| 04 | 05 | Both modify not-found border (line 483); 04 changes highlight, 05 replaces the expression |
| 04 | 08 | 04 adds `elseif` branch in content loop; 08 removes highlight locals from that same loop |

## Conflict Matrix

**C** = conflicting (same lines), **F** = same function (nearby lines), **-** = independent.

|      | 01 | 02 | 03 | 04 | 05 | 06 | 07 | 08 | 09 | 10 | 11 |
|------|----|----|----|----|----|----|----|----|----|----|-----|
| **01** | -- | -  | -  | -  | -  | F  | -  | -  | -  | -  | -   |
| **02** |    | -- | -  | -  | -  | -  | -  | -  | -  | -  | -   |
| **03** |    |    | -- | -  | -  | F  | -  | -  | F  | **C** | F |
| **04** |    |    |    | -- | **C** | - | -  | F  | -  | -  | F  |
| **05** |    |    |    |    | -- | -  | -  | F  | -  | -  | -   |
| **06** |    |    |    |    |    | -- | -  | -  | -  | **C** | F |
| **07** |    |    |    |    |    |    | -- | -  | -  | -  | -   |
| **08** |    |    |    |    |    |    |    | -- | -  | -  | -   |
| **09** |    |    |    |    |    |    |    |    | -- | F  | F   |
| **10** |    |    |    |    |    |    |    |    |    | -- | **C** |
| **11** |    |    |    |    |    |    |    |    |    |    | --  |

### Direct Conflicts (C)

| Pair | Overlapping Region |
|------|--------------------|
| 03 ~ 10 | Both rewrite portions of `resolve_embed_lines()` |
| 04 ~ 05 | Both modify not-found border at line 483 |
| 06 ~ 10 | 06 replaces patterns that 10 also rewrites (3 of 5 occurrences inside 10's zone) |
| 10 ~ 11 | 10 rewrites region containing 11's issue 11 and issue 13 targets |

## Parallel Groups

Plans within the same group can be applied simultaneously.

```
Group A (independent foundations):     Group E (render_embeds chain):
  ┌─────┐  ┌─────┐  ┌─────┐            ┌─────┐
  │ 01  │  │ 02  │  │ 07  │            │ 04  │
  └──┬──┘  └─────┘  └─────┘            └──┬──┘
     │                                     │
Group B:                               Group F:
  ┌──▼──┐                              ┌──▼──┐
  │ 06  │                              │ 08  │
  └──┬──┘                              └──┬──┘
     │                                     │
Group C:                               Group G:
  ┌──▼──┐                              ┌──▼──┐
  │ 10  │                              │ 05  │
  └──┬──┘                              └─────┘
     │
Group D (parallel pair):
  ┌──▼──┐  ┌─────┐
  │ 03  │  │ 11  │
  └──┬──┘  └──┬──┘
     └────┬───┘
          │
  ┌───────▼───────┐
  │      09       │
  └───────────────┘
```

Note: Groups D and E-G are independent chains that can run in parallel.

### Safe Parallel Applications

| Set | Plans | Why Safe |
|-----|-------|----------|
| {01, 02, 07} | Different files or widely separated regions |
| {03, 11} | Different line ranges within `resolve_embed_lines` (after 10) |
| {03, 04} | Different functions |
| {11, 04} | Different functions/distant regions |
| {09, 08} | Different functions/regions |

### Unsafe Parallel Applications

| Pair | Why Unsafe |
|------|-----------|
| {03, 10} | Overlapping regions in `resolve_embed_lines` |
| {06, 10} | 10 depends on EMBED_PAT from 06 |
| {04, 05} | Both modify not-found border line |
| {04, 08} | Both modify content highlight loop |
| {10, 11} | 10 rewrites region containing 11's targets |

## Recommended Execution Order

```
 #   Plan   Chain                 Reason
 1.  01     resolve_embed_lines   Foundation: clears IMAGE_EXTS, opens space for constants
 2.  02     (independent)         Bottom-of-file require cleanup, zero interactions
 3.  07     (independent)         link_utils helper + format_cycle_path, zero interactions
 4.  06     resolve_embed_lines   Introduces EMBED_PAT constant (required by 10)
 5.  10     resolve_embed_lines   Major rewrite of scan logic (uses EMBED_PAT)
 6.  03     resolve_embed_lines   Push/pop optimization (adapts to post-10 code)
 7.  11     resolve_embed_lines   Minor fixes in the settled code
 8.  09     resolve_embed_lines   Thread bufpath (after 03/11 stabilize signatures)
 9.  04     render_embeds         Error highlight + elseif branch + error counting
10.  08     render_embeds         Hoist highlight locals (after 04 finalizes loop)
11.  05     render_embeds         Border helpers (after 04+08 finalize border/hl code)
```

### Two Independent Workstreams

After step 5 (Plan 10), the remaining work splits into two independent chains:

**Chain 1** (`resolve_embed_lines`): 03 -> 11 -> 09
**Chain 2** (`render_embeds`): 04 -> 08 -> 05

These chains touch different functions and can be interleaved or run in parallel.

Steps 1-3 (Plans 01, 02, 07) are prerequisites for neither chain and can be done at any time.

## Key Constraint Summary

```
01 ──> 06 ──> 10 ──> {03, 11} ──> 09
                          |
               04 ──> 08 ──> 05

02, 07: float freely (apply any time)
```
