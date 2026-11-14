local engine = require("andrew.vault.engine")
local parser = require("andrew.vault.query.parser")
local index_mod = require("andrew.vault.query.index")
local executor = require("andrew.vault.query.executor")
local api = require("andrew.vault.query.api")
local render = require("andrew.vault.query.render")
local js2lua = require("andrew.vault.query.js2lua")
local notify = require("andrew.vault.notify")
local gen_cache = require("andrew.vault.gen_cache")
local pat = require("andrew.vault.patterns")
local config = require("andrew.vault.config")
local lru_cache = require("andrew.vault.lru_cache")
local M = {}

-- Bounded result cache wrapping execute_dql/execute_lua/execute_js. The output
-- of a query block is a pure function of (block kind, content, the resolved
-- query index contents, current_file). The query index contents are fully
-- determined by vault_index.current()._generation (the same generation
-- gen_cache keys on), so including that generation in the key makes the cache
-- invalidation-correct: any vault file change bumps the generation and stale
-- entries simply never match (and age out via LRU). current_file matters
-- because executor resolves this.* / current_page from it.
-- NOTE: cached result tables are returned shared on a hit; render only READS
-- them (it builds new content_lines and never mutates items), so this is safe.
-- Downstream consumers of these results MUST remain read-only.
local _result_cache = lru_cache.new(config.cache.query_result_max or 64)
local _result_hits = 0
local _result_misses = 0

-- Bounded content->AST cache for DQL parsing. parser.parse() is a pure function
-- of the query text, so the AST never goes stale and can be memoized by content
-- ALONE (independent of vault generation), exactly like the js2lua transpile
-- cache. The executor/results treat the AST as read-only (they only READ ast.*,
-- never mutate it — do not mutate), so the cached AST table is safely shared
-- across generation bumps. This means a vault save (which bumps the generation
-- and misses the result cache) no longer re-tokenizes and rebuilds the AST for
-- an unchanged query string. Reuses the shared LRU helper (same one backing the
-- result cache above) rather than a hand-rolled bounded map.
local _ast_cache = lru_cache.new(config.cache.query_ast_max or 128) -- content -> { ast, err }

local function clear_ast_cache()
  _ast_cache:clear()
end

local function parse_cached(content)
  local hit = _ast_cache:get(content)
  if hit then
    return hit[1], hit[2]
  end
  local ast, err = parser.parse(content)
  _ast_cache:put(content, { ast, err })
  return ast, err
end

--- Current vault index generation (mirrors gen_cache.current_index) without a
--- hard require, so a vault switch / generation bump changes the cache key.
local function current_gen()
  local vi = package.loaded["andrew.vault.vault_index"]
  local idx = vi and vi.current() or nil
  return idx and idx._generation or 0
end

-- Generation-cached query index.
-- key_fn returns vault_path so the cache rebuilds when the vault changes.
-- build_fn handles incremental vs full rebuild based on whether an existing
-- index for the same vault is available.
local _prev_index = nil -- retained between builds for incremental updates

local _index_cache = gen_cache.gen_cache(function(_idx)
  local vault_path = engine.vault_path
  if _prev_index and _prev_index.vault_path == vault_path then
    -- No ctx → full rebuild from the vault index (same-vault refresh path).
    _prev_index:update_incremental()
  else
    _prev_index = index_mod.Index.new(vault_path)
    _prev_index:build_sync()
  end
  return _prev_index
end, {
  key_fn = function() return engine.vault_path end,
  -- Scoped update for a small batch of changed files: re-convert only the
  -- affected pages instead of rebuilding every page. Returns _prev_index so it
  -- stays cached. Bail to a full rebuild (return nil) if the retained index is
  -- not the cached value (vault switched between builds).
  partial_fn = function(cached, idx, ctx)
    if not _prev_index or cached ~= _prev_index then return nil end
    _prev_index:update_incremental(idx, ctx)
    return _prev_index
  end,
})

--- Get or build the vault index. Rebuilds if vault was modified.
local function get_index()
  return _index_cache.get()
end

--- Force rebuild the index
function M.rebuild_index()
  _prev_index = nil
  _index_cache.invalidate()
  get_index()
  notify.info("query: index rebuilt")
end

-- Register with central cache registry
engine.register_cache({
  name = "query_index",
  module = "andrew.vault.query",
  invalidate = function()
    _prev_index = nil
    _index_cache.invalidate()
  end,
  stats = function()
    local index = _prev_index
    return {
      entries = index and index.pages and vim.tbl_count(index.pages) or 0,
      index_generation = _prev_index and "cached" or "none",
      vault = index and index.vault_path or nil,
    }
  end,
})

-- Register the bounded query result cache (belt-and-suspenders invalidation:
-- generation is part of the key, but a forced rebuild / cache-clear must drop
-- stale entries too).
engine.register_cache({
  name = "query_result",
  module = "andrew.vault.query",
  invalidate = function()
    _result_cache:clear()
    clear_ast_cache()
  end,
  stats = function()
    return {
      entries = _result_cache:size(),
      hits = _result_hits,
      misses = _result_misses,
    }
  end,
})

do
  local profiler = require("andrew.vault.memory_profiler")
  profiler.register_cache({
    name = "query_index",
    get_size = function()
      local index = _prev_index
      return index and index.pages and vim.tbl_count(index.pages) or 0
    end,
    get_capacity = function() return nil end,
    get_hits = function() return _index_cache.get_hits() end,
    get_misses = function() return _index_cache.get_misses() end,
    get_evictions = function() return 0 end,
  })
  profiler.register_cache({
    name = "query_result",
    get_size = function() return _result_cache:size() end,
    get_capacity = function() return config.cache.query_result_max end,
    get_hits = function() return _result_hits end,
    get_misses = function() return _result_misses end,
    get_evictions = function() return 0 end,
  })
end

--- Find the code block boundaries around the cursor position.
--- Returns block_type, content, start_line, end_line (0-indexed) or nil.
local function find_code_block_at_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-indexed
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local total = #lines

  -- Walk backwards from cursor to find opening fence
  local open_line = nil
  local block_type = nil
  for i = row, 0, -1 do
    local line = lines[i + 1]
    local lang = line:match("^%s*```(%S+)")
    if lang then
      open_line = i
      block_type = lang:lower()
      break
    end
    -- Hit a closing fence before an opening one -> not inside a block
    if i < row and line:match("^%s*```%s*$") then
      return nil
    end
  end
  if not open_line then return nil end

  -- Walk forwards from opening fence to find closing fence
  local close_line = nil
  for i = open_line + 1, total - 1 do
    local line = lines[i + 1]
    if line:match("^%s*```%s*$") then
      close_line = i
      break
    end
  end
  if not close_line then return nil end

  -- Cursor must be between open and close
  if row < open_line or row > close_line then return nil end

  -- Extract content (lines between fences)
  local content_lines = {}
  for i = open_line + 2, close_line do -- +2 because buf_get_lines is 1-indexed
    table.insert(content_lines, lines[i])
  end
  local content = table.concat(content_lines, "\n")

  return block_type, content, open_line, close_line
end

--- Build a result-cache key. A type tag keeps dataview/lua/js blocks with
--- identical content from colliding. The \0 separator cannot appear in any
--- component (kind/current_file/content are all NUL-free in practice).
local function result_key(kind, content, current_file)
  return kind .. "\0" .. tostring(current_gen()) .. "\0" .. (current_file or "") .. "\0" .. content
end

--- Run `compute` through the bounded result cache under (kind, content,
--- current_file). On a hit the cached result table is returned shared (render
--- only reads it); on a miss `compute` runs and its result is stored.
---@param kind string block-kind tag for the cache key
---@param content string raw block content
---@param current_file string|nil resolves this.* / current_page
---@param compute fun(): table
---@return table
local function memoized(kind, content, current_file, compute)
  local key = result_key(kind, content, current_file)
  local hit = _result_cache:get(key)
  if hit ~= nil then
    _result_hits = _result_hits + 1
    return hit
  end
  _result_misses = _result_misses + 1
  local results = compute()
  _result_cache:put(key, results)
  return results
end

--- Execute a dataview DQL query and return render results.
local function execute_dql(content, current_file)
  return memoized("dataview", content, current_file, function()
    local idx = get_index()
    local ast, parse_err = parse_cached(content)
    if not ast then
      return { { type = "error", message = "Parse error: " .. (parse_err or "unknown") } }
    end
    local exec_results, exec_err = executor.execute(ast, idx, current_file)
    if not exec_results then
      return { { type = "error", message = "Execution error: " .. (exec_err or "unknown") } }
    end
    return exec_results
  end)
end

--- Execute a Lua vault block and return render results.
local function execute_lua(content, current_file)
  return memoized("vault", content, current_file, function()
    local idx = get_index()
    local results, err = api.execute_block(content, idx, current_file)
    if not results then
      return { { type = "error", message = "Lua error: " .. (err or "unknown") } }
    end
    return results
  end)
end

--- Transpile JavaScript to Lua, then execute.
local function execute_js(content, current_file)
  return memoized("dataviewjs", content, current_file, function()
    local lua_code, transpile_err = js2lua.transpile(content)
    if not lua_code then
      return { { type = "error", message = "Transpile error: " .. (transpile_err or "unknown") } }
    end
    -- execute_lua keys the transpiled lua under the "vault" tag; the JS result
    -- is keyed here under "dataviewjs" so JS keys stay human-correspondent.
    return execute_lua(lua_code, current_file)
  end)
end

--- Render the query block under the cursor, or inline expr on current line.
function M.render_block()
  local block_type, content, _, close_line = find_code_block_at_cursor()
  if not block_type then
    -- Check if current line has an inline `$=...` expression
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local found_inline = false
    local current_file = vim.api.nvim_buf_get_name(buf)
    -- Clear this row's inline marks first so re-rendering the same line does not
    -- stack duplicate virtual text (render_inline only adds extmarks).
    render.clear_inline_line(buf, row)
    local search_start = 1
    while true do
      local s, e, expr = line:find("`%$=(.-)%`", search_start)
      if not s then break end
      search_start = e + 1
      found_inline = true
      local ok, result = pcall(function()
        local lua_expr = js2lua.transpile(expr)
        if not lua_expr then lua_expr = expr end
        -- Wrap as return statement for inline expressions
        local code = "return " .. vim.trim(lua_expr)
        local idx = get_index()
        local results, err = api.execute_block(code, idx, current_file)
        if not results then return nil, err end
        if #results > 0 and results[1].text then
          return results[1].text
        elseif #results > 0 and results[1].items then
          return tostring(#results[1].items) .. " items"
        end
        return tostring(results[1] and results[1].text or "nil")
      end)
      if ok and result then
        render.render_inline(buf, row, e - 1, tostring(result), false)
      else
        render.render_inline(buf, row, e - 1, tostring(result or "error"), true)
      end
    end
    if not found_inline then
      notify.warn("query: cursor not inside a code block or inline expression")
    end
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(buf)

  local ok, results = pcall(function()
    if block_type == "dataview" then
      return execute_dql(content, current_file)
    elseif block_type == "dataviewjs" then
      return execute_js(content, current_file)
    elseif block_type == "vault" then
      return execute_lua(content, current_file)
    else
      return { { type = "error", message = "unsupported block type '" .. block_type .. "'" } }
    end
  end)

  if ok then
    render.render(buf, close_line, results)
  else
    render.render(buf, close_line, {
      { type = "error", message = tostring(results) },
    })
  end
end

--- Clear rendered output under the cursor.
function M.clear_block()
  local buf = vim.api.nvim_get_current_buf()
  local block_type, _, _, close_line = find_code_block_at_cursor()
  if not block_type then
    -- Not in a block: clear inline `$=` output on the cursor line instead, so
    -- <leader>vqc undoes what <leader>vqr rendered there.
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    if line:find("`%$=") then
      render.clear_inline_line(buf, row)
      return
    end
    notify.warn("query: cursor not inside a code block")
    return
  end
  render.clear(buf, close_line)
end

--- Toggle rendered output under the cursor.
function M.toggle_block()
  local block_type, content, _, close_line = find_code_block_at_cursor()
  if not block_type then
    notify.warn("query: cursor not inside a code block")
    return
  end

  local buf = vim.api.nvim_get_current_buf()

  if render.is_rendered(buf, close_line) then
    render.clear(buf, close_line)
  else
    local current_file = vim.api.nvim_buf_get_name(buf)
    local results
    if block_type == "dataview" then
      results = execute_dql(content, current_file)
    elseif block_type == "dataviewjs" then
      results = execute_js(content, current_file)
    elseif block_type == "vault" then
      results = execute_lua(content, current_file)
    else
      notify.warn("query: unsupported block type '" .. block_type .. "'")
      return
    end
    render.render(buf, close_line, results)
  end
end

--- Render all query blocks in the current buffer.
function M.render_all()
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_file = vim.api.nvim_buf_get_name(buf)
  local total = #lines
  local block_count = 0

  local i = 0
  while i < total do
    local line = lines[i + 1]
    local lang = line:match("^%s*```(%S+)")
    if lang then
      local block_type = lang:lower()
      if block_type == "dataview" or block_type == "dataviewjs" or block_type == "vault" then
        -- Find closing fence
        local close_line = nil
        local content_lines = {}
        for j = i + 1, total - 1 do
          if lines[j + 1]:match("^%s*```%s*$") then
            close_line = j
            break
          end
          table.insert(content_lines, lines[j + 1])
        end
        if close_line then
          local content = table.concat(content_lines, "\n")
          local ok, results = pcall(function()
            if block_type == "dataview" then
              return execute_dql(content, current_file)
            elseif block_type == "dataviewjs" then
              return execute_js(content, current_file)
            else
              return execute_lua(content, current_file)
            end
          end)
          if ok then
            render.render(buf, close_line, results)
          else
            notify.info("query: block at line " .. i .. " error: " .. tostring(results))
            render.render(buf, close_line, {
              { type = "error", message = tostring(results) },
            })
          end
          block_count = block_count + 1
          i = close_line + 1
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  -- Also render inline expressions
  local inline_count = M.render_inline_all()

  local parts = {}
  if block_count > 0 then
    parts[#parts + 1] = block_count .. " block(s)"
  end
  if inline_count > 0 then
    parts[#parts + 1] = inline_count .. " inline"
  end
  if #parts == 0 then
    notify.warn("query: no dataview/vault queries found in buffer")
  else
    notify.info("query: rendered " .. table.concat(parts, ", "))
  end
end

--- Render all inline `$=expr` expressions in the current buffer.
function M.render_inline_all()
  local buf = vim.api.nvim_get_current_buf()
  -- Drop any previously rendered inline marks first: render_inline() only ADDS
  -- extmarks, so re-running (e.g. pressing <leader>vqa twice) otherwise stacked
  -- a second copy of every `$=` result next to the first.
  render.clear_all_inline(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local current_file = vim.api.nvim_buf_get_name(buf)
  local count = 0
  local inside_code_block = false

  for i, line in ipairs(lines) do
    -- Track code block boundaries so we skip fenced blocks
    if pat.is_code_fence(line) then
      inside_code_block = not inside_code_block
    elseif not inside_code_block then
      -- Find all `$=...` patterns on this line
      local search_start = 1
      while true do
        local s, e, expr = line:find("`%$=(.-)%`", search_start)
        if not s then break end
        search_start = e + 1

        local row = i - 1 -- 0-indexed
        local ok, result = pcall(function()
          local lua_expr = js2lua.transpile(expr)
          if not lua_expr then lua_expr = expr end
          local code = "return " .. vim.trim(lua_expr)
          local idx = get_index()
          local results, err = api.execute_block(code, idx, current_file)
          if not results then return nil, err end
          if #results > 0 and results[1].text then
            return results[1].text
          elseif #results > 0 and results[1].items then
            return tostring(#results[1].items) .. " items"
          end
          return tostring(results[1] and results[1].text or "nil")
        end)
        if ok and result then
          render.render_inline(buf, row, e - 1, tostring(result), false)
        else
          render.render_inline(buf, row, e - 1, tostring(result or "error"), true)
        end
        count = count + 1
      end
    end
  end

  return count
end

--- Clear all rendered output in the current buffer.
function M.clear_all()
  local buf = vim.api.nvim_get_current_buf()
  render.clear_all(buf)
  render.clear_all_inline(buf)
end

-- Commands, keymaps and palette entries are registered as Tier-3 lazy stubs in
-- andrew.vault.init (so opening a markdown buffer does not pull in this module's
-- js2lua transpiler tree); they require this module on first :VaultQuery* use.

return M
