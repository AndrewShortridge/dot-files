local M = {}

--- Equality comparison that understands Links, Dates, and plain values.
---@param a any
---@param b any
---@return boolean
function M.compare_eq(a, b)
  if a == nil and b == nil then
    return true
  end
  if a == nil or b == nil then
    return false
  end
  -- Link comparison: match on path
  if type(a) == "table" and a.path and type(b) == "table" and b.path then
    return a.path == b.path
  end
  -- Date comparison
  if type(a) == "table" and a.timestamp and type(b) == "table" and b.timestamp then
    return a:timestamp() == b:timestamp()
  end
  -- Fall back to string comparison so numbers and strings can coexist
  return tostring(a) == tostring(b)
end

--- Add two values.  Handles string concatenation, number addition, and
--- Date + Duration arithmetic.
---@param a any
---@param b any
---@return any
function M.add_values(a, b)
  if type(a) == "string" or type(b) == "string" then
    return tostring(a or "") .. tostring(b or "")
  end
  if type(a) == "table" and a.plus and type(b) == "table" and b.to_seconds then
    return a:plus(b)
  end
  return (tonumber(a) or 0) + (tonumber(b) or 0)
end

--- Subtract two values.  Handles number subtraction, Date - Duration, and
--- Date - Date.
---@param a any
---@param b any
---@return any
function M.sub_values(a, b)
  if type(a) == "table" and a.minus then
    return a:minus(b)
  end
  return (tonumber(a) or 0) - (tonumber(b) or 0)
end

--- Check whether container `a` contains value `b`.
--- Works for arrays (element membership, including Link path matching) and
--- strings (substring search).
---@param a any
---@param b any
---@return boolean
function M.contains_value(a, b)
  if type(a) == "table" then
    for _, v in ipairs(a) do
      if M.compare_eq(v, b) then
        return true
      end
    end
    -- Link-aware secondary pass
    for _, v in ipairs(a) do
      if type(v) == "table" and v.path then
        if type(b) == "table" and b.path then
          if v.path == b.path then
            return true
          end
        elseif type(b) == "string" then
          if v.path == b or v.path:find(b, 1, true) then
            return true
          end
        end
      end
    end
    return false
  elseif type(a) == "string" then
    return a:find(tostring(b or ""), 1, true) ~= nil
  end
  return false
end

return M
