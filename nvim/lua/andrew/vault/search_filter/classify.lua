--- AST node classification for search filter pipeline.

local M = {}

--- Leaf types evaluated against the vault index (no content search needed).
M.METADATA_TYPES = {
  field = true,
  has = true,
  task = true,
  graph = true,
}

--- Leaf types requiring content search via ripgrep.
M.TEXT_TYPES = {
  text = true,
  regex = true,
}

--- Classify whether a subtree is purely metadata, purely text, or mixed.
--- Accepts an optional cache table keyed by node identity (table reference)
--- to memoize results across calls and avoid redundant traversals.
---@param node table|nil AST node
---@param cache table|nil optional memoization table (node → classification)
---@return string "metadata"|"text"|"mixed"
function M.classify(node, cache)
  if not node then return "metadata" end
  if cache and cache[node] then return cache[node] end

  local result
  local t = node.type
  if M.METADATA_TYPES[t] then
    result = "metadata"
  elseif M.TEXT_TYPES[t] then
    result = "text"
  elseif t == "not" then
    result = M.classify(node.operand, cache)
  elseif t == "and" or t == "or" then
    local lc = M.classify(node.left, cache)
    local rc = M.classify(node.right, cache)
    if lc == rc then
      result = lc
    else
      result = "mixed"
    end
  else
    result = "text" -- unreachable: all node types handled above; satisfies Lua return requirement
  end

  if cache then cache[node] = result end
  return result
end

return M
