--- js2lua.lua -- DataviewJS-to-Lua transpiler for vault query blocks.
---
--- Converts a subset of JavaScript (as used by Obsidian Dataview) into
--- executable Lua code that runs against the `dv` API environment provided
--- by `andrew.vault.query.api`.
---
--- Usage:
---   local js2lua = require("andrew.vault.query.js2lua")
---   local lua_code, err = js2lua.transpile(js_source)

local M = {}

local TK          = require("andrew.vault.query.js2lua.tokens")
local tokenizer   = require("andrew.vault.query.js2lua.tokenizer")
local context     = require("andrew.vault.query.js2lua.context")
local statement   = require("andrew.vault.query.js2lua.statement")
local postprocess = require("andrew.vault.query.js2lua.postprocess")

-- ---------------------------------------------------------------------------
-- Transpilation cache
-- ---------------------------------------------------------------------------
-- transpile() is a pure function of js_code, so results never go stale and can
-- be memoized indefinitely by source text. Query blocks are re-transpiled on
-- every render (buffer change, block refresh), so this avoids repeated
-- tokenize/parse/postprocess work for unchanged source. Bounded to cap memory.
local _cache = {}        -- js_code -> { lua_code, err }
local _cache_count = 0
local _CACHE_MAX = 128

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local function transpile_uncached(js_code)
  local ok, result = pcall(function()
    local tokens = tokenizer.tokenize(js_code)
    local ctx = context.make_ctx(tokens)

    while ctx.pos <= #ctx.tokens and context.tk_cur(ctx).type ~= TK.EOF do
      statement.transform_statement(ctx)
    end

    local raw_lua = table.concat(ctx.out)
    return postprocess.postprocess(raw_lua)
  end)

  if not ok then
    return nil, "transpile error: " .. tostring(result)
  end
  return result, nil
end

--- Transpile a DataviewJS (JavaScript) code block into Lua code.
---
--- Returns the Lua code and nil on success, or nil and an error string on
--- failure. Results are memoized by source text.
---
---@param js_code string  The JavaScript source code.
---@return string|nil lua_code  The transpiled Lua code, or nil on error.
---@return string|nil error     Error message, or nil on success.
function M.transpile(js_code)
  if type(js_code) ~= "string" or js_code == "" then
    return nil, "transpile: input must be a non-empty string"
  end

  local hit = _cache[js_code]
  if hit then
    return hit[1], hit[2]
  end

  local lua_code, err = transpile_uncached(js_code)

  -- Simple bounded cache: drop everything once the cap is reached. Query
  -- source sets are small in practice, so churn here is negligible.
  if _cache_count >= _CACHE_MAX then
    _cache = {}
    _cache_count = 0
  end
  _cache[js_code] = { lua_code, err }
  _cache_count = _cache_count + 1

  return lua_code, err
end

--- Clear the transpilation cache (exposed for tests / diagnostics).
function M.clear_cache()
  _cache = {}
  _cache_count = 0
end

return M
