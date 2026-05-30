# Improvement Dependency Graph (28–35)

## Overview

| # | Title | Size | New Files | Key Modified Files |
|---|-------|------|-----------|-------------------|
| 28 | Smart Paste | Medium | `lua/andrew/utils/smart-paste.lua` | `ftplugin/markdown.lua` |
| 29 | Blockquote Shortcut | Small | — | `ftplugin/markdown.lua` |
| 30 | Table Creation Helper | Medium | `lua/andrew/utils/table-gen.lua` | `ftplugin/markdown.lua`, `luasnippets/markdown.lua` |
| 31 | Missing Snippet Types | Small | — | `luasnippets/markdown.lua` |
| 32 | Frontmatter Visual Editor | Medium | `lua/andrew/vault/frontmatter_editor.lua` | `lua/andrew/vault/init.lua` |
| 33 | Auto-Save on Focus Loss | Medium | `lua/andrew/vault/autosave.lua` | `lua/andrew/vault/config.lua`, `lua/andrew/vault/init.lua` |
| 34 | Block ID Validation | Medium | — | `lua/andrew/vault/linkcheck.lua`, `lua/andrew/vault/vault_index.lua` |
| 35 | Rename via Vault Index | Large | — | `lua/andrew/vault/rename.lua`, `lua/andrew/vault/vault_index.lua` |

---

## Visual Dependency Graph

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 1                              │
                    │              Independent / Quick Wins                   │
                    │          (no cross-improvement dependencies)            │
                    │                                                         │
                    │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
                    │  │ #31 Missing  │  │ #29 Block-   │  │ #33 Auto-    │  │
                    │  │ Snippets     │  │ quote Shortc.│  │ Save         │  │
                    │  │   [Small]    │  │   [Small]    │  │   [Medium]   │  │
                    │  └──────────────┘  └──────────────┘  └──────────────┘  │
                    └─────────────────────────────────────────────────────────┘

                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 2                              │
                    │           Markdown Editing Enhancements                 │
                    │       (share ftplugin/markdown.lua, snippets)           │
                    │                                                         │
                    │  ┌──────────────┐                                       │
                    │  │ #28 Smart    │──── shares ftplugin/markdown ────┐    │
                    │  │ Paste        │                                  │    │
                    │  │   [Medium]   │                                  │    │
                    │  └──────────────┘                                  │    │
                    │                                                    │    │
                    │  ┌──────────────┐                                  │    │
                    │  │ #30 Table    │──── shares ftplugin/markdown ────┘    │
                    │  │ Creation     │──── shares luasnippets/markdown ──┐   │
                    │  │   [Medium]   │                                   │   │
                    │  └──────────────┘                                   │   │
                    │                                                     │   │
                    │  (Note: #30 and #31 both touch luasnippets/markdown)│   │
                    └─────────────────────────────────────────────────────────┘

                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 3                              │
                    │           Vault Index Enhancements                      │
                    │        (both extend vault_index.lua)                    │
                    │                                                         │
                    │  ┌──────────────┐       ┌──────────────┐               │
                    │  │ #34 Block ID │       │ #35 Rename   │               │
                    │  │ Validation   │       │ via Index    │               │
                    │  │   [Medium]   │       │   [Large]    │               │
                    │  └──────────────┘       └──────────────┘               │
                    │   both add methods to vault_index.lua                   │
                    │   #34: get_block_ids()   #35: update_files_batch()     │
                    └─────────────────────────────────────────────────────────┘

                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 4                              │
                    │              Complex UI Feature                         │
                    │                                                         │
                    │  ┌──────────────┐                                       │
                    │  │ #32 Front-   │                                       │
                    │  │ matter Editor│                                       │
                    │  │   [Medium]   │                                       │
                    │  └──────────────┘                                       │
                    │   standalone, but benefits from stable vault modules    │
                    └─────────────────────────────────────────────────────────┘
```

### Inter-Improvement Dependencies

```
#28 Smart Paste ·············> vault_index (optional, lazy-loaded)
#29 Blockquote Shortcut         (no dependencies)
#30 Table Creation ·········> vim-table-mode (optional)
#31 Missing Snippets            (no dependencies)
#32 Frontmatter Editor ────> metaedit.lua, frontmatter_parser.lua, config.lua
                        ···> vault_index (optional, for completion)
#33 Auto-Save ─────────────> engine.lua (is_vault_path), config.lua
#34 Block ID Validation ───> vault_index.lua (adds get_block_ids method)
                        ───> linkcheck.lua (extends validation)
#35 Rename via Index ──────> vault_index.lua (adds update_files_batch method)
                        ───> rename.lua (refactors discovery phase)

─── = hard dependency    ··· = soft/optional dependency
```

---

## Dependency Matrix

| Improvement | #28 | #29 | #30 | #31 | #32 | #33 | #34 | #35 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **#28** Smart Paste | — | . | . | . | . | . | . | . |
| **#29** Blockquote | . | — | . | . | . | . | . | . |
| **#30** Table Create | . | . | — | S | . | . | . | . |
| **#31** Snippets | . | . | S | — | . | . | . | . |
| **#32** FM Editor | . | . | . | . | — | . | . | . |
| **#33** Auto-Save | . | . | . | . | . | — | . | . |
| **#34** Block Valid. | . | . | . | . | . | . | — | S |
| **#35** Rename Index | . | . | . | . | . | . | S | — |

**H** = hard dependency, **S** = soft/coordination needed, **.** = independent

**Key finding:** No hard inter-improvement dependencies exist. All 8 can be implemented independently. Soft coordination is needed only for shared files.

---

## Shared File Conflict Matrix

| Shared File | #28 | #29 | #30 | #31 | #32 | #33 | #34 | #35 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ftplugin/markdown.lua` | **W** | **W** | **W** | | | | | |
| `luasnippets/markdown.lua` | | | **W** | **W** | | | | |
| `lua/andrew/vault/vault_index.lua` | | | | | | | **W** | **W** |
| `lua/andrew/vault/init.lua` | | | | | W | W | | |
| `lua/andrew/vault/config.lua` | | | | | | W | | |
| `lua/andrew/vault/linkcheck.lua` | | | | | | | W | |
| `lua/andrew/vault/rename.lua` | | | | | | | | W |
| `lua/andrew/vault/metaedit.lua` | | | | | R | | | |
| `lua/andrew/vault/frontmatter_parser.lua` | | | | | R | | | |

**W** = writes/modifies, **R** = reads (dependency, no conflict), **bold** = high-conflict potential

### Hotspot Files

1. **`ftplugin/markdown.lua`** — 3 improvements (#28, #29, #30) add keymaps. Non-overlapping sections.
2. **`luasnippets/markdown.lua`** — 2 improvements (#30, #31) append snippets. Non-overlapping (different triggers).
3. **`vault_index.lua`** — 2 improvements (#34, #35) each add a new method. Non-overlapping (different function names).

---

## Per-Improvement Detail

### #28 — Smart Paste `[Medium]`
- **Creates:** `lua/andrew/utils/smart-paste.lua`
- **Modifies:** `ftplugin/markdown.lua` (visual `p`/`P` overrides, `<leader>mP`, `:SmartPasteToggle`)
- **Hard deps:** None
- **Soft deps:** vault_index (optional, for note name resolution)
- **Risk:** Low-Medium (visual mode paste override could surprise users; toggle mitigates)

### #29 — Blockquote Shortcut `[Small]`
- **Creates:** Nothing (inline functions in ftplugin)
- **Modifies:** `ftplugin/markdown.lua` (`<leader>mq`, `<leader>mQ`, `<leader>mC`)
- **Hard deps:** None
- **Soft deps:** None
- **Risk:** Very Low (pure line-prefix manipulation)

### #30 — Table Creation Helper `[Medium]`
- **Creates:** `lua/andrew/utils/table-gen.lua`
- **Modifies:** `ftplugin/markdown.lua` (`:TableCreate`, `<leader>mT`), `luasnippets/markdown.lua` (`tblx`)
- **Hard deps:** None
- **Soft deps:** vim-table-mode (optional auto-enable), coordinate with #31 on snippet file
- **Risk:** Low (pure function generator, graceful vim-table-mode fallback)

### #31 — Missing Snippet Types `[Small]`
- **Creates:** Nothing (appends to existing file)
- **Modifies:** `luasnippets/markdown.lua` (12+ new snippet definitions)
- **Hard deps:** None
- **Soft deps:** Coordinate with #30 on snippet file (non-overlapping triggers)
- **Risk:** Very Low (pure declarative LuaSnip additions)

### #32 — Frontmatter Visual Editor `[Medium]`
- **Creates:** `lua/andrew/vault/frontmatter_editor.lua`
- **Modifies:** `lua/andrew/vault/init.lua` (register setup)
- **Hard deps:** metaedit.lua (`set_field()`), frontmatter_parser.lua (`parse_buffer()`)
- **Soft deps:** vault_index (optional, for field name/value completion)
- **Risk:** Medium (float window management, two-way sync between float and source buffer)

### #33 — Auto-Save on Focus Loss `[Medium]`
- **Creates:** `lua/andrew/vault/autosave.lua`
- **Modifies:** `lua/andrew/vault/config.lua` (add `config.autosave`), `lua/andrew/vault/init.lua` (register)
- **Hard deps:** engine.lua (`is_vault_path()`)
- **Soft deps:** Works with frontmatter.lua `BufWritePre` (fires automatically on `update`)
- **Risk:** Low-Medium (timer lifecycle, guard checks prevent unwanted saves)

### #34 — Block ID Validation `[Medium]`
- **Creates:** Nothing (extends existing modules)
- **Modifies:** `vault_index.lua` (add `get_block_ids()`), `linkcheck.lua` (extend validation)
- **Hard deps:** vault_index.lua (requires new method)
- **Soft deps:** Coordinate with #35 on vault_index.lua (non-overlapping methods)
- **Risk:** Low (follows existing heading validation pattern exactly)

### #35 — Rename via Vault Index `[Large]`
- **Creates:** Nothing (refactors existing module)
- **Modifies:** `vault_index.lua` (add `update_files_batch()`), `rename.lua` (refactor discovery)
- **Hard deps:** vault_index.lua (requires new method + inlinks API)
- **Soft deps:** Coordinate with #34 on vault_index.lua (non-overlapping methods)
- **Risk:** Medium (two-phase refactor, must preserve ripgrep fallback, alias edge cases)

---

## Effort and Risk Assessment

| # | Title | Size | Risk | Rationale |
|---|-------|------|------|-----------|
| 28 | Smart Paste | M | Low-Med | New module, visual paste override needs careful fallback |
| 29 | Blockquote Shortcut | S | Very Low | Pure line manipulation, no external deps |
| 30 | Table Creation Helper | M | Low | New utility + snippet, optional vim-table-mode integration |
| 31 | Missing Snippet Types | S | Very Low | Declarative snippet additions, no logic |
| 32 | Frontmatter Visual Editor | M | Medium | Float UI, two-way data sync, type-aware editing |
| 33 | Auto-Save on Focus Loss | M | Low-Med | Timer management, comprehensive guard checks |
| 34 | Block ID Validation | M | Low | Mirrors existing heading validation pattern |
| 35 | Rename via Vault Index | L | Medium | Refactors core rename workflow, must preserve fallback |

**Total estimated: ~24-32h**

---

## Recommended Implementation Order

```
Phase 1 ─ Quick Wins (independent, zero conflicts)          ~3-4h
  1. #31  Missing Snippet Types        [Small]    ~1-2h
  2. #29  Blockquote Shortcut          [Small]    ~1-2h

Phase 2 ─ Markdown Editing (share ftplugin, snippets)       ~6-8h
  3. #30  Table Creation Helper        [Medium]   ~2-3h  (after #31, shares snippets file)
  4. #28  Smart Paste                  [Medium]   ~3-4h  (after #29, shares ftplugin)
  5. #33  Auto-Save on Focus Loss      [Medium]   ~2-3h  (independent, parallel OK)

Phase 3 ─ Vault Index Extensions (share vault_index.lua)    ~8-10h
  6. #34  Block ID Validation          [Medium]   ~3-4h
  7. #35  Rename via Vault Index       [Large]    ~5-6h  (after #34, shares vault_index)

Phase 4 ─ Complex UI Feature                                ~5-8h
  8. #32  Frontmatter Visual Editor    [Medium]   ~5-8h  (after stable vault modules)

Total estimated: ~24-32h
```

### Parallelization Timeline

```
Week 1 ──────────────────────────────────────────────
  │  #31 Snippets ████              (1-2h)
  │  #29 Blockquote ████            (1-2h)  ← parallel with #31
  │  #33 Auto-Save ██████████       (2-3h)  ← parallel with #31/#29
  │
Week 1-2 ────────────────────────────────────────────
  │  #30 Table Creation ████████    (2-3h)  ← after #31
  │  #28 Smart Paste ████████████   (3-4h)  ← after #29
  │
Week 2 ──────────────────────────────────────────────
  │  #34 Block ID Valid. ████████████  (3-4h)
  │  #35 Rename Index ██████████████████  (5-6h)  ← after #34
  │
Week 3 ──────────────────────────────────────────────
  │  #32 FM Editor ████████████████████████  (5-8h)
```

### Critical Path

```
#31 → #30 ──────────────────────────────┐
                                        ├──> all snippet/ftplugin work done
#29 → #28 ──────────────────────────────┘

#34 → #35 ──────────────────────────────────> vault index extensions done

#32 ────────────────────────────────────────> independent, schedule last (highest complexity)
```

**Minimum calendar time (with parallelization): ~2 weeks**

---

## Conflict Resolution Notes

### `ftplugin/markdown.lua` (3 improvements: #28, #29, #30)
Each adds its own keymap section. Use comment headers to delineate:
```lua
-- [29] Blockquote creation
-- [28] Smart paste
-- [30] Table creation
```
All add to the `<leader>m` which-key group. Non-overlapping keymaps:
- #28: `<leader>mP` + visual `p`/`P` overrides
- #29: `<leader>mq`, `<leader>mQ`, `<leader>mC`
- #30: `<leader>mT` + `:TableCreate` command

### `luasnippets/markdown.lua` (#30 + #31)
Both append snippets to the `snippets` table. Non-conflicting triggers:
- #30 adds: `tblx` (dynamic table)
- #31 adds: `img`, `imgc`, `comment`, `commentblock`, `reflink`, `refimg`, `hl`, `mark`, `hl!`, `hl?`, `abbr`, `def`, `kbd`, `kbdc`, `details`

Implement #31 first, then #30 appends after.

### `vault_index.lua` (#34 + #35)
Both add new public methods. Non-overlapping:
- #34 adds: `get_block_ids(abs_path)` — read-only query method
- #35 adds: `update_files_batch(paths)` — batch re-index + single rebuild

Implement #34 first (simpler, read-only), then #35 (write operation, larger scope).

### `lua/andrew/vault/init.lua` (#32 + #33)
Both add a `require` line to register their module's setup. Non-conflicting — append sequentially.

### `lua/andrew/vault/config.lua` (#33)
Only #33 modifies config. Adds `config.autosave` table. No conflicts.
