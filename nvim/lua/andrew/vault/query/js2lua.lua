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
-- Public API
-- ---------------------------------------------------------------------------

--- Transpile a DataviewJS (JavaScript) code block into Lua code.
---
--- Returns the Lua code and nil on success, or nil and an error string on
--- failure.
---
---@param js_code string  The JavaScript source code.
---@return string|nil lua_code  The transpiled Lua code, or nil on error.
---@return string|nil error     Error message, or nil on success.
function M.transpile(js_code)
  if type(js_code) ~= "string" or js_code == "" then
    return nil, "transpile: input must be a non-empty string"
  end

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

return M
