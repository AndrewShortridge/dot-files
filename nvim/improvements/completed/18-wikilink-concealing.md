# 18 — Wikilink Concealing & Resolution-Aware Highlighting

## Problem

Wikilinks (`[[Note Name]]`) display with full bracket syntax in the buffer. While `conceallevel = 2` is set in `ftplugin/markdown.lua`, the bracket concealing behavior depends on render-markdown.nvim's `obsidian` preset, which:

1. **Does** conceal `[[` and `]]` brackets and prepend an icon (`󱗖 `) when the cursor is **not** on the line.
2. **Does not** distinguish between valid and broken links — all wikilinks look identical regardless of whether the target note exists.
3. **Does not** color-code by link type (note reference vs. heading anchor vs. block reference).

The existing `linkdiag.lua` module validates links and reports broken ones as diagnostics (underline + error/warning signs), but there is no positive visual feedback for **valid** links — they just look like any other text when the cursor is on the line.

### Current Rendering Stack

| Layer | What It Does | File |
|-------|-------------|------|
| **Treesitter** | Parses `[[target]]` as `shortcut_link > link_text` (no `wiki_link` extension compiled) | `markdown_inline` parser |
| **render-markdown.nvim** | Conceals brackets, adds `󱗖 ` icon, applies `RenderMarkdownWikiLink` highlight | `render-markdown.lua` (obsidian preset) |
| **linkdiag.lua** | Validates links, sets ERROR/WARN diagnostics for broken links/headings | `lua/andrew/vault/linkdiag.lua` |
| **Treesitter default** | `(shortcut_link [ "[" "]" ] @conceal)` — conceals inner brackets | bundled `highlights.scm` |

### Why Treesitter Queries Alone Cannot Solve This

The installed `markdown_inline` parser does **not** compile the `wiki_link` extension. Wikilinks parse as:

```
inline
  "[" (anonymous)           ← outer bracket, child of inline (NOT shortcut_link)
  shortcut_link             ← spans only the inner [target]
    "["                     ← inner bracket (already concealed by default query)
    link_text "target"
    "]"                     ← inner bracket (already concealed)
  "]" (anonymous)           ← outer bracket, child of inline
```

The outer `[` and `]` are anonymous children of the root `inline` node. Treesitter queries **cannot** target "anonymous bracket that is a sibling of a `shortcut_link`" — there is no adjacency/sibling predicate for anonymous nodes. This is why render-markdown.nvim uses programmatic extmarks (Lua) rather than treesitter concealing for wiki links.

**Conclusion**: Resolution-aware highlighting requires a **Lua extmark module** that integrates with `linkdiag.lua`'s validation.

---

## Goal

Add resolution-aware visual feedback for wikilinks so that:

1. **Valid links** are highlighted with a distinct color (e.g., blue/cyan underline) when cursor is on the line.
2. **Broken links** are highlighted with a warning color (e.g., red/orange) — complementing existing diagnostics.
3. **Heading anchors** (`[[Note#Heading]]`) show a different accent when the heading exists vs. doesn't.
4. **Self-references** (`[[#Heading]]`, `[[^blockid]]`) get their own subtle highlight.
5. Highlighting coexists with render-markdown.nvim's bracket concealing (no conflicts).
6. Performance is acceptable for buffers with hundreds of links (debounced, uses existing caches).

---

## Approach

### Architecture

Create a new module `lua/andrew/vault/wikilink_highlights.lua` that:

1. Scans buffer lines for `[[...]]` patterns (same regex as `linkdiag.lua`).
2. For each wikilink, resolves the target using `wikilinks.resolve_link()`.
3. Applies extmarks with highlight groups based on resolution status.
4. Runs on `BufEnter`, `TextChanged`, `TextChangedI` (debounced 150ms).
5. Integrates with `linkdiag.lua` — shares validation results when available.

### Highlight Groups

| Group | Applies To | Default Style |
|-------|-----------|---------------|
| `VaultWikiLinkValid` | Resolved wikilink text | `fg = #61afef` (blue), `underline = true` |
| `VaultWikiLinkBroken` | Unresolved wikilink text | `fg = #e06c75` (red), `undercurl = true`, `sp = #e06c75` |
| `VaultWikiLinkHeading` | Valid `#heading` anchor portion | `fg = #98c379` (green), `italic = true` |
| `VaultWikiLinkHeadingBroken` | Broken `#heading` anchor | `fg = #d19a66` (orange), `undercurl = true`, `sp = #d19a66` |
| `VaultWikiLinkSelf` | Self-reference `[[#...]]` / `[[^...]]` | `fg = #c678dd` (purple), `italic = true` |
| `VaultWikiLinkAlias` | Display alias after `\|` | `fg = #61afef` (blue), `bold = true` |
| `VaultWikiLinkBracket` | The `[[` and `]]` brackets (when visible) | `fg = #5c6370` (gray), dim |

Colors are chosen from the OneDarkPro palette already used in `colorscheme.lua`.

### Interaction with render-markdown.nvim

render-markdown.nvim conceals brackets and adds an icon when the cursor is **off** the line. When the cursor **enters** the line, render-markdown.nvim removes its extmarks and shows raw text. Our module should:

- Apply highlights to the **link text** (between the brackets), not the brackets themselves.
- Use `priority = 200` for extmarks (render-markdown uses 1000+, linkdiag diagnostics use default ~10).
- Set `hl_mode = "combine"` so our underline/color combines with render-markdown's concealed view.
- Skip lines where render-markdown is actively rendering (cursor-off lines) — OR apply highlights that layer cleanly beneath render-markdown's extmarks.

**Simplest approach**: Apply highlights to ALL wikilinks in the buffer. When render-markdown conceals brackets, our highlight on the `link_text` region still shows through the concealed rendering. When the cursor is on the line and brackets are visible, our highlight applies to the text between `[[` and `]]`.

---

## Implementation

### File: `lua/andrew/vault/wikilink_highlights.lua`

```lua
local engine = require("andrew.vault.engine")
local link_utils = require("andrew.vault.link_utils")

local M = {}

M.enabled = true
M.ns = vim.api.nvim_create_namespace("vault_wikilink_hl")

--- Debounce timer handle.
---@type uv.uv_timer_t|nil
local timer = nil
local DEBOUNCE_MS = 150

-- ---------------------------------------------------------------------------
-- Highlight group definitions
-- ---------------------------------------------------------------------------

local hl_groups = {
  VaultWikiLinkValid = { fg = "#61afef", underline = true },
  VaultWikiLinkBroken = { fg = "#e06c75", undercurl = true, sp = "#e06c75" },
  VaultWikiLinkHeading = { fg = "#98c379", italic = true },
  VaultWikiLinkHeadingBroken = { fg = "#d19a66", undercurl = true, sp = "#d19a66" },
  VaultWikiLinkSelf = { fg = "#c678dd", italic = true },
  VaultWikiLinkAlias = { fg = "#61afef", bold = true },
  VaultWikiLinkBracket = { fg = "#5c6370" },
}

local function define_highlights()
  for group, attrs in pairs(hl_groups) do
    -- Use default = true so user colorscheme overrides take precedence
    attrs.default = true
    vim.api.nvim_set_hl(0, group, attrs)
  end
end

-- ---------------------------------------------------------------------------
-- Link resolution (delegates to wikilinks module)
-- ---------------------------------------------------------------------------

--- Resolve a wikilink target name to an absolute path (or nil if broken).
--- Uses the wikilinks module's cached resolution.
---@param name string the note name from the wikilink
---@return string|nil absolute path if resolved
local function resolve_link(name)
  -- Lazy-require to avoid circular dependency at load time
  local wikilinks = require("andrew.vault.wikilinks")
  return wikilinks.resolve_link(name)
end

--- Check if a heading exists in the given file.
---@param filepath string absolute path
---@param heading string heading text
---@return boolean
local function heading_exists(filepath, heading)
  local linkdiag = require("andrew.vault.linkdiag")
  local slug_set = linkdiag.get_headings(filepath)
  local target_slug = link_utils.heading_to_slug(heading)
  return slug_set[target_slug] == true
end

-- ---------------------------------------------------------------------------
-- Core highlight application
-- ---------------------------------------------------------------------------

--- Clear all wikilink highlights from a buffer.
---@param bufnr number
local function clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

--- Scan buffer and apply resolution-aware highlights to all wikilinks.
---@param bufnr number
local function apply(bufnr)
  if not M.enabled then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local fname = vim.api.nvim_buf_get_name(bufnr)
  if not engine.is_vault_path(fname) then
    clear(bufnr)
    return
  end

  clear(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local self_path = fname

  for i, line in ipairs(lines) do
    local pos = 1
    while true do
      -- Find wikilink opening [[
      local open = line:find("%[%[", pos, false)
      if not open then break end

      -- Skip embed links (![[...]])
      local is_embed = open > 1 and line:sub(open - 1, open - 1) == "!"
      local close = line:find("]]", open + 2, true)
      if not close then break end
      pos = close + 2
      if is_embed then goto continue end

      local inner = line:sub(open + 2, close - 1)
      local parsed = link_utils.parse_target(inner)
      local target = parsed.name
      local heading = parsed.heading
      local alias = parsed.alias

      -- Skip bare URLs inside wikilinks
      if target:match("^https?://") then goto continue end

      -- Byte positions for extmarks (0-indexed)
      local row = i - 1
      local bracket_open_start = open - 1        -- start of first [
      local bracket_open_end = open + 1           -- end of second [
      local text_start = open + 1                 -- start of inner text
      local text_end = close - 1                  -- end of inner text
      local bracket_close_start = close - 1       -- start of first ]
      local bracket_close_end = close + 1         -- end of second ]

      -- Highlight brackets (dim gray)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, bracket_open_start, {
        end_col = bracket_open_end,
        hl_group = "VaultWikiLinkBracket",
        hl_mode = "combine",
        priority = 200,
      })
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, bracket_close_start, {
        end_col = bracket_close_end,
        hl_group = "VaultWikiLinkBracket",
        hl_mode = "combine",
        priority = 200,
      })

      -- Determine highlight for the link text
      if target == "" then
        -- Self-reference: [[#Heading]] or [[^blockid]]
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, text_start, {
          end_col = text_end,
          hl_group = "VaultWikiLinkSelf",
          hl_mode = "combine",
          priority = 200,
        })
      else
        -- Cross-file link: resolve the target
        local resolved_path = resolve_link(target)

        if not resolved_path then
          -- Broken link: note not found
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, text_start, {
            end_col = text_end,
            hl_group = "VaultWikiLinkBroken",
            hl_mode = "combine",
            priority = 200,
          })
        else
          -- Valid note — find where the note name ends and heading begins
          local name_byte_end = text_start + #target

          -- Highlight the note name portion
          local name_hl = "VaultWikiLinkValid"
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, text_start, {
            end_col = math.min(name_byte_end, text_end),
            hl_group = name_hl,
            hl_mode = "combine",
            priority = 200,
          })

          -- Highlight heading anchor if present
          if heading then
            -- The # character + heading text starts after the note name
            local hash_pos = line:find("#", open + 2 + #target, true)
            if hash_pos then
              local heading_start = hash_pos - 1 -- 0-indexed
              local heading_end_pos = heading_start + 1 + #heading
              -- Check if heading actually exists in the target file
              local h_exists = heading_exists(resolved_path, heading)
              local heading_hl = h_exists
                and "VaultWikiLinkHeading"
                or "VaultWikiLinkHeadingBroken"
              pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, heading_start, {
                end_col = math.min(heading_end_pos, text_end),
                hl_group = heading_hl,
                hl_mode = "combine",
                priority = 200,
              })
            end
          end

          -- Highlight alias portion if present
          if alias then
            local pipe_pos = line:find("|", open + 2, true)
            if pipe_pos and pipe_pos < close then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, pipe_pos, {
                end_col = text_end,
                hl_group = "VaultWikiLinkAlias",
                hl_mode = "combine",
                priority = 200,
              })
            end
          end
        end
      end

      ::continue::
    end
  end
end

-- ---------------------------------------------------------------------------
-- Debounced update
-- ---------------------------------------------------------------------------

--- Schedule a debounced highlight update for the given buffer.
---@param bufnr number
local function schedule_update(bufnr)
  if timer then
    timer:stop()
  end
  timer = vim.uv.new_timer()
  timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      apply(bufnr)
    end
  end))
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

function M.toggle()
  M.enabled = not M.enabled
  if M.enabled then
    local bufnr = vim.api.nvim_get_current_buf()
    apply(bufnr)
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      clear(buf)
    end
  end
  vim.notify(
    "Vault: wikilink highlights " .. (M.enabled and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  define_highlights()

  local group = vim.api.nvim_create_augroup("VaultWikilinkHL", { clear = true })

  -- Apply on buffer enter and after writes
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        -- Defer slightly to let linkdiag and wikilinks caches settle
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            apply(ev.buf)
          end
        end, 50)
      end
    end,
  })

  -- Debounced update on text changes (normal and insert mode)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      if M.enabled and engine.is_vault_path(vim.api.nvim_buf_get_name(ev.buf)) then
        schedule_update(ev.buf)
      end
    end,
  })

  -- Re-define highlights when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = define_highlights,
  })

  -- Clean up on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      clear(ev.buf)
    end,
  })

  -- Commands
  vim.api.nvim_create_user_command("VaultWikilinkHLToggle", function()
    M.toggle()
  end, { desc = "Toggle wikilink resolution highlighting" })

  vim.api.nvim_create_user_command("VaultWikilinkHLRefresh", function()
    apply(vim.api.nvim_get_current_buf())
  end, { desc = "Refresh wikilink highlights in current buffer" })

  -- Buffer-local keymap
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vch", function()
        M.toggle()
      end, {
        buffer = ev.buf,
        desc = "Check: wikilink highlights toggle",
        silent = true,
      })
    end,
  })
end

return M
```

---

## Integration

### 1. Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add to the module setup chain (after `linkdiag` and `wikilinks`):

```lua
require("andrew.vault.wikilink_highlights").setup()
```

### 2. Verify render-markdown.nvim wiki config

The `obsidian` preset enables wiki link rendering by default. To customize:

**File:** `lua/andrew/plugins/render-markdown.lua`

Add to `opts`:

```lua
wiki = {
  enabled = true,
  icon = "󱗖 ",
  highlight = "RenderMarkdownWikiLink",
  -- Return nil to keep the original link text visible (don't replace with body)
  body = function() return nil end,
},
```

### 3. Optional: link render-markdown's wiki highlight to our groups

To make render-markdown.nvim's concealed view use resolution-aware colors, you would need to override its rendering per-link. This is **not supported** by render-markdown.nvim's API — it applies the same `RenderMarkdownWikiLink` highlight to all wiki links. Our extmarks with `hl_mode = "combine"` layer underneath and show through when render-markdown doesn't override.

**Practical result:**
- **Cursor off line**: render-markdown conceals brackets, shows icon + `RenderMarkdownWikiLink` color. Our extmarks are present but hidden by render-markdown's higher-priority extmarks.
- **Cursor on line**: render-markdown removes its extmarks, brackets become visible. **Our extmarks now show**: valid links in blue/underline, broken in red/undercurl, headings in green, etc.

This is the ideal UX: clean concealed view when reading, resolution-aware colors when editing.

---

## Configuration

Add to `lua/andrew/vault/config.lua`:

```lua
--- Wikilink highlight settings
wikilink_highlights = {
  enabled = true,
  debounce_ms = 150,
  -- Highlight groups can be overridden by the user's colorscheme
  highlights = {
    valid = "VaultWikiLinkValid",
    broken = "VaultWikiLinkBroken",
    heading = "VaultWikiLinkHeading",
    heading_broken = "VaultWikiLinkHeadingBroken",
    self_ref = "VaultWikiLinkSelf",
    alias = "VaultWikiLinkAlias",
    bracket = "VaultWikiLinkBracket",
  },
},
```

---

## Testing

### Manual Verification

1. **Open a vault markdown file with mixed valid/broken links:**
   ```markdown
   Valid note: [[Daily Log]]
   Broken note: [[Nonexistent Note]]
   Valid heading: [[Daily Log#Priorities]]
   Broken heading: [[Daily Log#Nonexistent Section]]
   Self-reference: [[#Heading In This File]]
   Aliased link: [[Daily Log|Today's Log]]
   ```

2. **Expected behavior:**
   - `Daily Log` text → blue with underline
   - `Nonexistent Note` text → red with undercurl
   - `Daily Log` portion of heading link → blue underline; `#Priorities` → green italic
   - `Daily Log` portion → blue underline; `#Nonexistent Section` → orange undercurl
   - `#Heading In This File` → purple italic
   - `Today's Log` alias portion → blue bold

3. **Move cursor on/off the lines:**
   - Cursor off: render-markdown conceals brackets, shows icon — our colors may or may not show through
   - Cursor on: brackets visible, our resolution colors clearly visible

4. **Edit a link to make it broken, wait 150ms** — highlight should change from valid to broken.

5. **Run `:VaultWikilinkHLToggle`** — highlights should disappear/reappear.

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: wikilink_highlights module loads and defines highlight groups
do
  local ok, wh = pcall(require, "andrew.vault.wikilink_highlights")
  assert_true(ok, "wikilink_highlights module loads")

  -- Verify highlight groups are defined after setup
  -- (would need nvim runtime for full test — pattern test here)
  local source = io.open("lua/andrew/vault/wikilink_highlights.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()
    assert_true(content:find("VaultWikiLinkValid") ~= nil, "defines VaultWikiLinkValid group")
    assert_true(content:find("VaultWikiLinkBroken") ~= nil, "defines VaultWikiLinkBroken group")
    assert_true(content:find("resolve_link") ~= nil, "uses resolve_link for validation")
    assert_true(content:find("nvim_buf_set_extmark") ~= nil, "uses extmarks for highlighting")
    assert_true(content:find("schedule_update") ~= nil, "has debounced update")
  end
end
```

### Performance Verification

In a vault with 500+ notes, open a file with 50+ wikilinks:
```vim
:lua local start = vim.uv.hrtime(); require("andrew.vault.wikilink_highlights").apply(0); print(("%.1f ms"):format((vim.uv.hrtime() - start) / 1e6))
```

Target: < 20ms for a 50-link buffer. The bottleneck is `resolve_link()` which uses the cached name→path mapping, so each call should be < 0.1ms.

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Empty wikilink `[[]]` | Skipped (no text to highlight) |
| Embed `![[Note]]` | Skipped (`is_embed` guard) |
| URL in wikilink `[[https://example.com]]` | Skipped (URL pattern guard) |
| Wikilink in code block | May highlight — acceptable tradeoff vs. treesitter code block detection cost |
| Escaped pipe in table `[[Note\|alias]]` | Handled by `link_utils.parse_target()` which normalizes `\|` to `|` |
| Very long lines (1000+ chars) | Works — string.find is efficient for pattern scanning |
| Multiple wikilinks on same line | All highlighted independently |
| Link target with path prefix `[[folder/Note]]` | Resolved via basename matching in `wikilinks.resolve_link()` |
| Buffer not in vault | Cleared immediately (no highlights) |
| linkdiag disabled | Still works — uses `wikilinks.resolve_link()` independently |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `is_vault_path()`, `vault_path` | Yes |
| `link_utils.lua` | `parse_target()`, `heading_to_slug()` | Yes |
| `wikilinks.lua` | `resolve_link()` (cached name resolution) | Yes |
| `linkdiag.lua` | `get_headings()` (cached heading extraction) | Optional (heading validation only) |
| render-markdown.nvim | Coexists — no direct dependency | No |

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/wikilink_highlights.lua` | **New file** — complete module |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.wikilink_highlights").setup()` |
| `lua/andrew/vault/config.lua` | Add `wikilink_highlights` config section (optional) |
| `lua/andrew/plugins/render-markdown.lua` | Add explicit `wiki` config (optional, for customization) |

---

## Risk Assessment

**Risk: Low**

- New module, no existing code modified (except one `require` line in `init.lua`).
- Uses established patterns from `linkdiag.lua` (extmarks, autocmds, debouncing).
- Extmarks with `priority = 200` won't conflict with render-markdown.nvim (priority 1000+) or diagnostics (priority ~10).
- `hl_mode = "combine"` ensures graceful layering.
- Toggle command provides easy escape if issues arise.
