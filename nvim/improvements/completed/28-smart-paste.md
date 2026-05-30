# 28 — Smart Paste (URL/Note as Link)

## Problem

When editing markdown in the vault, a very common workflow is: select some text, then paste a URL from the clipboard to turn the selection into a link. Currently, this requires a multi-step manual process:

1. Select the text in visual mode.
2. Press `<leader>mk` to invoke the "create markdown link" helper.
3. Type or paste the URL into the `vim.ui.input` prompt.
4. Press Enter to confirm.

This is three interactions for what should be a single paste operation. Every modern markdown editor (Obsidian, Typora, VS Code with Markdown All in One, Notion) detects when the clipboard contains a URL and the user pastes over a selection, automatically wrapping the selection as `[selected text](url)`. The current Neovim config has no equivalent.

The problem is compounded in a vault context: if the clipboard contains a vault note name rather than a URL, the user might want `[[note|selected text]]` instead. There is no mechanism for this at all today.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| `<leader>mk` | Visual mode: prompts for URL, creates `[text](url)` | `ftplugin/markdown.lua:294-316` |
| `<leader>mK` | Visual mode: wraps selection as `[[text]]` (toggle) | `ftplugin/markdown.lua:319-344` |
| `p` / `P` in visual mode | Default Vim behavior: replaces selection with register contents | Built-in |
| `vault_index:resolve_name()` | Resolves a note name to absolute path(s) via name/alias index | `lua/andrew/vault/vault_index.lua:961-968` |
| `wikilinks.resolve_link()` | Wraps vault index resolution with closest-path heuristic | `lua/andrew/vault/wikilinks.lua:59-68` |

### What Is Missing

1. No **auto-detection** of URL content in the clipboard when pasting over a visual selection.
2. No **auto-wrapping** of `[selection](clipboard_url)` on visual paste.
3. No **vault note detection** in the clipboard for automatic `[[note|selection]]` creation.
4. No **explicit "paste as link"** keymap for when the user wants the link behavior on demand without relying on auto-detection.
5. The existing `<leader>mk` requires an interactive prompt — it cannot consume the clipboard directly.

---

## Goal

1. When `p` or `P` is pressed in visual mode in a markdown buffer, and the clipboard (`+` register) contains a URL, replace the selection with `[selected text](url)` instead of performing a raw paste.
2. When the clipboard contains a vault note name (resolvable via vault index), replace the selection with `[[note|selected text]]`.
3. When the clipboard contains neither a URL nor a vault note name, fall through to default visual paste behavior (replace selection with clipboard contents).
4. Provide `<leader>mP` as an explicit "paste as link" keymap that always attempts the smart behavior (useful when auto-paste is disabled or for non-`p` workflows).
5. Work correctly in both characterwise visual (`v`) and linewise visual (`V`) modes, with linewise mode operating on the first line of the selection.
6. Provide a buffer-local variable `b:smart_paste_auto` (default `true`) to let users disable auto-detection per buffer while keeping `<leader>mP` available.
7. URL detection must handle: `http://`, `https://`, bare `www.` prefixes, and common TLD patterns without false positives on partial text.

---

## Approach

### Architecture

The implementation adds a small self-contained utility module `lua/andrew/utils/smart-paste.lua` that encapsulates:

1. **URL detection** — a robust pattern matching function.
2. **Vault note detection** — leverages the existing vault index singleton.
3. **Paste-as-link logic** — the core function that reads the clipboard, detects content type, and performs the appropriate text replacement.
4. **Visual mode `p`/`P` overrides** — buffer-local keymaps registered in `ftplugin/markdown.lua`.

Keeping the logic in a utility module (rather than inlining it in `ftplugin/markdown.lua`) allows it to be tested independently and potentially reused for other filetypes.

### URL Detection

The URL pattern must handle:

| Input | Should Match? | Reason |
|-------|:---:|--------|
| `https://example.com` | Yes | Standard HTTPS URL |
| `http://example.com/path?q=1&r=2#frag` | Yes | Full URL with query and fragment |
| `https://www.example.co.uk/page` | Yes | Country-code TLD |
| `www.example.com` | Yes | Bare www (common copy-paste from browsers) |
| `https://192.168.1.1:8080/api` | Yes | IP address with port |
| `ftp://files.example.com` | No | Only http/https (ftp is rare in markdown) |
| `example.com` | No | Too ambiguous without protocol or www |
| `not a url at all` | No | Plain text |
| `file:///home/user/doc.pdf` | No | Local file paths handled differently |
| `https://` | No | Incomplete URL |

The detection function:

```lua
--- Check if a string looks like a URL suitable for a markdown link.
---@param s string  The candidate string (trimmed)
---@return boolean
local function is_url(s)
  -- Must start with http://, https://, or www.
  if s:match("^https?://[%w]") then
    return true
  end
  if s:match("^www%.[%w]") then
    return true
  end
  return false
end
```

This is intentionally simple. The `https?://` prefix is unambiguous. The `www.` prefix covers the remaining common case. We do not attempt to match bare domain names (`example.com`) because the false positive rate is too high — any text containing a period would be at risk.

### Vault Note Detection

After URL detection fails, the clipboard content is checked against the vault index:

```lua
--- Check if a string resolves to a vault note name.
---@param s string  The candidate string (trimmed)
---@return string|nil  The resolved note name (for use in [[name|...]]), or nil
local function resolve_vault_note(s)
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    return nil
  end
  -- Strip .md extension if present (user might copy "Note.md")
  local name = s:gsub("%.md$", "")
  -- Reject if it looks like a path or URL
  if name:match("[/\\]") or name:match("^https?://") or name:match("^www%.") then
    return nil
  end
  local paths = idx:resolve_name(name)
  if paths and #paths > 0 then
    return name
  end
  return nil
end
```

### Content Type Priority

When the clipboard contains text, the detection order is:

1. **URL** (highest priority) — produces `[selection](url)`
2. **Vault note name** — produces `[[note|selection]]`
3. **Neither** — falls through to default paste

This ordering is important because a URL can never be a valid vault note name (it contains `://` and `/` characters, which are rejected by `resolve_vault_note`), so there is no ambiguity between cases 1 and 2.

### Visual Mode Paste Override

The `p` and `P` keys in visual mode are overridden with buffer-local keymaps that:

1. Read the clipboard register (`+`).
2. Trim whitespace and newlines.
3. Test against `is_url()` and `resolve_vault_note()`.
4. If a match is found:
   - Exit visual mode to set `'<` and `'>` marks.
   - Read the selected text from the buffer.
   - Replace the selection with the appropriate link syntax.
5. If no match, feed the original `p` or `P` key to Neovim for default behavior.

### Linewise Visual Mode

In linewise visual mode (`V`), the entire line(s) are selected. Smart paste operates on the **trimmed content of the first selected line** as the link text, and replaces only that portion. If multiple lines are selected, a warning is shown and the operation falls back to default paste — multi-line link text is not valid in markdown.

However, a special case: if exactly one line is selected in linewise mode, the smart paste trims leading/trailing whitespace from the line content and uses that as the link text, preserving the leading whitespace in the output.

---

## Implementation Steps

### Step 1: Create the utility module

**File:** `lua/andrew/utils/smart-paste.lua` (new file)

```lua
--- smart-paste.lua — Smart paste: URL/note-as-link for markdown visual paste
local M = {}

local vault_index = nil  -- lazy-loaded to avoid circular deps

--- Check if a string looks like a URL suitable for a markdown link.
--- Matches http://, https://, and bare www. prefixes.
---@param s string  The candidate string (trimmed, single-line)
---@return boolean
function M.is_url(s)
  if not s or s == "" then
    return false
  end
  -- Standard http(s) URL
  if s:match("^https?://[%w]") then
    return true
  end
  -- Bare www prefix (browsers often copy without protocol)
  if s:match("^www%.[%w]") then
    return true
  end
  return false
end

--- Normalize a URL for use in a markdown link.
--- Adds https:// to bare www. URLs.
---@param url string
---@return string
function M.normalize_url(url)
  if url:match("^www%.") then
    return "https://" .. url
  end
  return url
end

--- Check if a string resolves to a vault note name via the vault index.
--- Returns the canonical note name (without .md) if found, nil otherwise.
---@param s string  The candidate string (trimmed, single-line)
---@return string|nil
function M.resolve_vault_note(s)
  if not s or s == "" then
    return nil
  end
  -- Reject strings that look like URLs or paths
  if s:match("[/\\]") or s:match("^https?://") or s:match("^www%.") then
    return nil
  end
  -- Lazy-load vault_index (avoids requiring it at module load time)
  if not vault_index then
    local ok, vi = pcall(require, "andrew.vault.vault_index")
    if not ok then
      return nil
    end
    vault_index = vi
  end
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    return nil
  end
  -- Strip .md extension if the user copied "Note.md"
  local name = s:gsub("%.md$", "")
  -- Reject empty or whitespace-only after stripping
  if vim.trim(name) == "" then
    return nil
  end
  local paths = idx:resolve_name(name)
  if paths and #paths > 0 then
    return name
  end
  return nil
end

--- Detect what kind of link the clipboard content should produce.
---@param clipboard string  The raw clipboard text
---@return "url"|"note"|nil  The content type
---@return string|nil        The cleaned value (normalized URL or note name)
function M.detect(clipboard)
  if not clipboard then
    return nil, nil
  end
  -- Trim whitespace and collapse to single line
  local trimmed = vim.trim(clipboard)
  -- Reject multi-line clipboard (URLs and note names are single-line)
  if trimmed:find("\n") then
    return nil, nil
  end
  -- Check URL first (higher priority)
  if M.is_url(trimmed) then
    return "url", M.normalize_url(trimmed)
  end
  -- Check vault note name
  local note_name = M.resolve_vault_note(trimmed)
  if note_name then
    return "note", note_name
  end
  return nil, nil
end

--- Get the visual selection text and position from '< '> marks.
--- Must be called AFTER exiting visual mode (marks are set).
---@return { text: string, row: number, start_col: number, end_col: number }|nil
local function get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2], start_pos[3]
  local end_row, end_col = end_pos[2], end_pos[3]

  if start_row ~= end_row then
    return nil  -- multi-line not supported for link text
  end

  local line = vim.api.nvim_buf_get_lines(0, start_row - 1, start_row, false)[1]
  if not line then
    return nil
  end

  -- Handle linewise selection: end_col can be very large (2147483647)
  if end_col >= #line then
    end_col = #line
  end

  local text = line:sub(start_col, end_col)
  return {
    text = text,
    row = start_row,
    start_col = start_col,
    end_col = end_col,
    line = line,
  }
end

--- Perform smart paste: replace visual selection with a link using clipboard content.
--- Returns true if a smart paste was performed, false if it should fall through.
---@param opts? { force: boolean }  If force=true, always attempt (for <leader>mP)
---@return boolean
function M.smart_paste(opts)
  opts = opts or {}

  -- Check per-buffer opt-out (only for auto mode, not forced)
  if not opts.force then
    local auto = vim.b.smart_paste_auto
    if auto == false then
      return false
    end
  end

  -- Read the system clipboard (+ register)
  local clipboard = vim.fn.getreg("+")
  if not clipboard or clipboard == "" then
    if opts.force then
      vim.notify("Smart paste: clipboard is empty", vim.log.levels.WARN)
    end
    return false
  end

  local content_type, value = M.detect(clipboard)
  if not content_type then
    if opts.force then
      vim.notify("Smart paste: clipboard is not a URL or vault note", vim.log.levels.WARN)
    end
    return false
  end

  -- Get the visual selection (marks must be set by exiting visual mode first)
  local sel = get_visual_selection()
  if not sel then
    if opts.force then
      vim.notify("Smart paste: multi-line selections not supported for links", vim.log.levels.WARN)
    end
    return false
  end

  -- Build the replacement text
  local replacement
  if content_type == "url" then
    replacement = "[" .. sel.text .. "](" .. value .. ")"
  elseif content_type == "note" then
    replacement = "[[" .. value .. "|" .. sel.text .. "]]"
  end

  -- Replace the selection on the line
  local new_line = sel.line:sub(1, sel.start_col - 1) .. replacement .. sel.line:sub(sel.end_col + 1)
  vim.api.nvim_buf_set_lines(0, sel.row - 1, sel.row, false, { new_line })

  -- Position cursor at end of the inserted link
  local end_pos = sel.start_col - 1 + #replacement - 1
  vim.api.nvim_win_set_cursor(0, { sel.row, end_pos })

  -- Notify (briefly) what was done
  local type_label = content_type == "url" and "URL" or "note"
  vim.notify("Smart paste: linked as " .. type_label, vim.log.levels.INFO)

  return true
end

return M
```

### Step 2: Add visual mode `p`/`P` overrides in ftplugin

**File:** `ftplugin/markdown.lua`

Add the following section after the existing "Spell Checking Toggle" block (after line 399) and before the which-key override block:

```lua
-- =============================================================================
-- Smart Paste: URL/note detection on visual paste
-- =============================================================================

local smart_paste = require("andrew.utils.smart-paste")

-- Override visual mode p/P to detect URLs and vault notes in clipboard
for _, key in ipairs({ "p", "P" }) do
  vim.keymap.set("x", key, function()
    -- Exit visual mode to set '< '> marks
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    vim.schedule(function()
      local did_smart = smart_paste.smart_paste()
      if not did_smart then
        -- Fall through to default paste behavior.
        -- Re-select the same range and paste normally.
        vim.cmd("normal! gv" .. key)
      end
    end)
  end, { buffer = true, desc = "Smart paste (auto-link)" })
end

-- Explicit "paste as link" (always attempts smart behavior)
vmap("<leader>mP", function()
  smart_paste.smart_paste({ force = true })
end, "Paste clipboard as link")
```

### Step 3: Add which-key hint for the new keymap

**File:** `ftplugin/markdown.lua`

Inside the existing which-key `wk.add()` block (around line 407), add the new mapping description. The `<leader>mP` will automatically appear via the keymap `desc` field, but for discoverability in the `<leader>m` group, no additional which-key registration is needed — the buffer-local keymap's `desc` is picked up automatically.

### Step 4: Add buffer-local toggle command

**File:** `ftplugin/markdown.lua`

Add alongside the smart paste section:

```lua
-- Toggle auto smart paste for the current buffer
vim.api.nvim_buf_create_user_command(0, "SmartPasteToggle", function()
  local current = vim.b.smart_paste_auto
  if current == nil then
    current = true  -- default is enabled
  end
  vim.b.smart_paste_auto = not current
  vim.notify(
    "Smart paste auto: " .. (vim.b.smart_paste_auto and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end, { desc = "Toggle automatic smart paste for this buffer" })
```

---

## Complete Additions to `ftplugin/markdown.lua`

The following block is inserted after line 399 (the spell check toggle) and before the which-key block (line 405):

```lua
-- =============================================================================
-- Smart Paste: URL/note detection on visual paste
-- =============================================================================

local smart_paste = require("andrew.utils.smart-paste")

-- Override visual mode p/P to detect URLs and vault notes in clipboard
for _, key in ipairs({ "p", "P" }) do
  vim.keymap.set("x", key, function()
    -- Exit visual mode to set '< '> marks
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", false)
    vim.schedule(function()
      local did_smart = smart_paste.smart_paste()
      if not did_smart then
        -- Fall through to default paste behavior.
        -- Re-select the same range and paste normally.
        vim.cmd("normal! gv" .. key)
      end
    end)
  end, { buffer = true, desc = "Smart paste (auto-link)" })
end

-- Explicit "paste as link" — always attempts smart behavior, warns on failure
vmap("<leader>mP", function()
  smart_paste.smart_paste({ force = true })
end, "Paste clipboard as link")

-- Buffer-local command to toggle auto smart paste
vim.api.nvim_buf_create_user_command(0, "SmartPasteToggle", function()
  local current = vim.b.smart_paste_auto
  if current == nil then current = true end
  vim.b.smart_paste_auto = not current
  vim.notify(
    "Smart paste auto: " .. (vim.b.smart_paste_auto and "ON" or "OFF"),
    vim.log.levels.INFO
  )
end, { desc = "Toggle automatic smart paste for this buffer" })
```

---

## Testing

### Manual Test Plan

#### Setup

Open a markdown file in the vault:

```vim
:edit ~/vault/test-smart-paste.md
```

With this content:

```markdown
# Smart Paste Test

Here is some example text to select.

Another line with different words.

A reference to a known note name.
```

#### Test 1: URL paste over selection

1. Copy a URL to the system clipboard: `echo -n "https://example.com/page" | xclip -selection clipboard`
2. In the markdown buffer, visually select `example text` (the words on line 3).
3. Press `p`.
4. **Expected:** The line becomes `Here is some [example text](https://example.com/page) to select.`
5. A notification appears: "Smart paste: linked as URL".

#### Test 2: Bare www URL paste

1. Copy: `echo -n "www.github.com/user/repo" | xclip -selection clipboard`
2. Visually select `different words` on line 5.
3. Press `p`.
4. **Expected:** `Another line with [different words](https://www.github.com/user/repo).`
5. The `www.` URL is normalized to `https://www.`.

#### Test 3: Vault note name paste

1. Copy a known vault note name: `echo -n "Daily Notes" | xclip -selection clipboard`
   (assuming "Daily Notes" exists in the vault index).
2. Visually select `known note name` on line 7.
3. Press `p`.
4. **Expected:** `A reference to a [[Daily Notes|known note name]].`
5. Notification: "Smart paste: linked as note".

#### Test 4: Plain text fallthrough

1. Copy plain text: `echo -n "just some words" | xclip -selection clipboard`
2. Visually select `example text`.
3. Press `p`.
4. **Expected:** Normal paste behavior — `example text` is replaced with `just some words`.
5. No notification appears.

#### Test 5: Multi-line clipboard fallthrough

1. Copy multi-line text: `printf "line one\nline two" | xclip -selection clipboard`
2. Visually select some text.
3. Press `p`.
4. **Expected:** Normal paste behavior (multi-line clipboard is not a URL or note name).

#### Test 6: Explicit `<leader>mP` keymap

1. Copy a URL to clipboard.
2. Visually select text.
3. Press `<leader>mP`.
4. **Expected:** Same as Test 1 — creates a markdown link.

#### Test 7: Explicit `<leader>mP` with non-URL clipboard

1. Copy plain text to clipboard.
2. Visually select text.
3. Press `<leader>mP`.
4. **Expected:** Warning notification "Smart paste: clipboard is not a URL or vault note". Selection is unchanged.

#### Test 8: Auto-paste toggle

1. Run `:SmartPasteToggle`. Notification: "Smart paste auto: OFF".
2. Copy a URL to clipboard, select text, press `p`.
3. **Expected:** Normal paste (smart paste is disabled).
4. Press `u` to undo, then press `<leader>mP`.
5. **Expected:** Smart paste works (explicit keymap ignores the toggle).
6. Run `:SmartPasteToggle` again. Notification: "Smart paste auto: ON".
7. Copy URL, select text, press `p`.
8. **Expected:** Smart paste is active again.

#### Test 9: Linewise visual mode

1. Copy a URL to clipboard.
2. Press `V` to enter linewise visual mode on a single line.
3. Press `p`.
4. **Expected:** The line's trimmed text content becomes the link text, wrapped as `[content](url)`.

#### Test 10: Multi-line visual selection fallthrough

1. Copy a URL to clipboard.
2. Select multiple lines with `V` (linewise) across 2+ lines.
3. Press `p`.
4. **Expected:** Falls through to normal paste. Multi-line selections are not valid link text.

### Automated Verification

```vim
:verbose xmap p
:verbose xmap P
:verbose vmap <leader>mP
```

All three should show buffer-local mappings sourced from `ftplugin/markdown.lua`.

```vim
:lua print(require("andrew.utils.smart-paste").is_url("https://example.com"))
-- true
:lua print(require("andrew.utils.smart-paste").is_url("not a url"))
-- false
:lua print(require("andrew.utils.smart-paste").is_url("www.example.com"))
-- true
:lua print(require("andrew.utils.smart-paste").is_url("ftp://example.com"))
-- false
:lua print(require("andrew.utils.smart-paste").normalize_url("www.example.com"))
-- https://www.example.com
:lua print(require("andrew.utils.smart-paste").normalize_url("https://example.com"))
-- https://example.com
```

---

## Risks & Mitigations

### Risk 1: Overriding `p`/`P` in visual mode breaks normal paste workflows

**Severity:** Medium

Visual paste (`p` in visual mode) is a core Vim operation used constantly. If the smart paste detection has false positives, users will be surprised by text being wrapped in link syntax when they expected a raw paste.

**Mitigation:**
- URL detection requires an explicit `http://`, `https://`, or `www.` prefix. These are unambiguous and will not match normal text.
- Vault note detection requires the clipboard content to exactly match a note name (or alias) in the vault index. Random text will not match.
- Multi-line clipboard content is always rejected (falls through to default paste).
- The `b:smart_paste_auto` variable provides a per-buffer escape hatch via `:SmartPasteToggle`.
- If all detection fails, the fallback uses `gv` + original key to reproduce exact default behavior.

### Risk 2: `gv` + `p` fallback may not perfectly replicate default visual paste

**Severity:** Low

The fallback `vim.cmd("normal! gv" .. key)` re-selects the visual area and pastes. This should behave identically to the original `p`/`P` in most cases, but edge cases involving register types (characterwise vs linewise vs blockwise) could differ.

**Mitigation:**
- The `gv` command restores the exact previous visual selection, including mode (characterwise/linewise/blockwise).
- The `p`/`P` command after `gv` operates in visual mode, which is the same context as the original operation.
- If issues arise, the fallback can be changed to use `vim.api.nvim_feedkeys("gv" .. key, "n", false)` which processes the keys through Neovim's normal keymap engine without recursion (the `n` flag prevents remapping).

### Risk 3: Vault index not ready when pasting

**Severity:** Low

If the vault index has not finished building (e.g., on first launch with a large vault), `resolve_vault_note()` returns `nil`, and the note detection silently fails. URLs still work.

**Mitigation:**
- The `vault_index.current()` check returns `nil` gracefully when the singleton is not initialized.
- The `idx:is_ready()` check returns `false` during async builds.
- No error is thrown — the detection simply falls through to default paste.
- Once the index is ready (typically within seconds of launch), note detection works.

### Risk 4: Clipboard contains a URL that the user wants to paste literally

**Severity:** Low-Medium

Sometimes the user might want to paste a raw URL (e.g., into a code block or a URL list) rather than create a link.

**Mitigation:**
- This only triggers in visual mode (paste over a selection). If the user is pasting a URL without a selection (normal mode `p`), it works normally.
- The `:SmartPasteToggle` command disables auto-detection per buffer.
- The user can undo (`u`) immediately if the smart paste was unwanted, then use `:SmartPasteToggle` + `p` to paste raw.
- In code blocks (fenced or indented), users typically do not visually select text before pasting, so this is unlikely to trigger.

### Risk 5: Interaction with existing `<leader>mp` (paste clipboard image)

**Severity:** None

The new `<leader>mP` (uppercase P) is distinct from the existing `<leader>mp` (lowercase p) which pastes clipboard images. The keys are different and the behaviors are complementary: `<leader>mp` handles image data in the clipboard, while `<leader>mP` handles text URLs/note names.

### Risk 6: Register conflict — `p` uses unnamed register, smart paste reads `+`

**Severity:** Low

Default visual `p` pastes from the unnamed register (`""`), which may differ from the system clipboard (`"+`). The smart paste reads `+` (system clipboard) for URL/note detection, but the fallback uses the default `p` which pastes from `""`.

**Mitigation:**
- This is intentional. The URL/note detection specifically checks the system clipboard because that is where copied URLs and note names live (from browsers, file managers, etc.).
- If the system clipboard does not contain a URL/note, the fallback `p` pastes from whatever register the user intended (typically `""` which is the last yank/delete).
- The two-register model means: system clipboard URLs trigger smart behavior, while internal yanks paste normally. This matches user expectations.

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/utils/smart-paste.lua` | **New file** — URL detection, vault note detection, smart paste logic |
| `ftplugin/markdown.lua` | Add visual `p`/`P` overrides, `<leader>mP` keymap, `:SmartPasteToggle` command |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `vault_index.lua` | Note name resolution via `resolve_name()` | No (graceful fallback if unavailable) |
| `ftplugin/markdown.lua` | Registration of buffer-local keymaps | Yes |
| `which-key.nvim` | Auto-discovers `desc` from keymap registration | No (keymaps work without it) |
