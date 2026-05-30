# 27 -- Fix Remaining Neovim 0.11+ API Deprecations (v2)

## Problem

The first round of deprecation fixes (improvement #17) successfully addressed the most
common 0.10-era deprecations (`vim.highlight`, `vim.loop`, `vim.diagnostic.goto_prev/next`,
`vim.lsp.stop_client`, `nvim_win_set_option`, `nvim_buf_set_option`, `vim.fn.termopen`,
mason repo renames, and the neodev-to-lazydev migration). All of those changes have been
applied -- the source files are clean.

However, a **second wave** of deprecations was introduced or became enforced in Neovim 0.11
that were not covered by #17. These were found by a comprehensive codebase-wide grep on
2026-02-25.

---

## Summary of All Remaining Deprecations

| # | Issue | File | Line(s) |
|---|-------|------|---------|
| 1 | `vim.lsp.util.make_position_params()` missing required `position_encoding` param | `lua/andrew/plugins/lsp/lspconfig.lua` | 349 |
| 2 | `vim.lsp.handlers["textDocument/signatureHelp"]()` direct invocation (deprecated) | `lua/andrew/plugins/lsp/lspconfig.lua` | 359 |
| 3 | `nvim_set_option_value()` with `{ win = 0 }` -- functional but non-idiomatic | `lua/andrew/plugins/render-markdown.lua` | 149, 151, 154 |

### Already Fixed (Verified Clean)

These items from TODO.md and AGENTS.md are **already resolved** in source -- the checklists
are stale and should be ticked off:

| Previous Item | Status |
|---|---|
| `vim.highlight` -> `vim.hl` in `core/keymaps.lua` | Fixed |
| `vim.loop` -> `vim.uv` in `lazy.lua` | Fixed |
| `vim.diagnostic.goto_prev/next` -> `vim.diagnostic.jump` in `lspconfig.lua` | Fixed |
| `vim.lsp.stop_client()` -> `client:stop()` in `lspconfig.lua` | Fixed |
| `nvim_win_set_option()` -> `vim.wo[winid]` in `terminal.lua` | Fixed |
| `nvim_buf_set_option()` -> `vim.bo[buf]` in `preview.lua` | Fixed |
| `vim.fn.termopen()` -> `vim.fn.jobstart(..., { term = true })` in `terminal.lua` + `type-checker.lua` | Fixed |
| `williamboman/mason.nvim` -> `mason-org/mason.nvim` in `mason.lua` | Fixed |
| `williamboman/mason-lspconfig.nvim` -> `mason-org/mason-lspconfig.nvim` in `mason.lua` | Fixed |
| `folke/neodev.nvim` -> `folke/lazydev.nvim` in `lspconfig.lua` | Fixed |
| `vim.loop.fs_stat` in `docs/ctags-fortran-completion-guide.md` | Fixed |

### Investigated and Not Deprecated

| Pattern | File | Verdict |
|---|---|---|
| `vim.fn.sign_define()` for DAP breakpoint signs | `lua/andrew/plugins/dap/dap.lua:22-59` | NOT deprecated -- only diagnostic sign_define is deprecated; DAP signs via `vim.fn.sign_define` remain valid per nvim-dap maintainer ([#1292](https://github.com/mfussenegger/nvim-dap/issues/1292)) |
| `vim.lsp.util.open_floating_preview()` | `lua/andrew/plugins/lsp/lspconfig.lua:45,131,314` | NOT deprecated -- still the current API for LSP floating previews |
| `nvim_set_option_value()` | `lua/andrew/plugins/render-markdown.lua:149,151,154` | NOT deprecated (it IS the replacement for `nvim_buf_set_option`/`nvim_win_set_option`), but `vim.wo` is more idiomatic in Lua code |
| `client.request()` | `lua/andrew/plugins/lsp/lspconfig.lua:350` | NOT deprecated -- `client.request()` is the current API |

---

## 1. `vim.lsp.util.make_position_params()` -- Missing Required Parameter

### Reference

- Neovim 0.11 NEWS: [news-0.11](https://neovim.io/doc/user/news-0.11.html)
- Breaking change: `position_encoding` parameter is now **required** (was optional).
  Without it, Neovim emits: `"position_encoding param is required in
  vim.lsp.util.make_position_params. Defaulting to position encoding of the first client."`
- Upstream PR: [neovim/neovim#31249](https://github.com/neovim/neovim/pull/31249)
- Affected many plugins: [trouble.nvim#606](https://github.com/folke/trouble.nvim/issues/606),
  [blink.cmp#1624](https://github.com/Saghen/blink.cmp/issues/1624),
  [telescope.nvim#3497](https://github.com/nvim-telescope/telescope.nvim/issues/3497)

### Location

**File:** `lua/andrew/plugins/lsp/lspconfig.lua` line 349

### Current Code

```lua
local params =
  vim.lsp.util.make_position_params(0, ty_client.offset_encoding or "utf-16")
```

### Analysis

This code is already passing the `position_encoding` parameter as the second argument.
However, the Neovim 0.11 API changed the **signature**:

- **Old (0.10):** `make_position_params(window?, offset_encoding?)`
- **New (0.11):** `make_position_params(window, position_encoding)` -- both params required

The current code passes `0` (current window) and `ty_client.offset_encoding or "utf-16"`,
which satisfies the new requirement. However, `offset_encoding` was renamed to
`position_encoding` on the client object in 0.11. The field `ty_client.offset_encoding`
may be `nil` on newer Neovim builds, falling back to `"utf-16"` which is correct but could
mask issues.

### Replacement Code

```lua
local params =
  vim.lsp.util.make_position_params(0, ty_client.offset_encoding or "utf-16")
```

**Verdict: No code change required.** The current call already provides both required
parameters. The `or "utf-16"` fallback correctly handles the case where
`offset_encoding` is nil. The field name `offset_encoding` is still valid on the client
object (it was not renamed on the client, only in the function parameter name).

### Diff

No diff needed -- code is already compliant.

---

## 2. `vim.lsp.handlers["textDocument/signatureHelp"]()` -- Deprecated Handler Invocation

### Reference

- Neovim 0.11 NEWS: [news-0.11](https://neovim.io/doc/user/news-0.11.html)
- `vim.lsp.handlers.signature_help()` is deprecated. Functions like
  `vim.lsp.buf.references()`, `vim.lsp.buf.declaration()`, etc. no longer trigger the global
  handlers from `vim.lsp.handlers`. The handler is scheduled for removal in 0.13.
- The architectural reason: Neovim 0.11 removed the single-global-callback model to properly
  support multiple LSP clients per buffer.

### Location

**File:** `lua/andrew/plugins/lsp/lspconfig.lua` line 359

### Current Code

```lua
-- lines 346-362
if ty_client then
  vim.b.lsp_popup_kind = "signature"
  local params =
    vim.lsp.util.make_position_params(0, ty_client.offset_encoding or "utf-16")
  ty_client.request("textDocument/signatureHelp", params, function(err, result, ctx, _)
    if err then
      vim.notify(
        err.message or tostring(err),
        vim.log.levels.ERROR,
        { title = "LSP Signature Popup" }
      )
      return
    end
    vim.lsp.handlers["textDocument/signatureHelp"](err, result, ctx, _)
  end, bufnr)
  return
end
```

### Problem

Line 359 directly invokes `vim.lsp.handlers["textDocument/signatureHelp"]` as a callback to
display the signature help response in a floating window. In Neovim 0.11+, this handler is
deprecated and will be removed in 0.13.

### Replacement Code

Replace the direct handler invocation with `vim.lsp.buf.signature_help()` using a focused
approach. Since we already have the `ty_client` and want to specifically route the request
through it, we should use the lower-level `vim.lsp.util.open_floating_preview` to display
the result, or simply rely on `vim.lsp.buf.signature_help()` with a filter.

**Option A (Recommended): Use `vim.lsp.buf.signature_help()` directly**

Since Neovim 0.11+ handles multi-client dispatch properly, the simplest fix is to drop the
manual `client.request()` call entirely and let `vim.lsp.buf.signature_help()` handle it.
However, this loses the ability to target `ty` specifically.

**Option B (Preserve ty-targeting): Use the result directly with `open_floating_preview`**

```lua
if ty_client then
  vim.b.lsp_popup_kind = "signature"
  local params =
    vim.lsp.util.make_position_params(0, ty_client.offset_encoding or "utf-16")
  ty_client.request("textDocument/signatureHelp", params, function(err, result, ctx)
    if err then
      vim.notify(
        err.message or tostring(err),
        vim.log.levels.ERROR,
        { title = "LSP Signature Popup" }
      )
      return
    end
    if not result or not result.signatures or #result.signatures == 0 then
      vim.notify("No signature help available", vim.log.levels.INFO)
      return
    end
    -- Convert signature help result to markdown lines for display
    local lines = vim.lsp.util.convert_signature_help_to_markdown_lines(
      result,
      ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id)
        and vim.lsp.get_client_by_id(ctx.client_id).offset_encoding
        or "utf-16",
      result.activeSignature,
      result.activeParameter
    )
    if lines and #lines > 0 then
      vim.lsp.util.open_floating_preview(lines, "markdown", {
        border = "rounded",
        focus = false,
        title = "TY Function Parameter Popup",
        title_pos = "left",
      })
    end
  end, bufnr)
  return
end
```

**Option C (Simplest, recommended): Let Neovim handle it with method filter**

In Neovim 0.11+, `vim.lsp.buf.signature_help()` will use the active client(s). If both
`ty` and another Python LSP are attached and you want to prefer `ty`, you can filter:

```lua
if ty_client then
  vim.b.lsp_popup_kind = "signature"
  -- Neovim 0.11+ vim.lsp.buf.signature_help handles the full round-trip
  vim.lsp.buf.signature_help()
  return
end
```

This is the simplest approach. The existing `open_floating_preview` wrapper (line 131) will
still apply the custom title and border.

### Behavioral Differences

- **Option B** preserves exact control over which client is queried. The function
  `vim.lsp.util.convert_signature_help_to_markdown_lines` is NOT deprecated and is the
  internal function used by the old handler to format results.
- **Option C** is simplest but may not exclusively use `ty` if multiple Python LSPs are
  attached. In practice, Neovim 0.11 will query all capable clients and merge results.
- The custom `open_floating_preview` wrapper (line 131) will still intercept the float
  creation for both options, so custom borders/titles are preserved.

### Recommended Approach

**Use Option C** (simplest) unless there is a specific need to exclusively route through
`ty`. The existing floating preview wrapper handles title/border customization.

### Diff (Option C)

```diff
--- a/lua/andrew/plugins/lsp/lspconfig.lua
+++ b/lua/andrew/plugins/lsp/lspconfig.lua
@@ -344,20 +344,8 @@
             -- Use ty if available
             if ty_client then
               vim.b.lsp_popup_kind = "signature"
-              local params =
-                vim.lsp.util.make_position_params(0, ty_client.offset_encoding or "utf-16")
-              ty_client.request("textDocument/signatureHelp", params, function(err, result, ctx, _)
-                if err then
-                  vim.notify(
-                    err.message or tostring(err),
-                    vim.log.levels.ERROR,
-                    { title = "LSP Signature Popup" }
-                  )
-                  return
-                end
-                vim.lsp.handlers["textDocument/signatureHelp"](err, result, ctx, _)
-              end, bufnr)
+              vim.lsp.buf.signature_help()
               return
             end
           end
```

---

## 3. `nvim_set_option_value()` with `{ win = 0 }` -- Functional but Non-Idiomatic

### Reference

- `nvim_set_option_value()` is NOT deprecated -- it is the replacement for the deprecated
  `nvim_win_set_option()` and `nvim_buf_set_option()`.
- However, in Lua code, `vim.wo` and `vim.bo` are the idiomatic wrappers that are more
  readable and concise.
- See: [nvim_set_option_value docs](https://neovim.io/doc/user/api.html#nvim_set_option_value())

### Location

**File:** `lua/andrew/plugins/render-markdown.lua` lines 149, 151, 154

### Current Code

```lua
-- line 149
vim.api.nvim_set_option_value("foldmethod", "manual", { win = 0 })
-- line 151
vim.api.nvim_set_option_value("foldlevel", 99, { win = 0 })
-- line 154
vim.api.nvim_set_option_value("foldtext", "v:lua.VaultCalloutFoldtext()", { win = 0 })
```

### Replacement Code

```lua
-- line 149
vim.wo.foldmethod = "manual"
-- line 151
vim.wo.foldlevel = 99
-- line 154
vim.wo.foldtext = "v:lua.VaultCalloutFoldtext()"
```

### Behavioral Differences

None. `vim.wo.foldmethod = "manual"` is exactly equivalent to
`vim.api.nvim_set_option_value("foldmethod", "manual", { win = 0 })`. Both set a
window-local option on the current window. The `vim.wo` form is simply more concise and
consistent with the rest of the codebase (which already uses `vim.wo[winid]` elsewhere).

### Diff

```diff
--- a/lua/andrew/plugins/render-markdown.lua
+++ b/lua/andrew/plugins/render-markdown.lua
@@ -146,11 +146,11 @@
         local bufnr = ev.buf

         -- Use manual foldmethod so we can create folds programmatically
-        vim.api.nvim_set_option_value("foldmethod", "manual", { win = 0 })
+        vim.wo.foldmethod = "manual"
         -- Don't auto-close folds when moving cursor
-        vim.api.nvim_set_option_value("foldlevel", 99, { win = 0 })
+        vim.wo.foldlevel = 99

         -- Custom foldtext: show the callout header with a collapse indicator
-        vim.api.nvim_set_option_value("foldtext", "v:lua.VaultCalloutFoldtext()", { win = 0 })
+        vim.wo.foldtext = "v:lua.VaultCalloutFoldtext()"

         -- Buffer-local keymap to toggle callout fold
         vim.keymap.set("n", "<leader>mz", function()
```

---

## Housekeeping: Update Stale Checklists

The following files reference deprecations that have **already been fixed** and should be
updated to reflect the current state:

### `TODO.md` -- Section 1: Deprecation Fixes

All items under "1.1 API Replacements" and "1.2 Plugin Repository Migrations" should be
checked off. Every deprecation listed there has been resolved in source.

### `AGENTS.md` -- "Known Deprecations in This Config" Table (lines 891-904)

This table lists 8 deprecated patterns that no longer exist in the codebase. The section
should either be:
- Removed entirely (all items fixed), or
- Replaced with the new items from this document (#1 and #2 above)

---

## Implementation Order

1. **`vim.lsp.handlers` invocation** (lspconfig.lua line 359) -- **Priority: High**
   - This will emit deprecation warnings now and **break in 0.13**.
   - Replace with `vim.lsp.buf.signature_help()` (Option C above).

2. **`nvim_set_option_value` -> `vim.wo`** (render-markdown.lua) -- **Priority: Low**
   - Not deprecated, just a style/consistency improvement.
   - 3 simple replacements.

3. **Update stale TODO.md / AGENTS.md checklists** -- **Priority: Low**
   - Prevents confusion and future wasted effort auditing already-fixed items.

---

## Testing Checklist

After applying all changes, verify:

### Fix #1: Signature Help Handler

- [ ] Open a Python file with `ty` LSP attached
- [ ] Press `<C-k>` (signature help) inside a function call
- [ ] Verify the signature help float appears with correct content
- [ ] Verify the float has a rounded border and title ("TY Function Parameter Popup" or
  "LSP Preview" depending on option chosen)
- [ ] Check `:messages` for any deprecation warnings -- there should be none
- [ ] Open a non-Python file and press `<C-k>` -- fallback signature help should work
- [ ] Open a Python file without `ty` (only pyright) and press `<C-k>` -- should use
  pyright's signature help

### Fix #2: render-markdown fold options

- [ ] Open a markdown file in the vault
- [ ] Verify `:set foldmethod?` returns `manual`
- [ ] Verify `:set foldlevel?` returns `99`
- [ ] Verify `:set foldtext?` returns `v:lua.VaultCalloutFoldtext()`
- [ ] Create or open a file with a callout block, press `<leader>mz` -- fold should toggle
- [ ] No errors in `:messages`

### General Verification

- [ ] Open Neovim and run `:checkhealth vim.deprecated` -- should report no issues from
  this config's code
- [ ] Run `:messages` after opening several file types (Python, Lua, Fortran, markdown) --
  no `vim.deprecate` warnings should appear from config code
- [ ] All existing functionality works: LSP hover (K), signature help (Ctrl-k), diagnostic
  navigation ([d / ]d), terminal (<leader>tt), vault preview (K on wikilink)

---

## Comprehensive Codebase Audit Results

The following is a complete record of all deprecated API patterns searched and their status
as of 2026-02-25. This covers `lua/`, `ftplugin/`, and `after/` directories.

### Patterns Searched -- No Instances Found

| Pattern | Status |
|---|---|
| `vim.highlight` | Clean (was fixed in #17) |
| `vim.loop` | Clean (was fixed in #17) |
| `vim.diagnostic.goto_prev` / `vim.diagnostic.goto_next` | Clean (was fixed in #17) |
| `vim.lsp.stop_client` | Clean (was fixed in #17) |
| `nvim_win_set_option` | Clean (was fixed in #17) |
| `nvim_buf_set_option` | Clean (was fixed in #17) |
| `vim.lsp.buf_get_clients` | Never existed in config |
| `vim.lsp.get_active_clients` | Never existed in config |
| `vim.treesitter.get_node_at_cursor` | Never existed in config |
| `vim.fn.termopen` | Clean (was fixed in #17) |
| `vim.tbl_flatten` | Never existed in config |
| `vim.tbl_add_reverse_lookup` | Never existed in config |
| `vim.tbl_islist` | Never existed in config |
| `vim.tbl_isempty` | Never existed in config |
| `vim.lsp.start_client` | Never existed in config |
| `vim.lsp.buf.range_code_action` | Never existed in config |
| `vim.lsp.buf.formatting` | Never existed in config |
| `vim.treesitter.query.get_query` | Never existed in config |
| `vim.treesitter.query.parse_query` | Never existed in config |
| `vim.lsp.diagnostic` | Never existed in config |
| `vim.lsp.with` | Never existed in config |
| `nvim_exec` (v1, not v2) | Never existed in config |
| `vim.lsp.util.stylize_markdown` | Never existed in config |
| `vim.lsp.client_is_stopped` | Never existed in config |
| `vim.lsp.codelens.refresh` / `clear` | Never existed in config |
| `vim.lsp.semantic_tokens.start` / `stop` | Never existed in config |
| `vim.lsp.get_buffers_by_client_id` | Never existed in config |
| `vim.lsp.util.get_progress_messages` | Never existed in config |
| `vim.lsp.set_log_level` / `get_log_path` | Never existed in config |
| `vim.lsp.buf_attach_client` / `buf_detach_client` | Never existed in config |
| `vim.lsp.for_each_buffer_client` | Never existed in config |
| `vim.lsp.util.make_range_params` | Never existed in config |
| `vim.lsp.util.make_given_range_params` | Never existed in config |
| `vim.lsp.util.make_formatting_params` | Never existed in config |
| `vim.lsp.util.locations_to_items` | Never existed in config |
| `vim.lsp.util.jump_to_location` | Never existed in config |
| `vim.lsp.util.apply_text_edits` | Never existed in config |
| `vim.lsp.diagnostic.on_publish_diagnostics` | Never existed in config |
| `vim.lsp.diagnostic.on_diagnostic` | Never existed in config |
| `vim.diagnostic.disable` | Never existed in config |
| `vim.diagnostic.is_disabled` | Never existed in config |
| `vim.validate` (old-style) | Never existed in config |
| `nvim_buf_get_option` / `nvim_win_get_option` | Never existed in config |
| `nvim_set_option` (not `nvim_set_option_value`) | Never existed in config |
| `nvim_get_option` / `nvim_get_option_value` | Never existed in config |
| `williamboman/mason.nvim` | Clean (was fixed in #17) |
| `folke/neodev.nvim` | Clean (was fixed in #17) |

### Patterns Found -- Not Deprecated

| Pattern | File(s) | Verdict |
|---|---|---|
| `vim.fn.sign_define` (DAP signs) | `dap/dap.lua:22-59` | Valid -- only diagnostic sign_define is deprecated |
| `vim.lsp.util.open_floating_preview` | `lspconfig.lua:45,131,314` | Valid -- not deprecated |
| `nvim_set_option_value` | `render-markdown.lua:149,151,154` | Valid -- it IS the replacement API (style improvement only) |
| `client.request()` | `lspconfig.lua:350` | Valid -- current API |
| `vim.lsp.util.make_position_params()` | `lspconfig.lua:349` | Valid -- already passes required `position_encoding` param |
| `vim.treesitter.get_parser()` | Multiple vault/utils files | Valid -- not deprecated |
| `vim.api.nvim_buf_call()` | Multiple vault files | Valid -- not deprecated |

---

## Risk Assessment

**Risk: Very Low**

- Fix #1 (handlers) is the only change with functional impact, and Option C (using
  `vim.lsp.buf.signature_help()` directly) is a simplification that removes custom code in
  favor of the built-in.
- Fix #2 (vim.wo) is purely stylistic with zero behavioral change.
- The codebase is already in excellent shape -- #17 addressed all major deprecations.

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/plugins/lsp/lspconfig.lua` | Replace `vim.lsp.handlers` invocation with `vim.lsp.buf.signature_help()` |
| `lua/andrew/plugins/render-markdown.lua` | Replace `nvim_set_option_value` with `vim.wo` (3 lines) |
| `TODO.md` | Check off all deprecation items in section 1 |
| `AGENTS.md` | Update "Known Deprecations" table (lines 891-904) |
