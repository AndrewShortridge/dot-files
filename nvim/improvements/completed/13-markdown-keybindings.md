# 13: Markdown-Specific Editing Keybindings

## Problem

The Neovim config lacks common markdown text formatting keybindings. When editing
markdown files, toggling bold, italic, strikethrough, inline code, and creating
links all require manual typing of delimiters. This is tedious and error-prone,
especially for frequently used formatting like bold and italic.

The existing `ftplugin/markdown.lua` provides folding, heading navigation,
checkbox cycling, and math motions, but no inline text formatting shortcuts.
Editors like Obsidian and VS Code provide these out of the box. Adding them to
the Neovim config would bring parity with those tools for markdown editing
workflows.

---

## Existing Keybindings in `ftplugin/markdown.lua`

The `<leader>m` prefix is already used for markdown-specific operations in
markdown buffers. It is also registered globally in `which-key.lua` as
"Make/Build" for the `fortran-build.lua` plugin. Since ftplugin bindings are
buffer-local and override globals, there is no runtime conflict in markdown
buffers -- but the which-key group description shows "Make/Build" rather than
"Markdown" when editing `.md` files.

### Current `<leader>m` Mappings (Markdown Buffers)

| Keybinding     | Source                    | Mode | Description              |
|----------------|---------------------------|------|--------------------------|
| `<leader>mf`   | `ftplugin/markdown.lua`   | n    | Fold all (`zM`)          |
| `<leader>mu`   | `ftplugin/markdown.lua`   | n    | Unfold all (`zR`)        |
| `<leader>ml`   | `ftplugin/markdown.lua`   | n    | Set fold level (prompt)  |
| `<leader>mx`   | `ftplugin/markdown.lua`   | n    | Cycle checkbox state     |
| `<leader>mj`   | `vault/footnotes.lua`     | n    | Footnote: jump ref/def   |
| `<leader>mn`   | `vault/footnotes.lua`     | n    | Footnote: list all       |
| `<leader>mz`   | `render-markdown.lua`     | n    | Toggle callout fold      |

### Other Markdown-Buffer Keybindings (Non-`<leader>m` Prefix)

| Keybinding   | Source                | Mode | Description                     |
|--------------|------------------------|------|---------------------------------|
| `<Tab>`      | `ftplugin/markdown.lua`| n    | Toggle fold (`za`)              |
| `]h` / `[h`  | `ftplugin/markdown.lua`| n    | Next/previous heading           |
| `]1`..`]6`   | `ftplugin/markdown.lua`| n    | Next heading at level N         |
| `[1`..`[6`   | `ftplugin/markdown.lua`| n    | Previous heading at level N     |
| `]m` / `[m`  | `tex-motions.lua`      | n    | Next/previous math block        |
| `am` / `im`  | `tex-motions.lua`      | o/v  | Around/inner math text object   |
| `gf` / `gx`  | `vault/wikilinks.lua`  | n    | Follow link (wiki/md/URL)       |
| `]o` / `[o`  | `vault/wikilinks.lua`  | n    | Next/previous link              |
| `<leader>vp` | `vault/images.lua`     | n    | Paste clipboard image           |

### Available Keys Under `<leader>m`

Already taken: `f`, `u`, `l`, `x`, `j`, `n`, `z`

Free for new bindings: `b`, `i`, `s`, `c`, `k`, `p`, `1`-`6`, and others.

---

## New Keybindings to Add

All new keybindings use the `<leader>m` prefix and are buffer-local to markdown
files. They are added to `ftplugin/markdown.lua` to keep all markdown-specific
bindings in one place.

### Summary Table

| Keybinding         | Mode | Description                        |
|--------------------|------|------------------------------------|
| `<leader>mb`       | n, v | Toggle **bold**                    |
| `<leader>mi`       | n, v | Toggle *italic*                    |
| `<leader>ms`       | n, v | Toggle ~~strikethrough~~           |
| `<leader>mc`       | n, v | Toggle `` `inline code` ``        |
| `<leader>mk`       | v    | Create `[text](url)` link         |
| `<leader>mK`       | v    | Create `[[text]]` wikilink        |
| `<leader>mp`       | n    | Paste clipboard image              |
| `<leader>m1`..`m6` | n    | Set/toggle heading level 1-6      |

---

## Implementation

### a. Toggle Bold (`<leader>mb`)

In normal mode, toggles `**...**` around the word under the cursor.
In visual mode, wraps or unwraps the selection with `**`.

```lua
-- Toggle a markdown delimiter around text.
-- @param delim string  The delimiter (e.g., "**", "*", "~~", "`")
-- @param mode string   "n" for normal (word under cursor), "v" for visual selection
local function toggle_markup(delim, mode)
  local len = #delim

  if mode == "n" then
    -- Normal mode: operate on the word under cursor
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-indexed

    -- Find the word boundaries around the cursor.
    -- Expand to include adjacent delimiter characters so we detect wrapped words.
    local word_start = col
    while word_start > 0 and not line:sub(word_start, word_start):match("%s") do
      word_start = word_start - 1
    end
    word_start = word_start + 1 -- 1-indexed start of word region

    local word_end = col + 2 -- 1-indexed, start past cursor
    while word_end <= #line and not line:sub(word_end, word_end):match("%s") do
      word_end = word_end + 1
    end
    word_end = word_end - 1 -- 1-indexed end of word region

    local region = line:sub(word_start, word_end)

    -- Check if region is already wrapped with the delimiter
    if region:sub(1, len) == delim and region:sub(-len) == delim and #region > 2 * len then
      -- Remove delimiters
      local unwrapped = region:sub(len + 1, #region - len)
      local new_line = line:sub(1, word_start - 1) .. unwrapped .. line:sub(word_end + 1)
      vim.api.nvim_set_current_line(new_line)
      -- Adjust cursor position
      local new_col = math.min(col, word_start - 1 + #unwrapped - 1)
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], new_col })
    else
      -- Add delimiters
      local wrapped = delim .. region .. delim
      local new_line = line:sub(1, word_start - 1) .. wrapped .. line:sub(word_end + 1)
      vim.api.nvim_set_current_line(new_line)
      -- Move cursor to account for added prefix
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], col + len })
    end
  elseif mode == "v" then
    -- Visual mode: operate on the selected text
    -- Get selection range. Use getpos() for marks set by the last visual selection.
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_row, start_col = start_pos[2], start_pos[3] -- 1-indexed
    local end_row, end_col = end_pos[2], end_pos[3]         -- 1-indexed

    -- Only support single-line selections for inline formatting
    if start_row ~= end_row then
      vim.notify("Markdown format: only single-line selections supported", vim.log.levels.WARN)
      return
    end

    local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
    local selected = line:sub(start_col, end_col)

    -- Check if selection is already wrapped
    if selected:sub(1, len) == delim and selected:sub(-len) == delim and #selected > 2 * len then
      -- Unwrap: remove delimiters from inside the selection
      local unwrapped = selected:sub(len + 1, #selected - len)
      local new_line = line:sub(1, start_col - 1) .. unwrapped .. line:sub(end_col + 1)
      vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
    else
      -- Check if delimiters exist just outside the selection
      local pre = line:sub(math.max(1, start_col - len), start_col - 1)
      local post = line:sub(end_col + 1, math.min(#line, end_col + len))
      if pre == delim and post == delim then
        -- Remove the outer delimiters
        local new_line = line:sub(1, start_col - len - 1) .. selected .. line:sub(end_col + len + 1)
        vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
      else
        -- Wrap: add delimiters around selection
        local wrapped = delim .. selected .. delim
        local new_line = line:sub(1, start_col - 1) .. wrapped .. line:sub(end_col + 1)
        vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
      end
    end
  end
end
```

Keybinding registration:

```lua
-- Bold
vim.keymap.set("n", "<leader>mb", function()
  toggle_markup("**", "n")
end, { buffer = true, desc = "Toggle bold" })

vim.keymap.set("v", "<leader>mb", function()
  -- Exit visual mode so '< and '> marks are set
  vim.cmd("normal! ")
  toggle_markup("**", "v")
end, { buffer = true, desc = "Toggle bold" })
```

**Note on the visual mode pattern**: The `vim.cmd("normal! ")` call
(with a literal `<Esc>` character, written as `\27` in the actual Lua string)
exits visual mode, which causes Neovim to set the `'<` and `'>` marks to the
boundaries of the visual selection. The `toggle_markup` function then reads
those marks via `vim.fn.getpos()`. This is the standard pattern for operating
on a visual selection from a Lua keymap callback.

In the actual implementation, use the escape literal:

```lua
vim.keymap.set("v", "<leader>mb", function()
  vim.cmd([[normal! \<Esc>]])  -- won't work; see below
end, ...)
```

The correct approach for exiting visual mode in a keymap callback:

```lua
vim.keymap.set("v", "<leader>mb", function()
  -- Feedkeys approach: send <Esc> to exit visual mode, then process
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)
  toggle_markup("**", "v")
end, { buffer = true, desc = "Toggle bold" })
```

However, an even cleaner approach is to use `:` mapping mode which provides
the range automatically. The simplest reliable pattern is:

```lua
vim.keymap.set("v", "<leader>mb", "<Esc><cmd>lua ToggleMarkup('**', 'v')<CR>",
  { buffer = true, desc = "Toggle bold" })
```

But to avoid globals, the recommended pattern used throughout this implementation
is:

```lua
local function vmap(lhs, rhs, desc)
  vim.keymap.set("v", lhs, function()
    -- Exit visual mode to set '< '> marks
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    -- Schedule to run after visual mode is exited
    vim.schedule(rhs)
  end, { buffer = true, desc = desc })
end
```

---

### b. Toggle Italic (`<leader>mi`)

Uses the same `toggle_markup` function with `"*"` as the delimiter.

**Edge case**: Since `*` is a substring of `**`, the function must handle italic
vs bold correctly. The word-boundary detection naturally handles this because
`**word**` has `**` as the first 2 characters of the region, while `*word*` has
`*` as the first 1 character. When toggling italic, `len = 1`, so it checks for
a single `*` at each boundary. When the region is `**word**`, the single-`*`
check would match, but removing one `*` from each side would leave `*word*` --
which is still bold-formatted. This is actually the correct behavior for
"toggle italic on a bold word" (resulting in bold-italic), but it could be
confusing.

**Recommendation**: Check for the delimiter at the exact boundary and verify that
the character just beyond the delimiter is NOT the same character:

```lua
-- Inside toggle_markup, after extracting `region` in normal mode:
local starts_with = region:sub(1, len) == delim
local ends_with = region:sub(-len) == delim
-- Avoid matching ** when looking for *
if len < #region then
  local char_after_prefix = region:sub(len + 1, len + 1)
  local char_before_suffix = region:sub(#region - len, #region - len)
  if delim == "*" and char_after_prefix == "*" then
    starts_with = false
  end
  if delim == "*" and char_before_suffix == "*" then
    ends_with = false
  end
end
```

Keybinding registration:

```lua
map("<leader>mi", function() toggle_markup("*", "n") end, "Toggle italic")
vmap("<leader>mi", function() toggle_markup("*", "v") end, "Toggle italic")
```

---

### c. Toggle Strikethrough (`<leader>ms`)

Uses `toggle_markup` with `"~~"` as the delimiter. No special edge cases since
`~~` does not conflict with other markdown delimiters.

```lua
map("<leader>ms", function() toggle_markup("~~", "n") end, "Toggle strikethrough")
vmap("<leader>ms", function() toggle_markup("~~", "v") end, "Toggle strikethrough")
```

---

### d. Toggle Inline Code (`<leader>mc`)

Uses `toggle_markup` with `` "`" `` as the delimiter.

**Conflict note**: `<leader>mc` is currently mapped globally by
`fortran-build.lua` to "Make: Clean". Since the ftplugin binding is
buffer-local, it will take priority in markdown buffers. If this is undesirable,
use `<leader>m`` ` (backtick) instead, though that is harder to type.

```lua
map("<leader>mc", function() toggle_markup("`", "n") end, "Toggle inline code")
vmap("<leader>mc", function() toggle_markup("`", "v") end, "Toggle inline code")
```

---

### e. Quick Link Creation (`<leader>mk` / `<leader>mK`)

#### Markdown link from visual selection (`<leader>mk`)

Wraps the visual selection as `[text](url)` and prompts for the URL.

```lua
local function create_md_link()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row ~= end_row then
    vim.notify("Link creation: only single-line selections supported", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
  local selected = line:sub(start_col, end_col)

  vim.ui.input({ prompt = "URL: " }, function(url)
    if not url or url == "" then
      return
    end
    local link = "[" .. selected .. "](" .. url .. ")"
    local new_line = line:sub(1, start_col - 1) .. link .. line:sub(end_col + 1)
    vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
  end)
end

vmap("<leader>mk", create_md_link, "Create [text](url) link")
```

#### Wikilink from visual selection (`<leader>mK`)

Wraps the visual selection as `[[text]]`.

```lua
local function create_wikilink()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row ~= end_row then
    vim.notify("Link creation: only single-line selections supported", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
  local selected = line:sub(start_col, end_col)

  -- Check if already a wikilink
  local pre2 = line:sub(math.max(1, start_col - 2), start_col - 1)
  local post2 = line:sub(end_col + 1, math.min(#line, end_col + 2))
  if pre2 == "[[" and post2 == "]]" then
    -- Unwrap: remove [[ and ]]
    local new_line = line:sub(1, start_col - 3) .. selected .. line:sub(end_col + 3)
    vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
  else
    -- Wrap as wikilink
    local link = "[[" .. selected .. "]]"
    local new_line = line:sub(1, start_col - 1) .. link .. line:sub(end_col + 1)
    vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
  end
end

vmap("<leader>mK", create_wikilink, "Create [[wikilink]]")
```

---

### f. Paste Clipboard Image (`<leader>mp`)

Integrates with the existing `vault/images.lua` module. The existing
`<leader>vp` keybinding already provides this under the vault prefix. The
`<leader>mp` binding adds a second entry point under the markdown prefix for
discoverability.

```lua
map("<leader>mp", function()
  require("andrew.vault.images").paste_image()
end, "Paste clipboard image")
```

This delegates entirely to the existing `images.lua` implementation which:
1. Generates a timestamped filename (`img-YYYYMMDD-HHMMSS.png`)
2. Saves clipboard content to `{vault}/attachments/` via `xclip` or `wl-paste`
3. Inserts `![](attachments/filename.png)` at the cursor

---

### g. Toggle Heading Level (`<leader>m1` through `<leader>m6`)

Sets the current line to the specified heading level. If the line is already at
that level, removes the heading prefix entirely.

```lua
local function toggle_heading(level)
  local line = vim.api.nvim_get_current_line()
  local prefix = string.rep("#", level) .. " "

  -- Check if line already has a heading prefix
  local existing_hashes, rest = line:match("^(#+)%s+(.*)")
  if existing_hashes then
    if #existing_hashes == level then
      -- Same level: remove heading entirely
      vim.api.nvim_set_current_line(rest)
    else
      -- Different level: replace with new level
      vim.api.nvim_set_current_line(prefix .. rest)
    end
  else
    -- No heading: add heading prefix
    -- Strip leading whitespace before adding heading
    local trimmed = line:match("^%s*(.*)$")
    vim.api.nvim_set_current_line(prefix .. trimmed)
  end
end

for level = 1, 6 do
  map("<leader>m" .. level, function()
    toggle_heading(level)
  end, "Heading " .. level)
end
```

---

## Complete Implementation

The following is the complete code to add to `ftplugin/markdown.lua`. It should
be appended after the existing keybindings (after the checkbox cycling block).

```lua
-- =============================================================================
-- Markdown Inline Formatting Keybindings
-- =============================================================================

-- Helper: map a visual-mode keybinding that exits visual mode first
local function vmap(lhs, rhs, desc)
  vim.keymap.set("v", lhs, function()
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    vim.schedule(rhs)
  end, { buffer = true, desc = desc })
end

--- Toggle a markdown inline delimiter around text.
--- @param delim string  The delimiter (e.g., "**", "*", "~~", "`")
--- @param mode string   "n" for normal (word under cursor), "v" for visual selection
local function toggle_markup(delim, mode)
  local len = #delim

  if mode == "n" then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2] -- 0-indexed

    -- Find the word region around the cursor (including adjacent delimiters)
    local word_start = col
    while word_start > 0 and not line:sub(word_start, word_start):match("%s") do
      word_start = word_start - 1
    end
    word_start = word_start + 1 -- 1-indexed

    local word_end = col + 2 -- 1-indexed, start past cursor char
    while word_end <= #line and not line:sub(word_end, word_end):match("%s") do
      word_end = word_end + 1
    end
    word_end = word_end - 1 -- 1-indexed

    local region = line:sub(word_start, word_end)

    -- Determine if region is already delimited.
    -- Guard against partial matches (e.g., * vs **):
    -- After stripping the delimiter, the next char must NOT be the same.
    local is_wrapped = false
    if #region > 2 * len and region:sub(1, len) == delim and region:sub(-len) == delim then
      is_wrapped = true
      -- Check for false positive: * matching the first * of **
      if delim == "*" then
        if region:sub(len + 1, len + 1) == "*" or region:sub(#region - len, #region - len) == "*" then
          is_wrapped = false
        end
      end
    end

    if is_wrapped then
      local unwrapped = region:sub(len + 1, #region - len)
      local new_line = line:sub(1, word_start - 1) .. unwrapped .. line:sub(word_end + 1)
      vim.api.nvim_set_current_line(new_line)
      local new_col = math.max(0, math.min(col - len, word_start - 1 + #unwrapped - 1))
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], new_col })
    else
      local wrapped = delim .. region .. delim
      local new_line = line:sub(1, word_start - 1) .. wrapped .. line:sub(word_end + 1)
      vim.api.nvim_set_current_line(new_line)
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], col + len })
    end

  elseif mode == "v" then
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_row, start_col = start_pos[2], start_pos[3]
    local end_row, end_col = end_pos[2], end_pos[3]

    if start_row ~= end_row then
      vim.notify("Markdown format: only single-line selections supported", vim.log.levels.WARN)
      return
    end

    local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
    local selected = line:sub(start_col, end_col)

    -- Check if the selected text itself is wrapped
    local sel_wrapped = false
    if #selected > 2 * len and selected:sub(1, len) == delim and selected:sub(-len) == delim then
      sel_wrapped = true
      if delim == "*" then
        if selected:sub(len + 1, len + 1) == "*" or selected:sub(#selected - len, #selected - len) == "*" then
          sel_wrapped = false
        end
      end
    end

    if sel_wrapped then
      -- Remove delimiters from inside the selection
      local unwrapped = selected:sub(len + 1, #selected - len)
      local new_line = line:sub(1, start_col - 1) .. unwrapped .. line:sub(end_col + 1)
      vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
      return
    end

    -- Check if delimiters exist just outside the selection
    local pre = line:sub(math.max(1, start_col - len), start_col - 1)
    local post = line:sub(end_col + 1, math.min(#line, end_col + len))
    if pre == delim and post == delim then
      local new_line = line:sub(1, start_col - len - 1) .. selected .. line:sub(end_col + len + 1)
      vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
    else
      -- Wrap selection
      local wrapped = delim .. selected .. delim
      local new_line = line:sub(1, start_col - 1) .. wrapped .. line:sub(end_col + 1)
      vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
    end
  end
end

-- Toggle bold: **text**
map("<leader>mb", function() toggle_markup("**", "n") end, "Toggle bold")
vmap("<leader>mb", function() toggle_markup("**", "v") end, "Toggle bold")

-- Toggle italic: *text*
map("<leader>mi", function() toggle_markup("*", "n") end, "Toggle italic")
vmap("<leader>mi", function() toggle_markup("*", "v") end, "Toggle italic")

-- Toggle strikethrough: ~~text~~
map("<leader>ms", function() toggle_markup("~~", "n") end, "Toggle strikethrough")
vmap("<leader>ms", function() toggle_markup("~~", "v") end, "Toggle strikethrough")

-- Toggle inline code: `text`
map("<leader>mc", function() toggle_markup("`", "n") end, "Toggle inline code")
vmap("<leader>mc", function() toggle_markup("`", "v") end, "Toggle inline code")

-- =============================================================================
-- Quick Link Creation
-- =============================================================================

--- Create a markdown link [text](url) from visual selection, prompting for URL.
local function create_md_link()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row ~= end_row then
    vim.notify("Link creation: only single-line selections supported", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
  local selected = line:sub(start_col, end_col)

  vim.ui.input({ prompt = "URL: " }, function(url)
    if not url or url == "" then
      return
    end
    local link = "[" .. selected .. "](" .. url .. ")"
    local new_line = line:sub(1, start_col - 1) .. link .. line:sub(end_col + 1)
    vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
  end)
end

--- Create a wikilink [[text]] from visual selection (toggle on/off).
local function create_wikilink()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row ~= end_row then
    vim.notify("Link creation: only single-line selections supported", vim.log.levels.WARN)
    return
  end

  local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
  local selected = line:sub(start_col, end_col)

  -- Toggle: if already wrapped in [[...]], unwrap
  local pre2 = line:sub(math.max(1, start_col - 2), start_col - 1)
  local post2 = line:sub(end_col + 1, math.min(#line, end_col + 2))
  if pre2 == "[[" and post2 == "]]" then
    local new_line = line:sub(1, start_col - 3) .. selected .. line:sub(end_col + 3)
    vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
  else
    local link = "[[" .. selected .. "]]"
    local new_line = line:sub(1, start_col - 1) .. link .. line:sub(end_col + 1)
    vim.api.nvim_buf_set_lines(0, start_row - 1, start_row, false, { new_line })
  end
end

vmap("<leader>mk", create_md_link, "Create [text](url) link")
vmap("<leader>mK", create_wikilink, "Create [[wikilink]]")

-- =============================================================================
-- Paste Clipboard Image
-- =============================================================================

map("<leader>mp", function()
  require("andrew.vault.images").paste_image()
end, "Paste clipboard image")

-- =============================================================================
-- Toggle Heading Level
-- =============================================================================

--- Set current line to heading level N, or remove heading if already at that level.
--- @param level number  Heading level (1-6)
local function toggle_heading(level)
  local line = vim.api.nvim_get_current_line()
  local prefix = string.rep("#", level) .. " "

  local existing_hashes, rest = line:match("^(#+)%s+(.*)")
  if existing_hashes then
    if #existing_hashes == level then
      -- Same level: remove heading
      vim.api.nvim_set_current_line(rest)
    else
      -- Different level: change to requested level
      vim.api.nvim_set_current_line(prefix .. rest)
    end
  else
    -- No heading: add heading prefix (strip leading whitespace)
    local trimmed = line:match("^%s*(.*)$")
    vim.api.nvim_set_current_line(prefix .. trimmed)
  end
end

for level = 1, 6 do
  map("<leader>m" .. level, function()
    toggle_heading(level)
  end, "Heading " .. level)
end
```

---

## Which-Key Registration

The `<leader>m` group is currently registered in `lua/andrew/plugins/which-key.lua`
as "Make/Build". In markdown buffers the `<leader>m` prefix is used exclusively for
markdown operations. There are two options:

### Option A: Rename the Global Group (Recommended)

Change the which-key registration to be more generic, since the prefix is
context-dependent:

```lua
-- In lua/andrew/plugins/which-key.lua, change:
{ "<leader>m", group = "Make/Build" },
-- To:
{ "<leader>m", group = "Make/Markdown" },
```

### Option B: Add a Buffer-Local Which-Key Override

Add a which-key registration inside `ftplugin/markdown.lua` that overrides
the group name for markdown buffers:

```lua
-- At the end of ftplugin/markdown.lua
local ok, wk = pcall(require, "which-key")
if ok then
  wk.add({
    { "<leader>m", group = "Markdown", buffer = 0 },
  })
end
```

Option B is preferred if the "Make/Build" label is important to preserve for
non-markdown buffers.

---

## Testing

### Manual Test Plan

Each keybinding should be tested in a markdown buffer. Open a test file:

```
nvim /tmp/test-markdown-bindings.md
```

With this content:

```markdown
# Test File

This is a test word for formatting.

Here is another line with multiple words to test.

An existing **bold word** and *italic word* and ~~struck~~ and `code`.

## Section Two

Some text to link.
```

#### Bold (`<leader>mb`)

1. **Normal mode add**: Place cursor on "test", press `<leader>mb`.
   Expected: line becomes `This is a **test** word for formatting.`
2. **Normal mode remove**: Place cursor on "bold" inside `**bold word**`,
   press `<leader>mb`. Note: cursor must be on the full delimited region
   (between the `**` markers). Expected: `**` markers removed.
3. **Visual mode add**: Select "multiple words" with `viw` or `v`,
   press `<leader>mb`. Expected: `**multiple words**`.
4. **Visual mode remove**: Select `**bold word**` (including markers),
   press `<leader>mb`. Expected: markers removed.

#### Italic (`<leader>mi`)

1. Same tests as bold but with single `*`.
2. **Edge case**: Test on an already-bold word (`**word**`). Pressing
   `<leader>mi` should NOT strip one `*` from the bold markers.

#### Strikethrough (`<leader>ms`)

1. Normal mode: cursor on "struck" inside `~~struck~~`, press `<leader>ms`.
   Expected: `~~` removed.
2. Visual mode: select "words", press `<leader>ms`. Expected: `~~words~~`.

#### Inline Code (`<leader>mc`)

1. Normal mode: cursor on "code" inside `` `code` ``, press `<leader>mc`.
   Expected: backticks removed.
2. Visual mode: select text, press `<leader>mc`. Expected: backticks added.

#### Markdown Link (`<leader>mk`)

1. Select "text to link" in visual mode, press `<leader>mk`.
2. Enter `https://example.com` at the prompt.
3. Expected: `[text to link](https://example.com)`.
4. Press Escape at the prompt: no change should occur.

#### Wikilink (`<leader>mK`)

1. Select "Some text" in visual mode, press `<leader>mK`.
   Expected: `[[Some text]]`.
2. Select `Some text` again (now inside `[[...]]`), press `<leader>mK`.
   Expected: `[[` and `]]` removed.

#### Paste Image (`<leader>mp`)

1. Copy an image to clipboard (e.g., screenshot).
2. Press `<leader>mp` in a vault markdown file.
3. Expected: `![](attachments/img-YYYYMMDD-HHMMSS.png)` inserted at cursor.
4. Verify the file exists in the vault's `attachments/` directory.
5. Test with empty clipboard: should show error notification.

#### Heading Levels (`<leader>m1` through `<leader>m6`)

1. On a plain line "Some text", press `<leader>m1`.
   Expected: `# Some text`.
2. Press `<leader>m3`. Expected: `### Some text`.
3. Press `<leader>m3` again. Expected: `Some text` (heading removed).
4. On line `## Existing Heading`, press `<leader>m4`.
   Expected: `#### Existing Heading`.

### Automated Verification

Run `:checkhealth` after adding the bindings to confirm no errors. Then verify
all buffer-local mappings are registered:

```vim
:verbose map <leader>m
```

This should list all `<leader>m` prefixed mappings for the current markdown
buffer including both the existing (fold, checkbox, footnote) and new
(bold, italic, strikethrough, code, link, heading) bindings.

---

## Integration Notes

### Relationship to nvim-surround

The `nvim-surround` plugin (configured in `lua/andrew/plugins/surround.lua`)
already provides general-purpose surround operations (`ysiw*` for italic,
`ysiw2*` is not standard, etc.). However, nvim-surround does not provide
markdown-aware toggle behavior. The keybindings defined here are specifically
optimized for markdown:

- They toggle (add OR remove) rather than only adding.
- They use mnemonic `<leader>m` + letter mappings rather than operator-pending
  surround grammar.
- They handle the `*` vs `**` ambiguity that nvim-surround does not address.

The two systems are complementary, not conflicting.

### Relationship to vault/images.lua

The `<leader>mp` binding is a convenience alias for the existing `<leader>vp`
binding from `vault/images.lua`. Both call `M.paste_image()`. Having both
provides discoverability under both the vault (`<leader>v`) and markdown
(`<leader>m`) prefixes.

### File Location

All new code goes into `ftplugin/markdown.lua` because:

1. It keeps all markdown-specific keybindings in one file.
2. `ftplugin/` files are automatically loaded by Neovim for the matching
   filetype, ensuring bindings are buffer-local.
3. The existing `map()` helper function defined at the top of the file is
   reused for normal-mode bindings.
4. A new `vmap()` helper is added for visual-mode bindings following the
   same pattern.

### Potential `<leader>m` Conflicts

The `fortran-build.lua` plugin defines global `<leader>mb`, `<leader>mc`,
`<leader>md`, `<leader>mr`, `<leader>ma`, and `<leader>ml` bindings. In markdown
buffers, the buffer-local ftplugin bindings override these globals. This means:

- `<leader>mb` = "Toggle bold" in markdown, "Make: Build" elsewhere
- `<leader>mc` = "Toggle inline code" in markdown, "Make: Clean" elsewhere

This is intentional. The `<leader>m` prefix is context-sensitive by filetype.
If a user needs Make commands while editing markdown, they can use `:Make build`
or the command-line equivalents directly.
