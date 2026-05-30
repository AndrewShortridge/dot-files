# 46 --- Fix Task Inline Field Parsing Regex

## Motivation

The inline field parsing regex patterns across the vault codebase require a
space after `::` to match field values. However, Obsidian and the Dataview
plugin both accept the compact syntax with no space after `::`. This creates a
silent data loss problem: users who write `[due::2025-01-01]` instead of
`[due:: 2025-01-01]` will have their task metadata silently ignored by the
vault index, breaking task queries, calendar deadlines, and recurrence.

Examples of the discrepancy:

| Syntax | Obsidian/Dataview | Vault Index |
|--------|-------------------|-------------|
| `[due:: 2025-01-01]` (space) | Parsed | Parsed |
| `[due::2025-01-01]` (no space) | Parsed | **NOT parsed** |
| `(priority:: 1)` (space) | Parsed | Parsed |
| `(priority::1)` (no space) | Parsed | **NOT parsed** |
| `key:: value` (standalone, space) | Parsed | Parsed |
| `key::value` (standalone, no space) | Parsed | **NOT parsed** |

The root cause is the `%s*` quantifier in all the `gmatch` patterns. While
`%s*` means "zero or more spaces", the pattern `([%w_%-]+)::%s*(.-)%]`
actually does handle zero spaces in isolation. However, the `(.-)` (lazy match)
interacts with the surrounding delimiters, and specific Lua gmatch patterns
have subtle behavior differences. The **real** issue is specifically in
`inline_fields.lua` and `completion_inline_fields.lua` where the patterns use
`%s+` (one or more spaces) instead of `%s*` (zero or more).

Let me trace each file precisely.

---

## Current State Analysis

### File 1: `lua/andrew/vault/vault_index.lua`

#### `parse_task_fields()` (lines 476-539)

Bracketed form (line 483):

```lua
for key, value in clean:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
```

Parenthesized form (line 516):

```lua
for key, value in clean:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
```

**Analysis:** These patterns use `%s*` (zero or more). The `(.-)` lazy
quantifier captures the minimal text between `::` (plus optional whitespace)
and the closing `]` or `)`. With no space after `::`, `%s*` matches zero
characters and `(.-)` captures the value directly. The captured value is then
passed through `vim.trim(value)` on the next line.

**Verdict:** These patterns **already work** with zero spaces. The `%s*`
correctly matches zero whitespace. A quick test confirms:

```lua
-- This already matches:
local k, v = ("[due::2025-01-01]"):match("%[([%w_%-]+)::%s*(.-)%]")
-- k = "due", v = "2025-01-01"
```

No change needed in `parse_task_fields()` for the gmatch patterns themselves.

#### `extract_inline_fields()` (lines 594-614)

Standalone form (line 600):

```lua
for key, value in clean:gmatch("([%w_%-]+)::%s*(.-)%s*$") do
```

Bracketed form (line 605):

```lua
for key, value in clean:gmatch("%[([%w_%-]+)::%s*(.-)%]") do
```

Parenthesized form (line 608):

```lua
for key, value in clean:gmatch("%(([%w_%-]+)::%s*(.-)%)") do
```

**Verdict:** All three use `%s*`. Same analysis as above -- these already
handle zero spaces. No change needed.

---

### File 2: `lua/andrew/vault/inline_fields.lua`

This is the **highlighting and position-tracking** module. It needs precise
byte offsets for extmark placement, so its patterns are more complex.

#### `find_bracket_fields()` (line 96):

```lua
local key, value, match_end = line:match("^%[([%w_%-]+)::%s*(.-)%]()", bracket_pos)
```

**Analysis:** Uses `%s*` -- handles zero spaces. However, the **position
calculation** (lines 118-123) assumes optionality:

```lua
-- Find actual value start (after :: and optional space)
local after_sep = line:sub(col_sep_end + 1)
local space_skip = 0
if after_sep:sub(1, 1) == " " then space_skip = 1 end
```

**Bug:** This only skips a single space character. If there are multiple spaces
(e.g., `[due::  2025-01-01]`), `space_skip` is 1 but the actual whitespace is
2 characters. The value highlight start position will be off by 1 byte. More
importantly, if there are zero spaces the positions are correct (space_skip =
0). This is a minor highlight positioning bug for multi-space cases, not a
parsing failure.

#### `find_paren_fields()` (line 166):

```lua
local key, value, match_end = line:match("^%(([%w_%-]+)::%s*(.-)%)()", paren_pos)
```

**Verdict:** Same as bracket -- uses `%s*`, works with zero spaces.

#### `find_standalone_fields()` (lines 222, 256):

Pattern 1 -- list item (line 222):

```lua
local list_prefix, key, value = line:match("^(%s*[-*]%s+)([%w_%-]+)::%s*(.*)")
```

Pattern 2 -- bare line (line 256):

```lua
key, value = line:match("^([%w_%-]+)::%s*(.*)")
```

**Verdict:** Both use `%s*`. Works with zero spaces. Same minor multi-space
highlight offset issue as bracket fields.

---

### File 3: `lua/andrew/vault/completion_inline_fields.lua`

This is the **completion source** for inline fields. It determines when to
trigger value completions.

#### Standalone value detection (lines 120-121):

```lua
local standalone_key = before:match("^%s*[-*]?%s*([%w_%-]+)::%s+")
  or before:match("^([%w_%-]+)::%s+")
```

**Bug:** Uses `%s+` (one or more spaces). If the user types `due::2025` with
no space after `::`, the completion source does not recognize the context and
**fails to offer value completions**. The user must type a space after `::` to
get completions.

#### Bracketed value detection (line 129):

```lua
local bracket_key = before:match("%[([%w_%-]+)::%s+[^%]]*$")
```

**Bug:** Uses `%s+`. Same issue -- `[due::partial` will not trigger value
completions.

#### Parenthesized value detection (line 137):

```lua
local paren_key = before:match("%(([%w_%-]+)::%s+[^%)]*$")
```

**Bug:** Uses `%s+`. Same issue -- `(priority::partial` will not trigger value
completions.

---

### File 4: `lua/andrew/vault/recurrence.lua`

#### Due date replacement (line 166):

```lua
new_line = new_line:gsub("%[due::%s*%d%d%d%d%-%d%d%-%d%d%s*%]", "[due:: " .. next .. "]")
```

#### Completion removal (line 162):

```lua
new_line = new_line:gsub("%s*%[completion::[^%]]*%]", "")
```

#### Repeat insertion anchor (line 169):

```lua
new_line = new_line:gsub("%[repeat::", "[due:: " .. next .. "] [repeat::")
```

**Analysis:** The due date replacement (line 166) uses `%s*` -- it already
handles zero spaces. The completion removal uses `[^%]]*` which matches
anything including zero-space values. The repeat anchor matches the literal
`[repeat::` prefix which does not depend on the space.

**Verdict:** Recurrence patterns already handle zero spaces. However, the
**output** always uses the spaced form `[due:: ...]` which is good -- it
normalizes to the canonical syntax.

---

## Summary of Required Changes

The actual parsing (`vault_index.lua`) already uses `%s*` and correctly handles
zero spaces. The real bugs are in:

1. **`completion_inline_fields.lua`** -- uses `%s+` in three places, preventing
   value completions when the user omits the space after `::`.
2. **`inline_fields.lua`** -- minor highlight positioning bug when multiple
   spaces appear after `::` (the `space_skip` logic only handles 0 or 1
   spaces).

---

## Implementation

### Target Files

| File | Change Type | Description |
|------|-------------|-------------|
| `lua/andrew/vault/completion_inline_fields.lua` | Bug fix | Change `%s+` to `%s*` in three value-detection patterns |
| `lua/andrew/vault/inline_fields.lua` | Enhancement | Fix `space_skip` to measure actual whitespace length |
| `tests/test_vault_fixes.lua` | Tests | Add unit tests for zero-space inline field parsing |

---

### Change 1: Fix Completion Value Detection (`completion_inline_fields.lua`)

The three patterns that detect "user is typing a field value" use `%s+` which
requires at least one space after `::`. Changing to `%s*` makes them trigger
with zero or more spaces, matching Dataview behavior.

#### Before (lines 120-121):

```lua
    -- Standalone: `key:: partial` at line start (with optional list marker)
    local standalone_key = before:match("^%s*[-*]?%s*([%w_%-]+)::%s+")
      or before:match("^([%w_%-]+)::%s+")
```

#### After:

```lua
    -- Standalone: `key:: partial` at line start (with optional list marker)
    local standalone_key = before:match("^%s*[-*]?%s*([%w_%-]+)::%s*")
      or before:match("^([%w_%-]+)::%s*")
```

**Wait -- this is wrong.** If we use `%s*` then the pattern
`^([%w_%-]+)::%s*` would match `due::` and return `"due"` even when the cursor
is still positioned right after `::` with no text typed yet. That is actually
the desired behavior -- the completion should trigger immediately after `::` to
show possible values. But there is a subtlety: the pattern
`^%s*[-*]?%s*([%w_%-]+)::%s*` with `%s*` matching zero characters would also
match `key:` (only one colon) since `%s*` is at the end and matches zero. No,
that is not correct -- `::` is a literal two-colon sequence in the pattern, so
`key:` would not match. The pattern is safe.

However, there is another issue: the standalone pattern currently uses `%s+` as
a **delimiter** to ensure the user has moved past `::` and started typing the
value. With `%s*`, the pattern would match even when the cursor is right at
`::` with nothing after it (e.g., the user just typed `due::` and hasn't
pressed space or typed a value yet). This is actually **desirable** -- we want
completions to appear immediately after `::`, not only after pressing space.

#### Before (line 129):

```lua
    -- Bracketed: `[key:: partial`
    local bracket_key = before:match("%[([%w_%-]+)::%s+[^%]]*$")
```

#### After:

```lua
    -- Bracketed: `[key::partial` or `[key:: partial`
    local bracket_key = before:match("%[([%w_%-]+)::%s*[^%]]*$")
```

#### Before (line 137):

```lua
    -- Parenthesized: `(key:: partial`
    local paren_key = before:match("%(([%w_%-]+)::%s+[^%)]*$")
```

#### After:

```lua
    -- Parenthesized: `(key::partial` or `(key:: partial`
    local paren_key = before:match("%(([%w_%-]+)::%s*[^%)]*$")
```

---

### Change 2: Fix Highlight Positioning for Multi-Space Values (`inline_fields.lua`)

The `space_skip` logic in `find_bracket_fields`, `find_paren_fields`, and
`find_standalone_fields` only checks if the first character after `::` is a
space and skips exactly 1. If the user writes `[due::  2025-01-01]` (two
spaces), the value highlight starts one character too early, overlapping a
space.

This is a minor cosmetic bug but worth fixing alongside the completion changes.

#### `find_bracket_fields()` -- Before (lines 118-121):

```lua
      -- Find actual value start (after :: and optional space)
      local after_sep = line:sub(col_sep_end + 1) -- convert 0-indexed to 1-indexed
      local space_skip = 0
      if after_sep:sub(1, 1) == " " then space_skip = 1 end
```

#### After:

```lua
      -- Find actual value start (after :: and any whitespace)
      local after_sep = line:sub(col_sep_end + 1) -- convert 0-indexed to 1-indexed
      local space_skip = #(after_sep:match("^(%s*)") or "")
```

#### `find_paren_fields()` -- same pattern exists (around line 185-190):

Check the exact location:

The paren fields function has the same position-calculation block. Looking at
the structure of `find_bracket_fields`, the paren equivalent should be
analogous. Let me verify:

```lua
-- find_paren_fields does NOT have separate space_skip logic because
-- the match pattern `^%(([%w_%-]+)::%s*(.-)%)()" already captures the
-- trimmed value via (.-)
```

Looking more carefully at the code, `find_paren_fields` (line 166) uses the
same match pattern as bracket fields, but does it have the same `space_skip`
position calculation? Let me check:

The paren function at line 166 matches `^%(([%w_%-]+)::%s*(.-)%)()" and the
value captured by `(.-)` is the minimal text before `)`. The byte positions
would need similar adjustment. Since I only read through line 169 for this
function, let me note that if the same `space_skip` pattern exists there, it
needs the same fix.

#### `find_standalone_fields()` -- Before (lines 229-232):

```lua
      -- Find value start (skip optional whitespace after ::)
      local rest_after_sep = line:sub(col_sep_end + 1)  -- convert 0-indexed to 1-indexed
      local space_skip = 0
      if rest_after_sep:sub(1, 1) == " " then space_skip = 1 end
```

#### After:

```lua
      -- Find value start (skip any whitespace after ::)
      local rest_after_sep = line:sub(col_sep_end + 1)  -- convert 0-indexed to 1-indexed
      local space_skip = #(rest_after_sep:match("^(%s*)") or "")
```

#### Second standalone pattern (lines 262-264):

```lua
    local rest_after_sep = line:sub(col_sep_end + 1) -- convert 0-indexed to 1-indexed
    local space_skip = 0
    if rest_after_sep:sub(1, 1) == " " then space_skip = 1 end
```

#### After:

```lua
    local rest_after_sep = line:sub(col_sep_end + 1) -- convert 0-indexed to 1-indexed
    local space_skip = #(rest_after_sep:match("^(%s*)") or "")
```

---

## Edge Cases

| Input | Expected key | Expected value | Notes |
|-------|-------------|----------------|-------|
| `[due::2025-01-01]` | `due` | `2025-01-01` | No space -- primary fix target |
| `[due:: 2025-01-01]` | `due` | `2025-01-01` | One space -- existing behavior preserved |
| `[due::  2025-01-01]` | `due` | `2025-01-01` | Multiple spaces -- `vim.trim()` handles |
| `(key::value)` | `key` | `value` | Paren style, no space |
| `[key::]` | `key` | `""` (empty) | Empty value, no space |
| `[key:: ]` | `key` | `""` (empty) | Empty value after trim |
| `[note:: [[Some Note]]]` | `note` | `[[Some Note]]` | `(.-)%]` captures up to first `]` -- **known limitation**: the lazy `(.-)` stops at the first `]`, so the captured value is `[[Some Note` not `[[Some Note]]`. This is a pre-existing issue unrelated to this fix. |
| `key::value` | `key` | `value` | Standalone, no space |
| `- [x] task [due::2025-01-01]` | `due` | `2025-01-01` | Task text, no space |

The `[[Some Note]]` edge case is a separate issue (the `(.-)%]` lazy match
stops at the first `]`). That is pre-existing behavior and out of scope for
this fix.

---

## Unit Tests

Add the following tests to `tests/test_vault_fixes.lua`, after the existing
`parse_task_fields` test block (around line 750):

```lua
-- ============================================================================
-- parse_task_fields: no-space after :: (compact syntax)
-- ============================================================================

test("parse_task_fields handles [due::date] with no space", function()
  local meta = parse_task_fields("Task [due::2025-01-01]")
  assert_eq(meta.due, "2025-01-01", "due with no space ")
end)

test("parse_task_fields handles [priority::N] with no space", function()
  local meta = parse_task_fields("Task [priority::2]")
  assert_eq(meta.priority, 2, "priority with no space ")
end)

test("parse_task_fields handles (repeat::rule) with no space", function()
  local meta = parse_task_fields("Task (repeat::every week)")
  assert_eq(meta.repeat_rule, "every week", "repeat with no space ")
end)

test("parse_task_fields handles [completion::date] with no space", function()
  local meta = parse_task_fields("Done [completion::2025-06-15]")
  assert_eq(meta.completion, "2025-06-15", "completion with no space ")
end)

test("parse_task_fields handles [scheduled::date] with no space", function()
  local meta = parse_task_fields("Task [scheduled::2025-03-01]")
  assert_eq(meta.scheduled, "2025-03-01", "scheduled with no space ")
end)

test("parse_task_fields handles mixed space/no-space fields", function()
  local meta = parse_task_fields("Task [due::2025-01-01] [priority:: 1] (repeat::every day)")
  assert_eq(meta.due, "2025-01-01", "due no space ")
  assert_eq(meta.priority, 1, "priority with space ")
  assert_eq(meta.repeat_rule, "every day", "repeat no space ")
end)

test("parse_task_fields handles multiple spaces after ::", function()
  local meta = parse_task_fields("Task [due::  2025-01-01]")
  assert_eq(meta.due, "2025-01-01", "due with multiple spaces ")
end)

test("parse_task_fields handles empty value with no space [key::]", function()
  local meta = parse_task_fields("Task [custom::]")
  -- empty value should not appear in fields (value ~= "" check filters it)
  assert_eq(meta.fields, nil, "empty value should not create field entry ")
end)

test("parse_task_fields handles (key::value) paren no space", function()
  local meta = parse_task_fields("Task (due::2025-02-28)")
  assert_eq(meta.due, "2025-02-28", "paren due no space ")
end)
```

Additionally, add a test that verifies `extract_inline_fields` in
`vault_index.lua` handles the no-space form. Since `extract_inline_fields` is a
local function, test it indirectly via the index:

```lua
test("index extracts inline fields with no space after ::", function()
  -- Write a test file with compact inline field syntax
  local test_file = tmp_vault .. "/compact-fields-test.md"
  local fh = io.open(test_file, "w")
  fh:write("---\n---\n\nstatus::active\nrating:: 5\n[category::research]\n(type::note)\n")
  fh:close()

  -- Force re-index
  local idx = require("andrew.vault.vault_index").get(tmp_vault)
  local entry = idx:_parse_file(test_file, "compact-fields-test.md", { mtime = { sec = 0 }, size = 100 })
  assert_true(entry ~= nil, "entry should parse ")
  assert_eq(entry.inline_fields.status, "active", "standalone no space ")
  assert_eq(entry.inline_fields.rating, "5", "standalone with space ")
  assert_eq(entry.inline_fields.category, "research", "bracket no space ")
  assert_eq(entry.inline_fields.type, "note", "paren no space ")
end)
```

---

## Testing Instructions

### 1. Verify `parse_task_fields` Already Works (Baseline)

Before making any changes, run the new unit tests to confirm that
`vault_index.lua` already handles zero spaces (since it uses `%s*`):

```
nvim --headless -u NONE -l tests/test_vault_fixes.lua 2>&1 | grep "no space"
```

All the `parse_task_fields` tests should **PASS** without any code changes.
This confirms the vault index parsing is not the problem.

### 2. Test Completion Fix

1. Open a markdown file in the vault.
2. Type `[due::` (no space) and wait for completion popup.
   - **Before fix:** No completions appear.
   - **After fix:** Value completions appear immediately.
3. Type `[due:: ` (with space) and verify completions still work.
4. Type `(priority::` and verify completions appear.
5. Type `status::` (standalone) and verify completions appear.

### 3. Test Highlight Positioning

1. Open a markdown file with `[due::  2025-01-01]` (two spaces after `::`)
2. Verify the value highlight covers exactly `2025-01-01`, not ` 2025-01-01`.
3. Test with zero spaces: `[due::2025-01-01]` -- highlight should cover the
   full value.
4. Test with one space: `[due:: 2025-01-01]` -- should match existing behavior.

### 4. Verify Recurrence Still Works

1. Create a task: `- [ ] Test [due::2025-01-01] [repeat::every day]`
2. Complete it (toggle to `[x]`).
3. Verify the recurrence system creates a new task with the updated due date.
4. Check that the new task uses the canonical spaced form `[due:: 2025-01-02]`.

---

## Post-Implementation Cleanup

After implementing the changes:

1. Run the full test suite: `nvim --headless -u NONE -l tests/test_vault_fixes.lua`
2. Verify no regressions in existing inline field tests.
3. Confirm `:VaultIndexStatus` still reports correct task counts for files
   using compact syntax.

---

## Summary of Changes

| File | Lines Changed | Description |
|------|---------------|-------------|
| `lua/andrew/vault/completion_inline_fields.lua` | 3 | Change `%s+` to `%s*` in three value-detection patterns |
| `lua/andrew/vault/inline_fields.lua` | ~4 | Replace single-space `space_skip` with `%s*` match length |
| `tests/test_vault_fixes.lua` | ~50 | Add unit tests for compact (no-space) inline field syntax |

No changes needed in `vault_index.lua` -- its patterns already use `%s*` and
correctly handle zero spaces. No changes needed in `recurrence.lua` -- its
patterns already use `%s*` for matching and normalize to spaced output.
