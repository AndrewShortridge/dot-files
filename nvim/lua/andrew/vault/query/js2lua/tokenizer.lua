--- js2lua/tokenizer.lua -- JavaScript tokenizer for the JS-to-Lua transpiler.

local TK = require("andrew.vault.query.js2lua.tokens")

local M = {}

--- Tokenize JavaScript source into a flat list of tokens.
--- Each token is { type = TK.*, value = string, ... }
--- Template literals get an extra `parts` field: list of
--- { type = "text"|"expr", value = string }.
---@param src string
---@return table[] tokens
function M.tokenize(src)
  local tokens = {}
  local pos = 1
  local len = #src

  --- Peek at character at offset (0-based from pos).
  local function peek(offset)
    local i = pos + (offset or 0)
    if i > len then return "" end
    return src:sub(i, i)
  end

  --- Advance pos by n characters and return the consumed substring.
  local function advance(n)
    local s = src:sub(pos, pos + n - 1)
    pos = pos + n
    return s
  end

  --- Check if the previous non-whitespace token makes a `/` an operator.
  --- Returns true if `/` should be treated as division, false if regex.
  local function slash_is_division()
    for i = #tokens, 1, -1 do
      local t = tokens[i]
      if t.type ~= TK.WS and t.type ~= TK.NL and t.type ~= TK.COMMENT then
        -- After an identifier, number, closing paren/bracket, or ++/-- -> division
        if t.type == TK.IDENT or t.type == TK.NUM then return true end
        if t.type == TK.PUNCT and (t.value == ")" or t.value == "]") then return true end
        if t.type == TK.OP and (t.value == "++" or t.value == "--") then return true end
        return false
      end
    end
    return false -- start of input -> regex
  end

  while pos <= len do
    local ch = peek()

    -- Newline
    if ch == "\n" then
      tokens[#tokens + 1] = { type = TK.NL, value = advance(1) }

    -- Whitespace (not newline)
    elseif ch == " " or ch == "\t" or ch == "\r" then
      local start = pos
      while pos <= len and (peek() == " " or peek() == "\t" or peek() == "\r") do
        pos = pos + 1
      end
      tokens[#tokens + 1] = { type = TK.WS, value = src:sub(start, pos - 1) }

    -- Single-line comment
    elseif ch == "/" and peek(1) == "/" then
      local start = pos
      pos = pos + 2
      while pos <= len and peek() ~= "\n" do
        pos = pos + 1
      end
      tokens[#tokens + 1] = { type = TK.COMMENT, value = src:sub(start, pos - 1) }

    -- Multi-line comment
    elseif ch == "/" and peek(1) == "*" then
      local start = pos
      pos = pos + 2
      while pos <= len do
        if peek() == "*" and peek(1) == "/" then
          pos = pos + 2
          break
        end
        pos = pos + 1
      end
      tokens[#tokens + 1] = { type = TK.COMMENT, value = src:sub(start, pos - 1) }

    -- Template literal
    elseif ch == "`" then
      pos = pos + 1 -- skip opening backtick
      local parts = {}
      local buf = ""
      while pos <= len and peek() ~= "`" do
        if peek() == "$" and peek(1) == "{" then
          -- Save text so far
          if buf ~= "" then
            parts[#parts + 1] = { type = "text", value = buf }
            buf = ""
          end
          pos = pos + 2 -- skip ${
          local depth = 1
          local expr_start = pos
          while pos <= len and depth > 0 do
            local c = peek()
            if c == "{" then depth = depth + 1
            elseif c == "}" then depth = depth - 1
            end
            if depth > 0 then pos = pos + 1 end
          end
          parts[#parts + 1] = { type = "expr", value = src:sub(expr_start, pos - 1) }
          pos = pos + 1 -- skip closing }
        elseif peek() == "\\" then
          buf = buf .. advance(2) -- escape sequence
        else
          buf = buf .. advance(1)
        end
      end
      if buf ~= "" then
        parts[#parts + 1] = { type = "text", value = buf }
      end
      if pos <= len then pos = pos + 1 end -- skip closing backtick
      tokens[#tokens + 1] = { type = TK.TMPL, value = "", parts = parts }

    -- String literal (single or double quoted)
    elseif ch == '"' or ch == "'" then
      local quote = ch
      local start = pos
      pos = pos + 1
      while pos <= len and peek() ~= quote do
        if peek() == "\\" then
          pos = pos + 2
        else
          pos = pos + 1
        end
      end
      if pos <= len then pos = pos + 1 end -- closing quote
      tokens[#tokens + 1] = { type = TK.STR, value = src:sub(start, pos - 1) }

    -- Regex literal
    elseif ch == "/" and not slash_is_division() then
      local start = pos
      pos = pos + 1 -- skip opening /
      local in_class = false
      while pos <= len do
        local c = peek()
        if c == "\\" then
          pos = pos + 2
        elseif c == "[" then
          in_class = true
          pos = pos + 1
        elseif c == "]" then
          in_class = false
          pos = pos + 1
        elseif c == "/" and not in_class then
          pos = pos + 1
          break
        else
          pos = pos + 1
        end
      end
      -- Flags
      while pos <= len and peek():match("[gimsuy]") do
        pos = pos + 1
      end
      tokens[#tokens + 1] = { type = TK.REGEX, value = src:sub(start, pos - 1) }

    -- Number
    elseif ch:match("%d") or (ch == "." and peek(1):match("%d")) then
      local start = pos
      if peek() == "0" and (peek(1) == "x" or peek(1) == "X") then
        pos = pos + 2
        while pos <= len and peek():match("[%da-fA-F]") do pos = pos + 1 end
      else
        while pos <= len and peek():match("[%d]") do pos = pos + 1 end
        if peek() == "." then
          pos = pos + 1
          while pos <= len and peek():match("[%d]") do pos = pos + 1 end
        end
        if peek() == "e" or peek() == "E" then
          pos = pos + 1
          if peek() == "+" or peek() == "-" then pos = pos + 1 end
          while pos <= len and peek():match("[%d]") do pos = pos + 1 end
        end
      end
      tokens[#tokens + 1] = { type = TK.NUM, value = src:sub(start, pos - 1) }

    -- Identifier or keyword
    elseif ch:match("[%a_$]") then
      local start = pos
      while pos <= len and peek():match("[%w_$]") do
        pos = pos + 1
      end
      tokens[#tokens + 1] = { type = TK.IDENT, value = src:sub(start, pos - 1) }

    -- Multi-char operators
    elseif ch == "=" and peek(1) == "=" and peek(2) == "=" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(3) }
    elseif ch == "!" and peek(1) == "=" and peek(2) == "=" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(3) }
    elseif ch == "=" and peek(1) == ">" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == "&" and peek(1) == "&" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == "|" and peek(1) == "|" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == "=" and peek(1) == "=" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == "!" and peek(1) == "=" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == ">" and peek(1) == "=" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == "<" and peek(1) == "=" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == "+" and peek(1) == "=" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == "-" and peek(1) == "=" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == "+" and peek(1) == "+" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }
    elseif ch == "-" and peek(1) == "-" then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(2) }

    -- Single-char operators
    elseif ch == "+" or ch == "-" or ch == "*" or ch == "/"
        or ch == "%" or ch == "=" or ch == "!" or ch == "<"
        or ch == ">" or ch == "." then
      tokens[#tokens + 1] = { type = TK.OP, value = advance(1) }

    -- Punctuation
    elseif ch == "(" or ch == ")" or ch == "[" or ch == "]"
        or ch == "{" or ch == "}" or ch == "," or ch == ";"
        or ch == ":" or ch == "?" then
      tokens[#tokens + 1] = { type = TK.PUNCT, value = advance(1) }

    else
      -- Unknown character -- skip it
      tokens[#tokens + 1] = { type = TK.WS, value = advance(1) }
    end
  end

  tokens[#tokens + 1] = { type = TK.EOF, value = "" }
  return tokens
end

return M
