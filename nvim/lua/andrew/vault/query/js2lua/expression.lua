--- js2lua/expression.lua -- Expression transformer for the JS-to-Lua transpiler.

local TK = require("andrew.vault.query.js2lua.tokens")
local C = require("andrew.vault.query.js2lua.context")
local regex_mod = require("andrew.vault.query.js2lua.regex")
local tokenizer = require("andrew.vault.query.js2lua.tokenizer")

local M = {}

-- Late-bound references to statement module functions (set via setters to
-- break mutual recursion between expression.lua and statement.lua).
local _transform_statement
local _transform_block

function M.set_statement_transformer(fn)
  _transform_statement = fn
end

function M.set_block_transformer(fn)
  _transform_block = fn
end

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

  local sub = C.make_ctx(toks)
  sub.map_vars = parent_ctx.map_vars
  sub.indent = parent_ctx.indent

  -- Transform as a sequence of statements/expressions
  while sub.pos <= #sub.tokens and C.tk_cur(sub).type ~= TK.EOF do
    _transform_statement(sub)
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
      local expr_lua = transform_token_list(tokenizer.tokenize(p.value), parent_ctx)
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
  local t = C.tk_cur(ctx)

  -- Case 1: ident => ...
  if t.type == TK.IDENT then
    local next_sig, next_off = C.peek_significant(ctx, 1)
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
      local tk = C.tk_peek(ctx, off)
      if tk.type == TK.EOF then return nil end
      if tk.type == TK.PUNCT and tk.value == "(" then depth = depth + 1 end
      if tk.type == TK.PUNCT and tk.value == ")" then
        depth = depth - 1
        if depth == 0 then
          -- Check if next significant token is =>
          local after, after_off = C.peek_significant(ctx, off + 1)
          if after.type == TK.OP and after.value == "=>" then
            -- Collect param tokens
            local params = {}
            for i = 1, off - 1 do
              local pt = C.tk_peek(ctx, i)
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

--- Transform the body of an arrow function (expression form).
--- Collects and transforms tokens until we hit a terminator at depth 0.
---@param ctx table
local function transform_arrow_body(ctx)
  local depth_paren = 0
  local depth_bracket = 0
  local depth_brace = 0

  while C.tk_cur(ctx).type ~= TK.EOF do
    local t = C.tk_cur(ctx)

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
      local next_sig, _ = C.peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        -- Continuation, keep going
        C.emit(ctx, t.value)
        C.tk_advance(ctx)
      else
        return
      end
    else
      M.transform_expression(ctx)
    end
  end
end

--- Transform an arrow function.
--- Assumes detect_arrow returned non-nil. Consumes tokens and emits Lua.
---@param ctx table
---@param arrow table  from detect_arrow
local function transform_arrow(ctx, arrow)
  -- Skip to past the => token
  for _ = 1, arrow.arrow_offset do
    C.tk_advance(ctx)
  end
  C.tk_advance(ctx) -- skip the => itself

  C.skip_ws(ctx)

  C.emit(ctx, "function(" .. arrow.params .. ") ")

  -- Arrow body: either { block } or expression
  if C.tk_is(ctx, TK.PUNCT, "{") then
    -- Block body
    _transform_block(ctx, true)
    C.emit(ctx, " end")
  else
    -- Expression body: collect until we hit something that ends the expression
    -- in the current context (comma, closing paren/bracket, semicolon, or EOF)
    C.emit(ctx, "return ")
    transform_arrow_body(ctx)
    C.emit(ctx, " end")
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
  while C.tk_cur(ctx).type ~= TK.EOF do
    local t = C.tk_cur(ctx)
    if t.type == TK.PUNCT then
      if t.value == "(" or t.value == "[" or t.value == "{" then
        depth = depth + 1
      elseif t.value == ")" or t.value == "]" or t.value == "}" then
        if depth == 0 then break end
        depth = depth - 1
      elseif t.value == ":" and depth == 0 then
        C.tk_advance(ctx) -- skip :
        break
      end
    end
    M.transform_expression(ctx)
  end
  local then_lua = vim.trim(table.concat(ctx.out))

  -- Collect else-expression with shared output buffer
  ctx.out = {}
  depth = 0
  while C.tk_cur(ctx).type ~= TK.EOF do
    local t = C.tk_cur(ctx)
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
    M.transform_expression(ctx)
  end
  local else_lua = vim.trim(table.concat(ctx.out))

  -- Restore output and emit IIFE
  ctx.out = saved_out
  C.emit(ctx, "(function() if " .. cond_lua .. " then return " .. then_lua .. " else return " .. else_lua .. " end end)()")
end

--- Transform a single expression token (the main expression driver).
--- This handles one "unit" of expression (a token, possibly with suffixes).
---@param ctx table
function M.transform_expression(ctx)
  local t = C.tk_cur(ctx)

  -- EOF
  if t.type == TK.EOF then return end

  -- Whitespace / newline / comment -- pass through
  if t.type == TK.WS or t.type == TK.NL or t.type == TK.COMMENT then
    C.emit(ctx, C.tk_advance(ctx).value)
    return
  end

  -- Template literal
  if t.type == TK.TMPL then
    C.tk_advance(ctx)
    C.emit(ctx, transform_template(t, ctx))
    return
  end

  -- String literal
  if t.type == TK.STR then
    C.tk_advance(ctx)
    -- Convert single-quoted strings to double-quoted for consistency
    if t.value:sub(1, 1) == "'" then
      local inner = t.value:sub(2, -2)
      -- Unescape single quotes, escape double quotes
      inner = inner:gsub("\\'", "'")
      inner = inner:gsub('"', '\\"')
      C.emit(ctx, '"' .. inner .. '"')
    else
      C.emit(ctx, t.value)
    end
    return
  end

  -- Number
  if t.type == TK.NUM then
    C.emit(ctx, C.tk_advance(ctx).value)
    return
  end

  -- Regex literal (used in .replace() calls -- handled at call site mostly)
  if t.type == TK.REGEX then
    -- Convert to Lua pattern string
    local lua_pat, _ = regex_mod.regex_to_lua_pattern(t.value)
    C.tk_advance(ctx)
    if lua_pat then
      C.emit(ctx, '"' .. lua_pat:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"')
    else
      C.emit(ctx, '"" --[[ REGEX NOT CONVERTED: ' .. t.value .. ' ]]')
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
    C.tk_advance(ctx)

    if v == "===" then
      C.emit(ctx, "==")
      return
    elseif v == "!==" then
      C.emit(ctx, "~=")
      return
    elseif v == "==" then
      C.emit(ctx, "==")
      return
    elseif v == "!=" then
      C.emit(ctx, "~=")
      return
    elseif v == "&&" then
      C.emit(ctx, " and ")
      return
    elseif v == "||" then
      C.emit(ctx, " or ")
      return
    elseif v == "!" then
      C.emit(ctx, "not ")
      return
    elseif v == "+=" then
      -- x += y -> x = x + y
      -- The LHS was already emitted. We need to fix this at the statement level.
      -- For now, emit as-is; we'll handle it at the statement level.
      C.emit(ctx, "+= ") -- placeholder, handled in postprocess
      return
    elseif v == "-=" then
      C.emit(ctx, "-= ")
      return
    elseif v == "++" then
      C.emit(ctx, "++ ") -- placeholder, handled in postprocess
      return
    elseif v == "--" then
      C.emit(ctx, "-- ")
      return
    elseif v == "." then
      -- Dot access. Check for special property/method patterns.
      C.skip_ws(ctx)
      local prop = C.tk_cur(ctx)
      if prop.type == TK.IDENT then
        local prop_name = prop.value

        -- .length -> # prefix (handled specially)
        if prop_name == "length" then
          C.tk_advance(ctx)
          -- Convert .length to Lua # operator on the preceding expression
          local expr_str = extract_expr_from_output(ctx)

          -- Emit #(expr)
          if expr_str:match("^[%w_%.%:]+$") then
            C.emit(ctx, "#" .. expr_str)
          else
            C.emit(ctx, "#(" .. expr_str .. ")")
          end
          return
        end

        -- .push(val) -> table.insert(obj, val)
        if prop_name == "push" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx) -- skip 'push'
            C.skip_ws(ctx)
            -- Extract the object expression from the output buffer
            local obj = extract_expr_from_output(ctx)

            -- Consume the arguments between ( and )
            C.tk_advance(ctx) -- skip (
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then
                  C.tk_advance(ctx) -- skip )
                  break
                end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end

            local arg_lua = transform_token_list(arg_tokens, ctx)
            C.emit(ctx, "table.insert(" .. obj .. ", " .. vim.trim(arg_lua) .. ")")
            return
          end
        end

        -- .has(key) -> [key] ~= nil
        if prop_name == "has" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx) -- skip 'has'
            C.skip_ws(ctx)
            C.tk_advance(ctx) -- skip (
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local key_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            -- Emit [key] — truthy in Lua if the key exists (works with `not` prefix)
            C.emit(ctx, "[" .. key_lua .. "]")
            return
          end
        end

        -- .get(key) -> [key]
        if prop_name == "get" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx) -- skip 'get'
            C.skip_ws(ctx)
            C.tk_advance(ctx) -- skip (
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local key_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            C.emit(ctx, "[" .. key_lua .. "]")
            return
          end
        end

        -- .set(key, val) -> [key] = val (as a statement)
        if prop_name == "set" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx) -- skip 'set'
            C.skip_ws(ctx)
            C.tk_advance(ctx) -- skip (
            -- Collect all args, split by comma at depth 0
            local all_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              all_tokens[#all_tokens + 1] = C.tk_advance(ctx)
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
            C.emit(ctx, "[" .. key_lua .. "] = " .. val_lua)
            return
          end
        end

        -- .keys() -> pairs iteration (handled at Array.from site)
        if prop_name == "keys" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            -- .keys() is typically used inside Array.from(x.keys()).sort()
            -- We handle conversion at the Array.from level. Here emit a
            -- marker that Array.from can detect.
            C.tk_advance(ctx) -- skip 'keys'
            C.skip_ws(ctx)
            C.tk_advance(ctx) -- skip (
            -- Expect )
            if C.tk_is(ctx, TK.PUNCT, ")") then
              C.tk_advance(ctx)
            end
            -- Emit a special marker that Array.from can detect and handle
            C.emit(ctx, " --[[.keys()]]")
            return
          end
        end

        -- .trim() -> :match("^%s*(.-)%s*$") or vim.trim()
        if prop_name == "trim" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx) -- skip 'trim'
            C.skip_ws(ctx)
            C.tk_advance(ctx) -- skip (
            if C.tk_is(ctx, TK.PUNCT, ")") then C.tk_advance(ctx) end
            -- Use Lua string.match to trim whitespace
            C.emit(ctx, ":match(\"^%s*(.-)%s*$\")")
            return
          end
        end

        -- .replace(pattern, replacement) -> :gsub(pattern, replacement)
        if prop_name == "replace" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx) -- skip 'replace'
            C.skip_ws(ctx)
            C.tk_advance(ctx) -- skip (
            -- Collect arguments
            local all_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              all_tokens[#all_tokens + 1] = C.tk_advance(ctx)
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
            C.emit(ctx, ":gsub(" .. pattern_lua .. ", " .. repl_lua .. ")")
            return
          end
        end

        -- .split(sep) -> vim.split(str, sep) -- need to wrap
        if prop_name == "split" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx)
            C.skip_ws(ctx)
            C.tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local sep_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            C.emit(ctx, ":split(" .. sep_lua .. ")")
            return
          end
        end

        -- .join(sep) -> table.concat(arr, sep)
        if prop_name == "join" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx)
            C.skip_ws(ctx)
            C.tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local sep_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            local obj_expr = extract_expr_from_output(ctx)
            if sep_lua == "" then sep_lua = '""' end
            C.emit(ctx, "table.concat(" .. obj_expr .. ", " .. sep_lua .. ")")
            return
          end
        end

        -- .includes(val) -> vim.tbl_contains(arr, val) or string:find
        if prop_name == "includes" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx)
            C.skip_ws(ctx)
            C.tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local val_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            -- Emit as :find() for strings, or wrap for tables
            -- Use a generic helper
            C.emit(ctx, ":find(" .. val_lua .. ", 1, true) ~= nil")
            return
          end
        end

        -- .startsWith(str) -> string check
        if prop_name == "startsWith" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx)
            C.skip_ws(ctx)
            C.tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local val_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            C.emit(ctx, ":sub(1, #(" .. val_lua .. ")) == " .. val_lua)
            return
          end
        end

        -- .endsWith(str)
        if prop_name == "endsWith" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx)
            C.skip_ws(ctx)
            C.tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local val_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            C.emit(ctx, ":sub(-#(" .. val_lua .. ")) == " .. val_lua)
            return
          end
        end

        -- .toLowerCase() / .toUpperCase()
        if prop_name == "toLowerCase" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx); C.skip_ws(ctx); C.tk_advance(ctx)
            if C.tk_is(ctx, TK.PUNCT, ")") then C.tk_advance(ctx) end
            C.emit(ctx, ":lower()")
            return
          end
        end
        if prop_name == "toUpperCase" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx); C.skip_ws(ctx); C.tk_advance(ctx)
            if C.tk_is(ctx, TK.PUNCT, ")") then C.tk_advance(ctx) end
            C.emit(ctx, ":upper()")
            return
          end
        end

        -- .toString()
        if prop_name == "toString" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx); C.skip_ws(ctx); C.tk_advance(ctx)
            if C.tk_is(ctx, TK.PUNCT, ")") then C.tk_advance(ctx) end
            local expr_str = extract_expr_from_output(ctx)
            C.emit(ctx, "tostring(" .. expr_str .. ")")
            return
          end
        end

        -- .sort() with comparator -- convert JS comparator to Lua
        if prop_name == "sort" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx) -- skip 'sort'
            C.skip_ws(ctx)
            -- Check if it's .sort() with no args or .sort(comparator)
            local after_open, _ = C.peek_significant(ctx, 1)
            if after_open.type == TK.PUNCT and after_open.value == ")" then
              -- No comparator: .sort() -> table.sort(obj); wrap result
              C.tk_advance(ctx) -- skip (
              C.tk_advance(ctx) -- skip )
              -- For PageArray, :sort() already works. For plain tables, we need table.sort.
              -- Use colon syntax to support both.
              C.emit(ctx, ":sort()")
              return
            else
              -- Has comparator function
              C.tk_advance(ctx) -- skip (
              local arg_tokens = {}
              local depth = 1
              while C.tk_cur(ctx).type ~= TK.EOF do
                local at = C.tk_cur(ctx)
                if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
                if at.type == TK.PUNCT and at.value == ")" then
                  depth = depth - 1
                  if depth == 0 then C.tk_advance(ctx); break end
                end
                arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
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
                C.emit(ctx, "table.sort(" .. obj .. ", function(" .. params .. ") return (" .. body .. ") < 0 end)")
              else
                C.emit(ctx, "table.sort(" .. obj .. ", function(a, b) return (" .. comparator_lua .. ")(a, b) < 0 end)")
              end
              return
            end
          end
        end

        -- .filter(fn) -> :where(fn) for PageArray compatibility
        if prop_name == "filter" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx) -- skip 'filter'
            C.emit(ctx, ":where")
            return
          end
        end

        -- .map, .forEach, .flatMap, .groupBy, .where, .limit, etc. -- use colon syntax
        if prop_name == "map" or prop_name == "forEach" or prop_name == "flatMap"
            or prop_name == "groupBy" or prop_name == "where" or prop_name == "limit"
            or prop_name == "slice" or prop_name == "first" or prop_name == "last"
            or prop_name == "count" or prop_name == "values" or prop_name == "array"
            or prop_name == "plus" or prop_name == "minus" then
          local next_sig, _ = C.peek_significant(ctx, 1)
          if next_sig.type == TK.PUNCT and next_sig.value == "(" then
            C.tk_advance(ctx) -- skip method name
            C.emit(ctx, ":" .. prop_name)
            return
          end
        end

        -- Default: regular dot access
        C.tk_advance(ctx) -- skip property name
        C.emit(ctx, "." .. prop_name)
      else
        -- Dot not followed by ident (shouldn't happen normally)
        C.emit(ctx, ".")
      end
      return
    end

    -- .concat -> ..
    if v == "+" then
      -- This could be string concatenation or addition. Lua uses .. for strings
      -- and + for numbers. Since we can't always know the types, keep as +.
      -- The runtime will handle it via metamethods or the dv environment.
      C.emit(ctx, " + ")
      return
    end

    C.emit(ctx, v)
    return
  end

  -- Punctuation
  if t.type == TK.PUNCT then
    local v = t.value

    -- Semicolons -> remove (Lua doesn't need them, but they're valid)
    if v == ";" then
      C.tk_advance(ctx)
      -- Emit newline if the next token isn't already a newline
      local next_t = C.tk_cur(ctx)
      if next_t.type ~= TK.NL and next_t.type ~= TK.EOF then
        -- Don't emit anything; the next newline or statement will provide separation
      end
      return
    end

    -- Question mark -> ternary
    if v == "?" then
      C.tk_advance(ctx) -- skip ?
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
        C.tk_advance(ctx) -- skip [
        C.emit(ctx, "{")
        -- Transform contents until ]
        local depth = 1
        while C.tk_cur(ctx).type ~= TK.EOF do
          if C.tk_is(ctx, TK.PUNCT, "[") then depth = depth + 1 end
          if C.tk_is(ctx, TK.PUNCT, "]") then
            depth = depth - 1
            if depth == 0 then
              C.tk_advance(ctx) -- skip ]
              C.emit(ctx, "}")
              return
            end
          end
          M.transform_expression(ctx)
        end
        C.emit(ctx, "}")
        return
      else
        -- Property access: emit as-is
        C.tk_advance(ctx)
        C.emit(ctx, "[")
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
        C.tk_advance(ctx)
        C.emit(ctx, " =")
        return
      end
    end

    -- Default punctuation
    C.tk_advance(ctx)
    C.emit(ctx, v)
    return
  end

  -- Identifiers and keywords
  if t.type == TK.IDENT then
    local v = t.value

    -- typeof -> type()
    if v == "typeof" then
      C.tk_advance(ctx)
      C.skip_ws(ctx)
      -- Collect operand tokens, then transform them as a group.
      -- typeof binds to the next "primary expression" including property access.
      local operand_tokens = {}
      if C.tk_is(ctx, TK.PUNCT, "(") then
        -- Parenthesized: collect everything inside ( ... )
        operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx) -- (
        local depth = 1
        while C.tk_cur(ctx).type ~= TK.EOF do
          local ot = C.tk_cur(ctx)
          if ot.type == TK.PUNCT and ot.value == "(" then depth = depth + 1 end
          if ot.type == TK.PUNCT and ot.value == ")" then
            depth = depth - 1
            if depth == 0 then
              operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx) -- )
              break
            end
          end
          operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx)
        end
      else
        -- Unparenthesized: collect identifier + any .prop / [index] / (call) suffixes
        operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx)
        while C.tk_cur(ctx).type ~= TK.EOF do
          local nt = C.tk_cur(ctx)
          if nt.type == TK.OP and nt.value == "." then
            -- .prop
            operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx) -- .
            -- skip ws between . and prop name
            while C.tk_cur(ctx).type == TK.WS do
              operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx)
            end
            if C.tk_cur(ctx).type == TK.IDENT then
              operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx)
            end
          elseif nt.type == TK.PUNCT and nt.value == "[" then
            -- [index]
            operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx) -- [
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local bt = C.tk_cur(ctx)
              if bt.type == TK.PUNCT and bt.value == "[" then depth = depth + 1 end
              if bt.type == TK.PUNCT and bt.value == "]" then
                depth = depth - 1
                if depth == 0 then
                  operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx) -- ]
                  break
                end
              end
              operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx)
            end
          elseif nt.type == TK.PUNCT and nt.value == "(" then
            -- (call)
            operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx) -- (
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local ct = C.tk_cur(ctx)
              if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
              if ct.type == TK.PUNCT and ct.value == ")" then
                depth = depth - 1
                if depth == 0 then
                  operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx) -- )
                  break
                end
              end
              operand_tokens[#operand_tokens + 1] = C.tk_advance(ctx)
            end
          else
            break
          end
        end
      end
      local operand = vim.trim(transform_token_list(operand_tokens, ctx))
      C.emit(ctx, "type(" .. operand .. ")")
      return
    end

    -- null / undefined -> nil
    if v == "null" or v == "undefined" then
      C.tk_advance(ctx)
      C.emit(ctx, "nil")
      return
    end

    -- true / false -> true / false (same in Lua)
    if v == "true" or v == "false" then
      C.tk_advance(ctx)
      C.emit(ctx, v)
      return
    end

    -- this -> (leave as-is, or map to self)
    if v == "this" then
      C.tk_advance(ctx)
      C.emit(ctx, "self")
      return
    end

    -- Math.round -> math.floor(x + 0.5)
    if v == "Math" then
      local next_sig, next_off = C.peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = C.peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT then
          local method = method_sig.value
          if method == "round" then
            -- Math.round(expr) -> math.floor(expr + 0.5)
            for _ = 1, method_off do C.tk_advance(ctx) end
            C.tk_advance(ctx) -- skip method name
            C.skip_ws(ctx)
            if C.tk_is(ctx, TK.PUNCT, "(") then
              C.tk_advance(ctx) -- skip (
              local arg_tokens = {}
              local depth = 1
              while C.tk_cur(ctx).type ~= TK.EOF do
                local at = C.tk_cur(ctx)
                if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
                if at.type == TK.PUNCT and at.value == ")" then
                  depth = depth - 1
                  if depth == 0 then C.tk_advance(ctx); break end
                end
                arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
              end
              local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))
              C.emit(ctx, "math.floor(" .. arg_lua .. " + 0.5)")
            end
            return
          elseif method == "floor" or method == "ceil" or method == "abs"
              or method == "min" or method == "max" or method == "sqrt"
              or method == "pow" or method == "log" or method == "random" then
            -- Math.method -> math.method
            for _ = 1, method_off do C.tk_advance(ctx) end
            C.tk_advance(ctx)
            C.emit(ctx, "math." .. method)
            return
          elseif method == "PI" then
            for _ = 1, method_off do C.tk_advance(ctx) end
            C.tk_advance(ctx)
            C.emit(ctx, "math.pi")
            return
          end
        end
      end
    end

    -- console.log -> print
    if v == "console" then
      local next_sig, next_off = C.peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = C.peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT and method_sig.value == "log" then
          for _ = 1, method_off do C.tk_advance(ctx) end
          C.tk_advance(ctx)
          C.emit(ctx, "print")
          return
        end
      end
    end

    -- JSON.stringify -> vim.inspect
    if v == "JSON" then
      local next_sig, next_off = C.peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = C.peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT and method_sig.value == "stringify" then
          for _ = 1, method_off do C.tk_advance(ctx) end
          C.tk_advance(ctx)
          C.emit(ctx, "vim.inspect")
          return
        end
      end
    end

    -- Object.keys(x) -> (function() local _k = {} for k in pairs(x) do _k[#_k+1] = k end return _k end)()
    if v == "Object" then
      local next_sig, next_off = C.peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = C.peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT and method_sig.value == "keys" then
          for _ = 1, method_off do C.tk_advance(ctx) end
          C.tk_advance(ctx)
          C.skip_ws(ctx)
          if C.tk_is(ctx, TK.PUNCT, "(") then
            C.tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            C.emit(ctx, "(function() local _k = {}; for k in pairs(" .. arg_lua .. ") do _k[#_k+1] = k end; return _k end)()")
          end
          return
        end
        if method_sig.type == TK.IDENT and method_sig.value == "values" then
          for _ = 1, method_off do C.tk_advance(ctx) end
          C.tk_advance(ctx)
          C.skip_ws(ctx)
          if C.tk_is(ctx, TK.PUNCT, "(") then
            C.tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            C.emit(ctx, "(function() local _v = {}; for _, v in pairs(" .. arg_lua .. ") do _v[#_v+1] = v end; return _v end)()")
          end
          return
        end
      end
    end

    -- Array.from(expr).sort() -> sorted keys IIFE
    if v == "Array" then
      local next_sig, next_off = C.peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        local method_sig, method_off = C.peek_significant(ctx, next_off + 1)
        if method_sig.type == TK.IDENT and method_sig.value == "from" then
          for _ = 1, method_off do C.tk_advance(ctx) end
          C.tk_advance(ctx) -- skip 'from'
          C.skip_ws(ctx)
          if C.tk_is(ctx, TK.PUNCT, "(") then
            C.tk_advance(ctx) -- skip (
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))

            -- Check if the arg ends with --[[.keys()]]
            local keys_marker = " --[[.keys()]]"
            if arg_lua:sub(-#keys_marker) == keys_marker then
              local map_expr = vim.trim(arg_lua:sub(1, -#keys_marker - 1))
              -- Check if .sort() follows
              C.skip_ws(ctx)
              local sort_sig, sort_off = C.peek_significant(ctx, 0)
              if sort_sig.type == TK.OP and sort_sig.value == "." then
                local sort_name, sn_off = C.peek_significant(ctx, sort_off + 1)
                if sort_name.type == TK.IDENT and sort_name.value == "sort" then
                  -- Consume .sort()
                  for _ = 0, sn_off do C.tk_advance(ctx) end
                  C.skip_ws(ctx)
                  if C.tk_is(ctx, TK.PUNCT, "(") then
                    C.tk_advance(ctx)
                    if C.tk_is(ctx, TK.PUNCT, ")") then C.tk_advance(ctx) end
                  end
                  C.emit(ctx, "(function() local _k = {}; for k in pairs(" .. map_expr .. ") do _k[#_k+1] = k end; table.sort(_k); return _k end)()")
                  return
                end
              end
              -- No .sort() follows
              C.emit(ctx, "(function() local _k = {}; for k in pairs(" .. map_expr .. ") do _k[#_k+1] = k end; return _k end)()")
            else
              -- Generic Array.from -> just emit the inner expression
              -- (Converts iterable to array, which in Lua is usually already a table)
              C.emit(ctx, arg_lua)
            end
          end
          return
        end
        if method_sig.type == TK.IDENT and method_sig.value == "isArray" then
          for _ = 1, method_off do C.tk_advance(ctx) end
          C.tk_advance(ctx)
          C.skip_ws(ctx)
          if C.tk_is(ctx, TK.PUNCT, "(") then
            C.tk_advance(ctx)
            local arg_tokens = {}
            local depth = 1
            while C.tk_cur(ctx).type ~= TK.EOF do
              local at = C.tk_cur(ctx)
              if at.type == TK.PUNCT and at.value == "(" then depth = depth + 1 end
              if at.type == TK.PUNCT and at.value == ")" then
                depth = depth - 1
                if depth == 0 then C.tk_advance(ctx); break end
              end
              arg_tokens[#arg_tokens + 1] = C.tk_advance(ctx)
            end
            local arg_lua = vim.trim(transform_token_list(arg_tokens, ctx))
            C.emit(ctx, "(type(" .. arg_lua .. ') == "table")')
          end
          return
        end
      end
    end

    -- parseInt / parseFloat -> tonumber
    if v == "parseInt" or v == "parseFloat" then
      C.tk_advance(ctx)
      C.emit(ctx, "tonumber")
      return
    end

    -- String(x) -> tostring(x)
    if v == "String" then
      local next_sig, _ = C.peek_significant(ctx, 1)
      if next_sig.type == TK.PUNCT and next_sig.value == "(" then
        C.tk_advance(ctx)
        C.emit(ctx, "tostring")
        return
      end
    end

    -- Number(x) -> tonumber(x)
    if v == "Number" then
      local next_sig, _ = C.peek_significant(ctx, 1)
      if next_sig.type == TK.PUNCT and next_sig.value == "(" then
        C.tk_advance(ctx)
        C.emit(ctx, "tonumber")
        return
      end
    end

    -- Default identifier
    C.tk_advance(ctx)
    C.emit(ctx, v)
    return
  end

  -- Fallback: emit as-is
  C.emit(ctx, C.tk_advance(ctx).value)
end

return M
