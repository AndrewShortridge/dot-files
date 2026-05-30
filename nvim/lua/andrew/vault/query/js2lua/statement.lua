--- js2lua/statement.lua -- Statement transformer for the JS-to-Lua transpiler.

local TK = require("andrew.vault.query.js2lua.tokens")
local C = require("andrew.vault.query.js2lua.context")
local expression = require("andrew.vault.query.js2lua.expression")

local M = {}

--- Transform a sub-token-list into Lua code (local helper mirroring expression.lua's).
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
    M.transform_statement(sub)
  end

  return table.concat(sub.out)
end

--- Transform a brace-delimited block `{ stmts }`.
--- Consumes the opening `{` and closing `}`.
--- If `is_arrow` is true, doesn't emit enclosing tokens (used for arrow function blocks).
---@param ctx table
---@param is_arrow boolean|nil
function M.transform_block(ctx, is_arrow)
  if not C.tk_is(ctx, TK.PUNCT, "{") then return end
  C.tk_advance(ctx) -- skip {

  while C.tk_cur(ctx).type ~= TK.EOF do
    if C.tk_is(ctx, TK.PUNCT, "}") then
      C.tk_advance(ctx) -- skip }
      return
    end
    M.transform_statement(ctx)
  end
end

--- Transform a single statement.
---@param ctx table
function M.transform_statement(ctx)
  local t = C.tk_cur(ctx)

  -- EOF
  if t.type == TK.EOF then return end

  -- Whitespace / newline / comment -- pass through
  if t.type == TK.WS or t.type == TK.NL or t.type == TK.COMMENT then
    C.emit(ctx, C.tk_advance(ctx).value)
    return
  end

  -- Variable declarations: const/let/var
  if t.type == TK.IDENT and (t.value == "const" or t.value == "let" or t.value == "var") then
    C.tk_advance(ctx) -- skip keyword
    C.skip_ws(ctx)
    local name_tok = C.tk_cur(ctx)
    if name_tok.type == TK.IDENT then
      local var_name = name_tok.value
      C.tk_advance(ctx) -- skip name
      C.skip_ws(ctx)

      -- Check for = initializer
      if C.tk_is(ctx, TK.OP, "=") then
        C.tk_advance(ctx) -- skip =
        C.skip_ws(ctx)

        -- Check for `new Map()`
        if C.tk_is(ctx, TK.IDENT, "new") then
          local next_sig, next_off = C.peek_significant(ctx, 1)
          if next_sig.type == TK.IDENT and next_sig.value == "Map" then
            -- new Map() -> {}
            for _ = 0, next_off do C.tk_advance(ctx) end
            C.skip_ws(ctx)
            if C.tk_is(ctx, TK.PUNCT, "(") then
              C.tk_advance(ctx)
              if C.tk_is(ctx, TK.PUNCT, ")") then C.tk_advance(ctx) end
            end
            ctx.map_vars[var_name] = true
            C.emit(ctx, "local " .. var_name .. " = {}")
            -- Skip trailing semicolon
            C.skip_ws(ctx)
            if C.tk_is(ctx, TK.PUNCT, ";") then C.tk_advance(ctx) end
            return
          end
        end

        C.emit(ctx, "local " .. var_name .. " = ")
        -- Transform the rest of the expression until semicolon or newline at depth 0
        local depth = 0
        while C.tk_cur(ctx).type ~= TK.EOF do
          local ct = C.tk_cur(ctx)
          if ct.type == TK.PUNCT and ct.value == ";" then
            C.tk_advance(ctx)
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
            local next_sig, _ = C.peek_significant(ctx, 1)
            if next_sig.type == TK.OP and next_sig.value == "." then
              C.emit(ctx, C.tk_advance(ctx).value) -- emit newline
            else
              break
            end
          else
            expression.transform_expression(ctx)
          end
        end
        return
      else
        -- Declaration without initializer
        C.emit(ctx, "local " .. var_name)
        if C.tk_is(ctx, TK.PUNCT, ";") then C.tk_advance(ctx) end
        return
      end
    end
    -- Destructuring or other pattern -- fall through to expression
    C.emit(ctx, "local ")
    return
  end

  -- Function declarations
  if t.type == TK.IDENT and t.value == "function" then
    local next_sig, next_off = C.peek_significant(ctx, 1)
    if next_sig.type == TK.IDENT then
      -- Named function declaration
      C.tk_advance(ctx) -- skip 'function'
      C.skip_ws(ctx)
      local fname = C.tk_cur(ctx).value
      C.tk_advance(ctx) -- skip name
      C.skip_ws(ctx)

      -- Collect parameters
      local params = ""
      if C.tk_is(ctx, TK.PUNCT, "(") then
        C.tk_advance(ctx)
        local param_parts = {}
        while not C.tk_is(ctx, TK.PUNCT, ")") and C.tk_cur(ctx).type ~= TK.EOF do
          local pt = C.tk_cur(ctx)
          if pt.type == TK.IDENT then
            param_parts[#param_parts + 1] = pt.value
          end
          C.tk_advance(ctx)
        end
        if C.tk_is(ctx, TK.PUNCT, ")") then C.tk_advance(ctx) end
        params = table.concat(param_parts, ", ")
      end

      C.emit(ctx, "local function " .. fname .. "(" .. params .. ")")
      C.skip_ws(ctx)

      -- Function body
      if C.tk_is(ctx, TK.PUNCT, "{") then
        M.transform_block(ctx, false)
      end

      C.emit(ctx, "\nend")
      return
    end
  end

  -- For-of loop: for (const x of expr) { ... }
  if t.type == TK.IDENT and t.value == "for" then
    C.tk_advance(ctx) -- skip 'for'
    C.skip_ws(ctx)

    if C.tk_is(ctx, TK.PUNCT, "(") then
      C.tk_advance(ctx) -- skip (
      C.skip_ws(ctx)

      -- Check for for-of pattern
      -- for (const/let/var x of expr)
      local has_decl = false
      if C.tk_is(ctx, TK.IDENT, "const") or C.tk_is(ctx, TK.IDENT, "let") or C.tk_is(ctx, TK.IDENT, "var") then
        C.tk_advance(ctx) -- skip const/let/var
        C.skip_ws(ctx)
        has_decl = true
      end

      local var_name_tok = C.tk_cur(ctx)
      if var_name_tok.type == TK.IDENT then
        local var_name = var_name_tok.value
        C.tk_advance(ctx) -- skip variable name
        C.skip_ws(ctx)

        if C.tk_is(ctx, TK.IDENT, "of") then
          -- For-of loop
          C.tk_advance(ctx) -- skip 'of'
          C.skip_ws(ctx)

          -- Collect the iterable expression until )
          local iter_tokens = {}
          local depth = 1
          while C.tk_cur(ctx).type ~= TK.EOF do
            local ct = C.tk_cur(ctx)
            if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
            if ct.type == TK.PUNCT and ct.value == ")" then
              depth = depth - 1
              if depth == 0 then
                C.tk_advance(ctx) -- skip )
                break
              end
            end
            iter_tokens[#iter_tokens + 1] = C.tk_advance(ctx)
          end
          local iter_lua = vim.trim(transform_token_list(iter_tokens, ctx))

          C.emit(ctx, "for _, " .. var_name .. " in ipairs(" .. iter_lua .. ") do")
          C.skip_ws(ctx)

          -- Loop body
          if C.tk_is(ctx, TK.PUNCT, "{") then
            M.transform_block(ctx, false)
          else
            -- Single statement body
            C.emit(ctx, "\n  ")
            M.transform_statement(ctx)
          end

          C.emit(ctx, "\nend")
          return
        elseif C.tk_is(ctx, TK.IDENT, "in") then
          -- For-in loop (iterating object keys)
          C.tk_advance(ctx) -- skip 'in'
          C.skip_ws(ctx)

          local iter_tokens = {}
          local depth = 1
          while C.tk_cur(ctx).type ~= TK.EOF do
            local ct = C.tk_cur(ctx)
            if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
            if ct.type == TK.PUNCT and ct.value == ")" then
              depth = depth - 1
              if depth == 0 then
                C.tk_advance(ctx)
                break
              end
            end
            iter_tokens[#iter_tokens + 1] = C.tk_advance(ctx)
          end
          local iter_lua = vim.trim(transform_token_list(iter_tokens, ctx))

          C.emit(ctx, "for " .. var_name .. " in pairs(" .. iter_lua .. ") do")
          C.skip_ws(ctx)

          if C.tk_is(ctx, TK.PUNCT, "{") then
            M.transform_block(ctx, false)
          else
            C.emit(ctx, "\n  ")
            M.transform_statement(ctx)
          end

          C.emit(ctx, "\nend")
          return
        end
      end

      -- C-style for loop: for (init; cond; update) { body }
      -- At this point we've consumed: for ( [const/let/var] var_name
      -- Remaining tokens: rest_of_init ; cond ; update ) { body }
      -- Transpile to: do local var = init; while cond do body; update end end
      local parts = { {}, {}, {} }
      local part_idx = 1
      local depth = 1 -- inside the outer (
      while C.tk_cur(ctx).type ~= TK.EOF do
        local ct = C.tk_cur(ctx)
        if ct.type == TK.PUNCT and ct.value == "(" then
          depth = depth + 1
          parts[part_idx][#parts[part_idx] + 1] = C.tk_advance(ctx)
        elseif ct.type == TK.PUNCT and ct.value == ")" then
          depth = depth - 1
          if depth == 0 then
            C.tk_advance(ctx) -- skip closing )
            break
          end
          parts[part_idx][#parts[part_idx] + 1] = C.tk_advance(ctx)
        elseif ct.type == TK.PUNCT and ct.value == ";" and depth == 1 then
          C.tk_advance(ctx) -- skip ;
          C.skip_ws(ctx)
          part_idx = math.min(part_idx + 1, 3)
        else
          parts[part_idx][#parts[part_idx] + 1] = C.tk_advance(ctx)
        end
      end

      local init_rest = vim.trim(transform_token_list(parts[1], ctx))
      local cond_lua = vim.trim(transform_token_list(parts[2], ctx))
      local update_lua = vim.trim(transform_token_list(parts[3], ctx))

      -- Build the init statement
      local init_stmt
      if has_decl then
        init_stmt = "local " .. var_name_tok.value .. (init_rest ~= "" and (" " .. init_rest) or "")
      else
        init_stmt = var_name_tok.value .. (init_rest ~= "" and (" " .. init_rest) or "")
      end

      if cond_lua == "" then cond_lua = "true" end

      C.emit(ctx, "do\n" .. init_stmt .. "\nwhile " .. cond_lua .. " do")
      C.skip_ws(ctx)

      -- Loop body
      if C.tk_is(ctx, TK.PUNCT, "{") then
        M.transform_block(ctx, false)
      else
        C.emit(ctx, "\n  ")
        M.transform_statement(ctx)
      end

      -- Update expression before end
      if update_lua ~= "" then
        C.emit(ctx, "\n" .. update_lua)
      end

      C.emit(ctx, "\nend\nend")
      return
    end
  end

  -- If/else
  if t.type == TK.IDENT and t.value == "if" then
    C.tk_advance(ctx) -- skip 'if'
    C.skip_ws(ctx)

    -- Collect condition (inside parens)
    if C.tk_is(ctx, TK.PUNCT, "(") then
      C.tk_advance(ctx) -- skip (
      local cond_tokens = {}
      local depth = 1
      while C.tk_cur(ctx).type ~= TK.EOF do
        local ct = C.tk_cur(ctx)
        if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
        if ct.type == TK.PUNCT and ct.value == ")" then
          depth = depth - 1
          if depth == 0 then
            C.tk_advance(ctx) -- skip )
            break
          end
        end
        cond_tokens[#cond_tokens + 1] = C.tk_advance(ctx)
      end
      local cond_lua = vim.trim(transform_token_list(cond_tokens, ctx))
      C.emit(ctx, "if " .. cond_lua .. " then")
    end

    C.skip_ws(ctx)

    -- If body
    if C.tk_is(ctx, TK.PUNCT, "{") then
      M.transform_block(ctx, false)
    else
      -- Single statement
      C.emit(ctx, "\n  ")
      M.transform_statement(ctx)
    end

    -- Check for else / else if
    local trailing_ws = C.skip_ws(ctx)
    while C.tk_is(ctx, TK.IDENT, "else") do
      C.tk_advance(ctx) -- skip 'else'
      C.skip_ws(ctx)

      if C.tk_is(ctx, TK.IDENT, "if") then
        -- else if
        C.tk_advance(ctx) -- skip 'if'
        C.skip_ws(ctx)
        if C.tk_is(ctx, TK.PUNCT, "(") then
          C.tk_advance(ctx)
          local cond_tokens = {}
          local depth = 1
          while C.tk_cur(ctx).type ~= TK.EOF do
            local ct = C.tk_cur(ctx)
            if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
            if ct.type == TK.PUNCT and ct.value == ")" then
              depth = depth - 1
              if depth == 0 then C.tk_advance(ctx); break end
            end
            cond_tokens[#cond_tokens + 1] = C.tk_advance(ctx)
          end
          local cond_lua = vim.trim(transform_token_list(cond_tokens, ctx))
          C.emit(ctx, "\nelseif " .. cond_lua .. " then")
        end
        C.skip_ws(ctx)
        if C.tk_is(ctx, TK.PUNCT, "{") then
          M.transform_block(ctx, false)
        else
          C.emit(ctx, "\n  ")
          M.transform_statement(ctx)
        end
        trailing_ws = C.skip_ws(ctx)
      else
        -- plain else
        C.emit(ctx, "\nelse")
        C.skip_ws(ctx)
        if C.tk_is(ctx, TK.PUNCT, "{") then
          M.transform_block(ctx, false)
        else
          C.emit(ctx, "\n  ")
          M.transform_statement(ctx)
        end
        break -- else is always last
      end
    end

    C.emit(ctx, "\nend")
    -- Re-emit any trailing whitespace that was consumed while looking for else
    if trailing_ws ~= "" then
      C.emit(ctx, trailing_ws)
    end
    return
  end

  -- While loop
  if t.type == TK.IDENT and t.value == "while" then
    C.tk_advance(ctx)
    C.skip_ws(ctx)
    if C.tk_is(ctx, TK.PUNCT, "(") then
      C.tk_advance(ctx)
      local cond_tokens = {}
      local depth = 1
      while C.tk_cur(ctx).type ~= TK.EOF do
        local ct = C.tk_cur(ctx)
        if ct.type == TK.PUNCT and ct.value == "(" then depth = depth + 1 end
        if ct.type == TK.PUNCT and ct.value == ")" then
          depth = depth - 1
          if depth == 0 then C.tk_advance(ctx); break end
        end
        cond_tokens[#cond_tokens + 1] = C.tk_advance(ctx)
      end
      local cond_lua = vim.trim(transform_token_list(cond_tokens, ctx))
      C.emit(ctx, "while " .. cond_lua .. " do")
    end
    C.skip_ws(ctx)
    if C.tk_is(ctx, TK.PUNCT, "{") then
      M.transform_block(ctx, false)
    else
      C.emit(ctx, "\n  ")
      M.transform_statement(ctx)
    end
    C.emit(ctx, "\nend")
    return
  end

  -- Return statement
  if t.type == TK.IDENT and t.value == "return" then
    C.tk_advance(ctx)
    C.emit(ctx, "return")
    -- Transform the return value expression
    C.skip_ws(ctx)
    if C.tk_cur(ctx).type ~= TK.PUNCT or (C.tk_cur(ctx).value ~= ";" and C.tk_cur(ctx).value ~= "}") then
      C.emit(ctx, " ")
      -- Transform until ; or } or newline at depth 0
      local depth = 0
      while C.tk_cur(ctx).type ~= TK.EOF do
        local ct = C.tk_cur(ctx)
        if ct.type == TK.PUNCT and ct.value == ";" then
          C.tk_advance(ctx)
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
        expression.transform_expression(ctx)
      end
    else
      if C.tk_is(ctx, TK.PUNCT, ";") then C.tk_advance(ctx) end
    end
    return
  end

  -- Break / continue
  if t.type == TK.IDENT and (t.value == "break" or t.value == "continue") then
    local kw = t.value
    C.tk_advance(ctx)
    if kw == "continue" then
      -- Lua doesn't have continue in 5.1. Use goto if available (LuaJIT).
      -- For now, emit a comment and a goto pattern.
      C.emit(ctx, "goto continue") -- requires a ::continue:: label at end of loop
    else
      C.emit(ctx, "break")
    end
    if C.tk_is(ctx, TK.PUNCT, ";") then C.tk_advance(ctx) end
    return
  end

  -- `new Map()` at expression level (not in a declaration)
  if t.type == TK.IDENT and t.value == "new" then
    local next_sig, _ = C.peek_significant(ctx, 1)
    if next_sig.type == TK.IDENT and next_sig.value == "Map" then
      C.tk_advance(ctx) -- skip 'new'
      C.skip_ws(ctx)
      C.tk_advance(ctx) -- skip 'Map'
      C.skip_ws(ctx)
      if C.tk_is(ctx, TK.PUNCT, "(") then
        C.tk_advance(ctx)
        if C.tk_is(ctx, TK.PUNCT, ")") then C.tk_advance(ctx) end
      end
      C.emit(ctx, "{}")
      return
    end
    -- new Set(), new Array(), etc. -- generic handling
    if next_sig.type == TK.IDENT and (next_sig.value == "Set" or next_sig.value == "Array") then
      C.tk_advance(ctx)
      C.skip_ws(ctx)
      C.tk_advance(ctx)
      C.skip_ws(ctx)
      if C.tk_is(ctx, TK.PUNCT, "(") then
        C.tk_advance(ctx)
        if C.tk_is(ctx, TK.PUNCT, ")") then C.tk_advance(ctx) end
      end
      C.emit(ctx, "{}")
      return
    end
    -- Fallthrough: emit 'new' and let expression handle it
  end

  -- Default: transform as full expression-statement.
  -- Process tokens until we hit a statement terminator (;, newline at depth 0,
  -- or enclosing }). Compound assignment (+=, -=) and increment/decrement
  -- (++, --) are handled by the postprocess() pass.
  local depth = 0
  while C.tk_cur(ctx).type ~= TK.EOF do
    local ct = C.tk_cur(ctx)
    if ct.type == TK.PUNCT and ct.value == ";" then
      C.tk_advance(ctx)
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
      local next_sig, _ = C.peek_significant(ctx, 1)
      if next_sig.type == TK.OP and next_sig.value == "." then
        C.emit(ctx, ct.value)
        C.tk_advance(ctx)
      else
        break
      end
    else
      expression.transform_expression(ctx)
    end
  end
end

-- Wire up late-bound references in expression.lua to break mutual recursion.
expression.set_statement_transformer(M.transform_statement)
expression.set_block_transformer(M.transform_block)

return M
