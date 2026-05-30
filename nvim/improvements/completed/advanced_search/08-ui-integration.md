# UI Integration

## Overview

The advanced search adds two UI modes to `lua/andrew/vault/search.lua`:
1. **Prompt mode** -- User composes query in `vim.ui.input`, results in fzf-lua
2. **Live mode** -- User types in fzf-lua input bar, results update in real-time

Both modes reuse existing engine helpers and fzf-lua patterns.

## Prompt Mode: `search_advanced()`

### Entry Point: `:VaultSearchAdvanced`

```lua
function M.search_advanced()
  local search_query = require("andrew.vault.search_query")
  local search_filter = require("andrew.vault.search_filter")
  local vault_index = require("andrew.vault.vault_index")

  -- Get user input via engine coroutine
  local query_string = nil
  engine.run(function()
    query_string = engine.input({ prompt = "Advanced search: " })
  end)
  if not query_string or query_string == "" then return end

  -- Parse the query
  local ast, parse_err = search_query.parse_query(query_string)
  if not ast then
    vim.notify("Search parse error: " .. (parse_err or "unknown"), vim.log.levels.ERROR)
    return
  end

  -- Split into metadata and text portions
  local metadata_ast, text_nodes = search_filter.split_ast(ast)

  -- Phase 1: Metadata filtering
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    vim.notify("Vault index not ready", vim.log.levels.WARN)
    return
  end

  local metadata_matches = nil
  if metadata_ast then
    metadata_matches = {}
    for rel_path, entry in pairs(idx.files) do
      if search_filter.match_entry(metadata_ast, entry) then
        metadata_matches[#metadata_matches + 1] = entry
      end
    end
  end

  -- Phase 2: Text search via ripgrep
  if #text_nodes > 0 then
    local matches = metadata_matches or idx:all_entries()
    local results = search_filter.ripgrep_in_files(text_nodes, matches, engine.vault_path)

    -- Display ripgrep results in fzf
    local fzf = require("fzf-lua")
    fzf.fzf_exec(results, engine.vault_fzf_opts("Advanced [" .. query_string .. "]", {
      previewer = "builtin",
      actions = engine.vault_fzf_actions(),
    }))
  else
    -- Metadata-only: display file list
    local fzf = require("fzf-lua")
    local entries = {}
    for _, entry in ipairs(metadata_matches or {}) do
      entries[#entries + 1] = entry.rel_path
    end
    fzf.fzf_exec(entries, engine.vault_fzf_opts("Advanced [" .. query_string .. "]", {
      previewer = "builtin",
      actions = engine.vault_fzf_actions(),
    }))
  end

  -- Track for saved searches
  track(query_string, "all", "advanced")
end
```

### Data Flow

```
User types query in vim.ui.input
        |
        v
  parse_query(query_string) --> AST
        |
        v
  split_ast(ast) --> metadata_ast + text_nodes
        |
        +--- metadata_ast present?
        |         |
        |    Yes: iterate idx.files, match_entry() each
        |         --> metadata_matches[]
        |         |
        |    No:  metadata_matches = nil (all files)
        |
        +--- text_nodes present?
        |         |
        |    Yes: ripgrep_in_files(text_nodes, matches, vault_path)
        |         --> ripgrep result lines
        |         --> fzf.fzf_exec(results, ...)
        |         |
        |    No:  extract rel_paths from metadata_matches
        |         --> fzf.fzf_exec(paths, ...)
        |
        v
  track(query_string, "all", "advanced")
```

## Live Mode: `search_advanced_live()`

### Entry Point: `:VaultSearchAdvancedLive`

```lua
function M.search_advanced_live()
  local fzf = require("fzf-lua")
  local search_query = require("andrew.vault.search_query")
  local search_filter = require("andrew.vault.search_filter")

  fzf.fzf_live(function(query_string)
    if not query_string or query_string == "" then
      return {}
    end

    local ast, err = search_query.parse_query(query_string)
    if not ast then return {} end

    local metadata_ast, text_nodes = search_filter.split_ast(ast)
    local idx = require("andrew.vault.vault_index").current()
    if not idx or not idx:is_ready() then return {} end

    -- Get metadata-matched files
    local matches = {}
    if metadata_ast then
      for rel_path, entry in pairs(idx.files) do
        if search_filter.match_entry(metadata_ast, entry) then
          matches[#matches + 1] = entry
        end
      end
    else
      for _, entry in pairs(idx.files) do
        matches[#matches + 1] = entry
      end
    end

    -- If no text terms, return file list
    if #text_nodes == 0 then
      local results = {}
      for _, entry in ipairs(matches) do
        results[#results + 1] = entry.rel_path
      end
      return results
    end

    -- Text terms: run ripgrep restricted to matched files
    return search_filter.ripgrep_in_files(text_nodes, matches, engine.vault_path)
  end, engine.vault_fzf_opts("Advanced search", {
    exec_empty_query = false,
    previewer = "builtin",
    actions = engine.vault_fzf_actions(),
  }))
end
```

### How `fzf.fzf_live()` Works

`fzf_live` is fzf-lua's API for dynamic content based on user input:

1. fzf-lua opens the fzf UI with a text input
2. On each keystroke (debounced), it calls the provider function with the
   current query string
3. The provider function returns either:
   - A string array (displayed as entries)
   - A command string (executed, stdout displayed as entries)
4. fzf re-renders with the new entries

**This pattern is NOT currently used anywhere in the vault codebase.** The
advanced search will be the first module to use `fzf_live`.

### Live Mode Data Flow

```
User types in fzf input bar
        |  (debounced, ~150ms)
        v
provider(query_string) called
        |
        v
  parse_query(query_string) --> AST (or {} on parse error)
        |
        v
  split_ast(ast)
        |
        +--- metadata filtering (in-memory, < 5ms)
        +--- ripgrep (if text terms, async)
        |
        v
  Return results array to fzf
        |
        v
  fzf re-renders entries
```

### Live Mode Considerations

**Debouncing:** fzf-lua handles debouncing internally. The
`config.search.live_debounce_ms` (150ms default) can be passed as part of
fzf options.

**Parse errors:** When the user is mid-typing, the query may be incomplete
(e.g., `type:meet` before finishing `type:meeting`). The parser should handle
partial queries gracefully:
- Incomplete field values still match as prefix
- Unmatched parens return empty results (no error notification)
- Only the live mode silences parse errors; prompt mode shows them

**Performance budget:**
- Parse: < 0.5ms
- Metadata filter (500 files): < 5ms
- Ripgrep (restricted file set): < 100ms
- fzf render: < 50ms
- **Total: < 200ms for responsive feel**

## Execute Advanced Query (for Saved Searches)

```lua
function M.execute_advanced_query(query_string)
  -- Same as search_advanced() but takes query_string directly
  -- (no vim.ui.input prompt)
  local search_query = require("andrew.vault.search_query")
  local search_filter = require("andrew.vault.search_filter")
  local vault_index = require("andrew.vault.vault_index")

  local ast, parse_err = search_query.parse_query(query_string)
  if not ast then
    vim.notify("Saved search parse error: " .. (parse_err or "unknown"), vim.log.levels.ERROR)
    return
  end

  -- ... same Phase 1/2/3 as search_advanced() ...
end
```

## Graceful Degradation

When the vault index is not ready (cold start, still building):

```lua
local idx = vault_index.current()
if not idx or not idx:is_ready() then
  -- Fall back to plain ripgrep with notification
  vim.notify("Vault index not ready. Falling back to text search.", vim.log.levels.WARN)

  -- Extract text terms from query (best effort)
  -- Or just pass the whole query to ripgrep
  local fzf = require("fzf-lua")
  fzf.live_grep(engine.vault_fzf_opts("Search (no index)", {
    rg_opts = engine.rg_base_opts(),
  }))
  return
end
```

## Commands & Keymaps

### New Commands

| Command                     | Function                        | Description                       |
|-----------------------------|---------------------------------|-----------------------------------|
| `:VaultSearchAdvanced`      | `M.search_advanced()`           | Prompt mode advanced search       |
| `:VaultSearchAdvancedLive`  | `M.search_advanced_live()`      | Live mode advanced search         |
| `:VaultSearchHelp`          | Opens syntax reference float    | Query language help               |

### New Keymaps

| Keymap        | Function                        | Mnemonic                         |
|---------------|---------------------------------|----------------------------------|
| `<leader>vfa` | `M.search_advanced()`           | vault find Advanced              |
| `<leader>vfA` | `M.search_advanced_live()`      | vault find Advanced (live)       |

### Existing Commands (Unchanged)

| Command              | Function             | Keymap        |
|----------------------|----------------------|---------------|
| `:VaultSearch`       | `M.search()`         | `<leader>vfs` |
| `:VaultSearchNotes`  | `M.search_notes()`   | `<leader>vfn` |
| `:VaultSearchFiltered`| `M.search_filtered()`| `<leader>vfD` |
| `:VaultSearchType`   | `M.search_by_type()` | `<leader>vfy` |

## Search Help Float

`:VaultSearchHelp` opens a floating window with the query syntax reference:

```lua
function M.search_help()
  local lines = {
    "Advanced Search Syntax",
    "═══════════════════════",
    "",
    "Text:      deploy              Files containing 'deploy'",
    "Quoted:    \"exact phrase\"      Exact match",
    "Regex:     /^## Results/       Regex (ripgrep)",
    "",
    "Fields:    type:meeting        Frontmatter type",
    "           tag:project         Tag (prefix match)",
    "           path:Projects/      Path prefix",
    "           file:Dashboard      Basename substring",
    "           folder:Log          Folder match",
    "           status:active       Status field",
    "           priority:>3         Numeric comparison",
    "",
    "Dates:     modified:>7d        Last 7 days",
    "           created:today       Created today",
    "           modified:this-week  This week",
    "           created:2026-01..2026-02  Date range",
    "",
    "Tasks:     task:\"\"             Any task",
    "           task-todo:\"\"        Open tasks",
    "           task-done:\"\"        Done tasks",
    "",
    "Existence: has:tags            Has any tags",
    "           has:aliases         Has aliases",
    "           has:outlinks        Has outgoing links",
    "",
    "Boolean:   A AND B             Both match",
    "           A OR B              Either matches",
    "           NOT A / -A          Negation",
    "           (A OR B) AND C      Grouping",
    "",
    "Implicit:  type:meeting deploy = type:meeting AND deploy",
  }

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "markdown"

  -- Open centered float
  local width = 60
  local height = #lines
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Search Help ",
    title_pos = "center",
  })

  -- Close on q or Esc
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = buf })
end
```

## Completion Support

The advanced search prompt can provide completions for field names and values.
Using `vim.ui.input`'s optional `completion` parameter:

```lua
engine.input({
  prompt = "Advanced search: ",
  completion = function(arg_lead, cmd_line, cursor_pos)
    -- Analyze cursor position in query
    -- If after a known field prefix, suggest values
    -- If at word start, suggest field names and operators
    local suggestions = {}

    -- Field name completion
    if not arg_lead:find(":") then
      for _, field in ipairs(config.search.builtin_fields) do
        if field:sub(1, #arg_lead) == arg_lead then
          suggestions[#suggestions + 1] = field .. ":"
        end
      end
      -- Also suggest operators
      for _, op in ipairs({"AND", "OR", "NOT"}) do
        if op:sub(1, #arg_lead:upper()) == arg_lead:upper() then
          suggestions[#suggestions + 1] = op
        end
      end
    end

    -- Value completion (after field:)
    local field, partial = arg_lead:match("^([^:]+):(.*)$")
    if field then
      field = field:lower()
      local idx = require("andrew.vault.vault_index").current()
      if field == "tag" and idx then
        for _, tag in ipairs(idx:all_tags()) do
          if tag:sub(1, #partial) == partial:lower() then
            suggestions[#suggestions + 1] = field .. ":" .. tag
          end
        end
      elseif field == "type" then
        for _, t in ipairs(config.note_types) do
          if t:sub(1, #partial) == partial:lower() then
            suggestions[#suggestions + 1] = field .. ":" .. t
          end
        end
      elseif field == "status" then
        for _, s in ipairs(config.status_values) do
          if s:lower():sub(1, #partial) == partial:lower() then
            suggestions[#suggestions + 1] = field .. ":" .. s
          end
        end
      elseif field == "has" then
        for _, h in ipairs({"tags", "aliases", "tasks", "outlinks", "inlinks", "frontmatter"}) do
          if h:sub(1, #partial) == partial:lower() then
            suggestions[#suggestions + 1] = "has:" .. h
          end
        end
      end
    end

    return suggestions
  end,
})
```
