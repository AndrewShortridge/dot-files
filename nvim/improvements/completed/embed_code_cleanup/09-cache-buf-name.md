# Implementation Plan: Cache `nvim_buf_get_name(bufnr)` in embed.lua

## Problem

`vim.api.nvim_buf_get_name(bufnr)` is called 5+ times during a single `render_embeds()` invocation. The buffer name never changes mid-render. `render_embeds()` already has `bufpath` at line 323 but downstream functions re-fetch it.

## Strategy

Pass `bufpath` as an optional parameter to `resolve_image()`, `resolve_embed()`, and `resolve_embed_lines()`. Leave `debug_info()` unchanged (not performance-critical).

## Changes

### 1. `resolve_image()` -- add `bufpath` parameter

```lua
-- Before (line 67):
local function resolve_image(bufnr, image_name)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local buf_dir = vim.fs.dirname(bufname)

-- After:
local function resolve_image(bufnr, image_name, bufpath)
  bufpath = bufpath or vim.api.nvim_buf_get_name(bufnr)
  local buf_dir = vim.fs.dirname(bufpath)
```

### 2. `resolve_embed()` -- add `bufpath` parameter

```lua
-- Before (line 104):
local function resolve_embed(name, bufnr)
  if name == "" then
    return vim.api.nvim_buf_get_name(bufnr)
  end

-- After:
local function resolve_embed(name, bufnr, bufpath)
  if name == "" then
    return bufpath or vim.api.nvim_buf_get_name(bufnr)
  end
```

### 3. `resolve_embed_lines()` -- add `bufpath` parameter (position 8)

```lua
-- Before (line 189):
local function resolve_embed_lines(details, source, depth, visited_set, visited_list, bufnr, budget)

-- After:
local function resolve_embed_lines(details, source, depth, visited_set, visited_list, bufnr, budget, bufpath)
```

**Line 206:**
```lua
-- Before:
target_path = vim.api.nvim_buf_get_name(bufnr)
-- After:
target_path = bufpath
```

**Line 284 (recursive resolve_embed call):**
```lua
-- Before:
local inner_path = resolve_embed(inner_details.name, bufnr)
-- After:
local inner_path = resolve_embed(inner_details.name, bufnr, bufpath)
```

**Lines 288-292 (recursive resolve_embed_lines call):**
```lua
-- Before:
  ..., bufnr, remaining)
-- After:
  ..., bufnr, remaining, bufpath)
```

### 4. Update call sites in `render_embeds()`

**Line 373:**
```lua
-- Before:
local src = resolve_image(bufnr, image_name)
-- After:
local src = resolve_image(bufnr, image_name, bufpath)
```

**Line 411:**
```lua
-- Before:
local path = resolve_embed(details.name, bufnr)
-- After:
local path = resolve_embed(details.name, bufnr, bufpath)
```

**Lines 445-452:**
```lua
-- Before:
  ..., bufnr, content_budget)
-- After:
  ..., bufnr, content_budget, bufpath)
```

## What Does NOT Change

- `debug_info()` calls without `bufpath` -- uses the `or` fallback
- Line 323 in `render_embeds()` -- the canonical fetch stays

## Net Effect

In the render path: `nvim_buf_get_name` called exactly **once** (line 323), down from potentially many.

## Files Modified

Only `lua/andrew/vault/embed.lua` -- 3 function signatures, ~6 call sites.
