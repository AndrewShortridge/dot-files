--- AST splitting for search filter pipeline.
--- Separates metadata-only and text-only portions of a query AST.

local M = {}

local classify_mod = require("andrew.vault.search_filter.classify")
local classify = classify_mod.classify
local METADATA_TYPES = classify_mod.METADATA_TYPES
local TEXT_TYPES = classify_mod.TEXT_TYPES

--- Generic AST extraction: walk the boolean tree, keeping only nodes for
--- which keep_fn returns true. keep_fn(node, cache) should return:
---   true  → keep this leaf as-is
---   false → drop this leaf (not relevant to this extraction)
---   nil   → not a leaf, continue recursive traversal
---@param node table|nil AST node
---@param keep_fn fun(node: table, cache: table|nil): boolean|nil
---@param cache table|nil classification cache
---@return table|nil extracted AST with boolean structure preserved
local function extract_ast(node, keep_fn, cache)
  if not node then return nil end
  local keep = keep_fn(node, cache)
  if keep == true then return node end
  if keep == false then return nil end

  local t = node.type
  if t == "not" then
    local inner = extract_ast(node.operand, keep_fn, cache)
    if inner then return { type = "not", operand = inner } end
    return nil
  end

  if t == "and" then
    local la = extract_ast(node.left, keep_fn, cache)
    local ra = extract_ast(node.right, keep_fn, cache)
    if la and ra then return { type = "and", left = la, right = ra } end
    return la or ra
  end

  if t == "or" then
    local la = extract_ast(node.left, keep_fn, cache)
    local ra = extract_ast(node.right, keep_fn, cache)
    if la and ra then return { type = "or", left = la, right = ra } end
    -- If one side is nil, the OR cannot be safely evaluated for this
    -- extraction (text side: nil means "matches everything" → no constraint;
    -- metadata side: nil means partial OR is unsound).
    return nil
  end

  return nil
end

--- Extract the text-only portion of an AST, preserving boolean structure.
--- Metadata nodes are dropped (they impose no text constraint).
--- For OR: if one side has no text constraint, the whole OR has none
--- (that side matches everything, so OR with anything is always true for text).
---@param node table|nil AST node
---@return table|nil text-only AST with boolean structure preserved
local function extract_text_ast(node, cache)
  return extract_ast(node, function(n, c)
    local cls = c and c[n] or nil
    if cls then
      if cls == "text" then return true end
      if cls == "metadata" then return false end
      return nil
    end
    local t = n.type
    if TEXT_TYPES[t] then return true end
    if METADATA_TYPES[t] then return false end
    return nil
  end, cache)
end

--- Extract the metadata-only portion of an AST, dropping text/regex leaves.
--- For AND nodes with mixed children, only the metadata side is kept.
--- For OR nodes, both sides must be metadata or the whole subtree is nil.
---@param node table|nil AST node
---@param cache table|nil classification cache from split_ast
---@return table|nil metadata-only AST
local function extract_metadata_ast(node, cache)
  return extract_ast(node, function(n, c)
    local cls = c and c[n] or classify(n, c)
    if cls == "metadata" then return true end
    if cls == "text" then return false end
    return nil
  end, cache)
end

--- Split a query AST into a metadata-only tree and a text-only tree.
--- Returns a table with:
---   - metadata_ast: AST containing only metadata nodes (or nil)
---   - text_ast:     AST containing only text/regex nodes with boolean structure (or nil)
---   - mode:         "metadata_only"|"text_only"|"metadata_then_text"|"mixed_or"
---
---@param ast table|nil parsed query AST from search_query.parse_query()
---@return table { metadata_ast, text_ast, mode }
function M.split_ast(ast)
  if not ast then
    return { metadata_ast = nil, text_ast = nil, mode = "text_only" }
  end

  -- match_all: query was only directives (e.g., group:) with no filters
  if ast.type == "match_all" then
    return { metadata_ast = nil, text_ast = nil, mode = "metadata_only", match_all = true }
  end

  -- Build classification cache once; reused by extract_metadata_ast to avoid re-traversal
  local cache = {}
  local cls = classify(ast, cache)

  if cls == "metadata" then
    return { metadata_ast = ast, text_ast = nil, mode = "metadata_only" }
  end

  if cls == "text" then
    return { metadata_ast = nil, text_ast = ast, mode = "text_only" }
  end

  -- Mixed: strategy depends on the top-level combiner
  local t = ast.type

  if t == "and" then
    local meta = extract_metadata_ast(ast, cache)
    local text = extract_text_ast(ast, cache)
    if meta and text then
      return { metadata_ast = meta, text_ast = text, mode = "metadata_then_text" }
    elseif meta then
      return { metadata_ast = meta, text_ast = nil, mode = "metadata_only" }
    else
      return { metadata_ast = nil, text_ast = text, mode = "text_only" }
    end
  end

  if t == "or" then
    local meta = extract_metadata_ast(ast, cache)
    local text = extract_text_ast(ast, cache)
    return { metadata_ast = meta, text_ast = text, mode = "mixed_or" }
  end

  if t == "not" then
    local meta = extract_metadata_ast(ast, cache)
    local text = extract_text_ast(ast, cache)
    if meta and text then
      return { metadata_ast = meta, text_ast = text, mode = "metadata_then_text" }
    elseif meta then
      return { metadata_ast = meta, text_ast = nil, mode = "metadata_only" }
    else
      return { metadata_ast = nil, text_ast = text, mode = "text_only" }
    end
  end

  -- Fallback
  return { metadata_ast = nil, text_ast = extract_text_ast(ast, cache), mode = "text_only" }
end

return M
