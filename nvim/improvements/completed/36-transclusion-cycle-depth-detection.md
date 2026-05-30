# 36 — Transclusion Cycle & Depth Detection

## Problem

The embed system (`embed.lua`) renders `![[...]]` note transclusions as virtual text extmarks, but it has two critical safety gaps:

1. **No cycle detection.** If Note A embeds `![[Note B]]` and Note B embeds `![[Note A]]`, the system will loop indefinitely. Currently `render_embeds()` only processes top-level `![[...]]` patterns in the current buffer — it does not recurse into embedded content. However, the natural next step for the embed system is nested transclusion (rendering embeds within embeds), and without cycle detection that will immediately produce infinite loops.

2. **No depth limit.** Even without true cycles, deeply nested embed chains (A embeds B, B embeds C, C embeds D, ...) can produce unbounded virtual text. There is no configurable cap on how deep the embed resolution goes.

3. **No nested transclusion at all.** The current `render_embeds()` function only scans the buffer's own lines for `![[...]]` patterns. When embedded content itself contains `![[...]]` patterns, those inner embeds are rendered as literal text rather than being resolved. This means transclusion is limited to a single level.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **embed.lua** | Renders `![[...]]` as virtual text extmarks; handles image embeds via snacks.nvim placements | `lua/andrew/vault/embed.lua` (536 lines) |
| **config.lua** | `M.embed = { max_lines = 20 }` — only controls max lines for full-note embeds, no depth/cycle config | `lua/andrew/vault/config.lua` (line 66-68) |
| **link_utils.lua** | `read_heading_section()`, `read_block_content()` — reads content for heading/block embeds | `lua/andrew/vault/link_utils.lua` (lines 127-194) |
| **wikilinks.lua** | `resolve_link(name)` — resolves note names to absolute paths via vault index cache | `lua/andrew/vault/wikilinks.lua` |
| **get_embed_content()** | Local function in embed.lua (lines 105-128) — dispatches to link_utils readers based on embed type | `lua/andrew/vault/embed.lua` |
| **render_embeds()** | Main render function (lines 132-269) — scans buffer lines for `![[...]]`, resolves, renders virtual text. No recursion, no depth tracking, no visited set | `lua/andrew/vault/embed.lua` |

### Why the Current Design Cannot Handle Cycles or Depth

`render_embeds()` iterates over the current buffer's lines and renders each `![[...]]` pattern as virtual text. It calls `get_embed_content()` which reads the target note's content via `link_utils.read_heading_section()` or `link_utils.read_block_content()`, but the returned lines are inserted as virtual text verbatim — any `![[...]]` patterns within them are never parsed or resolved.

This means:
- Transclusion is flat (one level deep).
- There is no recursion, so cycles cannot manifest yet.
- There is no visited-set or depth counter anywhere in the call chain.

Once nested transclusion is added (resolving `![[...]]` within embedded content), the absence of cycle detection and depth limits will immediately create infinite loops for circular embed chains — a common pattern in knowledge bases where notes reference each other.

---

## Proposed Solution

### Architecture

Add depth-limited recursive transclusion with cycle detection to `render_embeds()`. The approach uses:

1. **A `depth` parameter** propagated through the embed resolution chain, incremented at each nesting level.
2. **A `visited` set** (table of absolute file paths) tracking the current embed chain to detect cycles.
3. **A new `resolve_embed_lines()` function** that recursively resolves `![[...]]` patterns within embedded content, producing the final virtual text lines.
4. **`config.embed.max_depth`** (default 5) controlling the maximum nesting depth.
5. **Visual indicators** for depth limits and cycles rendered as virtual text.

The recursion happens at the virtual-text-line level, not the extmark level. When `render_embeds()` encounters a note embed, it calls `resolve_embed_lines()` which reads the target note's content, then scans those content lines for further `![[...]]` patterns. Each nested embed is resolved and its lines are inlined, up to `max_depth`. Image embeds within nested content are skipped (they require buffer-level snacks placements which cannot work in virtual text).

```
render_embeds(bufnr)
  │
  for each ![[Target]] in buffer lines:
  │
  ├─ Image embed? → snacks placement (unchanged, no recursion)
  │
  └─ Note embed?
       │
       resolve_embed_lines(details, source, depth=1, visited={bufpath})
         │
         ├─ depth > max_depth? → return ["⋯ (max embed depth)"]
         │
         ├─ target_path in visited? → return ["↻ cycle: A → B → A"]
         │
         ├─ get_embed_content(details, source) → raw content lines
         │
         └─ for each ![[Inner]] in content lines:
              │
              ├─ Image? → render as literal text (no placement in virtual text)
              │
              └─ Note? → resolve_embed_lines(inner_details, inner_source,
                           depth+1, visited ∪ {target_path})
                   │
                   └─ returns resolved lines (inlined into parent)
```

### Implementation

#### 1. Config change: `config.lua`

**File:** `lua/andrew/vault/config.lua`

Replace the current `M.embed` block (lines 66-68):

```lua
-- BEFORE:
M.embed = {
  max_lines = 20,
}

-- AFTER:
M.embed = {
  max_lines = 20,
  max_depth = 5,  -- max nesting depth for recursive transclusion (0 = flat/no recursion)
}
```

#### 2. New function: `resolve_embed_lines()` in `embed.lua`

**File:** `lua/andrew/vault/embed.lua`

Add this function after `get_embed_content()` (after line 128) and before `render_embeds()` (line 132):

```lua
--- Build the cycle path string for display.
--- Example: "NoteA → NoteB → NoteA"
---@param visited_list string[] ordered list of visited file paths
---@param cycle_target string the path that closes the cycle
---@return string
local function format_cycle_path(visited_list, cycle_target)
  local names = {}
  for _, p in ipairs(visited_list) do
    names[#names + 1] = vim.fn.fnamemodify(p, ":t:r")
  end
  names[#names + 1] = vim.fn.fnamemodify(cycle_target, ":t:r")
  return table.concat(names, " \u{2192} ")
end

--- Recursively resolve embed content, handling nested ![[...]] patterns.
--- Returns an array of strings representing the fully-resolved content lines.
--- Image embeds within nested content are left as literal text (snacks placements
--- require buffer context and cannot be rendered inside virtual text).
---
---@param details {name: string, heading: string|nil, block_id: string|nil}
---@param source string|string[] resolved file path or buffer lines array
---@param depth number current nesting depth (1 = first level embed)
---@param visited_set table<string, boolean> set of absolute paths in current chain
---@param visited_list string[] ordered list of absolute paths for cycle display
---@param bufnr number the buffer being rendered (for same-file resolution)
---@return string[] resolved_lines
local function resolve_embed_lines(details, source, depth, visited_set, visited_list, bufnr)
  local max_depth = config.embed.max_depth or 5

  -- Depth limit check
  if depth > max_depth then
    return { "\u{22ef} (max embed depth reached)" }
  end

  -- Determine the absolute path of the target
  local target_path
  if type(source) == "table" then
    -- Same-file embed: source is buffer lines, target is the buffer itself
    target_path = vim.api.nvim_buf_get_name(bufnr)
  else
    target_path = source
  end

  -- Cycle detection
  if target_path and visited_set[target_path] then
    return { "\u{21bb} cycle: " .. format_cycle_path(visited_list, target_path) }
  end

  -- Get the raw content for this embed
  local content = get_embed_content(details, source)
  if #content == 0 then
    return content
  end

  -- If at max_depth, return content without further resolution
  if depth == max_depth then
    return content
  end

  -- Update visited tracking for recursion
  local new_visited_set = vim.tbl_extend("keep", {}, visited_set)
  local new_visited_list = { unpack(visited_list) }
  if target_path then
    new_visited_set[target_path] = true
    new_visited_list[#new_visited_list + 1] = target_path
  end

  -- Scan content lines for nested ![[...]] and resolve them inline
  local resolved = {}
  for _, cline in ipairs(content) do
    local has_embed = cline:find("!%[%[.-%]%]")
    if not has_embed then
      resolved[#resolved + 1] = cline
    else
      -- Process all embeds on this line
      local pos = 1
      local line_prefix = nil
      local line_has_non_embed_text = false

      -- Check if the line has text outside the embed pattern
      local test_line = cline:gsub("!%[%[.-%]%]", "")
      if vim.trim(test_line) ~= "" then
        line_has_non_embed_text = true
      end

      -- If the line has non-embed text, keep it as-is with embeds as literal text
      -- (cannot inline multi-line content into a line with other text)
      if line_has_non_embed_text then
        resolved[#resolved + 1] = cline
      else
        -- Line is purely embed(s) — resolve each one
        local start = 1
        while true do
          local s, e = cline:find("!%[%[.-%]%]", start)
          if not s then break end

          local inner_text = vim.trim(cline:sub(s + 3, e - 2))

          if is_image_embed(inner_text) then
            -- Image embeds in nested content: render as literal text
            -- (snacks placements need buffer context, unavailable in virt text)
            resolved[#resolved + 1] = cline:sub(s, e)
          else
            -- Nested note embed: resolve recursively
            local inner_details = link_utils.parse_target(inner_text)
            local inner_path = resolve_embed(inner_details.name, bufnr)

            if inner_path then
              local inner_source = inner_path
              -- If the nested embed points to the buffer itself, use disk content
              -- (we're already past the top-level buffer lines)
              local inner_lines = resolve_embed_lines(
                inner_details, inner_source,
                depth + 1, new_visited_set, new_visited_list, bufnr
              )
              for _, il in ipairs(inner_lines) do
                resolved[#resolved + 1] = il
              end
            else
              resolved[#resolved + 1] = "[Not found: " .. inner_text .. "]"
            end
          end

          start = e + 1
        end
      end
    end
  end

  return resolved
end
```

#### 3. Modify `render_embeds()` to use recursive resolution

**File:** `lua/andrew/vault/embed.lua`

Replace the note embed rendering block inside `render_embeds()`. The current code (lines 208-248) is:

```lua
      -- BEFORE (lines 208-248):
      else
        -- Note embed: render as virtual text
        local details = link_utils.parse_target(inner)

        local path = resolve_embed(details.name, bufnr)
        local virt_lines = {}

        if path then
          -- For same-file embeds, use buffer lines (reflects unsaved changes)
          local source = path
          if path == bufpath then
            source = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          end
          local content = get_embed_content(details, source)
          local header_text = string.rep("\u{2500}", 2)
            .. " ![[" .. inner .. "]] "
            .. string.rep("\u{2500}", 40)

          -- Header border
          virt_lines[#virt_lines + 1] = { { header_text, border_hl } }

          -- Content lines
          for _, cl in ipairs(content) do
            virt_lines[#virt_lines + 1] = { { "  " .. cl, content_hl } }
          end

          -- Footer border
          local footer_text = string.rep("\u{2500}", 50)
          virt_lines[#virt_lines + 1] = { { footer_text, border_hl } }
          stats.notes = stats.notes + 1
        else
          virt_lines[#virt_lines + 1] = {
            { string.rep("\u{2500}", 2) .. " ![[" .. inner .. "]] (not found) " .. string.rep("\u{2500}", 20), border_hl },
          }
          stats.errors = stats.errors + 1
        end

        vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
        })
      end
```

Replace with:

```lua
      -- AFTER:
      else
        -- Note embed: render as virtual text with recursive resolution
        local details = link_utils.parse_target(inner)

        local path = resolve_embed(details.name, bufnr)
        local virt_lines = {}

        if path then
          -- For same-file embeds, use buffer lines (reflects unsaved changes)
          local source = path
          if path == bufpath then
            source = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          end

          -- Initialize visited set with the current buffer to detect self-cycles
          local visited_set = { [bufpath] = true }
          local visited_list = { bufpath }

          -- Recursively resolve nested embeds within the content
          local content = resolve_embed_lines(
            details, source,
            1,              -- depth starts at 1 for first-level embeds
            visited_set,
            visited_list,
            bufnr
          )

          local header_text = string.rep("\u{2500}", 2)
            .. " ![[" .. inner .. "]] "
            .. string.rep("\u{2500}", 40)

          -- Header border
          virt_lines[#virt_lines + 1] = { { header_text, border_hl } }

          -- Content lines (detect cycle/depth indicators for highlight)
          local cycle_hl = "VaultEmbedCycle"
          local depth_hl = "VaultEmbedDepth"
          for _, cl in ipairs(content) do
            if cl:find("^\u{21bb} cycle:") then
              virt_lines[#virt_lines + 1] = { { "  " .. cl, cycle_hl } }
            elseif cl:find("^\u{22ef} %(max embed depth") then
              virt_lines[#virt_lines + 1] = { { "  " .. cl, depth_hl } }
            else
              virt_lines[#virt_lines + 1] = { { "  " .. cl, content_hl } }
            end
          end

          -- Footer border
          local footer_text = string.rep("\u{2500}", 50)
          virt_lines[#virt_lines + 1] = { { footer_text, border_hl } }
          stats.notes = stats.notes + 1
        else
          virt_lines[#virt_lines + 1] = {
            { string.rep("\u{2500}", 2) .. " ![[" .. inner .. "]] (not found) " .. string.rep("\u{2500}", 20), border_hl },
          }
          stats.errors = stats.errors + 1
        end

        vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
        })
      end
```

#### 4. Add highlight groups in `setup()`

**File:** `lua/andrew/vault/embed.lua`

Add two highlight groups after the existing ones in `setup()` (after line 460):

```lua
-- BEFORE (lines 459-460):
  vim.api.nvim_set_hl(0, "VaultEmbedContent", { italic = true, fg = "#8888aa", default = true })
  vim.api.nvim_set_hl(0, "VaultEmbedBorder", { fg = "#555577", default = true })

-- AFTER:
  vim.api.nvim_set_hl(0, "VaultEmbedContent", { italic = true, fg = "#8888aa", default = true })
  vim.api.nvim_set_hl(0, "VaultEmbedBorder", { fg = "#555577", default = true })
  vim.api.nvim_set_hl(0, "VaultEmbedCycle", { italic = true, fg = "#e06060", default = true })
  vim.api.nvim_set_hl(0, "VaultEmbedDepth", { italic = true, fg = "#c0a040", default = true })
```

#### 5. Update `debug_info()` to show cycle/depth config

**File:** `lua/andrew/vault/embed.lua`

Add after the existing debug lines in `debug_info()` (around line 366, after the `"  Embeds visible:"` line):

```lua
  info[#info + 1] = "  config.embed.max_depth: " .. tostring(config.embed.max_depth or 5)
  info[#info + 1] = "  config.embed.max_lines: " .. tostring(config.embed.max_lines)
```

---

## Configuration

**File:** `lua/andrew/vault/config.lua`

```lua
M.embed = {
  max_lines = 20,    -- max lines for full-note embeds (existing)
  max_depth = 5,     -- max nesting depth for recursive transclusion
                     -- 0 = no recursion (current behavior)
                     -- 1 = resolve first-level embeds only (no nested)
                     -- 5 = resolve up to 5 levels deep (default)
}
```

Setting `max_depth = 0` disables recursive transclusion entirely, preserving the current flat rendering behavior. This provides a safe fallback if recursive resolution causes performance issues in large vaults.

---

## File Changes

| File | Change |
|------|--------|
| `lua/andrew/vault/config.lua` | Add `max_depth = 5` to `M.embed` table |
| `lua/andrew/vault/embed.lua` | Add `format_cycle_path()` helper; add `resolve_embed_lines()` recursive resolver; modify `render_embeds()` to call `resolve_embed_lines()` with visited/depth tracking; add `VaultEmbedCycle` and `VaultEmbedDepth` highlight groups; update `debug_info()` to show depth config |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `config.lua` | `config.embed.max_depth` for depth limit | Yes (reads existing config table) |
| `link_utils.lua` | `parse_target()` for parsing nested embed patterns; `read_heading_section()` and `read_block_content()` via `get_embed_content()` | Yes (unchanged) |
| `wikilinks.lua` | `resolve_link()` via `resolve_embed()` for nested note resolution | Yes (unchanged) |
| `engine.lua` | `is_vault_path()`, `read_file_lines()` — used by existing code | Yes (unchanged) |

No new dependencies are introduced. The implementation uses only modules already required by `embed.lua`. The `resolve_embed_lines()` function calls existing local functions (`get_embed_content()`, `resolve_embed()`, `is_image_embed()`) and stdlib functions (`vim.tbl_extend`, `vim.fn.fnamemodify`, `vim.trim`).

---

## Testing Plan

### Manual Verification

#### 1. Basic nested transclusion

Create three notes:

```markdown
<!-- NoteA.md -->
# Note A
Content of A.
![[NoteB]]
```

```markdown
<!-- NoteB.md -->
# Note B
Content of B.
![[NoteC]]
```

```markdown
<!-- NoteC.md -->
# Note C
Leaf content of C.
```

Open `NoteA.md` and run `:VaultEmbedRender`.

**Expected:** The virtual text shows Note A's embed of Note B, and within that, Note B's embed of Note C is resolved and inlined. The final virtual text should contain content from all three notes with proper borders.

#### 2. Cycle detection

```markdown
<!-- CycleA.md -->
# Cycle A
Start of A.
![[CycleB]]
```

```markdown
<!-- CycleB.md -->
# Cycle B
Middle of B.
![[CycleA]]
```

Open `CycleA.md` and run `:VaultEmbedRender`.

**Expected:** The embed of CycleB is resolved and shows its content. Within CycleB's content, the `![[CycleA]]` embed is detected as a cycle and rendered as:
```
  ↻ cycle: CycleA → CycleB → CycleA
```
in the `VaultEmbedCycle` highlight (red/italic).

#### 3. Self-referencing cycle

```markdown
<!-- SelfRef.md -->
# Self Reference
![[SelfRef]]
```

Open `SelfRef.md` and run `:VaultEmbedRender`.

**Expected:** The embed detects that the buffer file is already in the visited set and renders:
```
  ↻ cycle: SelfRef → SelfRef
```

#### 4. Depth limit

Create a chain of 7 notes: `D1.md` embeds `D2.md`, `D2.md` embeds `D3.md`, ..., `D7.md` has no embeds.

With `config.embed.max_depth = 5`, open `D1.md`.

**Expected:** Embeds resolve through D1 -> D2 -> D3 -> D4 -> D5, and the embed of D6 within D5's content shows:
```
  ⋯ (max embed depth reached)
```
in the `VaultEmbedDepth` highlight (amber/italic).

#### 5. max_depth = 0 (flat mode)

Set `config.embed.max_depth = 0` and open a note with embeds.

**Expected:** Embeds render as flat content (the current behavior) with no recursion into nested `![[...]]` patterns. The nested patterns appear as literal text within the virtual text content.

#### 6. Image embeds in nested content

```markdown
<!-- WithImage.md -->
# With Image
Some text.
![[photo.png]]
More text.
```

```markdown
<!-- Outer.md -->
# Outer
![[WithImage]]
```

Open `Outer.md`.

**Expected:** WithImage's content is transcluded. The `![[photo.png]]` line within the transcluded content appears as literal text `![[photo.png]]` (not as an inline image — snacks placements cannot be created within virtual text lines).

#### 7. Heading and block embeds in nested content

```markdown
<!-- Source.md -->
# Source
![[Target#Important Section]]
```

```markdown
<!-- Target.md -->
# Target
Preamble.

## Important Section
Key information here.
![[Leaf]]
```

```markdown
<!-- Leaf.md -->
# Leaf
Leaf content.
```

Open `Source.md`.

**Expected:** The heading section of Target is transcluded. Within that section, the `![[Leaf]]` embed is recursively resolved, showing Leaf's content inline.

#### 8. Mixed embed line (text + embed)

```markdown
<!-- Mixed.md -->
# Mixed
See also: ![[OtherNote]] for details.
```

Open a note that embeds `Mixed.md`.

**Expected:** The line `See also: ![[OtherNote]] for details.` is rendered as literal text (not recursively resolved) because the line contains non-embed text. Recursive resolution only applies to lines that consist entirely of embed patterns.

### Performance Verification

Test with a 5-level embed chain:

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.embed").render_embeds(); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

**Targets:**
- Flat rendering (no nested embeds): unchanged from current performance.
- 3-level chain (typical): < 50ms additional overhead (3 file reads + pattern scanning).
- 5-level chain (max depth): < 100ms additional overhead.
- Cycle detection short-circuit: near-zero overhead (set lookup + immediate return).

The visited set uses Lua table membership testing which is O(1). The depth check is a single integer comparison. The dominant cost is file I/O from `get_embed_content()` which already exists in the current implementation.

### Debug verification

Run `:VaultEmbedDebug` and confirm the output includes:

```
  config.embed.max_depth: 5
  config.embed.max_lines: 20
```

### Automated Verification

```lua
-- Test: embed cycle/depth detection structure
do
  local source = io.open("lua/andrew/vault/embed.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- Core functions present
    assert_true(content:find("function resolve_embed_lines") ~= nil,
      "has resolve_embed_lines function")
    assert_true(content:find("function format_cycle_path") ~= nil,
      "has format_cycle_path helper")

    -- Cycle detection
    assert_true(content:find("visited_set") ~= nil, "uses visited set for cycle detection")
    assert_true(content:find("visited_list") ~= nil, "tracks visit order for cycle display")
    assert_true(content:find("\u{21bb} cycle:") ~= nil, "renders cycle indicator")

    -- Depth limiting
    assert_true(content:find("max_depth") ~= nil, "uses max_depth config")
    assert_true(content:find("\u{22ef}") ~= nil, "renders depth limit indicator")

    -- Highlight groups
    assert_true(content:find("VaultEmbedCycle") ~= nil, "defines cycle highlight group")
    assert_true(content:find("VaultEmbedDepth") ~= nil, "defines depth highlight group")

    -- Zero new requires
    local requires = {}
    for req in content:gmatch('require%("([^"]+)"%)') do
      requires[req] = true
    end
    assert_true(requires["andrew.vault.engine"] ~= nil, "requires engine (existing)")
    assert_true(requires["andrew.vault.wikilinks"] ~= nil, "requires wikilinks (existing)")
    assert_true(requires["andrew.vault.config"] ~= nil, "requires config (existing)")
    assert_true(requires["andrew.vault.link_utils"] ~= nil, "requires link_utils (existing)")
  end
end

-- Test: config has max_depth
do
  local source = io.open("lua/andrew/vault/config.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()
    assert_true(content:find("max_depth") ~= nil, "config.embed has max_depth setting")
  end
end
```
