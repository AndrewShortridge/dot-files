--- js2lua/tokens.lua -- Token type constants for the JS-to-Lua transpiler.

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

return TK
