--- js2lua/postprocess.lua -- Post-processing pass for generated Lua code.

local M = {}

--- Post-process the generated Lua code to fix up patterns that are hard
--- to handle during the main transform pass.
---@param lua string
---@return string
function M.postprocess(lua)
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

return M
