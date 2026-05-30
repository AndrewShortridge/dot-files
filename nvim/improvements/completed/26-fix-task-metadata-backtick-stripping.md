# Fix: Task Metadata Extraction Incorrectly Parses Inline Fields Inside Backticks

## Severity

Medium -- causes phantom metadata on tasks containing inline code examples that happen to match the `[key:: value]` or `(key:: value)` pattern. Can corrupt search results, calendar deadlines, and task priority ordering.

## Summary

`parse_task_fields()` in `vault_index.lua` runs its `gmatch` patterns directly on the raw task text without first stripping backtick-delimited code spans. This means a task like:

```
- [ ] Check `[due:: fake]` value
```

will incorrectly extract `due = "fake"` even though the inline field is inside a code span and should be treated as literal text. The same issue affects `extract_inline_fields()` which also operates on raw lines without stripping inline code.

The sibling module `inline_fields.lua` does NOT have this bug -- it uses `build_code_exclusion()` from `link_scan.lua` to check whether each parsed field falls inside a code span before highlighting it (line 419). However, the vault index parser operates on raw file content (not a buffer), so treesitter-based exclusion is unavailable. It must use string-level stripping instead.

## Root Cause

### `parse_task_fields()` (line 453)

The function receives the raw task text and directly runs `gmatch` against it:

```lua
-- vault_index.lua, line 453
local function parse_task_fields(text)
  local result = {}
  local extra = {}

  for key, value in text:gmatch("%[([%w_%-]+)::%s*(.-)%]") do   -- line 457
    -- ...
  end

  for key, value in text:gmatch("%(([%w_%-]+)::%s*(.-)%)") do   -- line 490
    -- ...
  end
  -- ...
end
```

There is no stripping of backtick-enclosed content before the pattern scan. The `text` parameter comes directly from `extract_tasks()` at line 542:

```lua
-- vault_index.lua, line 542
local task_meta = parse_task_fields(text)
```

where `text` is the raw remainder of the task line after `- [x] `.

### `extract_inline_fields()` (line 567)

Same problem -- iterates raw body lines and matches `[key:: value]` / `(key:: value)` without stripping code spans:

```lua
-- vault_index.lua, line 567
local function extract_inline_fields(body)
  local fields = {}
  for line in body:gmatch("[^\n]+") do
    if line:match("^%s*[-*] %[.%] ") then goto continue end
    for key, value in line:gmatch("([%w_%-]+)::%s*(.-)%s*$") do  -- line 571
      -- ...
    end
    for key, value in line:gmatch("%[([%w_%-]+)::%s*(.-)%]") do  -- line 576
      -- ...
    end
    for key, value in line:gmatch("%(([%w_%-]+)::%s*(.-)%)") do  -- line 579
      -- ...
    end
    ::continue::
  end
  return fields
end
```

### Existing `strip_code_blocks()` -- almost right but insufficient

The existing helper at line 219 handles fenced code blocks AND single backtick spans:

```lua
-- vault_index.lua, line 219
local function strip_code_blocks(text)
  local lines = {}
  local in_fence = false
  for line in text:gmatch("[^\n]*") do
    if line:match("^%s*```") then
      in_fence = not in_fence
      lines[#lines + 1] = ""
    elseif in_fence then
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = line:gsub("`[^`]+`", "")   -- single backtick spans
    end
  end
  return table.concat(lines, "\n")
end
```

This function is already used by `extract_tags()` (line 347) and `extract_links()` (line 407), but it is **not** called by `parse_task_fields()` or `extract_inline_fields()`.

However, the inline code stripping pattern `` `[^`]+` `` has two problems:

1. It does not handle double-backtick spans (`` `` `code` `` ``), which are valid Markdown for embedding literal backticks.
2. It does not handle triple-backtick inline spans (``` `` ` `` ```).

These are edge cases but should be handled correctly.

## The Fix

### Step 1: Improve `strip_code_blocks()` to handle multi-backtick inline spans

Replace the single inline code gsub with a function that strips all backtick-delimited spans, handling variable-length backtick delimiters (single, double, triple).

**File:** `lua/andrew/vault/vault_index.lua`

**Before** (line 219-233):

```lua
local function strip_code_blocks(text)
  local lines = {}
  local in_fence = false
  for line in text:gmatch("[^\n]*") do
    if line:match("^%s*```") then
      in_fence = not in_fence
      lines[#lines + 1] = ""
    elseif in_fence then
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = line:gsub("`[^`]+`", "")
    end
  end
  return table.concat(lines, "\n")
end
```

**After:**

```lua
--- Strip inline code spans from a single line.
--- Handles variable-length backtick delimiters: `, ``, ```, etc.
--- Replaces each code span with spaces of equal length to preserve byte offsets
--- for downstream consumers that don't need them (we blank them out).
---@param line string
---@return string line with code spans replaced by spaces
local function strip_inline_code(line)
  local result = {}
  local pos = 1
  local len = #line

  while pos <= len do
    -- Count consecutive backticks at current position
    local bt_start = pos
    while pos <= len and line:sub(pos, pos) == "`" do
      pos = pos + 1
    end
    local bt_len = pos - bt_start

    if bt_len == 0 then
      -- Not a backtick: copy character as-is
      result[#result + 1] = line:sub(pos, pos)
      pos = pos + 1
    else
      -- We found bt_len backticks. Look for matching closing sequence.
      local closer = ("`"):rep(bt_len)
      local close_start = line:find(closer, pos, true)

      if close_start then
        -- Found matching closer: blank out the entire span (open + content + close)
        local span_len = (close_start + bt_len) - bt_start
        result[#result + 1] = (" "):rep(span_len)
        pos = close_start + bt_len
      else
        -- No matching closer: these backticks are literal text
        result[#result + 1] = line:sub(bt_start, bt_start + bt_len - 1)
        -- pos is already advanced past the backticks
      end
    end
  end

  return table.concat(result)
end

--- Strip fenced code blocks (multi-line) and inline code spans (single-line).
local function strip_code_blocks(text)
  local lines = {}
  local in_fence = false
  for line in text:gmatch("[^\n]*") do
    if line:match("^%s*```") then
      in_fence = not in_fence
      lines[#lines + 1] = ""
    elseif in_fence then
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = strip_inline_code(line)
    end
  end
  return table.concat(lines, "\n")
end
```

### Step 2: Strip inline code in `parse_task_fields()` before pattern matching

**Before** (line 453-457):

```lua
local function parse_task_fields(text)
  local result = {}
  local extra = {}

  for key, value in text:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
```

**After:**

```lua
local function parse_task_fields(text)
  local result = {}
  local extra = {}

  -- Strip inline code spans so fields inside backticks are ignored
  local clean = strip_inline_code(text)

  for key, value in clean:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
```

And update the parenthesized form scan on the same cleaned text (line 490):

**Before:**

```lua
  -- Also check (key:: value) parenthesized form
  for key, value in text:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
```

**After:**

```lua
  -- Also check (key:: value) parenthesized form
  for key, value in clean:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
```

### Step 3: Strip inline code in `extract_inline_fields()` line iteration

**Before** (line 567-584):

```lua
local function extract_inline_fields(body)
  local fields = {}
  for line in body:gmatch("[^\n]+") do
    if line:match("^%s*[-*] %[.%] ") then goto continue end
    for key, value in line:gmatch("([%w_%-]+)::%s*(.-)%s*$") do
      if not key:match("^https?$") then
        fields[key] = vim.trim(value)
      end
    end
    for key, value in line:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
      fields[key] = vim.trim(value)
    end
    for key, value in line:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
      fields[key] = vim.trim(value)
    end
    ::continue::
  end
  return fields
end
```

**After:**

```lua
local function extract_inline_fields(body)
  local fields = {}
  for line in body:gmatch("[^\n]+") do
    if line:match("^%s*[-*] %[.%] ") then goto continue end
    -- Strip inline code spans so fields inside backticks are ignored
    local clean = strip_inline_code(line)
    for key, value in clean:gmatch("([%w_%-]+)::%s*(.-)%s*$") do
      if not key:match("^https?$") then
        fields[key] = vim.trim(value)
      end
    end
    for key, value in clean:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
      fields[key] = vim.trim(value)
    end
    for key, value in clean:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
      fields[key] = vim.trim(value)
    end
    ::continue::
  end
  return fields
end
```

### Step 4: Tag extraction in `extract_tasks()` also needs protection

The tag scan at line 537 also runs on raw `text`:

```lua
for tag in text:gmatch("#([%w_%-][%w_%-/]*)") do
```

This should use the cleaned text to avoid matching tags inside backticks:

**After:**

```lua
local clean_text = strip_inline_code(text)
for tag in clean_text:gmatch("#([%w_%-][%w_%-/]*)") do
```

Note: `parse_task_fields` is already being called with raw `text` and will clean internally (Step 2), so no double-stripping needed there.

## Test Cases

### 1. Basic inline code containing a fake field

```
- [ ] Check `[due:: 2026-01-01]` value
```

**Expected:** No `due` field extracted. The `[due:: 2026-01-01]` is inside backticks.

### 2. Real field outside backticks, fake inside

```
- [ ] Run `[due:: fake]` then [due:: 2026-03-02]
```

**Expected:** `due = "2026-03-02"` (only the real one outside backticks).

### 3. Double-backtick code span

```
- [ ] Use ``[priority:: 1]`` syntax for fields [priority:: 3]
```

**Expected:** `priority = 3` (the double-backtick span is stripped, only the real field remains).

### 4. Parenthesized field inside backticks

```
- [ ] Example `(repeat:: every day)` note
```

**Expected:** No `repeat_rule` extracted.

### 5. Backtick inside code span (double-backtick wrapping)

```
- [ ] Show `` ` `` char [due:: 2026-04-01]
```

**Expected:** `due = "2026-04-01"` (the double-backtick span contains a single backtick; the real field is outside).

### 6. Unmatched backtick (no closing)

```
- [ ] This has a `stray backtick and [due:: 2026-05-01]
```

**Expected:** `due = "2026-05-01"` (no matching close backtick, so the opening backtick is literal text, not a code span; the field is valid).

### 7. Fenced code block in body (already handled by `extract_tasks`)

```
    ```
    - [ ] Not a real task [due:: 2026-01-01]
    ```
```

**Expected:** No task extracted (fenced code blocks are already skipped by `extract_tasks` via `in_code_fence` at line 521-527).

### 8. Multiple code spans on same line

```
- [ ] Use `[due:: x]` and `(priority:: 9)` syntax [scheduled:: 2026-06-01]
```

**Expected:** `scheduled = "2026-06-01"` only. Both backtick-enclosed fields are stripped.

### 9. Inline field for non-task lines (extract_inline_fields)

```
See `[status:: draft]` for details
status:: published
```

**Expected:** `status = "published"` (the backtick-enclosed bracket field is stripped; the standalone field on the next line is valid).

### 10. Tag inside backtick on task line

```
- [ ] Check `#fake-tag` value #real-tag
```

**Expected:** `tags = { "real-tag" }` only.

## Edge Cases

| Case | Input | Behavior |
|------|-------|----------|
| Empty backticks | `` - [ ] Check `` `` value [due:: 2026-01-01] `` | Two empty backticks → stripped as code span containing nothing; `due` extracted normally |
| Adjacent code spans | `` - [ ] `[a:: 1]``[b:: 2]` real [c:: 3] `` | Both spans stripped; `c = "3"` only |
| Backtick in field value | `- [ ] [note:: has \` char]` | The backtick inside `[note:: ...]` starts a code span search; if no closer, treated as literal; field may partially parse depending on closer position -- this is an inherent Markdown ambiguity |
| Triple backtick inline | `` - [ ] Show ``` [due:: x] ``` code `` | Triple-backtick span stripped; no `due` extracted |
| Nested patterns | `` - [ ] `code [due:: 1]` [due:: 2026-03-02] `more [due:: 3]` `` | First and third spans stripped; `due = "2026-03-02"` |
| Performance | Lines with no backticks | `strip_inline_code` scans character-by-character but most task lines are short (<200 chars); negligible cost vs. the existing `gmatch` calls |

## Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/vault_index.lua` | Add `strip_inline_code()` helper (~30 lines); update `strip_code_blocks()` to use it; add `strip_inline_code()` call in `parse_task_fields()`, `extract_inline_fields()`, and tag extraction within `extract_tasks()` |

No other files need changes. The `inline_fields.lua` highlighting module already handles this correctly via treesitter-based `build_code_exclusion()`.
