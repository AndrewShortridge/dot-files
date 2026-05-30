# 17 -- Fix All Neovim 0.11+ Deprecations

## Problem

Multiple deprecated Neovim 0.11+ APIs and outdated plugin repository references remain in
this config. These trigger runtime warnings now and will break in a future Neovim release.
This document catalogs every instance found across the entire `~/.config/nvim` tree, with
exact line numbers, current code, replacement code, behavioral notes, and a complete
before/after diff for each file.

---

## Summary of All Deprecations Found

| # | Deprecated API / Reference | File | Line(s) |
|---|---------------------------|------|---------|
| 1 | `vim.highlight.on_yank` | `lua/andrew/core/keymaps.lua` | 71 |
| 2 | `vim.loop.fs_stat` | `lua/andrew/lazy.lua` | 16 |
| 3 | `vim.diagnostic.goto_prev` | `lua/andrew/plugins/lsp/lspconfig.lua` | 277 |
| 4 | `vim.diagnostic.goto_next` | `lua/andrew/plugins/lsp/lspconfig.lua` | 281 |
| 5 | `vim.lsp.stop_client()` | `lua/andrew/plugins/lsp/lspconfig.lua` | 577 |
| 6 | `folke/neodev.nvim` dependency | `lua/andrew/plugins/lsp/lspconfig.lua` | 28 |
| 7 | `nvim_win_set_option()` (x7 calls) | `lua/andrew/custom/plugins/terminal.lua` | 143-153 |
| 8 | `vim.fn.termopen()` | `lua/andrew/custom/plugins/terminal.lua` | 129 |
| 9 | `vim.fn.termopen()` | `lua/andrew/plugins/type-checker.lua` | 44 |
| 10 | `vim.api.nvim_buf_set_option()` | `lua/andrew/vault/preview.lua` | 337 |
| 11 | `williamboman/mason.nvim` | `lua/andrew/plugins/lsp/mason.lua` | 38, 80 |
| 12 | `williamboman/mason-lspconfig.nvim` | `lua/andrew/plugins/lsp/mason.lua` | 15-16 |
| 13 | `vim.loop.fs_stat` (docs only) | `docs/ctags-fortran-completion-guide.md` | 331 |

---

## 1. `vim.highlight` -> `vim.hl`

### Location

**File:** `lua/andrew/core/keymaps.lua` line 71

### Current Code (deprecated)

```lua
vim.highlight.on_yank({ higroup = "IncSearch", timeout = 300 })
```

### Replacement Code

```lua
vim.hl.on_yank({ higroup = "IncSearch", timeout = 300 })
```

### Behavioral Differences

None. `vim.hl` is a direct rename of `vim.highlight`. The function signature, parameters,
and behavior are identical. `vim.highlight` is a thin alias that emits a deprecation
warning.

### Diff

```diff
--- a/lua/andrew/core/keymaps.lua
+++ b/lua/andrew/core/keymaps.lua
@@ -68,7 +68,7 @@
   group = vim.api.nvim_create_augroup("highlight-yank", { clear = true }),
   callback = function()
     -- Highlight the yanked text region for 300ms
-    vim.highlight.on_yank({ higroup = "IncSearch", timeout = 300 })
+    vim.hl.on_yank({ higroup = "IncSearch", timeout = 300 })
   end,
 })
```

---

## 2. `vim.loop` -> `vim.uv`

### Location

**File:** `lua/andrew/lazy.lua` line 16

### Current Code (deprecated)

```lua
if not vim.loop.fs_stat(lazypath) then
```

### Replacement Code

```lua
if not vim.uv.fs_stat(lazypath) then
```

### Behavioral Differences

None. `vim.uv` is a direct rename of `vim.loop`. Both expose the same libuv bindings.
`vim.loop` now emits a deprecation warning.

### Diff

```diff
--- a/lua/andrew/lazy.lua
+++ b/lua/andrew/lazy.lua
@@ -13,7 +13,7 @@
 local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"

 -- Check if lazy.nvim is already installed
-if not vim.loop.fs_stat(lazypath) then
+if not vim.uv.fs_stat(lazypath) then
   -- Clone the repository using Git with blobless clone for faster downloads
   vim.fn.system({
     "git",
```

### Also Found In (documentation only)

**File:** `docs/ctags-fortran-completion-guide.md` line 331
This is a code example inside a markdown fenced block, not executed code. Update for
accuracy if desired, but it will not trigger runtime warnings.

```diff
--- a/docs/ctags-fortran-completion-guide.md
+++ b/docs/ctags-fortran-completion-guide.md
@@ -328,7 +328,7 @@
   local tags_file = project_root .. "/.tags-headers"

   if vim.fn.filereadable(tags_file) == 1 then
-    local stat = vim.loop.fs_stat(tags_file)
+    local stat = vim.uv.fs_stat(tags_file)
     local size = stat and stat.size or 0
```

---

## 3. `vim.diagnostic.goto_prev/next()` -> `vim.diagnostic.jump()`

### Location

**File:** `lua/andrew/plugins/lsp/lspconfig.lua` lines 277 and 281

### Current Code (deprecated)

```lua
-- line 277
keymap.set("n", "[d", vim.diagnostic.goto_prev, opts)

-- line 281
keymap.set("n", "]d", vim.diagnostic.goto_next, opts)
```

### Replacement Code

```lua
-- line 277
opts.desc = "Go to previous diagnostic"
keymap.set("n", "[d", function()
  vim.diagnostic.jump({ count = -1, float = true })
end, opts)

-- line 281
opts.desc = "Go to next diagnostic"
keymap.set("n", "]d", function()
  vim.diagnostic.jump({ count = 1, float = true })
end, opts)
```

### Behavioral Differences

- `vim.diagnostic.jump()` unifies `goto_prev` and `goto_next` into a single function.
  Direction is controlled by the sign of `count`: negative = backward, positive = forward.
- `float = true` replicates the default behavior of `goto_prev`/`goto_next`, which
  automatically opens a float showing the diagnostic at the new position.
- `vim.diagnostic.jump()` also accepts `severity`, `wrap`, `win_id`, and `namespace`
  options in the same table -- a superset of the old API.

### Diff

```diff
--- a/lua/andrew/plugins/lsp/lspconfig.lua
+++ b/lua/andrew/plugins/lsp/lspconfig.lua
@@ -274,11 +274,13 @@

         -- Navigate to previous diagnostic
         opts.desc = "Go to previous diagnostic"
-        keymap.set("n", "[d", vim.diagnostic.goto_prev, opts)
+        keymap.set("n", "[d", function()
+          vim.diagnostic.jump({ count = -1, float = true })
+        end, opts)

         -- Navigate to next diagnostic
         opts.desc = "Go to next diagnostic"
-        keymap.set("n", "]d", vim.diagnostic.goto_next, opts)
+        keymap.set("n", "]d", function()
+          vim.diagnostic.jump({ count = 1, float = true })
+        end, opts)
```

---

## 4. `vim.lsp.stop_client()` -> `client:stop()`

### Location

**File:** `lua/andrew/plugins/lsp/lspconfig.lua` line 577

### Current Code (deprecated)

```lua
vim.api.nvim_create_user_command("CtagsLspRestart", function()
  vim.lsp.stop_client(vim.lsp.get_clients({ name = "ctags_lsp" }))
  vim.defer_fn(function()
    vim.cmd("edit")  -- Reopen buffer to trigger LSP attach
    vim.notify("Ctags LSP restarted", vim.log.levels.INFO)
  end, 100)
end, { desc = "Restart ctags LSP server" })
```

### Replacement Code

```lua
vim.api.nvim_create_user_command("CtagsLspRestart", function()
  for _, client in ipairs(vim.lsp.get_clients({ name = "ctags_lsp" })) do
    client:stop()
  end
  vim.defer_fn(function()
    vim.cmd("edit")  -- Reopen buffer to trigger LSP attach
    vim.notify("Ctags LSP restarted", vim.log.levels.INFO)
  end, 100)
end, { desc = "Restart ctags LSP server" })
```

### Behavioral Differences

- `vim.lsp.stop_client()` accepted a single client, a client ID, or a list of clients/IDs.
  It is now deprecated.
- `client:stop()` is a method on the client object itself. When iterating over multiple
  clients, call `:stop()` on each one individually.
- The stop behavior (graceful shutdown then SIGTERM) is identical.

### Diff

```diff
--- a/lua/andrew/plugins/lsp/lspconfig.lua
+++ b/lua/andrew/plugins/lsp/lspconfig.lua
@@ -574,7 +574,9 @@
     -- Ctags LSP Commands
     -- =============================================================================
     vim.api.nvim_create_user_command("CtagsLspRestart", function()
-      vim.lsp.stop_client(vim.lsp.get_clients({ name = "ctags_lsp" }))
+      for _, client in ipairs(vim.lsp.get_clients({ name = "ctags_lsp" })) do
+        client:stop()
+      end
       vim.defer_fn(function()
         vim.cmd("edit")  -- Reopen buffer to trigger LSP attach
         vim.notify("Ctags LSP restarted", vim.log.levels.INFO)
```

---

## 5. `nvim_win_set_option()` -> `vim.wo[winid]`

### Location

**File:** `lua/andrew/custom/plugins/terminal.lua` lines 143-153

### Current Code (deprecated)

```lua
  -- Configure window appearance
  vim.api.nvim_win_set_option(floating_terminal.winid, "number", false)
  vim.api.nvim_win_set_option(floating_terminal.winid, "relativenumber", false)
  vim.api.nvim_win_set_option(floating_terminal.winid, "signcolumn", "no")
  vim.api.nvim_win_set_option(floating_terminal.winid, "foldcolumn", "0")
  vim.api.nvim_win_set_option(floating_terminal.winid, "spell", false)
  vim.api.nvim_win_set_option(floating_terminal.winid, "cursorline", false)
  vim.api.nvim_win_set_option(
    floating_terminal.winid,
    "winblend",
    floating_terminal.options.winblend
  )
```

### Replacement Code

```lua
  -- Configure window appearance
  local winid = floating_terminal.winid
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].spell = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].winblend = floating_terminal.options.winblend
```

### Behavioral Differences

- `vim.api.nvim_win_set_option()` was a C API function that is now deprecated.
- `vim.wo[winid]` is the idiomatic Lua wrapper. Behavior is identical -- both set
  window-local options on a specific window by ID.
- `vim.wo[winid]` is also more concise and consistent with `vim.bo[bufnr]` for
  buffer-local options.

### Diff

```diff
--- a/lua/andrew/custom/plugins/terminal.lua
+++ b/lua/andrew/custom/plugins/terminal.lua
@@ -140,17 +140,14 @@
   end

   -- Configure window appearance
-  vim.api.nvim_win_set_option(floating_terminal.winid, "number", false)
-  vim.api.nvim_win_set_option(floating_terminal.winid, "relativenumber", false)
-  vim.api.nvim_win_set_option(floating_terminal.winid, "signcolumn", "no")
-  vim.api.nvim_win_set_option(floating_terminal.winid, "foldcolumn", "0")
-  vim.api.nvim_win_set_option(floating_terminal.winid, "spell", false)
-  vim.api.nvim_win_set_option(floating_terminal.winid, "cursorline", false)
-  vim.api.nvim_win_set_option(
-    floating_terminal.winid,
-    "winblend",
-    floating_terminal.options.winblend
-  )
+  local winid = floating_terminal.winid
+  vim.wo[winid].number = false
+  vim.wo[winid].relativenumber = false
+  vim.wo[winid].signcolumn = "no"
+  vim.wo[winid].foldcolumn = "0"
+  vim.wo[winid].spell = false
+  vim.wo[winid].cursorline = false
+  vim.wo[winid].winblend = floating_terminal.options.winblend

   -- Enter insert mode if not already in it
   if not vim.opt_local.insertmode:get() then
```

---

## 6. `vim.fn.termopen()` -> `vim.fn.jobstart(..., { term = true })`

### Locations

**File 1:** `lua/andrew/custom/plugins/terminal.lua` line 129
**File 2:** `lua/andrew/plugins/type-checker.lua` line 44

### 6a. terminal.lua

#### Current Code (deprecated)

```lua
floating_terminal.termpid = vim.fn.termopen(floating_terminal.options.shell)
```

#### Replacement Code

```lua
floating_terminal.termpid = vim.fn.jobstart(floating_terminal.options.shell, { term = true })
```

#### Diff

```diff
--- a/lua/andrew/custom/plugins/terminal.lua
+++ b/lua/andrew/custom/plugins/terminal.lua
@@ -126,7 +126,7 @@
     vim.bo[floating_terminal.bufnr].bufhidden = "hide"

     -- Start terminal process
-    floating_terminal.termpid = vim.fn.termopen(floating_terminal.options.shell)
+    floating_terminal.termpid = vim.fn.jobstart(floating_terminal.options.shell, { term = true })

     -- Auto-hide on terminal exit (preserve session for reopening)
     if floating_terminal.options.hide_on_exit then
```

### 6b. type-checker.lua

#### Current Code (deprecated)

```lua
vim.fn.termopen(cmd, {
  cwd = vim.fn.getcwd(),  -- Use current working directory
  on_exit = function(_, code, _)
    -- Notify on completion (success=info, failure=error)
    local level = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
    local msg = string.format("%s exited with code %d", title, code)
    vim.schedule(function()
      vim.notify(msg, level, { title = "TypeCheck" })
    end)
  end,
})
```

#### Replacement Code

```lua
vim.fn.jobstart(cmd, {
  term = true,
  cwd = vim.fn.getcwd(),  -- Use current working directory
  on_exit = function(_, code, _)
    -- Notify on completion (success=info, failure=error)
    local level = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
    local msg = string.format("%s exited with code %d", title, code)
    vim.schedule(function()
      vim.notify(msg, level, { title = "TypeCheck" })
    end)
  end,
})
```

#### Diff

```diff
--- a/lua/andrew/plugins/type-checker.lua
+++ b/lua/andrew/plugins/type-checker.lua
@@ -41,7 +41,8 @@
       vim.bo[buf].filetype = "typecheck"    -- Syntax highlighting

       -- Run command in terminal
-      vim.fn.termopen(cmd, {
-        cwd = vim.fn.getcwd(),  -- Use current working directory
+      vim.fn.jobstart(cmd, {
+        term = true,
+        cwd = vim.fn.getcwd(),  -- Use current working directory
         on_exit = function(_, code, _)
```

### Behavioral Differences

- `vim.fn.termopen()` has been a thin wrapper around `vim.fn.jobstart()` with `term=true`
  since its inception. It is deprecated in Neovim 0.11.
- Adding `term = true` to `jobstart()` opts produces identical terminal behavior.
- All existing options (`cwd`, `on_exit`, etc.) carry over unchanged.

---

## 7. `nvim_buf_set_option()` -> `vim.bo[bufnr]`

### Location

**File:** `lua/andrew/vault/preview.lua` line 337

### Current Code (deprecated)

```lua
vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
```

### Replacement Code

```lua
vim.bo[buf].filetype = "markdown"
```

### Behavioral Differences

None. `vim.bo[bufnr]` is the idiomatic Lua wrapper for `nvim_buf_set_option()`. The
underlying behavior is identical.

### Diff

```diff
--- a/lua/andrew/vault/preview.lua
+++ b/lua/andrew/vault/preview.lua
@@ -334,7 +334,7 @@
   })

   -- Buffer options
-  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
+  vim.bo[buf].filetype = "markdown"

   -- Window options
   vim.wo[win].conceallevel = 2
```

---

## 8. mason.nvim Repository Migration

### Location

**File:** `lua/andrew/plugins/lsp/mason.lua` lines 15-16, 38, 80

The mason plugins have moved from the `williamboman` GitHub user to the `mason-org`
organization. The old URLs redirect, but lazy.nvim will show a warning about the repo
change and the lock file entry will become stale.

### Current Code

```lua
-- line 15-16
-- Repository: https://github.com/williamboman/mason-lspconfig.nvim
"williamboman/mason-lspconfig.nvim",

-- line 38
"williamboman/mason.nvim",

-- line 80
"williamboman/mason.nvim",
```

### Replacement Code

```lua
-- line 15-16
-- Repository: https://github.com/mason-org/mason-lspconfig.nvim
"mason-org/mason-lspconfig.nvim",

-- line 38
"mason-org/mason.nvim",

-- line 80
"mason-org/mason.nvim",
```

### Post-Change Steps

After updating the plugin specs:

1. Run `:Lazy sync` to re-clone from the new URLs.
2. The `lazy-lock.json` entries for `mason.nvim`, `mason-lspconfig.nvim`, and `neodev.nvim`
   will be updated automatically by lazy.nvim.

### Behavioral Differences

None for the repo rename alone. However, `mason-org/mason.nvim` v2.0+ introduced
breaking changes to its internal module structure. If you are pinned to v1.x, the rename
alone is safe. If upgrading to v2.x, verify that `mason-lspconfig.nvim` is also updated
to a compatible version (v2.x).

### Diff

```diff
--- a/lua/andrew/plugins/lsp/mason.lua
+++ b/lua/andrew/plugins/lsp/mason.lua
@@ -12,8 +12,8 @@

   {
     -- Plugin: mason-lspconfig - LSP server manager integration
-    -- Repository: https://github.com/williamboman/mason-lspconfig.nvim
-    "williamboman/mason-lspconfig.nvim",
+    -- Repository: https://github.com/mason-org/mason-lspconfig.nvim
+    "mason-org/mason-lspconfig.nvim",

     -- Configuration options
     opts = {
@@ -35,7 +35,7 @@
     dependencies = {
       -- mason: Core package manager
       {
-        "williamboman/mason.nvim",
+        "mason-org/mason.nvim",
         opts = {
           -- UI configuration for mason status display
           ui = {
@@ -77,7 +77,7 @@

     dependencies = {
       -- mason: Core package manager dependency
-      "williamboman/mason.nvim",
+      "mason-org/mason.nvim",
     },
   },
 }
```

---

## 9. neodev.nvim -> lazydev.nvim Migration

### Location

**File:** `lua/andrew/plugins/lsp/lspconfig.lua` line 28

### Current Code

```lua
dependencies = {
    -- blink.cmp: Provides LSP capabilities for completion
    "saghen/blink.cmp",

    -- File operations: Rename/move files with LSP awareness
    { "antosha417/nvim-lsp-file-operations", config = true },

    -- Neovim Lua development: Improves Lua LSP understanding of vim API
    { "folke/neodev.nvim", opts = {} },
},
```

### Replacement Code

```lua
dependencies = {
    -- blink.cmp: Provides LSP capabilities for completion
    "saghen/blink.cmp",

    -- File operations: Rename/move files with LSP awareness
    { "antosha417/nvim-lsp-file-operations", config = true },

    -- Neovim Lua development: Faster LuaLS setup with lazy workspace libraries
    {
      "folke/lazydev.nvim",
      ft = "lua",
      opts = {
        library = {
          -- Load luvit types when vim.uv is referenced
          { path = "${3rd}/luv/library", words = { "vim%.uv" } },
        },
      },
    },
},
```

### Config Differences Between neodev and lazydev

| Aspect | neodev.nvim | lazydev.nvim |
|--------|-----------|-------------|
| Loading | Eager (on any buffer) | Lazy (`ft = "lua"` only) |
| Library resolution | All configured libs loaded upfront | Libs loaded lazily based on `require()` calls |
| Status | **EOL** (end of life) | Actively maintained |
| Neovim requirement | >= 0.8 | >= 0.10 |
| blink.cmp integration | Not needed | Optional `lazydev` source provider (see below) |

### Optional: blink.cmp Integration

If you want completion for `require()` module names, add a `lazydev` source to blink.cmp.
This is **optional** -- lazydev works without it, but this adds richer completions.

If you want to add this, put it in blink.cmp's config (separate from the lspconfig
dependency above):

```lua
-- In your blink.cmp plugin spec opts:
sources = {
  default = { "lazydev", "lsp", "path", "snippets", "buffer" },
  providers = {
    lazydev = {
      name = "LazyDev",
      module = "lazydev.integrations.blink",
      score_offset = 100,  -- Show lazydev completions above other sources
    },
  },
},
```

### Diff

```diff
--- a/lua/andrew/plugins/lsp/lspconfig.lua
+++ b/lua/andrew/plugins/lsp/lspconfig.lua
@@ -25,8 +25,16 @@
     -- File operations: Rename/move files with LSP awareness
     { "antosha417/nvim-lsp-file-operations", config = true },

-    -- Neovim Lua development: Improves Lua LSP understanding of vim API
-    { "folke/neodev.nvim", opts = {} },
+    -- Neovim Lua development: Faster LuaLS setup with lazy workspace libraries
+    {
+      "folke/lazydev.nvim",
+      ft = "lua",
+      opts = {
+        library = {
+          -- Load luvit types when vim.uv is referenced
+          { path = "${3rd}/luv/library", words = { "vim%.uv" } },
+        },
+      },
+    },
   },
```

### Post-Change Steps

1. Run `:Lazy sync` to install `lazydev.nvim` and remove `neodev.nvim`.
2. Verify Lua LSP completions still work: open any file in `lua/andrew/` and confirm
   `vim.api.nvim_` completions appear.
3. Run `:LazyDev debug` to verify lazydev is active and loading workspace libraries.

---

## Complete File-by-File Change Summary

### `lua/andrew/core/keymaps.lua`

- Line 71: `vim.highlight.on_yank` -> `vim.hl.on_yank`

### `lua/andrew/lazy.lua`

- Line 16: `vim.loop.fs_stat` -> `vim.uv.fs_stat`

### `lua/andrew/plugins/lsp/lspconfig.lua`

- Line 28: `folke/neodev.nvim` -> `folke/lazydev.nvim` (with `ft = "lua"` and `library` opts)
- Line 277: `vim.diagnostic.goto_prev` -> `vim.diagnostic.jump({ count = -1, float = true })`
- Line 281: `vim.diagnostic.goto_next` -> `vim.diagnostic.jump({ count = 1, float = true })`
- Line 577: `vim.lsp.stop_client(...)` -> iterate clients and call `client:stop()`

### `lua/andrew/custom/plugins/terminal.lua`

- Line 129: `vim.fn.termopen(shell)` -> `vim.fn.jobstart(shell, { term = true })`
- Lines 143-153: All `nvim_win_set_option()` calls -> `vim.wo[winid].opt = val`

### `lua/andrew/plugins/type-checker.lua`

- Line 44: `vim.fn.termopen(cmd, opts)` -> `vim.fn.jobstart(cmd, vim.tbl_extend("force", opts, { term = true }))`

### `lua/andrew/vault/preview.lua`

- Line 337: `nvim_buf_set_option(buf, "filetype", "markdown")` -> `vim.bo[buf].filetype = "markdown"`

### `lua/andrew/plugins/lsp/mason.lua`

- Lines 15-16: `williamboman/mason-lspconfig.nvim` -> `mason-org/mason-lspconfig.nvim`
- Line 38: `williamboman/mason.nvim` -> `mason-org/mason.nvim`
- Line 80: `williamboman/mason.nvim` -> `mason-org/mason.nvim`

### `docs/ctags-fortran-completion-guide.md` (documentation only)

- Line 331: `vim.loop.fs_stat` -> `vim.uv.fs_stat` (code example in markdown; optional fix)

---

## Implementation Order

Recommended order to minimize risk:

1. **vim.highlight -> vim.hl** (single line, zero risk)
2. **vim.loop -> vim.uv** (single line, zero risk)
3. **nvim_buf_set_option -> vim.bo** (single line, zero risk)
4. **nvim_win_set_option -> vim.wo** (terminal.lua, 7 lines, zero risk)
5. **vim.fn.termopen -> vim.fn.jobstart** (terminal.lua + type-checker.lua, low risk)
6. **vim.diagnostic.goto_prev/next -> vim.diagnostic.jump** (lspconfig.lua, low risk)
7. **vim.lsp.stop_client -> client:stop()** (lspconfig.lua, low risk)
8. **mason repo migration** (mason.lua, requires `:Lazy sync` after)
9. **neodev -> lazydev** (lspconfig.lua, requires `:Lazy sync` after, test Lua completions)

---

## Verification

After applying all changes:

1. **No deprecation warnings**: Open Neovim and check `:messages` -- no `vim.deprecate`
   warnings should appear.
2. **Yank highlight**: Yank text in any buffer -- the highlight flash should still work.
3. **Lazy bootstrap**: Delete `~/.local/share/nvim/lazy/lazy.nvim` and reopen Neovim --
   lazy.nvim should auto-install.
4. **Diagnostic navigation**: Open a file with diagnostics, press `[d` and `]d` -- should
   jump between diagnostics with float preview.
5. **CtagsLspRestart**: Run `:CtagsLspRestart` -- should stop and restart the ctags LSP.
6. **Floating terminal**: Press `<leader>tt` -- terminal should open with correct window
   options (no line numbers, no sign column, etc.).
7. **Type checker**: Run `:TypeCheck` (or equivalent) -- terminal output should display.
8. **Vault preview**: Press `K` on a wikilink -- preview float should have markdown filetype.
9. **Mason**: Run `:Mason` -- UI should load correctly with the new repo sources.
10. **Lua LSP**: Open a Lua config file -- completions for `vim.api`, `vim.fn`, etc. should
    work via lazydev.nvim.
