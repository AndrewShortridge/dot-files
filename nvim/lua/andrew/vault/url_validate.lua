-- url_validate.lua — Async external URL validation via curl

local config = require("andrew.vault.config")
local cleanup = require("andrew.vault.resource_cleanup")
local link_utils = require("andrew.vault.link_utils")
local pat = require("andrew.vault.patterns")
local coalescer = require("andrew.vault.request_coalescer")
local rate_limiter = require("andrew.vault.rate_limiter")

local M = {}

-- Coalescer pool for URL validation (callback fan-out on duplicate URLs)
local url_pool = coalescer.new({ name = "url_validate" })

-- Rate limiter instance (lazy-initialized)
local _limiter = nil

--- Get or create the rate limiter instance.
---@return table
local function get_limiter()
  if not _limiter then
    local cfg = config.url_validation
    _limiter = rate_limiter.new({
      max_concurrent = cfg.max_concurrent,
      domain_cooldown_ms = cfg.domain_rate_limit_ms,
      max_queue_size = cfg.max_queue_size,
      queue_drain_interval_ms = cfg.queue_drain_interval_ms,
    })
  end
  return _limiter
end

-- Result cache (loaded from disk)
local _cache = {} -- url -> { status, checked_at, error }
local _cache_path = nil -- set on init
local _cache_dirty = false
local _persist_timer = nil
local _cache_hits = 0
local _cache_misses = 0
local _cache_evictions = 0

-- ---------------------------------------------------------------------------
-- URL extraction
-- ---------------------------------------------------------------------------

--- Extract all external URLs from a buffer's lines.
--- Returns both markdown links and bare URLs, with line numbers.
--- Skips URLs inside fenced code blocks.
---@param lines string[]
---@return { url: string, lnum: number, col: number, end_col: number, kind: string }[]
function M.extract_urls(lines)
  local urls = {}

  -- Mark code block line ranges (pre-computed lookup table).
  -- Intentionally NOT using link_scan.is_in_fenced_code_lines() here:
  -- that function is O(n) per call (scans from line 1 to target_line),
  -- so calling it inside the loop below would be O(n²). Pre-computing
  -- the table is O(n) total.
  local in_fence = false
  local code_lines = {}
  for i, line in ipairs(lines) do
    if pat.is_code_fence(line) then
      in_fence = not in_fence
    end
    code_lines[i] = in_fence
  end

  for i, line in ipairs(lines) do
    if code_lines[i] then goto next_line end

    -- 1. Markdown links: [text](url)
    local pos = 1
    while true do
      -- Capture group variant of pat.MARKDOWN_LINK ("%[.-%]%(.-%)"):
      local s, e, url = line:find("%[.-%]%((.-)%)", pos)
      if not s then break end
      -- Skip wikilinks: preceded by [
      if s > 1 and line:sub(s - 1, s - 1) == "[" then
        pos = s + 1
      else
        if url:match("^https?://") then
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
      local s, e = line:find(link_utils.URL_PAT, pos)
      if not s then break end
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
    pat.scan_wikilinks(line, function(inner, start_col, end_col)
      if inner:match("^https?://") then
        local url_part = inner:match("^(.-)%|") or inner
        urls[#urls + 1] = {
          url = url_part,
          lnum = i,
          col = start_col - 1,
          end_col = end_col,
          kind = "wikilink",
        }
      end
    end)

    ::next_line::
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
    _cache_hits = _cache_hits + 1
    return entry
  end
  _cache_misses = _cache_misses + 1
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
  _persist_timer = cleanup.debounce(_persist_timer, config.url_validation.cache_persist_debounce_ms, function()
    M._persist()
  end)
end

--- Blocking persist for VimLeavePre — flush any pending dirty cache immediately.
function M.persist_now()
  cleanup.close_timer(_persist_timer)
  _persist_timer = nil
  M._persist()
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
  local dir = link_utils.lua_dirname(_cache_path)
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

--- Build a coalescer key for a URL validation request.
---@param url string
---@param method string
---@return string
local function make_url_key(url, method)
  return method .. ":" .. url
end

--- Run the actual curl validation for a URL. Called as operation_fn by coalescer.
---@param url string
---@param method string
---@param resolve fun(result: table)
local function run_curl(url, method, resolve)
  local cfg = config.url_validation

  local curl_args = {
    "curl",
    "--silent",
    method == "GET" and "--request" or "--head",
  }
  if method == "GET" then curl_args[#curl_args + 1] = "GET" end
  local tail = {
    "--output", "/dev/null",
    "--write-out", "%{http_code}",
    "--max-time", tostring(math.floor(cfg.timeout_ms / 1000)),
    "--max-redirs", tostring(cfg.max_redirects),
    "--location",
    "--user-agent", cfg.user_agent,
    "--connect-timeout", "5",
    url,
  }
  for _, arg in ipairs(tail) do curl_args[#curl_args + 1] = arg end

  vim.system(curl_args, { text = true }, function(result)
    vim.schedule(function()
      local status_code = 0
      local err_msg = nil

      if result.code ~= 0 then
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
        local code_str = (result.stdout or ""):match("(%d+)%s*$")
        status_code = tonumber(code_str) or 0
      end

      -- Check accept_status_codes
      if status_code > 0 then
        for _, accepted in ipairs(cfg.accept_status_codes) do
          if status_code == accepted then
            status_code = 200 -- treat as OK
            break
          end
        end
      end

      -- HEAD fallback to GET: some servers reject HEAD
      if method == "HEAD"
        and status_code > 0
        and cfg.head_fallback_to_get
      then
        for _, fallback_code in ipairs(cfg.head_fallback_to_get) do
          if status_code == fallback_code then
            -- Cancel this HEAD result and start a GET request instead.
            -- The GET will go through validate_url again (cache/dedup/rate-limit).
            -- We resolve with nil to signal the fallback; validate_url handles the retry.
            resolve({ url = url, status = status_code, error = nil, _fallback_get = true })
            return
          end
        end
      end

      -- Cache and report
      M.cache_result(url, status_code, err_msg)
      resolve({ url = url, status = status_code, error = err_msg })
    end)
  end)
end

--- Validate a single URL asynchronously.
--- Duplicate requests for the same URL join the existing in-flight operation.
--- All URLs are queued via the rate limiter — no silent concurrency failures.
---@param url string
---@param callback fun(result: { url: string, status: number, error: string|nil })
---@param opts? { method: string, priority: integer }  method: "HEAD" (default) or "GET"; priority: 1-10 (lower = higher)
function M.validate_url(url, callback, opts)
  opts = opts or {}
  local method = opts.method or "HEAD"

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

  local key = make_url_key(url, method)

  -- If already in-flight, join via coalescer (bypass rate limiter queue)
  if url_pool:is_pending(key) then
    url_pool:request(key, function() end, function(result, err)
      if err then
        callback({ url = url, status = 0, error = err })
      else
        callback(result)
      end
    end)
    return
  end

  -- Submit to rate limiter (queues if concurrency/cooldown limits are hit)
  local domain = url_domain(url)
  local priority = opts.priority or 5
  local rl = get_limiter()
  local ok, status = rl:submit(domain, { priority = priority }, function(done)
    -- Start validation via coalescer pool (preserves callback fan-out for duplicate URLs)
    url_pool:request(key, function(resolve)
      run_curl(url, method, resolve)
    end, function(result, err)
      if err then
        callback({ url = url, status = 0, error = err })
        done()
        return
      end
      -- Handle HEAD→GET fallback: curl resolved with a fallback marker.
      -- The retry goes through validate_url again (gets its own rate limiter slot),
      -- so release the current permit now.
      if result._fallback_get then
        done()
        M.validate_url(url, callback, { method = "GET", priority = priority })
        return
      end
      callback(result)
      done()
    end)
  end)

  if not ok then
    callback({ url = url, status = -2, error = status })
  end
end

--- Validate multiple URLs with queue-based concurrency control.
--- All entries are submitted to the rate limiter which handles concurrency,
--- per-domain cooldowns, and priority ordering.
---@param url_entries { url: string, lnum: number, col: number, end_col: number, priority: integer|nil }[]
---@param on_result fun(entry: table, result: table)|nil
---@param on_done fun(results: table[])
function M.validate_batch(url_entries, on_result, on_done)
  local results = {}
  local remaining = #url_entries
  if remaining == 0 then
    if on_done then on_done({}) end
    return
  end

  for _, entry in ipairs(url_entries) do
    M.validate_url(entry.url, function(result)
      results[#results + 1] = { entry = entry, result = result }
      if on_result then
        on_result(entry, result)
      end
      remaining = remaining - 1
      if remaining == 0 and on_done then
        on_done(results)
      end
    end, { priority = entry.priority })
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
  return nil
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
  local rl = _limiter
  local rl_stats = rl and rl:stats() or { submitted = 0, completed = 0, rejected = 0 }
  return {
    total = total,
    valid = valid,
    expired = expired,
    by_class = by_class,
    queue_depth = rl and rl:queue_depth() or 0,
    queue_active = rl and rl:active_count() or 0,
    queue_submitted = rl_stats.submitted,
    queue_completed = rl_stats.completed,
    queue_rejected = rl_stats.rejected,
    max_queue_size = config.url_validation.max_queue_size or 200,
  }
end

-- Register with engine cache system (deferred to avoid circular require with engine.lua)
vim.schedule(function()
  local engine = require("andrew.vault.engine")
  engine.register_cache({
    name = "url_validation",
    module = "andrew.vault.url_validate",
    invalidate = function()
      if _limiter then _limiter:destroy() end
      _limiter = nil
      local count = 0
      for _ in pairs(_cache) do count = count + 1 end
      _cache_evictions = _cache_evictions + count
      _cache = {}
      _cache_dirty = false
    end,
    stats = function()
      local s = M.cache_stats()
      return {
        entries = s.total,
        valid = s.valid,
        expired = s.expired,
      }
    end,
  })

  local profiler = require("andrew.vault.memory_profiler")
  profiler.register_cache({
    name = "url_validation",
    get_size = function()
      local count = 0
      for _ in pairs(_cache) do count = count + 1 end
      return count
    end,
    get_capacity = function() return nil end,
    get_hits = function() return _cache_hits end,
    get_misses = function() return _cache_misses end,
    get_evictions = function() return _cache_evictions end,
  })
end)

return M
