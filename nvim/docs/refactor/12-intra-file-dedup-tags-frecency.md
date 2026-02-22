# Feature 12: Intra-File Deduplication — `tags.lua` + `frecency.lua`

## Dependencies
- **None** — these are self-contained intra-file refactors.
- **Depended on by:** Nothing

## Problem

### 12a: tags.lua — 3 internal duplications

**1. Line-splitting logic (exact copy within same file):**
- Lines 183-190 (inside `add_tag`):
```lua
local lines = {}
for line in (content .. "\n"):gmatch("(.-)\n") do
  lines[#lines + 1] = line
end
if #lines > 0 and lines[#lines] == "" and not content:match("\n$") then
  lines[#lines] = nil
end
```
- Lines 363-369 (inside `remove_tag`): character-for-character identical

**2. Buffer reload logic (exact copy within same file):**
- Lines 290-302 (inside `add_tag`):
```lua
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) then
    local bufname = vim.api.nvim_buf_get_name(buf)
    for _, abs in ipairs(modified_paths) do
      if bufname == abs then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("edit!")
        end)
        break
      end
    end
  end
end
```
- Lines 461-473 (inside `remove_tag`): identical except variable name (`abs` vs `path`, `modified_paths` vs `files`)

**3. `vim.system()` rg callback pattern (3 copies):**
- Lines 61-72, 75-92, 340-349: same callback structure — check exit code, schedule notify on error, iterate stdout lines

### 12b: frecency.lua — scored entries loop duplicated

- Lines 122-134 (`ranked_files`):
```lua
local db = load_db()
local vault = engine.vault_path
local now = os.time()
local scored = {}
for rel, entry in pairs(db) do
  local abs = vault .. "/" .. rel
  if vim.fn.filereadable(abs) == 1 then
    scored[#scored + 1] = { path = rel, score = M.score(entry, now) }
  end
end
table.sort(scored, function(a, b) return a.score > b.score end)
```
- Lines 159-170 (`frequent_files`): character-for-character identical

`ranked_files` then appends untracked files. `frequent_files` does not. The shared scoring part is an exact duplicate.

## Files to Modify
1. `lua/andrew/vault/tags.lua` — Extract 3 local helpers
2. `lua/andrew/vault/frecency.lua` — Extract 1 local helper

## Implementation Steps

### Step 1: tags.lua — Extract `split_lines(content)`

Add near the top of tags.lua (after the require block):

```lua
--- Split file content string into a lines array.
--- @param content string
--- @return string[]
local function split_lines(content)
  local lines = {}
  for line in (content .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if #lines > 0 and lines[#lines] == "" and not content:match("\n$") then
    lines[#lines] = nil
  end
  return lines
end
```

Replace lines 183-190 in `add_tag` with: `local lines = split_lines(content)`
Replace lines 363-369 in `remove_tag` with: `local lines = split_lines(content)`

### Step 2: tags.lua — Extract `reload_buffers(paths)`

```lua
--- Reload any open buffers whose file path is in the given list.
--- @param paths string[]
local function reload_buffers(paths)
  local path_set = {}
  for _, p in ipairs(paths) do path_set[p] = true end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local bufname = vim.api.nvim_buf_get_name(buf)
      if path_set[bufname] then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("edit!")
        end)
      end
    end
  end
end
```

Replace lines 290-302 in `add_tag` with: `reload_buffers(modified_paths)`
Replace lines 461-473 in `remove_tag` with: `reload_buffers(files)`

Note: The replacement version uses a set lookup (`path_set`) instead of nested loops, which is also more efficient for large path lists.

### Step 3: tags.lua — Extract `run_rg(cmd, on_lines, on_done)`

```lua
--- Run a ripgrep command asynchronously and process stdout lines.
--- @param cmd string[]  The rg command and arguments
--- @param on_line fun(line: string)  Called for each stdout line
--- @param on_done fun()  Called when command completes
local function run_rg(cmd, on_line, on_done)
  vim.system(cmd, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("Vault tags: rg failed (exit " .. (result.code or "?") .. ")", vim.log.levels.WARN)
      end)
    elseif result.stdout and result.stdout ~= "" then
      for line in result.stdout:gmatch("[^\n]+") do
        on_line(line)
      end
    end
    if on_done then on_done() end
  end)
end
```

Replace the three `vim.system()` callback blocks (lines 61-72, 75-92, 340-349) with calls to `run_rg()`.

### Step 4: frecency.lua — Extract `scored_entries()`

Add near the scoring functions:

```lua
--- Compute scored entries for all tracked files that still exist.
--- @return { path: string, score: number }[]  Sorted descending by score
local function scored_entries()
  local db = load_db()
  local vault = engine.vault_path
  local now = os.time()
  local scored = {}
  for rel, entry in pairs(db) do
    local abs = vault .. "/" .. rel
    if vim.fn.filereadable(abs) == 1 then
      scored[#scored + 1] = { path = rel, score = M.score(entry, now) }
    end
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  return scored
end
```

Replace lines 122-134 in `ranked_files` with:
```lua
local scored = scored_entries()
-- Then append untracked files (existing logic at lines 135-155)...
```

Replace lines 159-170 in `frequent_files` with:
```lua
local scored = scored_entries()
```

## Testing

### tags.lua
- `VaultTagAdd` — add a tag to multiple files, verify tag appears in each, verify open buffers reload
- `VaultTagRemove` — remove a tag from multiple files, verify tag removed, verify buffers reload
- `VaultTags` — tag collection picker works, shows correct counts

### frecency.lua
- `VaultFiles` — shows files sorted by frecency score, includes untracked files at bottom
- `VaultRecent` — shows recently accessed files sorted by score (no untracked files)
- Open several files, then check `VaultFiles` — verify recently opened files are ranked higher

## Estimated Impact
- **tags.lua:** ~30 lines removed, ~20 lines added → net ~10 lines saved
- **frecency.lua:** ~12 lines removed, ~10 lines added → net ~2 lines saved
- **Total net reduction:** ~12 lines
- **Readability:** Significantly improved — each function has a clear name and single responsibility
