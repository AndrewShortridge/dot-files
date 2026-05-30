# Implementation Order & Dependency Graph

## Dependency Chain

```
#17 Deprecation Fixes
 └──> #10 Code Duplication Cleanup
       └──> #08 Cache Invalidation Fixes
             └──> #09 Lazy Cache Building
                   └──> #07 Template Variable Substitution

#12 Markdown Text Objects  (independent)
 └──> #13 Markdown Keybindings  (benefits from #12)

#11 Missing Snippets  (independent, do last)
```

## Execution Order

| Phase | Doc | File | Key Files Modified | Est. Risk |
|-------|-----|------|--------------------|-----------|
| 1 | [#17](./17-deprecation-fixes.md) | Deprecation Fixes | `keymaps.lua`, `lazy.lua`, `lspconfig.lua`, `terminal.lua`, `mason.lua`, `preview.lua`, `type-checker.lua` | Low |
| 2 | [#10](./10-code-duplication-cleanup.md) | Code Duplication Cleanup | `link_utils.lua`, `preview.lua`, `linkcheck.lua`, `linkdiag.lua` | Medium |
| 3 | [#08](./08-cache-invalidation-fixes.md) | Cache Invalidation Fixes | `wikilinks.lua`, `engine.lua`, `linkdiag.lua`, `init.lua`, `config.lua` | Medium |
| 4 | [#09](./09-lazy-cache-building.md) | Lazy Cache Building | `wikilinks.lua`, `engine.lua`, `linkcheck.lua`, `tags.lua` | High |
| 5 | [#07](./07-template-variable-substitution.md) | Template Variable Substitution | `engine.lua`, templates/ | Low |
| 6 | [#12](./12-markdown-text-objects.md) | Markdown Text Objects | `md-textobjects.lua` (new), `ftplugin/markdown.lua` | Low |
| 7 | [#13](./13-markdown-keybindings.md) | Markdown Keybindings | `ftplugin/markdown.lua` | Low |
| 8 | [#11](./11-missing-snippets.md) | Missing Snippets | `luasnippets/markdown.lua`, `lua/andrew/utils/tex.lua` | Low |

## Why This Order

### Phase 1: #17 Deprecation Fixes
- Zero dependencies, zero functional change
- Eliminates Neovim 0.11+ warnings that clutter `:messages`
- Touches 7 files but each change is a mechanical rename
- Must go first: later phases modify some of the same files (`preview.lua`, `engine.lua`)

### Phase 2: #10 Code Duplication Cleanup
- Refactors `preview.lua`, `linkcheck.lua`, `linkdiag.lua` — all modified by #08/#09
- Consolidates heading extraction into `link_utils.lua` (single source of truth)
- **Do before #08**: cache invalidation fixes reference `linkdiag.get_headings()` which gets simplified here
- **Do before #09**: lazy cache changes to `linkcheck.lua` are cleaner against deduplicated code
- Net result: -68 lines, cleaner call sites for subsequent phases

### Phase 3: #08 Cache Invalidation Fixes
- Fixes correctness bugs (external edits missed, vault switch doesn't clear caches)
- Adds `FocusGained` autocmd, `vim.uv` file watcher, vault-switch invalidation
- **Do before #09**: lazy loading must invalidate correctly; wrong order means lazy caches serve stale data silently
- Modifies `wikilinks.lua` and `engine.lua` — same files #09 restructures

### Phase 4: #09 Lazy Cache Building
- Highest risk: restructures initialization flow for `wikilinks.lua`, `engine.lua`, `linkcheck.lua`, `tags.lua`
- **Depends on #10**: deduplicated code is simpler to convert to lazy patterns
- **Depends on #08**: invalidation hooks must exist before making caches lazy (otherwise stale data has no recovery path)
- Expected payoff: ~100-170ms faster startup

### Phase 5: #07 Template Variable Substitution
- Modifies `engine.lua` (adds `substitute()` function, extends `render()`)
- **Do after #09**: both touch `engine.lua`; template changes are additive and won't conflict once lazy cache restructuring is settled
- Low risk: backward-compatible (existing `${var}` syntax preserved alongside new `{{var}}`)

### Phase 6-7: #12 Text Objects, #13 Keybindings
- Both are independent of the vault internals chain (#10→#08→#09→#07)
- #13 benefits from #12: keybindings can reference text objects (e.g., `d ac` to delete code block)
- Could be done in parallel with phases 1-5 but sequencing after reduces cognitive load
- Both primarily modify `ftplugin/markdown.lua` — do #12 first to avoid merge conflicts

### Phase 8: #11 Missing Snippets
- Purely additive: 469 new snippets, no existing code modified
- Largest changeset by line count (2,112 lines of docs, ~3,000+ lines of snippet code)
- Zero conflict risk — save for last as a reward after the hard refactoring work

## File Conflict Matrix

Files touched by multiple phases (implement in order to avoid conflicts):

| File | Phases | Resolution |
|------|--------|------------|
| `engine.lua` | #08, #09, #07 | #08 adds invalidation → #09 restructures init → #07 adds substitute() |
| `wikilinks.lua` | #08, #09 | #08 fixes invalidation → #09 converts to lazy |
| `linkcheck.lua` | #10, #09 | #10 deduplicates → #09 converts to async |
| `linkdiag.lua` | #10, #08 | #10 simplifies get_headings → #08 adds inode tracking |
| `preview.lua` | #17, #10 | #17 fixes nvim_buf_set_option → #10 removes duplicate functions |
| `ftplugin/markdown.lua` | #12, #13 | #12 adds text objects → #13 adds keybindings |
| `link_utils.lua` | #10 | Only touched by #10 (adds extract_headings) |
| `tags.lua` | #09 | Only touched by #09 (single-pass ripgrep) |
| `lua/andrew/utils/tex.lua` | #11 | Only touched by #11 (new readable-name snippets) |

## Verification Checkpoints

After each phase, verify before proceeding:

1. **#17**: `nvim --startuptime /tmp/st.log` — no deprecation warnings in `:messages`
2. **#10**: Run existing tests: `nvim --headless -u NONE -l tests/test_vault_fixes.lua` — all pass
3. **#08**: Open vault file, edit externally, return to Neovim — cache refreshes
4. **#09**: `nvim --startuptime /tmp/st.log` — compare startup time before/after
5. **#07**: Create note from template — `{{date}}`, `{{title}}` replaced correctly
6. **#12**: In markdown file: `dac` deletes code block, `vil` selects list item text
7. **#13**: In markdown file: visual select text, `<leader>mb` wraps in `**bold**`
8. **#11**: In markdown file: type `;simulation-figures` — section inserts correctly
