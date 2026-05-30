--- DQL parser state: cursor over a token list with peek/advance/match/expect.

local M = {}

--- Create a new parser over a token list.
---@param tokens table[]  list of tokens from tokenize()
---@return table           parser state with cursor and helper methods
function M.new(tokens)
  local P = {
    tokens = tokens,
    pos = 1,
  }

  --- Return the current token without consuming it.
  function P:peek()
    return self.tokens[self.pos]
  end

  --- Return the current token and advance the cursor.
  function P:advance()
    local tok = self.tokens[self.pos]
    self.pos = self.pos + 1
    return tok
  end

  --- If the current token matches `type`, consume and return it.
  --- Otherwise return nil.
  function P:match(type)
    if self:peek().type == type then
      return self:advance()
    end
    return nil
  end

  --- Consume a token of `type` or produce an error.
  function P:expect(type)
    local tok = self:peek()
    if tok.type == type then
      return self:advance()
    end
    return nil, "expected " .. type .. " at position " .. tok.pos
        .. " but got " .. tok.type
        .. (tok.value and (" '" .. tostring(tok.value) .. "'") or "")
  end

  --- Format a contextual error message.
  function P:error(msg)
    local tok = self:peek()
    return msg .. " at position " .. tok.pos
  end

  return P
end

return M
