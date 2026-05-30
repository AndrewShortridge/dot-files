--- js2lua/context.lua -- Transform context and cursor helpers.

local TK = require("andrew.vault.query.js2lua.tokens")

local M = {}

--- Create a new transform context.
---@param tokens table[]
---@return table ctx
function M.make_ctx(tokens)
  return {
    tokens = tokens,
    pos = 1,
    out = {},           -- output buffer (list of strings)
    map_vars = {},      -- set of variable names known to be Maps
    indent = "",        -- current indentation string
  }
end

--- Peek at token at offset from current position (0 = current).
---@param ctx table
---@param offset number|nil
---@return table token
function M.tk_peek(ctx, offset)
  local i = ctx.pos + (offset or 0)
  if i < 1 or i > #ctx.tokens then
    return { type = TK.EOF, value = "" }
  end
  return ctx.tokens[i]
end

--- Get current token.
---@param ctx table
---@return table
function M.tk_cur(ctx)
  return M.tk_peek(ctx, 0)
end

--- Advance to next token and return the one we just passed.
---@param ctx table
---@return table
function M.tk_advance(ctx)
  local t = M.tk_cur(ctx)
  ctx.pos = ctx.pos + 1
  return t
end

--- Check if current token matches type and optionally value.
---@param ctx table
---@param typ string
---@param val string|nil
---@return boolean
function M.tk_is(ctx, typ, val)
  local t = M.tk_cur(ctx)
  if t.type ~= typ then return false end
  if val and t.value ~= val then return false end
  return true
end

--- Skip whitespace and newline tokens, returning them concatenated.
---@param ctx table
---@return string
function M.skip_ws(ctx)
  local buf = {}
  while M.tk_cur(ctx).type == TK.WS or M.tk_cur(ctx).type == TK.NL or M.tk_cur(ctx).type == TK.COMMENT do
    buf[#buf + 1] = M.tk_advance(ctx).value
  end
  return table.concat(buf)
end

--- Peek ahead past whitespace to find the next significant token.
---@param ctx table
---@param start_offset number|nil  offset to start looking from (default 0)
---@return table token
---@return number offset  the offset where it was found
function M.peek_significant(ctx, start_offset)
  local off = start_offset or 0
  while true do
    local t = M.tk_peek(ctx, off)
    if t.type ~= TK.WS and t.type ~= TK.NL and t.type ~= TK.COMMENT then
      return t, off
    end
    off = off + 1
  end
end

--- Emit a string to the output.
---@param ctx table
---@param s string
function M.emit(ctx, s)
  ctx.out[#ctx.out + 1] = s
end

return M
