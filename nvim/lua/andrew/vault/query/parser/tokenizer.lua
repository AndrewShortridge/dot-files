--- DQL tokenizer: lexical analysis for Dataview Query Language.
---
--- Produces a flat token list from a raw query string.

local M = {}

-- =============================================================================
-- Token types
-- =============================================================================

M.TK = {
  -- Literals and identifiers
  STRING = "STRING",
  NUMBER = "NUMBER",
  IDENT = "IDENT",

  -- Punctuation
  DOT = "DOT",
  COMMA = "COMMA",
  LPAREN = "LPAREN",
  RPAREN = "RPAREN",
  BANG = "BANG",
  HASH = "HASH",
  SLASH = "SLASH",
  PLUS = "PLUS",
  MINUS = "MINUS",
  STAR = "STAR",

  -- Comparison operators
  EQ = "EQ",
  NEQ = "NEQ",
  LT = "LT",
  GT = "GT",
  LTE = "LTE",
  GTE = "GTE",

  -- End of input
  EOF = "EOF",
}

--- Keywords recognized by the tokenizer. Stored uppercase for
--- case-insensitive matching. When a scanned identifier matches one of
--- these (after uppercasing), the token type becomes that keyword string.
M.KEYWORDS = {
  TABLE = true, LIST = true, TASK = true,
  FROM = true, WHERE = true, SORT = true,
  GROUP = true, BY = true, FLATTEN = true, LIMIT = true,
  AS = true, ASC = true, DESC = true,
  WITHOUT = true, ID = true,
  AND = true, OR = true, NOT = true,
  CONTAINS = true,
  TRUE = true, FALSE = true, NULL = true,
  THIS = true,
}

--- Create a token table.
---@param type string   token type from TK or a keyword string
---@param value any     semantic value (string text, number, etc.)
---@param pos  number   1-based byte offset in the source where the token starts
---@return table
local function token(type, value, pos)
  return { type = type, value = value, pos = pos }
end

--- Tokenize a DQL query string into a flat list of tokens.
---@param src string  the raw query text
---@return table[]    list of tokens, always ending with an EOF token
---@return string|nil error message on failure
function M.tokenize(src)
  local TK = M.TK
  local KEYWORDS = M.KEYWORDS
  local tokens = {}
  local i = 1
  local len = #src

  --- Skip whitespace and advance `i`.
  local function skip_ws()
    while i <= len do
      local ch = src:byte(i)
      -- space, tab, newline, carriage return
      if ch == 32 or ch == 9 or ch == 10 or ch == 13 then
        i = i + 1
      else
        break
      end
    end
  end

  while true do
    skip_ws()
    if i > len then
      tokens[#tokens + 1] = token(TK.EOF, nil, i)
      break
    end

    local start = i
    local ch = src:sub(i, i)
    local byte = ch:byte()

    -- -----------------------------------------------------------------
    -- Single-character punctuation
    -- -----------------------------------------------------------------
    if ch == "." then
      tokens[#tokens + 1] = token(TK.DOT, ".", start)
      i = i + 1
    elseif ch == "," then
      tokens[#tokens + 1] = token(TK.COMMA, ",", start)
      i = i + 1
    elseif ch == "(" then
      tokens[#tokens + 1] = token(TK.LPAREN, "(", start)
      i = i + 1
    elseif ch == ")" then
      tokens[#tokens + 1] = token(TK.RPAREN, ")", start)
      i = i + 1
    elseif ch == "#" then
      tokens[#tokens + 1] = token(TK.HASH, "#", start)
      i = i + 1
    elseif ch == "/" then
      tokens[#tokens + 1] = token(TK.SLASH, "/", start)
      i = i + 1
    elseif ch == "+" then
      tokens[#tokens + 1] = token(TK.PLUS, "+", start)
      i = i + 1
    elseif ch == "-" then
      tokens[#tokens + 1] = token(TK.MINUS, "-", start)
      i = i + 1
    elseif ch == "*" then
      tokens[#tokens + 1] = token(TK.STAR, "*", start)
      i = i + 1

    -- -----------------------------------------------------------------
    -- Multi-character operators
    -- -----------------------------------------------------------------
    elseif ch == "!" then
      if i + 1 <= len and src:sub(i + 1, i + 1) == "=" then
        tokens[#tokens + 1] = token(TK.NEQ, "!=", start)
        i = i + 2
      else
        tokens[#tokens + 1] = token(TK.BANG, "!", start)
        i = i + 1
      end
    elseif ch == "=" then
      tokens[#tokens + 1] = token(TK.EQ, "=", start)
      i = i + 1
    elseif ch == "<" then
      if i + 1 <= len and src:sub(i + 1, i + 1) == "=" then
        tokens[#tokens + 1] = token(TK.LTE, "<=", start)
        i = i + 2
      else
        tokens[#tokens + 1] = token(TK.LT, "<", start)
        i = i + 1
      end
    elseif ch == ">" then
      if i + 1 <= len and src:sub(i + 1, i + 1) == "=" then
        tokens[#tokens + 1] = token(TK.GTE, ">=", start)
        i = i + 2
      else
        tokens[#tokens + 1] = token(TK.GT, ">", start)
        i = i + 1
      end

    -- -----------------------------------------------------------------
    -- String literals (double or single quoted)
    -- -----------------------------------------------------------------
    elseif ch == '"' or ch == "'" then
      local quote = ch
      i = i + 1 -- skip opening quote
      local buf = {}
      while i <= len and src:sub(i, i) ~= quote do
        buf[#buf + 1] = src:sub(i, i)
        i = i + 1
      end
      if i > len then
        return nil, "unterminated string starting at position " .. start
      end
      i = i + 1 -- skip closing quote
      tokens[#tokens + 1] = token(TK.STRING, table.concat(buf), start)

    -- -----------------------------------------------------------------
    -- Number literals
    -- -----------------------------------------------------------------
    elseif byte >= 48 and byte <= 57 then -- 0-9
      local j = i
      while i <= len and src:byte(i) >= 48 and src:byte(i) <= 57 do
        i = i + 1
      end
      -- optional fractional part
      if i <= len and src:sub(i, i) == "." then
        i = i + 1
        while i <= len and src:byte(i) >= 48 and src:byte(i) <= 57 do
          i = i + 1
        end
      end
      tokens[#tokens + 1] = token(TK.NUMBER, tonumber(src:sub(j, i - 1)), start)

    -- -----------------------------------------------------------------
    -- Identifiers and keywords
    -- -----------------------------------------------------------------
    elseif (byte >= 65 and byte <= 90)    -- A-Z
        or (byte >= 97 and byte <= 122)   -- a-z
        or byte == 95 then                -- _
      local j = i
      i = i + 1
      while i <= len do
        local b = src:byte(i)
        if (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or (b >= 48 and b <= 57)
            or b == 95   -- _
            or b == 45   -- - (Obsidian allows hyphens in field names)
        then
          i = i + 1
        else
          break
        end
      end
      local word = src:sub(j, i - 1)
      local upper = word:upper()
      if KEYWORDS[upper] then
        tokens[#tokens + 1] = token(upper, word, start)
      else
        tokens[#tokens + 1] = token(TK.IDENT, word, start)
      end

    -- -----------------------------------------------------------------
    -- Unexpected character
    -- -----------------------------------------------------------------
    else
      return nil, "unexpected character '" .. ch .. "' at position " .. start
    end
  end

  return tokens
end

return M
