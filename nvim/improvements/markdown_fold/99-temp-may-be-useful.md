Your current markdown folding uses a three-layer system:
 1. ftplugin/markdown.lua sets foldmethod=expr with treesitter foldexpr
 2. render-markdown.lua switches expr → manual on BufWinEnter to freeze folds, then applies
 callout-specific open/close states
 3. callout_folds.lua persists user overrides via content fingerprinting

 The expr → manual switching hack works but is fragile — the two fold systems don't share a
 unified model. This plan consolidates everything into a single fold_manager.lua module that
 uses foldmethod=manual exclusively, computing fold boundaries from treesitter directly.

 Key constraint: Pure foldmethod=expr cannot preserve per-fold open/closed state (Neovim
 issue #32759). The unified method MUST use foldmethod=manual.

 ---
 New Module: lua/andrew/vault/fold_manager.lua

 A single module that owns all markdown fold computation and state management.

 Algorithm (the recompute(bufnr) pipeline)

 1. Parse treesitter tree — call vim.treesitter.get_parser(bufnr, "markdown"):parse()
 2. Collect @fold captures — iterate vim.treesitter.query.get("markdown", "folds") captures
 (this reads the base query + your ; extends blockquote addition)
 3. Build fold regions — for each captured node, extract start_line, end_line, kind
 (section/code_block/list/block_quote), trim trailing blank lines
 4. Assign nesting levels — sort regions (start asc, end desc), walk with a stack to compute
 depth
 5. Detect callout patterns — for block_quote regions, check first line for > [!TYPE]-/+,
 compute fingerprint via callout_folds.fingerprint()
 6. Apply folds — zE to clear all existing manual folds, then create folds from deepest level
  first via :{range}fold
 7. Apply open/close state — zR to open all, then close callout folds per suffix default and
 persisted user overrides

 Recomputation triggers

 ┌───────────────────┬────────────────┬─────────────────────────────────────────┐
 │       Event       │     Delay      │                  Notes                  │
 ├───────────────────┼────────────────┼─────────────────────────────────────────┤
 │ BufWinEnter *.md  │ 50ms defer     │ Initial setup, sets window fold options │
 ├───────────────────┼────────────────┼─────────────────────────────────────────┤
 │ BufWritePost *.md │ 30ms defer     │ Refresh after save                      │
 ├───────────────────┼────────────────┼─────────────────────────────────────────┤
 │ TextChanged *.md  │ 500ms debounce │ Catches structural edits in normal mode │
 ├───────────────────┼────────────────┼─────────────────────────────────────────┤
 │ :VaultFoldRefresh │ Immediate      │ Explicit command                        │
 └───────────────────┴────────────────┴─────────────────────────────────────────┘

 Public API

 M.recompute(bufnr)        -- full pipeline
 M.toggle_callout(bufnr)   -- toggle callout fold under cursor (replaces render-markdown.lua
 version)
 M.foldtext()              -- custom fold text (replaces global MarkdownFoldText)
 M.fold_all(bufnr)         -- zM
 M.unfold_all(bufnr)       -- zR
 M.set_fold_level(bufnr, n) -- close all, open folds with level <= n
 M.setup()                 -- register autocmds, commands, keymaps

 Per-buffer state

 Cache computed FoldRegion[] per buffer for set_fold_level and debug. Clean up on BufDelete.

 ---
 Changes to Existing Files

 1. lua/andrew/vault/callout_folds.lua — Promote private functions to public API

 Make these accessible to fold_manager (currently local):
 - parse_callout_header(line) → M.parse_callout_header
 - fingerprint(bufnr, header_lnum) → M.fingerprint
 - default_state(suffix) → M.default_state
 - load_db() → M.load_db

 Remove:
 - M.restore(bufnr) — absorbed into fold_manager's apply_fold_states()
 - The VaultCalloutFoldPersist FileType autocmd that sets <leader>mZ (moves to fold_manager)

 Keep: M.record_toggle, M.clear, M.invalidate, M.debug, M.setup
 (VaultFoldClear/VaultFoldDebug commands).

 2. ftplugin/markdown.lua — Remove fold settings and keymaps (lines 13-47)

 Remove:
 - Lines 13-18: foldmethod, foldexpr, foldlevel, foldcolumn, foldenable
 - Lines 19-25: foldtext and MarkdownFoldText() function
 - Lines 31-47: All fold-related keymaps (<Tab>, <leader>mf/mu/ml, zd/zD/zE/zf/zF)

 These all move to fold_manager.setup()'s FileType autocmd and BufWinEnter handler.

 3. lua/andrew/plugins/render-markdown.lua — Remove fold logic (lines 24-179)

 The entire callout fold system in the config function gets removed. Simplified to:

 config = function(_, opts)
   vim.treesitter.language.register("markdown", "blink-cmp-documentation")
   require("render-markdown").setup(opts)
 end,

 The opts table (callout definitions, checkboxes, etc.) is unchanged.

 4. lua/andrew/vault/init.lua — Add fold_manager.setup()

 After line 220 (callout_folds.setup()), add:
 require("andrew.vault.fold_manager").setup()

 5. queries/markdown/folds.scm — No changes

 Still defines what's foldable. The fold_manager reads this query via
 vim.treesitter.query.get().

 ---
 Implementation Order

 1. Refactor callout_folds.lua — promote private functions to public (non-breaking)
 2. Create fold_manager.lua — full implementation
 3. Remove fold logic from render-markdown.lua
 4. Remove fold settings/keymaps from ftplugin/markdown.lua
 5. Add fold_manager.setup() to vault/init.lua
 6. Remove M.restore() and <leader>mZ autocmd from callout_folds.lua

 ---
 Verification

 1. Open a markdown file with headings, code blocks, lists, blockquotes, and callouts with
 -/+ suffixes
 2. Verify: heading sections fold at correct nesting levels
 3. Verify: code blocks, blockquotes, nested lists all fold
 4. Verify: > [!NOTE]- callouts start collapsed, > [!NOTE]+ start expanded
 5. Verify: <leader>mz toggles callout fold and persists across buffer re-entry
 6. Verify: <Tab> toggles any fold, <leader>mf/<leader>mu fold/unfold all
 7. Verify: <leader>ml with level input opens/closes folds by depth
 8. Verify: editing text triggers debounced recompute (folds stay correct after structural
 changes)
 9. Verify: :VaultFoldRefresh manually recomputes
 10. Verify: non-vault markdown files still get structural folds (just no callout
 persistence)

