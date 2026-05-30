# Dependency Graph -- Batch 02 Improvements

## Overview

This batch contains 6 improvements to the Neovim vault configuration:

| # | Improvement | Summary |
|---|-------------|---------|
| 03 | Register `<leader>m` keymaps with which-key | Add subgroup labels, icons, and visual-mode entries to the which-key popup for all markdown `<leader>m*` keymaps |
| 04 | Use vault index for backlinks | Replace ripgrep subprocess calls with O(1) vault index lookups for backlinks/heading-backlinks, keeping ripgrep as fallback |
| 07 | Unified vault color module | Create `colors.lua` as single source of truth for all vault highlight colors across 4 modules, with per-colorscheme palette detection |
| 08 | Smart list continuation on Enter | Auto-continue list markers, checkboxes, ordered numbers, and blockquotes when pressing Enter in insert mode |
| 09 | Add total line limit to embeds | Cap total virtual text lines across all embeds in a buffer via `max_total_lines` config option |
| 10 | Vault index progress indicator | Show progress notifications during `build_async()` on cold start and large incremental rebuilds |

## Dependency Graph (ASCII)

```
                    +-----------+
                    |    07     |
                    |  Unified  |
                    |  Colors   |
                    +-----+-----+
                          |
                          | (should go first: 4 modules depend on its highlight groups)
                          |
         +----------------+----------------+
         |                |                |
         v                v                v
   (wikilink_hl)    (tag_hl)     (inline_fields, highlights)
         |                |                |
         |                |                |
         v                v                v
   [no downstream  [no downstream  [no downstream
    improvements]   improvements]   improvements]


   +-------+     +-------+     +-------+     +-------+     +-------+
   |  03   |     |  04   |     |  08   |     |  09   |     |  10   |
   | Which |     | Index |     | List  |     | Embed |     | Index |
   |  Key  |     | Back  |     | Cont  |     | Limit |     | Prog  |
   |       |     | links |     |       |     |       |     |       |
   +-------+     +-------+     +-------+     +-------+     +-------+
       |              |             |             |              |
       |              |             |             |              |
       |         (vault_index      |         (config +      (config +
       |          already has      |          embed.lua)     vault_index +
       |          needed APIs)     |                         engine +
       |                           |                         init.lua)
       |                           |
  ftplugin/         backlinks    ftplugin/
  markdown.lua      .lua         markdown.lua
  (wk block)                     (CR mapping)


  PARALLEL GROUP A          PARALLEL GROUP B          PARALLEL GROUP C
  (no file overlap)         (no file overlap)         (no file overlap)
  +---+---+                 +---+---+                 +---+
  | 03| 04|                 | 08| 09|                 | 07|
  +---+---+                 +---+---+                 +---+
                                                        |
                                                  (do first for
                                                   cleanest diff)

  Recommended Serial Order:
  07 --> 09 --> 10 --> 04 --> 03 --> 08
```

### Dependency Summary

- **No hard dependencies exist between any of the 6 improvements.** Each can be implemented independently.
- **07 (Unified Colors) is a soft prerequisite** for any future work touching highlight groups in `wikilink_highlights.lua`, `tag_highlights.lua`, `highlights.lua`, or `inline_fields.lua`. Implementing it first prevents having to refactor highlight code twice.
- **03 and 08 both modify `ftplugin/markdown.lua`** but in different sections (which-key block vs. new require + autocmd near line 137). This creates a minor merge conflict risk if done in parallel branches.
- **09 and 10 both modify `config.lua`** but in different sections (`M.embed` vs. `M.index`). Low conflict risk.
- **10 also modifies `init.lua` and `engine.lua`**, which 07 also touches (07 adds a `require("andrew.vault.colors").setup()` call in `engine.lua`). Potential merge conflict in initialization order.

## File Conflict Matrix

Files modified by each improvement. Shared files are marked with `**SHARED**`.

| File | 03 | 04 | 07 | 08 | 09 | 10 |
|------|:--:|:--:|:--:|:--:|:--:|:--:|
| `ftplugin/markdown.lua` | **M** | | | **M** | | |
| `lua/andrew/vault/backlinks.lua` | | **M** | | | | |
| `lua/andrew/vault/config.lua` | | | | **M** | **M** | **M** |
| `lua/andrew/vault/embed.lua` | | | | | **M** | |
| `lua/andrew/vault/engine.lua` | | | **M** | | | **M** |
| `lua/andrew/vault/init.lua` | | | | | | **M** |
| `lua/andrew/vault/vault_index.lua` | | | | | | **M** |
| `lua/andrew/vault/wikilink_highlights.lua` | | | **M** | | | |
| `lua/andrew/vault/tag_highlights.lua` | | | **M** | | | |
| `lua/andrew/vault/highlights.lua` | | | **M** | | | |
| `lua/andrew/vault/inline_fields.lua` | | | **M** | | | |
| `lua/andrew/plugins/which-key.lua` | | | | | | |
| **New:** `lua/andrew/vault/colors.lua` | | | **C** | | | |
| **New:** `lua/andrew/utils/list-continuation.lua` | | | | **C** | | |

**Legend:** M = Modified, C = Created

### Shared File Conflicts

| Shared File | Improvements | Conflict Risk | Details |
|-------------|-------------|:-------------:|---------|
| `ftplugin/markdown.lua` | 03, 08 | **Medium** | 03 replaces the which-key `wk.add()` block (lines 780-803). 08 adds a new section near line 137 and also adds an entry inside the which-key block. If 03 lands first, 08's which-key addition targets the new expanded block. |
| `lua/andrew/vault/config.lua` | 08, 09, 10 | **Low** | Each adds to a different config table: 08 adds `M.list_continuation`, 09 adds `max_total_lines` to `M.embed`, 10 adds `show_progress`/`progress_threshold` to `M.index`. Non-overlapping sections. |
| `lua/andrew/vault/engine.lua` | 07, 10 | **Low** | 07 adds `require("andrew.vault.colors").setup()` early in init. 10 adds `show_progress`/`progress_threshold` to the `configure()` call. Different locations in the file. |

## Implementation Order

### Recommended Order

| Order | # | Improvement | Rationale |
|:-----:|:-:|-------------|-----------|
| 1 | **07** | Unified vault color module | Foundation change. Refactors 4 existing modules. Doing this first avoids touching highlight code in those files twice. Creates `colors.lua` that future work references. |
| 2 | **09** | Add total line limit to embeds | Self-contained, touches only `config.lua` + `embed.lua`. Quick win. No overlap with 07's files. Low risk. |
| 3 | **10** | Vault index progress indicator | Self-contained, touches `config.lua` + `vault_index.lua` + `engine.lua` + `init.lua`. Medium effort but low risk. The `engine.lua` overlap with 07 is minimal (different functions). |
| 4 | **04** | Use vault index for backlinks | Isolated to `backlinks.lua`. No file conflicts with anything above. Medium complexity (new query pattern). |
| 5 | **03** | Register `<leader>m` keymaps with which-key | Isolated to `ftplugin/markdown.lua`. Quick win but placed here to minimize conflict with 08. |
| 6 | **08** | Smart list continuation on Enter | Also touches `ftplugin/markdown.lua` (and adds to which-key block). Placed last so it applies cleanly after 03's expanded which-key block. Highest complexity. |

### Rationale Details

1. **Dependencies first**: 07 is the only improvement that functions as a foundation for other modules. Doing it first means all downstream highlight code is already clean.
2. **Risk ordering**: 09 and 10 are low-risk, additive changes. 04 is medium-risk (changes a user-facing query path with fallback). 08 is highest risk (intercepts `<CR>` in insert mode with plugin interaction chains).
3. **Effort ordering**: 03 and 09 are quick wins (~30 min each). 07 and 10 are medium effort (~1-2 hours). 04 and 08 are higher effort (~2-3 hours each).
4. **Conflict avoidance**: 03 and 08 share `ftplugin/markdown.lua`. Doing them sequentially (03 then 08) avoids merge conflicts.

## Parallel Execution Groups

These groups can be implemented simultaneously with no file conflicts or logical dependencies:

### Group 1 (Zero overlap)

| Improvement | Files Touched |
|-------------|---------------|
| **04** (Index backlinks) | `backlinks.lua` |
| **07** (Unified colors) | `colors.lua` (new), `wikilink_highlights.lua`, `tag_highlights.lua`, `highlights.lua`, `inline_fields.lua`, `engine.lua` |
| **09** (Embed line limit) | `config.lua`, `embed.lua` |

These three share zero files and have no logical dependencies. They can be done in parallel branches and merged independently.

### Group 2 (Zero overlap with Group 1 remnants)

| Improvement | Files Touched |
|-------------|---------------|
| **10** (Index progress) | `config.lua`, `vault_index.lua`, `engine.lua`, `init.lua` |
| **03** (Which-key registration) | `ftplugin/markdown.lua` |

These two share zero files with each other. They have minor `config.lua` and `engine.lua` overlap with Group 1 items (09 and 07), so they should start after those merge.

### Group 3 (After Group 2)

| Improvement | Files Touched |
|-------------|---------------|
| **08** (List continuation) | `list-continuation.lua` (new), `ftplugin/markdown.lua`, `config.lua` |

This should be last because it modifies `ftplugin/markdown.lua` (shared with 03) and `config.lua` (shared with 09, 10). Cleanest to implement after all prior changes have landed.

### Maximum Parallelism Strategy

If three developers were available:

```
Time -->

Dev A:  [=== 07 (colors) ===]----[=== 10 (progress) ===]
Dev B:  [== 04 (backlinks) ==]---[== 03 (which-key) ==]-[= 08 (list cont) =]
Dev C:  [= 09 (embed limit) =]
```

## Estimated Effort

| # | Improvement | Lines of Code | Complexity | Risk | Time Estimate |
|:-:|-------------|:------------:|:----------:|:----:|:------------:|
| 03 | Register `<leader>m` keymaps with which-key | ~80 (replace block) | **Low** | **Low** | 30 min |
| 04 | Use vault index for backlinks | ~150 (new helpers + refactor) | **Medium** | **Medium** | 2 hours |
| 07 | Unified vault color module | ~150 (new file) + ~60 (removals across 4 files) | **Medium** | **Medium** | 1.5 hours |
| 08 | Smart list continuation on Enter | ~220 (new file) + ~20 (ftplugin integration) | **High** | **High** | 3 hours |
| 09 | Add total line limit to embeds | ~80 (modifications) | **Medium** | **Low** | 1 hour |
| 10 | Vault index progress indicator | ~80 (modifications across 4 files) | **Low** | **Low** | 1 hour |

**Total estimated effort: ~9 hours**

### Risk Breakdown

| Risk Level | Improvements | Why |
|:----------:|:------------:|-----|
| **Low** | 03, 09, 10 | 03 is purely additive UI metadata. 09 adds a config value and threads a counter. 10 adds notifications to an existing async loop. All have clear rollback paths. |
| **Medium** | 04, 07 | 04 changes the backlinks query path but has a ripgrep fallback. 07 refactors 4 modules but maintains backward compatibility via `default = true`. |
| **High** | 08 | Intercepts `<CR>` in insert mode. Must chain correctly with blink.cmp (completion accept) and nvim-autopairs (bracket expansion). Edge cases with treesitter context detection (code blocks, frontmatter). Timing-sensitive lazy setup via `InsertEnter` autocmd. |

## Notes

### Cross-Cutting Concerns

1. **`config.lua` is a hotspot.** Three improvements (08, 09, 10) add new config sections. All additions are in different `M.*` tables, so textual conflicts are minimal, but reviewers should verify the final `config.lua` after all merges to ensure no duplicate keys or formatting inconsistencies.

2. **`engine.lua` initialization order matters.** Both 07 and 10 add code to the engine/init startup path. 07 needs `colors.setup()` to run BEFORE the highlight modules' `setup()` calls. 10 needs `configure()` to run BEFORE `build_async()`. If both land, verify the final ordering in `engine.lua` is:
   - `vault_index.configure(...)` (with progress config from 10)
   - `colors.setup()` (from 07)
   - highlight module `setup()` calls
   - `build_async()` (existing)

3. **`ftplugin/markdown.lua` has two changes.** 03 replaces the which-key block at the end of the file. 08 adds a new section near line 137 AND adds one entry to the which-key block. If implementing 03 first, the which-key block location and content changes. 08 must target the new expanded block when adding its `<CR>` entry.

4. **Soft-paper theme interaction.** Improvement 07 is designed to be backward-compatible with `soft-paper.lua`. The theme continues to override `Vault*` groups without `default = true`. After 07 lands, verify the theme-switching test (OneDark -> soft-paper -> OneDark) works correctly.

5. **Vault index readiness.** Both 04 (backlinks) and 10 (progress) interact with `vault_index._ready` and `build_async()`. They do not conflict (04 reads readiness state; 10 reports it). However, testing should verify that backlinks gracefully fall back to ripgrep during the period when 10's progress bar is still showing (index not yet ready).

6. **No new plugin dependencies.** All 6 improvements use only existing APIs (`vim.api`, `vim.notify`, `vim.uv`, `vim.treesitter`, which-key's `wk.add()`, fzf-lua's `fzf_exec()`, vault_index's existing query methods). No new external plugins are required.

7. **Testing priority.** The highest-risk item (08, smart list continuation) should receive the most thorough manual testing, particularly the interaction with blink.cmp's `<CR>` accept and nvim-autopairs' bracket expansion. A regression in Enter key behavior would affect every markdown editing session.
