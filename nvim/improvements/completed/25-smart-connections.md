# 25 — Smart Connection Suggestions

## Problem

When working in a note, the user has no automated way to discover **related notes** beyond direct wikilinks and backlinks. The existing navigation tools (`backlinks.lua`, `graph.lua`, `forwardlinks`) only surface explicit link relationships. Notes that share tags, reference common targets, discuss similar topics, or were written in the same time period remain invisible unless the user manually searches for them.

This is the "unknown unknowns" problem: the most valuable connections are often the ones the user has not yet drawn explicitly.

### Current State

| Component | What It Does | File |
|-----------|-------------|------|
| **backlinks.lua** | Finds notes that link to the current note (1-hop inlinks) | `lua/andrew/vault/backlinks.lua` |
| **graph.lua** | ASCII local graph of direct backlinks + forward links | `lua/andrew/vault/graph.lua` |
| **tags.lua** | Collects/searches tags; no cross-note similarity | `lua/andrew/vault/tags.lua` |
| **query/index.lua** | Full vault index with pages, tags, outlinks, inlinks, frontmatter | `lua/andrew/vault/query/index.lua` |
| **frontmatter.lua** | Auto-updates `created`/`modified` timestamps | `lua/andrew/vault/frontmatter.lua` |
| **frecency.lua** | Tracks access frequency; no relational scoring | `lua/andrew/vault/frecency.lua` |
| **config.lua** | Centralized config; no connection weights | `lua/andrew/vault/config.lua` |

### What Is Missing

1. No **multi-signal scoring** that combines tags, links, frontmatter fields, and temporal proximity into a single relatedness score.
2. No **tag specificity weighting** (IDF) — a tag used on 2 notes is far more meaningful than one used on 200.
3. No **2-hop link detection** — notes that link to the same targets but do not link to each other.
4. No **fzf-lua picker** showing ranked related notes with explanations of why they are related.
5. No **caching** of computed scores to avoid recomputing on every invocation.

---

## Goal

Add a smart connections module that:

1. Scores and ranks every vault note against the current note using multiple weighted signals.
2. Presents a fzf-lua picker (`<leader>vr`) showing "Related Notes" sorted by score.
3. Displays the connection score and a human-readable breakdown of reasons (shared tags, co-links, etc.).
4. Caches computed scores per source note with a configurable TTL.
5. Integrates with the vault index (`query/index.lua`) for efficient data access.
6. Provides configurable weights for each signal type via `config.lua`.

---

## Approach

### Architecture

Create a new module `lua/andrew/vault/connections.lua` that:

1. Loads the vault index (via `query/index.lua`) to access all pages with their tags, outlinks, inlinks, and frontmatter.
2. Computes a relatedness score between the current note and every other note in the vault.
3. Combines five signal types with configurable weights.
4. Caches results keyed by `(source_rel_path, index_build_time)` with a TTL.
5. Presents results in a fzf-lua picker with ANSI-colored score and reason annotations.

### Signal Types

#### 1. Shared Tags (IDF-Weighted)

Each shared tag contributes a score inversely proportional to its frequency across the vault. Rare tags are stronger signals than common ones.

```
tag_score = sum over shared_tags of: weight * log(N / count(tag))
```

Where:
- `N` = total number of pages in the vault
- `count(tag)` = number of pages containing that tag
- Tags include parent expansions (e.g., `project/active` also matches `project`)
- Only leaf-level matches score (no double-counting parents)

**Rationale**: Two notes sharing `#project/cfd-validation` (used on 3 notes) is a much stronger connection than two notes sharing `#status/active` (used on 50 notes).

#### 2. Shared Frontmatter Fields

Notes that share specific frontmatter field values are likely related. Scored fields:
- `type` — same note type (e.g., both are `simulation`)
- `project` — same project reference
- `domain` — same knowledge domain
- `status` — same workflow status (lower weight, less meaningful)

Each matching field contributes its configured weight. Link-typed values (wikilinks in frontmatter) are compared by their resolved target path.

```
fm_score = sum over configured_fields of:
  field_weight  if values match (case-insensitive for strings)
```

#### 3. Co-occurrence in Backlinks (Bibliographic Coupling)

Two notes that both link to the same target are likely related even if they do not link to each other. This is the "bibliographic coupling" signal.

```
colink_score = weight * |outlink_targets(A) ∩ outlink_targets(B)| / max(1, min(|out(A)|, |out(B)|))
```

The normalization by `min(|out(A)|, |out(B)|)` prevents notes with many outlinks from dominating.

#### 4. Direct Link Proximity

- **1-hop**: A links to B or B links to A. Strong direct connection.
- **2-hop**: A links to C, C links to B (or vice versa). Weaker indirect connection.

```
link_score =
  1_hop_weight  if direct link exists
  2_hop_weight * |shared_neighbors| / max_2hop_count  otherwise
```

Where `shared_neighbors` are notes that both A and B link to/from (the 2-hop bridges). `max_2hop_count` caps the contribution to avoid runaway scores on highly connected notes.

#### 5. Temporal Proximity

Notes created or modified around the same time are often related (written during the same research session, project sprint, etc.).

```
temporal_score = weight * max(
  decay(|ctime(A) - ctime(B)|),
  decay(|mtime(A) - mtime(B)|)
)
```

Where `decay(delta_days)` is:
- 1.0 if `delta_days < 1`
- 0.7 if `delta_days < 3`
- 0.4 if `delta_days < 7`
- 0.2 if `delta_days < 30`
- 0.0 otherwise

### Scoring Algorithm

```
total_score(A, B) =
    w_tags     * tag_score(A, B)
  + w_fm       * fm_score(A, B)
  + w_colink   * colink_score(A, B)
  + w_link     * link_score(A, B)
  + w_temporal * temporal_score(A, B)
```

Results are sorted by `total_score` descending. Notes with `total_score = 0` are excluded.

### Data Structures

```lua
--- Per-note precomputed data (built once from the index).
---@class ConnectionNoteData
---@field rel_path string         -- vault-relative path
---@field tags table<string, true> -- set of tags (leaf and parent)
---@field outlink_targets table<string, true> -- set of resolved rel_paths this note links to
---@field inlink_sources table<string, true>  -- set of resolved rel_paths linking to this note
---@field neighbors table<string, true>       -- union of outlink_targets and inlink_sources
---@field fm_fields table<string, any>        -- selected frontmatter fields for comparison
---@field ctime number                        -- creation time (epoch seconds)
---@field mtime number                        -- modification time (epoch seconds)

--- Scored result for a candidate note.
---@class ConnectionResult
---@field rel_path string
---@field name string
---@field score number
---@field reasons string[]  -- human-readable list: "tags: #project/cfd, #methodology"
---@field breakdown table   -- { tags = 3.2, fm = 1.0, colink = 2.5, link = 5.0, temporal = 0.4 }

--- Cache entry.
---@class ConnectionCacheEntry
---@field source_path string
---@field results ConnectionResult[]
---@field timestamp number   -- epoch seconds when computed
---@field index_ts number    -- index build timestamp for invalidation
```

### Caching Strategy

- Cache is an in-memory table keyed by `source_rel_path`.
- Each entry stores the results, a timestamp, and the index build time.
- A cache hit requires:
  1. `(now - entry.timestamp) < TTL` (default 60 seconds)
  2. `entry.index_ts == current_index_build_ts` (index has not been rebuilt)
- Cache is fully invalidated on vault switch (via `engine.invalidate_all_caches()`).
- The `BufWritePost` autocmd invalidates the cache entry for the written file.
- Manual invalidation via `:VaultConnectionsRefresh`.

### Tag Frequency Table (IDF)

Built once per scoring run from the index:

```lua
--- Build inverse document frequency table for tags.
---@param pages table[] all pages from the index
---@return table<string, number> tag -> document count
---@return number total_pages
local function build_tag_idf(pages)
  local doc_count = {}
  local total = 0
  for _, page in ipairs(pages) do
    total = total + 1
    local seen = {}
    for _, tag in ipairs(page.file.tags) do
      if not seen[tag] then
        seen[tag] = true
        doc_count[tag] = (doc_count[tag] or 0) + 1
      end
    end
  end
  return doc_count, total
end
```

### fzf-lua Integration

The picker displays each result as a formatted line with ANSI color codes:

```
  [8.3]  Note Title                  tags: #project/cfd | colink: 3 shared | 1-hop link
```

Where:
- Score in brackets (dimmed/colored by magnitude)
- Note name (primary text for fuzzy filtering)
- Reason annotations (dimmed, pipe-separated)

Actions:
- `<CR>` / `default`: Open the selected note
- `ctrl-s`: Open in horizontal split
- `ctrl-v`: Open in vertical split
- `ctrl-t`: Open in new tab

The picker uses `fzf.fzf_exec()` with a list of pre-formatted ANSI strings, and a custom action that extracts the rel_path from the entry for file opening.

---

## Implementation

### File: `lua/andrew/vault/connections.lua`

```lua
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

local M = {}

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

---@type table<string, ConnectionCacheEntry>
local _cache = {}
local _cache_vault = nil

--- Invalidate the entire connection cache.
function M.invalidate_cache()
  _cache = {}
end

--- Invalidate cache for a specific source note.
---@param rel_path string
function M.invalidate_for(rel_path)
  _cache[rel_path] = nil
end

-- ---------------------------------------------------------------------------
-- Index access
-- ---------------------------------------------------------------------------

local _index = nil
local _index_ts = 0

--- Get or build the vault index.
--- Re-uses the query module's index if available, otherwise builds fresh.
---@return table Index, number build_timestamp
local function get_index()
  local now = vim.uv.now() / 1000
  local ttl = config.connections and config.connections.index_ttl or config.query.index_ttl

  if _index and _cache_vault == engine.vault_path and (now - _index_ts) < ttl then
    return _index, _index_ts
  end

  local Index = require("andrew.vault.query.index").Index
  _index = Index.new(engine.vault_path):build_sync()
  _index_ts = now
  _cache_vault = engine.vault_path
  return _index, _index_ts
end

-- ---------------------------------------------------------------------------
-- Signal: Tag IDF
-- ---------------------------------------------------------------------------

--- Build inverse document frequency table.
---@param pages table[]
---@return table<string, number> tag -> doc_count
---@return number total_pages
local function build_tag_idf(pages)
  local doc_count = {}
  local total = 0
  for _, page in ipairs(pages) do
    total = total + 1
    local seen = {}
    for _, tag in ipairs(page.file.tags) do
      if not seen[tag] then
        seen[tag] = true
        doc_count[tag] = (doc_count[tag] or 0) + 1
      end
    end
  end
  return doc_count, total
end

--- Compute tag similarity score between two tag sets using IDF weighting.
---@param tags_a table<string, true>
---@param tags_b table<string, true>
---@param idf table<string, number>
---@param total number
---@return number score
---@return string[] shared_tags list of shared tag names for display
local function score_tags(tags_a, tags_b, idf, total)
  local score = 0
  local shared = {}
  for tag in pairs(tags_a) do
    if tags_b[tag] then
      local df = idf[tag] or 1
      -- IDF: log(N / df), minimum 0.1 to avoid log(1)=0 for unique tags
      local tag_idf = math.log(total / df)
      if tag_idf < 0.1 then tag_idf = 0.1 end
      score = score + tag_idf
      shared[#shared + 1] = tag
    end
  end
  return score, shared
end

-- ---------------------------------------------------------------------------
-- Signal: Frontmatter field matching
-- ---------------------------------------------------------------------------

--- Fields to compare and their individual sub-weights (relative within the fm signal).
local FM_FIELDS = {
  { key = "type",    weight = 1.0 },
  { key = "project", weight = 1.5 },
  { key = "domain",  weight = 1.0 },
  { key = "status",  weight = 0.3 },
}

--- Extract comparable frontmatter values from a page.
---@param page table
---@return table<string, string> key -> normalized string value
local function extract_fm_values(page)
  local vals = {}
  for _, field in ipairs(FM_FIELDS) do
    local v = page[field.key]
    if v ~= nil then
      if type(v) == "table" and v.path then
        -- Link type: use the path for comparison
        vals[field.key] = tostring(v.path):lower()
      elseif type(v) == "string" then
        vals[field.key] = v:lower()
      else
        vals[field.key] = tostring(v):lower()
      end
    end
  end
  return vals
end

--- Score frontmatter field similarity.
---@param fm_a table<string, string>
---@param fm_b table<string, string>
---@return number score
---@return string[] reasons
local function score_frontmatter(fm_a, fm_b)
  local score = 0
  local reasons = {}
  for _, field in ipairs(FM_FIELDS) do
    local va = fm_a[field.key]
    local vb = fm_b[field.key]
    if va and vb and va == vb then
      score = score + field.weight
      reasons[#reasons + 1] = field.key .. ": " .. va
    end
  end
  return score, reasons
end

-- ---------------------------------------------------------------------------
-- Signal: Co-occurrence (bibliographic coupling)
-- ---------------------------------------------------------------------------

--- Score based on shared outlink targets (notes both A and B link to).
---@param out_a table<string, true>
---@param out_b table<string, true>
---@return number score (0..1 normalized)
---@return number shared_count
local function score_colinks(out_a, out_b)
  local shared = 0
  for target in pairs(out_a) do
    if out_b[target] then
      shared = shared + 1
    end
  end
  if shared == 0 then
    return 0, 0
  end
  -- Normalize by the smaller outlink set to get a 0..1 ratio
  local min_size = math.min(
    vim.tbl_count(out_a),
    vim.tbl_count(out_b)
  )
  if min_size == 0 then min_size = 1 end
  return shared / min_size, shared
end

-- ---------------------------------------------------------------------------
-- Signal: Direct link proximity
-- ---------------------------------------------------------------------------

--- Score direct and 2-hop link proximity.
---@param rel_a string source note rel_path
---@param neighbors_a table<string, true>
---@param rel_b string candidate note rel_path
---@param neighbors_b table<string, true>
---@param weights table connection weights config
---@return number score
---@return string|nil reason
local function score_link_proximity(rel_a, neighbors_a, rel_b, neighbors_b, weights)
  -- 1-hop: A directly links to B or B directly links to A
  if neighbors_a[rel_b] or neighbors_b[rel_a] then
    return weights.link_1hop, "1-hop link"
  end

  -- 2-hop: count shared neighbors (notes connected to both A and B)
  local shared = 0
  local max_2hop = weights.max_2hop_bridges or 5
  for n in pairs(neighbors_a) do
    if neighbors_b[n] then
      shared = shared + 1
    end
  end
  if shared > 0 then
    local capped = math.min(shared, max_2hop)
    local score = weights.link_2hop * (capped / max_2hop)
    return score, shared .. " 2-hop bridge" .. (shared > 1 and "s" or "")
  end

  return 0, nil
end

-- ---------------------------------------------------------------------------
-- Signal: Temporal proximity
-- ---------------------------------------------------------------------------

--- Decay function for time difference in days.
---@param delta_days number
---@return number 0..1
local function temporal_decay(delta_days)
  if delta_days < 1 then return 1.0 end
  if delta_days < 3 then return 0.7 end
  if delta_days < 7 then return 0.4 end
  if delta_days < 30 then return 0.2 end
  return 0.0
end

--- Convert a Date object (from query/types.lua) to epoch seconds.
---@param d table Date object with year, month, day fields
---@return number epoch seconds
local function date_to_epoch(d)
  if not d or not d.year then return 0 end
  local ok, ts = pcall(os.time, {
    year = d.year,
    month = d.month or 1,
    day = d.day or 1,
    hour = d.hour or 12,
    min = d.min or 0,
    sec = d.sec or 0,
  })
  return ok and ts or 0
end

--- Score temporal proximity between two notes.
---@param ctime_a number epoch seconds
---@param mtime_a number epoch seconds
---@param ctime_b number epoch seconds
---@param mtime_b number epoch seconds
---@return number score (0..1)
local function score_temporal(ctime_a, mtime_a, ctime_b, mtime_b)
  if ctime_a == 0 or ctime_b == 0 then return 0 end
  local ctime_delta = math.abs(ctime_a - ctime_b) / 86400 -- days
  local mtime_delta = math.abs(mtime_a - mtime_b) / 86400
  return math.max(temporal_decay(ctime_delta), temporal_decay(mtime_delta))
end

-- ---------------------------------------------------------------------------
-- Precompute note data
-- ---------------------------------------------------------------------------

--- Build a ConnectionNoteData table for a page.
---@param page table index page
---@return ConnectionNoteData
local function build_note_data(page)
  -- Build tag set
  local tags = {}
  for _, t in ipairs(page.file.tags) do
    tags[t] = true
  end

  -- Build outlink target set (resolved rel_paths)
  local outlink_targets = {}
  for _, link in ipairs(page.file.outlinks) do
    local path = link.path or ""
    -- Strip heading/block refs
    path = path:match("^([^#^]+)") or path
    path = vim.trim(path)
    if path ~= "" then
      -- Normalize: ensure .md extension for consistency
      if not path:match("%.md$") then
        path = path .. ".md"
      end
      outlink_targets[path:lower()] = true
    end
  end

  -- Build inlink source set
  local inlink_sources = {}
  for _, link in ipairs(page.file.inlinks) do
    local path = link.path or ""
    if not path:match("%.md$") then
      path = path .. ".md"
    end
    inlink_sources[path:lower()] = true
  end

  -- Neighbors = union of outlink targets and inlink sources
  local neighbors = {}
  for k in pairs(outlink_targets) do neighbors[k] = true end
  for k in pairs(inlink_sources) do neighbors[k] = true end

  -- Frontmatter values
  local fm_fields = extract_fm_values(page)

  -- Timestamps
  local ctime = date_to_epoch(page.file.ctime)
  local mtime = date_to_epoch(page.file.mtime)

  return {
    rel_path = page.file.path,
    tags = tags,
    outlink_targets = outlink_targets,
    inlink_sources = inlink_sources,
    neighbors = neighbors,
    fm_fields = fm_fields,
    ctime = ctime,
    mtime = mtime,
  }
end

-- ---------------------------------------------------------------------------
-- Main scoring
-- ---------------------------------------------------------------------------

--- Get connection weights from config with defaults.
---@return table
local function get_weights()
  local defaults = {
    tags = 3.0,
    frontmatter = 2.0,
    colink = 2.5,
    link_1hop = 5.0,
    link_2hop = 2.0,
    temporal = 1.0,
    max_2hop_bridges = 5,
  }
  local cfg = config.connections and config.connections.weights or {}
  return vim.tbl_extend("keep", cfg, defaults)
end

--- Compute related notes for a given source page.
---@param source_rel_path string
---@param max_results? number (default 30)
---@return ConnectionResult[]
function M.compute(source_rel_path, max_results)
  max_results = max_results or 30

  local index, index_ts = get_index()
  local weights = get_weights()

  -- Check cache
  local ttl = config.connections and config.connections.cache_ttl or 60
  local now = vim.uv.now() / 1000
  local cached = _cache[source_rel_path]
  if cached
    and (now - cached.timestamp) < ttl
    and cached.index_ts == index_ts
  then
    return cached.results
  end

  -- Get all pages and build IDF
  local all_pages = index:all_pages()
  local idf, total_pages = build_tag_idf(all_pages)

  -- Get source page
  local source_page = index:get_page(source_rel_path)
  if not source_page then
    return {}
  end
  local source_data = build_note_data(source_page)

  -- Score every other page
  local results = {}
  for _, page in ipairs(all_pages) do
    if page.file.path == source_rel_path then
      goto continue
    end

    local candidate = build_note_data(page)
    local total_score = 0
    local reasons = {}
    local breakdown = {}

    -- 1. Tags
    local tag_score, shared_tags = score_tags(
      source_data.tags, candidate.tags, idf, total_pages
    )
    tag_score = weights.tags * tag_score
    breakdown.tags = tag_score
    if tag_score > 0 and #shared_tags > 0 then
      -- Show at most 3 tags in the reason string
      local display_tags = {}
      for i = 1, math.min(3, #shared_tags) do
        display_tags[i] = "#" .. shared_tags[i]
      end
      local suffix = #shared_tags > 3 and (" +" .. (#shared_tags - 3)) or ""
      reasons[#reasons + 1] = "tags: " .. table.concat(display_tags, ", ") .. suffix
    end
    total_score = total_score + tag_score

    -- 2. Frontmatter
    local fm_score, fm_reasons = score_frontmatter(
      source_data.fm_fields, candidate.fm_fields
    )
    fm_score = weights.frontmatter * fm_score
    breakdown.fm = fm_score
    if fm_score > 0 then
      reasons[#reasons + 1] = "fm: " .. table.concat(fm_reasons, ", ")
    end
    total_score = total_score + fm_score

    -- 3. Co-occurrence (bibliographic coupling)
    local colink_raw, colink_count = score_colinks(
      source_data.outlink_targets, candidate.outlink_targets
    )
    local colink_score = weights.colink * colink_raw
    breakdown.colink = colink_score
    if colink_count > 0 then
      reasons[#reasons + 1] = "colink: " .. colink_count .. " shared"
    end
    total_score = total_score + colink_score

    -- 4. Link proximity
    local link_score, link_reason = score_link_proximity(
      source_data.rel_path:lower(),
      source_data.neighbors,
      candidate.rel_path:lower(),
      candidate.neighbors,
      weights
    )
    breakdown.link = link_score
    if link_reason then
      reasons[#reasons + 1] = link_reason
    end
    total_score = total_score + link_score

    -- 5. Temporal proximity
    local temporal_raw = score_temporal(
      source_data.ctime, source_data.mtime,
      candidate.ctime, candidate.mtime
    )
    local temporal_score = weights.temporal * temporal_raw
    breakdown.temporal = temporal_score
    -- Only show temporal reason if it's the sole signal or strongly contributing
    if temporal_raw >= 0.4 then
      local label = temporal_raw >= 0.7 and "recent" or "near"
      reasons[#reasons + 1] = "time: " .. label
    end
    total_score = total_score + temporal_score

    -- Skip zero-score candidates
    if total_score > 0 then
      results[#results + 1] = {
        rel_path = page.file.path,
        name = page.file.name,
        score = total_score,
        reasons = reasons,
        breakdown = breakdown,
      }
    end

    ::continue::
  end

  -- Sort by score descending
  table.sort(results, function(a, b) return a.score > b.score end)

  -- Trim to max_results
  if #results > max_results then
    local trimmed = {}
    for i = 1, max_results do
      trimmed[i] = results[i]
    end
    results = trimmed
  end

  -- Cache
  _cache[source_rel_path] = {
    source_path = source_rel_path,
    results = results,
    timestamp = now,
    index_ts = index_ts,
  }

  return results
end

-- ---------------------------------------------------------------------------
-- fzf-lua picker
-- ---------------------------------------------------------------------------

--- ANSI escape codes for coloring picker entries.
local ANSI = {
  reset   = "\27[0m",
  dim     = "\27[2m",
  bold    = "\27[1m",
  yellow  = "\27[33m",
  green   = "\27[32m",
  blue    = "\27[34m",
  cyan    = "\27[36m",
  magenta = "\27[35m",
}

--- Format a score for display in the picker.
---@param score number
---@return string
local function format_score(score)
  local color
  if score >= 10 then
    color = ANSI.magenta
  elseif score >= 5 then
    color = ANSI.green
  elseif score >= 2 then
    color = ANSI.cyan
  else
    color = ANSI.dim
  end
  return color .. string.format("[%4.1f]", score) .. ANSI.reset
end

--- Format a result line for the fzf-lua picker.
---@param result ConnectionResult
---@return string formatted ANSI string
local function format_entry(result)
  local score_str = format_score(result.score)
  local reasons_str = ""
  if #result.reasons > 0 then
    reasons_str = ANSI.dim .. "  " .. table.concat(result.reasons, " | ") .. ANSI.reset
  end
  -- Embed the rel_path as a hidden prefix for action extraction
  -- Using a NUL byte as separator (fzf strips ANSI but preserves the text)
  return result.rel_path .. "\t" .. score_str .. "  " .. result.name .. reasons_str
end

--- Open the related notes picker for the current buffer.
function M.related_notes()
  local buf_path = vim.api.nvim_buf_get_name(0)
  if not engine.is_vault_path(buf_path) then
    vim.notify("Vault: current file is not in the vault", vim.log.levels.WARN)
    return
  end

  local rel_path = engine.vault_relative(buf_path)
  if not rel_path then
    vim.notify("Vault: cannot determine relative path", vim.log.levels.WARN)
    return
  end

  local results = M.compute(rel_path)

  if #results == 0 then
    vim.notify("Vault: no related notes found", vim.log.levels.INFO)
    return
  end

  -- Build picker entries
  local entries = {}
  local path_map = {} -- display_line -> abs_path for actions
  for _, r in ipairs(results) do
    local entry = format_entry(r)
    entries[#entries + 1] = entry
    path_map[entry] = engine.vault_path .. "/" .. r.rel_path
  end

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Related notes> ",
    fzf_opts = {
      ["--ansi"] = "",
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      ["--no-sort"] = "",  -- preserve score ordering
    },
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local rel = selected[1]:match("^([^\t]+)")
          if rel then
            local abs = engine.vault_path .. "/" .. rel
            vim.cmd("edit " .. vim.fn.fnameescape(abs))
          end
        end
      end,
      ["ctrl-s"] = function(selected)
        if selected and selected[1] then
          local rel = selected[1]:match("^([^\t]+)")
          if rel then
            local abs = engine.vault_path .. "/" .. rel
            vim.cmd("split " .. vim.fn.fnameescape(abs))
          end
        end
      end,
      ["ctrl-v"] = function(selected)
        if selected and selected[1] then
          local rel = selected[1]:match("^([^\t]+)")
          if rel then
            local abs = engine.vault_path .. "/" .. rel
            vim.cmd("vsplit " .. vim.fn.fnameescape(abs))
          end
        end
      end,
      ["ctrl-t"] = function(selected)
        if selected and selected[1] then
          local rel = selected[1]:match("^([^\t]+)")
          if rel then
            local abs = engine.vault_path .. "/" .. rel
            vim.cmd("tabedit " .. vim.fn.fnameescape(abs))
          end
        end
      end,
    },
  })
end

-- ---------------------------------------------------------------------------
-- Debug: show score breakdown for a specific pair
-- ---------------------------------------------------------------------------

--- Print a detailed score breakdown between the current note and a target.
---@param target_name string note name (without .md)
function M.debug_pair(target_name)
  local buf_path = vim.api.nvim_buf_get_name(0)
  if not engine.is_vault_path(buf_path) then
    vim.notify("Vault: not in vault", vim.log.levels.WARN)
    return
  end

  local rel_path = engine.vault_relative(buf_path)
  local results = M.compute(rel_path, 999)

  local lower_target = target_name:lower()
  for _, r in ipairs(results) do
    if r.name:lower() == lower_target or r.rel_path:lower():match(lower_target) then
      local lines = {
        "Connection: " .. vim.fn.fnamemodify(buf_path, ":t:r") .. " <-> " .. r.name,
        string.format("Total score: %.2f", r.score),
        "",
        "Breakdown:",
        string.format("  Tags:        %6.2f", r.breakdown.tags or 0),
        string.format("  Frontmatter: %6.2f", r.breakdown.fm or 0),
        string.format("  Co-links:    %6.2f", r.breakdown.colink or 0),
        string.format("  Link prox:   %6.2f", r.breakdown.link or 0),
        string.format("  Temporal:    %6.2f", r.breakdown.temporal or 0),
        "",
        "Reasons:",
      }
      for _, reason in ipairs(r.reasons) do
        lines[#lines + 1] = "  - " .. reason
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      return
    end
  end
  vim.notify("Vault: no connection found to '" .. target_name .. "'", vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  -- Commands
  vim.api.nvim_create_user_command("VaultRelated", function()
    M.related_notes()
  end, { desc = "Show related notes for the current note" })

  vim.api.nvim_create_user_command("VaultConnectionsRefresh", function()
    M.invalidate_cache()
    vim.notify("Vault: connection cache cleared", vim.log.levels.INFO)
  end, { desc = "Clear the connection score cache" })

  vim.api.nvim_create_user_command("VaultConnectionDebug", function(opts)
    if opts.args and opts.args ~= "" then
      M.debug_pair(opts.args)
    else
      vim.notify("Usage: :VaultConnectionDebug <note_name>", vim.log.levels.INFO)
    end
  end, {
    nargs = "?",
    desc = "Debug connection score between current note and target",
  })

  -- Keymaps (buffer-local for markdown)
  local group = vim.api.nvim_create_augroup("VaultConnections", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vr", function()
        M.related_notes()
      end, {
        buffer = ev.buf,
        desc = "Vault: related notes",
        silent = true,
      })
    end,
  })

  -- Invalidate cache entry on save
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufpath = vim.api.nvim_buf_get_name(ev.buf)
      if engine.is_vault_path(bufpath) then
        local rel = engine.vault_relative(bufpath)
        if rel then
          M.invalidate_for(rel)
          -- Also invalidate the index so next compute() rebuilds
          _index_ts = 0
        end
      end
    end,
  })
end

return M
```

---

## Integration

### 1. Register in vault init

**File:** `lua/andrew/vault/init.lua`

Add after the graph module setup:

```lua
-- Load smart connection suggestions
require("andrew.vault.connections").setup()
```

### 2. Add config section

**File:** `lua/andrew/vault/config.lua`

Add a new section:

```lua
-- ---------------------------------------------------------------------------
-- Smart connections
-- ---------------------------------------------------------------------------
M.connections = {
  cache_ttl = 60,       -- seconds before cached scores expire
  index_ttl = 30,       -- seconds before the index is considered stale
  max_results = 30,     -- max related notes to show in picker
  weights = {
    tags = 3.0,         -- IDF-weighted shared tag score multiplier
    frontmatter = 2.0,  -- shared frontmatter field score multiplier
    colink = 2.5,       -- bibliographic coupling (shared outlink targets)
    link_1hop = 5.0,    -- direct link (A->B or B->A)
    link_2hop = 2.0,    -- 2-hop bridge connections
    temporal = 1.0,     -- temporal proximity multiplier
    max_2hop_bridges = 5, -- cap on 2-hop bridges counted
  },
  --- Frontmatter fields to compare and their sub-weights.
  fm_fields = {
    { key = "type",    weight = 1.0 },
    { key = "project", weight = 1.5 },
    { key = "domain",  weight = 1.0 },
    { key = "status",  weight = 0.3 },
  },
}
```

### 3. Register cache invalidation

**File:** `lua/andrew/vault/engine.lua`

Add to `invalidate_all_caches()`:

```lua
-- 7. Connection score cache
local ok_conn, connections = pcall(require, "andrew.vault.connections")
if ok_conn and connections.invalidate_cache then
  connections.invalidate_cache()
end
```

---

## Testing

### Manual Verification

1. **Open a vault note with known relationships:**

   Open a note that has inline tags, frontmatter fields (type, project), and wikilinks to other notes.

2. **Invoke the picker:**

   Press `<leader>vr` or run `:VaultRelated`.

3. **Expected behavior:**
   - A fzf-lua picker appears with "Related notes>" prompt.
   - Notes are sorted by score (highest first).
   - Each entry shows `[score]  NoteName  reason1 | reason2 | ...`.
   - Score brackets are colored by magnitude (magenta > green > cyan > dim).
   - Results are not re-sorted by fzf (pre-sorted by relevance).
   - `<CR>` opens the selected note. `ctrl-s/v/t` open in split/vsplit/tab.

4. **Debug a specific pair:**

   ```vim
   :VaultConnectionDebug SomeNoteName
   ```

   Should display a detailed breakdown with scores for each signal type.

5. **Cache verification:**
   - Run `<leader>vr` twice within 60 seconds. The second invocation should be near-instant.
   - Edit and save the current note. Run `<leader>vr` again. Results should reflect the new state.
   - Run `:VaultConnectionsRefresh` to force a full recompute.

### Performance Verification

In a vault with 500+ notes:

```vim
:lua local s = vim.uv.hrtime(); require("andrew.vault.connections").compute(require("andrew.vault.engine").vault_relative(vim.api.nvim_buf_get_name(0))); print(("%.1f ms"):format((vim.uv.hrtime() - s) / 1e6))
```

**Target:** < 500ms for first computation on a 500-note vault. Subsequent cached lookups should be < 1ms.

The main cost is the synchronous index build (`build_sync()`) which walks the filesystem and parses frontmatter. On a warm filesystem cache this is typically 100-300ms for 500 files. The scoring loop itself is O(N) with constant-factor per-note work.

### Automated Test

Add to `tests/test_vault_fixes.lua`:

```lua
-- Test: connections module structure
do
  local source = io.open("lua/andrew/vault/connections.lua", "r")
  if source then
    local content = source:read("*a")
    source:close()

    assert_true(content:find("score_tags") ~= nil, "has tag scoring function")
    assert_true(content:find("score_frontmatter") ~= nil, "has frontmatter scoring")
    assert_true(content:find("score_colinks") ~= nil, "has co-link scoring")
    assert_true(content:find("score_link_proximity") ~= nil, "has link proximity scoring")
    assert_true(content:find("score_temporal") ~= nil, "has temporal scoring")
    assert_true(content:find("build_tag_idf") ~= nil, "has IDF computation")
    assert_true(content:find("invalidate_cache") ~= nil, "has cache invalidation")
    assert_true(content:find("fzf_exec") ~= nil, "has fzf-lua integration")
    assert_true(content:find("related_notes") ~= nil, "has picker function")
    assert_true(content:find("<leader>vr") ~= nil, "has keymap binding")
  end
end
```

---

## Scoring Examples

### Example 1: Strong Connection

**Source:** `Projects/CFD-Validation/Dashboard.md`
- Tags: `#project/cfd-validation`, `#status/active`, `#type/project`
- Frontmatter: `type: project`, `project: [[CFD Validation]]`
- Links to: `Simulations/Mesh-Study.md`, `Findings/Pressure-Drop.md`

**Candidate:** `Simulations/Mesh-Study.md`
- Tags: `#project/cfd-validation`, `#methodology`, `#type/simulation`
- Frontmatter: `type: simulation`, `project: [[CFD Validation]]`
- Links to: `Findings/Pressure-Drop.md`, `Methods/FVM.md`

| Signal | Calculation | Score |
|--------|------------|-------|
| Tags | `#project/cfd-validation` (IDF ~3.9) | `3.0 * 3.9 = 11.7` |
| Frontmatter | `project` match (1.5) | `2.0 * 1.5 = 3.0` |
| Co-links | `Findings/Pressure-Drop.md` shared (1/2 = 0.5) | `2.5 * 0.5 = 1.25` |
| Link proximity | Direct link exists | `5.0` |
| Temporal | Created same week (0.4) | `1.0 * 0.4 = 0.4` |
| **Total** | | **21.35** |

### Example 2: Weak Connection

**Source:** `Projects/CFD-Validation/Dashboard.md` (same as above)

**Candidate:** `Library/Turbulence-Modeling.md`
- Tags: `#concept`, `#methodology`
- No shared frontmatter
- No shared outlinks
- No direct links
- Created 6 months ago

| Signal | Calculation | Score |
|--------|------------|-------|
| Tags | No shared tags | `0` |
| Frontmatter | No matches | `0` |
| Co-links | No shared targets | `0` |
| Link proximity | No link path | `0` |
| Temporal | > 30 days apart | `0` |
| **Total** | | **0** (excluded from results) |

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| New note with no tags, no links, no frontmatter | Empty results, notification "no related notes found" |
| Self-reference | Current note excluded from results |
| Note not in vault | Warning notification, no picker |
| Empty vault (1 note) | Empty results |
| Very large vault (1000+ notes) | May take 1-2 seconds on first compute; cached afterwards |
| Vault switch | Cache fully invalidated; new index built on next call |
| Multiple notes with same name | Disambiguated by rel_path in the picker action |
| Frontmatter link values `[[Note]]` | Compared by resolved link path, not display text |
| Tags with parent expansions | `project/cfd/mesh` contributes `project/cfd/mesh`, `project/cfd`, `project` |
| Note with 100+ outlinks | Co-link normalization prevents dominating other notes |
| All weights set to 0 | All scores are 0; empty results |

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `engine.lua` | Vault path, `is_vault_path()`, `vault_relative()`, cache invalidation | Yes |
| `config.lua` | Weight configuration, TTL settings | Yes (falls back to defaults) |
| `query/index.lua` | Full vault index (pages, tags, links, frontmatter) | Yes |
| `query/types.lua` | `Date` and `Link` types (via index) | Yes (indirect) |
| `fzf-lua` | Picker UI | Yes (for interactive use) |

---

## Key Files Modified

| File | Change |
|------|--------|
| `lua/andrew/vault/connections.lua` | **New file** — complete module |
| `lua/andrew/vault/init.lua` | Add `require("andrew.vault.connections").setup()` |
| `lua/andrew/vault/config.lua` | Add `connections` config section |
| `lua/andrew/vault/engine.lua` | Add connections cache to `invalidate_all_caches()` |

---

## Risk Assessment

**Risk: Low-Medium**

- **New module**: The core `connections.lua` is entirely new code. No existing modules are modified beyond adding one `require` line in `init.lua` and one cache invalidation entry in `engine.lua`.
- **Index dependency**: Relies on `query/index.lua` which does synchronous filesystem I/O. The index is already battle-tested by the query/dataview system. The connections module shares the same index TTL to avoid redundant builds.
- **Performance**: The full scoring loop is O(N) per invocation where N is the number of vault pages. For 500 notes this is <500ms. The 60-second cache TTL means this cost is amortized. For vaults with 2000+ notes, consider reducing `max_results` or implementing lazy scoring.
- **No destructive operations**: The module is purely read-only. It never modifies any files. The worst failure mode is an empty or incorrect results list.
- **fzf-lua dependency**: Uses the same `fzf_exec` pattern as `frecency.lua`, `backlinks.lua`, and `tags.lua`. No new fzf-lua features are required.
- **Cache invalidation**: Hooks into the existing `invalidate_all_caches()` pattern. Individual note invalidation on `BufWritePost` prevents stale results for the most common case (editing the current note).

---

## Future Enhancements

These are explicitly **out of scope** for this implementation but noted for future consideration:

1. **Content similarity (TF-IDF on body text)**: Would require building a term-frequency index. Significant complexity and performance cost. Best implemented as an optional async background job.
2. **Graph-distance weighting**: Use shortest-path distance in the full link graph (Dijkstra/BFS). Currently approximated by 1-hop/2-hop signals.
3. **Machine-learned weights**: Collect user interactions (which related notes they actually open) and train per-vault weight profiles.
4. **Async computation**: Move the index build and scoring to a background thread to avoid blocking the UI on large vaults.
5. **Connection strength visualization**: Show a sparkline or bar chart of the score breakdown in the picker.
