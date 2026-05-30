# External URL Validation

## Problem Statement

The vault plugin validates internal wikilinks thoroughly -- `linkdiag.lua` reports
broken note references as ERROR diagnostics and broken heading anchors as WARN
diagnostics, while `linkcheck.lua` provides buffer-level and vault-wide broken
link scanning. However, **external URLs are completely ignored**.

In `linkdiag.lua` line 164, any target matching `^https?://` is explicitly
skipped:

```lua
if target:match("^https?://") then goto continue end
```

And in `linkcheck.lua`, the `extract_links` function only processes wikilinks
(`[[...]]`), not markdown links (`[text](url)`) or bare URLs.

This means external URLs can silently rot over time -- pages get taken down,
domains expire, URLs change -- and the user has no way to discover dead links
without manually clicking every one. In a knowledge base that accumulates
references over months or years, link rot is a significant problem.

The vault index already tracks outlinks per file (including wikilinks that happen
to contain `http://` or `https://` targets), but markdown-style links
(`[text](url)`) and bare URLs are not captured in the index at all. Both forms
need to be covered for comprehensive external URL validation.

## Current Architecture

### linkdiag.lua -- Real-time Diagnostics

`linkdiag.lua` provides **inline diagnostics** via `vim.diagnostic`. It:

1. Runs on `BufEnter` and on `VaultCacheInvalidate` user events.
2. Scans buffer lines for `[[...]]` wikilinks using pattern matching.
3. For each wikilink, checks note existence via `engine.get_name_cache()` (which
   delegates to the vault index).
4. For links with `#heading` anchors, validates the heading exists in the target
   file via slug-based comparison.
5. Sets `vim.diagnostic` entries with severity ERROR (broken note) or WARN
   (broken heading).
6. Provides code actions (fuzzy-match suggestions) for broken links.
7. Has a namespace `vault_linkdiag` for diagnostic isolation.

Key detail: wikilinks whose target starts with `https?://` are skipped at line
164. Markdown links (`[text](url)`) and bare URLs are not scanned at all.

### linkcheck.lua -- On-Demand Scanning

`linkcheck.lua` provides **on-demand** broken link reports via fzf-lua pickers:

1. `check_buffer()` -- scans the current buffer for broken wikilinks (notes,
   headings, block refs). Shows results in fzf-lua.
2. `check_vault()` -- uses `rg` to find all `[[...]]` patterns across the vault,
   then validates each. Shows broken links in fzf-lua with grep-like format.
3. `check_orphans()` -- finds notes with zero inbound links.

Like `linkdiag.lua`, only wikilinks are checked. External URLs are not covered.

### vault_index.lua -- Outlinks Data

The vault index's `extract_links()` function (line 386) captures both wikilinks
and embeds from file content. Each outlink is stored as:

```lua
{ path = "target", display = "display text", embed = true|false }
```

However, `extract_links()` captures wikilink targets verbatim, so a wikilink
like `[[https://example.com]]` would appear in `outlinks` with
`path = "https://example.com"`. But standard markdown links (`[text](url)`) and
bare URLs are **not** captured in the outlinks array.

### link_utils.lua -- Wikilink Parsing

`link_utils.parse_target()` handles the inner content of `[[...]]`, splitting
into name, heading, block_id, and alias. It does not distinguish between
internal note names and external URLs.

### wikilinks.lua -- URL Handling for Navigation

The `follow_link()` function handles three link types for `gf` navigation:
1. Wikilinks `[[...]]` -- resolved via vault index
2. Markdown links `[text](url)` -- HTTP URLs opened with `vim.ui.open()`
3. Bare URLs `https://...` -- opened with `vim.ui.open()`

The URL patterns used here serve as a reference for extraction:
- Markdown link URL: extracted from `[text](url)` via pattern matching
- Bare URL: `https?://[%w%-%.%_%~%:%/%?#%[%]@!%$&'%(%)%*%+,;=%%]+`

### config.lua

Currently has no configuration section for external URL validation.

## Proposed Solution

Add an external URL validation system that:

1. **Extracts** all external URLs from a buffer or vault (markdown links, bare
   URLs, and HTTP wikilinks).
2. **Validates** them asynchronously using HTTP HEAD requests via `curl`
   subprocesses.
3. **Caches** results persistently to avoid re-checking recently validated URLs.
4. **Reports** dead links as diagnostics (in `linkdiag.lua`) and in on-demand
   pickers (in `linkcheck.lua`).
5. **Rate-limits** requests to avoid overwhelming servers or the network.

### HTTP Validation Strategy: curl Subprocesses

**Why curl over vim.uv TCP?**

`vim.uv` (libuv) provides raw TCP socket APIs, but implementing HTTP/HTTPS
(including TLS negotiation, redirect following, header parsing) on top of raw
sockets is complex and fragile. `curl` is:

- Already installed on virtually all systems
- Handles TLS, redirects, timeouts, HTTP/2, and connection reuse natively
- Can be invoked via `vim.system()` (non-blocking)
- Supports HEAD requests, custom timeouts, and redirect limits
- Returns structured exit codes and HTTP status codes

The approach: spawn `curl` processes with `vim.system()` in async mode, parse
the HTTP status code from stdout, and report results back via callbacks.

### Cache Strategy

URL validation results are cached in a persistent file alongside the vault
index:

```
{vault_path}/.vault-index/url-cache.json
```

Each entry maps a URL to its last-checked status:

```lua
{
  ["https://example.com/page"] = {
    status = 200,          -- HTTP status code (0 = network error)
    checked_at = 1740000000, -- Unix timestamp
    error = nil,           -- Error message if status == 0
  },
}
```

Cache TTLs:
- **Successful (2xx):** 7 days -- working URLs rarely break overnight
- **Redirect (3xx):** 3 days -- redirects may change; check more often
- **Client error (4xx):** 1 day -- may be temporarily down or rate-limited
- **Server error (5xx):** 1 day -- transient server issues
- **Network error (0):** 4 hours -- retry sooner for connectivity issues

These are configurable via `config.lua`.

## Implementation Steps

### Step 1: Add Configuration

Add a new section to `config.lua`:

```lua
-- ---------------------------------------------------------------------------
-- External URL validation
-- ---------------------------------------------------------------------------
M.url_validation = {
  enabled = false,         -- opt-in (network requests are sensitive)
  -- Diagnostic integration (inline markers in buffer)
  diagnostics = true,
  -- Timeout per request (ms)
  timeout_ms = 10000,
  -- Maximum concurrent requests
  max_concurrent = 5,
  -- Maximum redirects to follow
  max_redirects = 5,
  -- Rate limit: minimum ms between requests to the same domain
  domain_rate_limit_ms = 1000,
  -- User-Agent string (some sites block curl's default)
  user_agent = "Mozilla/5.0 (compatible; VaultLinkCheck/1.0)",
  -- Cache TTLs (seconds)
  cache_ttl = {
    success = 7 * 86400,      -- 2xx: 7 days
    redirect = 3 * 86400,     -- 3xx: 3 days
    client_error = 86400,     -- 4xx: 1 day
    server_error = 86400,     -- 5xx: 1 day
    network_error = 4 * 3600, -- connection failure: 4 hours
  },
  -- URL patterns to skip (Lua patterns, matched against full URL)
  exclude_patterns = {
    "^https?://localhost",
    "^https?://127%.",
    "^https?://192%.168%.",
    "^https?://10%.",
    "^https?://0%.0%.0%.0",
  },
  -- Specific domains to skip entirely
  exclude_domains = {},
  -- Status codes to treat as "OK" (beyond 2xx)
  -- e.g., some sites return 403 for HEAD but are fine with GET
  accept_status_codes = {},
  -- Fall back to GET if HEAD fails with certain status codes
  head_fallback_to_get = { 403, 405, 501 },
}
```

### Step 2: Create the URL Validation Module

Create `lua/andrew/vault/url_validate.lua` -- the core async HTTP validation
engine.

```lua
-- url_validate.lua — Async external URL validation via curl

local config = require("andrew.vault.config")

local M = {}

-- In-flight request tracking
local _inflight = {}  -- url -> true
local _inflight_count = 0

-- Per-domain rate limiting
local _domain_last_request = {}  -- domain -> timestamp (ms)

-- Result cache (loaded from disk)
local _cache = {}       -- url -> { status, checked_at, error }
local _cache_path = nil -- set on init
local _cache_dirty = false
local _persist_timer = nil

-- ---------------------------------------------------------------------------
-- URL extraction
-- ---------------------------------------------------------------------------

--- Extract all external URLs from a buffer's lines.
--- Returns both markdown links and bare URLs, with line numbers.
---@param lines string[]
---@return { url: string, lnum: number, col: number, end_col: number, kind: string }[]
function M.extract_urls(lines)
  local urls = {}

  for i, line in ipairs(lines) do
    -- 1. Markdown links: [text](url)
    local pos = 1
    while true do
      -- Match [...](...) but not [[...]] (wikilinks)
      local s, e, url = line:find("%[.-%]%((.-)%)", pos)
      if not s then break end
      -- Skip wikilinks: preceded by [
      if s > 1 and line:sub(s - 1, s - 1) == "[" then
        pos = s + 1
      else
        if url:match("^https?://") then
          -- Find the URL portion's column range within the line
          local url_start = line:find(vim.pesc(url), s, true)
          urls[#urls + 1] = {
            url = url,
            lnum = i,
            col = url_start and (url_start - 1) or (s - 1),
            end_col = e,
            kind = "markdown",
          }
        end
        pos = e + 1
      end
    end

    -- 2. Bare URLs (not already inside markdown links or wikilinks)
    pos = 1
    while true do
      local s, e = line:find("https?://[%w%-%.%_%~%:%/%?#%[%]@!%$&'%(%)%*%+,;=%%]+", pos)
      if not s then break end
      -- Check this URL isn't inside a markdown link (url) or wikilink [[url]]
      local already_captured = false
      for _, existing in ipairs(urls) do
        if existing.lnum == i and s >= existing.col and s <= existing.end_col then
          already_captured = true
          break
        end
      end
      if not already_captured then
        urls[#urls + 1] = {
          url = line:sub(s, e),
          lnum = i,
          col = s - 1,
          end_col = e,
          kind = "bare",
        }
      end
      pos = e + 1
    end

    -- 3. Wikilinks with HTTP targets: [[https://...]]
    pos = 1
    while true do
      local s = line:find("%[%[", pos)
      if not s then break end
      local close = line:find("]]", s + 2, true)
      if not close then break end
      local inner = line:sub(s + 2, close - 1)
      if inner:match("^https?://") then
        -- Strip alias: [[url|alias]]
        local url_part = inner:match("^(.-)%|") or inner
        urls[#urls + 1] = {
          url = url_part,
          lnum = i,
          col = s - 1,
          end_col = close + 1,
          kind = "wikilink",
        }
      end
      pos = close + 2
    end
  end

  return urls
end

-- ---------------------------------------------------------------------------
-- Domain extraction and rate limiting
-- ---------------------------------------------------------------------------

--- Extract domain from URL.
---@param url string
---@return string
local function url_domain(url)
  return url:match("^https?://([^/:]+)") or ""
end

--- Check if a URL should be excluded based on config patterns.
---@param url string
---@return boolean
local function is_excluded(url)
  local cfg = config.url_validation
  for _, pat in ipairs(cfg.exclude_patterns) do
    if url:match(pat) then return true end
  end
  local domain = url_domain(url)
  for _, d in ipairs(cfg.exclude_domains) do
    if domain == d or domain:match("%." .. vim.pesc(d) .. "$") then
      return true
    end
  end
  return false
end

--- Check if rate limit allows a request to this domain.
---@param domain string
---@return boolean can_request
---@return number wait_ms  ms to wait if not allowed
local function check_rate_limit(domain)
  local now = vim.uv.now()  -- ms
  local last = _domain_last_request[domain]
  local min_interval = config.url_validation.domain_rate_limit_ms
  if not last or (now - last) >= min_interval then
    return true, 0
  end
  return false, min_interval - (now - last)
end

--- Record that a request was made to this domain.
---@param domain string
local function record_request(domain)
  _domain_last_request[domain] = vim.uv.now()
end

-- ---------------------------------------------------------------------------
-- Cache management
-- ---------------------------------------------------------------------------

--- Check if a cached result is still valid.
---@param entry table cache entry
---@return boolean
local function cache_valid(entry)
  if not entry or not entry.checked_at then return false end
  local age = os.time() - entry.checked_at
  local ttl_cfg = config.url_validation.cache_ttl
  local status = entry.status or 0

  if status == 0 then
    return age < ttl_cfg.network_error
  elseif status >= 200 and status < 300 then
    return age < ttl_cfg.success
  elseif status >= 300 and status < 400 then
    return age < ttl_cfg.redirect
  elseif status >= 400 and status < 500 then
    return age < ttl_cfg.client_error
  else
    return age < ttl_cfg.server_error
  end
end

--- Get cached result for a URL, or nil if expired/missing.
---@param url string
---@return { status: number, checked_at: number, error: string|nil }|nil
function M.get_cached(url)
  local entry = _cache[url]
  if entry and cache_valid(entry) then
    return entry
  end
  return nil
end

--- Store a result in cache.
---@param url string
---@param status number HTTP status (0 for network error)
---@param err string|nil error message
function M.cache_result(url, status, err)
  _cache[url] = {
    status = status,
    checked_at = os.time(),
    error = err,
  }
  _cache_dirty = true
  M._schedule_persist()
end

--- Load cache from disk.
function M.load_cache(vault_path)
  _cache_path = vault_path .. "/.vault-index/url-cache.json"
  local f = io.open(_cache_path, "r")
  if not f then
    _cache = {}
    return
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if ok and type(data) == "table" then
    _cache = data
  else
    _cache = {}
  end
end

--- Persist cache to disk (debounced).
function M._schedule_persist()
  if not _cache_dirty or not _cache_path then return end
  if _persist_timer then
    _persist_timer:stop()
  end
  _persist_timer = vim.uv.new_timer()
  _persist_timer:start(5000, 0, vim.schedule_wrap(function()
    M._persist()
  end))
end

function M._persist()
  if not _cache_dirty or not _cache_path then return end
  -- Prune expired entries before writing
  local pruned = {}
  for url, entry in pairs(_cache) do
    if cache_valid(entry) then
      pruned[url] = entry
    end
  end
  local dir = vim.fn.fnamemodify(_cache_path, ":h")
  vim.fn.mkdir(dir, "p")
  local f = io.open(_cache_path, "w")
  if f then
    f:write(vim.json.encode(pruned))
    f:close()
    _cache = pruned
    _cache_dirty = false
  end
end

-- ---------------------------------------------------------------------------
-- HTTP validation (curl subprocess)
-- ---------------------------------------------------------------------------

--- Validate a single URL asynchronously.
---@param url string
---@param callback fun(result: { url: string, status: number, error: string|nil })
---@param opts? { method: string }  "HEAD" (default) or "GET"
function M.validate_url(url, callback, opts)
  opts = opts or {}
  local method = opts.method or "HEAD"
  local cfg = config.url_validation

  -- Check exclusions
  if is_excluded(url) then
    callback({ url = url, status = -1, error = "excluded" })
    return
  end

  -- Check cache
  local cached = M.get_cached(url)
  if cached then
    callback({ url = url, status = cached.status, error = cached.error })
    return
  end

  -- Check if already in-flight
  if _inflight[url] then return end

  -- Check concurrency limit
  if _inflight_count >= cfg.max_concurrent then
    -- Queue for later -- simplified: just skip and let next pass catch it
    callback({ url = url, status = -2, error = "concurrency limit" })
    return
  end

  -- Check rate limit
  local domain = url_domain(url)
  local can_req, wait_ms = check_rate_limit(domain)
  if not can_req then
    -- Defer the request
    vim.defer_fn(function()
      M.validate_url(url, callback, opts)
    end, wait_ms)
    return
  end

  -- Mark in-flight
  _inflight[url] = true
  _inflight_count = _inflight_count + 1
  record_request(domain)

  local curl_args = {
    "curl",
    "--silent",
    "--head",                    -- HEAD request (overridden below for GET)
    "--output", "/dev/null",
    "--write-out", "%{http_code}",
    "--max-time", tostring(math.floor(cfg.timeout_ms / 1000)),
    "--max-redirs", tostring(cfg.max_redirects),
    "--location",                -- follow redirects
    "--user-agent", cfg.user_agent,
    "--connect-timeout", "5",
    url,
  }

  if method == "GET" then
    -- Replace --head with GET-specific flags
    curl_args[3] = "--request"
    curl_args[4] = "GET"
    -- Keep --output /dev/null to discard body
  end

  vim.system(curl_args, { text = true }, function(result)
    vim.schedule(function()
      -- Release in-flight slot
      _inflight[url] = nil
      _inflight_count = _inflight_count - 1

      local status_code = 0
      local err_msg = nil

      if result.code ~= 0 then
        -- curl failed (network error, timeout, DNS failure, etc.)
        err_msg = "curl exit " .. result.code
        if result.code == 28 then
          err_msg = "timeout"
        elseif result.code == 6 then
          err_msg = "DNS resolution failed"
        elseif result.code == 7 then
          err_msg = "connection refused"
        elseif result.code == 35 then
          err_msg = "TLS/SSL error"
        elseif result.code == 60 then
          err_msg = "certificate verification failed"
        end
      else
        -- Parse HTTP status code from curl output
        local code_str = (result.stdout or ""):match("(%d+)%s*$")
        status_code = tonumber(code_str) or 0
      end

      -- HEAD fallback to GET: some servers reject HEAD
      if method == "HEAD"
        and status_code > 0
        and cfg.head_fallback_to_get
      then
        for _, fallback_code in ipairs(cfg.head_fallback_to_get) do
          if status_code == fallback_code then
            -- Retry with GET
            M.validate_url(url, callback, { method = "GET" })
            return
          end
        end
      end

      -- Cache and report
      M.cache_result(url, status_code, err_msg)
      callback({
        url = url,
        status = status_code,
        error = err_msg,
      })
    end)
  end)
end

--- Validate multiple URLs with concurrency control.
--- Calls `on_result` for each URL as it completes, and `on_done` when all finish.
---@param url_entries { url: string, lnum: number, col: number, end_col: number }[]
---@param on_result fun(entry: table, result: table)
---@param on_done fun(results: table[])
function M.validate_batch(url_entries, on_result, on_done)
  local results = {}
  local remaining = #url_entries
  if remaining == 0 then
    on_done({})
    return
  end

  -- Process URLs through a queue with concurrency control
  local queue = {}
  for _, entry in ipairs(url_entries) do
    queue[#queue + 1] = entry
  end

  local function process_next()
    if #queue == 0 then return end
    local entry = table.remove(queue, 1)

    M.validate_url(entry.url, function(result)
      results[#results + 1] = { entry = entry, result = result }
      if on_result then
        on_result(entry, result)
      end
      remaining = remaining - 1
      if remaining == 0 then
        on_done(results)
      else
        -- Process next from queue
        process_next()
      end
    end)
  end

  -- Start initial batch (up to max_concurrent)
  local initial = math.min(#queue, config.url_validation.max_concurrent)
  for _ = 1, initial do
    process_next()
  end
end

-- ---------------------------------------------------------------------------
-- Status interpretation
-- ---------------------------------------------------------------------------

--- Classify an HTTP status code for diagnostic severity.
---@param status number
---@return string "ok"|"redirect"|"dead"|"error"|"excluded"|"pending"
function M.classify_status(status)
  if status == -1 then return "excluded" end
  if status == -2 then return "pending" end
  if status == 0 then return "error" end
  if status >= 200 and status < 300 then return "ok" end
  if status >= 300 and status < 400 then return "redirect" end
  if status >= 400 then return "dead" end
  return "error"
end

--- Map classification to diagnostic severity.
---@param class string
---@return number|nil vim.diagnostic.severity or nil to skip
function M.class_to_severity(class)
  if class == "dead" then
    return vim.diagnostic.severity.WARN
  elseif class == "error" then
    return vim.diagnostic.severity.WARN
  end
  return nil  -- ok, redirect, excluded, pending -> no diagnostic
end

-- ---------------------------------------------------------------------------
-- Stats / debug
-- ---------------------------------------------------------------------------

--- Get cache stats.
---@return { total: number, valid: number, expired: number, by_class: table }
function M.cache_stats()
  local total, valid, expired = 0, 0, 0
  local by_class = { ok = 0, redirect = 0, dead = 0, error = 0, excluded = 0 }
  for _, entry in pairs(_cache) do
    total = total + 1
    if cache_valid(entry) then
      valid = valid + 1
      local class = M.classify_status(entry.status)
      by_class[class] = (by_class[class] or 0) + 1
    else
      expired = expired + 1
    end
  end
  return { total = total, valid = valid, expired = expired, by_class = by_class }
end

return M
```

### Step 3: Integrate into linkdiag.lua (Real-time Diagnostics)

Modify `linkdiag.lua` to optionally validate external URLs in the current
buffer. Since HTTP validation is async, this uses a two-phase approach:

1. The synchronous `validate()` call sets internal-link diagnostics immediately
   (unchanged behavior).
2. If `config.url_validation.enabled` and `config.url_validation.diagnostics`
   are true, it also extracts external URLs and fires async validation. When
   results arrive, diagnostics are merged.

```lua
-- In M.validate(), after processing all wikilinks and setting diagnostics:

if config.url_validation.enabled and config.url_validation.diagnostics then
  local url_validate = require("andrew.vault.url_validate")
  local url_entries = url_validate.extract_urls(
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  )

  -- Add cached results immediately (avoids flicker for known-dead links)
  for _, entry in ipairs(url_entries) do
    local cached = url_validate.get_cached(entry.url)
    if cached then
      local class = url_validate.classify_status(cached.status)
      local severity = url_validate.class_to_severity(class)
      if severity then
        diags[#diags + 1] = {
          lnum = entry.lnum - 1,
          col = entry.col,
          end_col = entry.end_col,
          severity = severity,
          message = string.format("Dead URL [%d]: %s", cached.status, entry.url),
          source = "vault-linkdiag",
          _type = "dead_url",
          _url = entry.url,
        }
      end
    end
  end

  -- Set diagnostics with what we have now (internal + cached URL results)
  vim.diagnostic.set(M.ns, bufnr, diags)

  -- Fire async validation for uncached URLs
  local uncached = {}
  for _, entry in ipairs(url_entries) do
    if not url_validate.get_cached(entry.url) then
      uncached[#uncached + 1] = entry
    end
  end

  if #uncached > 0 then
    url_validate.validate_batch(uncached, function(entry, result)
      -- On each result, re-validate to merge new findings
      -- (only if buffer is still valid)
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.validate(bufnr)
      end
    end, function(_all_results)
      -- All done -- final re-validate
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.validate(bufnr)
      end
    end)
  end
end
```

This re-entrant design means `validate()` picks up cached results on each call.
After the first async pass, subsequent calls are instant (all cached).

### Step 4: Integrate into linkcheck.lua (On-Demand Pickers)

Add `check_urls_buffer()` and `check_urls_vault()` functions:

```lua
--- Scan the current buffer for dead external URLs.
function M.check_urls_buffer()
  local url_validate = require("andrew.vault.url_validate")
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local url_entries = url_validate.extract_urls(lines)

  if #url_entries == 0 then
    vim.notify("Vault: no external URLs found in buffer", vim.log.levels.INFO)
    return
  end

  vim.notify(
    "Vault: checking " .. #url_entries .. " URL(s)...",
    vim.log.levels.INFO
  )

  local dead = {}
  url_validate.validate_batch(url_entries,
    nil, -- no per-result callback
    function(results)
      for _, r in ipairs(results) do
        local class = url_validate.classify_status(r.result.status)
        if class == "dead" or class == "error" then
          local label = r.result.error or ("HTTP " .. r.result.status)
          dead[#dead + 1] = string.format(
            "%d: %s [%s]", r.entry.lnum, r.entry.url, label
          )
        end
      end

      if #dead == 0 then
        vim.notify(
          "Vault: all " .. #url_entries .. " URLs OK",
          vim.log.levels.INFO
        )
        return
      end

      vim.notify(
        "Vault: " .. #dead .. " dead URL(s) found",
        vim.log.levels.WARN
      )

      require("fzf-lua").fzf_exec(dead, {
        prompt = "Dead URLs> ",
        actions = {
          ["default"] = function(selected)
            if selected[1] then
              local lnum = tonumber(selected[1]:match("^(%d+):"))
              if lnum then
                vim.api.nvim_win_set_cursor(0, { lnum, 0 })
              end
            end
          end,
        },
      })
    end
  )
end
```

For vault-wide URL checking, use `rg` to find all URLs across the vault first,
then validate them in batch:

```lua
--- Scan entire vault for dead external URLs.
function M.check_urls_vault()
  local url_validate = require("andrew.vault.url_validate")
  vim.notify("Vault: scanning vault for external URLs...", vim.log.levels.INFO)

  vim.system({
    "rg",
    "--no-heading",
    "--line-number",
    "--only-matching",
    "--glob", "*.md",
    "https?://[\\w\\-\\.\\~\\:\\/\\?#\\[\\]@!\\$&'\\(\\)\\*\\+,;=%]+",
    engine.vault_path,
  }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 and result.code ~= 1 then
        vim.notify("Vault: rg failed", vim.log.levels.ERROR)
        return
      end

      -- Deduplicate URLs (same URL may appear many times)
      local unique_urls = {}
      local url_locations = {}  -- url -> { {file, lnum}, ... }

      for line in (result.stdout or ""):gmatch("[^\n]+") do
        local file, lnum, url = line:match("^(.+):(%d+):(.+)$")
        if url then
          if not url_locations[url] then
            url_locations[url] = {}
            unique_urls[#unique_urls + 1] = {
              url = url, lnum = 0, col = 0, end_col = 0,
            }
          end
          url_locations[url][#url_locations[url] + 1] = {
            file = file, lnum = tonumber(lnum),
          }
        end
      end

      vim.notify(
        "Vault: checking " .. #unique_urls .. " unique URL(s)...",
        vim.log.levels.INFO
      )

      url_validate.validate_batch(unique_urls, nil, function(results)
        local dead = {}
        for _, r in ipairs(results) do
          local class = url_validate.classify_status(r.result.status)
          if class == "dead" or class == "error" then
            local label = r.result.error or ("HTTP " .. r.result.status)
            for _, loc in ipairs(url_locations[r.entry.url] or {}) do
              local rel = loc.file:sub(#engine.vault_path + 2)
              dead[#dead + 1] = string.format(
                "%s:%d: %s [%s]", rel, loc.lnum, r.entry.url, label
              )
            end
          end
        end

        if #dead == 0 then
          vim.notify("Vault: all URLs OK across vault", vim.log.levels.INFO)
          return
        end

        vim.notify(
          "Vault: " .. #dead .. " dead URL reference(s) found",
          vim.log.levels.WARN
        )

        require("fzf-lua").fzf_exec(dead, engine.vault_fzf_opts("Dead URLs", {
          previewer = "builtin",
          actions = engine.vault_fzf_actions(),
        }))
      end)
    end)
  end)
end
```

### Step 5: Register Commands and Keybindings

In `linkcheck.lua` setup:

```lua
vim.api.nvim_create_user_command("VaultURLCheck", function()
  M.check_urls_buffer()
end, { desc = "Check external URLs in current buffer" })

vim.api.nvim_create_user_command("VaultURLCheckAll", function()
  M.check_urls_vault()
end, { desc = "Check external URLs across entire vault" })

-- In the FileType markdown autocmd:
vim.keymap.set("n", "<leader>vcu", function()
  M.check_urls_buffer()
end, { buffer = ev.buf, desc = "Check: URLs (buffer)", silent = true })

vim.keymap.set("n", "<leader>vcU", function()
  M.check_urls_vault()
end, { buffer = ev.buf, desc = "Check: URLs (vault)", silent = true })
```

In `linkdiag.lua`, add a debug command:

```lua
vim.api.nvim_create_user_command("VaultURLCacheStats", function()
  local url_validate = require("andrew.vault.url_validate")
  local stats = url_validate.cache_stats()
  vim.notify(string.format(
    "URL cache: %d total (%d valid, %d expired)\n" ..
    "  OK: %d | Dead: %d | Error: %d | Redirect: %d",
    stats.total, stats.valid, stats.expired,
    stats.by_class.ok, stats.by_class.dead,
    stats.by_class.error, stats.by_class.redirect
  ), vim.log.levels.INFO)
end, { desc = "Show URL validation cache statistics" })
```

### Step 6: Initialize Cache on Vault Load

In `engine.lua` or `init.lua`, when the vault is initialized:

```lua
if config.url_validation.enabled then
  local url_validate = require("andrew.vault.url_validate")
  url_validate.load_cache(engine.vault_path)
end
```

And on `VimLeavePre`, persist immediately:

```lua
if config.url_validation.enabled then
  local url_validate = require("andrew.vault.url_validate")
  url_validate._persist()
end
```

### Step 7: Extend vault_index.lua to Track External URLs (Optional Enhancement)

To enable vault-wide URL checking without `rg`, extend the index parser to also
capture markdown links and bare URLs. Add a new field to `VaultIndexEntry`:

```lua
---@field external_urls { url: string, line: number }[]
```

In `extract_links()` or a new `extract_external_urls()` helper:

```lua
local function extract_external_urls(content)
  local urls = {}
  local lines = vim.split(content, "\n", { plain = true })
  for i, line in ipairs(lines) do
    -- Markdown links
    for url in line:gmatch("%[.-%]%((.-)%)") do
      if url:match("^https?://") then
        urls[#urls + 1] = { url = url, line = i }
      end
    end
    -- Bare URLs
    for url in line:gmatch("https?://[%w%-%.%_%~%:%/%?#%[%]@!%$&'%(%)%*%+,;=%%]+") do
      urls[#urls + 1] = { url = url, line = i }
    end
  end
  return urls
end
```

This would allow vault-wide URL collection to be instant (read from index)
rather than requiring a full `rg` scan. However, this increases index size and
parse time. It should be gated behind `config.url_validation.enabled` and can be
deferred to a follow-up improvement.

## Key Design Decisions

### 1. curl Subprocess vs vim.uv TCP

**Decision: curl subprocess via `vim.system()`.**

Rationale:
- `vim.uv` provides raw TCP only. Building HTTP/1.1 + TLS + redirect handling +
  chunked encoding on raw sockets would be hundreds of lines of fragile code.
- curl handles all protocol complexity, including HTTP/2, connection reuse, TLS
  certificate verification, and SOCKS/HTTP proxy support.
- `vim.system()` is fully async and non-blocking.
- curl is universally available on Linux/macOS. On systems without curl, the
  feature gracefully disables with a notification.

Trade-offs:
- Process spawn overhead (~2-5ms per request). Mitigated by the concurrency
  limit (max 5 concurrent) and batch processing.
- No connection pooling between requests (each curl invocation is independent).
  For vault-wide scans of 100+ URLs, this adds ~200-500ms total overhead. This
  is acceptable for an on-demand operation.

### 2. HEAD vs GET Requests

**Decision: HEAD first, fallback to GET for specific status codes.**

HEAD requests are preferred because they avoid downloading response bodies
(which can be megabytes). However, some servers:
- Return 403 for HEAD but 200 for GET (e.g., some CDNs)
- Return 405 Method Not Allowed for HEAD
- Return 501 Not Implemented for HEAD

The `head_fallback_to_get` config allows retrying with GET when HEAD returns
these codes. The GET request still uses `--output /dev/null` to discard the
body.

### 3. Caching Strategy

**Decision: Persistent JSON file with TTL-based expiration.**

- File location: `{vault_path}/.vault-index/url-cache.json`
- Survives across Neovim sessions (no redundant re-checking)
- Different TTLs for different status classes (success = long, error = short)
- Expired entries pruned on write (keeps file size bounded)
- Debounced writes (5 second interval) to avoid excessive I/O

Why not SQLite? JSON is simpler, has zero dependencies, and is sufficient for
the expected cache size (hundreds to low thousands of URLs).

### 4. Rate Limiting

**Decision: Per-domain minimum interval + global concurrency cap.**

- `domain_rate_limit_ms = 1000`: At most one request per second per domain.
  Prevents triggering rate limiters on sites that appear multiple times.
- `max_concurrent = 5`: At most 5 curl processes running simultaneously. Avoids
  overwhelming the system or the network on large vault scans.
- Deferred retries: If a domain is rate-limited, the request is re-queued via
  `vim.defer_fn()` with the computed wait time.

### 5. Opt-in by Default

**Decision: `config.url_validation.enabled = false`.**

External URL validation makes network requests, which:
- May be unexpected in a text editor
- Can be slow on poor connections
- May leak vault content (URLs reveal what the user is reading/researching)
- Could trigger security alerts in corporate environments

Users must explicitly enable the feature. The diagnostic integration
(`config.url_validation.diagnostics`) has a separate toggle so users can enable
on-demand checking (`:VaultURLCheck`) without inline diagnostics.

### 6. Diagnostic Severity for Dead URLs

**Decision: WARN (not ERROR).**

Internal broken links use ERROR because they indicate a definite problem (the
target note does not exist locally). External dead URLs use WARN because:
- The URL may be temporarily down
- The user's network may be offline
- Some sites block automated checks (false positives)
- The URL might work in a browser but not via HEAD/GET

This distinction keeps the diagnostic channel useful without being alarmist.

## Edge Cases

### Redirects

curl's `--location` flag follows redirects automatically (up to
`max_redirects`). The final status code after all redirects is what gets
reported. A URL that redirects to a 200 is classified as "ok". A redirect chain
that ends in 404 is classified as "dead".

Permanent redirects (301) are not flagged as warnings by default. A future
enhancement could optionally warn about 301s to suggest updating the URL.

### Sites That Block HEAD Requests

Handled by the `head_fallback_to_get` mechanism. When HEAD returns 403, 405, or
501, the URL is automatically retried with GET. This covers most cases. Sites
that block both HEAD and GET with non-standard behavior will appear as dead
links. The `accept_status_codes` config allows whitelisting specific codes.

### Authentication-Required URLs

URLs returning 401 (Unauthorized) or 403 (Forbidden, after GET fallback) are
classified as "dead". This is the correct behavior for link validation: if a
reader cannot access the URL without credentials, it is effectively dead as a
reference.

For URLs behind authentication that the user knows are valid, the
`exclude_patterns` or `exclude_domains` config provides a way to skip them.

### Network Offline

When the network is unavailable, curl will fail with exit code 6 (DNS
resolution failed) or 7 (connection refused). These are cached as "network
error" with a short TTL (4 hours), so they will be retried relatively soon.

The feature does not attempt to detect network availability before running. If
all URLs fail with network errors, the notification makes it clear:

```
Vault: 47 dead URL(s) found
```

The user will see all URLs marked as "DNS resolution failed" or similar and
understand the issue. Once connectivity is restored, the short cache TTL ensures
re-validation happens on the next check.

### Slow Responses

The `timeout_ms` config (default 10 seconds) caps the maximum time per request.
curl's `--connect-timeout 5` ensures that connection establishment alone does
not exceed 5 seconds. Combined with the concurrency limit, a batch of 100 URLs
should complete in roughly:

```
100 URLs / 5 concurrent = 20 batches * 10s timeout = 200s worst case
```

In practice, most URLs respond in under 1 second, so typical completion time
for 100 URLs is 20-30 seconds.

### Large Vaults with Many URLs

For vaults with thousands of external URLs, the vault-wide scan could be slow.
Mitigations:
- Deduplication: The vault-wide scan collects unique URLs first. If the same URL
  appears in 50 files, it is only checked once.
- Cache: After the first full scan, subsequent scans only check URLs whose cache
  has expired.
- Progress feedback: The notification shows the count being checked.

A future enhancement could add a progress bar or per-URL streaming output.

### URL Encoding and Special Characters

URLs may contain encoded characters (`%20`, `%E2%80%99`, etc.). These are passed
to curl as-is, which handles them correctly. The extraction patterns in
`extract_urls()` include the `%` character to capture percent-encoded URLs.

### Fragment-Only URLs

URLs like `https://example.com/page#section` include a fragment. The fragment
is part of the URL passed to curl, but HTTP servers ignore fragments (they are
client-side only). curl will check `https://example.com/page` and the fragment
has no effect on the validation result. This is correct behavior.

### Data URIs and JavaScript URLs

`data:` URIs and `javascript:` URLs do not match the `https?://` pattern and
are naturally excluded.

### URLs in Code Blocks

The `extract_urls()` function operates on raw buffer lines, which may include
fenced code blocks. URLs inside code blocks are typically not "live" references
and should be skipped. Two approaches:

1. **Simple (initial implementation):** Check URLs in all lines. Accept that code
   block URLs may produce false positives. Users can exclude specific patterns.
2. **Refined (follow-up):** Strip fenced code blocks before extraction, similar
   to how `vault_index.lua`'s `strip_code_blocks()` works. This is recommended
   for the initial implementation.

The recommended approach is to add code-block stripping to `extract_urls()`:

```lua
-- Before extraction, mark code block line ranges
local in_fence = false
local code_lines = {}
for i, line in ipairs(lines) do
  if line:match("^```") then
    in_fence = not in_fence
  end
  code_lines[i] = in_fence
end

-- Then in the extraction loop:
for i, line in ipairs(lines) do
  if code_lines[i] then goto next_line end
  -- ... extract URLs ...
  ::next_line::
end
```

## Files Modified

### New Files

1. **`lua/andrew/vault/url_validate.lua`** -- Core URL validation module
   - URL extraction from buffer lines (markdown links, bare URLs, HTTP wikilinks)
   - Async HTTP validation via curl subprocess
   - Persistent result cache with TTL-based expiration
   - Rate limiting (per-domain interval + global concurrency cap)
   - Batch validation with concurrency control
   - Status classification and diagnostic severity mapping
   - Cache statistics for debugging

### Modified Files

2. **`lua/andrew/vault/config.lua`**
   - Add `M.url_validation` configuration section with all tunables

3. **`lua/andrew/vault/linkdiag.lua`**
   - In `M.validate()`: after internal link diagnostics, extract external URLs
     from buffer and add cached dead-URL diagnostics immediately
   - Fire async validation for uncached URLs; re-validate on completion
   - Add `VaultURLCacheStats` command
   - Handle new `_type = "dead_url"` diagnostic entries (no code actions for
     these -- dead URLs cannot be auto-fixed)

4. **`lua/andrew/vault/linkcheck.lua`**
   - Add `M.check_urls_buffer()`: extract + validate URLs in current buffer
   - Add `M.check_urls_vault()`: use `rg` to find all URLs in vault, deduplicate,
     validate in batch, show results in fzf-lua
   - Register `VaultURLCheck` and `VaultURLCheckAll` commands
   - Add `<leader>vcu` and `<leader>vcU` keybindings in FileType autocmd

5. **`lua/andrew/vault/engine.lua`** (or `init.lua`)
   - Load URL cache on vault initialization (if feature enabled)
   - Persist URL cache on `VimLeavePre`
   - Pass vault path to `url_validate.load_cache()`

6. **`lua/andrew/vault/vault_index.lua`** (optional, follow-up)
   - Add `external_urls` field to `VaultIndexEntry`
   - Add `extract_external_urls()` helper to single-pass parser
   - Gate behind `config.url_validation.enabled` to avoid index bloat when
     the feature is disabled

## Testing Plan

### Manual Verification

1. **Basic function test:**
   - Create a test note with a mix of:
     - Valid URLs: `https://google.com`, `[GitHub](https://github.com)`
     - Dead URLs: `https://httpstat.us/404`, `[Dead](https://httpstat.us/500)`
     - Timeout URLs: `https://httpstat.us/200?sleep=15000`
     - Non-existent domains: `https://this-domain-does-not-exist-12345.com`
     - Localhost/excluded: `http://localhost:8080`
   - Run `:VaultURLCheck` and verify:
     - Valid URLs: not listed
     - Dead URLs: listed with correct status codes
     - Timeout URLs: listed as "timeout"
     - Non-existent domains: listed as "DNS resolution failed"
     - Excluded URLs: not checked

2. **Diagnostic integration test:**
   - Enable `url_validation.enabled = true` and `url_validation.diagnostics = true`
   - Open the test note, wait for async validation
   - Verify WARN diagnostics appear on dead URL lines
   - Verify no diagnostics on valid URL lines
   - Verify diagnostics update correctly after editing the buffer

3. **Cache persistence test:**
   - Run `:VaultURLCheck` on a buffer with mixed URLs
   - Check `.vault-index/url-cache.json` exists and contains valid JSON
   - Close and reopen Neovim
   - Run `:VaultURLCheck` again -- verify cached results return instantly
   - Run `:VaultURLCacheStats` -- verify counts match expectations

4. **Rate limiting test:**
   - Create a note with 20 URLs all pointing to the same domain
   - Run `:VaultURLCheck` and observe that requests are spaced out
   - Verify total time is approximately `20 * 1000ms = 20 seconds`

5. **HEAD fallback test:**
   - Find a URL that returns 403 for HEAD but 200 for GET (or use
     `https://httpstat.us/403` for HEAD simulation)
   - Verify the fallback to GET produces the correct result

6. **Vault-wide scan test:**
   - Run `:VaultURLCheckAll` on a vault with many notes
   - Verify URLs are deduplicated (same URL in multiple files checked once)
   - Verify results show correct file:line references for each dead URL
   - Verify fzf-lua picker opens with navigable results

7. **Concurrent request limit test:**
   - Create a note with 30 URLs to different domains
   - Monitor system processes during `:VaultURLCheck`
   - Verify no more than 5 curl processes run simultaneously

8. **Network offline test:**
   - Disconnect from network
   - Run `:VaultURLCheck` on a buffer with external URLs
   - Verify all URLs report network errors (not hangs)
   - Reconnect and re-run -- verify URLs are re-checked (short TTL)

9. **Exclusion test:**
   - Add `"^https?://internal%.corp"` to `exclude_patterns`
   - Add `"private.example.com"` to `exclude_domains`
   - Verify matching URLs are skipped with `status = -1`

10. **Code block exclusion test:**
    - Create a note with URLs inside fenced code blocks
    - Run `:VaultURLCheck`
    - Verify those URLs are not checked

### Automated / Regression Tests

11. **URL extraction unit test:**
    - Test `extract_urls()` with various input lines covering all three URL
      types (markdown link, bare URL, HTTP wikilink)
    - Test edge cases: URL at start of line, end of line, multiple URLs per
      line, URLs in code blocks, URL with special characters, nested brackets

12. **Status classification test:**
    - Verify `classify_status()` for status codes: 0, 200, 301, 403, 404, 500,
      -1, -2

13. **Cache TTL test:**
    - Create cache entries with backdated `checked_at` timestamps
    - Verify `cache_valid()` returns correct true/false for each TTL tier

14. **Exclude pattern test:**
    - Test `is_excluded()` with various URL and pattern combinations
    - Test domain matching (exact and subdomain)
