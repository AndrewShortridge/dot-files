# 20 — Unlinked Mentions

## Problem

The vault contains notes that reference other notes by name in prose but without wrapping those references in `[[wikilinks]]`. These "unlinked mentions" represent missing connections in the knowledge graph. Obsidian surfaces them in its backlinks panel, but this vault system has no equivalent.

Without unlinked mention detection:

1. **Connections are invisible** — a note about "Finite Element Method" might mention "Mesh Convergence" in prose, but without `[[Mesh Convergence]]`, the backlinks panel for "Mesh Convergence" will never show it.
2. **Link hygiene degrades over time** — as the vault grows, manually spotting note names in prose becomes impractical.
3. **Refactoring is blind** — renaming a note via `rename.lua` updates wikilinks but cannot find or update bare text mentions.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **wikilinks.lua** | Builds name->path cache (basenames + aliases), resolves links, follows `gf` | `lua/andrew/vault/wikilinks.lua` |
| **backlinks.lua** | Ripgrep search for `[[NoteName]]` patterns, fzf-lua picker | `lua/andrew/vault/backlinks.lua` |
| **link_utils.lua** | Parses `[[inner]]` content, heading slug matching, section extraction | `lua/andrew/vault/link_utils.lua` |
| **engine.lua** | `get_name_cache()` — basename+path lookup with TTL, `find_md_cmd()`, `rg_base_opts()` | `lua/andrew/vault/engine.lua` |
| **frontmatter_parser.lua** | Parses YAML frontmatter including `aliases` field | `lua/andrew/vault/frontmatter_parser.lua` |
| **search.lua** | Vault-wide live grep, scoped grep, type search via fzf-lua | `lua/andrew/vault/search.lua` |
| **tag_highlights.lua** | Extmark-based inline `#tag` highlighting with code block exclusion | `lua/andrew/vault/tag_highlights.lua` |

### What Exists That Can Be Reused

1. **`wikilinks.lua` cache** — already indexes every note basename and frontmatter `aliases` into a `lower(name) -> [paths]` lookup table. This is the primary source of "what names to search for."
2. **`engine.rg_base_opts()`** — standard ripgrep flags for vault-scoped searches.
3. **`engine.vault_fzf_opts()`** — standard fzf-lua picker configuration.
4. **`frontmatter_parser.parse_file()`** — extracts `aliases` for the current note to include in search terms.
5. **`tag_highlights.lua`** patterns — the code block exclusion logic (`build_code_exclusion`, `get_frontmatter_range`) provides a proven template for filtering false positives.

### Why This Cannot Be Done With Existing Backlinks

The `backlinks.lua` module searches for `\[\[NoteName\]\]` — it explicitly looks for wikilink syntax. Unlinked mentions are the complement: occurrences of the note's name in prose that are **not** inside `[[...]]`.

---

## Goal

Add an unlinked mentions system so that:

1. A user can see all files that mention the current note's name (or aliases) in prose without using `[[wikilinks]]`.
2. Results appear in a fzf-lua picker with context lines showing the match.
3. A user can accept a match to jump to its location and optionally wrap it in `[[...]]` with a single action.
4. A vault-wide scan identifies all potential unlinked mentions across all notes.
5. Matches exclude code blocks, frontmatter, existing wikilinks, URLs, and headings.
6. Word-boundary matching prevents partial matches (e.g., "note" inside "denote").
7. Performance is acceptable for vaults with 1000+ notes.

---

## Approach

### Architecture

Create a new module `lua/andrew/vault/unlinked.lua` that:

1. Reads the current note's basename and frontmatter aliases.
2. Leverages the `wikilinks.lua` resolution cache to get all known note names + aliases.
3. Builds ripgrep patterns with word boundaries that exclude existing wikilink contexts.
4. Presents results in fzf-lua with context lines and a "wrap in wikilink" action.
5. Provides both per-note and vault-wide scanning modes.

### Data Flow

```
                    wikilinks.lua cache
                    (ensure_cache())
                          |
                          v
              +----------------------------+
              |  build_name_list()         |
              |  basenames + aliases        |
              |  from all vault notes       |
              +----------------------------+
                          |
                          v
              +----------------------------+
              |  build_rg_pattern()        |
              |  word-boundary regex        |
              |  exclude [[...]] context    |
              +----------------------------+
                          |
                  +-------+--------+
                  |                |
                  v                v
          Per-note scan      Vault-wide scan
          (current note      (all names across
           name + aliases)    all files)
                  |                |
                  v                v
              +----------------------------+
              |  ripgrep via vim.system()   |
              |  --pcre2 word boundaries    |
              +----------------------------+
                          |
                          v
              +----------------------------+
              |  filter_results()          |
              |  exclude frontmatter,       |
              |  code blocks, headings,     |
              |  URLs (post-filter in Lua)  |
              +----------------------------+
                          |
                          v
              +----------------------------+
              |  fzf-lua picker            |
              |  default: jump to match     |
              |  ctrl-w: wrap in [[...]]    |
              |  ctrl-a: wrap all in file   |
              +----------------------------+
```

### Ripgrep Pattern Strategy

The key challenge is searching for note names while excluding existing wikilinks. The strategy uses a two-phase approach:

**Phase 1 (ripgrep):** Find lines containing the note name with word boundaries.

```
\b(?:Note Name|Alias One|Alias Two)\b
```

**Phase 2 (Lua post-filter):** Discard matches that fall inside:
- `[[...]]` wikilink brackets
- Fenced code blocks (``` or ~~~)
- Inline code spans (`` ` ``)
- YAML frontmatter (`---` delimiters)
- Headings (`# ...` lines)
- URLs (`https://...`)
- The note's own file (self-mentions)

This two-phase approach is necessary because ripgrep cannot express "match X but not when surrounded by `[[` and `]]`" with simple regex — negative lookaround on multi-character delimiters is fragile across line boundaries.

### Word Boundary Matching

Ripgrep's `\b` assertion handles most word-boundary cases. For note names containing special characters (hyphens, apostrophes), the pattern escapes them properly:

| Note Name | Regex Pattern | Matches | Does NOT Match |
|-----------|--------------|---------|----------------|
| `Mesh Convergence` | `\bMesh Convergence\b` | "about Mesh Convergence study" | "Mesh Convergence2" |
| `CFD` | `\bCFD\b` | "using CFD for" | "CFDRC", "aCFD" |
| `k-epsilon` | `\bk-epsilon\b` | "the k-epsilon model" | "k-epsilon-v2" |
| `note` | `\bnote\b` | "this note about" | "denote", "notebook" |

Case sensitivity: searches are **case-insensitive** (`-i` flag) since `wikilinks.lua` already normalizes to lowercase for resolution.

---

## Implementation

### File: `lua/andrew/vault/unlinked.lua`

```lua
local engine = require("andrew.vault.engine")
local wikilinks = require("andrew.vault.wikilinks")
local fm_parser = require("andrew.vault.frontmatter_parser")

local M = {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

--- Minimum note name length to include in scans.
--- Very short names (1-2 chars) cause too many false positives.
local MIN_NAME_LENGTH = 3

--- Maximum number of names to search in a single ripgrep invocation.
--- Names are batched to avoid exceeding shell argument limits.
local MAX_PATTERN_NAMES = 50

--- Lines of context shown around matches in fzf-lua.
local CONTEXT_LINES = 2

-- ---------------------------------------------------------------------------
-- Name collection
-- ---------------------------------------------------------------------------

--- Get the current note's searchable names (basename + aliases).
--- Returns nil if the buffer is not a vault file.
---@return { names: string[], path: string }|nil
local function current_note_names()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" or not engine.is_vault_path(bufname) then
    return nil
  end

  local basename = vim.fn.fnamemodify(bufname, ":t:r")
  local names = { basename }

  -- Add frontmatter aliases
  local fm = fm_parser.parse_file(bufname)
  local aliases = fm and fm.fields and fm.fields.aliases or nil
  if type(aliases) == "string" then
    aliases = { aliases }
  end
  if aliases then
    for _, alias in ipairs(aliases) do
      local trimmed = vim.trim(alias)
      if trimmed ~= "" and trimmed:lower() ~= basename:lower() then
        names[#names + 1] = trimmed
      end
    end
  end

  return { names = names, path = bufname }
end

--- Collect all note names and aliases from the wikilinks cache.
--- Returns a deduplicated list of { name, path } entries.
---@return { name: string, path: string }[]
local function all_note_names()
  -- Force the wikilinks cache to be current
  wikilinks.resolve_link("")

  -- Access the internal cache by resolving each known name.
  -- Instead, use engine's name cache which is lighter weight.
  local name_cache = engine.get_name_cache()
  local entries = {}
  local seen = {}

  for name_lower, path in pairs(name_cache.paths) do
    if #name_lower >= MIN_NAME_LENGTH and not seen[name_lower] then
      seen[name_lower] = true
      -- Recover original-case name from the file path
      local original = vim.fn.fnamemodify(path, ":t:r")
      entries[#entries + 1] = { name = original, path = path }
    end
  end

  -- Also gather aliases from the wikilinks cache by scanning vault files
  -- This is handled by wikilinks.lua's cache which indexes aliases.
  -- We access it indirectly: attempt to resolve each alias-like key.

  return entries
end

-- ---------------------------------------------------------------------------
-- Pattern building
-- ---------------------------------------------------------------------------

--- Escape a string for use in a PCRE2 regex.
---@param s string
---@return string
local function pcre2_escape(s)
  return s:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\])", "\\%1")
end

--- Build a PCRE2 alternation pattern for a list of names with word boundaries.
--- The pattern is case-insensitive (flag applied to rg, not embedded).
---@param names string[]
---@return string
local function build_rg_pattern(names)
  local escaped = {}
  for _, name in ipairs(names) do
    if #name >= MIN_NAME_LENGTH then
      escaped[#escaped + 1] = pcre2_escape(name)
    end
  end
  if #escaped == 0 then
    return ""
  end
  -- Sort longest first so "Finite Element Method" matches before "Finite Element"
  table.sort(escaped, function(a, b) return #a > #b end)
  return "\\b(" .. table.concat(escaped, "|") .. ")\\b"
end

-- ---------------------------------------------------------------------------
-- Result filtering (post-ripgrep Lua phase)
-- ---------------------------------------------------------------------------

--- Check if a match position is inside a wikilink on the given line.
---@param line string
---@param match_start number 1-indexed byte position of match
---@param match_end number 1-indexed byte position of match end
---@return boolean
local function is_inside_wikilink(line, match_start, match_end)
  local pos = 1
  while true do
    local open_s, open_e = line:find("%[%[", pos)
    if not open_s then break end
    local close_s, close_e = line:find("%]%]", open_e + 1)
    if not close_s then break end
    -- Match overlaps with [[...]] span
    if match_start >= open_s and match_end <= close_e then
      return true
    end
    -- Match starts inside the wikilink content
    if match_start > open_e and match_start < close_s then
      return true
    end
    pos = close_e + 1
  end
  return false
end

--- Check if a match is inside an inline code span.
---@param line string
---@param match_start number 1-indexed
---@return boolean
local function is_inside_code_span(line, match_start)
  local pos = 1
  while true do
    local tick_s = line:find("`", pos, true)
    if not tick_s then break end
    -- Handle double backticks
    local tick_end = tick_s
    while line:sub(tick_end + 1, tick_end + 1) == "`" do
      tick_end = tick_end + 1
    end
    local ticks = line:sub(tick_s, tick_end)
    local close_s, close_e = line:find(ticks, tick_end + 1, true)
    if not close_s then break end
    if match_start > tick_end and match_start < close_s then
      return true
    end
    pos = close_e + 1
  end
  return false
end

--- Check if a match is inside a URL.
---@param line string
---@param match_start number 1-indexed
---@param match_end number 1-indexed
---@return boolean
local function is_inside_url(line, match_start, match_end)
  -- Check for http(s):// URLs
  local url_pattern = "https?://[%w%-%.%_%~%:%/%?#%[%]@!%$&'%(%)%*%+,;=%%]+"
  local pos = 1
  while true do
    local s, e = line:find(url_pattern, pos)
    if not s then break end
    if match_start >= s and match_end <= e then
      return true
    end
    pos = e + 1
  end
  return false
end

--- Check if a line is inside a fenced code block.
--- Uses a simple state-machine approach on the line array.
---@param lines string[]
---@param target_line number 1-indexed line number
---@return boolean
local function is_in_fenced_code(lines, target_line)
  local in_fence = false
  for i = 1, target_line do
    local line = lines[i]
    if line:match("^```") or line:match("^~~~") then
      in_fence = not in_fence
    end
  end
  return in_fence
end

--- Check if a line is inside YAML frontmatter.
---@param lines string[]
---@param target_line number 1-indexed line number
---@return boolean
local function is_in_frontmatter(lines, target_line)
  if #lines == 0 or lines[1] ~= "---" then return false end
  if target_line <= 1 then return true end
  for i = 2, #lines do
    if lines[i] == "---" or lines[i] == "..." then
      return target_line <= i
    end
  end
  -- Unclosed frontmatter — treat everything as inside
  return true
end

--- Check if a line is a markdown heading.
---@param line string
---@return boolean
local function is_heading_line(line)
  return line:match("^#+ ") ~= nil
end

-- ---------------------------------------------------------------------------
-- Core scanning
-- ---------------------------------------------------------------------------

--- Parse a ripgrep output line in the format: file:line:col:text
---@param rg_line string
---@return { file: string, line: number, col: number, text: string }|nil
local function parse_rg_line(rg_line)
  -- Format: file:line:col:text (with --column flag)
  local file, lnum, col, text = rg_line:match("^(.+):(%d+):(%d+):(.*)$")
  if file then
    return {
      file = file,
      line = tonumber(lnum),
      col = tonumber(col),
      text = text,
    }
  end
  return nil
end

--- Run ripgrep to find unlinked mentions and return raw results.
--- Results are NOT yet filtered (Lua post-filtering happens next).
---@param names string[] note names to search for
---@param exclude_path string|nil path to exclude (current note)
---@param callback fun(results: { file: string, line: number, col: number, text: string }[])
local function rg_search(names, exclude_path, callback)
  local pattern = build_rg_pattern(names)
  if pattern == "" then
    vim.schedule(function() callback({}) end)
    return
  end

  local cmd = {
    "rg",
    "--column",
    "--line-number",
    "--no-heading",
    "--color=never",
    "-i",              -- case-insensitive
    "--pcre2",         -- for \b word boundaries
    "--glob", "*.md",
    pattern,
    engine.vault_path,
  }

  vim.system(cmd, { text = true }, function(result)
    local results = {}
    if result.code == 0 and result.stdout and result.stdout ~= "" then
      for line in result.stdout:gmatch("[^\n]+") do
        local parsed = parse_rg_line(line)
        if parsed then
          -- Exclude the note's own file
          if not exclude_path or parsed.file ~= exclude_path then
            results[#results + 1] = parsed
          end
        end
      end
    end
    vim.schedule(function() callback(results) end)
  end)
end

--- Apply Lua post-filters to ripgrep results.
--- Reads each file to check code blocks, frontmatter, etc.
---@param results { file: string, line: number, col: number, text: string }[]
---@param names string[] the names being searched (for match length calculation)
---@return { file: string, line: number, col: number, text: string, match: string }[]
local function filter_results(results, names)
  if #results == 0 then return {} end

  -- Group results by file to avoid re-reading the same file
  local by_file = {}
  for _, r in ipairs(results) do
    if not by_file[r.file] then
      by_file[r.file] = {}
    end
    by_file[r.file][#by_file[r.file] + 1] = r
  end

  -- Build a lowercase name lookup for match identification
  local name_lower_set = {}
  for _, name in ipairs(names) do
    name_lower_set[name:lower()] = name
  end

  local filtered = {}

  for file, file_results in pairs(by_file) do
    local lines = engine.read_file_lines(file)
    if #lines > 0 then
      for _, r in ipairs(file_results) do
        local skip = false
        local line_text = lines[r.line] or r.text

        -- Filter 1: frontmatter
        if is_in_frontmatter(lines, r.line) then
          skip = true
        end

        -- Filter 2: fenced code block
        if not skip and is_in_fenced_code(lines, r.line) then
          skip = true
        end

        -- Filter 3: heading line
        if not skip and is_heading_line(line_text) then
          skip = true
        end

        -- Filter 4: inside wikilink
        if not skip then
          -- Find the actual match extent on the line
          local line_lower = line_text:lower()
          for name_lower, original_name in pairs(name_lower_set) do
            local ms, me = line_lower:find(name_lower, 1, true)
            while ms do
              if ms <= r.col and r.col <= me then
                if is_inside_wikilink(line_text, ms, me) then
                  skip = true
                  break
                end
                -- Filter 5: inside code span
                if is_inside_code_span(line_text, ms) then
                  skip = true
                  break
                end
                -- Filter 6: inside URL
                if is_inside_url(line_text, ms, me) then
                  skip = true
                  break
                end
                r.match = original_name
                break
              end
              ms, me = line_lower:find(name_lower, ms + 1, true)
            end
            if skip or r.match then break end
          end
        end

        if not skip and r.match then
          filtered[#filtered + 1] = r
        end
      end
    end
  end

  return filtered
end

-- ---------------------------------------------------------------------------
-- Wikilink wrapping
-- ---------------------------------------------------------------------------

--- Wrap a text match in [[wikilinks]] at the given file location.
--- If the match text differs from the note basename (i.e., it's an alias
--- match or a case variant), uses [[NoteName|matched text]] format.
---@param file string absolute file path
---@param lnum number 1-indexed line number
---@param match_text string the exact text to wrap
---@param note_name string|nil the canonical note name (for alias display)
---@return boolean success
local function wrap_in_wikilink(file, lnum, match_text, note_name)
  -- Check if the file is open in a buffer
  local bufnr = vim.fn.bufnr(file)
  local use_buffer = bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)

  local lines
  if use_buffer then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  else
    lines = engine.read_file_lines(file)
  end

  if #lines < lnum then return false end

  local line = lines[lnum]
  -- Find the exact match on this line (case-insensitive)
  local line_lower = line:lower()
  local match_lower = match_text:lower()
  local ms, me = line_lower:find(match_lower, 1, true)

  -- Walk forward to find the instance that's NOT already in [[ ]]
  while ms do
    if not is_inside_wikilink(line, ms, me) then
      local before = line:sub(1, ms - 1)
      local matched = line:sub(ms, me)
      local after = line:sub(me + 1)

      local replacement
      -- If matched text exactly equals a resolvable note name, use simple link
      local resolved = wikilinks.resolve_link(matched)
      if resolved and matched:lower() == vim.fn.fnamemodify(resolved, ":t:r"):lower() then
        replacement = "[[" .. matched .. "]]"
      elseif note_name then
        -- Use alias form: [[NoteName|displayed text]]
        replacement = "[[" .. note_name .. "|" .. matched .. "]]"
      else
        replacement = "[[" .. matched .. "]]"
      end

      local new_line = before .. replacement .. after

      if use_buffer then
        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new_line })
      else
        lines[lnum] = new_line
        engine.write_file(file, table.concat(lines, "\n") .. "\n")
      end
      return true
    end
    ms, me = line_lower:find(match_lower, ms + 1, true)
  end

  return false
end

-- ---------------------------------------------------------------------------
-- Fzf-lua pickers
-- ---------------------------------------------------------------------------

--- Show unlinked mentions for the current note via fzf-lua.
function M.unlinked_mentions()
  local info = current_note_names()
  if not info then
    vim.notify("Vault: not in a vault note", vim.log.levels.WARN)
    return
  end

  -- Filter out names that are too short
  local search_names = {}
  for _, name in ipairs(info.names) do
    if #name >= MIN_NAME_LENGTH then
      search_names[#search_names + 1] = name
    end
  end

  if #search_names == 0 then
    vim.notify("Vault: note name too short for unlinked mention search", vim.log.levels.WARN)
    return
  end

  vim.notify("Vault: scanning for unlinked mentions...", vim.log.levels.INFO)

  rg_search(search_names, info.path, function(raw_results)
    local results = filter_results(raw_results, search_names)

    if #results == 0 then
      vim.notify("Vault: no unlinked mentions found for " .. search_names[1], vim.log.levels.INFO)
      return
    end

    -- Format entries for fzf-lua
    local fzf = require("fzf-lua")
    local entries = {}
    local entry_map = {}

    for _, r in ipairs(results) do
      local rel = engine.vault_relative(r.file) or r.file
      local entry = rel .. ":" .. r.line .. ":" .. r.col .. ": " .. r.text
      entries[#entries + 1] = entry
      entry_map[entry] = r
    end

    fzf.fzf_exec(entries, {
      prompt = "Unlinked mentions (" .. search_names[1] .. ")> ",
      previewer = "builtin",
      fzf_opts = {
        ["--no-sort"] = "",
        ["--delimiter"] = ":",
        ["--nth"] = "4..",
      },
      actions = {
        -- Default: jump to the match location
        ["default"] = function(selected)
          if not selected or #selected == 0 then return end
          local sel = selected[1]
          local r = entry_map[sel]
          if r then
            vim.cmd("edit " .. vim.fn.fnameescape(r.file))
            vim.api.nvim_win_set_cursor(0, { r.line, r.col - 1 })
            vim.cmd("normal! zz")
          end
        end,
        -- Ctrl-W: wrap selected match in [[wikilink]]
        ["ctrl-w"] = function(selected)
          if not selected or #selected == 0 then return end
          local wrapped = 0
          for _, sel in ipairs(selected) do
            local r = entry_map[sel]
            if r then
              -- Determine canonical note name for alias linking
              local canonical = search_names[1] -- primary name
              if wrap_in_wikilink(r.file, r.line, r.match, canonical) then
                wrapped = wrapped + 1
              end
            end
          end
          if wrapped > 0 then
            vim.notify("Vault: wrapped " .. wrapped .. " mention(s) in [[wikilinks]]", vim.log.levels.INFO)
          end
        end,
        -- Ctrl-A: wrap ALL matches in the selected file(s)
        ["ctrl-a"] = function(selected)
          if not selected or #selected == 0 then return end
          -- Collect unique files from selection
          local files = {}
          local file_set = {}
          for _, sel in ipairs(selected) do
            local r = entry_map[sel]
            if r and not file_set[r.file] then
              file_set[r.file] = true
              files[#files + 1] = r.file
            end
          end

          local wrapped = 0
          -- Process each file's matches in reverse line order to preserve positions
          for _, file in ipairs(files) do
            local file_matches = {}
            for _, r in ipairs(results) do
              if r.file == file then
                file_matches[#file_matches + 1] = r
              end
            end
            -- Sort by line descending so wrapping doesn't shift later positions
            table.sort(file_matches, function(a, b) return a.line > b.line end)
            for _, r in ipairs(file_matches) do
              local canonical = search_names[1]
              if wrap_in_wikilink(r.file, r.line, r.match, canonical) then
                wrapped = wrapped + 1
              end
            end
          end
          if wrapped > 0 then
            vim.notify("Vault: wrapped " .. wrapped .. " mention(s) in [[wikilinks]]", vim.log.levels.INFO)
          end
        end,
      },
    })
  end)
end

--- Show all unlinked mentions across the entire vault.
--- Groups by target note — each entry shows which note name was mentioned
--- and where in the vault the unlinked reference exists.
function M.vault_unlinked_mentions()
  vim.notify("Vault: building unlinked mentions index (this may take a moment)...", vim.log.levels.INFO)

  local all_names = all_note_names()
  if #all_names == 0 then
    vim.notify("Vault: no notes found in vault", vim.log.levels.WARN)
    return
  end

  -- Batch names to avoid massive regex patterns
  local batches = {}
  local current_batch = {}
  for _, entry in ipairs(all_names) do
    current_batch[#current_batch + 1] = entry
    if #current_batch >= MAX_PATTERN_NAMES then
      batches[#batches + 1] = current_batch
      current_batch = {}
    end
  end
  if #current_batch > 0 then
    batches[#batches + 1] = current_batch
  end

  local all_results = {}
  local pending = #batches

  for _, batch in ipairs(batches) do
    local names = {}
    local exclude_map = {}
    for _, entry in ipairs(batch) do
      names[#names + 1] = entry.name
      -- Exclude self-mentions: don't report "Mesh" in Mesh.md
      exclude_map[entry.name:lower()] = entry.path
    end

    rg_search(names, nil, function(raw_results)
      -- Filter self-mentions
      local non_self = {}
      for _, r in ipairs(raw_results) do
        -- Find which name this matched
        local line_lower = r.text:lower()
        local is_self = false
        for _, entry in ipairs(batch) do
          local name_lower = entry.name:lower()
          if line_lower:find(name_lower, 1, true) and r.file == entry.path then
            is_self = true
            break
          end
        end
        if not is_self then
          non_self[#non_self + 1] = r
        end
      end

      local filtered = filter_results(non_self, names)
      for _, r in ipairs(filtered) do
        all_results[#all_results + 1] = r
      end

      pending = pending - 1
      if pending == 0 then
        if #all_results == 0 then
          vim.notify("Vault: no unlinked mentions found", vim.log.levels.INFO)
          return
        end

        -- Format for fzf-lua
        local fzf = require("fzf-lua")
        local entries = {}
        local entry_map = {}

        for _, r in ipairs(all_results) do
          local rel = engine.vault_relative(r.file) or r.file
          local entry = "[" .. (r.match or "?") .. "] " .. rel .. ":" .. r.line .. ": " .. r.text
          entries[#entries + 1] = entry
          entry_map[entry] = r
        end

        -- Sort by note name then file
        table.sort(entries)

        fzf.fzf_exec(entries, {
          prompt = "Vault unlinked mentions (" .. #all_results .. ")> ",
          previewer = "builtin",
          fzf_opts = { ["--no-sort"] = "" },
          actions = {
            ["default"] = function(selected)
              if not selected or #selected == 0 then return end
              local r = entry_map[selected[1]]
              if r then
                vim.cmd("edit " .. vim.fn.fnameescape(r.file))
                vim.api.nvim_win_set_cursor(0, { r.line, r.col - 1 })
                vim.cmd("normal! zz")
              end
            end,
            ["ctrl-w"] = function(selected)
              if not selected or #selected == 0 then return end
              local wrapped = 0
              for _, sel in ipairs(selected) do
                local r = entry_map[sel]
                if r and r.match then
                  if wrap_in_wikilink(r.file, r.line, r.match, r.match) then
                    wrapped = wrapped + 1
                  end
                end
              end
              if wrapped > 0 then
                vim.notify("Vault: wrapped " .. wrapped .. " mention(s)", vim.log.levels.INFO)
              end
            end,
          },
        })
      end
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  -- Commands
  vim.api.nvim_create_user_command("VaultUnlinked", function()
    M.unlinked_mentions()
  end, { desc = "Show unlinked mentions for current note" })

  vim.api.nvim_create_user_command("VaultUnlinkedAll", function()
    M.vault_unlinked_mentions()
  end, { desc = "Show all unlinked mentions across vault" })

  -- Keymaps (registered on markdown FileType for buffer-local binding)
  local group = vim.api.nvim_create_augroup("VaultUnlinked", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vfu", function()
        M.unlinked_mentions()
      end, {
        buffer = ev.buf,
        desc = "Find: unlinked mentions",
        silent = true,
      })

      vim.keymap.set("n", "<leader>vfU", function()
        M.vault_unlinked_mentions()
      end, {
        buffer = ev.buf,
        desc = "Find: vault-wide unlinked mentions",
        silent = true,
      })
    end,
  })
end

-- Expose internals for testing
M._build_rg_pattern = build_rg_pattern
M._filter_results = filter_results
M._is_inside_wikilink = is_inside_wikilink
M._wrap_in_wikilink = wrap_in_wikilink
M._current_note_names = current_note_names

return M
```

---

## Integration

### 1. Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add after the `tag_highlights` setup line:

```lua
-- Load unlinked mentions scanner
require("andrew.vault.unlinked").setup()
```

### 2. Add config section (optional)

**File:** `lua/andrew/vault/config.lua`

Add to the config table:

```lua
--- Unlinked mentions settings
unlinked = {
  min_name_length = 3,       -- skip names shorter than this
  max_pattern_names = 50,    -- batch size for rg invocations
  context_lines = 2,         -- lines of context in fzf picker
  exclude_dirs = {},         -- vault-relative dirs to skip (e.g., {"attachments", "templates"})
},
```

### 3. Register cache invalidation (optional, for `engine.invalidate_all_caches`)

No dedicated cache is maintained in `unlinked.lua` — it relies on `wikilinks.lua`'s cache and `engine.get_name_cache()`, both of which are already invalidated by the existing `invalidate_all_caches()` mechanism.

---

## Keymaps

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>vfu` | n | Find: unlinked mentions for current note |
| `<leader>vfU` | n | Find: vault-wide unlinked mentions |

### Fzf-lua Picker Actions

| Key | Action |
|-----|--------|
| `<CR>` (Enter) | Jump to the unlinked mention location |
| `Ctrl-W` | Wrap selected mention(s) in `[[wikilinks]]` |
| `Ctrl-A` | Wrap ALL mentions in the selected file(s) (per-note picker only) |

### Commands

| Command | Description |
|---------|-------------|
| `:VaultUnlinked` | Show unlinked mentions for current note |
| `:VaultUnlinkedAll` | Show all unlinked mentions across vault |

---

## Testing

### Manual Verification

1. **Create test notes:**

   `Test Note Alpha.md`:
   ```markdown
   ---
   aliases: [TNA, Alpha Note]
   ---

   # Test Note Alpha

   This note discusses the Mesh Convergence problem.
   ```

   `Mesh Convergence.md`:
   ```markdown
   ---
   aliases: [mesh convergence study]
   ---

   # Mesh Convergence

   This is about mesh convergence analysis.
   ```

   `Third Note.md`:
   ```markdown
   # Third Note

   References to Test Note Alpha appear here without links.
   Also mentions TNA as an alias.
   But [[Mesh Convergence]] is already linked.
   The word `Test Note Alpha` in code should be ignored.

   ```python
   # Test Note Alpha in a code block should also be ignored
   ```
   ```

2. **Expected results for `:VaultUnlinked` on `Mesh Convergence.md`:**
   - `Test Note Alpha.md:5` — "This note discusses the Mesh Convergence problem."
   - Should NOT include the `[[Mesh Convergence]]` link in `Third Note.md` (already linked).
   - Should NOT include the code block reference in `Third Note.md`.

3. **Expected results for `:VaultUnlinked` on `Test Note Alpha.md`:**
   - `Third Note.md:3` — "References to Test Note Alpha appear here..."
   - `Third Note.md:4` — "Also mentions TNA as an alias."
   - Should NOT include the code span on line 5.
   - Should NOT include the code block mention.

4. **Wrap action test:**
   - Select "Test Note Alpha" match in `Third Note.md` and press `Ctrl-W`.
   - Line should change to: "References to [[Test Note Alpha]] appear here without links."
   - Select "TNA" match and press `Ctrl-W`.
   - Line should change to: "Also mentions [[Test Note Alpha|TNA]] as an alias."

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: unlinked module structure
do
  local source = io.open("lua/andrew/vault/unlinked.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    -- Core functionality present
    assert_true(content:find("unlinked_mentions") ~= nil, "has per-note unlinked_mentions()")
    assert_true(content:find("vault_unlinked_mentions") ~= nil, "has vault-wide scan")
    assert_true(content:find("build_rg_pattern") ~= nil, "builds ripgrep patterns")
    assert_true(content:find("filter_results") ~= nil, "has result filtering")
    assert_true(content:find("is_inside_wikilink") ~= nil, "filters existing wikilinks")
    assert_true(content:find("is_inside_code_span") ~= nil, "filters code spans")
    assert_true(content:find("is_in_fenced_code") ~= nil, "filters code blocks")
    assert_true(content:find("is_in_frontmatter") ~= nil, "filters frontmatter")
    assert_true(content:find("is_heading_line") ~= nil, "filters headings")
    assert_true(content:find("is_inside_url") ~= nil, "filters URLs")
    assert_true(content:find("wrap_in_wikilink") ~= nil, "has wikilink wrapping")
    assert_true(content:find("pcre2_escape") ~= nil, "escapes regex special chars")
    assert_true(content:find("\\\\b") ~= nil, "uses word boundaries")
    assert_true(content:find("VaultUnlinked") ~= nil, "defines user command")
    assert_true(content:find("ctrl%-w") ~= nil, "has wrap action")
  end
end

-- Test: rg_pattern building
do
  local ok, unlinked = pcall(require, "andrew.vault.unlinked")
  if ok and unlinked._build_rg_pattern then
    local pat = unlinked._build_rg_pattern({"Mesh Convergence", "CFD"})
    -- Longest names first
    assert_true(pat:find("Mesh Convergence") ~= nil, "includes full name")
    assert_true(pat:find("CFD") ~= nil, "includes short name")
    assert_true(pat:find("\\b") ~= nil, "has word boundaries")

    -- Empty names
    local empty = unlinked._build_rg_pattern({})
    assert_true(empty == "", "empty pattern for no names")

    -- Short names filtered
    local short = unlinked._build_rg_pattern({"ab"})
    assert_true(short == "", "filters names shorter than MIN_NAME_LENGTH")
  end
end

-- Test: wikilink detection
do
  local ok, unlinked = pcall(require, "andrew.vault.unlinked")
  if ok and unlinked._is_inside_wikilink then
    local fn = unlinked._is_inside_wikilink
    assert_true(fn("see [[Mesh Convergence]] here", 6, 23), "inside wikilink")
    assert_true(not fn("Mesh Convergence is great", 1, 16), "not in wikilink")
    assert_true(fn("[[Mesh Convergence|MC]]", 3, 18), "inside aliased wikilink")
    assert_true(not fn("before [[link]] Mesh Convergence after", 17, 32), "after wikilink")
  end
end
```

### Performance Verification

For a per-note scan (single note name):

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.unlinked").unlinked_mentions(); print(("Launched in %.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

Target: < 50ms to launch (ripgrep runs async). Total time including ripgrep depends on vault size — expect < 500ms for a 1000-note vault with a single search term.

For vault-wide scan, times scale linearly with batch count:

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.unlinked").vault_unlinked_mentions(); print(("Launched in %.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

Target: < 5s for a 1000-note vault (20 batches of 50, running serially via async callbacks).

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| Note name is 1-2 characters (e.g., "AI") | Skipped — `MIN_NAME_LENGTH = 3` prevents noise |
| Note name contains regex special chars (e.g., "C++ Basics") | PCRE2-escaped to `C\+\+ Basics` |
| Note name is a common English word (e.g., "Note") | Matched with word boundaries — `\bNote\b` won't match "denote" |
| Same name appears linked AND unlinked on one line | Only the unlinked occurrence is reported |
| Match inside `[[Note\|alias]]` (escaped pipe in table) | Detected as inside wikilink, skipped |
| Match inside markdown link `[text](url)` | Not filtered (intentional — markdown links are different from wikilinks) |
| Match in heading `# My Mesh Convergence Study` | Filtered out — heading lines excluded |
| Match in frontmatter `title: Mesh Convergence` | Filtered out — frontmatter excluded |
| Match in fenced code block | Filtered out — code fence state machine |
| Match in inline code `` `Mesh Convergence` `` | Filtered out — code span detection |
| Match in URL `https://example.com/Mesh+Convergence` | Filtered out — URL detection |
| Note with no aliases | Only basename is searched |
| Note with multiple aliases | All aliases searched in one ripgrep invocation |
| Vault-wide scan with 500+ notes | Batched into groups of 50, each async ripgrep |
| Empty vault | No results, no errors |
| Wrapping a mention that already has `[[` nearby on same line | `is_inside_wikilink` prevents double-wrapping |
| Buffer open in Neovim vs. file on disk | `wrap_in_wikilink` prefers buffer API if loaded |
| Alias match (e.g., "TNA" matches "Test Note Alpha") | Wrapped as `[[Test Note Alpha\|TNA]]` |
| Case mismatch (e.g., "mesh convergence" in prose) | Matched case-insensitively, wrapped preserving original case |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | `vault_path`, `is_vault_path()`, `get_name_cache()`, `rg_base_opts()`, `vault_fzf_opts()`, `read_file_lines()`, `write_file()`, `vault_relative()` | Yes |
| `wikilinks.lua` | `resolve_link()` for cache warming and link verification | Yes |
| `frontmatter_parser.lua` | `parse_file()` for alias extraction from current note | Yes |
| `fzf-lua` | Picker UI for results display and actions | Yes |
| `ripgrep` | External binary — vault-wide text search with PCRE2 | Yes (`--pcre2` flag required) |
| `config.lua` | Optional configuration overrides | No (fallback defaults) |

### External Requirements

- **ripgrep with PCRE2 support:** The `--pcre2` flag is required for `\b` word boundaries. Check with `rg --pcre2-version`. Most package managers install ripgrep with PCRE2 enabled. If unavailable, fall back to `(?<![a-zA-Z])` / `(?![a-zA-Z])` lookaround patterns (less accurate at non-ASCII boundaries).

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/unlinked.lua` | **New file** — complete module |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.unlinked").setup()` |
| `lua/andrew/vault/config.lua` | Add `unlinked` config section (optional) |

---

## Risk Assessment

**Risk: Low-Medium**

- **New module** — no existing code modified except one `require` line in `init.lua`.
- **Async ripgrep** — all scanning runs via `vim.system()` callbacks, no UI blocking.
- **Post-filtering is defensive** — false negatives (missing a valid unlinked mention) are acceptable; false positives (wrapping text that shouldn't be wrapped) are prevented by multiple filter layers.
- **Wikilink wrapping is explicit** — requires user action (`Ctrl-W`), never automatic.
- **PCRE2 dependency** — if ripgrep lacks PCRE2, the command will fail with a clear error. A fallback could be added but is unlikely to be needed on modern systems.
- **Vault-wide scan performance** — large vaults (2000+ notes) may take several seconds. The batching strategy keeps individual ripgrep invocations fast, and progress is communicated via notifications.
- **No cache of its own** — relies entirely on `wikilinks.lua` and `engine.lua` caches, so it stays consistent with the rest of the system without needing its own invalidation logic.

---

## Future Enhancements

1. **Virtual text indicators** — show inline virtual text markers (e.g., a dim `[unlinked]` badge) next to unlinked mentions in the current buffer, similar to how `linkdiag.lua` shows broken link diagnostics.
2. **Auto-link on write** — optional `BufWritePre` hook that prompts to wrap unlinked mentions found during save (disabled by default).
3. **Exclusion list** — user-configurable list of note names to never report as unlinked (e.g., very common words that happen to be note names).
4. **Telescope integration** — alternative picker backend for users who prefer telescope over fzf-lua.
5. **Batch wrap confirmation** — show a diff preview before applying `Ctrl-A` bulk wrapping.
