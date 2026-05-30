# Add Total Line Limit to Embeds

## Problem

The embed system has `max_depth=5` for recursion and `max_lines=20` per individual
full-note embed, but no cap on the **total** number of virtual text lines generated
across all embeds in a buffer. A buffer with multiple embed links, or a chain of
deeply nested embeds, can generate an unbounded number of virtual text lines:

- 5 nested notes x 20+ lines each = 100+ virtual text lines from a single `![[...]]`
- A buffer with 10 embed links, each resolving nested content = hundreds of virt lines
- Heading-section and block-id embeds have **no per-embed line cap at all** (they
  return the full section regardless of length)
- Performance degradation: each virt line is an extmark entry; large counts slow
  rendering, scrolling, and redraw
- Visual noise: the actual buffer content gets buried under walls of embed text

## Current State

### Config (`config.lua` lines 66-69)

```lua
M.embed = {
  max_lines = 20,   -- per full-note embed (heading/block embeds are unlimited)
  max_depth = 5,    -- max nesting depth for recursive transclusion
}
```

- `max_lines` only applies to **full-note embeds** (no heading, no block_id). It is
  passed to `engine.read_file_lines(path, max_lines)` and used to slice buffer lines
  in `get_embed_content()`.
- `max_depth` caps recursion depth. When exceeded, a single indicator line
  `"⋯ (max embed depth reached)"` is returned.
- There is **no `max_total_lines`** option.

### Rendering Pipeline (`embed.lua`)

The rendering flow for note embeds:

1. **`render_embeds(opts)`** (line 251) — top-level entry point. Iterates every line
   in the buffer, finds `![[...]]` patterns, and dispatches to image or note handling.

2. For each note embed (line 328-388):
   - `link_utils.parse_target(inner)` parses the link into `{name, heading, block_id}`
   - `resolve_embed(name, bufnr)` resolves the note name to an absolute path
   - `resolve_embed_lines(details, source, depth=1, visited_set, visited_list, bufnr)`
     is called to recursively resolve content

3. **`resolve_embed_lines()`** (line 156) — recursive resolver:
   - Checks depth against `max_depth` (returns indicator if exceeded)
   - Checks `visited_set` for cycles (returns cycle indicator if detected)
   - Calls `get_embed_content(details, source)` to get raw lines
   - Scans returned lines for nested `![[...]]` patterns
   - For each nested note embed, recurses with `depth + 1`
   - Returns a flat array of all resolved lines

4. **`get_embed_content()`** (line 105) — reads raw content:
   - Block embeds (`^blockid`): returns full paragraph via `link_utils.read_block_content()` — **no line limit**
   - Heading embeds (`#Heading`): returns full section via `link_utils.read_heading_section()` — **no line limit**
   - Full-note embeds: returns first `config.embed.max_lines` lines

5. Back in `render_embeds()` (line 354-388), the resolved lines are wrapped:
   - Header border line: `── ![[inner]] ──────...`
   - Each content line prefixed with `"  "` and assigned a highlight group
   - Footer border line: `──────────...`
   - The whole `virt_lines` array is attached as a single extmark

### Key Observations

- The line count is **unbounded** across the full buffer. Each top-level `![[...]]`
  independently resolves its entire tree with no shared budget.
- Heading sections can be arbitrarily long (an `## H2` section could span hundreds
  of lines if no subsequent H2 follows).
- The recursive resolver builds the full resolved line array in memory before any
  truncation could happen — there is no early exit.
- Virtual text lines include 2 border lines (header + footer) per embed, which also
  count toward visual weight.

## Solution

Add a `config.embed.max_total_lines` option that caps the total number of virtual
text content lines rendered across **all** embeds in a single buffer. The limit is
enforced at two levels:

1. **Per-embed cap within `resolve_embed_lines()`**: thread a running line counter
   through the recursion so nested embeds can be cut short when the budget is
   exhausted.
2. **Buffer-level cap in `render_embeds()`**: track total lines emitted across all
   top-level embeds. Once exhausted, remaining embeds render a truncation indicator
   instead of resolving content.

### Design Decisions

- **Default value**: `max_total_lines = 150`. This allows ~7 full embeds (20 lines
  each + 2 border lines) or a few deeply nested chains. Large enough for typical use,
  small enough to prevent runaway rendering.
- **Border lines count toward the total**: header and footer lines consume budget
  because they contribute to visual weight and extmark count.
- **Per-embed `max_lines` still applies**: the per-embed limit and total limit are
  independent constraints. A single embed is capped at `max_lines` (for full-note)
  AND the remaining total budget, whichever is smaller.
- **Heading/block embeds also get capped**: currently unlimited, they will now be
  subject to the remaining total budget.
- **Truncation indicator**: when the total limit causes truncation, a distinctive
  virtual text line is shown so the user understands why content is missing.
- **`max_total_lines = 0` disables the limit**: for users who want unlimited output.

## Implementation Steps

### Step 1: Add Config Option

**File**: `lua/andrew/vault/config.lua`

Add `max_total_lines` to the embed config table:

```lua
M.embed = {
  max_lines = 20,
  max_depth = 5,
  max_total_lines = 150,  -- 0 = unlimited
}
```

### Step 2: Add Per-Embed Line Budget to `get_embed_content()`

**File**: `lua/andrew/vault/embed.lua`, function `get_embed_content()` (line 105)

Currently heading and block embeds return unlimited lines. Add an optional
`line_budget` parameter that caps the returned lines regardless of embed type.

```lua
--- Get the content lines for an embed.
---@param details {name: string, heading: string|nil, block_id: string|nil}
---@param source string|string[] resolved file path or buffer lines array
---@param line_budget number|nil max lines to return (nil = use config defaults)
---@return string[]
---@return boolean truncated  true if content was cut short
local function get_embed_content(details, source, line_budget)
  local lines
  local truncated = false

  if details.block_id then
    lines = link_utils.read_block_content(source, details.block_id)
    if #lines == 0 then return { "[Block not found: ^" .. details.block_id .. "]" }, false end
  elseif details.heading then
    lines = link_utils.read_heading_section(source, details.heading)
    if #lines == 0 then return { "[Heading not found: #" .. details.heading .. "]" }, false end
  else
    -- Full note embed: use the smaller of max_lines and line_budget
    local limit = config.embed.max_lines
    if line_budget and line_budget < limit then
      limit = line_budget
    end
    if type(source) == "table" then
      lines = {}
      for i = 1, math.min(#source, limit) do
        lines[i] = source[i]
      end
      truncated = #source > limit
    else
      lines = engine.read_file_lines(source, limit)
      -- Cannot know exact truncation without reading the full file, but
      -- if we got exactly `limit` lines, assume truncated
      truncated = #lines >= limit
    end
    if #lines == 0 then return { "[Could not read file]" }, false end
    return lines, truncated
  end

  -- Apply line_budget cap to heading/block embeds
  if line_budget and #lines > line_budget then
    local capped = {}
    for i = 1, line_budget do
      capped[i] = lines[i]
    end
    return capped, true
  end

  return lines, truncated
end
```

### Step 3: Thread Line Counter Through `resolve_embed_lines()`

**File**: `lua/andrew/vault/embed.lua`, function `resolve_embed_lines()` (line 156)

Add a `budget` parameter that represents the remaining line budget. The function
consumes from this budget as it adds lines, and passes the remaining budget into
recursive calls. Returns both the resolved lines and the number of lines consumed.

```lua
--- Recursively resolve embed content, handling nested ![[...]] patterns.
--- Returns an array of resolved content lines and the number of budget lines consumed.
---
---@param details {name: string, heading: string|nil, block_id: string|nil}
---@param source string|string[]
---@param depth number current nesting depth
---@param visited_set table<string, boolean>
---@param visited_list string[]
---@param bufnr number
---@param budget number|nil remaining line budget (nil = unlimited)
---@return string[] resolved_lines
---@return number lines_consumed
local function resolve_embed_lines(details, source, depth, visited_set, visited_list, bufnr, budget)
  local max_depth = config.embed.max_depth or 5

  -- Depth limit check
  if depth > max_depth then
    return { "⋯ (max embed depth reached)" }, 1
  end

  -- Budget exhausted check
  if budget and budget <= 0 then
    return { "⋯ (total line limit reached)" }, 1
  end

  -- Determine the absolute path of the target
  local target_path
  if type(source) == "table" then
    target_path = vim.api.nvim_buf_get_name(bufnr)
  else
    target_path = source
  end

  -- Cycle detection
  if target_path and visited_set[target_path] then
    return { "↻ cycle: " .. format_cycle_path(visited_list, target_path) }, 1
  end

  -- Get the raw content for this embed (pass budget so it can cap early)
  local content, content_truncated = get_embed_content(details, source, budget)
  if #content == 0 then
    return content, 0
  end

  -- If at max_depth, return content without further resolution
  if depth == max_depth then
    local used = #content
    if content_truncated then
      content[#content + 1] = "⋯ (truncated)"
      used = used + 1
    end
    return content, used
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
  local remaining = budget  -- nil means unlimited

  for _, cline in ipairs(content) do
    -- Check if budget is exhausted mid-content
    if remaining and remaining <= 0 then
      resolved[#resolved + 1] = "⋯ (total line limit reached)"
      break
    end

    local has_embed = cline:find("!%[%[.-%]%]")
    if not has_embed then
      resolved[#resolved + 1] = cline
      if remaining then remaining = remaining - 1 end
    else
      local test_line = cline:gsub("!%[%[.-%]%]", "")
      if vim.trim(test_line) ~= "" then
        -- Line has non-embed text: keep as-is
        resolved[#resolved + 1] = cline
        if remaining then remaining = remaining - 1 end
      else
        -- Line is purely embed(s) — resolve each one
        local start = 1
        while true do
          -- Re-check budget before each nested embed
          if remaining and remaining <= 0 then
            resolved[#resolved + 1] = "⋯ (total line limit reached)"
            break
          end

          local s, e = cline:find("!%[%[.-%]%]", start)
          if not s then break end

          local inner_text = vim.trim(cline:sub(s + 3, e - 2))

          if is_image_embed(inner_text) then
            resolved[#resolved + 1] = cline:sub(s, e)
            if remaining then remaining = remaining - 1 end
          else
            local inner_details = link_utils.parse_target(inner_text)
            local inner_path = resolve_embed(inner_details.name, bufnr)

            if inner_path then
              local inner_source = inner_path
              local inner_lines, inner_used = resolve_embed_lines(
                inner_details, inner_source,
                depth + 1, new_visited_set, new_visited_list, bufnr,
                remaining
              )
              for _, il in ipairs(inner_lines) do
                resolved[#resolved + 1] = il
              end
              if remaining then remaining = remaining - inner_used end
            else
              resolved[#resolved + 1] = "[Not found: " .. inner_text .. "]"
              if remaining then remaining = remaining - 1 end
            end
          end

          start = e + 1
        end
      end
    end
  end

  -- If the raw content was truncated and we still have budget, add indicator
  if content_truncated and (not remaining or remaining > 0) then
    resolved[#resolved + 1] = "⋯ (truncated)"
  end

  local total_used = budget and (budget - (remaining or 0)) or #resolved
  return resolved, total_used
end
```

### Step 4: Enforce Buffer-Level Total in `render_embeds()`

**File**: `lua/andrew/vault/embed.lua`, function `render_embeds()` (line 251)

Track a running total across all top-level embeds. When the budget is exhausted,
skip resolving further embeds and show a truncation indicator instead.

Changes to `render_embeds()`:

```lua
function M.render_embeds(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local bufpath = vim.api.nvim_buf_get_name(bufnr)

  if not engine.is_vault_path(bufpath) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  clear_image_placements(bufnr)

  local PlacementMod, snacks_doc_cfg = init_snacks_image()
  local merge = (Snacks and Snacks.config and Snacks.config.merge) or function(...)
    return vim.tbl_deep_extend("force", ...)
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local border_hl = "VaultEmbedBorder"
  local content_hl = "VaultEmbedContent"

  local stats = { images = 0, notes = 0, errors = 0 }

  -- Total line budget across all embeds in this buffer
  local max_total = config.embed.max_total_lines or 150
  local total_remaining = max_total > 0 and max_total or nil  -- nil = unlimited

  for i, line in ipairs(lines) do
    local start = 1
    while true do
      local s, e = line:find("!%[%[.-%]%]", start)
      if not s then break end

      local inner = vim.trim(line:sub(s + 3, e - 2))

      if is_image_embed(inner) then
        -- ... (image handling unchanged) ...
      else
        -- Note embed
        local details = link_utils.parse_target(inner)
        local path = resolve_embed(details.name, bufnr)
        local virt_lines = {}

        if path then
          -- Check if total budget is already exhausted
          if total_remaining and total_remaining <= 0 then
            -- Show truncation indicator instead of resolving
            virt_lines[#virt_lines + 1] = {
              { string.rep("─", 2)
                .. " ![[" .. inner .. "]] (total line limit) "
                .. string.rep("─", 20), "VaultEmbedTruncated" },
            }
            stats.notes = stats.notes + 1
          else
            local source = path
            if path == bufpath then
              source = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            end

            local visited_set = { [bufpath] = true }
            local visited_list = { bufpath }

            -- Pass remaining budget (minus 2 for header+footer borders)
            local content_budget = total_remaining
            if content_budget then
              content_budget = content_budget - 2  -- reserve for borders
              if content_budget < 1 then content_budget = 1 end
            end

            local content, lines_used = resolve_embed_lines(
              details, source, 1, visited_set, visited_list, bufnr,
              content_budget
            )

            -- Build virt_lines (header + content + footer)
            local header_text = string.rep("─", 2)
              .. " ![[" .. inner .. "]] "
              .. string.rep("─", 40)
            virt_lines[#virt_lines + 1] = { { header_text, border_hl } }

            local cycle_hl = "VaultEmbedCycle"
            local depth_hl = "VaultEmbedDepth"
            local truncated_hl = "VaultEmbedTruncated"
            for _, cl in ipairs(content) do
              if cl:find("^↻ cycle:") then
                virt_lines[#virt_lines + 1] = { { "  " .. cl, cycle_hl } }
              elseif cl:find("^⋯ %(max embed depth") then
                virt_lines[#virt_lines + 1] = { { "  " .. cl, depth_hl } }
              elseif cl:find("^⋯ %(total line limit") or cl:find("^⋯ %(truncated") then
                virt_lines[#virt_lines + 1] = { { "  " .. cl, truncated_hl } }
              else
                virt_lines[#virt_lines + 1] = { { "  " .. cl, content_hl } }
              end
            end

            local footer_text = string.rep("─", 50)
            virt_lines[#virt_lines + 1] = { { footer_text, border_hl } }
            stats.notes = stats.notes + 1

            -- Deduct from total budget: content lines + 2 border lines
            if total_remaining then
              total_remaining = total_remaining - lines_used - 2
            end
          end
        else
          virt_lines[#virt_lines + 1] = {
            { string.rep("─", 2) .. " ![[" .. inner .. "]] (not found) "
              .. string.rep("─", 20), border_hl },
          }
          stats.errors = stats.errors + 1
        end

        vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
        })
      end

      start = e + 1
    end
  end

  embeds_visible[bufnr] = true

  -- ... (notification unchanged) ...
end
```

### Step 5: Add Highlight Group for Truncation

**File**: `lua/andrew/vault/embed.lua`, function `setup()` (line 599)

Add a new highlight group for the truncation indicator, visually distinct from the
depth and cycle indicators:

```lua
vim.api.nvim_set_hl(0, "VaultEmbedTruncated", { italic = true, fg = "#c0a040", default = true })
```

This reuses the same color as `VaultEmbedDepth` since both are "limit reached"
indicators. They could be differentiated later if needed.

### Step 6: Update Debug Info

**File**: `lua/andrew/vault/embed.lua`, function `debug_info()` (line 429)

Add the new config value to the debug output (near line 508):

```lua
info[#info + 1] = "  config.embed.max_total_lines: " .. tostring(config.embed.max_total_lines or 150)
```

## Files to Modify

| File | Changes |
|------|---------|
| `lua/andrew/vault/config.lua` | Add `max_total_lines = 150` to `M.embed` |
| `lua/andrew/vault/embed.lua` | Modify `get_embed_content()`, `resolve_embed_lines()`, `render_embeds()`, `setup()`, `debug_info()` |

## Edge Cases

1. **Single embed exceeds total limit**: The embed still renders, but its content is
   truncated at the budget boundary with a `"⋯ (truncated)"` indicator. The user sees
   partial content rather than nothing.

2. **Budget exhausted between embeds**: Subsequent top-level embeds show a single-line
   `"(total line limit)"` indicator in the header, so the user knows the embed exists
   but was not resolved.

3. **`max_total_lines = 0`**: Disables the total limit entirely. Budget is tracked as
   `nil` (unlimited), so all existing code paths with `if remaining then` guards are
   skipped. Zero performance overhead when disabled.

4. **Image embeds**: Not affected by the line budget. Image placements are rendered by
   snacks.nvim as inline graphics, not virtual text lines, so they do not consume from
   the total line budget.

5. **Heading sections with no line cap**: A heading section that spans 200 lines will
   now be capped by the remaining total budget via the `line_budget` parameter in
   `get_embed_content()`.

6. **Mixed embed + text lines**: Lines containing both text and `![[...]]` are kept
   as-is (existing behavior). They consume 1 line from the budget.

## Testing

### Manual Test Cases

1. **Basic truncation**: Create a note with 10 `![[...]]` embeds, each pointing to a
   20-line note. With `max_total_lines=150`, the first ~7 embeds render fully and the
   remaining show `"(total line limit)"`.

2. **Deep nesting**: Create a chain A -> B -> C -> D -> E, each embedding the next
   with 30 lines of content. Verify the total across the chain respects the limit and
   shows `"⋯ (total line limit reached)"` at the cut-off point.

3. **Heading section truncation**: Create a note with a heading section spanning 200
   lines. Embed it via `![[Note#LongSection]]`. Verify only `max_total_lines` lines
   are shown with a truncation indicator.

4. **Disabled limit**: Set `max_total_lines = 0`. Verify all embeds render fully
   (same as current behavior).

5. **Single large embed**: One embed pointing to a 500-line note. With
   `max_total_lines=150` and `max_lines=20`, the per-embed limit of 20 applies first.
   Total budget consumed: 22 (20 content + 2 borders).

6. **Debug output**: Run `:VaultEmbedDebug` and verify `max_total_lines` appears in
   the output.

### Verification Checklist

- [ ] Existing embeds render identically when `max_total_lines` is large or 0
- [ ] Truncation indicator appears when limit is reached
- [ ] Per-embed `max_lines` still respected independently
- [ ] Cycle detection still works within budget-limited resolution
- [ ] Depth limit still works within budget-limited resolution
- [ ] Image embeds unaffected
- [ ] `:VaultEmbedDebug` shows the new config value
- [ ] No errors on empty embeds, not-found notes, or self-referencing embeds
