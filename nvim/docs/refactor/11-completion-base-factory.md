# Feature 11: Completion Source Base Factory

## Dependencies
- **Feature 02** (engine.read_file for frontmatter parsing) — optional, but helpful
- **Depended on by:** Nothing directly

## Problem
The three blink-cmp completion sources share massive amounts of identical boilerplate:
- `completion.lua` (wikilinks)
- `completion_tags.lua`
- `completion_frontmatter.lua`

**Identical across all 3 files:**
1. `source` table + `source.new(opts)` constructor with metatable — character-for-character identical
2. `source:enabled()` returning `vim.bo.filetype == "markdown"` — identical
3. Cache state variables: `cached_vault`, `building`, `build_generation` — identical
4. `invalidate()` function — identical structure
5. `BufWritePost` autocmd registration on `*.md` — identical except augroup name
6. `empty` response sentinel: `{ is_incomplete_forward = false, is_incomplete_backward = false, items = {} }` — identical
7. Async build guard: `if building then return end; building = true` — identical
8. Generation check in callback: `if gen ~= build_generation then ... return end` — identical
9. Cache-check-or-build pattern in `get_completions` — identical
10. `fd`/`fdfind` detection block — identical in completion.lua and completion_frontmatter.lua

**3 separate `BufWritePost` autocmds** fire on every `.md` save — wasteful.

## Files to Modify
1. **CREATE** `lua/andrew/vault/completion_base.lua` — Factory module
2. `lua/andrew/vault/completion.lua` — Use factory
3. `lua/andrew/vault/completion_tags.lua` — Use factory
4. `lua/andrew/vault/completion_frontmatter.lua` — Use factory

## Implementation Steps

### Step 1: Create `lua/andrew/vault/completion_base.lua`

```lua
local engine = require("andrew.vault.engine")

local M = {}

local all_invalidators = {}

-- Single BufWritePost autocmd to invalidate ALL vault completion sources
vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*.md",
  group = vim.api.nvim_create_augroup("VaultCompletionCacheAll", { clear = true }),
  callback = function()
    for _, invalidate in ipairs(all_invalidators) do
      invalidate()
    end
  end,
})

--- Detect the best available file-finder command.
--- @param vault_path string
--- @return string[], boolean  cmd, use_fd
function M.find_md_cmd(vault_path)
  local fd_bin = vim.fn.executable("fd") == 1 and "fd"
    or vim.fn.executable("fdfind") == 1 and "fdfind"
    or nil
  if fd_bin then
    return { fd_bin, "--type", "f", "--extension", "md", "--base-directory", vault_path }, true
  else
    return { "find", vault_path, "-type", "f", "-name", "*.md" }, false
  end
end

--- Compute relative and absolute paths from command output line.
--- @param line string  Raw output line
--- @param vault_path string
--- @param use_fd boolean
--- @return string, string  rel_path, abs_path
function M.resolve_paths(line, vault_path, use_fd)
  local rel = line
  if not use_fd then
    rel = line:sub(#vault_path + 2)
  end
  local abs = use_fd and (vault_path .. "/" .. rel) or line
  return rel, abs
end

--- Create a blink-cmp completion source with standard boilerplate.
--- @param opts { build: fun(vault_path: string, callback: fun(items: table[])), get_completions: fun(self: table, ctx: table, items: table[], callback: fun(response: table)) }
--- @return table  blink-cmp source module
function M.create_source(opts)
  local source = {}
  local cached_items = nil
  local cached_vault = nil
  local building = false
  local build_generation = 0

  local empty = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }

  local function invalidate()
    cached_items = nil
    build_generation = build_generation + 1
  end

  -- Register this source's invalidator for the shared autocmd
  all_invalidators[#all_invalidators + 1] = invalidate

  local function build_items_async(callback)
    if building then return end
    building = true
    local gen = build_generation
    local vault_path = engine.vault_path

    opts.build(vault_path, function(items)
      vim.schedule(function()
        building = false
        if gen ~= build_generation then
          if callback then callback({}) end
          return
        end
        cached_items = items
        cached_vault = vault_path
        if callback then callback(items) end
      end)
    end)
  end

  function source.new(source_opts)
    local self = setmetatable({}, { __index = source })
    self.opts = source_opts or {}
    build_items_async()
    return self
  end

  function source:enabled()
    return vim.bo.filetype == "markdown"
  end

  function source:get_completions(ctx, callback)
    -- If the source provides a custom get_completions, use it
    if opts.get_completions then
      if cached_items and cached_vault == engine.vault_path then
        opts.get_completions(self, ctx, cached_items, callback)
        return
      end
      build_items_async(function(items)
        opts.get_completions(self, ctx, items or {}, callback)
      end)
      return
    end

    -- Default: return all cached items
    if cached_items and cached_vault == engine.vault_path then
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = cached_items })
      return
    end
    build_items_async(function(items)
      callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items or {} })
    end)
  end

  -- Passthrough resolve_item if the source defines it
  if opts.resolve_item then
    function source:resolve(item, callback)
      opts.resolve_item(self, item, callback)
    end
  end

  return source
end

--- Format a count as "N note(s)" for label descriptions.
--- @param count number
--- @return string
function M.count_label(count)
  return count .. " note" .. (count == 1 and "" or "s")
end

--- Format a sortText string for frequency-based sorting (descending).
--- @param count number
--- @param name string
--- @return string
function M.freq_sort_text(count, name)
  return string.format("%05d", 99999 - count) .. name
end

return M
```

### Step 2: Refactor completion.lua

```lua
local base = require("andrew.vault.completion_base")

-- Keep the parse_frontmatter function and item-building logic
-- but wrap it in the factory:

return base.create_source({
  build = function(vault_path, callback)
    local cmd, use_fd = base.find_md_cmd(vault_path)
    vim.system(cmd, { text = true }, function(result)
      if result.code ~= 0 then callback({}) return end
      local items = {}
      for line in (result.stdout or ""):gmatch("[^\n]+") do
        local rel, abs = base.resolve_paths(line, vault_path, use_fd)
        -- ... existing item building logic with parse_frontmatter ...
        items[#items + 1] = item
      end
      callback(items)
    end)
  end,

  get_completions = function(self, ctx, items, callback)
    -- existing trigger character detection ([[) and filtering logic
    -- ...
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = filtered })
  end,

  resolve_item = function(self, item, callback)
    -- existing hover documentation building
    callback(item)
  end,
})
```

Delete: `source` table, `source.new`, `source:enabled`, cache variables, `invalidate`, `BufWritePost` autocmd, `empty`, `fd`/`fdfind` detection, build guard, generation check.

### Step 3: Refactor completion_tags.lua

```lua
local base = require("andrew.vault.completion_base")

return base.create_source({
  build = function(vault_path, callback)
    -- existing rg-based tag collection logic
    -- use base.count_label() and base.freq_sort_text() for formatting
    callback(items)
  end,

  get_completions = function(self, ctx, items, callback)
    -- existing # trigger detection logic
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
  end,
})
```

### Step 4: Refactor completion_frontmatter.lua

```lua
local base = require("andrew.vault.completion_base")

return base.create_source({
  build = function(vault_path, callback)
    local cmd, use_fd = base.find_md_cmd(vault_path)
    -- existing frontmatter scanning logic
    -- use base.resolve_paths() for path computation
    callback(items)
  end,

  get_completions = function(self, ctx, items, callback)
    -- existing frontmatter context detection (in_frontmatter check)
    callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
  end,
})
```

## Testing
- Open a `.md` file, type `[[` — wikilink completions appear
- Type `#` after a space — tag completions appear
- Inside frontmatter, type a key name — property completions appear
- Save a `.md` file — all three caches invalidate (verify with `:messages` or by checking completion refreshes)
- Switch vaults — completions refresh for new vault

## Estimated Impact
- **Lines removed:** ~90
- **Lines added:** ~70 (factory) + ~0 net per consumer (restructured, not reduced)
- **Net reduction:** ~60 lines across all 4 files
- **Bonus:** Single `BufWritePost` autocmd instead of 3
- **Bonus:** Consistent behavior guaranteed across all completion sources
