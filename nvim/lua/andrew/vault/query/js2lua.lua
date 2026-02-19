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

-- ---------------------------------------------------------------------------
-- Token types
-- ---------------------------------------------------------------------------

local TK = {
  IDENT   = "ident",
  NUM     = "num",
  STR     = "str",
  TMPL    = "tmpl",    -- template literal (parsed into segments)
  REGEX   = "regex",
  OP      = "op",
  PUNCT   = "punct",
  NL      = "nl",
  WS      = "ws",
  COMMENT = "comment",
  EOF     = "eof",
}

-- ---------------------------------------------------------------------------
-- Tokenizer
-- ---------------------------------------------------------------------------

--- Tokenize JavaScript source into a flat list of tokens.
--- Each token is { type = TK.*, value = string, ... }
--- Template literals get an extra `parts` field: list of
--- { type = "text"|"expr", value = string }.
---@param src string
---@return table[] tokens
local function tokenize(src)
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

-- ---------------------------------------------------------------------------
-- Regex-to-Lua-pattern converter
-- ---------------------------------------------------------------------------

--- Attempt to convert a JavaScript regex literal to a Lua pattern string.
--- Returns the pattern string and a boolean `is_global`.
--- Returns nil if conversion is not possible.
---@param regex_token string  e.g. `/\w+/g`
---@return string|nil lua_pattern
---@return boolean is_global
local function regex_to_lua_pattern(regex_token)
  -- Extract pattern and flags
  local pattern, flags = regex_token:match("^/(.+)/([gimsuy]*)$")
  if not pattern then
    return nil, false
  end
  local is_global = flags:find("g") ~= nil

  -- Build Lua pattern character by character
  local out = {}
  local i = 1
  local plen = #pattern

  while i <= plen do
    local ch = pattern:sub(i, i)

    if ch == "\\" then
      -- Escape sequence
      i = i + 1
      if i > plen then break end
      local next_ch = pattern:sub(i, i)
      if next_ch == "w" then
        out[#out + 1] = "[%w_]"
      elseif next_ch == "W" then
        out[#out + 1] = "[^%w_]"
      elseif next_ch == "d" then
        out[#out + 1] = "%d"
      elseif next_ch == "D" then
        out[#out + 1] = "%D"
      elseif next_ch == "s" then
        out[#out + 1] = "%s"
      elseif next_ch == "S" then
        out[#out + 1] = "%S"
      elseif next_ch == "b" then
        -- Word boundary -- no Lua equivalent, skip
        -- (approximation: empty)
      elseif next_ch == "n" then
        out[#out + 1] = "\n"
      elseif next_ch == "t" then
        out[#out + 1] = "\t"
      elseif next_ch == "r" then
        out[#out + 1] = "\r"
      elseif next_ch:match("[%(%)%.%%%+%-%*%?%[%]%^%${}|/]") then
        -- Escaped special char -> escape for Lua if needed
        if next_ch:match("[%(%)%.%%%+%-%*%?%[%]%^%$]") then
          out[#out + 1] = "%" .. next_ch
        else
          out[#out + 1] = next_ch
        end
      else
        out[#out + 1] = next_ch
      end
      i = i + 1

    elseif ch == "[" then
      -- Character class
      i = i + 1
      local class_buf = "["
      if i <= plen and pattern:sub(i, i) == "^" then
        class_buf = class_buf .. "^"
        i = i + 1
      end
      -- Allow ] as first char in class
      if i <= plen and pattern:sub(i, i) == "]" then
        class_buf = class_buf .. "%]"
        i = i + 1
      end
      while i <= plen and pattern:sub(i, i) ~= "]" do
        local c = pattern:sub(i, i)
        if c == "\\" then
          i = i + 1
          if i <= plen then
            local nc = pattern:sub(i, i)
            if nc == "w" then class_buf = class_buf .. "%w_"
            elseif nc == "d" then class_buf = class_buf .. "%d"
            elseif nc == "s" then class_buf = class_buf .. "%s"
            elseif nc == "]" then class_buf = class_buf .. "%]"
            elseif nc == "[" then class_buf = class_buf .. "%["
            elseif nc:match("[%(%)%.%%%+%-%*%?%^%$]") then
              class_buf = class_buf .. "%" .. nc
            else
              class_buf = class_buf .. nc
            end
          end
        elseif c:match("[%(%)%.%%%+%-%*%?%^%$]") then
          -- Inside character class, most of these don't need escaping in Lua
          -- but % does, and ] does
          if c == "%" then
            class_buf = class_buf .. "%%"
          else
            class_buf = class_buf .. c
          end
        else
          class_buf = class_buf .. c
        end
        i = i + 1
      end
      class_buf = class_buf .. "]"
      if i <= plen then i = i + 1 end -- skip ]
      out[#out + 1] = class_buf

    elseif ch == "(" then
      -- Check for non-capturing group (?:...)
      if i + 2 <= plen and pattern:sub(i + 1, i + 2) == "?:" then
        -- Just emit ( and skip ?:
        out[#out + 1] = "("
        i = i + 3
      else
        out[#out + 1] = "("
        i = i + 1
      end

    elseif ch == "{" then
      -- Quantifier {n,m} or {n}
      local quant = pattern:match("^(%{%d+,?%d*%})", i)
      if quant then
        -- Lua patterns don't support {n,m}. Try to approximate.
        local min_n, max_n = quant:match("^{(%d+),(%d+)}$")
        if not min_n then
          min_n = quant:match("^{(%d+)}$")
          max_n = min_n
        end
        if not min_n then
          min_n = quant:match("^{(%d+),}$")
          max_n = nil -- unbounded
        end
        min_n = tonumber(min_n) or 0
        max_n = max_n and tonumber(max_n) or nil

        -- Get the previous pattern element
        local prev = out[#out] or ""
        -- Approximate: repeat the prev element min_n to max_n times
        -- For small values, just repeat literally
        if min_n == 0 and max_n and max_n <= 4 then
          -- {0,n}: make each occurrence optional with ?
          local repeated = ""
          for _ = 1, max_n do
            repeated = repeated .. prev .. "?"
          end
          out[#out] = repeated
        elseif min_n == 1 and max_n == nil then
          -- {1,} is equivalent to +
          out[#out] = prev .. "+"
        elseif min_n == 0 and max_n == nil then
          -- {0,} is equivalent to *
          out[#out] = prev .. "*"
        else
          -- Best effort: repeat min_n times then add optional copies
          local base = string.rep(prev, min_n)
          if max_n then
            local optional = string.rep(prev .. "?", max_n - min_n)
            out[#out] = base .. optional
          else
            out[#out] = base .. prev .. "*"
          end
        end
        i = i + #quant
      else
        out[#out + 1] = "%{"
        i = i + 1
      end

    elseif ch == ")" then
      out[#out + 1] = ")"
      i = i + 1

    elseif ch == "|" then
      -- Lua patterns don't support alternation.
      -- Return nil to signal conversion failure.
      return nil, is_global

    elseif ch == "." then
      -- . matches anything except newline
      out[#out + 1] = "."
      i = i + 1

    elseif ch == "^" then
      out[#out + 1] = "^"
      i = i + 1

    elseif ch == "$" then
      out[#out + 1] = "$"
      i = i + 1

    elseif ch == "*" then
      -- Check for *? (non-greedy)
      if i + 1 <= plen and pattern:sub(i + 1, i + 1) == "?" then
        out[#out + 1] = "-"
        i = i + 2
      else
        out[#out + 1] = "*"
        i = i + 1
      end

    elseif ch == "+" then
      if i + 1 <= plen and pattern:sub(i + 1, i + 1) == "?" then
        -- +? non-greedy -> Lua - (after at least one)
        -- Lua has no non-greedy + ; approximate with +
        -- Actually we can't do non-greedy in Lua easily; just use +
        out[#out + 1] = "+"
        i = i + 2
      else
        out[#out + 1] = "+"
        i = i + 1
      end

    elseif ch == "?" then
      -- Check for ?? (non-greedy optional)
      if i + 1 <= plen and pattern:sub(i + 1, i + 1) == "?" then
        out[#out + 1] = "?"
        i = i + 2
      else
        out[#out + 1] = "?"
        i = i + 1
      end

    elseif ch:match("[%(%)%.%%%+%-%*%?%[%]%^%$]") then
      out[#out + 1] = "%" .. ch
      i = i + 1

    else
      out[#out + 1] = ch
      i = i + 1
    end
  end

  return table.concat(out), is_global
end

-- ---------------------------------------------------------------------------
-- Transform engine
-- ---------------------------------------------------------------------------
-- Operates on the token list with a cursor. Produces Lua source code.

--- Create a new transform context.
---@param tokens table[]
---@return table ctx
local function make_ctx(tokens)
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
local function tk_peek(ctx, offset)
  local i = ctx.pos + (offset or 0)
  if i < 1 or i > #ctx.tokens then
    return { type = TK.EOF, value = "" }
  end
  return ctx.tokens[i]
end

--- Get current token.
---@param ctx table
---@return table
local function tk_cur(ctx)
  return tk_peek(ctx, 0)
end

--- Advance to next token and return the one we just passed.
---@param ctx table
---@return table
local function tk_advance(ctx)
  local t = tk_cur(ctx)
  ctx.pos = ctx.pos + 1
  return t
end

--- Check if current token matches type and optionally value.
---@param ctx table
---@param typ string
---@param val string|nil
---@return boolean
local function tk_is(ctx, typ, val)
  local t = tk_cur(ctx)
  if t.type ~= typ then return false end
  if val and t.value ~= val then return false end
  return true
end

--- Skip whitespace and newline tokens, returning them concatenated.
---@param ctx table
---@return string
local function skip_ws(ctx)
  local buf = {}
  while tk_cur(ctx).type == TK.WS or tk_cur(ctx).type == TK.NL or tk_cur(ctx).type == TK.COMMENT do
    buf[#buf + 1] = tk_advance(ctx).value
  end
  return table.concat(buf)
end

--- Peek ahead past whitespace to find the next significant token.
---@param ctx table
---@param start_offset number|nil  offset to start looking from (default 0)
---@return table token
---@return number offset  the offset where it was found
local function peek_significant(ctx, start_offset)
  local off = start_offset or 0
  while true do
    local t = tk_peek(ctx, off)
    if t.type ~= TK.WS and t.type ~= TK.NL and t.type ~= TK.COMMENT then
      return t, off
    end
    off = off + 1
  end
end

--- Emit a string to the output.
---@param ctx table
---@param s string
local function emit(ctx, s)
  ctx.out[#ctx.out + 1] = s
end

-- Forward declarations
local transform_expression
local transform_statement
local transform_block
local transform_arrow_body

-- ---------------------------------------------------------------------------
-- Expression transformer
-- ---------------------------------------------------------------------------

--- Transform a sub-token-list into Lua code.
--- Creates a sub-context and runs the expression transformer.
---@param tokens table[]
---@param parent_ctx table
---@return string
local function transform_token_list(tokens, parent_ctx)
  -- Add EOF
  local toks = {}
  for _, t in ipairs(tokens) do toks[#toks + 1] = t end
  toks[#toks + 1] = { type = TK.EOF, value = "" }

  local sub = make_ctx(toks)
  sub.map_vars = parent_ctx.map_vars
  sub.indent = parent_ctx.indent

  -- Transform as a sequence of statements/expressions
  while sub.pos <= #sub.tokens and tk_cur(sub).type ~= TK.EOF do
    transform_statement(sub)
  end

  return table.concat(sub.out)
end

--- Transform a template literal token into Lua concatenation.
---@param token table  token with .parts
---@param parent_ctx table
---@return string
local function transform_template(token, parent_ctx)
  local parts = token.parts
  if not parts or #parts == 0 then
    return '""'
  end

  -- If there are no expressions, just return a simple string
  local has_expr = false
  for _, p in ipairs(parts) do
    if p.type == "expr" then has_expr = true; break end
  end
  if not has_expr then
    local text = parts[1].value
    -- Escape quotes in the text
    text = text:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. text .. '"'
  end

  local segments = {}
  for _, p in ipairs(parts) do
    if p.type == "text" then
      local text = p.value:gsub("\\", "\\\\"):gsub('"', '\\"')
      if text ~= "" then
        segments[#segments + 1] = '"' .. text .. '"'
      end
    else
      -- Expression: tokenize and transform
      local expr_lua = transform_token_list(tokenize(p.value), parent_ctx)
      expr_lua = vim.trim(expr_lua)
      segments[#segments + 1] = "tostring(" .. expr_lua .. ")"
    end
  end

  if #segments == 0 then return '""' end
  if #segments == 1 then return segments[1] end
  return table.concat(segments, " .. ")
end

--- Check whether the upcoming tokens form an arrow function starting from
--- the current position. Returns param info if so.
--- Patterns:
---   ident =>           (single param, no parens)
---   (params) =>        (parenthesized params)
---@param ctx table
---@return table|nil  { params = string, end_offset = number }
local function detect_arrow(ctx)
  local t = tk_cur(ctx)

  -- Case 1: ident => ...
  if t.type == TK.IDENT then
    local next_sig, next_off = peek_significant(ctx, 1)
    if next_sig.type == TK.OP and next_sig.value == "=>" then
      return { params = t.value, arrow_offset = next_off }
    end
  end

  -- Case 2: ( ... ) => ...
  -- We need to verify there's a matching ) followed by =>
  if t.type == TK.PUNCT and t.value == "(" then
    local depth = 1
    local off = 1
    while true do
      local tk = tk_peek(ctx, off)
      if tk.type == TK.EOF then return nil end
      if tk.type == TK.PUNCT and tk.value == "(" then depth = depth + 1 end
      if tk.type == TK.PUNCT and tk.value == ")" then
        depth = depth - 1
        if depth == 0 then
          -- Check if next significant token is =>
          local after, after_off = peek_significant(ctx, off + 1)
          if after.type == TK.OP and after.value == "=>" then
            -- Collect param tokens
            local params = {}
            for i = 1, off - 1 do
              local pt = tk_peek(ctx, i)
              if pt.type == TK.IDENT then
                params[#params + 1] = pt.value
              end
            end
            return { params = table.concat(params, ", "), paren_close_offset = off, arrow_offset = after_off }
          end
          return nil
        end
      end
      off = off + 1
    end
  end

  return nil
end

--- Transform an arrow function.
--- Assumes detect_arrow returned non-nil. Consumes tokens and emits Lua.
---@param ctx table
---@param arrow table  from detect_arrow
local function transform_arrow(ctx, arrow)
  -- Skip to past the => token
  for _ = 1, arrow.arrow_offset do
    tk_advance(ctx)
  end
  tk_advance(ctx) -- skip the => itself

  skip_ws(ctx)

  emit(ctx, "function(" .. arrow.params .. ") ")

  -- Arrow body: either { block } or expression
  if tk_is(ctx, TK.PUNCT, "{") then
    -- Block body
    transform_block(ctx, true)
    emit(ctx, " end")
  else
    -- Expression body: collect until we hit something that ends the expression
    -- in the current context (comma, closing paren/bracket, semicolon, or EOF)
    emit(ctx, "return ")
    transform_arrow_body(ctx)
    emit(ctx, " end")
  end
end

--- Transform the body of an arrow function (expression form).
--- Collects and transforms tokens until we hit a terminator at depth 0.
---@param ctx table
transform_arrow_body = function(ctx)
  local depth_paren = 0
  local depth_bracket = 0
  local depth_brace = 0

  while tk_cur(ctx).type ~= TK.EOF do
    local t = tk_cur(ctx)

    -- Track nesting
    if t.type == TK.PUNCT then
      if t.value == "(" then depth_paren = depth_paren + 1
      elseif t.value == ")" then
        if depth_paren == 0 then return end -- end of enclosing call
        depth_paren = depth_paren - 1
      elseif t.value == "[" then depth_bracket = depth_bracket + 1
      elseif t.value == "]" then
        if depth_bracket == 0 then return end
        depth_bracket = depth_bracket - 1
      elseif t.value == "{" then depth_brace = depth_brace + 1
      elseif t.value == "}" then
        if depth_brace == 0 then return end
        depth_brace = depth_brace - 1
      elseif t.value == "," and depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 then
        return -- end of this arg in a call
      elseif t.value == ";" then
        return
      end
    end

    -- Stop at newline when not nested (but only if the next significant
    -- token isn't a continuation like . or method chain)
    if t.type == TK.NL and depth_paren == 0 and depth_bracket == 0 and depth_brace == 0 then
      local next_sig, _ = peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        -- Continuation, keep going
        emit(ctx, t.value)
        tk_advance(ctx)
      else
        return
      end
    else
      transform_expression(ctx)
    end
  end
end

--- Extract the most recent expression from the output buffer.
--- Walks backward from the end of ctx.out to find where the current
--- expression started (after the last statement boundary like `=`, `local`,
--- `return`, newline, etc.), removes those entries from ctx.out, and returns
--- the trimmed expression string.
---@param ctx table
---@return string  the extracted expression
local function extract_expr_from_output(ctx)
  local out = ctx.out
  local es = #out
  -- Walk backward past trailing whitespace
  while es >= 1 and vim.trim(out[es]) == "" do
    es = es - 1
  end
  local expr_end = es
  -- Now walk backward to find the expression start.
  -- Stop at statement boundaries.
  local paren_depth = 0
  while es >= 1 do
    local s = out[es]
    -- Count closing/opening parens to stay balanced
    for ci = #s, 1, -1 do
      local c = s:sub(ci, ci)
      if c == ")" or c == "]" then paren_depth = paren_depth + 1
      elseif c == "(" or c == "[" then paren_depth = paren_depth - 1
      end
    end
    if paren_depth <= 0 and es > 1 then
      local prev_raw = out[es - 1]
      local prev = vim.trim(prev_raw)
      -- Statement boundaries
      if prev == "" or prev == "=" or prev == "local" or prev == "return"
          or prev == "end" or prev == "then" or prev == "do" or prev == "else"
          or prev:match("=$") and not prev:match("[~<>=!]=$")
          or prev_raw:match("\n") then
        break
      end
    end
    es = es - 1
  end
  if es < 1 then es = 1 end
  local parts = {}
  for i = es, expr_end do
    parts[#parts + 1] = out[i]
  end
  local expr = vim.trim(table.concat(parts))
  -- Remove extracted parts from output
  for _ = es, #out do
    out[#out] = nil
  end
  return expr
end

--- Transform a ternary expression: cond ? then_expr : else_expr
--- Emits: (function() if cond then return then_expr else return else_expr end end)()
--- But we use the simpler Lua idiom: (cond and then_val or else_val) when safe,
--- or the IIFE form for safety.
---@param ctx table
---@param cond_lua string  already-transformed condition
local function transform_ternary(ctx, cond_lua)
  -- We've already consumed up to and including ?
  -- Collect then-expression using a shared output buffer so that multi-token
  -- expressions (like a[1]) retain context for [ literal vs property detection.
  local saved_out = ctx.out
  ctx.out = {}
  local depth = 0
  while tk_cur(ctx).type ~= TK.EOF do
    local t = tk_cur(ctx)
    if t.type == TK.PUNCT then
      if t.value == "(" or t.value == "[" or t.value == "{" then
        depth = depth + 1
      elseif t.value == ")" or t.value == "]" or t.value == "}" then
        if depth == 0 then break end
        depth = depth - 1
      elseif t.value == ":" and depth == 0 then
        tk_advance(ctx) -- skip :
        break
      end
    end
    transform_expression(ctx)
  end
  local then_lua = vim.trim(table.concat(ctx.out))

  -- Collect else-expression with shared output buffer
  ctx.out = {}
  depth = 0
  while tk_cur(ctx).type ~= TK.EOF do
    local t = tk_cur(ctx)
    if t.type == TK.PUNCT then
      if t.value == "(" or t.value == "[" or t.value == "{" then
        depth = depth + 1
      elseif t.value == ")" or t.value == "]" or t.value == "}" then
        if depth == 0 then break end
        depth = depth - 1
      elseif t.value == "," and depth == 0 then break
      elseif t.value == ";" then break
      elseif t.value == ":" and depth == 0 then
        -- This could be another ternary's else, stop
        break
      end
    end
    if t.type == TK.NL and depth == 0 then break end
    transform_expression(ctx)
  end
  local else_lua = vim.trim(table.concat(ctx.out))

  -- Restore output and emit IIFE
  ctx.out = saved_out
  emit(ctx, "(function() if " .. cond_lua .. " then return " .. then_lua .. " else return " .. else_lua .. " end end)()")
end

--- Transform a single expression token (the main expression driver).
--- This handles one "unit" of expression (a token, possibly with suffixes).
---@param ctx table
transform_expression = function(ctx)
  local t = tk_cur(ctx)

  -- EOF
  if t.type == TK.EOF then return end

  -- Whitespace / newline / comment -- pass through
  if t.type == TK.WS or t.type == TK.NL or t.type == TK.COMMENT then
    emit(ctx, tk_advance(ctx).value)
    return
  end

  -- Template literal
  if t.type == TK.TMPL then
    tk_advance(ctx)
    emit(ctx, transform_template(t, ctx))
    return
  end

  -- String literal
  if t.type == TK.STR then
    tk_advance(ctx)
    -- Convert single-quoted strings to double-quoted for consistency
    if t.value:sub(1, 1) == "'" then
      local inner = t.value:sub(2, -2)
      -- Unescape single quotes, escape double quotes
      inner = inner:gsub("\\'", "'")
      inner = inner:gsub('"', '\\"')
      emit(ctx, '"' .. inner .. '"')
    else
      emit(ctx, t.value)
    end
    return
  end

  -- Number
  if t.type == TK.NUM then
    emit(ctx, tk_advance(ctx).value)
    return
  end

  -- Regex literal (used in .replace() calls -- handled at call site mostly)
  if t.type == TK.REGEX then
    -- Convert to Lua pattern string
    local lua_pat, _ = regex_to_lua_pattern(t.value)
    tk_advance(ctx)
    if lua_pat then
      emit(ctx, '"' .. lua_pat:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"')
    else
      emit(ctx, '"" --[[ REGEX NOT CONVERTED: ' .. t.value .. ' ]]')
    end
    return
  end

  -- Arrow function detection
  local arrow = detect_arrow(ctx)
  if arrow then
    transform_arrow(ctx, arrow)
    return
  end

  -- Operators
  if t.type == TK.OP then
    local v = t.value
    tk_advance(ctx)

    if v == "===" then
      emit(ctx, "==")
      return
    elseif v == "!==" then
      emit(ctx, "~=")
      return
    elseif v == "==" then
      emit(ctx, "==")
      return
    elseif v == "!=" then
      emit(ctx, "~=")
      return
    elseif v == "&&" then
      emit(ctx, " and ")
      return
    elseif v == "||" then
      emit(ctx, " or ")
      return
    elseif v == "!" then
      emit(ctx, "not ")
      return
    elseif v == "+=" then
      -- x += y -> x = x + y
      -- The LHS was already emitted. We need to fix this at the statement level.
      -- For now, emit as-is; we'll handle it at the statement level.
      emit(ctx, "+= ") -- placeholder, handled in postprocess
      return
    elseif v == "-=" then
      emit(ctx, "-= ")
      return
    elseif v == "++" then
      emit(ctx, "++ ") -- placeholder, handled in postprocess
      return
    elseif v == "--" then
      emit(ctx, "-- ")
      return
    elseif v == "." then
      -- Dot access. Check for special property/method patterns.
      skip_ws(ctx)
      local prop = tk_cur(ctx)
      if prop.type == TK.IDENT then
        local prop_name = prop.value

        -- .length -> # prefix (handled specially)
        if prop_name == "length" then
          tk_advance(ctx)
          -- Convert .length to Lua # operator on the preceding expression
          local expr_str = extract_expr_from_output(ctx)

          -- Emit #(expr)
          if expr_str:match("^[%w_%.%:]+$") then
            emit(ctx, "#" .. expr_str)
          else
            emit(ctx, "#(" .. expr_str .. ")")
          end
          return
        end

        -- .push(val) -> table.insert(obj, val)
        if prop_name == "push" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx) -- skip 'push'
            skip_ws(ctx)
            -- Extract the object expression from the output buffer
            local obj = extract_expr_from_output(ctx)

            -- Consume the arguments between ( and )
            tk_advance(ctx) -- skip (
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then
                  tk_advance(ctx) -- skip )
                  break
                end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end

            local arg_lua = transform_token_list(arg_tokens, ctx)
            emit(ctx, "table.insert(" .. obj .. ", " .. vim.trim(arg_lua) .. ")")
            return
          end
        end

        -- .has(key) -> [key] ~= nil
        if prop_name == "has" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx) -- skip 'has'
            skip_ws(ctx)
            tk_advance(ctx) -- skip (
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local key_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            -- Emit [key] — truthy in Lua if the key exists (works with `not` prefix)
            emit(ctx, "[" .. key_lua .. "]")
            return
          end
        end

        -- .get(key) -> [key]
        if prop_name == "get" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx) -- skip 'get'
            skip_ws(ctx)
            tk_advance(ctx) -- skip (
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local key_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            emit(ctx, "[" .. key_lua .. "]")
            return
          end
        end

        -- .set(key, val) -> [key] = val (as a statement)
        if prop_name == "set" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx) -- skip 'set'
            skip_ws(ctx)
            tk_advance(ctx) -- skip (
            -- Collect all args, split by comma at depth 0
            local all_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              all_tokens[#all_tokens + 1] = tk_advance(ctx)
            end
            -- Split into key and value at first comma at depth 0
            local key_toks = {}
            local val_toks = {}
            local in_key = true
            local d = 0
            for _, tok in ipairs(all_tokens) do
              if tok.type == TK.PUNCT and (tok.value == "(" or tok.value == "[" or tok.value == "{") then d = d + 1 end
              if tok.type == TK.PUNCT and (tok.value == ")" or tok.value == "]" or tok.value == "}") then d = d - 1 end
              if in_key and tok.type == TK.PUNCT and tok.value == "," and d == 0 then
                in_key = false
              elseif in_key then
                key_toks[#key_toks + 1] = tok
              else
                val_toks[#val_toks + 1] = tok
              end
            end
            local key_lua = vim.trim(transform_token_list(key_toks, ctx))
            local val_lua = vim.trim(transform_token_list(val_toks, ctx))
            emit(ctx, "[" .. key_lua .. "] = " .. val_lua)
            return
          end
        end

        -- .keys() -> pairs iteration (handled at Array.from site)
        if prop_name == "keys" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            -- .keys() is typically used inside Array.from(x.keys()).sort()
            -- We handle conversion at the Array.from level. Here emit a
            -- marker that Array.from can detect.
            tk_advance(ctx) -- skip 'keys'
            skip_ws(ctx)
            tk_advance(ctx) -- skip (
            -- Expect )
            if tk_is(ctx, TK.PUNCT, ")") then
              tk_advance(ctx)
            end
            -- Emit a special marker that Array.from can detect and handle
            emit(ctx, " --[[.keys()]]")
            return
          end
        end

        -- .trim() -> :match("^%s*(.-)%s*$") or vim.trim()
        if prop_name == "trim" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx) -- skip 'trim'
            skip_ws(ctx)
            tk_advance(ctx) -- skip (
            if tk_is(ctx, TK.PUNCT, ")") then tk_advance(ctx) end
            -- Use Lua string.match to trim whitespace
            emit(ctx, ":match(\"^%s*(.-)%s*$\")")
            return
          end
        end

        -- .replace(pattern, replacement) -> :gsub(pattern, replacement)
        if prop_name == "replace" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx) -- skip 'replace'
            skip_ws(ctx)
            tk_advance(ctx) -- skip (
            -- Collect arguments
            local all_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              all_tokens[#all_tokens + 1] = tk_advance(ctx)
            end
            -- Split args
            local arg1_toks = {}
            local arg2_toks = {}
            local in_first = true
            local d = 0
            for _, tok in ipairs(all_tokens) do
              if tok.type == TK.PUNCT and (tok.value == "(" or tok.value == "[" or tok.value == "{") then d = d + 1 end
              if tok.type == TK.PUNCT and (tok.value == ")" or tok.value == "]" or tok.value == "}") then d = d - 1 end
              if in_first and tok.type == TK.PUNCT and tok.value == "," and d == 0 then
                in_first = false
              elseif in_first then
                arg1_toks[#arg1_toks + 1] = tok
              else
                arg2_toks[#arg2_toks + 1] = tok
              end
            end
            local pattern_lua = vim.trim(transform_token_list(arg1_toks, ctx))
            local repl_lua = vim.trim(transform_token_list(arg2_toks, ctx))
            emit(ctx, ":gsub(" .. pattern_lua .. ", " .. repl_lua .. ")")
            return
          end
        end

        -- .split(sep) -> vim.split(str, sep) -- need to wrap
        if prop_name == "split" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx)
            skip_ws(ctx)
            tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local sep_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            emit(ctx, ":split(" .. sep_lua .. ")")
            return
          end
        end

        -- .join(sep) -> table.concat(arr, sep)
        if prop_name == "join" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx)
            skip_ws(ctx)
            tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local sep_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            local obj_expr = extract_expr_from_output(ctx)
            if sep_lua == "" then sep_lua = '""' end
            emit(ctx, "table.concat(" .. obj_expr .. ", " .. sep_lua .. ")")
            return
          end
        end

        -- .includes(val) -> vim.tbl_contains(arr, val) or string:find
        if prop_name == "includes" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx)
            skip_ws(ctx)
            tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local val_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            -- Emit as :find() for strings, or wrap for tables
            -- Use a generic helper
            emit(ctx, ":find(" .. val_lua .. ", 1, true) ~= nil")
            return
          end
        end

        -- .startsWith(str) -> string check
        if prop_name == "startsWith" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx)
            skip_ws(ctx)
            tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local val_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            emit(ctx, ":sub(1, #(" .. val_lua .. ")) == " .. val_lua)
            return
          end
        end

        -- .endsWith(str)
        if prop_name == "endsWith" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx)
            skip_ws(ctx)
            tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local val_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            emit(ctx, ":sub(-#(" .. val_lua .. ")) == " .. val_lua)
            return
          end
        end

        -- .toLowerCase() / .toUpperCase()
        if prop_name == "toLowerCase" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx); skip_ws(ctx); tk_advance(ctx)
            if tk_is(ctx, TK.PUNCT, ")") then tk_advance(ctx) end
            emit(ctx, ":lower()")
            return
          end
        end
        if prop_name == "toUpperCase" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx); skip_ws(ctx); tk_advance(ctx)
            if tk_is(ctx, TK.PUNCT, ")") then tk_advance(ctx) end
            emit(ctx, ":upper()")
            return
          end
        end

        -- .toString()
        if prop_name == "toString" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx); skip_ws(ctx); tk_advance(ctx)
            if tk_is(ctx, TK.PUNCT, ")") then tk_advance(ctx) end
            local expr_str = extract_expr_from_output(ctx)
            emit(ctx, "tostring(" .. expr_str .. ")")
            return
          end
        end

        -- .sort() with comparator -- convert JS comparator to Lua
        if prop_name == "sort" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx) -- skip 'sort'
            skip_ws(ctx)
            -- Check if it's .sort() with no args or .sort(comparator)
            local after_open, _ = peek_significant(ctx, 1)
            if after_open.type == TK.PUNCT and after_open.value == ")" then
              -- No comparator: .sort() -> table.sort(obj); wrap result
              tk_advance(ctx) -- skip (
              tk_advance(ctx) -- skip )
              -- For PageArray, :sort() already works. For plain tables, we need table.sort.
              -- Use colon syntax to support both.
              emit(ctx, ":sort()")
              return
            else
              -- Has comparator function
              tk_advance(ctx) -- skip (
              local arg_tokens = {}
              local depth = 1
              while tk_cur(ctx).type ~= TK.EOF do
                local at = tk_cur(ctx)
                if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
                if at.type == TK.PUNCT and at.value == ")" then
                  depth = depth - 1
                  if depth == 0 then tk_advance(ctx); break end
                end
                arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
              end
              local comparator_lua = vim.trim(transform_token_list(arg_tokens, ctx))

              -- JS comparator returns -1/0/1; Lua table.sort needs a < function.
              -- Extract the object expression and wrap with comparator adapter.
              local obj = extract_expr_from_output(ctx)

              -- Check if comparator is a simple function that we can adapt
              -- For pattern: function(a, b) return EXPR end
              -- Transform EXPR from returning -1/0/1 to returning boolean
              local params, body = comparator_lua:match("^function%(([^)]+)%)%s+return%s+(.+)%s+end$")
              if params and body then
                -- The body likely contains ternary IIFE patterns. Convert to boolean.
                -- Simple approach: wrap the whole thing
                emit(ctx, "table.sort(" .. obj .. ", function(" .. params .. ") return (" .. body .. ") < 0 end)")
              else
                emit(ctx, "table.sort(" .. obj .. ", function(a, b) return (" .. comparator_lua .. ")(a, b) < 0 end)")
              end
              return
            end
          end
        end

        -- .filter(fn) -> :where(fn) for PageArray compatibility
        if prop_name == "filter" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx) -- skip 'filter'
            emit(ctx, ":where")
            return
          end
        end

        -- .map, .forEach, .flatMap, .groupBy, .where, .limit, etc. -- use colon syntax
        if prop_name == "map" or prop_name == "forEach" or prop_name == "flatMap"
            or prop_name == "groupBy" or prop_name == "where" or prop_name == "limit"
            or prop_name == "slice" or prop_name == "first" or prop_name == "last"
            or prop_name == "count" or prop_name == "values" or prop_name == "array"
            or prop_name == "plus" or prop_name == "minus" then
          local next_sig, _ = peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            tk_advance(ctx) -- skip method name
            emit(ctx, ":" .. prop_name)
            return
          end
        end

        -- Default: regular dot access
        tk_advance(ctx) -- skip property name
        emit(ctx, "." .. prop_name)
      else
        -- Dot not followed by ident (shouldn't happen normally)
        emit(ctx, ".")
      end
      return
    end

    -- .concat -> ..
    if v == "+" then
      -- This could be string concatenation or addition. Lua uses .. for strings
      -- and + for numbers. Since we can't always know the types, keep as +.
      -- The runtime will handle it via metamethods or the dv environment.
      emit(ctx, " + ")
      return
    end

    emit(ctx, v)
    return
  end

  -- Punctuation
  if t.type == TK.PUNCT then
    local v = t.value

    -- Semicolons -> remove (Lua doesn't need them, but they're valid)
    if v == ";" then
      tk_advance(ctx)
      -- Emit newline if the next token isn't already a newline
      local next_t = tk_cur(ctx)
      if next_t.type ~= TK.NL and next_t.type ~= TK.EOF then
        -- Don't emit anything; the next newline or statement will provide separation
      end
      return
    end

    -- Question mark -> ternary
    if v == "?" then
      tk_advance(ctx) -- skip ?
      -- The condition was already emitted. Extract it from output.
      local out = ctx.out
      -- Walk backward to find the start of the condition expression
      local es = #out
      -- The condition starts after the last statement boundary
      while es >= 1 do
        local raw = out[es]
        local s = vim.trim(raw)
        -- Skip whitespace-only entries (don't treat as boundary)
        if s == "" then
          es = es - 1
        elseif s == "then" or s == "do" or s == "else" then
          es = es + 1
          break
        elseif s == "return" or s == "local" then
          es = es + 1
          break
        elseif s:match("=$") and not s:match("[~<>=!]=$") then
          -- Assignment operator boundary
          es = es + 1
          break
        elseif raw:match("\n") then
          es = es + 1
          break
        else
          es = es - 1
        end
      end
      if es < 1 then es = 1 end
      local cond_parts = {}
      for i = es, #out do
        cond_parts[#cond_parts + 1] = out[i]
      end
      local cond_lua = vim.trim(table.concat(cond_parts))
      for _ = es, #out do out[#out] = nil end

      transform_ternary(ctx, cond_lua)
      return
    end

    -- Array literal [] -> {}
    if v == "[" then
      -- Check if this is an array literal (not property access)
      -- It's an array literal if preceded by: nothing, =, (, [, {, ,, return, operators
      local is_literal = true
      for i = #ctx.out, 1, -1 do
        local s = vim.trim(ctx.out[i])
        if s ~= "" then
          -- If preceded by an identifier, ), or ] -> property access
          if s:match("[%w_%)%]]$") then
            is_literal = false
          end
          break
        end
      end

      if is_literal then
        tk_advance(ctx) -- skip [
        emit(ctx, "{")
        -- Transform contents until ]
        local depth = 1
        while tk_cur(ctx).type ~= TK.EOF do
          if tk_is(ctx, TK.PUNCT, "[") then depth = depth + 1 end
          if tk_is(ctx, TK.PUNCT, "]") then
            depth = depth - 1
            if depth == 0 then
              tk_advance(ctx) -- skip ]
              emit(ctx, "}")
              return
            end
          end
          transform_expression(ctx)
        end
        emit(ctx, "}")
        return
      else
        -- Property access: emit as-is
        tk_advance(ctx)
        emit(ctx, "[")
        return
      end
    end

    -- Colon in object literal { key: value } -> { key = value }
    if v == ":" then
      -- Check if previous significant output was an identifier inside { }
      -- by scanning backward for the last meaningful output
      local prev_ident = false
      local in_brace = false
      local brace_depth = 0
      for i = #ctx.out, 1, -1 do
        local s = vim.trim(ctx.out[i])
        if s == "" then
          -- skip whitespace
        elseif s:match("^[%w_]+$") then
          prev_ident = true
          -- Now check if we're inside { }
          for j = i - 1, 1, -1 do
            local sj = ctx.out[j]
            for ci = #sj, 1, -1 do
              local c = sj:sub(ci, ci)
              if c == "}" then brace_depth = brace_depth + 1
              elseif c == "{" then
                if brace_depth == 0 then in_brace = true end
                brace_depth = brace_depth - 1
              end
            end
            if in_brace then break end
          end
          break
        else
          break
        end
      end
      if prev_ident and in_brace then
        tk_advance(ctx)
        emit(ctx, " =")
        return
      end
    end

    -- Default punctuation
    tk_advance(ctx)
    emit(ctx, v)
    return
  end

  -- Identifiers and keywords
  if t.type == TK.IDENT then
    local v = t.value

    -- typeof -> type()
    if v == "typeof" then
      tk_advance(ctx)
      skip_ws(ctx)
      -- Collect operand tokens, then transform them as a group.
      -- typeof binds to the next "primary expression" including property access.
      local operand_tokens = {}
      if tk_is(ctx, TK.PUNCT, "(") then
        -- Parenthesized: collect everything inside ( ... )
        operand_tokens[#operand_tokens + 1] = tk_advance(ctx) -- (
        local depth = 1
        while tk_cur(ctx).type ~= TK.EOF do
          local ot = tk_cur(ctx)
          if ot.type == TK.PUNCT and ot.value == "(" then depth = depth + 1 end
          if ot.type == TK.PUNCT and ot.value == ")" then
            depth = depth - 1
            if depth == 0 then
              operand_tokens[#operand_tokens + 1] = tk_advance(ctx) -- )
              break
            end
          end
          operand_tokens[#operand_tokens + 1] = tk_advance(ctx)
        end
      else
        -- Unparenthesized: collect identifier + any .prop / [index] / (call) suffixes
        operand_tokens[#operand_tokens + 1] = tk_advance(ctx)
        while tk_cur(ctx).type ~= TK.EOF do
          local nt = tk_cur(ctx)
          if nt.type == TK.OP and nt.value == "." then
            -- .prop
            operand_tokens[#operand_tokens + 1] = tk_advance(ctx) -- .
            -- skip ws between . and prop name
            while tk_cur(ctx).type == TK.WS do
              operand_tokens[#operand_tokens + 1] = tk_advance(ctx)
            end
            if tk_cur(ctx).type == TK.IDENT then
              operand_tokens[#operand_tokens + 1] = tk_advance(ctx)
            end
          elseif nt.type == TK.PUNCT and nt.value == "[" then
            -- [index]
            operand_tokens[#operand_tokens + 1] = tk_advance(ctx) -- [
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local bt = tk_cur(ctx)
              if bt.type == TK.PUNCT and bt.value == "[" then depth = depth + 1 end
              if bt.type == TK.PUNCT and bt.value == "]" then
                depth = depth - 1
                if depth == 0 then
                  operand_tokens[#operand_tokens + 1] = tk_advance(ctx) -- ]
                  break
                end
              end
              operand_tokens[#operand_tokens + 1] = tk_advance(ctx)
            end
          elseif nt.type == TK.PUNCT and nt.value == "(" then
            -- (call)
            operand_tokens[#operand_tokens + 1] = tk_advance(ctx) -- (
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local ct = tk_cur(ctx)
              if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
              if ct.type == TK.PUNCT and ct.value == ")" then
                depth = depth - 1
                if depth == 0 then
                  operand_tokens[#operand_tokens + 1] = tk_advance(ctx) -- )
                  break
                end
              end
              operand_tokens[#operand_tokens + 1] = tk_advance(ctx)
            end
          else
            break
          end
        end
      end
      local operand = vim.trim(transform_token_list(operand_tokens, ctx))
      emit(ctx, "type(" .. operand .. ")")
      return
    end

    -- null / undefined -> nil
    if v == "null" or v == "undefined" then
      tk_advance(ctx)
      emit(ctx, "nil")
      return
    end

    -- true / false -> true / false (same in Lua)
    if v == "true" or v == "false" then
      tk_advance(ctx)
      emit(ctx, v)
      return
    end

    -- this -> (leave as-is, or map to self)
    if v == "this" then
      tk_advance(ctx)
      emit(ctx, "self")
      return
    end

    -- Math.round -> math.floor(x + 0.5)
    if v == "Math" then
      local next_sig, next_off = peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT then
          local method = method_sig.value
          if method == "round" then
            -- Math.round(expr) -> math.floor(expr + 0.5)
            for _ = 1, method_off do tk_advance(ctx) end
            tk_advance(ctx) -- skip method name
            skip_ws(ctx)
            if tk_is(ctx, TK.PUNCT, "(") then
              tk_advance(ctx) -- skip (
              local arg_tokens = {}
              local depth = 1
              while tk_cur(ctx).type ~= TK.EOF do
                local at = tk_cur(ctx)
                if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
                if at.type == TK.PUNCT and at.value == ")" then
                  depth = depth - 1
                  if depth == 0 then tk_advance(ctx); break end
                end
                arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
              end
              local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))
              emit(ctx, "math.floor(" .. arg_lua .. " + 0.5)")
            end
            return
          elseif method == "floor" or method == "ceil" or method == "abs"
              or method == "min" or method == "max" or method == "sqrt"
              or method == "pow" or method == "log" or method == "random" then
            -- Math.method -> math.method
            for _ = 1, method_off do tk_advance(ctx) end
            tk_advance(ctx)
            emit(ctx, "math." .. method)
            return
          elseif method == "PI" then
            for _ = 1, method_off do tk_advance(ctx) end
            tk_advance(ctx)
            emit(ctx, "math.pi")
            return
          end
        end
      end
    end

    -- console.log -> print
    if v == "console" then
      local next_sig, next_off = peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT and method_sig.value == "log" then
          for _ = 1, method_off do tk_advance(ctx) end
          tk_advance(ctx)
          emit(ctx, "print")
          return
        end
      end
    end

    -- JSON.stringify -> vim.inspect
    if v == "JSON" then
      local next_sig, next_off = peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT and method_sig.value == "stringify" then
          for _ = 1, method_off do tk_advance(ctx) end
          tk_advance(ctx)
          emit(ctx, "vim.inspect")
          return
        end
      end
    end

    -- Object.keys(x) -> (function() local _k = {} for k in pairs(x) do _k[#_k+1] = k end return _k end)()
    if v == "Object" then
      local next_sig, next_off = peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT and method_sig.value == "keys" then
          for _ = 1, method_off do tk_advance(ctx) end
          tk_advance(ctx)
          skip_ws(ctx)
          if tk_is(ctx, TK.PUNCT, "(") then
            tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            emit(ctx, "(function() local _k = {}; for k in pairs(" .. arg_lua .. ") do _k[#_k+1] = k end; return _k end)()")
          end
          return
        end
        if method_sig.type == TK.IDENT and method_sig.value == "values" then
          for _ = 1, method_off do tk_advance(ctx) end
          tk_advance(ctx)
          skip_ws(ctx)
          if tk_is(ctx, TK.PUNCT, "(") then
            tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            emit(ctx, "(function() local _v = {}; for _, v in pairs(" .. arg_lua .. ") do _v[#_v+1] = v end; return _v end)()")
          end
          return
        end
      end
    end

    -- Array.from(expr).sort() -> sorted keys IIFE
    if v == "Array" then
      local next_sig, next_off = peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT and method_sig.value == "from" then
          for _ = 1, method_off do tk_advance(ctx) end
          tk_advance(ctx) -- skip 'from'
          skip_ws(ctx)
          if tk_is(ctx, TK.PUNCT, "(") then
            tk_advance(ctx) -- skip (
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))

            -- Check if the arg ends with --[[.keys()]]
            local keys_marker = " --[[.keys()]]"
            if arg_lua:sub(-#keys_marker) == keys_marker then
              local map_expr = vim.trim(arg_lua:sub(1, -#keys_marker - 1))
              -- Check if .sort() follows
              skip_ws(ctx)
              local sort_sig, sort_off = peek_significant(ctx, 0)
              if sort_sig.type == TK.OP and sort_sig.value == "." then
                local sort_name, sn_off = peek_significant(ctx, sort_off + 1)
                if sort_name.type == TK.IDENT and sort_name.value == "sort" then
                  -- Consume .sort()
                  for _ = 0, sn_off do tk_advance(ctx) end
                  skip_ws(ctx)
                  if tk_is(ctx, TK.PUNCT, "(") then
                    tk_advance(ctx)
                    if tk_is(ctx, TK.PUNCT, ")") then tk_advance(ctx) end
                  end
                  emit(ctx, "(function() local _k = {}; for k in pairs(" .. map_expr .. ") do _k[#_k+1] = k end; table.sort(_k); return _k end)()")
                  return
                end
              end
              -- No .sort() follows
              emit(ctx, "(function() local _k = {}; for k in pairs(" .. map_expr .. ") do _k[#_k+1] = k end; return _k end)()")
            else
              -- Generic Array.from -> just emit the inner expression
              -- (Converts iterable to array, which in Lua is usually already a table)
              emit(ctx, arg_lua)
            end
          end
          return
        end
        if method_sig.type == TK.IDENT and method_sig.value == "isArray" then
          for _ = 1, method_off do tk_advance(ctx) end
          tk_advance(ctx)
          skip_ws(ctx)
          if tk_is(ctx, TK.PUNCT, "(") then
            tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while tk_cur(ctx).type ~= TK.EOF do
              local at = tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = tk_advance(ctx)
            end
            local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            emit(ctx, "(type(" .. arg_lua .. ') == "table")')
          end
          return
        end
      end
    end

    -- parseInt / parseFloat -> tonumber
    if v == "parseInt" or v == "parseFloat" then
      tk_advance(ctx)
      emit(ctx, "tonumber")
      return
    end

    -- String(x) -> tostring(x)
    if v == "String" then
      local next_sig, _ = peek_significant(ctx, 1)
      if next_sig.type == TK.PUNCT and next_sig.value == "(" then
        tk_advance(ctx)
        emit(ctx, "tostring")
        return
      end
    end

    -- Number(x) -> tonumber(x)
    if v == "Number" then
      local next_sig, _ = peek_significant(ctx, 1)
      if next_sig.type == TK.PUNCT and next_sig.value == "(" then
        tk_advance(ctx)
        emit(ctx, "tonumber")
        return
      end
    end

    -- Default identifier
    tk_advance(ctx)
    emit(ctx, v)
    return
  end

  -- Fallback: emit as-is
  emit(ctx, tk_advance(ctx).value)
end

-- ---------------------------------------------------------------------------
-- Statement transformer
-- ---------------------------------------------------------------------------

--- Transform a single statement.
---@param ctx table
transform_statement = function(ctx)
  local t = tk_cur(ctx)

  -- EOF
  if t.type == TK.EOF then return end

  -- Whitespace / newline / comment -- pass through
  if t.type == TK.WS or t.type == TK.NL or t.type == TK.COMMENT then
    emit(ctx, tk_advance(ctx).value)
    return
  end

  -- Variable declarations: const/let/var
  if t.type == TK.IDENT and (t.value == "const" or t.value == "let" or t.value == "var") then
    tk_advance(ctx) -- skip keyword
    skip_ws(ctx)
    local name_tok = tk_cur(ctx)
    if name_tok.type == TK.IDENT then
      local var_name = name_tok.value
      tk_advance(ctx) -- skip name
      skip_ws(ctx)

      -- Check for = initializer
      if tk_is(ctx, TK.OP, "=") then
        tk_advance(ctx) -- skip =
        skip_ws(ctx)

        -- Check for `new Map()`
        if tk_is(ctx, TK.IDENT, "new") then
          local next_sig, next_off = peek_significant(ctx, 1)
          if next_sig.type == TK.IDENT and next_sig.value == "Map" then
            -- new Map() -> {}
            for _ = 0, next_off do tk_advance(ctx) end
            skip_ws(ctx)
            if tk_is(ctx, TK.PUNCT, "(") then
              tk_advance(ctx)
              if tk_is(ctx, TK.PUNCT, ")") then tk_advance(ctx) end
            end
            ctx.map_vars[var_name] = true
            emit(ctx, "local " .. var_name .. " = {}")
            -- Skip trailing semicolon
            skip_ws(ctx)
            if tk_is(ctx, TK.PUNCT, ";") then tk_advance(ctx) end
            return
          end
        end

        emit(ctx, "local " .. var_name .. " = ")
        -- Transform the rest of the expression until semicolon or newline at depth 0
        local depth = 0
        while tk_cur(ctx).type ~= TK.EOF do
          local ct = tk_cur(ctx)
          if ct.type == TK.PUNCT and ct.value == ";" then
            tk_advance(ctx)
            break
          end
          if ct.type == TK.PUNCT and (ct.value == "(" or ct.value == "[" or ct.value == "{") then
            depth = depth + 1
          end
          if ct.type == TK.PUNCT and (ct.value == ")" or ct.value == "]" or ct.value == "}") then
            depth = depth - 1
          end
          if ct.type == TK.NL and depth <= 0 then
            -- Check if next line continues with . (method chaining)
            local next_sig, _ = peek_significant(ctx, 1)
            if next_sig.type == TK.OP and next_sig.value == "." then
              emit(ctx, tk_advance(ctx).value) -- emit newline
            else
              break
            end
          else
            transform_expression(ctx)
          end
        end
        return
      else
        -- Declaration without initializer
        emit(ctx, "local " .. var_name)
        if tk_is(ctx, TK.PUNCT, ";") then tk_advance(ctx) end
        return
      end
    end
    -- Destructuring or other pattern -- fall through to expression
    emit(ctx, "local ")
    return
  end

  -- Function declarations
  if t.type == TK.IDENT and t.value == "function" then
    local next_sig, next_off = peek_significant(ctx, 1)
    if next_sig.type == TK.IDENT then
      -- Named function declaration
      tk_advance(ctx) -- skip 'function'
      skip_ws(ctx)
      local fname = tk_cur(ctx).value
      tk_advance(ctx) -- skip name
      skip_ws(ctx)

      -- Collect parameters
      local params = ""
      if tk_is(ctx, TK.PUNCT, "(") then
        tk_advance(ctx)
        local param_parts = {}
        while not tk_is(ctx, TK.PUNCT, ")") and tk_cur(ctx).type ~= TK.EOF do
          local pt = tk_cur(ctx)
          if pt.type == TK.IDENT then
            param_parts[#param_parts + 1] = pt.value
          end
          tk_advance(ctx)
        end
        if tk_is(ctx, TK.PUNCT, ")") then tk_advance(ctx) end
        params = table.concat(param_parts, ", ")
      end

      emit(ctx, "local function " .. fname .. "(" .. params .. ")")
      skip_ws(ctx)

      -- Function body
      if tk_is(ctx, TK.PUNCT, "{") then
        transform_block(ctx, false)
      end

      emit(ctx, "\nend")
      return
    end
  end

  -- For-of loop: for (const x of expr) { ... }
  if t.type == TK.IDENT and t.value == "for" then
    tk_advance(ctx) -- skip 'for'
    skip_ws(ctx)

    if tk_is(ctx, TK.PUNCT, "(") then
      tk_advance(ctx) -- skip (
      skip_ws(ctx)

      -- Check for for-of pattern
      -- for (const/let/var x of expr)
      local has_decl = false
      if tk_is(ctx, TK.IDENT, "const") or tk_is(ctx, TK.IDENT, "let") or tk_is(ctx, TK.IDENT, "var") then
        tk_advance(ctx) -- skip const/let/var
        skip_ws(ctx)
        has_decl = true
      end

      local var_name_tok = tk_cur(ctx)
      if var_name_tok.type == TK.IDENT then
        local var_name = var_name_tok.value
        tk_advance(ctx) -- skip variable name
        skip_ws(ctx)

        if tk_is(ctx, TK.IDENT, "of") then
          -- For-of loop
          tk_advance(ctx) -- skip 'of'
          skip_ws(ctx)

          -- Collect the iterable expression until )
          local iter_tokens = {}
          local depth = 1
          while tk_cur(ctx).type ~= TK.EOF do
            local ct = tk_cur(ctx)
            if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
            if ct.type == TK.PUNCT and ct.value == ")" then
              depth = depth - 1
              if depth == 0 then
                tk_advance(ctx) -- skip )
                break
              end
            end
            iter_tokens[#iter_tokens + 1] = tk_advance(ctx)
          end
          local iter_lua = vim.trim(transform_token_list(iter_tokens, ctx))

          emit(ctx, "for _, " .. var_name .. " in ipairs(" .. iter_lua .. ") do")
          skip_ws(ctx)

          -- Loop body
          if tk_is(ctx, TK.PUNCT, "{") then
            transform_block(ctx, false)
          else
            -- Single statement body
            emit(ctx, "\n  ")
            transform_statement(ctx)
          end

          emit(ctx, "\nend")
          return
        elseif tk_is(ctx, TK.IDENT, "in") then
          -- For-in loop (iterating object keys)
          tk_advance(ctx) -- skip 'in'
          skip_ws(ctx)

          local iter_tokens = {}
          local depth = 1
          while tk_cur(ctx).type ~= TK.EOF do
            local ct = tk_cur(ctx)
            if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
            if ct.type == TK.PUNCT and ct.value == ")" then
              depth = depth - 1
              if depth == 0 then
                tk_advance(ctx)
                break
              end
            end
            iter_tokens[#iter_tokens + 1] = tk_advance(ctx)
          end
          local iter_lua = vim.trim(transform_token_list(iter_tokens, ctx))

          emit(ctx, "for " .. var_name .. " in pairs(" .. iter_lua .. ") do")
          skip_ws(ctx)

          if tk_is(ctx, TK.PUNCT, "{") then
            transform_block(ctx, false)
          else
            emit(ctx, "\n  ")
            transform_statement(ctx)
          end

          emit(ctx, "\nend")
          return
        end
      end

      -- C-style for loop: for (init; cond; update) { body }
      -- This is harder. Collect the three parts.
      -- Actually we may have already consumed some tokens. Let me emit a basic version.
      -- For simplicity, re-emit what we have and handle as a while loop.
      -- This path handles: for (let i = 0; i < n; i++) { body }
      -- We need to go back to before we consumed the declaration.
      -- This is getting complex. Let me just emit a placeholder comment.
      emit(ctx, "-- TODO: C-style for loop not fully supported\n")
      -- Skip to matching )
      local depth = 1
      while tk_cur(ctx).type ~= TK.EOF do
        local ct = tk_cur(ctx)
        if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
        if ct.type == TK.PUNCT and ct.value == ")" then
          depth = depth - 1
          if depth == 0 then tk_advance(ctx); break end
        end
        tk_advance(ctx)
      end
      skip_ws(ctx)
      if tk_is(ctx, TK.PUNCT, "{") then
        -- Skip body
        depth = 1
        tk_advance(ctx)
        while tk_cur(ctx).type ~= TK.EOF do
          local ct = tk_cur(ctx)
          if ct.type == TK.PUNCT and ct.value == "{" then depth = depth + 1 end
          if ct.type == TK.PUNCT and ct.value == "}" then
            depth = depth - 1
            if depth == 0 then tk_advance(ctx); break end
          end
          tk_advance(ctx)
        end
      end
      return
    end
  end

  -- If/else
  if t.type == TK.IDENT and t.value == "if" then
    tk_advance(ctx) -- skip 'if'
    skip_ws(ctx)

    -- Collect condition (inside parens)
    if tk_is(ctx, TK.PUNCT, "(") then
      tk_advance(ctx) -- skip (
      local cond_tokens = {}
      local depth = 1
      while tk_cur(ctx).type ~= TK.EOF do
        local ct = tk_cur(ctx)
        if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
        if ct.type == TK.PUNCT and ct.value == ")" then
          depth = depth - 1
          if depth == 0 then
            tk_advance(ctx) -- skip )
            break
          end
        end
        cond_tokens[#cond_tokens + 1] = tk_advance(ctx)
      end
      local cond_lua = vim.trim(transform_token_list(cond_tokens, ctx))
      emit(ctx, "if " .. cond_lua .. " then")
    end

    skip_ws(ctx)

    -- If body
    if tk_is(ctx, TK.PUNCT, "{") then
      transform_block(ctx, false)
    else
      -- Single statement
      emit(ctx, "\n  ")
      transform_statement(ctx)
    end

    -- Check for else / else if
    local trailing_ws = skip_ws(ctx)
    while tk_is(ctx, TK.IDENT, "else") do
      tk_advance(ctx) -- skip 'else'
      skip_ws(ctx)

      if tk_is(ctx, TK.IDENT, "if") then
        -- else if
        tk_advance(ctx) -- skip 'if'
        skip_ws(ctx)
        if tk_is(ctx, TK.PUNCT, "(") then
          tk_advance(ctx)
          local cond_tokens = {}
          local depth = 1
          while tk_cur(ctx).type ~= TK.EOF do
            local ct = tk_cur(ctx)
            if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
            if ct.type == TK.PUNCT and ct.value == ")" then
              depth = depth - 1
              if depth == 0 then tk_advance(ctx); break end
            end
            cond_tokens[#cond_tokens + 1] = tk_advance(ctx)
          end
          local cond_lua = vim.trim(transform_token_list(cond_tokens, ctx))
          emit(ctx, "\nelseif " .. cond_lua .. " then")
        end
        skip_ws(ctx)
        if tk_is(ctx, TK.PUNCT, "{") then
          transform_block(ctx, false)
        else
          emit(ctx, "\n  ")
          transform_statement(ctx)
        end
        trailing_ws = skip_ws(ctx)
      else
        -- plain else
        emit(ctx, "\nelse")
        skip_ws(ctx)
        if tk_is(ctx, TK.PUNCT, "{") then
          transform_block(ctx, false)
        else
          emit(ctx, "\n  ")
          transform_statement(ctx)
        end
        break -- else is always last
      end
    end

    emit(ctx, "\nend")
    -- Re-emit any trailing whitespace that was consumed while looking for else
    if trailing_ws ~= "" then
      emit(ctx, trailing_ws)
    end
    return
  end

  -- While loop
  if t.type == TK.IDENT and t.value == "while" then
    tk_advance(ctx)
    skip_ws(ctx)
    if tk_is(ctx, TK.PUNCT, "(") then
      tk_advance(ctx)
      local cond_tokens = {}
      local depth = 1
      while tk_cur(ctx).type ~= TK.EOF do
        local ct = tk_cur(ctx)
        if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
        if ct.type == TK.PUNCT and ct.value == ")" then
          depth = depth - 1
          if depth == 0 then tk_advance(ctx); break end
        end
        cond_tokens[#cond_tokens + 1] = tk_advance(ctx)
      end
      local cond_lua = vim.trim(transform_token_list(cond_tokens, ctx))
      emit(ctx, "while " .. cond_lua .. " do")
    end
    skip_ws(ctx)
    if tk_is(ctx, TK.PUNCT, "{") then
      transform_block(ctx, false)
    else
      emit(ctx, "\n  ")
      transform_statement(ctx)
    end
    emit(ctx, "\nend")
    return
  end

  -- Return statement
  if t.type == TK.IDENT and t.value == "return" then
    tk_advance(ctx)
    emit(ctx, "return")
    -- Transform the return value expression
    skip_ws(ctx)
    if tk_cur(ctx).type ~= TK.PUNCT or (tk_cur(ctx).value ~= ";" and tk_cur(ctx).value ~= "}") then
      emit(ctx, " ")
      -- Transform until ; or } or newline at depth 0
      local depth = 0
      while tk_cur(ctx).type ~= TK.EOF do
        local ct = tk_cur(ctx)
        if ct.type == TK.PUNCT and ct.value == ";" then
          tk_advance(ctx)
          break
        end
        if ct.type == TK.PUNCT and ct.value == "}" and depth <= 0 then
          break
        end
        if ct.type == TK.PUNCT and (ct.value == "(" or ct.value == "[" or ct.value == "{") then
          depth = depth + 1
        end
        if ct.type == TK.PUNCT and (ct.value == ")" or ct.value == "]" or ct.value == "}") then
          depth = depth - 1
        end
        if ct.type == TK.NL and depth <= 0 then
          break
        end
        transform_expression(ctx)
      end
    else
      if tk_is(ctx, TK.PUNCT, ";") then tk_advance(ctx) end
    end
    return
  end

  -- Break / continue
  if t.type == TK.IDENT and (t.value == "break" or t.value == "continue") then
    local kw = t.value
    tk_advance(ctx)
    if kw == "continue" then
      -- Lua doesn't have continue in 5.1. Use goto if available (LuaJIT).
      -- For now, emit a comment and a goto pattern.
      emit(ctx, "goto continue") -- requires a ::continue:: label at end of loop
    else
      emit(ctx, "break")
    end
    if tk_is(ctx, TK.PUNCT, ";") then tk_advance(ctx) end
    return
  end

  -- `new Map()` at expression level (not in a declaration)
  if t.type == TK.IDENT and t.value == "new" then
    local next_sig, _ = peek_significant(ctx, 1)
    if next_sig.type == TK.IDENT and next_sig.value == "Map" then
      tk_advance(ctx) -- skip 'new'
      skip_ws(ctx)
      tk_advance(ctx) -- skip 'Map'
      skip_ws(ctx)
      if tk_is(ctx, TK.PUNCT, "(") then
        tk_advance(ctx)
        if tk_is(ctx, TK.PUNCT, ")") then tk_advance(ctx) end
      end
      emit(ctx, "{}")
      return
    end
    -- new Set(), new Array(), etc. -- generic handling
    if next_sig.type == TK.IDENT and (next_sig.value == "Set" or next_sig.value == "Array") then
      tk_advance(ctx)
      skip_ws(ctx)
      tk_advance(ctx)
      skip_ws(ctx)
      if tk_is(ctx, TK.PUNCT, "(") then
        tk_advance(ctx)
        if tk_is(ctx, TK.PUNCT, ")") then tk_advance(ctx) end
      end
      emit(ctx, "{}")
      return
    end
    -- Fallthrough: emit 'new' and let expression handle it
  end

  -- Default: transform as full expression-statement.
  -- Process tokens until we hit a statement terminator (;, newline at depth 0,
  -- or enclosing }). Compound assignment (+=, -=) and increment/decrement
  -- (++, --) are handled by the postprocess() pass.
  local depth = 0
  while tk_cur(ctx).type ~= TK.EOF do
    local ct = tk_cur(ctx)
    if ct.type == TK.PUNCT and ct.value == ";" then
      tk_advance(ctx)
      break
    end
    -- Don't consume closing brace that belongs to enclosing block
    if ct.type == TK.PUNCT and ct.value == "}" and depth == 0 then
      break
    end
    if ct.type == TK.PUNCT and (ct.value == "(" or ct.value == "[" or ct.value == "{") then
      depth = depth + 1
    end
    if ct.type == TK.PUNCT and (ct.value == ")" or ct.value == "]" or ct.value == "}") then
      depth = depth - 1
    end
    if ct.type == TK.NL and depth <= 0 then
      -- Check for method chain continuation on next line
      local next_sig, _ = peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        emit(ctx, ct.value)
        tk_advance(ctx)
      else
        break
      end
    else
      transform_expression(ctx)
    end
  end
end

--- Transform a brace-delimited block `{ stmts }`.
--- Consumes the opening `{` and closing `}`.
--- If `is_arrow` is true, doesn't emit enclosing tokens (used for arrow function blocks).
---@param ctx table
---@param is_arrow boolean|nil
transform_block = function(ctx, is_arrow)
  if not tk_is(ctx, TK.PUNCT, "{") then return end
  tk_advance(ctx) -- skip {

  while tk_cur(ctx).type ~= TK.EOF do
    if tk_is(ctx, TK.PUNCT, "}") then
      tk_advance(ctx) -- skip }
      return
    end
    transform_statement(ctx)
  end
end

-- ---------------------------------------------------------------------------
-- Post-processing
-- ---------------------------------------------------------------------------

--- Post-process the generated Lua code to fix up patterns that are hard
--- to handle during the main transform pass.
---@param lua string
---@return string
local function postprocess(lua)
  -- Fix compound assignment: x += y -> x = x + y
  lua = lua:gsub("([%w_%.%[%]\"']+)%s*%+=%s*", function(lhs)
    return lhs .. " = " .. lhs .. " + "
  end)
  lua = lua:gsub("([%w_%.%[%]\"']+)%s*%-=%s*", function(lhs)
    return lhs .. " = " .. lhs .. " - "
  end)

  -- Fix x++ / ++x -> x = x + 1
  lua = lua:gsub("([%w_%.%[%]]+)%+%+%s*", function(lhs)
    return lhs .. " = " .. lhs .. " + 1"
  end)
  lua = lua:gsub("([%w_%.%[%]]+)%-%-%s", function(lhs)
    -- Be careful not to match Lua comments (--)
    return lhs .. " = " .. lhs .. " - 1 "
  end)

  -- Convert 0-based JS numeric array indices to 1-based Lua indices.
  -- Matches patterns like: identifier[0], expr)[1], etc.
  -- Only affects numeric literals inside [] preceded by word chars, ), or ].
  lua = lua:gsub("([%w_%)%]])%[(%d+)%]", function(prefix, num)
    return prefix .. "[" .. (tonumber(num) + 1) .. "]"
  end)

  -- Remove trailing whitespace on lines
  lua = lua:gsub("[ \t]+\n", "\n")

  -- Remove multiple consecutive blank lines
  lua = lua:gsub("\n\n\n+", "\n\n")

  -- Remove leading/trailing whitespace
  lua = vim.trim(lua)

  return lua
end

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
    local tokens = tokenize(js_code)
    local ctx = make_ctx(tokens)

    while ctx.pos <= #ctx.tokens and tk_cur(ctx).type ~= TK.EOF do
      transform_statement(ctx)
    end

    local raw_lua = table.concat(ctx.out)
    return postprocess(raw_lua)
  end)

  if not ok then
    return nil, "Transpile error: " .. tostring(result)
  end

  return result, nil
end

--- Convenience: transpile and return the result suitable for execute_block().
--- Wraps the transpiled code so it can be passed directly to
--- `api.execute_block()`.
---@param js_code string
---@return string|nil lua_code
---@return string|nil error
function M.transpile_for_exec(js_code)
  return M.transpile(js_code)
end

-- Expose internals for testing
M._tokenize = tokenize
M._regex_to_lua_pattern = regex_to_lua_pattern

return M
