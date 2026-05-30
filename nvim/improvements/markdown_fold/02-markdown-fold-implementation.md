# Unified Markdown Fold Manager — Implementation Document

## Context

Your current markdown folding uses a three-layer system:
1. **ftplugin/markdown.lua** sets `foldmethod=expr` with treesitter `foldexpr`
2. **render-markdown.lua** switches `expr → manual` on BufWinEnter to freeze folds, then applies callout-specific open/close states
3. **callout_folds.lua** persists user overrides via content fingerprinting

The `expr → manual` switching hack works but is fragile — the two fold systems
don't share a unified model. This plan consolidates everything into a single
`fold_manager.lua` module that uses `foldmethod=manual` exclusively, computing
fold boundaries from treesitter directly.

**Key constraint:** Pure `foldmethod=expr` cannot preserve per-fold open/closed
state (Neovim issue #32759). The fold inheritance mechanism in `fold.c` resets
open/closed state on buffer changes. No plugin has solved this without falling
back to manual folds. The unified method MUST use `foldmethod=manual`.

---

## Architecture: Single Module Owns Everything

```
fold_manager.lua (NEW)
  ├── Reads: queries/markdown/folds.scm (via vim.treesitter.query.get)
  ├── Uses:  callout_folds.lua (fingerprinting, persistence, record_toggle)
  ├── Uses:  vault/engine.lua (is_vault_path, vault_relative)
  ├── Sets:  foldmethod=manual (per-window, on BufWinEnter)
  ├── Owns:  All fold keymaps (<Tab>, <leader>mf/mu/ml/mz/mZ)
  ├── Owns:  All fold commands (:VaultFoldRefresh, :VaultFoldDebug)
  └── Owns:  Custom foldtext function

callout_folds.lua (REFACTORED — persistence-only)
  ├── Public: parse_callout_header(), fingerprint(), default_state(), load_db()
  ├── Public: record_toggle(), clear(), invalidate(), debug()
  └── Removed: restore() — absorbed into fold_manager

ftplugin/markdown.lua (SIMPLIFIED — no fold settings)
render-markdown.lua  (SIMPLIFIED — no fold logic)
queries/markdown/folds.scm (UNCHANGED)
```

---

## New Module: `lua/andrew/vault/fold_manager.lua`

### Data Structure

```lua
---@class FoldRegion
---@field start_line number  1-indexed first line of the fold
---@field end_line number    1-indexed last line of the fold
---@field level number       Nesting depth (1 = outermost)
---@field kind string        "section"|"code_block"|"list"|"block_quote"
---@field callout_suffix string|nil  "-", "+", or nil
---@field callout_fp string|nil      Fingerprint for persistence
```

### Public API

```lua
M.recompute(bufnr)          -- Full pipeline: treesitter → fold creation → state
M.toggle_callout(bufnr)     -- Toggle callout fold under cursor
M.foldtext()                -- Custom fold text (registered as global VaultFoldText)
M.fold_all(bufnr)           -- Close all folds (zM)
M.unfold_all(bufnr)         -- Open all folds (zR)
M.set_fold_level(bufnr, n)  -- Open folds with level <= n, close deeper
M.debug(bufnr)              -- Print computed fold tree
M.toggle_enabled()          -- Enable/disable the manager
M.setup()                   -- Register autocmds, commands, keymaps
```

### Algorithm: `recompute(bufnr)` Pipeline

#### Step 1: Parse treesitter and collect @fold captures

```lua
local function compute_fold_regions(bufnr)
  local regions = {}

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "markdown")
  if not ok or not parser then return regions end

  -- Parse all trees (including injections)
  parser:parse(true)

  -- Load the combined folds query (base + ; extends block_quote)
  local query = vim.treesitter.query.get("markdown", "folds")
  if not query then return regions end

  -- Iterate over each tree (language injections get their own trees)
  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local lang_query = vim.treesitter.query.get(lang, "folds")
    if not lang_query then return end

    local root = tree:root()
    for id, node in lang_query:iter_captures(root, bufnr) do
      local name = lang_query.captures[id]
      if name == "fold" then
        local sr, _, er, ec = node:range()  -- 0-indexed

        -- Convert to 1-indexed inclusive range
        local fold_start = sr + 1
        local fold_end = (ec == 0) and er or (er + 1)

        -- Trim trailing blank lines
        fold_end = trim_trailing_blanks(bufnr, fold_start, fold_end)

        -- Skip single-line "folds"
        if fold_end > fold_start then
          -- Classify node type
          local kind = classify_node(node)

          table.insert(regions, {
            start_line = fold_start,
            end_line = fold_end,
            level = 0,  -- assigned in Step 2
            kind = kind,
            callout_suffix = nil,
            callout_fp = nil,
          })
        end
      end
    end
  end)

  return regions
end
```

Helper functions:

```lua
local function trim_trailing_blanks(bufnr, start_line, end_line)
  for lnum = end_line, start_line + 1, -1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if line and vim.trim(line) ~= "" then
      return lnum
    end
  end
  return start_line
end

local NODE_KIND_MAP = {
  section = "section",
  fenced_code_block = "code_block",
  indented_code_block = "code_block",
  list = "list",
  list_item = "list",
  block_quote = "block_quote",
}

local function classify_node(node)
  return NODE_KIND_MAP[node:type()] or "unknown"
end
```

#### Step 2: Assign nesting levels

```lua
local function assign_levels(regions)
  -- Sort: start ascending, end descending (parent before child when same start)
  table.sort(regions, function(a, b)
    if a.start_line ~= b.start_line then
      return a.start_line < b.start_line
    end
    return a.end_line > b.end_line
  end)

  local stack = {}  -- stack of end_line values

  for _, region in ipairs(regions) do
    -- Pop regions that have ended before this region starts
    while #stack > 0 and stack[#stack] < region.start_line do
      table.remove(stack)
    end
    region.level = #stack + 1
    table.insert(stack, region.end_line)
  end
end
```

#### Step 3: Detect callout patterns

```lua
local function annotate_callouts(bufnr, regions)
  local callout_folds = require("andrew.vault.callout_folds")

  for _, r in ipairs(regions) do
    if r.kind == "block_quote" then
      local line = vim.api.nvim_buf_get_lines(bufnr, r.start_line - 1, r.start_line, false)[1]
      if line then
        local _, suffix = callout_folds.parse_callout_header(line)
        if suffix then
          r.callout_suffix = suffix
          r.callout_fp = callout_folds.fingerprint(bufnr, r.start_line)
        end
      end
    end
  end
end
```

#### Step 4: Apply folds (clear + recreate)

```lua
local function apply_folds(bufnr, regions)
  vim.api.nvim_buf_call(bufnr, function()
    -- Clear all existing manual folds
    pcall(vim.cmd, "normal! zE")

    -- Find maximum level
    local max_level = 0
    for _, r in ipairs(regions) do
      if r.level > max_level then max_level = r.level end
    end

    -- Apply deepest folds first, then outer folds
    -- This ensures correct nesting: inner folds exist before outer folds wrap them
    for level = max_level, 1, -1 do
      for _, r in ipairs(regions) do
        if r.level == level and r.end_line > r.start_line then
          pcall(vim.cmd, r.start_line .. "," .. r.end_line .. "fold")
        end
      end
    end
  end)
end
```

#### Step 5: Apply open/close state

```lua
local function apply_fold_states(bufnr, regions)
  local callout_folds = require("andrew.vault.callout_folds")
  local engine = require("andrew.vault.engine")

  -- Load persisted overrides (vault files only)
  local file_overrides = {}
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if engine.is_vault_path(fname) then
    local rel = engine.vault_relative(fname)
    local db = callout_folds.load_db()
    file_overrides = (rel and db[rel]) or {}
  end

  vim.api.nvim_buf_call(bufnr, function()
    -- Start with all folds open
    pcall(vim.cmd, "normal! zR")

    -- Close callout folds per suffix default + user overrides
    for _, r in ipairs(regions) do
      if r.callout_suffix then
        local default = callout_folds.default_state(r.callout_suffix)
        local override = r.callout_fp and file_overrides[r.callout_fp]
        local desired = override or default

        if desired == "closed" then
          pcall(vim.cmd, r.start_line .. "foldclose")
        end
      end
    end
  end)
end
```

#### Full recompute pipeline

```lua
--- Per-buffer cache for set_fold_level and debug
---@type table<number, FoldRegion[]>
local region_cache = {}

function M.recompute(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Step 1: Compute fold regions from treesitter
  local regions = compute_fold_regions(bufnr)
  if #regions == 0 then
    -- No foldable content — clear any leftover folds
    pcall(function()
      vim.api.nvim_buf_call(bufnr, function()
        pcall(vim.cmd, "normal! zE")
      end)
    end)
    region_cache[bufnr] = {}
    return
  end

  -- Step 2: Assign nesting levels
  assign_levels(regions)

  -- Step 3: Detect callout patterns and fingerprints
  annotate_callouts(bufnr, regions)

  -- Step 4: Save cursor position
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)

  -- Step 5: Apply folds (clear + recreate)
  apply_folds(bufnr, regions)

  -- Step 6: Apply open/close state
  apply_fold_states(bufnr, regions)

  -- Step 7: Restore cursor position
  pcall(vim.api.nvim_win_set_cursor, win, cursor)

  -- Cache regions for set_fold_level and debug
  region_cache[bufnr] = regions
end
```

### Recomputation Triggers

```lua
local recompute_timer = nil
local DEBOUNCE_MS = 500

local function schedule_recompute(bufnr)
  if recompute_timer then
    recompute_timer:stop()
  end
  recompute_timer = vim.uv.new_timer()
  recompute_timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
      M.recompute(bufnr)
    end
  end))
end
```

### Toggle Callout Fold

```lua
function M.toggle_callout(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]

  -- Walk backward to find the callout header
  local header_lnum = nil
  for lnum = cursor_lnum, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if line and line:match("^>%s*%[![%w_]+%]") then
      header_lnum = lnum
      break
    end
    if not line or not line:match("^>") then break end
  end

  if not header_lnum then
    vim.notify("No callout under cursor", vim.log.levels.WARN)
    return
  end

  -- Find block end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local block_end = header_lnum
  for lnum = header_lnum + 1, line_count do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if not line or not line:match("^>") then break end
    block_end = lnum
  end

  if block_end <= header_lnum then
    vim.notify("Callout has no content to fold", vim.log.levels.WARN)
    return
  end

  -- Toggle
  local fold_closed = vim.fn.foldclosed(header_lnum)
  local is_now_open

  if fold_closed ~= -1 then
    pcall(vim.cmd, header_lnum .. "foldopen")
    is_now_open = true
  else
    local fold_level = vim.fn.foldlevel(header_lnum)
    if fold_level > 0 then
      pcall(vim.cmd, header_lnum .. "foldclose")
    else
      pcall(vim.cmd, header_lnum .. "," .. block_end .. "fold")
      pcall(vim.cmd, header_lnum .. "foldclose")
    end
    is_now_open = false
  end

  -- Persist
  local callout_folds = require("andrew.vault.callout_folds")
  callout_folds.record_toggle(bufnr, header_lnum, is_now_open)
end
```

### Custom Foldtext

```lua
function M.foldtext()
  local first = vim.fn.getline(vim.v.foldstart)
  local count = vim.v.foldend - vim.v.foldstart
  return first .. " (" .. count .. " lines)"
end

-- Register globally for vim foldtext option
_G.VaultFoldText = M.foldtext
```

### Fold Level Control

```lua
function M.fold_all(bufnr)
  vim.api.nvim_buf_call(bufnr or 0, function()
    pcall(vim.cmd, "normal! zM")
  end)
end

function M.unfold_all(bufnr)
  vim.api.nvim_buf_call(bufnr or 0, function()
    pcall(vim.cmd, "normal! zR")
  end)
end

function M.set_fold_level(bufnr, level)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local regions = region_cache[bufnr]
  if not regions then return end

  vim.api.nvim_buf_call(bufnr, function()
    -- Close everything first
    pcall(vim.cmd, "normal! zM")
    -- Open folds whose level is <= target
    for _, r in ipairs(regions) do
      if r.level <= level then
        pcall(vim.cmd, r.start_line .. "foldopen")
      end
    end
  end)
end
```

### Debug

```lua
function M.debug(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local regions = region_cache[bufnr]
  if not regions or #regions == 0 then
    vim.notify("Fold manager: no computed regions", vim.log.levels.INFO)
    return
  end

  local lines = { "Fold regions (" .. #regions .. " total):" }
  for _, r in ipairs(regions) do
    local extra = ""
    if r.callout_suffix then
      extra = " callout:" .. r.callout_suffix
      if r.callout_fp then extra = extra .. " fp:" .. r.callout_fp end
    end
    lines[#lines + 1] = string.format(
      "  L%d-%d [%s] level=%d%s",
      r.start_line, r.end_line, r.kind, r.level, extra
    )
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end
```

### Setup Function

```lua
function M.setup()
  local group = vim.api.nvim_create_augroup("VaultFoldManager", { clear = true })

  -- Set window fold options and compute folds on buffer display
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if not M.enabled then return end
      local bufnr = ev.buf
      vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if vim.api.nvim_get_current_buf() ~= bufnr then return end
        vim.wo.foldmethod = "manual"
        vim.wo.foldenable = true
        vim.wo.foldcolumn = "1"
        vim.wo.foldtext = "v:lua.VaultFoldText()"
        vim.wo.foldlevel = 99
        M.recompute(bufnr)
      end, 50)
    end,
  })

  -- Recompute on write
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if not M.enabled then return end
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          M.recompute(ev.buf)
        end
      end, 30)
    end,
  })

  -- Debounced recompute on text change (normal mode only)
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if not M.enabled then return end
      schedule_recompute(ev.buf)
    end,
  })

  -- Clean up cached regions on buffer unload
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      region_cache[ev.buf] = nil
    end,
  })

  -- Commands
  vim.api.nvim_create_user_command("VaultFoldRefresh", function()
    M.recompute(vim.api.nvim_get_current_buf())
  end, { desc = "Recompute markdown folds" })

  vim.api.nvim_create_user_command("VaultFoldDebug", function()
    M.debug(vim.api.nvim_get_current_buf())
  end, { desc = "Show computed fold tree" })

  vim.api.nvim_create_user_command("VaultFoldToggle", function()
    M.toggle_enabled()
  end, { desc = "Toggle fold manager on/off" })

  -- Buffer-local keymaps
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      local bufnr = ev.buf
      local bmap = function(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = desc, silent = true })
      end

      bmap("<Tab>", "za", "Toggle fold")
      bmap("<leader>mf", function() M.fold_all(bufnr) end, "Fold all")
      bmap("<leader>mu", function() M.unfold_all(bufnr) end, "Unfold all")
      bmap("<leader>mz", function() M.toggle_callout(bufnr) end, "Toggle callout fold")
      bmap("<leader>mZ", function()
        require("andrew.vault.callout_folds").clear()
      end, "Clear callout fold cache (this file)")
      bmap("<leader>ml", function()
        local level = vim.fn.input("Fold level: ")
        level = tonumber(level)
        if level then M.set_fold_level(bufnr, level) end
      end, "Set fold level")

      -- Prevent user from creating manual folds that would be destroyed on recompute
      bmap("zd", "<Nop>", "Fold delete (managed)")
      bmap("zD", "<Nop>", "Fold delete (managed)")
      bmap("zE", "<Nop>", "Fold eliminate (managed)")
      bmap("zf", "<Nop>", "Fold create (managed)")
      bmap("zF", "<Nop>", "Fold create (managed)")
    end,
  })
end
```

---

## Changes to Existing Files

### 1. `lua/andrew/vault/callout_folds.lua`

**Promote private → public:**
```lua
-- These were local, now on M:
M.parse_callout_header = parse_callout_header
M.fingerprint = fingerprint
M.default_state = default_state
M.load_db = load_db
```

**Remove:**
- `M.restore(bufnr)` function (lines 172-239) — absorbed into fold_manager
- The `VaultCalloutFoldPersist` augroup FileType autocmd that sets `<leader>mZ` (lines 325-337) — moves to fold_manager

**Keep everything else** (record_toggle, clear, invalidate, debug, setup commands).

### 2. `ftplugin/markdown.lua`

**Remove lines 13-47:**
```lua
-- DELETE: opt_local.foldmethod, foldexpr, foldlevel, foldcolumn, foldenable
-- DELETE: opt_local.foldtext and MarkdownFoldText()
-- DELETE: <Tab>, <leader>mf, <leader>mu, <leader>ml keymaps
-- DELETE: zd, zD, zE, zf, zF <Nop> keymaps
```

All of these now live in fold_manager.setup().

### 3. `lua/andrew/plugins/render-markdown.lua`

**Remove lines 24-179** (the entire callout fold system in the config function). Simplified:

```lua
config = function(_, opts)
  vim.treesitter.language.register("markdown", "blink-cmp-documentation")
  require("render-markdown").setup(opts)
end,
```

The `opts` table (callout definitions, checkboxes, headings, etc.) is unchanged.

### 4. `lua/andrew/vault/init.lua`

After line 220 (`callout_folds.setup()`), add:
```lua
require("andrew.vault.fold_manager").setup()
```

### 5. `queries/markdown/folds.scm` — No changes

---

## Implementation Order

1. Refactor `callout_folds.lua` — promote private functions (non-breaking, existing code still works)
2. Create `fold_manager.lua` — full implementation
3. Remove fold logic from `render-markdown.lua` (lines 24-179)
4. Remove fold settings/keymaps from `ftplugin/markdown.lua` (lines 13-47)
5. Add `fold_manager.setup()` to `vault/init.lua`
6. Remove `M.restore()` and `<leader>mZ` autocmd from `callout_folds.lua`

---

## Edge Cases

| Case | Handling |
|------|----------|
| Empty buffer / no treesitter parser | `compute_fold_regions` returns `{}`, no folds created |
| Non-vault markdown files | Structural folds work, callout persistence skipped |
| Section with only a heading (no content) | Filtered by `end_line > start_line` check |
| Block_quote that is NOT a callout | Gets fold (from folds.scm), defaults to open |
| Callout without +/- suffix | No callout_suffix, treated as regular block_quote |
| Nested block_quotes | Treesitter handles nesting, level assignment correct |
| Multiple windows on same buffer | BufWinEnter fires per-window, sets window-local options |
| Cursor inside closed fold during recompute | Position saved/restored, fold may re-close around it |
| Treesitter parse not ready on BufWinEnter | 50ms defer; `parser:parse()` forces sync parse if needed |
| Very large files (1000+ regions) | Acceptable — O(n log n) sort + O(n) sweep |
| Identical callouts (same fingerprint) | Override applies to first match (by design) |

---

## Verification Checklist

1. Open markdown file with headings, code blocks, lists, blockquotes, callouts
2. Heading sections fold at correct nesting levels
3. Code blocks, blockquotes, nested lists all fold
4. `> [!NOTE]-` callouts start collapsed, `> [!NOTE]+` start expanded
5. `<leader>mz` toggles callout fold, persists across buffer re-entry
6. `<Tab>` toggles any fold
7. `<leader>mf` / `<leader>mu` fold/unfold all
8. `<leader>ml` with level input opens/closes folds by depth
9. Editing text triggers debounced recompute (folds stay correct)
10. `:VaultFoldRefresh` manually recomputes
11. Non-vault markdown files get structural folds (no callout persistence)
12. `:VaultFoldDebug` shows computed fold tree
13. Callout fold cache (`<leader>mZ`, `:VaultFoldClear`) still works
