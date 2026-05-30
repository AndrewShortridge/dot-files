# 09 -- Lazy Cache Building

## 1. Problem

The vault system currently builds caches eagerly at startup. The main offenders:

1. **`wikilinks.lua` line 382**: `M.setup()` calls `build_cache()` synchronously,
   which scans every `.md` file in the vault via `vim.fs.find`, then reads
   frontmatter from each file to index aliases. For a vault with 500+ notes this
   is a measurable blocking pause at startup.

2. **`engine.lua` line 424**: `M.get_name_cache()` uses a synchronous
   `vim.system(...):wait()` call with `fd`/`find`. While guarded by a 10-second
   TTL, the first invocation happens as soon as any consumer touches the cache
   (linkcheck, linkdiag, completion sources).

3. **`tags.lua` lines 53-76 / 67-76**: `collect_tags()` fires **two** separate
   `ripgrep` processes (inline tags and frontmatter tags) every time the tag
   picker is opened. The dual-rg pattern doubles subprocess overhead.

4. **`linkcheck.lua` lines 136-147 / 257-266**: `check_vault()` and
   `check_orphans()` run synchronous `vim.system(...):wait()` against the entire
   vault. While these are user-initiated commands, the underlying name cache
   they depend on (`engine.get_name_cache()`) can itself trigger a synchronous
   rebuild.

### Startup sequence today

```
init.lua:7    require("andrew.vault")
  vault/init.lua:1   require engine, pickers, templates (all eager)
  vault/init.lua:112  require query module (eager -- loads parser, index, executor, api, render, js2lua)
  vault/init.lua:115  wikilinks.setup()
                        build_cache()          <-- BLOCKING: vim.fs.find + io.open every .md file
  vault/init.lua:118  backlinks.setup()        (registers autocmds only, OK)
  vault/init.lua:121  navigate.setup()
  ...
  vault/init.lua:136  linkcheck.setup()        (registers autocmds only, OK)
  ...
  vault/init.lua:196  linkdiag.setup()
                        BufWritePost autocmd calls engine.invalidate_name_cache()
                        BufEnter / FileType autocmds reference engine.get_name_cache() on first trigger
  vault/init.lua:202  saved_searches.setup()
```

The critical hot path is `wikilinks.setup() -> build_cache()`. Everything else
is deferred to autocmd triggers, but `build_cache()` blocks the main thread
during every Neovim startup -- even when the user is opening a non-vault file.

---

## 2. Current Behavior -- Detailed Analysis

### 2.1 wikilinks.lua cache

**File**: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/wikilinks.lua`

```lua
-- Lines 7-8: module-level state
local cache = {}
local cache_valid = false
local cache_vault = nil

-- Lines 11-42: build_cache() -- THE HOT PATH
local function build_cache()
  cache = {}
  local vault_path = engine.vault_path
  cache_vault = vault_path
  local files = vim.fs.find(function(name)      -- synchronous directory walk
    return name:match("%.md$")
  end, { path = vault_path, type = "file", limit = math.huge })
  for _, path in ipairs(files) do
    local basename = vim.fn.fnamemodify(path, ":t:r"):lower()
    if not cache[basename] then
      cache[basename] = {}
    end
    table.insert(cache[basename], path)

    -- Index by frontmatter aliases
    local fm = fm_parser.parse_file(path)       -- io.open + read per file!
    local aliases = fm and fm.fields.aliases or nil
    ...
  end
  cache_valid = true
end

-- Line 382: called eagerly from setup()
function M.setup()
  build_cache()   -- <-- blocks startup
  ...
end
```

**Cost breakdown** (estimated for a 500-note vault):
- `vim.fs.find`: ~20ms (libuv `fs_scandir` recursive walk)
- `fm_parser.parse_file` x 500: ~80-150ms (500 `io.open` + frontmatter parse)
- Total: **~100-170ms** of synchronous blocking

**Consumers** (modules that call `resolve_link` or `ensure_cache`):
- `wikilinks.lua:78` -- `resolve_link()` calls `ensure_cache()`
- `backlinks.lua:83` -- `forwardlinks()` calls `wikilinks.resolve_link()`
- `embed.lua` -- transclusion resolution
- `graph.lua:34` -- local graph view
- `export.lua` -- pandoc export
- `blockid.lua` -- block ID generation
- `preview.lua` -- hover preview

All of these are user-action-triggered. None require the cache at startup.

### 2.2 engine.lua name cache

**File**: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/engine.lua`

```lua
-- Lines 417-460: get_name_cache()
function M.get_name_cache()
  local now = vim.uv.now() / 1000
  if _name_cache and _name_cache_vault == M.vault_path
     and (now - _name_cache_ts) < NAME_CACHE_TTL then
    return _name_cache
  end
  ...
  local result = vim.system(cmd, { text = true }):wait()   -- synchronous!
  ...
end
```

Already has a TTL guard (10 seconds). Not called at startup unless a consumer
triggers it. **Lower priority** -- but the synchronous `:wait()` could be
converted to an async build with a callback pattern.

### 2.3 tags.lua dual ripgrep

**File**: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/tags.lua`

```lua
-- Lines 49-116: collect_tags() fires TWO async rg processes
local function collect_tags(callback)
  local inline_cmd = { "rg", "-o", "(?:^|\\s)#(...)", ... }    -- rg #1
  local frontmatter_cmd = { "rg", "-U", ... "^tags:\\n(...)" } -- rg #2

  local pending = 2
  ...
  run_rg(inline_cmd, ..., finish)      -- async
  run_rg(frontmatter_cmd, ..., finish) -- async
end
```

Already async, but fires two subprocesses. These could be merged into a single
rg call with alternation, or cached with a TTL.

### 2.4 linkcheck.lua vault scans

**File**: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/linkcheck.lua`

```lua
-- Lines 136-147: check_vault() -- synchronous rg
local result = vim.system({ "rg", ... }, { text = true }):wait()

-- Lines 257-266: check_orphans() -- synchronous rg
local rg_result = vim.system({ "rg", ... }, { text = true }):wait()
```

User-initiated commands. The synchronous `:wait()` blocks the UI during the
scan. Could be made async with a callback and progress notification.

---

## 3. Lazy Pattern -- Proxy Tables with `__index`

The core idea: replace eager `build_cache()` at startup with a proxy table that
builds the cache **on first access**. This is the same pattern used by
`snacks.nvim` for lazy submodule loading.

```lua
-- Generic lazy-init pattern
local function lazy_init(builder)
  local data = nil
  local building = false

  return setmetatable({}, {
    __index = function(self, key)
      if not data then
        if building then
          -- Re-entrant access during build: return nil gracefully
          return nil
        end
        building = true
        data = builder()
        building = false
        -- Replace proxy with real data for future accesses
        for k, v in pairs(data) do
          rawset(self, k, v)
        end
      end
      return data[key]
    end,
    __len = function()
      -- Force build if someone calls #cache
      if not data then
        building = true
        data = builder()
        building = false
      end
      return #data
    end,
  })
end
```

---

## 4. Implementation: wikilinks.lua -- Lazy Cache

### 4.1 Changes to `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/wikilinks.lua`

**Remove** the eager `build_cache()` call from `setup()` (line 382).
**Convert** the cache to a lazy proxy that builds on first `ensure_cache()`.
**Add** optional async pre-warming for when a vault markdown file is opened.

#### Full replacement code

Replace lines 7-52 (the cache variables, `build_cache`, `invalidate_cache`,
and `ensure_cache`) with:

```lua
-- ---------------------------------------------------------------------------
-- Lazy wikilink cache
-- ---------------------------------------------------------------------------
local cache = {}
local cache_valid = false
local cache_vault = nil
local cache_building = false

--- Build the note-name -> paths mapping synchronously.
--- Called lazily on first access, not at startup.
local function build_cache()
  if cache_building then return end  -- guard against re-entrant calls
  cache_building = true

  cache = {}
  local vault_path = engine.vault_path
  cache_vault = vault_path

  -- Use fd for faster enumeration when available
  local cmd, use_fd = engine.find_md_cmd(vault_path)
  local result = vim.system(cmd, { text = true }):wait()

  if result.code == 0 and result.stdout then
    for line in result.stdout:gmatch("[^\n]+") do
      local rel = use_fd and line:gsub("^%./", "") or line:sub(#vault_path + 2)
      local abs = use_fd and (vault_path .. "/" .. rel) or line
      local basename = vim.fn.fnamemodify(abs, ":t:r"):lower()
      if not cache[basename] then
        cache[basename] = {}
      end
      table.insert(cache[basename], abs)

      -- Index by frontmatter aliases
      local fm = fm_parser.parse_file(abs)
      local aliases = fm and fm.fields.aliases or nil
      if type(aliases) == "string" then aliases = { aliases } end
      if aliases then
        for _, alias in ipairs(aliases) do
          local key = alias:lower()
          if key ~= basename then
            if not cache[key] then
              cache[key] = {}
            end
            table.insert(cache[key], abs)
          end
        end
      end
    end
  end

  cache_valid = true
  cache_building = false
end

function M.invalidate_cache()
  cache_valid = false
end

local function ensure_cache()
  if not cache_valid or cache_vault ~= engine.vault_path then
    build_cache()
  end
end
```

Then replace the `setup()` function (line 381-427) with:

```lua
function M.setup()
  -- NOTE: build_cache() is NOT called here. The cache builds lazily
  -- on the first call to resolve_link() or any other cache consumer.

  local group = vim.api.nvim_create_augroup("VaultWikilinks", { clear = true })

  -- Pre-warm the cache when a vault markdown file is first opened.
  -- This runs deferred (50ms) so it doesn't block BufReadPost rendering.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    pattern = "*.md",
    once = true,   -- only need to warm once per session
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if engine.is_vault_path(bufpath) then
        vim.defer_fn(function()
          ensure_cache()
        end, 50)
      end
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "gf", follow_link, {
        buffer = ev.buf,
        desc = "Vault: follow link (wiki/markdown/URL)",
        silent = true,
      })
      vim.keymap.set("n", "gx", follow_link, {
        buffer = ev.buf,
        desc = "Vault: open link in browser or follow",
        silent = true,
      })
      vim.keymap.set("n", "]o", function()
        jump_link(1)
      end, {
        buffer = ev.buf,
        desc = "Vault: next link",
        silent = true,
      })
      vim.keymap.set("n", "[o", function()
        jump_link(-1)
      end, {
        buffer = ev.buf,
        desc = "Vault: previous link",
        silent = true,
      })
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if engine.is_vault_path(bufpath) then
        M.invalidate_cache()
      end
    end,
  })
end
```

### 4.2 Side-benefit: Use `fd` instead of `vim.fs.find`

The current `build_cache` uses `vim.fs.find` with a Lua callback for every
directory entry. The replacement uses `engine.find_md_cmd()` which prefers `fd`
(a Rust binary) and falls back to `find`. `fd` is significantly faster for large
directory trees because it skips `.git`, `.obsidian`, etc. by default.

### 4.3 Ensuring correctness

The `ensure_cache()` guard already exists and is called by `resolve_link()`.
Every consumer goes through `resolve_link()` or directly calls `ensure_cache()`.
The only change is **when** `build_cache` first runs:

| Before | After |
|--------|-------|
| `require("andrew.vault")` at init.lua:7 | First `gf`, `K`, embed render, backlink query, etc. |

First user-visible latency moves from "always at startup" to "first link
interaction in a vault file". The `BufReadPost` pre-warm (with `once = true`)
ensures the cache builds shortly after the first vault file opens, before the
user is likely to interact.

---

## 5. Implementation: linkcheck.lua -- Async Vault Scans

### 5.1 Changes to `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/linkcheck.lua`

The `check_vault()` and `check_orphans()` functions currently block the UI with
`:wait()`. Convert them to async with `vim.system` callbacks.

#### 5.1a Convert check_vault() (lines 136-236)

Replace the synchronous `vim.system(...):wait()` at line 139 with an async
callback pattern:

```lua
function M.check_vault()
  vim.notify("Vault: scanning for broken links...", vim.log.levels.INFO)

  vim.system({
    "rg",
    "--no-heading",
    "--line-number",
    "--only-matching",
    "--glob", "*.md",
    "\\[\\[[^\\]]+\\]\\]",
    engine.vault_path,
  }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 and result.code ~= 1 then
        vim.notify("Vault: rg failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
        return
      end

      local output = result.stdout or ""
      if output == "" then
        vim.notify("Vault: no wikilinks found in vault", vim.log.levels.INFO)
        return
      end

      local resolved = {}
      local heading_file_cache = {}
      local broken = {}
      local total = 0

      for line in output:gmatch("[^\n]+") do
        local file, lnum, match = line:match("^(.+):(%d+):%[%[(.+)%]%]$")
        if file and lnum and match then
          local parsed = link_utils.parse_target(match)
          local name = parsed.name
          local heading = parsed.heading

          if name ~= "" then
            total = total + 1

            if resolved[name] == nil then
              resolved[name] = link_exists(name)
            end

            if not resolved[name] then
              local rel = file:sub(#engine.vault_path + 2)
              local display = heading and (name .. "#" .. heading) or name
              broken[#broken + 1] = string.format("%s:%s: [[%s]] (broken note)", rel, lnum, display)
            elseif heading then
              local name_lower = name:lower()
              local filepath = get_note_path(name_lower)
              local self_name = vim.fn.fnamemodify(file, ":t:r"):lower()
              if name_lower == self_name then
                filepath = file
              end
              if filepath then
                if not heading_file_cache[filepath] then
                  heading_file_cache[filepath] = extract_headings(filepath)
                end
                local slug_set = heading_file_cache[filepath]
                local anchor_slug = link_utils.heading_to_slug(heading)
                if not slug_set[anchor_slug] then
                  local rel = file:sub(#engine.vault_path + 2)
                  broken[#broken + 1] = string.format(
                    "%s:%s: [[%s#%s]] (broken heading)", rel, lnum, name, heading
                  )
                end
              end
            end
          end
        end
      end

      if #broken == 0 then
        vim.notify("Vault: all " .. total .. " links OK across vault", vim.log.levels.INFO)
        return
      end

      vim.notify(
        "Vault: found " .. #broken .. " broken link(s) out of " .. total,
        vim.log.levels.WARN
      )

      local fzf = require("fzf-lua")
      fzf.fzf_exec(broken, {
        prompt = "Broken vault links> ",
        cwd = engine.vault_path,
        file_icons = true,
        git_icons = false,
        previewer = "builtin",
        actions = {
          ["default"] = fzf.actions.file_edit,
          ["ctrl-s"] = fzf.actions.file_split,
          ["ctrl-v"] = fzf.actions.file_vsplit,
        },
      })
    end)
  end)
end
```

#### 5.1b Convert check_orphans() (lines 241-311)

Same pattern. Replace the synchronous `vim.system(...):wait()` at line 257:

```lua
function M.check_orphans()
  vim.notify("Vault: scanning for orphan notes...", vim.log.levels.INFO)

  local cache = engine.get_name_cache()
  local all_notes = {}
  for key, abs_path in pairs(cache.paths) do
    local basename = vim.fn.fnamemodify(abs_path, ":t:r"):lower()
    if key == basename then
      local rel = abs_path:sub(#engine.vault_path + 2)
      all_notes[basename] = rel
    end
  end

  vim.system({
    "rg",
    "--no-heading",
    "--no-line-number",
    "--only-matching",
    "--no-filename",
    "--glob", "*.md",
    "\\[\\[[^\\]]+\\]\\]",
    engine.vault_path,
  }, { text = true }, function(result)
    vim.schedule(function()
      local linked = {}
      if result.code == 0 and result.stdout then
        for match in result.stdout:gmatch("%[%[([^%]]+)%]%]") do
          local target = link_utils.parse_target(match).name
          if target ~= "" then
            linked[target:lower()] = true
          end
        end
      end

      local orphans = {}
      for basename, rel in pairs(all_notes) do
        if not linked[basename] then
          orphans[#orphans + 1] = rel
        end
      end
      table.sort(orphans)

      if #orphans == 0 then
        vim.notify("Vault: no orphan notes found", vim.log.levels.INFO)
        return
      end

      vim.notify(
        "Vault: found " .. #orphans .. " orphan note(s)",
        vim.log.levels.WARN
      )

      local fzf = require("fzf-lua")
      fzf.fzf_exec(orphans, {
        prompt = "Orphan notes> ",
        cwd = engine.vault_path,
        file_icons = true,
        git_icons = false,
        previewer = "builtin",
        actions = {
          ["default"] = fzf.actions.file_edit,
          ["ctrl-s"] = fzf.actions.file_split,
          ["ctrl-v"] = fzf.actions.file_vsplit,
        },
      })
    end)
  end)
end
```

**Note**: `check_buffer()` (line 67) operates on the current buffer only, not
the vault. It is already fast. No change needed.

---

## 6. Implementation: tags.lua -- Single-Pass Ripgrep

### 6.1 Current dual-rg problem

**File**: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/tags.lua`

Lines 53-76 define two separate ripgrep commands:
- `inline_cmd` (line 53): finds `#tag` patterns in body text
- `frontmatter_cmd` (line 67): finds YAML `tags:\n  - tagname` blocks

This spawns two processes and coordinates them with a `pending` counter.

### 6.2 Single-pass replacement with cached results

Replace the `collect_tags` function (lines 49-116) with a version that:
1. Uses a single `rg` call with alternation
2. Caches results with a TTL to avoid re-scanning on repeated opens

```lua
-- ---------------------------------------------------------------------------
-- Tag collection: single-pass ripgrep with TTL cache
-- ---------------------------------------------------------------------------
local _tag_cache = nil
local _tag_cache_vault = nil
local _tag_cache_ts = 0
local TAG_CACHE_TTL = 15  -- seconds

--- Collect all unique tags from the vault using a single ripgrep pass.
--- Results are cached for TAG_CACHE_TTL seconds.
---@param callback fun(tags: string[])
local function collect_tags(callback)
  -- Return cached if fresh
  local now = vim.uv.now() / 1000
  if _tag_cache
    and _tag_cache_vault == engine.vault_path
    and (now - _tag_cache_ts) < TAG_CACHE_TTL
  then
    vim.schedule(function() callback(_tag_cache) end)
    return
  end

  -- Single rg command: match inline #tags OR frontmatter "  - tagname" lines.
  -- The inline pattern uses a PCRE2 lookbehind to avoid headings.
  -- The frontmatter pattern matches indented list items under any YAML key
  -- (we filter for tag-like values in post-processing).
  local cmd = {
    "rg",
    "-o",
    "-N",
    "--no-filename",
    "--glob", "*.md",
    -- Alternation: inline #tag | frontmatter list item
    "(?:(?:^|\\s)#([a-zA-Z][a-zA-Z0-9_/-]+))|(?:^\\s+- \\s*(.+))",
    engine.vault_path,
  }

  local seen = {}
  local tags = {}

  local function add_tag(name)
    local trimmed = vim.trim(name)
    -- Filter out values that don't look like tags
    -- (numbers, URLs, full sentences with spaces and punctuation)
    if trimmed == "" then return end
    if trimmed:match("^%d+$") then return end
    if trimmed:match("^https?://") then return end
    if #trimmed > 60 then return end
    -- Strip surrounding quotes
    trimmed = trimmed:gsub("^[\"'](.+)[\"']$", "%1")
    if not seen[trimmed] then
      seen[trimmed] = true
      tags[#tags + 1] = trimmed
    end
  end

  run_rg(cmd, function(line)
    -- rg -o outputs just the matched text.
    -- Could be "#tagname" (inline) or "  - tagname" (frontmatter)
    local inline_tag = line:match("#([a-zA-Z][a-zA-Z0-9_/-]+)")
    if inline_tag then
      add_tag(inline_tag)
      return
    end
    local fm_tag = line:match("^%s+-%s+(.+)$")
    if fm_tag then
      add_tag(fm_tag)
    end
  end, function()
    table.sort(tags)
    _tag_cache = tags
    _tag_cache_vault = engine.vault_path
    _tag_cache_ts = vim.uv.now() / 1000
    vim.schedule(function()
      callback(tags)
    end)
  end)
end
```

### 6.3 Invalidate on write

Add cache invalidation to the existing `BufWritePost` pattern. In `M.setup()`
(currently line 461), add within the setup function body:

```lua
  -- Invalidate tag cache when vault files change
  local tag_group = vim.api.nvim_create_augroup("VaultTagCache", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = tag_group,
    pattern = "*.md",
    callback = function()
      _tag_cache_ts = 0  -- force rebuild on next collect_tags()
    end,
  })
```

### 6.4 Alternative: keep dual-rg but add cache

If merging into a single regex proves fragile (frontmatter list items are
context-dependent and hard to distinguish from body list items), an alternative
is to keep the two-command approach but wrap results in the same TTL cache
shown above. The cache check at the top of `collect_tags` prevents redundant
subprocess spawning regardless of how many rg processes the uncached path uses.

---

## 7. Implementation: engine.lua -- Async Name Cache

### 7.1 Current synchronous path

**File**: `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/engine.lua`

Lines 422-460: `get_name_cache()` calls `vim.system(cmd):wait()` which blocks
the main thread. The 10-second TTL means this only blocks once per TTL window,
but the first call (triggered by linkdiag's `BufEnter` autocmd or completion
source init) can stall the UI.

### 7.2 Async pre-build pattern

Add an async builder that populates the cache in the background. Consumers that
need the cache synchronously still fall through to the `:wait()` path, but if
the async build has already completed, they hit the cached result.

Insert after line 460 (after the existing `get_name_cache` function):

```lua
--- Pre-build the name cache asynchronously.
--- Does nothing if the cache is already fresh.
--- Consumers that call get_name_cache() before this completes
--- will fall through to the synchronous :wait() path as before.
function M.prebuild_name_cache_async()
  local now = vim.uv.now() / 1000
  if _name_cache and _name_cache_vault == M.vault_path
     and (now - _name_cache_ts) < NAME_CACHE_TTL then
    return  -- already fresh
  end

  local cmd, use_fd = M.find_md_cmd()
  local vault_path = M.vault_path

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      -- Bail if vault switched while we were building
      if M.vault_path ~= vault_path then return end
      -- Bail if someone already rebuilt (synchronously) while we waited
      local check_now = vim.uv.now() / 1000
      if _name_cache and _name_cache_vault == vault_path
         and (check_now - _name_cache_ts) < NAME_CACHE_TTL then
        return
      end

      if result.code ~= 0 or not result.stdout then return end

      local names = {}
      local paths = {}
      for line in result.stdout:gmatch("[^\n]+") do
        local rel = use_fd and line:gsub("^%./", "") or line:sub(#vault_path + 2)
        local abs = use_fd and (vault_path .. "/" .. rel) or line
        local basename = vim.fn.fnamemodify(abs, ":t:r"):lower()
        names[basename] = true
        if not paths[basename] then
          paths[basename] = abs
        end
        local rel_stem = rel:gsub("%.md$", ""):lower()
        if rel_stem ~= basename then
          names[rel_stem] = true
          if not paths[rel_stem] then
            paths[rel_stem] = abs
          end
        end
      end

      _name_cache = { names = names, paths = paths }
      _name_cache_vault = vault_path
      _name_cache_ts = check_now
    end)
  end)
end
```

Then call this from the wikilinks `BufReadPost` pre-warm autocmd, or add a
separate pre-warm in engine:

```lua
-- Add to the bottom of engine.lua, before `return M`:
vim.api.nvim_create_autocmd("BufReadPost", {
  pattern = "*.md",
  once = true,
  callback = function()
    vim.defer_fn(function()
      M.prebuild_name_cache_async()
    end, 100)
  end,
})
```

---

## 8. Benchmarking

### 8.1 Startup time measurement

Use Neovim's built-in `--startuptime`:

```bash
# Before changes (baseline):
nvim --startuptime /tmp/startup-before.log -c 'qall'

# After changes:
nvim --startuptime /tmp/startup-after.log -c 'qall'

# Compare:
tail -1 /tmp/startup-before.log
tail -1 /tmp/startup-after.log
```

### 8.2 Targeted cache timing

Add instrumentation inside `build_cache()`:

```lua
local function build_cache()
  local start = vim.uv.hrtime()
  -- ... existing build logic ...
  local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
  vim.notify(string.format("Vault: wikilink cache built in %.1fms (%d entries)",
    elapsed_ms, vim.tbl_count(cache)), vim.log.levels.DEBUG)
end
```

### 8.3 Vault size profiling command

Add a diagnostic command to measure cache performance:

```lua
vim.api.nvim_create_user_command("VaultCacheBench", function()
  -- Force invalidate
  M.invalidate_cache()
  engine.invalidate_name_cache()

  local t0 = vim.uv.hrtime()
  build_cache()   -- wikilink cache
  local t1 = vim.uv.hrtime()
  engine.get_name_cache()  -- name cache
  local t2 = vim.uv.hrtime()

  vim.notify(string.format(
    "Vault cache bench:\n  wikilink cache: %.1fms\n  name cache: %.1fms\n  total: %.1fms",
    (t1 - t0) / 1e6,
    (t2 - t1) / 1e6,
    (t2 - t0) / 1e6
  ), vim.log.levels.INFO)
end, { desc = "Benchmark vault cache build times" })
```

### 8.4 Expected improvement

| Metric | Before | After (lazy) |
|--------|--------|--------------|
| Startup time (non-vault file) | +100-170ms | +0ms |
| Startup time (vault file) | +100-170ms | +0ms (50ms deferred pre-warm) |
| First `gf` press (cold) | 0ms (already cached) | ~100-170ms (builds cache) |
| First `gf` press (after pre-warm) | 0ms | 0ms |
| Subsequent `gf` presses | 0ms | 0ms |

The net effect: **startup is ~100-170ms faster**. The cost is shifted to the
first interaction, but the `BufReadPost` pre-warm with `once = true` and
`defer_fn(50)` ensures the cache is ready before the user is likely to press
`gf`.

---

## 9. Gotchas

### 9.1 Race condition: async pre-warm vs synchronous access

**Scenario**: User opens a vault file, the `BufReadPost` pre-warm fires
`defer_fn(50)`. Before those 50ms elapse, the user presses `gf`.

**Mitigation**: `ensure_cache()` is synchronous. If the cache is not valid when
`resolve_link()` is called, it builds synchronously on the spot. The deferred
pre-warm is a best-effort optimization, not a correctness requirement. When
`build_cache` later runs from the deferred callback, it sees `cache_valid =
true` and returns immediately (via the `ensure_cache` guard). The
`cache_building` flag prevents concurrent re-entrant builds.

### 9.2 Race condition: engine async name cache

**Scenario**: `prebuild_name_cache_async()` fires. While it's running,
`linkdiag.validate()` calls `engine.get_name_cache()` synchronously.

**Mitigation**: The synchronous path in `get_name_cache()` builds its own
cache and updates `_name_cache_ts`. When the async callback fires, it checks
the timestamp and bails out if the cache is already fresh. No data corruption
possible because both paths write the same structure atomically (single Lua
assignment to `_name_cache`).

### 9.3 Vault switch during async build

**Scenario**: User calls `:VaultSwitch` while an async cache build is in
progress.

**Mitigation**: Both the wikilinks `build_cache` and the engine
`prebuild_name_cache_async` store the vault path at build start and compare
against `engine.vault_path` before committing results. If the vault changed,
the stale results are discarded. The `cache_vault` comparison in
`ensure_cache()` forces a fresh build for the new vault.

### 9.4 Module load order

**Concern**: Other modules (`embed.lua`, `preview.lua`, `graph.lua`) do
`local wikilinks = require("andrew.vault.wikilinks")` at module load time
(line 1-4 of each file). With eager cache building, the cache was populated
before these modules loaded. With lazy building, the cache is empty at load
time.

**Why this is fine**: None of these modules access the cache at `require`
time. They only call `wikilinks.resolve_link()` from within callback
functions (autocmd handlers, keymap callbacks, user commands). By the time
those callbacks execute, the lazy cache will build on demand via
`ensure_cache()`.

### 9.5 `once = true` pre-warm edge case

**Concern**: The `BufReadPost` autocmd with `once = true` fires only for the
first markdown file. If the first `.md` file is not in the vault (e.g., a
README.md in a code project), the pre-warm does nothing.

**Mitigation**: The `engine.is_vault_path(bufpath)` guard prevents pre-warming
for non-vault files. However, the `once = true` means the autocmd is consumed
and won't fire again for a subsequent vault file.

**Fix**: Replace `once = true` with a manual flag:

```lua
local prewarm_done = false

vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  pattern = "*.md",
  callback = function(ev)
    if prewarm_done then return end
    local bufpath = vim.api.nvim_buf_get_name(ev.buf)
    if engine.is_vault_path(bufpath) then
      prewarm_done = true
      vim.defer_fn(function()
        ensure_cache()
      end, 50)
    end
  end,
})
```

This way the autocmd keeps firing until a vault file is actually opened, then
stops. This is slightly more expensive (the autocmd fires for every `.md`
`BufReadPost` until prewarm) but ensures the pre-warm targets the right file.

### 9.6 Frontmatter parsing during lazy build

**Concern**: `fm_parser.parse_file(path)` does `io.open()` for every file in
the vault to read aliases. This is the dominant cost in `build_cache()`.

**Future optimization**: Build the alias index lazily too. Most notes don't have
aliases. Use a two-tier approach:

1. **Tier 1** (fast): Index by basename only using `fd` output (no `io.open`).
2. **Tier 2** (deferred): Async scan for aliases using `rg` to find files with
   `aliases:` in frontmatter, then parse only those files.

This would reduce the cache build from ~150ms to ~20ms for tier 1, with tier 2
running asynchronously in the background.

```lua
-- Tier 1: fast basename-only index (no IO beyond fd)
local function build_cache_fast()
  cache = {}
  local vault_path = engine.vault_path
  cache_vault = vault_path
  local cmd, use_fd = engine.find_md_cmd(vault_path)
  local result = vim.system(cmd, { text = true }):wait()
  if result.code == 0 and result.stdout then
    for line in result.stdout:gmatch("[^\n]+") do
      local rel = use_fd and line:gsub("^%./", "") or line:sub(#vault_path + 2)
      local abs = use_fd and (vault_path .. "/" .. rel) or line
      local basename = vim.fn.fnamemodify(abs, ":t:r"):lower()
      if not cache[basename] then
        cache[basename] = {}
      end
      table.insert(cache[basename], abs)
    end
  end
  cache_valid = true
end

-- Tier 2: async alias enrichment
local function enrich_aliases_async()
  vim.system({
    "rg", "-l", "--glob", "*.md", "^aliases:", engine.vault_path,
  }, { text = true }, function(result)
    vim.schedule(function()
      if not result.stdout or result.stdout == "" then return end
      for path in result.stdout:gmatch("[^\n]+") do
        local fm = fm_parser.parse_file(path)
        local aliases = fm and fm.fields.aliases or nil
        if type(aliases) == "string" then aliases = { aliases } end
        if aliases then
          local basename = vim.fn.fnamemodify(path, ":t:r"):lower()
          for _, alias in ipairs(aliases) do
            local key = alias:lower()
            if key ~= basename then
              if not cache[key] then
                cache[key] = {}
              end
              -- Avoid duplicate entries
              local found = false
              for _, existing in ipairs(cache[key]) do
                if existing == path then found = true; break end
              end
              if not found then
                table.insert(cache[key], path)
              end
            end
          end
        end
      end
    end)
  end)
end
```

This two-tier approach is a further optimization that can be done in a
follow-up. The primary lazy conversion (section 4) already eliminates the
startup cost.

---

## 10. Summary of Changes

| File | Line(s) | Change | Impact |
|------|---------|--------|--------|
| `wikilinks.lua` | 7-52 | Replace cache vars + build_cache with lazy version using `engine.find_md_cmd()` | Eliminates startup scan |
| `wikilinks.lua` | 381-427 | Remove `build_cache()` from `setup()`, add `BufReadPost` pre-warm | Startup: -100-170ms |
| `linkcheck.lua` | 136-236 | Convert `check_vault()` from `:wait()` to async callback | Unblocks UI during vault scan |
| `linkcheck.lua` | 241-311 | Convert `check_orphans()` from `:wait()` to async callback | Unblocks UI during orphan scan |
| `tags.lua` | 49-116 | Merge dual rg into single pass, add TTL cache | Fewer subprocesses, cached results |
| `tags.lua` | 461+ | Add `BufWritePost` invalidation for tag cache | Cache consistency |
| `engine.lua` | 460+ | Add `prebuild_name_cache_async()` function | Background pre-warm for name cache |
| `engine.lua` | bottom | Add `BufReadPost` once-autocmd for async pre-warm | Reduces first-access latency |

### Priority order

1. **wikilinks.lua lazy cache** -- highest impact, eliminates the only startup-blocking scan
2. **linkcheck.lua async** -- improves UX for vault-wide commands
3. **tags.lua single-pass + cache** -- reduces subprocess overhead
4. **engine.lua async pre-build** -- polish, reduces edge-case latency
