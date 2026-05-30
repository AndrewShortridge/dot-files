# Filter Pipeline

## File: `lua/andrew/vault/search_filter.lua`

The filter pipeline evaluates a search query AST against vault index entries
and ripgrep results, producing a filtered set of file paths.

## Architecture

```
     Query AST
         |
    +----v----+
    | split_  |   Classify leaves as metadata vs text
    | ast()   |
    +--+---+--+
       |   |
  +----+   +----+
  |              |
  v              v
Metadata AST   Text Nodes[]
  |              |
  v              v
match_entry()  ripgrep_in_files()
  |              |
  v              v
File set A     File set B
  |              |
  +------+-------+
         |
    +----v-----+
    | Result   |   AND/OR/NOT set operations
    | Combiner |
    +----+-----+
         |
         v
    Final file set (for fzf-lua display)
```

## Public API

### `M.split_ast(ast)`

Walks the AST and classifies each leaf node as "metadata" (evaluable from the
index) or "text" (requires ripgrep).

```lua
---@param ast table  parsed query AST
---@return table|nil metadata_ast  AST with only metadata nodes (nil if none)
---@return table[]   text_nodes    list of text/regex leaf nodes
function M.split_ast(ast)
```

**Classification rules:**
- `field`, `has`, `task` → metadata
- `text`, `regex` → text
- `and`, `or`, `not` → depends on children

**For pure metadata queries:** Returns the full AST as metadata_ast, empty text_nodes.
**For pure text queries:** Returns nil metadata_ast, all nodes as text_nodes.
**For mixed queries:** Returns a metadata_ast with text leaves removed, and
the text leaves collected separately.

### `M.match_entry(ast, entry)`

Evaluates a metadata-only AST against a single VaultIndexEntry.

```lua
---@param ast table            metadata AST node
---@param entry VaultIndexEntry
---@return boolean matches
function M.match_entry(ast, entry)
```

### `M.evaluate(ast, index)`

Full evaluation: splits AST, runs metadata filtering, returns matching paths
and text terms.

```lua
---@param ast table          parsed query AST
---@param index VaultIndex   the vault index instance
---@return table<string, boolean>  matching rel_paths
---@return table[]                 text_terms for ripgrep
function M.evaluate(ast, index)
```

### `M.ripgrep_in_files(text_nodes, matches, vault_path)`

Runs ripgrep restricted to a set of files, returning grep-format results.

```lua
---@param text_nodes table[]          text/regex AST nodes
---@param matches VaultIndexEntry[]   metadata-matched entries
---@param vault_path string           vault root directory
---@return string[]                   ripgrep result lines
function M.ripgrep_in_files(text_nodes, matches, vault_path)
```

## AST Splitting Algorithm

```lua
function M.split_ast(ast)
  local text_nodes = {}

  local function walk(node)
    if not node then return nil end

    if node.type == "text" or node.type == "regex" then
      text_nodes[#text_nodes + 1] = node
      return nil  -- removed from metadata tree
    end

    if node.type == "field" or node.type == "has" or node.type == "task" then
      return node  -- kept in metadata tree
    end

    if node.type == "not" then
      local inner = walk(node.operand)
      if inner then
        return { type = "not", operand = inner }
      end
      -- If operand was text, this NOT applies to text search
      -- The text_node already captured; we need special handling
      return nil
    end

    if node.type == "and" then
      local left = walk(node.left)
      local right = walk(node.right)
      if left and right then
        return { type = "and", left = left, right = right }
      end
      return left or right  -- if one side was text-only, keep the other
    end

    if node.type == "or" then
      local left = walk(node.left)
      local right = walk(node.right)
      if left and right then
        return { type = "or", left = left, right = right }
      end
      -- OR with mixed metadata/text is complex; see "Mixed OR" below
      return left or right
    end

    return node
  end

  local metadata_ast = walk(ast)
  return metadata_ast, text_nodes
end
```

### Mixed OR Handling

When an OR node has one metadata child and one text child, the split is
ambiguous. The strategy:

- If `(metadata_filter) OR (text_term)`: both paths must be evaluated
  independently and their result sets unioned.
- This is tracked by marking the text_node with its boolean context.
- For v1, complex mixed OR expressions fall back to evaluating both paths
  and combining results.

## Field Filter Evaluation

### `match_entry(ast, entry)`

```lua
function M.match_entry(ast, entry)
  if ast.type == "and" then
    return M.match_entry(ast.left, entry) and M.match_entry(ast.right, entry)
  end

  if ast.type == "or" then
    return M.match_entry(ast.left, entry) or M.match_entry(ast.right, entry)
  end

  if ast.type == "not" then
    return not M.match_entry(ast.operand, entry)
  end

  if ast.type == "field" then
    return match_field(ast, entry)
  end

  if ast.type == "has" then
    return match_has(ast, entry)
  end

  if ast.type == "task" then
    return match_task(ast, entry)
  end

  return false  -- unknown node type
end
```

### Field Match Rules

```lua
local function match_field(node, entry)
  local name = node.name
  local op = node.op
  local value = node.value
  local value2 = node.value2

  -- Dispatch by field name
  if name == "type" then
    return match_string(entry.frontmatter and entry.frontmatter.type, op, value)

  elseif name == "tag" then
    return match_tag(entry.tags, value)

  elseif name == "path" then
    return match_prefix(entry.rel_path, value)

  elseif name == "file" then
    return match_substring_ci(entry.basename, value)

  elseif name == "folder" then
    return match_folder(entry.folder, value)

  elseif name == "status" then
    local actual = (entry.frontmatter and entry.frontmatter.status)
                or (entry.inline_fields and entry.inline_fields.status)
    return match_string(actual, op, value)

  elseif name == "priority" then
    local actual = (entry.frontmatter and entry.frontmatter.priority)
                or (entry.inline_fields and entry.inline_fields.priority)
    return match_numeric(tonumber(actual), op, tonumber(value), tonumber(value2))

  elseif name == "created" then
    local t = entry.ctime or entry.mtime  -- fallback if ctime nil
    return match_date(t, op, value, value2)

  elseif name == "modified" then
    return match_date(entry.mtime, op, value, value2)

  elseif name == "day" then
    return match_day(entry.day, op, value, value2)

  else
    -- Generic field: check frontmatter then inline_fields
    local actual = (entry.frontmatter and entry.frontmatter[name])
                or (entry.inline_fields and entry.inline_fields[name])
    if actual == nil then return false end
    return match_string(tostring(actual), op, value)
  end
end
```

### Match Helper Functions

#### String Match (case-insensitive)
```lua
local function match_string(actual, op, expected)
  if actual == nil then return false end
  actual = tostring(actual):lower()
  expected = expected:lower()
  if op == "=" then
    return actual == expected
  end
  return false
end
```

#### Tag Match (prefix)
```lua
local function match_tag(tags, target)
  if not tags then return false end
  target = target:lower()
  for _, tag in ipairs(tags) do
    -- Exact match or parent match (tag starts with target/)
    if tag == target or tag:sub(1, #target + 1) == target .. "/" then
      return true
    end
  end
  return false
end
```

Tags are already stored lowercase in the index.

#### Path Prefix Match
```lua
local function match_prefix(actual, prefix)
  if not actual then return false end
  return actual:sub(1, #prefix) == prefix
end
```

#### Substring Match (case-insensitive)
```lua
local function match_substring_ci(actual, needle)
  if not actual then return false end
  return actual:lower():find(needle:lower(), 1, true) ~= nil
end
```

#### Folder Match
```lua
local function match_folder(actual, target)
  if not actual then return false end
  return actual == target or actual:sub(1, #target + 1) == target .. "/"
end
```

#### Numeric Comparison
```lua
local function match_numeric(actual, op, value, value2)
  if not actual then return false end
  if op == "="  then return actual == value end
  if op == ">"  then return actual > value end
  if op == ">=" then return actual >= value end
  if op == "<"  then return actual < value end
  if op == "<=" then return actual <= value end
  if op == ".." then return actual >= value and actual <= value2 end
  return false
end
```

#### Has Match
```lua
local function match_has(node, entry)
  local target = node.target
  if target == "tags"        then return entry.tags and #entry.tags > 0 end
  if target == "aliases"     then return entry.aliases and #entry.aliases > 0 end
  if target == "tasks"       then return entry.tasks and #entry.tasks > 0 end
  if target == "outlinks"    then return entry.outlinks and #entry.outlinks > 0 end
  if target == "inlinks"     then
    -- Requires index access for _inlinks table
    -- Handled specially in evaluate()
    return false
  end
  if target == "frontmatter" then
    return entry.frontmatter and next(entry.frontmatter) ~= nil
  end
  -- Generic: check if field exists and is non-empty
  local val = (entry.frontmatter and entry.frontmatter[target])
           or (entry.inline_fields and entry.inline_fields[target])
  return val ~= nil and val ~= ""
end
```

#### Task Match
```lua
local function match_task(node, entry)
  if not entry.tasks or #entry.tasks == 0 then return false end
  if node.variant == "any" then return true end
  if node.variant == "todo" then
    for _, t in ipairs(entry.tasks) do
      if not t.completed then return true end
    end
    return false
  end
  if node.variant == "done" then
    for _, t in ipairs(entry.tasks) do
      if t.completed then return true end
    end
    return false
  end
  return false
end
```

## Date Value Parsing

```lua
local function resolve_date(value)
  local now = os.time()

  -- Relative: "7d", "30d", "90d"
  local days = value:match("^(%d+)d$")
  if days then
    return now - (tonumber(days) * 86400)
  end

  -- Named shortcuts
  if value == "today" then
    local t = os.date("*t", now)
    return os.time({ year = t.year, month = t.month, day = t.day,
                     hour = 0, min = 0, sec = 0 })
  end

  if value == "yesterday" then
    local t = os.date("*t", now - 86400)
    return os.time({ year = t.year, month = t.month, day = t.day,
                     hour = 0, min = 0, sec = 0 })
  end

  if value == "this-week" then
    local t = os.date("*t", now)
    local wday = t.wday  -- 1=Sunday, 2=Monday, ...
    local days_since_monday = (wday - 2) % 7
    local monday = now - (days_since_monday * 86400)
    local mt = os.date("*t", monday)
    return os.time({ year = mt.year, month = mt.month, day = mt.day,
                     hour = 0, min = 0, sec = 0 })
  end

  if value == "this-month" then
    local t = os.date("*t", now)
    return os.time({ year = t.year, month = t.month, day = 1,
                     hour = 0, min = 0, sec = 0 })
  end

  -- Absolute: "YYYY-MM-DD"
  local y, m, d = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if y then
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d),
                     hour = 0, min = 0, sec = 0 })
  end

  -- Partial: "YYYY-MM" (start of month)
  local y2, m2 = value:match("^(%d%d%d%d)-(%d%d)$")
  if y2 then
    return os.time({ year = tonumber(y2), month = tonumber(m2), day = 1,
                     hour = 0, min = 0, sec = 0 })
  end

  return nil
end
```

### Date Comparison

```lua
local function match_date(timestamp, op, value, value2)
  if not timestamp then return false end

  if op == ">" then
    local threshold = resolve_date(value)
    if not threshold then return false end
    return timestamp >= threshold
  end

  if op == ">=" then
    local threshold = resolve_date(value)
    if not threshold then return false end
    return timestamp >= threshold
  end

  if op == "<" then
    local threshold = resolve_date(value)
    if not threshold then return false end
    return timestamp < threshold
  end

  if op == "<=" then
    local threshold = resolve_date(value)
    if not threshold then return false end
    return timestamp <= threshold
  end

  if op == "=" then
    -- Exact date match: compare date portion only
    local threshold = resolve_date(value)
    if not threshold then return false end
    local t1 = os.date("*t", timestamp)
    local t2 = os.date("*t", threshold)
    return t1.year == t2.year and t1.month == t2.month and t1.day == t2.day
  end

  if op == ".." then
    local lo = resolve_date(value)
    local hi = resolve_date(value2)
    if not lo or not hi then return false end
    -- End of range: add 1 day (or 1 month for partial dates)
    return timestamp >= lo and timestamp < hi + 86400
  end

  return false
end
```

### Day Field Matching

The `day` field is a string (`"YYYY-MM-DD"`), not a timestamp:

```lua
local function match_day(day, op, value, value2)
  if not day then return false end
  if op == "=" then return day == value end
  if op == ".." then return day >= value and day <= value2 end
  if op == ">" then
    local threshold = resolve_date(value)
    if not threshold then return false end
    -- Convert day string to timestamp for comparison
    local y, m, d = day:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not y then return false end
    local ts = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
    return ts >= threshold
  end
  -- ... similar for <, >=, <=
  return false
end
```

## Ripgrep Integration

### `ripgrep_in_files(text_nodes, matches, vault_path)`

Runs ripgrep restricted to metadata-matched files using `--files-from`:

```lua
function M.ripgrep_in_files(text_nodes, matches, vault_path)
  -- Build the list of file paths
  local file_list = {}
  for _, entry in ipairs(matches) do
    file_list[#file_list + 1] = entry.rel_path
  end

  -- If too many files, skip --files-from and search full vault
  local config = require("andrew.vault.config")
  local max_files = config.search and config.search.max_files_from or 500
  local use_files_from = #file_list <= max_files

  -- Build ripgrep command for each text term
  local results = {}
  for _, node in ipairs(text_nodes) do
    local pattern
    if node.type == "regex" then
      pattern = node.pattern
    elseif node.quoted then
      pattern = vim.fn.shellescape(node.value)  -- exact match
    else
      pattern = vim.fn.shellescape(node.value)
    end

    local cmd
    if use_files_from then
      -- Write file list to temp file
      local tmpfile = os.tmpname()
      local f = io.open(tmpfile, "w")
      for _, path in ipairs(file_list) do
        f:write(path .. "\n")
      end
      f:close()

      cmd = string.format(
        "rg --column --line-number --no-heading --color=always --smart-case "
        .. "--files-from %s -- %s",
        vim.fn.shellescape(tmpfile),
        pattern
      )
    else
      cmd = string.format(
        "rg --column --line-number --no-heading --color=always --smart-case "
        .. '--glob "*.md" -- %s',
        pattern
      )
    end

    -- Execute from vault root
    local handle = io.popen("cd " .. vim.fn.shellescape(vault_path) .. " && " .. cmd)
    if handle then
      for line in handle:lines() do
        results[#results + 1] = line
      end
      handle:close()
    end

    -- Clean up temp file
    if use_files_from then os.remove(tmpfile) end
  end

  -- If use_files_from was false, post-filter results against metadata matches
  if not use_files_from and #matches > 0 then
    local match_set = {}
    for _, entry in ipairs(matches) do
      match_set[entry.rel_path] = true
    end
    local filtered = {}
    for _, line in ipairs(results) do
      local file = line:match("^([^:]+):")
      if file and match_set[file] then
        filtered[#filtered + 1] = line
      end
    end
    results = filtered
  end

  return results
end
```

### Multiple Text Terms with AND

When multiple text terms are connected by AND, run ripgrep once per term and
intersect the file sets:

```lua
-- For AND: intersect result files
local file_sets = {}
for _, node in ipairs(text_nodes) do
  local results = run_rg_single(node, file_list, vault_path)
  local files = {}
  for _, line in ipairs(results) do
    local f = line:match("^([^:]+):")
    if f then files[f] = true end
  end
  file_sets[#file_sets + 1] = files
end

-- Intersect all file sets
local intersection = file_sets[1]
for i = 2, #file_sets do
  local next_set = {}
  for f in pairs(intersection) do
    if file_sets[i][f] then next_set[f] = true end
  end
  intersection = next_set
end
```

### Multiple Text Terms with OR

When connected by OR, use ripgrep alternation:

```lua
-- For OR: combine patterns with |
local patterns = {}
for _, node in ipairs(text_nodes) do
  patterns[#patterns + 1] = node.value
end
local combined = table.concat(patterns, "|")
-- Single ripgrep call with alternation
```

## Performance Considerations

### Metadata Filtering Speed
- O(N) iteration over in-memory data (no I/O)
- For 500 files: < 5ms
- For 1000 files: < 10ms

### Ripgrep with `--files-from`
- Restricts search to metadata-matched files
- Significant speedup when metadata filters are selective
- Falls back to full vault search when > `max_files_from` matches

### Debounce for Live Mode
- Re-parsing on every keystroke: < 0.1ms per parse
- Metadata evaluation: < 5ms
- Ripgrep execution: varies, but fzf-lua handles streaming
- Target: < 300ms total perceived latency
