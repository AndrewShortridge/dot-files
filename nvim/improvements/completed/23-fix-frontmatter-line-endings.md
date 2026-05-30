# 23 - Fix Frontmatter Parser for Bare `\r` Line Endings

**Severity:** Medium -- silent data loss (frontmatter silently treated as body text)
**Status:** Done
**File:** `lua/andrew/vault/vault_index.lua`

## Summary

`split_frontmatter()` fails to detect the opening `---` delimiter when a file
uses bare `\r` (classic Mac, pre-OS X) line endings. The function's regex
patterns assume every line ends with `\n` or `\r\n`, so a file delimited
solely by `\r` is treated as one giant line. The opening-fence check fails
immediately and the entire file is returned as body text with no frontmatter.
All metadata (aliases, tags, dates, inline fields in frontmatter) is lost for
that file in the vault index.

The same `\n`-only splitting assumption is present in **every** line-iteration
helper in the single-pass parser, meaning headings, block IDs, tasks, inline
fields, and links are also broken for bare-`\r` files.

## Root Cause Analysis

### Primary: `split_frontmatter()` (lines 236-251)

```lua
-- line 237
if not content:match("^%-%-%-\r?\n") then   -- FAILS on "---\r" (bare CR)
  return "", content
end
-- line 240
local _, fm_end = content:find("\n%-%-%-\r?\n", 4)   -- never finds \r---\r
-- line 242
  _, fm_end = content:find("\n%-%-%-\r?$", 4)         -- likewise
-- line 247
local fm_start = content:find("\n", 1) + 1            -- no \r awareness
-- line 248
local fm_text = content:sub(fm_start, fm_end):gsub("\n%-%-%-\r?\n?$", "")
```

The pattern `\r?\n` matches either `\n` (Unix) or `\r\n` (Windows) but never
bare `\r` (old Mac). On a bare-`\r` file the opening test on line 237 fails
and the function returns `("", content)` -- no frontmatter is parsed.

### Secondary: every `gmatch("[^\n]*")` / `vim.split(text, "\n")` call

| Line(s) | Function             | Pattern                                  |
|----------|----------------------|------------------------------------------|
| 222      | `strip_code_blocks`  | `text:gmatch("[^\n]*")`                  |
| 257      | `parse_frontmatter`  | `vim.split(text, "\n", { plain = true })` |
| 367      | `extract_headings`   | `content:gmatch("[^\n]*")`               |
| 392      | `extract_block_ids`  | `content:gmatch("[^\n]*")`               |
| 422      | `extract_links`      | `clean:gmatch("[^\n]+")`                 |
| 520      | `extract_tasks`      | `vim.split(body, "\n", { plain = true })` |
| 569      | `extract_inline_fields` | `body:gmatch("[^\n]+")`               |

All of these split exclusively on `\n`. If content is delimited by bare `\r`,
each function receives the entire file as a single "line", breaking heading
detection, block-ID extraction, task parsing, etc.

## The Fix

### Strategy: normalize line endings once, at read time

The cleanest and most robust approach is to normalize line endings to `\n`
immediately after reading the file, before any parsing. This is a single-line
change in `_parse_file()` and guarantees every downstream function sees
Unix-style endings. No regex surgery is needed in `split_frontmatter()` or
any other helper.

### Before (`_parse_file`, line 588-593)

```lua
function M.VaultIndex:_parse_file(abs_path, rel_path, stat)
  local f = io.open(abs_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if not content then return nil end
```

### After

```lua
function M.VaultIndex:_parse_file(abs_path, rel_path, stat)
  local f = io.open(abs_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if not content then return nil end

  -- Normalize line endings: \r\n -> \n, then bare \r -> \n
  -- Must replace \r\n first to avoid turning it into \n\n.
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
```

This two-step gsub is the standard idiom:
1. `\r\n` -> `\n` (Windows CRLF becomes Unix LF -- no change in line count).
2. `\r` -> `\n` (any remaining bare CRs become LFs).

The order matters: reversing it would turn `\r\n` into `\n\n`, doubling every
line.

### Why not patch `split_frontmatter()` patterns instead?

Changing every regex from `\r?\n` to `[\r\n]` would fix the delimiter
detection, but it would NOT fix the downstream `gmatch("[^\n]*")` calls in
`extract_headings`, `extract_block_ids`, `extract_links`, `extract_tasks`,
`extract_inline_fields`, or `strip_code_blocks`. Each of those would need
its own patch. Normalizing once at the source is simpler, complete, and
impossible to regress by adding new helpers that forget about `\r`.

### Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/vault_index.lua` | Add 2-line normalization after `f:read("*a")` in `_parse_file()` (around line 593) |

No other files need changes. All parsing functions are internal to this file
and are only called from `_parse_file()`.

## Test Cases

### 1. Bare `\r` line endings (old Mac)

```lua
-- Input (hex: 2D2D2D 0D 74 69 74 6C 65 3A ... 0D 2D2D2D 0D ...)
local content = "---\rtitle: Hello\rtags: [a, b]\r---\r# Heading\rSome text ^blk-abc\r"

-- After normalization:
-- "---\ntitle: Hello\ntags: [a, b]\n---\n# Heading\nSome text ^blk-abc\n"

-- Expected results:
-- fm_fields.title == "Hello"
-- fm_fields.tags == {"a", "b"}
-- headings[1].text == "Heading"
-- block_ids[1].id == "blk-abc"
```

### 2. Windows `\r\n` line endings

```lua
local content = "---\r\ntitle: Hello\r\ntags: [a, b]\r\n---\r\n# Heading\r\nSome text ^blk-abc\r\n"

-- After normalization:
-- "---\ntitle: Hello\ntags: [a, b]\n---\n# Heading\nSome text ^blk-abc\n"

-- Same expected results as above.
-- (Note: this already worked before the fix via \r?\n patterns, but
--  normalization keeps it working without relying on those patterns.)
```

### 3. Unix `\n` line endings (baseline, must not regress)

```lua
local content = "---\ntitle: Hello\ntags: [a, b]\n---\n# Heading\nSome text ^blk-abc\n"

-- No change after normalization. Existing behavior preserved.
```

### 4. No frontmatter

```lua
local content_cr   = "# Just a heading\rSome body text\r"
local content_crlf = "# Just a heading\r\nSome body text\r\n"
local content_lf   = "# Just a heading\nSome body text\n"

-- All three: fm_text == "", body == full content (normalized to \n)
-- Heading still extracted correctly from body.
```

### 5. Mixed line endings within the same file

```lua
-- Simulates a file corrupted by copy-paste from different OS sources.
local content = "---\r\ntitle: Mixed\rtags:\n  - alpha\r  - beta\r\n---\n# Heading\r"

-- After normalization:
-- "---\ntitle: Mixed\ntags:\n  - alpha\n  - beta\n---\n# Heading\n"

-- Expected:
-- fm_fields.title == "Mixed"
-- fm_fields.tags == {"alpha", "beta"}
-- headings[1].text == "Heading"
```

### 6. Frontmatter at EOF without trailing newline (bare `\r`)

```lua
-- File ends immediately after closing fence, no trailing newline.
local content = "---\rtitle: Minimal\r---"

-- After normalization: "---\ntitle: Minimal\n---"
-- split_frontmatter must handle closing --- at EOF (line 242 pattern).
-- Expected: fm_fields.title == "Minimal", body == ""
```

### 7. Inline fields and tasks with bare `\r`

```lua
local content = "---\r---\r- [x] Do thing [due:: 2026-03-01]\rtype:: note\r"

-- After normalization: "---\n---\n- [x] Do thing [due:: 2026-03-01]\ntype:: note\n"
-- Expected:
-- tasks[1].text contains "Do thing"
-- tasks[1].due == "2026-03-01"
-- inline_fields.type == "note"
```

## Edge Cases and Considerations

1. **Binary files / non-text content:** `io.open(path, "r")` with `*a` read
   on a binary file could contain arbitrary `\r` bytes. However, vault_index
   only processes `.md` files (filtered earlier in the scan loop), so this is
   not a practical concern.

2. **Performance:** Two gsub passes over the full file content add negligible
   cost. The patterns are single-byte literal replacements (no backtracking).
   For a typical 10KB markdown note this takes microseconds.

3. **Interaction with `io.open` text mode:** On Linux, `io.open(path, "r")`
   does NOT translate `\r\n` (that is a Windows C runtime behavior). So the
   explicit gsub normalization is necessary even in "text" mode on Linux.

4. **Preserving original content:** The normalized `content` is only used for
   index parsing (headings, links, block IDs, etc.). The file on disk is never
   modified. Neovim's own buffer handling (via `fileformat` / `fileformats`)
   is separate and unaffected.

5. **Future-proofing:** Any new extraction function added to the single-pass
   parser automatically benefits from normalization without needing to handle
   `\r` itself.
