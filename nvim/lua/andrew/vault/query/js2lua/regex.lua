--- js2lua/regex.lua -- JavaScript regex to Lua pattern converter.

local M = {}

--- Attempt to convert a JavaScript regex literal to a Lua pattern string.
--- Returns the pattern string and a boolean `is_global`.
--- Returns nil if conversion is not possible.
---@param regex_token string  e.g. `/\w+/g`
---@return string|nil lua_pattern
---@return boolean is_global
function M.regex_to_lua_pattern(regex_token)
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
      if i <= plen and pattern:byte(i) == 94 then
        class_buf = class_buf .. "^"
        i = i + 1
      end
      -- Allow ] as first char in class
      if i <= plen and pattern:byte(i) == 93 then
        class_buf = class_buf .. "%]"
        i = i + 1
      end
      while i <= plen and pattern:byte(i) ~= 93 do
        local c = string.char(pattern:byte(i))
        if c == "\\" then
          i = i + 1
          if i <= plen then
            local nc = string.char(pattern:byte(i))
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

return M
