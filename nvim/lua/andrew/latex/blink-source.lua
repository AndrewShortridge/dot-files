-- =============================================================================
-- blink.cmp source: LaTeX math commands inside an equation
-- =============================================================================
-- Type `\` inside `$...$` / `$$...$$` (markdown) or anywhere in a .tex buffer
-- and get the command table from andrew.latex.symbols as completions, with
-- the Unicode glyph as the label description and a one-line doc.
--
-- Shape of the items, and why:
--   * `filterText` is the bare command name (+ aliases). blink's Rust fuzzy
--     matcher hard-codes the keyword charset to [\w-], so after `\al` the
--     keyword is `al`; scoring it against "alpha" rather than "\alpha" keeps
--     the backslash out of the match.
--   * `textEdit` spans from the `\` to the cursor, so accepting `\alpha`
--     replaces the `\` the user typed instead of producing `\\alpha`. blink
--     stamps `cursor_column` on every item at fetch time and shifts the
--     range end by however far the cursor has moved since
--     (lib/text_edits.lua compensate_for_cursor_movement), so the range stays
--     right while the user keeps typing after the initial `\` trigger.
--   * Entries with a `body` are LSP snippets (insertTextFormat = 2) expanded by
--     the luasnip preset; plain symbols insert `\cmd` verbatim. The source
--     inserts the COMMAND, never the glyph: snacks typesets the source text.
--   * Only offered when the token under the cursor starts with `\`. Bare
--     words inside math belong to the LuaSnip autosnippets (`sum`, `lim`,
--     `hat`, ...) in luasnippets/, and listing 300+ commands on every keyword
--     would bury the buffer/snippet items.
--
-- Fresh item tables per query, same reason as fortran/blink-source.lua:
-- blink mutates the items it is handed (score_offset accumulates,
-- cursor_column is frozen at first fetch).

local source = {}

-- LSP CompletionItemKind
local KIND = {
  greek = 21, -- Constant
  letterlike = 21,
  misc = 21,
  operator = 24, -- Operator
  bigop = 24,
  relation = 24,
  arrow = 24,
  delimiter = 24,
  spacing = 1, -- Text
  ["function"] = 3, -- Function
  accent = 15, -- Snippet
  structure = 15,
  font = 15,
  environment = 15,
}

local cached_items = nil ---@type table[]?

---@param e table  entry from andrew.latex.symbols
---@return table  item template (never handed to blink directly)
local function template(e)
  local label = e.label or ("\\" .. e.cmd)
  local filter = e.cmd
  if e.aliases then
    filter = filter .. " " .. table.concat(e.aliases, " ")
  end
  local doc = {}
  doc[#doc + 1] = ("`%s`%s"):format(label, e.glyph and ("  →  " .. e.glyph) or "")
  if e.doc then
    doc[#doc + 1] = ""
    doc[#doc + 1] = e.doc
  end
  if e.body then
    doc[#doc + 1] = ""
    doc[#doc + 1] = "```latex"
    -- tab stops out, LSP escapes (`\$` `\}` `\\`) collapsed, so the preview
    -- reads as the LaTeX that will land in the buffer.
    doc[#doc + 1] = (e.body:gsub("%$%d+", ""):gsub("\\([%$}\\])", "%1"):gsub("\t", "  "))
    doc[#doc + 1] = "```"
  end
  return {
    label = label,
    filterText = filter,
    kind = KIND[e.kind] or 1,
    glyph = e.glyph,
    newText = e.body or ("\\" .. e.cmd),
    insertTextFormat = e.body and 2 or 1,
    documentation = { kind = "markdown", value = table.concat(doc, "\n") },
  }
end

local function get_items()
  if cached_items then
    return cached_items
  end
  cached_items = {}
  for _, e in ipairs(require("andrew.latex.symbols")) do
    cached_items[#cached_items + 1] = template(e)
  end
  return cached_items
end

---Byte column (0-based) of the `\` that starts the command token ending at
---`col`, or nil when the cursor is not on a `\`-prefixed token.
---@param line string
---@param col number  0-based cursor column (bytes before the cursor)
---@return number?
function source.command_start(line, col)
  local before = line:sub(1, col)
  local pos = before:match("()\\%a*$")
  if not pos then
    return nil
  end
  -- `\\` is a line break, not the start of a command
  if pos > 1 and before:sub(pos - 1, pos - 1) == "\\" then
    return nil
  end
  return pos - 1
end

function source.new(opts)
  local self = setmetatable({}, { __index = source })
  self.opts = opts or {}
  return self
end

function source:enabled()
  local ft = vim.bo.filetype
  if ft == "tex" or ft == "plaintex" then
    return true
  end
  if ft == "markdown" then
    return require("andrew.utils.tex").in_mathzone()
  end
  return false
end

function source:get_trigger_characters()
  return { "\\" }
end

function source:get_completions(ctx, callback)
  local start = source.command_start(ctx.line, ctx.cursor[2])
  if not start then
    return callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
  end
  local row0 = ctx.cursor[1] - 1
  local range = {
    start = { line = row0, character = start },
    ["end"] = { line = row0, character = ctx.cursor[2] },
  }
  local items = {}
  for i, t in ipairs(get_items()) do
    items[i] = {
      label = t.label,
      labelDetails = t.glyph and { description = t.glyph } or nil,
      filterText = t.filterText,
      kind = t.kind,
      insertTextFormat = t.insertTextFormat,
      textEdit = { newText = t.newText, range = range },
      documentation = t.documentation,
    }
  end
  callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
end

function source:resolve(item, callback)
  callback(item)
end

return source
