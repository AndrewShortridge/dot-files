# Improvement Dependency Graph (20–27)

## Visual Dependency Graph

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 1                              │
                    │              Independent / Quick Wins                   │
                    │                                                         │
                    │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
                    │  │ #21 Snippet  │  │ #25 Smart    │  │ #27 Deprec.  │  │
                    │  │ Consolidation│  │ Connections  │  │ Fixes v2     │  │
                    │  │   [Medium]   │  │   [Large]    │  │   [Small]    │  │
                    │  └──────────────┘  └──────┬───────┘  └──────┬───────┘  │
                    └───────────────────────────┼──────────────────┼──────────┘
                                                │                  │
                        uses query/index.lua ───┘    touches ──────┘
                                                     render-markdown.lua
                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 2                              │
                    │         Coordinated Markdown/Spell/Folds               │
                    │         (share ftplugin, queries, blink)               │
                    │                                                         │
                    │  ┌──────────────┐                                       │
                    │  │ #22 Inline   │──── shares queries/markdown/ ────┐    │
                    │  │ Fields       │──── shares ftplugin/markdown ─┐  │    │
                    │  │   [Large]    │──── shares blink-cmp ──────┐ │  │    │
                    │  └──────────────┘                             │ │  │    │
                    │                                              │ │  │    │
                    │  ┌──────────────┐                             │ │  │    │
                    │  │ #23 Spell    │──── shares blink-cmp ──────┘ │  │    │
                    │  │ Checking     │──── shares ftplugin/markdown ─┘  │    │
                    │  │   [Large]    │──── shares queries/markdown/ ────┘    │
                    │  └──────────────┘                                       │
                    │                                                         │
                    │  ┌──────────────┐                                       │
                    │  │ #26 Callout  │──── shares ftplugin/markdown.lua      │
                    │  │ Fold Persist │──── shares render-markdown.lua        │
                    │  │   [Medium]   │                                       │
                    │  └──────────────┘                                       │
                    └─────────────────────────────────────────────────────────┘

                    ┌─────────────────────────────────────────────────────────┐
                    │                    PHASE 3                              │
                    │            Vault Knowledge Graph                        │
                    │                                                         │
                    │  ┌──────────────┐       ┌──────────────┐               │
                    │  │ #20 Unlinked │◄─────►│ #24 Auto-Link│               │
                    │  │ Mentions     │related│ Suggestions  │               │
                    │  │   [Large]    │       │   [Large]    │               │
                    │  └──────────────┘       └──────────────┘               │
                    │   both use wikilinks.lua name cache                     │
                    │   both use engine.lua cache invalidation               │
                    └─────────────────────────────────────────────────────────┘
```

---

## Shared File Conflict Matrix

| Shared File | #20 | #21 | #22 | #23 | #24 | #25 | #26 | #27 |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `ftplugin/markdown.lua` | | | **W** | **W** | **W** | | **W** | |
| `lua/andrew/vault/config.lua` | W | | W | W | W | W | W | |
| `lua/andrew/vault/init.lua` | W | | W | | W | W | W | |
| `lua/andrew/vault/engine.lua` | W | | | | | W | W | |
| `lua/andrew/plugins/blink-cmp.lua` | | | **W** | **W** | | | | |
| `lua/andrew/plugins/render-markdown.lua` | | | | | | | **W** | **W** |
| `queries/markdown/highlights.scm` | | | **W** | **W** | | | | |
| `lua/andrew/plugins/lsp/lspconfig.lua` | | | | | | | | W |
| `luasnippets/markdown.lua` | | W | | | | | | |
| `snippets/markdown.json` | | D | | | | | | |
| `lua/andrew/plugins/colorscheme.lua` | | | | W | | | | |

**W** = writes/modifies, **D** = deletes, **bold** = high-conflict potential

---

## Per-Improvement Detail

### #20 — Unlinked Mentions `[Large]`
- **Creates:** `lua/andrew/vault/unlinked.lua`
- **Hard deps:** None
- **Soft deps:** Benefits from #24 (complementary UI)
- **Builds on:** wikilinks.lua cache, engine.lua, backlinks.lua picker patterns
- **Risk:** Medium (ripgrep PCRE2 pattern complexity)

### #21 — Snippet Consolidation `[Medium]`
- **Creates:** Nothing new (modifies existing)
- **Deletes:** `snippets/markdown.json`
- **Hard deps:** None
- **Soft deps:** None
- **Builds on:** Completed #11 (missing snippets)
- **Risk:** Low

### #22 — Inline Fields `[Large]`
- **Creates:** `lua/andrew/vault/inline_fields.lua`
- **Hard deps:** None
- **Soft deps:** Coordinate with #23 on `queries/markdown/highlights.scm`
- **Builds on:** #19 tag_highlights.lua extmark pattern, query/index.lua
- **Risk:** Medium (treesitter query correctness)

### #23 — Spell Checking `[Large]`
- **Creates:** `lua/andrew/vault/completion_spell.lua`, `spell/en.utf-8.add`, 2 treesitter query files
- **Hard deps:** None
- **Soft deps:** Coordinate with #22 on shared treesitter queries
- **Builds on:** Native vim spell, treesitter `@nospell`
- **Risk:** Medium (spell + render-markdown interaction)

### #24 — Auto-Link Suggestions `[Large]`
- **Creates:** `lua/andrew/vault/autolink.lua`
- **Hard deps:** None
- **Soft deps:** Related to #20 (complementary); both use name cache
- **Builds on:** #19 extmark pattern, wikilinks.lua cache
- **Risk:** Medium (false positives, performance)

### #25 — Smart Connections `[Large]`
- **Creates:** `lua/andrew/vault/connections.lua`
- **Hard deps:** None
- **Soft deps:** None
- **Builds on:** query/index.lua, backlinks.lua, tags.lua, frecency.lua
- **Risk:** Low-Medium (scoring tuning)

### #26 — Callout Fold Persistence `[Medium]`
- **Creates:** `lua/andrew/vault/callout_folds.lua`
- **Hard deps:** Must integrate with render-markdown.lua fold system
- **Soft deps:** Coordinate with #27 (both touch render-markdown.lua)
- **Builds on:** engine.lua json_store pattern (frecency, pins)
- **Risk:** Low (content fingerprint approach is robust)

### #27 — Deprecation Fixes v2 `[Small]`
- **Creates:** Nothing
- **Hard deps:** None
- **Soft deps:** Do after #26 if both touch render-markdown.lua
- **Builds on:** Completed #17 (deprecation fixes)
- **Risk:** Very Low (2 targeted replacements)

---

## Recommended Implementation Order

```
Week 1 ─ Quick Wins (independent, no conflicts)
  1. #27  Deprecation Fixes v2        [Small]   ~1h
  2. #21  Snippet Consolidation        [Medium]  ~2-3h
  3. #25  Smart Connections            [Large]   ~6-8h

Week 2 ─ Coordinated Batch (share ftplugin, queries, blink)
  4. #22  Inline Fields                [Large]   ~4-5h
  5. #23  Spell Checking               [Large]   ~3-4h   (after #22)
  6. #26  Callout Fold Persistence     [Medium]  ~3-4h   (after #23)

Week 3 ─ Vault Knowledge Graph (complementary pair)
  7. #20  Unlinked Mentions            [Large]   ~4-6h
  8. #24  Auto-Link Suggestions        [Large]   ~4-5h   (after #20)

Total estimated: ~28-36h
```

### Rationale

1. **#27 first** — trivial cleanup, clears stale TODO items, no risk
2. **#21 next** — self-contained snippet work, immediate quality-of-life win
3. **#25 early** — fully independent, high-value feature, no file conflicts
4. **#22 → #23 → #26** — must be sequential because they share `ftplugin/markdown.lua`, `queries/markdown/`, and `render-markdown.lua`. Doing #22 first establishes the treesitter query file that #23 extends
5. **#20 → #24** — complementary features (unlinked mentions = discovery, auto-link = inline suggestions). #20's ripgrep infrastructure informs #24's detection approach

---

## Conflict Resolution Notes

### `ftplugin/markdown.lua` (4 improvements touch this)
Each adds its own section. Use comment headers:
```lua
-- [22] Inline field keymaps
-- [23] Spell checking
-- [24] Auto-link suggestion autocommands
-- [26] Callout fold persistence keymap
```

### `queries/markdown/highlights.scm` (#22 + #23)
Use separate `; extends` files OR a single shared file. If single file, #22 goes first (inline field nodes), #23 appends (`@nospell` captures for frontmatter/math).

### `blink-cmp.lua` (#22 + #23)
Both add completion sources to the `per_filetype.markdown` list. Non-conflicting if done sequentially — each appends a source entry.

### `render-markdown.lua` (#26 + #27)
- \#27 changes `nvim_set_option_value` → `vim.wo` (3 lines)
- \#26 adds `pcall(require, ...)` hooks in fold functions
- Non-overlapping edits, but do #26 before #27 to avoid touching same file twice
