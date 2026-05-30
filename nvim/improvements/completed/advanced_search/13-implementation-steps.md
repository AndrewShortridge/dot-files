# Implementation Steps

## Overview

Six steps, ordered by dependency. Each step produces a testable unit.

## Step 1: Search Query Module (Tokenizer + Parser)

**New file:** `lua/andrew/vault/search_query.lua`

### What to Build
1. Token type constants (`M.TK`)
2. `M.tokenize(input)` -- single-pass tokenizer
3. `M.parse(tokens)` -- recursive descent parser
4. `M.parse_query(query_string)` -- convenience wrapper

### Dependencies
None. Pure Lua, no requires.

### Test First
- Tokenizer: all token types, edge cases, error cases
- Parser: all AST shapes, precedence, implicit AND, error cases

### Estimated Complexity
~300-400 lines. Largest new file.

### Key Decisions
- FIELD token carries structured `{ name, op, value, value2 }`
- Known field names hardcoded in tokenizer
- Generic fields (unknown names) allowed
- Case-insensitive keywords
- Error on first failure, no recovery

## Step 2: Filter Pipeline

**New file:** `lua/andrew/vault/search_filter.lua`

### What to Build
1. `M.split_ast(ast)` -- classify nodes as metadata vs text
2. `M.match_entry(ast, entry)` -- evaluate metadata AST against one entry
3. `M.evaluate(ast, index)` -- full evaluation across index
4. `M.ripgrep_in_files(text_nodes, matches, vault_path)` -- restricted ripgrep
5. Date value parser: `resolve_date(value)`
6. Field match helpers: string, numeric, tag, path, date, has, task

### Dependencies
- `search_query.lua` (AST types)
- `vault_index.lua` (VaultIndexEntry, current(), is_ready())
- `config.lua` (search.max_files_from)

### Test First
- Each field filter against mock entries
- Date parsing for all formats
- AST splitting for pure/mixed/combined queries
- Boolean combiners (AND/OR/NOT)

### Estimated Complexity
~400-500 lines. Most business logic lives here.

### Key Decisions
- `--files-from` via temp file (not stdin, for simplicity)
- Fallback to full vault ripgrep when > max_files_from matches
- `ctime` nil fallback to `mtime`
- Case-insensitive matching by default for fields

## Step 3: Advanced Search UI

**Modified file:** `lua/andrew/vault/search.lua`

### What to Build
1. `M.search_advanced()` -- prompt mode (vim.ui.input → fzf)
2. `M.search_advanced_live()` -- live mode (fzf_live with provider function)
3. `M.execute_advanced_query(query_string)` -- for saved search dispatch
4. Register commands: `:VaultSearchAdvanced`, `:VaultSearchAdvancedLive`
5. Register keymaps: `<leader>vfa`, `<leader>vfA`

### Dependencies
- `search_query.lua` (parse_query)
- `search_filter.lua` (split_ast, match_entry, ripgrep_in_files)
- `vault_index.lua` (current, is_ready, files)
- `engine.lua` (vault_fzf_opts, vault_fzf_actions, run, input)
- `fzf-lua` (fzf_exec, fzf_live)

### Test First
- Prompt mode: manual test with various query types
- Live mode: manual test for responsiveness
- Graceful degradation when index not ready

### Estimated Complexity
~150-200 lines added to search.lua.

### Key Decisions
- `fzf_live` with function provider (first use in codebase)
- Metadata-only results as file paths, text results as ripgrep lines
- Silent parse errors in live mode, notifications in prompt mode

## Step 4: Saved Search Integration

**Modified file:** `lua/andrew/vault/saved_searches.lua`

### What to Build
1. Extend `execute_search()` to handle `entry.advanced == true`
2. Extend `set_last_search()` with `advanced` parameter
3. Extend `save()` with `advanced` parameter
4. Update `save_last()` to preserve advanced flag
5. Update `save_interactive()` to offer "advanced" type
6. Update `list()` display to show `[ADV]` prefix

### Dependencies
- `search.lua` (execute_advanced_query)

### Test First
- Save advanced search, reload, verify JSON
- Execute saved advanced search
- Backward compatibility with existing saved searches

### Estimated Complexity
~30-50 lines changed in saved_searches.lua.

### Key Decisions
- `advanced` field omitted from JSON when false (nil)
- Raw query string stored, not AST
- Existing entries continue to work without changes

## Step 5: Completion and Help

**Modified file:** `lua/andrew/vault/search.lua`

### What to Build
1. Completion function for advanced search prompt
2. `M.search_help()` -- floating window with syntax reference
3. Register `:VaultSearchHelp` command

### Dependencies
- `config.lua` (search.builtin_fields, note_types, status_values)
- `vault_index.lua` (all_tags)

### Test First
- Completion suggestions for field names
- Completion suggestions for tag/type/status values
- Help float opens and closes properly

### Estimated Complexity
~80-100 lines.

### Key Decisions
- Completion via vim.ui.input's `completion` parameter (if supported)
- Help float uses minimal style, closeable with q/Esc
- Field names and operators suggested at word start
- Values suggested after field:

## Step 6: Configuration

**Modified file:** `lua/andrew/vault/config.lua`

### What to Build
1. Add `M.search` configuration table
2. Fields: `live_debounce_ms`, `max_files_from`, `builtin_fields`, `field_aliases`

### Dependencies
None.

### Test First
- Verify defaults work when no config override exists

### Estimated Complexity
~15-20 lines added to config.lua.

## Dependency Graph

```
Step 6: config.lua (M.search)
    |
    v
Step 1: search_query.lua (tokenizer + parser)
    |
    v
Step 2: search_filter.lua (evaluation + ripgrep)
    |
    v
Step 3: search.lua (UI: prompt + live modes)
    |
    +---> Step 4: saved_searches.lua (integration)
    |
    +---> Step 5: search.lua (completion + help)
```

Steps 1 and 6 can be done in parallel (no dependencies).
Steps 4 and 5 can be done in parallel (both depend on Step 3).

## Files Summary

### New Files (2)
| File | Lines | Purpose |
|------|-------|---------|
| `lua/andrew/vault/search_query.lua` | ~350 | Tokenizer + parser |
| `lua/andrew/vault/search_filter.lua` | ~450 | Filter pipeline |

### Modified Files (3)
| File | Changes | Purpose |
|------|---------|---------|
| `lua/andrew/vault/search.lua` | +200 lines | Advanced search UI |
| `lua/andrew/vault/saved_searches.lua` | +40 lines | Advanced dispatch |
| `lua/andrew/vault/config.lua` | +20 lines | Search config |

### Unchanged Files (benefit indirectly)
- `vault_index.lua` -- Existing metadata is sufficient
- `engine.lua` -- Existing helpers reused as-is
- `query/parser.lua` -- Separate query language
- `pickers.lua`, `frontmatter.lua`, `inline_fields.lua` -- No changes
