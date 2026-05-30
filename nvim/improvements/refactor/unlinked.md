# unlinked.lua Refactoring Plan

## Status: COMPLETE

All extractions implemented. Test file updated to match new module structure.

## Current Structure

| File | Lines | Purpose |
|------|-------|---------|
| `unlinked.lua` | 302 | Orchestrator: public API, scan helpers, setup, test re-exports |
| `unlinked/rg_pipeline.lua` | ~160 | Ripgrep search, pattern building, result filtering, context exclusion |
| `unlinked/ui.lua` | 142 | FZF pickers (vault-wide shared picker + buffer picker) |
| `unlinked/wrapper.lua` | 115 | Text wrapping: file-based, buffer-based, wikilink wrapping |
| `unlinked/names.lua` | ~85 | Note name collection, word counting |
| `unlinked/utils.lua` | ~96 | Shared utilities: batching, grouping, name filtering, file reading |
| **Total** | **~900** | |

## Completed Extractions

1. **Subsystem A: rg_pipeline.lua** - Ripgrep search pipeline (pattern building, filtering, context exclusion)
2. **Subsystem B: ui.lua** - FZF pickers (3 vault callers share `open_vault_picker`, buffer picker separate)
3. **Subsystem C: wrapper.lua** - Wrap helpers (`apply_file_wraps_bottom_up`, `apply_buffer_wraps_bottom_up`, `wrap_in_wikilink`)
4. **Subsystem D: names.lua** - Name collection (`current_note_names`, `all_note_names`, `word_count`)
5. **Subsystem E: utils.lua** - Shared utilities (`batch_list`, `group_by_file`, `filter_names_by_min_length`, `word_count`, `find_name_at_col`, `read_lines_prefer_buffer`)

## Resolved Duplication

- **FZF Picker Skeleton**: 3 vault callers (autolink_vault, unlinked_mentions, vault_unlinked_mentions) share `open_vault_picker()`
- **Config Accessors**: Eliminated; all modules use direct `config.autolink.*` access
- **Entry Building**: Centralized in `ui.build_vault_entries()`

## Test Updates

- Source-reading test updated to check submodule files instead of monolithic `unlinked.lua`
- `is_inside_wikilink` + `is_inside_url` → unified `is_inside_link_or_url`
- `pcre2_escape` → `rg_escape` (in engine.lua, called from rg_pipeline)
- All functional tests (rg_pattern, link detection, code span, frontmatter, heading) pass via `M._*` re-exports
