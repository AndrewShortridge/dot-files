# 17 -- Search Enhancements

## Current State

The advanced search system (`search.lua`, `search_query.lua`, `search_filter.lua`) provides a comprehensive query language with boolean logic, field filters, task metadata queries, graph traversal, and result grouping. The system supports two interaction modes: prompt mode (floating input with single-shot execution) and live mode (fzf_live with per-keystroke re-evaluation).

### Existing Components

| Module | File | Role |
|--------|------|------|
| `search.lua` | `lua/andrew/vault/search.lua` | UI: prompt mode, live mode, help float, Tab completion |
| `search_query.lua` | `lua/andrew/vault/search_query.lua` | Tokenizer + recursive descent parser (pure Lua, no deps) |
| `search_filter.lua` | `lua/andrew/vault/search_filter.lua` | AST splitting, metadata eval, ripgrep dispatch |
| `saved_searches.lua` | `lua/andrew/vault/saved_searches.lua` | Persistent named searches with `advanced` flag |
| `frecency.lua` | `lua/andrew/vault/frecency.lua` | Time-decay scoring for file access frequency |
| `config.lua` | `lua/andrew/vault/config.lua` | `M.search` section with builtin_fields, field_aliases, grouping |
| `filter_utils.lua` | `lua/andrew/vault/filter_utils.lua` | Shared filter predicates (tags, timestamps, types) |
| `date_utils.lua` | `lua/andrew/vault/date_utils.lua` | Date resolution, parsing, comparison helpers |
| `engine.lua` | `lua/andrew/vault/engine.lua` | `json_store()`, `vault_fzf_opts()`, vault path resolution |

### What Is Missing

1. **No search history.** When a user runs `:VaultSearchAdvanced` repeatedly, there is no recall of previous queries. The `saved_searches.lua` module provides explicit save/load of named queries, but requires manual naming. Users cannot quickly re-run or browse recent queries.

2. **No result statistics.** The fzf picker shows results but provides no summary of how many files or matches were found, or how long the query took to evaluate. The `--header` is used only for syntax hints.

3. **No field name correction.** If a user types `tpye:meeting` instead of `type:meeting`, the tokenizer produces a TEXT token (falling through the field check since `tpye` has a colon but does not match known fields). The user sees unexpected results with no feedback about the typo.

4. **No regex flags.** The tokenizer parses `/pattern/` but discards anything after the closing `/`. Users cannot specify case-insensitive (`/pattern/i`) or multiline (`/pattern/m`) matching, which are common regex features.

5. **No field value completion.** While `_complete_advanced()` already provides completions for `type:`, `status:`, `tag:`, and a few other fields, many fields have no value completion. Generic frontmatter fields (e.g., `area:`, `project:`) could aggregate values from the vault index but do not.

---

## Sub-Feature 1: Search History with Frecency Ranking

### Motivation

Power users run dozens of search queries per session. Without history, re-running a recent query requires retyping it or having pre-saved it. The `frecency.lua` module already implements time-decay scoring for file access -- the same algorithm can rank search queries by recency and frequency of use.

### Architecture

A new module `search_history.lua` manages a JSON-backed query history with frecency scoring. It follows the same patterns as `frecency.lua` (using `engine.json_store()` for persistence, time-bucketed scoring, debounced writes) and `saved_searches.lua` (fzf picker for selection).

### Implementation

#### New File: `lua/andrew/vault/search_history.lua`

```lua
--- Search history with frecency ranking.
---
--- Persists query history to .vault-search-history.json with timestamps.
--- Uses the same time-decay scoring algorithm as frecency.lua to rank
--- queries by recency and frequency of use.

local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

--- Maximum timestamps stored per query entry.
local MAX_TIMESTAMPS = 10

--- Recency weight buckets (same as frecency.lua).
local BUCKETS = {
  { 1, 100 },   -- last hour
  { 24, 80 },   -- last day
  { 72, 60 },   -- last 3 days
  { 168, 40 },  -- last week
  { 336, 20 },  -- last 2 weeks
  { 720, 10 },  -- last month
}
local FLOOR_WEIGHT = 5

-- In-memory cache
local _db = nil
local _db_vault = nil

local store = engine.json_store(".vault-search-history.json")

---@return table<string, {timestamps: number[], type?: string}>
local function load_db()
  if _db and _db_vault == engine.vault_path then
    return _db
  end
  _db_vault = engine.vault_path
  _db = store.load()
  return _db
end

---@param db table
local function save_db(db)
  _db = db
  _db_vault = engine.vault_path
  store.save(db)
end
```

**Scoring** -- reuses the same recency_weight algorithm as `frecency.lua`:

```lua
--- Compute recency weight for a single timestamp.
---@param ts number epoch seconds
---@param now number epoch seconds
---@return number
local function recency_weight(ts, now)
  local age_hours = (now - ts) / 3600
  for _, bucket in ipairs(BUCKETS) do
    if age_hours < bucket[1] then
      return bucket[2]
    end
  end
  return FLOOR_WEIGHT
end

--- Compute frecency score for a history entry.
---@param entry {timestamps: number[]}
---@param now? number
---@return number
function M.score(entry, now)
  now = now or os.time()
  local total = 0
  for _, ts in ipairs(entry.timestamps or {}) do
    total = total + recency_weight(ts, now)
  end
  return total
end
```

**Recording** -- called when a query is executed:

```lua
--- Record a query execution.
---@param query string the raw query text
---@param search_type? string "advanced"|"grep"|"type"
function M.record(query, search_type)
  if not query or query == "" then return end

  local max_entries = config.search
    and config.search.history
    and config.search.history.max_entries or 200

  local db = load_db()
  local entry = db[query] or { timestamps = {} }
  local ts = entry.timestamps or {}

  -- Debounce: skip if same query was recorded < 5 seconds ago
  if #ts > 0 and (os.time() - ts[1]) < 5 then return end

  table.insert(ts, 1, os.time())
  while #ts > MAX_TIMESTAMPS do
    table.remove(ts)
  end
  entry.timestamps = ts
  if search_type then entry.type = search_type end
  db[query] = entry

  -- Prune oldest entries if exceeding max size
  local count = vim.tbl_count(db)
  if count > max_entries then
    local all = {}
    local now = os.time()
    for q, e in pairs(db) do
      all[#all + 1] = { query = q, score = M.score(e, now) }
    end
    table.sort(all, function(a, b) return a.score > b.score end)
    -- Remove bottom 10%
    local cutoff = math.floor(max_entries * 0.9)
    for i = cutoff + 1, #all do
      db[all[i].query] = nil
    end
  end

  save_db(db)
end
```

**Ranked retrieval** -- sorted by frecency for the picker:

```lua
--- Get all history entries sorted by frecency score (highest first).
---@return {query: string, score: number, type?: string}[]
function M.ranked()
  local db = load_db()
  local now = os.time()
  local scored = {}
  for query, entry in pairs(db) do
    scored[#scored + 1] = {
      query = query,
      score = M.score(entry, now),
      type = entry.type,
    }
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  return scored
end
```

**Picker** -- fzf picker for browsing and re-executing history:

```lua
--- Open fzf picker with search history sorted by frecency.
--- Selecting an entry re-executes the query.
function M.pick()
  local ranked = M.ranked()
  if #ranked == 0 then
    vim.notify("Vault: no search history", vim.log.levels.INFO)
    return
  end

  local entries = {}
  local lookup = {}
  for _, item in ipairs(ranked) do
    local prefix = item.type == "advanced" and "[ADV] " or ""
    local display = prefix .. item.query
    entries[#entries + 1] = display
    lookup[display] = item
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Search history> ",
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then return end
        local item = lookup[selected[1]]
        if not item then return end
        if item.type == "advanced" then
          vim.schedule(function()
            require("andrew.vault.search").execute_advanced_query(item.query)
          end)
        else
          -- Re-execute as live grep with the query pre-filled
          vim.schedule(function()
            local fzf2 = require("fzf-lua")
            fzf2.live_grep(
              require("andrew.vault.engine").vault_fzf_opts("Vault search", {
                search = item.query,
              })
            )
          end)
        end
      end,
      -- ctrl-d: delete selected history entry
      ["ctrl-d"] = function(selected)
        if not selected or #selected == 0 then return end
        local item = lookup[selected[1]]
        if item then
          M.delete(item.query)
          vim.notify("Deleted from history: " .. item.query, vim.log.levels.INFO)
        end
      end,
    },
    fzf_opts = {
      ["--no-sort"] = "",  -- preserve frecency order
    },
  })
end

--- Delete a query from history.
---@param query string
function M.delete(query)
  local db = load_db()
  db[query] = nil
  save_db(db)
end

--- Clear all search history.
function M.clear()
  save_db({})
  vim.notify("Vault: search history cleared", vim.log.levels.INFO)
end
```

**Setup:**

```lua
function M.setup()
  vim.api.nvim_create_user_command("VaultSearchHistory", function()
    M.pick()
  end, { desc = "Browse vault search history (frecency-ranked)" })

  vim.api.nvim_create_user_command("VaultSearchHistoryClear", function()
    M.clear()
  end, { desc = "Clear vault search history" })
end

return M
```

**Estimated size:** ~160 lines.

#### Changes to `search.lua`

**1. Record history on query execution.**

In the `track()` function (line 11), add a call to `search_history.record()`:

```lua
local function track(query, scope, search_type, advanced)
  require("andrew.vault.saved_searches").set_last_search(query, scope, search_type, advanced)
  -- Record in search history (non-empty queries only)
  if query and query ~= "" then
    require("andrew.vault.search_history").record(query, advanced and "advanced" or search_type)
  end
end
```

**2. Add Ctrl-r keymap in prompt mode** to open history from the search input.

Inside `search_advanced()`, after the existing keymaps (line 372):

```lua
  -- Ctrl-r: open search history and paste selected query into prompt
  vim.keymap.set({ "n", "i" }, "<C-r>", function()
    local history = require("andrew.vault.search_history")
    local ranked = history.ranked()
    if #ranked == 0 then
      vim.notify("No search history", vim.log.levels.INFO)
      return
    end
    local items = {}
    for _, item in ipairs(ranked) do
      items[#items + 1] = item.query
    end
    vim.ui.select(items, { prompt = "Search history:" }, function(choice)
      if choice and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { choice })
        -- Move cursor to end of line
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_cursor(win, { 1, #choice })
            vim.cmd("startinsert!")
          end
        end)
      end
    end)
  end, { buffer = buf, silent = true })
```

**3. Add keymap and command in `setup()`:**

```lua
  vim.keymap.set("n", "<leader>vfH", function()
    require("andrew.vault.search_history").pick()
  end, { desc = "Find: search history", silent = true })
```

**4. Update prompt footer** to mention Ctrl-r:

```lua
    footer = {
      { " field:value tag:x has:tags links-to:N created:>7d AND OR NOT | ", "Comment" },
      { "Ctrl-/", "Special" },
      { " help ", "Comment" },
      { " | ", "Comment" },
      { "Ctrl-r", "Special" },
      { " history ", "Comment" },
    },
```

#### Changes to `config.lua`

Add history configuration inside `M.search`:

```lua
  -- Search history
  history = {
    -- Maximum number of queries stored in history.
    max_entries = 200,

    -- Automatically record queries to history.
    enabled = true,
  },
```

#### Edge Cases

1. **Deduplication:** The JSON key is the raw query string. `type:meeting` and `type:meeting ` (trailing space) are different keys. The `track()` function already trims via `vim.trim()` in prompt mode, so this is handled at the call site. Live mode tracks `last_live_query` which comes directly from fzf input (untrimmed). Trim before recording.

2. **History size:** The `max_entries` config caps the JSON file size. Pruning removes the bottom 10% by score when the cap is exceeded, keeping the most-used queries.

3. **Vault switching:** Like `frecency.lua`, the in-memory cache is keyed by `engine.vault_path` and reloaded on vault switch.

4. **Empty queries:** Filtered out at the `track()` call site -- empty strings are not recorded.

5. **Identical queries with different results:** The history tracks query text, not results. The same query re-executed later may produce different results (if the vault has changed). This is expected behavior.

---

## Sub-Feature 2: Result Statistics in fzf Header

### Motivation

When running a search that returns many results, users have no feedback about the result set size or query performance. A "42 matches in 12 files (87ms)" line in the fzf header provides immediate context for refining the query.

### Architecture

Statistics are computed alongside `resolve_query()` and injected into the fzf `--header` string. For prompt mode (single-shot execution), timing is straightforward. For live mode (per-keystroke re-evaluation), the stats are returned from the provider function and displayed via fzf header updates.

### Implementation

#### Changes to `search.lua`

**1. Add timing and counting to `execute_advanced_query()`:**

After `resolve_query()` returns (line 235), compute stats and inject into the header:

```lua
function M.execute_advanced_query(query_string, opts)
  opts = opts or {}
  local search_query = require("andrew.vault.search_query")
  local search_filter = require("andrew.vault.search_filter")
  local vault_index = require("andrew.vault.vault_index")
  local fzf = require("fzf-lua")

  local t_start = vim.uv.hrtime()

  local ast, err, group_mode = search_query.parse_query(query_string)
  -- ... existing parse error handling ...

  local idx = vault_index.current()
  -- ... existing index fallback ...

  local split = search_filter.split_ast(ast)
  -- ... existing graph pre-computation ...

  local result = resolve_query(split, idx, engine.vault_path, graph_sets, group_mode)

  local elapsed_ms = math.floor((vim.uv.hrtime() - t_start) / 1e6)

  if #result.entries == 0 then
    if not opts.silent then
      vim.notify(
        string.format("Advanced search: no matches (%dms)", elapsed_ms),
        vim.log.levels.INFO
      )
    end
    return
  end

  -- Count unique files in results
  local file_count = count_unique_files(result.entries, group_mode)
  local match_count = count_matches(result.entries, group_mode)

  -- Build stats line for header
  local stats_line = string.format(
    "%d match%s in %d file%s (%dms)",
    match_count, match_count == 1 and "" or "es",
    file_count, file_count == 1 and "" or "s",
    elapsed_ms
  )

  -- ... existing actions setup ...

  local fzf_inner_opts = {
    ["--header"] = stats_line .. "\n" .. SEARCH_HEADER,
    ["--ansi"] = "",
  }
  -- ...
end
```

**2. Add helper functions** before `execute_advanced_query()`:

```lua
--- Count unique files in a result set (excluding group headers).
---@param entries string[]
---@param group_mode? string
---@return number
local function count_unique_files(entries, group_mode)
  local search_group = require("andrew.vault.search_group")
  local seen = {}
  local count = 0
  for _, entry in ipairs(entries) do
    if not (group_mode and search_group.is_header(entry)) then
      local file = entry:match("^(.-):%d+:%d+:") or entry
      if not seen[file] then
        seen[file] = true
        count = count + 1
      end
    end
  end
  return count
end

--- Count non-header entries in a result set.
---@param entries string[]
---@param group_mode? string
---@return number
local function count_matches(entries, group_mode)
  if not group_mode then return #entries end
  local search_group = require("andrew.vault.search_group")
  local count = 0
  for _, entry in ipairs(entries) do
    if not search_group.is_header(entry) then
      count = count + 1
    end
  end
  return count
end
```

**3. Live mode stats:**

In `search_advanced_live()`, the provider function returns entries per keystroke. Computing stats inside the provider is straightforward since we already have the result set. However, fzf-lua's `fzf_live` does not natively support dynamic header updates per query.

Two approaches:

**Option A -- Static header with prompt prefix (simpler):**

The fzf prompt can include a count suffix. This requires no fzf header changes but provides less detail.

**Option B -- Return stats via a header sentinel line (recommended):**

Prepend a stats line to the result entries using the same HEADER_PREFIX sentinel as group headers. This line appears at the top of the list and is skipped by the default action:

```lua
  fzf.fzf_live(function(args)
    local query_string = type(args) == "table" and args[1] or args
    if type(query_string) ~= "string" or query_string == "" then return {} end
    last_live_query = query_string

    local t_start = vim.uv.hrtime()

    local ast, _, group_mode = search_query.parse_query(query_string)
    if not ast then return {} end

    -- ... existing group_mode / split / graph_sets logic ...

    local result = resolve_query(split, idx, engine.vault_path, graph_sets, group_mode)

    -- Prepend stats line if configured
    if config.search and config.search.show_stats ~= false then
      local elapsed_ms = math.floor((vim.uv.hrtime() - t_start) / 1e6)
      local file_count = count_unique_files(result.entries, group_mode)
      local match_count = count_matches(result.entries, group_mode)
      local ANSI_DIM = "\27[2m"
      local ANSI_RESET = "\27[0m"
      local stats = string.format(
        "%s%s%d match%s in %d file%s (%dms)%s",
        search_group.HEADER_PREFIX,
        ANSI_DIM,
        match_count, match_count == 1 and "" or "es",
        file_count, file_count == 1 and "" or "s",
        elapsed_ms,
        ANSI_RESET
      )
      table.insert(result.entries, 1, stats)
    end

    return result.entries
  end, ...)
```

The stats line uses `HEADER_PREFIX` so it is filtered out by the existing header-skipping logic in the default action, and `--no-sort` (already set) ensures it stays at the top.

#### Changes to `config.lua`

```lua
  -- Show result statistics (match count, file count, timing) in search results.
  show_stats = true,
```

#### Edge Cases

1. **Zero results:** The "no matches" notification already handles this; stats are not shown.
2. **Metadata-only results:** `count_unique_files()` handles bare rel_paths (no `:line:col:` suffix).
3. **Group headers:** Both count functions exclude group header lines.
4. **Performance overhead:** `count_unique_files()` is O(N) with a hash set; negligible for typical result sizes (< 5000 entries).
5. **Live mode timing:** The `elapsed_ms` in live mode includes parse + evaluate + grouping but not fzf rendering. This accurately reflects the vault search engine's performance.

**Estimated changes:** ~50 lines in `search.lua`, ~5 lines in `config.lua`.

---

## Sub-Feature 3: Fuzzy Field Name Correction

### Motivation

A typo in a field name (`tpye:meeting`, `priortiy:1`, `createdd:>7d`) silently becomes a TEXT token, producing a full-text grep for the literal string `tpye:meeting` instead of a metadata filter. The user sees wrong results with no indication of the mistake. Computing edit distance against known field names can catch these typos and warn the user.

### Architecture

The correction logic sits in `search_query.lua` at the tokenizer level. When the tokenizer encounters a word containing `:` that fails `parse_field_token()` (returns nil), it checks whether the name portion is a near-match for any known field. If the edit distance is <= 2, it emits a warning via a callback and optionally auto-corrects.

The known field list is sourced from `config.search.builtin_fields` plus task prefixes, `has:`, and `graph:`. This avoids a dependency on `config.lua` inside the pure-Lua tokenizer by accepting the field list as a parameter.

### Implementation

#### Changes to `search_query.lua`

**1. Add Levenshtein distance function** (pure Lua, no dependencies):

```lua
--- Compute the Levenshtein edit distance between two strings.
---@param a string
---@param b string
---@return number
local function edit_distance(a, b)
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end

  -- Use two rows instead of full matrix (space optimization)
  local prev = {}
  local curr = {}
  for j = 0, lb do prev[j] = j end

  for i = 1, la do
    curr[0] = i
    for j = 1, lb do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
      curr[j] = math.min(
        prev[j] + 1,       -- deletion
        curr[j - 1] + 1,   -- insertion
        prev[j - 1] + cost -- substitution
      )
    end
    prev, curr = curr, prev
  end
  return prev[lb]
end
```

**2. Add field name suggestion function:**

```lua
--- Find the closest known field name to an unknown identifier.
--- Returns the best match if edit distance <= max_distance, or nil.
---@param unknown string the unrecognized field name
---@param known_fields string[] list of valid field names
---@param max_distance? number threshold (default 2)
---@return string|nil suggested field name
---@return number|nil edit distance
function M.suggest_field(unknown, known_fields, max_distance)
  max_distance = max_distance or 2
  local best_field = nil
  local best_dist = max_distance + 1

  for _, field in ipairs(known_fields) do
    local dist = edit_distance(unknown:lower(), field:lower())
    if dist < best_dist then
      best_dist = dist
      best_field = field
    end
  end

  if best_dist <= max_distance then
    return best_field, best_dist
  end
  return nil, nil
end
```

**3. Add a warnings list to tokenize() output.**

Rather than calling `vim.notify()` inside the tokenizer (which is pure Lua with no Neovim deps), the tokenizer accumulates warnings that the caller can handle:

```lua
--- Tokenize a search query string into a flat list of tokens.
---
--- Returns a token list ending with EOF on success, or nil + error string.
--- Third return value is an array of warning strings (e.g., field suggestions).
---
---@param input string  the raw query text
---@param opts? { known_fields?: string[] }
---@return table[]|nil  list of tokens
---@return string|nil   error message on failure
---@return string[]     warnings (may be empty)
function M.tokenize(input, opts)
  local tokens = {}
  local warnings = {}
  local known_fields = opts and opts.known_fields or nil
  local i = 1
  local len = #input

  while i <= len do
    -- ... existing tokenization logic ...

    -- In the unquoted word branch, after parse_field_token returns nil:
    else
      -- ... existing word extraction ...

      if word:find(":", 1, true) then
        local ftok = parse_field_token(word, start)
        if ftok then
          tokens[#tokens + 1] = ftok
        else
          -- Check for near-match field name suggestion
          if known_fields then
            local colon = word:find(":", 1, true)
            local name = word:sub(1, colon - 1):lower()
            -- Skip URL-like patterns (already handled by parse_field_token)
            if name:match("^[a-z][a-z0-9_-]*$") then
              local suggestion = M.suggest_field(name, known_fields)
              if suggestion then
                warnings[#warnings + 1] = string.format(
                  "Unknown field '%s' -- did you mean '%s'?", name, suggestion
                )
              end
            end
          end
          tokens[#tokens + 1] = token(TK.TEXT, word, start)
        end
      else
        tokens[#tokens + 1] = token(TK.TEXT, word, start)
      end
    end
  end

  tokens[#tokens + 1] = token(TK.EOF, nil, i)
  return tokens, nil, warnings
end
```

**4. Update `parse_query()` to forward warnings:**

```lua
---@param query_string string  the raw search query
---@param opts? { known_fields?: string[] }
---@return table|nil            AST root node
---@return string|nil           error message on failure
---@return string|nil           group mode from group: directive
---@return string[]             warnings from tokenizer
function M.parse_query(query_string, opts)
  if type(query_string) ~= "string" or query_string:match("^%s*$") then
    return nil, "Empty query", nil, {}
  end
  local tokens, tok_err, warnings = M.tokenize(query_string, opts)
  if not tokens then return nil, tok_err, nil, warnings or {} end
  local group_mode = M.extract_group(tokens)
  if #tokens == 1 and tokens[1].type == TK.EOF then
    return { type = "match_all" }, nil, group_mode, warnings
  end
  local ast, parse_err = M.parse(tokens)
  return ast, parse_err, group_mode, warnings
end
```

#### Changes to `search.lua`

**1. Build known_fields list** and pass to `parse_query()`:

```lua
--- Build the full list of known field names for suggestion/correction.
---@return string[]
local function get_known_fields()
  local fields = {}
  -- Builtin fields from config
  for _, f in ipairs(config.search and config.search.builtin_fields or {}) do
    fields[#fields + 1] = f
  end
  -- Field aliases
  for alias, _ in pairs(config.search and config.search.field_aliases or {}) do
    fields[#fields + 1] = alias
  end
  -- Task prefixes
  for _, prefix in ipairs({
    "task", "task-todo", "task-done",
    "task-due", "task-priority", "task-tag",
    "task-state", "task-repeat", "task-completion",
    "task-scheduled",
  }) do
    fields[#fields + 1] = prefix
  end
  -- Special prefixes
  for _, special in ipairs({ "has", "graph", "group" }) do
    fields[#fields + 1] = special
  end
  return fields
end
```

**2. Display warnings after query execution** in `execute_advanced_query()`:

```lua
  local known_fields = get_known_fields()
  local ast, err, group_mode, warnings = search_query.parse_query(
    query_string, { known_fields = known_fields }
  )

  -- Show field name suggestions
  if warnings and #warnings > 0 and not opts.silent then
    for _, w in ipairs(warnings) do
      vim.notify("Search: " .. w, vim.log.levels.WARN)
    end
  end
```

**3. In live mode**, display warnings sparingly (only on first occurrence per query to avoid spam):

```lua
  local warned_queries = {}

  fzf.fzf_live(function(args)
    local query_string = type(args) == "table" and args[1] or args
    -- ...
    local ast, _, group_mode, warnings = search_query.parse_query(
      query_string, { known_fields = known_fields }
    )
    if warnings and #warnings > 0 and not warned_queries[query_string] then
      warned_queries[query_string] = true
      vim.schedule(function()
        for _, w in ipairs(warnings) do
          vim.notify("Search: " .. w, vim.log.levels.WARN)
        end
      end)
    end
    -- ...
  end, ...)
```

#### Changes to `config.lua`

```lua
  -- Field name correction
  field_correction = {
    -- Enable fuzzy field name correction (suggest similar field names on typos).
    enabled = true,

    -- Maximum edit distance for suggestions (1 = strict, 2 = lenient).
    max_distance = 2,

    -- Auto-correct: if true, silently treat the typo as the suggested field.
    -- If false (default), show a warning but search for the literal text.
    auto_correct = false,
  },
```

#### Auto-Correction Mode

When `config.search.field_correction.auto_correct` is true, instead of emitting a warning and tokenizing as TEXT, the tokenizer replaces the misspelled field name with the suggested one and re-parses as a FIELD token:

```lua
          if known_fields then
            local colon = word:find(":", 1, true)
            local name = word:sub(1, colon - 1):lower()
            if name:match("^[a-z][a-z0-9_-]*$") then
              local suggestion = M.suggest_field(name, known_fields)
              if suggestion then
                local auto_correct = opts and opts.auto_correct
                if auto_correct then
                  -- Re-try with corrected field name
                  local corrected = suggestion .. word:sub(colon)
                  local corrected_tok = parse_field_token(corrected, start)
                  if corrected_tok then
                    warnings[#warnings + 1] = string.format(
                      "Auto-corrected '%s' to '%s'", name, suggestion
                    )
                    tokens[#tokens + 1] = corrected_tok
                    goto continue
                  end
                end
                warnings[#warnings + 1] = string.format(
                  "Unknown field '%s' -- did you mean '%s'?", name, suggestion
                )
              end
            end
          end
```

#### Edge Cases

1. **Short field names:** `a:value` (1-char name) has edit distance 1 from many fields. The `max_distance = 2` threshold could produce false positives. Mitigation: skip suggestions when the unknown name is shorter than 3 characters.

2. **Intentional generic fields:** Users can have custom frontmatter fields not in `builtin_fields`. Suggesting a different field for `project:Alpha` when `project` is a valid (but unlisted) frontmatter field name would be wrong. Mitigation: only suggest when `parse_field_token()` returns nil (which means the field was rejected by the identifier check), not for all unknown field names. Actually, `parse_field_token()` accepts any identifier matching `^[a-z][a-z0-9_-]*$` as a generic FIELD -- it only returns nil for non-identifier prefixes (e.g., URLs). So suggestions should only fire when `parse_field_token()` returns nil, which means the name portion failed the identifier regex. For valid-but-unknown fields, the tokenizer already produces a FIELD token and no suggestion is needed.

    Wait -- re-reading the code: `parse_field_token()` at line 186 checks `name:match("^[a-z][a-z0-9_-]*$")` and returns nil if it fails. If the name passes the regex, it proceeds to `parse_field_value()` and produces a FIELD token regardless of whether the field name is known. So `tpye:meeting` would pass the regex (all lowercase alpha) and produce a FIELD token, not a TEXT token. The suggestion logic should fire at a different point.

    **Corrected approach:** Instead of checking at the tokenizer level (where all valid identifiers produce FIELD tokens), perform the field name check in `match_field()` within `search_filter.lua`. When `match_field()` encounters an unknown field name that produces no match via `get_generic_field()`, it falls through to the generic handler which returns false. The warning should be emitted during AST evaluation, not tokenization.

    **Better approach:** Check at the search.lua level after parsing. Walk the AST, collect all FIELD node names, compare against known fields + index frontmatter keys. Warn about names that match no known field or index key and have a close edit-distance match to a known field.

```lua
--- Collect all field names from an AST.
---@param ast table
---@return string[] field_names
local function collect_field_names(ast)
  if not ast then return {} end
  local names = {}
  if ast.type == "field" then
    names[#names + 1] = ast.name
  elseif ast.type == "and" or ast.type == "or" then
    vim.list_extend(names, collect_field_names(ast.left))
    vim.list_extend(names, collect_field_names(ast.right))
  elseif ast.type == "not" then
    vim.list_extend(names, collect_field_names(ast.operand))
  end
  return names
end

--- Check field names in the AST and warn about probable typos.
---@param ast table
---@param idx table VaultIndex
local function warn_unknown_fields(ast, idx)
  if not config.search or config.search.field_correction == false then return end
  local correction = config.search.field_correction or {}
  if correction.enabled == false then return end

  local known = get_known_fields()
  -- Add frontmatter keys observed in the index
  if idx then
    local fm_keys = idx:all_frontmatter_keys()
    if fm_keys then
      vim.list_extend(known, fm_keys)
    end
  end

  local used = collect_field_names(ast)
  local known_set = {}
  for _, f in ipairs(known) do known_set[f:lower()] = true end

  local search_query = require("andrew.vault.search_query")
  local max_dist = correction.max_distance or 2
  for _, name in ipairs(used) do
    if not known_set[name:lower()] then
      local suggestion = search_query.suggest_field(name, known, max_dist)
      if suggestion then
        vim.notify(
          string.format("Search: unknown field '%s' -- did you mean '%s'?", name, suggestion),
          vim.log.levels.WARN
        )
      end
    end
  end
end
```

Call `warn_unknown_fields(ast, idx)` inside `execute_advanced_query()` after the AST is parsed and the index is available.

3. **Performance:** Levenshtein distance is O(n*m) per pair. With ~30 known fields and typically 1-3 field names per query, the total work is negligible (< 1ms).

4. **Case sensitivity:** Edit distance comparison is case-insensitive (both sides lowered).

**Estimated changes:** ~80 lines in `search_query.lua`, ~50 lines in `search.lua`, ~10 lines in `config.lua`.

---

## Sub-Feature 4: Regex Flags Support

### Motivation

The tokenizer parses `/pattern/` as a REGEX token but discards anything after the closing `/`. Users familiar with regex conventions expect `/pattern/i` for case-insensitive matching and `/pattern/m` for multiline. Currently, ripgrep defaults to case-sensitive regex matching (via `build_rg_args()` in `search_filter.lua`), with no way to override.

### Architecture

The tokenizer is extended to consume optional flag characters after the closing `/`. Flags are stored in the REGEX token and propagated through the AST to `build_rg_args()` in `search_filter.lua`, where they map to ripgrep CLI options.

### Supported Flags

| Flag | Meaning | Ripgrep Equivalent |
|------|---------|-------------------|
| `i` | Case-insensitive | `--case-sensitive` removed, `-i` added |
| `m` | Multiline (`.` matches newline) | `--multiline` |
| `s` | Dotall (`.` matches newline, alias for `m` in ripgrep) | `--multiline --multiline-dotall` |

Note: ripgrep's `--multiline` enables multi-line matching (pattern can span lines), while `--multiline-dotall` makes `.` match newlines. The `m` flag maps to `--multiline` (cross-line patterns), and `s` maps to `--multiline --multiline-dotall` (dotall semantics).

### Implementation

#### Changes to `search_query.lua`

**1. Extend the regex tokenizer** to consume flags after the closing `/`:

The existing regex parsing (lines 233-248) handles the `/pattern/` syntax. After consuming the closing `/`, consume any trailing `[ims]` characters:

```lua
    -- Regex
    elseif b == 47 then -- /
      local start = i
      i = i + 1
      while i <= len do
        local rb = input:byte(i)
        if rb == 47 then break end            -- closing /
        if rb == 92 and i + 1 <= len then     -- backslash: skip escaped char
          i = i + 1
        end
        i = i + 1
      end
      if i > len then
        return nil, "Unterminated regex at position " .. start
      end
      local pattern = input:sub(start + 1, i - 1)
      i = i + 1 -- skip closing /

      -- Consume optional flags after closing /
      local flags = ""
      while i <= len do
        local fb = input:byte(i)
        -- i=105, m=109, s=115
        if fb == 105 or fb == 109 or fb == 115 then
          flags = flags .. string.char(fb)
          i = i + 1
        else
          break
        end
      end

      if flags ~= "" then
        tokens[#tokens + 1] = token(TK.REGEX, { pattern = pattern, flags = flags }, start)
      else
        tokens[#tokens + 1] = token(TK.REGEX, pattern, start)
      end
```

**2. Update the parser** to normalize the REGEX token value:

The parser's `parse_primary()` function (line 472-475) currently reads `tok.value` as a plain string for REGEX:

```lua
  if tok.type == TK.REGEX then
    P:advance()
    -- Handle both old (string) and new (table with flags) formats
    if type(tok.value) == "table" then
      return { type = "regex", pattern = tok.value.pattern, flags = tok.value.flags }
    end
    return { type = "regex", pattern = tok.value }
  end
```

#### Changes to `search_filter.lua`

**1. Update `build_rg_args()`** to handle regex flags:

```lua
local function build_rg_args(node, vault_path, files_from)
  local args = {
    "rg",
    "--column",
    "--line-number",
    "--no-heading",
    "--color=never",
  }

  if node.type == "text" then
    if node.quoted then
      args[#args + 1] = "--fixed-strings"
    else
      args[#args + 1] = "--smart-case"
    end
    args[#args + 1] = "--"
    args[#args + 1] = node.value
  elseif node.type == "regex" then
    -- Apply regex flags
    local flags = node.flags or ""
    if flags:find("i") then
      args[#args + 1] = "--case-insensitive"
    end
    if flags:find("m") then
      args[#args + 1] = "--multiline"
    end
    if flags:find("s") then
      args[#args + 1] = "--multiline"
      args[#args + 1] = "--multiline-dotall"
    end
    args[#args + 1] = "--"
    args[#args + 1] = node.pattern
  end

  if files_from then
    args[#args + 1] = "--files-from=" .. files_from
  else
    args[#args + 1] = vault_path
  end

  return args
end
```

#### Changes to `search.lua`

**1. Update help text** in `search_help()`:

Replace the existing regex line:

```lua
    "  /^## Results/            Regex pattern",
```

With:

```lua
    "  /^## Results/            Regex pattern",
    "  /pattern/i               Case-insensitive regex",
    "  /pattern/m               Multiline regex",
    "  /pattern/s               Dotall (. matches newline)",
```

#### Edge Cases

1. **Unknown flags:** Characters after `/` that are not `i`, `m`, or `s` stop flag consumption. `/pattern/x` would parse as `/pattern/` with no flags, followed by the text `x`. This is correct -- `x` is not a recognized flag.

2. **Flag ordering:** `/pattern/im` and `/pattern/mi` are equivalent. The flag string is checked with `:find()` for each flag character, so order does not matter.

3. **Empty flags:** `/pattern/` without trailing flags behaves identically to the current implementation (backward compatible).

4. **Regex in non-ripgrep context:** The `classify()` function treats regex nodes as TEXT_TYPES (requiring ripgrep). Flags only affect the `build_rg_args()` function. If a regex appears in a NOT-only metadata context, the flags propagate correctly through `ripgrep_in_files()`.

5. **Multiline output format:** When `--multiline` is used, ripgrep may return matches spanning multiple lines. The current result parsing (`(result.stdout or ""):gmatch("[^\n]+")`) would split these across multiple result entries. This is acceptable for display purposes -- each line of a multiline match becomes a separate fzf entry, all pointing to the same file. For exact multiline fidelity, the `--multiline` output would need special handling, but this is an edge case that can be addressed later.

6. **Token value backward compatibility:** The REGEX token value changes from a plain string to either a string or a table `{ pattern, flags }`. The parser normalizes both into the AST node format `{ type = "regex", pattern = ..., flags = ... }`. The `build_rg_args()` function handles the optional `flags` field with a fallback to `""`. Existing saved searches with `/pattern/` queries continue to work.

**Estimated changes:** ~20 lines in `search_query.lua`, ~15 lines in `search_filter.lua`, ~5 lines in `search.lua`.

---

## Sub-Feature 5: Field Value Completion

### Motivation

The existing `_complete_advanced()` function in `search.lua` already provides value completions for several field prefixes: `type:`, `status:`, `tag:`, `links-to:`, `linked-from:`, `alias:`, `task-state:`, `task-priority:`, `task-due:`, `task-tag:`, `has:`, `group:`, and `graph:`. However, generic frontmatter fields (e.g., `area:`, `project:`, `maturity:`) have no value completion. These fields are often used in queries, and their possible values can be aggregated from the vault index.

### Architecture

Extend `_complete_advanced()` to provide value completions for any field name by aggregating values from the vault index. When the cursor is positioned after `fieldname:`, the completion function:

1. Checks for a hard-coded handler (existing behavior for `type:`, `status:`, etc.)
2. Falls back to aggregating values from `idx.files[*].frontmatter[fieldname]` and `idx.files[*].inline_fields[fieldname]`
3. Sorts values by frequency (most-used first)

### Implementation

#### Changes to `search.lua`

**1. Add a generic field value aggregation function:**

```lua
--- Aggregate all unique values for a field name from the vault index.
--- Returns values sorted by frequency (most common first).
---@param field_name string
---@return string[]
local function aggregate_field_values(field_name)
  local vault_index = require("andrew.vault.vault_index")
  local idx = vault_index.current()
  if not idx or not idx:is_ready() then return {} end

  local counts = {}  -- value -> count

  for _, entry in pairs(idx.files) do
    local val = nil
    -- Check frontmatter
    if entry.frontmatter and entry.frontmatter[field_name] ~= nil then
      val = entry.frontmatter[field_name]
    end
    -- Check inline_fields
    if val == nil and entry.inline_fields and entry.inline_fields[field_name] ~= nil then
      val = entry.inline_fields[field_name]
    end
    -- Check field aliases
    if val == nil then
      local aliases = config.search and config.search.field_aliases or {}
      local alias_path = aliases[field_name]
      if alias_path then
        local v = entry
        for part in alias_path:gmatch("[^%.]+") do
          if type(v) ~= "table" then v = nil; break end
          v = v[part]
        end
        val = v
      end
    end

    if val ~= nil then
      -- Handle list values (e.g., tags stored as arrays)
      if type(val) == "table" then
        for _, v in ipairs(val) do
          local sv = tostring(v)
          counts[sv] = (counts[sv] or 0) + 1
        end
      else
        local sv = tostring(val)
        counts[sv] = (counts[sv] or 0) + 1
      end
    end
  end

  -- Sort by frequency (descending), then alphabetically
  local sorted = {}
  for v, c in pairs(counts) do
    sorted[#sorted + 1] = { value = v, count = c }
  end
  table.sort(sorted, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.value < b.value
  end)

  local result = {}
  for _, item in ipairs(sorted) do
    result[#result + 1] = item.value
  end
  return result
end
```

**2. Add generic fallback to `_complete_advanced()`:**

At the end of `_complete_advanced()`, after all the specific field handlers and before the `return candidates` statement, add:

```lua
  -- Generic field value completion: if lead is "fieldname:partial" and no
  -- specific handler matched above, aggregate values from the vault index.
  if #candidates == 0 and lead:find(":", 1, true) then
    local colon = lead:find(":", 1, true)
    local field_name = lead:sub(1, colon - 1):lower()
    local prefix = lead:sub(1, colon)
    local rest = lead:sub(colon + 1):lower()

    -- Skip fields already handled above
    local handled = {
      type = true, status = true, tag = true, has = true,
      group = true, graph = true,
      ["links-to"] = true, ["linked-from"] = true, alias = true,
      ["task-state"] = true, ["task-priority"] = true,
      ["task-due"] = true, ["task-completion"] = true,
      ["task-scheduled"] = true, ["task-tag"] = true,
    }
    if not handled[field_name] then
      local values = aggregate_field_values(field_name)
      for _, v in ipairs(values) do
        if v:lower():sub(1, #rest) == rest then
          if v:find(" ") then
            candidates[#candidates + 1] = prefix .. '"' .. v .. '"'
          else
            candidates[#candidates + 1] = prefix .. v
          end
        end
      end
    end
  end

  return candidates
```

**3. Add config-defined enum values:**

For fields with a small set of valid values (like `maturity`), config-defined enums should take priority over index-aggregated values. Add a config option:

#### Changes to `config.lua`

```lua
  -- Predefined enum values for field completion.
  -- Maps field names to arrays of valid values. These take priority over
  -- index-aggregated values in Tab completion.
  field_enums = {
    maturity = { "Seed", "Developing", "Mature", "Evergreen" },
    -- Additional fields can be added by the user:
    -- area = { "Research", "Engineering", "Teaching" },
  },
```

Then in `_complete_advanced()`, check `config.search.field_enums` before falling back to aggregation:

```lua
    if not handled[field_name] then
      -- Check config-defined enums first
      local enums = config.search and config.search.field_enums or {}
      if enums[field_name] then
        for _, v in ipairs(enums[field_name]) do
          if v:lower():sub(1, #rest) == rest:lower() then
            if v:find(" ") then
              candidates[#candidates + 1] = prefix .. '"' .. v .. '"'
            else
              candidates[#candidates + 1] = prefix .. v
            end
          end
        end
      else
        -- Aggregate from index
        local values = aggregate_field_values(field_name)
        for _, v in ipairs(values) do
          if v:lower():sub(1, #rest) == rest then
            if v:find(" ") then
              candidates[#candidates + 1] = prefix .. '"' .. v .. '"'
            else
              candidates[#candidates + 1] = prefix .. v
            end
          end
        end
      end
    end
```

#### Edge Cases

1. **Large value sets:** A field like `project` might have hundreds of unique values across the vault. The aggregation iterates all index entries once (O(N)) and collects unique values. For N=1000 entries, this takes < 5ms. The fzf completion popup handles large candidate lists natively.

2. **Numeric values:** Fields like `priority` store numbers. `tostring(val)` converts them to strings for completion. The user sees `priority:3` as a candidate.

3. **List-valued fields:** Some frontmatter fields are arrays (e.g., `tags: [a, b, c]`). The aggregation function flattens arrays and counts each element independently.

4. **Null/empty values:** `nil` values are skipped; empty string values (`""`) are included (they represent "field exists but is empty").

5. **Quoted values:** Values containing spaces are automatically quoted in the completion candidate (e.g., `area:"Fluid Dynamics"`).

6. **Performance in live mode:** `_complete_advanced()` is only called when Tab is pressed in the prompt mode buffer. It is not called during live mode keystroke evaluation, so performance is not a concern.

7. **Cache invalidation:** The aggregation function calls `vault_index.current()` on each invocation, which returns the current index instance. No additional caching is needed since the index is already in memory and the aggregation is fast.

**Estimated changes:** ~60 lines in `search.lua`, ~10 lines in `config.lua`.

---

## File Summary

| File | Action | Sub-features | Estimated Lines |
|------|--------|-------------|-----------------|
| `lua/andrew/vault/search_history.lua` | **Create** | 1 (history) | ~160 |
| `lua/andrew/vault/search.lua` | **Modify** | 1, 2, 3, 5 | ~130 |
| `lua/andrew/vault/search_query.lua` | **Modify** | 3, 4 | ~100 |
| `lua/andrew/vault/search_filter.lua` | **Modify** | 4 | ~15 |
| `lua/andrew/vault/config.lua` | **Modify** | 1, 2, 3, 5 | ~30 |

**Total estimated new/changed lines:** ~435

---

## Config Summary

All new config options live inside `M.search` in `config.lua`:

```lua
M.search = {
  -- ... existing options ...

  -- Search history (Sub-feature 1)
  history = {
    enabled = true,          -- record queries to history
    max_entries = 200,       -- maximum stored queries
  },

  -- Result statistics (Sub-feature 2)
  show_stats = true,         -- show match/file count and timing in results

  -- Field name correction (Sub-feature 3)
  field_correction = {
    enabled = true,          -- enable fuzzy field name correction
    max_distance = 2,        -- max edit distance for suggestions
    auto_correct = false,    -- silently use suggestion instead of warning
  },

  -- Predefined enum values for field completion (Sub-feature 5)
  field_enums = {
    maturity = { "Seed", "Developing", "Mature", "Evergreen" },
  },
}
```

---

## Keybinding Summary

| Binding | Mode | Action | Sub-feature |
|---------|------|--------|-------------|
| `<leader>vfH` | Normal | Open search history picker | 1 |
| `<C-r>` | Insert (search prompt) | Recall query from history | 1 |
| `<C-d>` | Normal (history picker) | Delete selected history entry | 1 |

---

## Implementation Order

The sub-features are independent and can be implemented in any order. The recommended order prioritizes user-visible impact:

### Phase 1: Search History (Sub-feature 1)
- Create `search_history.lua`
- Integrate `record()` into `search.lua:track()`
- Add picker, keybindings, commands
- Add config options

### Phase 2: Result Statistics (Sub-feature 2)
- Add counting helpers to `search.lua`
- Add timing to `execute_advanced_query()`
- Add stats line to live mode
- Add config option

### Phase 3: Regex Flags (Sub-feature 4)
- Extend tokenizer in `search_query.lua`
- Update parser for flags in AST
- Update `build_rg_args()` in `search_filter.lua`
- Update help text

### Phase 4: Field Value Completion (Sub-feature 5)
- Add `aggregate_field_values()` to `search.lua`
- Add generic fallback in `_complete_advanced()`
- Add `field_enums` to config

### Phase 5: Fuzzy Field Name Correction (Sub-feature 3)
- Add `edit_distance()` and `suggest_field()` to `search_query.lua`
- Add AST field name collection and warning logic to `search.lua`
- Add `field_correction` to config

---

## Testing Plan

### Sub-feature 1: Search History

1. Run `:VaultSearchAdvanced`, enter and execute several queries
2. Run `:VaultSearchHistory` (or `<leader>vfH`) -- verify queries appear ranked by recency
3. Execute the same query multiple times -- verify its score increases (moves to top)
4. Wait several minutes, run other queries -- verify older queries drop in ranking
5. Press `<C-d>` on a history entry -- verify it is removed
6. Run `:VaultSearchHistoryClear` -- verify all history is removed
7. Verify `.vault-search-history.json` is written to the vault root
8. Close and reopen Neovim -- verify history persists
9. In the search prompt, press `<C-r>` -- verify history picker appears and selected query is inserted
10. With `max_entries = 5` in config, record 10 queries -- verify oldest entries are pruned

### Sub-feature 2: Result Statistics

1. Run `:VaultSearchAdvanced` with `type:meeting` -- verify header shows "N matches in M files (Xms)"
2. Run with a text query `deploy` -- verify counts reflect ripgrep matches
3. Run with `group:folder type:meeting` -- verify counts exclude group headers
4. Run in live mode -- verify stats line appears at top of results and updates per keystroke
5. Run a query returning 0 results -- verify notification includes timing but no stats line
6. Set `show_stats = false` in config -- verify stats are suppressed

### Sub-feature 3: Fuzzy Field Name Correction

1. Enter `tpye:meeting` -- verify warning "Unknown field 'tpye' -- did you mean 'type'?"
2. Enter `priortiy:1` -- verify suggestion for `priority`
3. Enter `createdd:>7d` -- verify suggestion for `created`
4. Enter `customfield:value` (a valid but unknown field) -- verify no warning (field produces a FIELD token)
5. Enter `xyz:value` where `xyz` is distant from all known fields -- verify no suggestion
6. With `auto_correct = true`, enter `tpye:meeting` -- verify it evaluates as `type:meeting` with an auto-correct notification
7. In live mode, verify warnings appear only once per query (not on every keystroke)
8. Verify the `edit_distance` function: `edit_distance("type", "tpye")` = 2, `edit_distance("priority", "priortiy")` = 2

### Sub-feature 4: Regex Flags

1. Enter `/TODO/` -- verify case-sensitive matching (existing behavior preserved)
2. Enter `/todo/i` -- verify case-insensitive matching (finds TODO, Todo, todo)
3. Enter `/^## .*\nContent/m` -- verify multiline matching spans lines
4. Enter `/pattern/im` -- verify both flags are applied
5. Enter `/pattern/x` -- verify `x` is not consumed as a flag (treated as separate text)
6. Enter `/pattern/` (no flags) -- verify backward compatibility
7. Verify in fzf results that matched lines display correctly
8. Check help float includes new regex flag documentation

### Sub-feature 5: Field Value Completion

1. In the search prompt, type `maturity:` and press Tab -- verify enum values appear (Seed, Developing, Mature, Evergreen)
2. Type `maturity:S` and press Tab -- verify only "Seed" is suggested
3. Type `area:` and press Tab (assuming `area` is a frontmatter field in the vault) -- verify aggregated values appear, sorted by frequency
4. Type `type:` and press Tab -- verify existing handler still works (not overridden by generic fallback)
5. Type `tag:` and press Tab -- verify existing handler still works
6. Type `unknownfield:` and press Tab -- verify no suggestions (field does not exist in vault)
7. Add `field_enums = { area = { "Research", "Engineering" } }` to config -- verify config values appear for `area:` instead of aggregated values
8. Verify values containing spaces are auto-quoted in completion
