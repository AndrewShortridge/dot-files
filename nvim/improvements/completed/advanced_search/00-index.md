# Advanced Search Operators -- Documentation Index

## Quick Reference

This directory contains detailed documentation for implementing the Advanced
Search Operators feature (improvement #10). Each document covers a specific
aspect of the spec and its relationship to the existing codebase.

## Documents

| # | File | Description |
|---|------|-------------|
| 01 | [Current Search Architecture](01-current-search-architecture.md) | How `search.lua`, `engine.lua`, and fzf-lua work today. Every function, keymap, data flow, and fzf pattern documented. |
| 02 | [Saved Searches Architecture](02-saved-searches-architecture.md) | How `saved_searches.lua` works: JSON schema, execute dispatch, save/load/delete flows, commands. |
| 03 | [Vault Index Metadata](03-vault-index-metadata.md) | Every field in `VaultIndexEntry` that's available for search filtering. Single-pass parser details, derived lookup tables, public API. |
| 04 | [Query Syntax and Grammar](04-query-syntax-and-grammar.md) | Full query syntax reference, formal EBNF grammar, token types, AST node types, precedence rules, comparison with DQL. |
| 05 | [Tokenizer Implementation](05-tokenizer-implementation.md) | How to implement the tokenizer: algorithm, field token parsing, edge cases, test cases. |
| 06 | [Parser Implementation](06-parser-implementation.md) | How to implement the recursive descent parser: state object, precedence functions, implicit AND, AST examples. |
| 07 | [Filter Pipeline](07-filter-pipeline.md) | How AST evaluation works: split_ast, match_entry, field matchers, date parsing, ripgrep integration, result combination. |
| 08 | [UI Integration](08-ui-integration.md) | Prompt mode, live mode with `fzf_live`, graceful degradation, commands/keymaps, search help float, completion. |
| 09 | [Configuration](09-configuration.md) | New `config.search` section and all existing config values used by advanced search. |
| 10 | [Saved Search Integration](10-saved-search-integration.md) | Schema extension (`advanced` flag), dispatch changes, tracking changes, backward compatibility. |
| 11 | [Edge Cases and Error Handling](11-edge-cases-and-error-handling.md) | Malformed queries, missing fields, type coercion, tag matching, date edge cases, ripgrep integration, graceful degradation. |
| 12 | [Testing Plan](12-testing-plan.md) | Unit tests (tokenizer, parser, filter, date parsing), integration tests, performance benchmarks. |
| 13 | [Implementation Steps](13-implementation-steps.md) | Six ordered steps with dependencies, estimated complexity, and key decisions per step. |
| 14 | [Design Decisions](14-design-decisions.md) | 13 design decisions with rationale and trade-offs. |
| 15 | [DQL Parser Reference](15-dql-parser-reference.md) | Patterns from the existing DQL parser that can be reused or adapted. |

## Architecture Summary

```
New files:
  lua/andrew/vault/search_query.lua   -- Tokenizer + Parser (~350 lines)
  lua/andrew/vault/search_filter.lua  -- Filter Pipeline (~450 lines)

Modified files:
  lua/andrew/vault/search.lua         -- +200 lines (advanced UI)
  lua/andrew/vault/saved_searches.lua -- +40 lines (advanced dispatch)
  lua/andrew/vault/config.lua         -- +20 lines (search config)

Unchanged (used as-is):
  lua/andrew/vault/vault_index.lua    -- Metadata source
  lua/andrew/vault/engine.lua         -- FZF/ripgrep helpers
  lua/andrew/vault/query/parser.lua   -- Separate DQL (reference only)
```

## Key Data Flow

```
User Input: "type:meeting tag:urgent modified:>7d deploy"
     |
     v
[Tokenizer] --> [FIELD, FIELD, FIELD, TEXT, EOF]
     |
     v
[Parser] --> AST: AND(AND(AND(field, field), field), text)
     |
     v
[split_ast] --> metadata_ast + text_nodes
     |                |
     v                v
[match_entry]    [ripgrep --files-from]
  (in-memory)      (filesystem)
     |                |
     v                v
  file set A       file set B
     |                |
     +-------+--------+
             |
             v
    Combined file set (AND/OR/NOT)
             |
             v
      fzf-lua display
```
