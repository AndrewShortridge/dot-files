--- DQL source parser: FROM clause logic.
---
--- Parses source filters (folder paths, tags, negation, boolean combinations).

local tokenizer = require("andrew.vault.query.parser.tokenizer")
local TK = tokenizer.TK
local KEYWORDS = tokenizer.KEYWORDS

local M = {}

local parse_source, parse_source_atom

--- source = source_atom (("AND"|"OR") source_atom)*
parse_source = function(P)
  local left, err = parse_source_atom(P)
  if not left then return nil, err end
  while P:peek().type == "AND" or P:peek().type == "OR" do
    local op_tok = P:advance()
    local right
    right, err = parse_source_atom(P)
    if not right then return nil, err end
    left = {
      type = op_tok.type == "AND" and "and" or "or",
      left = left,
      right = right,
    }
  end
  return left
end

--- source_atom = string_literal        -- folder: "Projects"
---            | "#" tag_path           -- tag: #project/active
---            | "!" source_atom        -- negation
---            | "(" source ")"         -- grouping
parse_source_atom = function(P)
  local tok = P:peek()

  -- Folder path: quoted string
  if tok.type == TK.STRING then
    P:advance()
    return { type = "folder", path = tok.value }
  end

  -- Tag: # followed by tag_path (ident ("/" ident)*)
  if tok.type == TK.HASH then
    P:advance()
    local seg = P:peek()
    if seg.type ~= TK.IDENT and not KEYWORDS[seg.type] then
      return nil, P:error("Expected tag name after '#'")
    end
    P:advance()
    local parts = { seg.value }
    while P:peek().type == TK.SLASH do
      P:advance() -- consume "/"
      seg = P:peek()
      if seg.type ~= TK.IDENT and not KEYWORDS[seg.type] then
        return nil, P:error("Expected tag segment after '/'")
      end
      P:advance()
      parts[#parts + 1] = seg.value
    end
    return { type = "tag", tag = table.concat(parts, "/") }
  end

  -- Negation
  if tok.type == TK.BANG or tok.type == "NOT" then
    P:advance()
    local operand, err = parse_source_atom(P)
    if not operand then return nil, err end
    return { type = "not", operand = operand }
  end

  -- Grouped source
  if tok.type == TK.LPAREN then
    P:advance()
    local src, err = parse_source(P)
    if not src then return nil, err end
    local _, perr = P:expect(TK.RPAREN)
    if perr then return nil, perr end
    return src
  end

  return nil, P:error("Expected source (quoted path, #tag, !, or parenthesized source)")
end

M.parse_source = parse_source

return M
