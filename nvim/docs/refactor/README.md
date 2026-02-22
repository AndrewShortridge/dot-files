# Vault Module Refactoring Guide

17 implementation guides for consolidating redundant code across the vault module.
Estimated total impact: **~550+ lines removed**, 2 bugs fixed, consistency guaranteed.

## Dependency Graph

Features are numbered in recommended implementation order. Arrows show "must be done before" relationships.

```
TIER 0: Foundational (no dependencies — implement first, in any order)
  01  engine.json_store
  02  engine.read_file / write_file
  03  engine.is_vault_path / vault_relative / current_note_name
  04  engine.rg_base_opts / vault_fzf_opts / vault_fzf_actions
  05  config.status_values / priority_values / scopes
  10  ui.create_float_input / create_float_display
  12  [intra-file] tags.lua + frecency.lua dedup
  13  [intra-file] metaedit.lua + rename.lua + tasks.lua dedup
  15  date utility consolidation

TIER 1: Depends on Tier 0
  06  link_utils module + parse_target          ── (new module, no hard deps)
  11  completion base factory                   ── optionally uses 02
  14  hardcoded directory paths → config.dirs   ── depends on 05
  17  vault file enumeration consolidation      ── depends on 03

TIER 2: Depends on Tier 1
  07  link_utils.heading_to_slug                ── depends on 06
  08  wikilink-under-cursor + resolve_link      ── depends on 06
  09  link_utils.read_heading_section/block     ── depends on 06, optionally 02
  16  frontmatter parsing consolidation         ── depends on 02, optionally 06
```

## Dependency Matrix

| Feature | Depends On | Depended On By |
|---------|-----------|----------------|
| **01** engine.json_store | — | — |
| **02** engine.read_file/write_file | — | 09, 16 |
| **03** engine.path_utils | — | 17 |
| **04** engine.fzf_utils | — | 13 (tasks.lua, optional) |
| **05** config.canonical_values | — | 14 |
| **06** link_utils + parse_target | — | 07, 08, 09 |
| **07** heading_to_slug | 06 | — |
| **08** cursor + resolve_link | 06 | — |
| **09** content extraction | 06, 02 | — |
| **10** ui.float_utils | — | — |
| **11** completion base factory | 02 (optional) | — |
| **12** tags/frecency dedup | — | — |
| **13** metaedit/rename/tasks dedup | 04 (optional) | — |
| **14** hardcoded dir paths | 05 | — |
| **15** date consolidation | — | — |
| **16** frontmatter parser | 02 | — |
| **17** vault file enumeration | 03 | — |

## Suggested Implementation Order

### Phase 1: Foundational Utilities (no risk, all independent)
Start with any/all of these in parallel:
1. **01** — `engine.json_store` (pins, frecency, saved_searches)
2. **02** — `engine.read_file / write_file` (5 consumers)
3. **03** — `engine.is_vault_path / vault_relative` (9 consumers)
4. **04** — `engine.rg_base_opts / vault_fzf_opts` (8 consumers)
5. **05** — `config.status_values / scopes` (fixes inconsistency bug)
6. **10** — `ui.create_float_input / display` (4 consumers)

### Phase 2: Intra-File Cleanups (safe, self-contained)
These touch only one file each and can be done in parallel:
7. **12** — tags.lua + frecency.lua internal dedup
8. **13** — metaedit.lua + rename.lua + tasks.lua internal dedup
9. **15** — Date utility consolidation

### Phase 3: Shared Modules (depend on Phase 1)
10. **06** — Create `link_utils` module + `parse_target`
11. **11** — Completion base factory
12. **14** — Hardcoded directory paths (depends on 05)
13. **17** — Vault file enumeration (depends on 03)

### Phase 4: Link Utils Extensions (depend on 06)
14. **07** — `heading_to_slug` (fixes slug inconsistency bug)
15. **08** — Wikilink-under-cursor + resolve_link consolidation
16. **09** — `read_heading_section` / `read_block_content`

### Phase 5: Deep Consolidation (depends on Phase 1+)
17. **16** — Frontmatter parsing consolidation (largest, most cross-cutting)

## Bugs Fixed by This Refactor

1. **Status/Priority inconsistency** (Feature 05): `metaedit.lua` and `completion_frontmatter.lua` define different status/priority value lists, causing completions to suggest values that cycling doesn't recognize.

2. **Heading slug divergence** (Feature 07): `backlinks.lua` produces different heading slugs than all other modules due to an extra hyphen-collapse step, potentially causing heading anchor navigation failures.

## New Files Created

| File | Created By |
|------|-----------|
| `lua/andrew/vault/link_utils.lua` | Feature 06 |
| `lua/andrew/vault/ui.lua` | Feature 10 |
| `lua/andrew/vault/completion_base.lua` | Feature 11 |
| `lua/andrew/vault/frontmatter_parser.lua` | Feature 16 |
