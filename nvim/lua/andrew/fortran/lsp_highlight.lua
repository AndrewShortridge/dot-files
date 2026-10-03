-- textDocument/documentHighlight for Fortran, over the line scanner.
--
-- WHY THIS EXISTS
--
-- fortls 3.2.2 does not advertise documentHighlight, so in a Fortran buffer
-- `]]` / `[[` / `<a-n>` / `<a-p>` are never bound (andrew.lsp_keymaps gates
-- them on the capability) and Snacks.words never lights up the word under the
-- cursor. andrew.fortran.lsp supplies the capability; this module supplies the
-- answer.
--
-- WHY SCOPED TO THE PROGRAM UNIT
--
-- The naive answer -- every occurrence of the word in the file -- is actively
-- wrong for the F77-descended code this config is aimed at. Main.f90 in the
-- project this was built against is 522 lines holding a dozen subroutines,
-- every one of which declares its own `I`, `J`, `NNODE`. Highlighting the `I`
-- of one loop across the whole file would light up ten unrelated subroutines
-- and make `]]` jump into a different procedure. So the answer is restricted
-- to the innermost enclosing program unit, found with the SAME open/close
-- logic scan.nesting_depths uses: `end if` and `end do` close a construct, a
-- bare `end` (which is all F77 writes) closes a unit.
--
-- This is scoping by NESTING, not by declaration: a name used in a subroutine
-- that is really a COMMON-block global still highlights only within that
-- subroutine. That is the conservative direction -- it under-reports rather
-- than dragging in unrelated variables that happen to share a spelling, which
-- is exactly what implicit typing makes common.
--
-- WHY THE CURSOR TOKEN COMES FROM THE MASKED LINE
--
-- scan.mask blanks comments and string literals length-preservingly, so
-- looking the cursor token up in the masked line means a cursor sitting in a
-- comment finds no identifier and the request answers nothing -- no argument
-- needed about whether prose words should highlight. Columns are unchanged by
-- masking, so the positions map straight back into the raw line.
--
-- WHY KEYWORDS ARE DROPPED
--
-- Fortran reserves nothing, so `if`, `do` and `end` are ordinary identifier
-- tokens to the scanner. Lighting up every `if` in a subroutine (and putting
-- `]]` on them) is noise, so a token that is only a keyword answers nothing --
-- unless the unit actually declares something by that name, in which case it
-- is a variable and gets the normal treatment.
--
-- PERFORMANCE
--
-- This fires on every cursor movement via Snacks.words. A 522-line scan per
-- CursorMoved is the regression pattern this config has hit repeatedly, so
-- everything derived from the buffer text is cached against its changedtick
-- and the per-line identifier tokenisation is done lazily, only for the lines
-- of the unit the cursor is actually in.

local M = {}

local scan = require("andrew.fortran.scan")
local keywords = require("andrew.fortran.keywords")
local lsp = require("andrew.fortran.lsp")

-- LSP DocumentHighlightKind.
local TEXT, WRITE, READ = 1, 2, 3
M.KIND = { text = TEXT, write = WRITE, read = READ }

-- Same set scan.nesting_depths counts by: constructs (`if`, `do`, `select`,
-- `block`) are deliberately absent, because `end if` must not close a
-- subroutine.
local UNIT_END_KEYWORDS = {
  program = true, module = true, submodule = true, subroutine = true,
  ["function"] = true, type = true, interface = true,
}

local KEYWORD_SET = keywords.set()

-- ---------------------------------------------------------------------------
-- Program units
-- ---------------------------------------------------------------------------

--- Line spans of every program unit, innermost first.
---
--- Ordered by the line that CLOSES each unit, which is what makes "innermost
--- first" true: a nested unit is always closed before the unit containing it,
--- so the first span in this list that contains a line is the tightest one.
--- Units left open at end of file (a truncated buffer, or a `.h` include full
--- of declarations) run to the last line.
---@param masked_lines string[]
---@param defs table[] scanner definition records
---@return { first: integer, last: integer }[]
function M.unit_spans(masked_lines, defs)
  local opens = {}
  for _, d in ipairs(defs or {}) do
    if UNIT_END_KEYWORDS[d.kind] then
      opens[d.lnum] = (opens[d.lnum] or 0) + 1
    end
  end

  local spans, stack = {}, {}
  for lnum, masked in ipairs(masked_lines) do
    local endkw = masked:match("^%s*end%s*([%a_]*)")
    local closes = endkw ~= nil and (endkw == "" or UNIT_END_KEYWORDS[endkw])

    if closes then
      local first = table.remove(stack)
      if first then
        spans[#spans + 1] = { first = first, last = lnum }
      end
    else
      -- An unnamed or abstract `interface` opens a unit that no definition
      -- record marks, but `end interface` will close one.
      local unnamed_interface = masked:match("^%s*interface%s*$")
        or masked:match("^%s*abstract%s+interface%s*$")
      local n = (opens[lnum] or 0) + (unnamed_interface and 1 or 0)
      for _ = 1, n do
        stack[#stack + 1] = lnum
      end
    end
  end

  -- Whatever is still open runs to the end, innermost (top of stack) first.
  for i = #stack, 1, -1 do
    spans[#spans + 1] = { first = stack[i], last = #masked_lines }
  end

  return spans
end

--- First and last line of the innermost program unit containing `lnum`.
--- Falls back to the whole buffer when the line is outside every unit -- an
--- include file of bare COMMON blocks has no unit at all, and answering
--- nothing there would be worse than answering file-wide.
---@param masked_lines string[]
---@param defs table[] scanner definition records
---@param lnum integer 1-based
---@return integer first, integer last
function M.unit_range(masked_lines, defs, lnum)
  for _, span in ipairs(M.unit_spans(masked_lines, defs)) do
    if span.first <= lnum and lnum <= span.last then
      return span.first, span.last
    end
  end
  return 1, #masked_lines
end

-- ---------------------------------------------------------------------------
-- Read / write classification
-- ---------------------------------------------------------------------------

--- Parenthesis nesting depth immediately before `col` on a masked line.
---@param masked string
---@param col integer
---@return integer
local function depth_before(masked, col)
  local depth = 0
  for i = 1, col - 1 do
    local ch = masked:sub(i, i)
    if ch == "(" or ch == "[" then
      depth = depth + 1
    elseif ch == ")" or ch == "]" then
      depth = depth - 1
    end
  end
  return depth
end

--- True when the token at (col, len) is the target of an assignment.
---
--- The token must sit at paren depth 0 -- that single test disposes of the
--- whole family of `=` signs that are not assignments: `real(kind=8) :: x`,
--- `open(unit=7, file=...)`, `call sub(n=3)` and every other keyword argument
--- lives inside parentheses.
---
--- Past the name an arbitrary run of parenthesised subscripts is allowed
--- (`grid(i,j) = 0`, `s(1:3)(2:2) = 'x'`), then the next non-blank byte must
--- be a `=` that does not begin `==`. The other comparison operators need no
--- test of their own: `/=`, `<=` and `>=` put their first character where the
--- `=` would have to be. `=>` IS an assignment (pointer association), so only
--- a following `=` disqualifies.
---@param masked string
---@param col integer 1-based
---@param len integer
---@return boolean
function M.is_assignment_target(masked, col, len)
  if depth_before(masked, col) ~= 0 then
    return false
  end

  local i = col + len
  while true do
    local _, e = masked:find("^%s*%b()", i)
    if not e then
      break
    end
    i = e + 1
  end

  local j = masked:match("^%s*()", i)
  if masked:sub(j, j) ~= "=" then
    return false
  end
  return masked:sub(j + 1, j + 1) ~= "="
end

-- ---------------------------------------------------------------------------
-- Per-buffer analysis, cached against changedtick
-- ---------------------------------------------------------------------------

---@type table<integer, table>
local cache = {}

--- Drop every cached analysis. Exported for the spec; nothing in normal
--- operation needs it, because changedtick invalidates entries on its own.
function M.reset_cache()
  cache = {}
end

--- The scan of `bufnr`, plus the sets derived from it, for the current
--- changedtick. Recomputed only when the buffer text changes.
---@param bufnr integer
---@return table
local function analysis(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = cache[bufnr]
  if entry and entry.tick == tick then
    return entry
  end

  -- A buffer that has been wiped never comes back; its entry would otherwise
  -- live as long as the session.
  for buf in pairs(cache) do
    if not vim.api.nvim_buf_is_valid(buf) then
      cache[buf] = nil
    end
  end

  local data = scan.scan_buffer(bufnr)

  -- "lnum:col" of every declared name, so a declaration can be reported as a
  -- write without re-deciding what a declaration looks like.
  local decl_at = {}
  -- Names the file declares or defines, which is what rescues a variable
  -- called `type` or `data` from the keyword filter.
  local declared = {}
  for _, d in ipairs(data.decls) do
    decl_at[d.lnum .. ":" .. d.col] = true
    declared[d.lname] = true
  end
  for _, d in ipairs(data.defs) do
    declared[d.lname] = true
  end

  entry = {
    tick = tick,
    scan = data,
    decl_at = decl_at,
    declared = declared,
    tokens = {},
    spans = nil,
  }
  cache[bufnr] = entry
  return entry
end

--- Identifier tokens of one line, tokenised at most once per changedtick.
---@param entry table
---@param lnum integer
---@return { lname: string, col: integer }[]
local function tokens_of(entry, lnum)
  local toks = entry.tokens[lnum]
  if not toks then
    toks = scan.identifiers(entry.scan.masked[lnum] or "")
    entry.tokens[lnum] = toks
  end
  return toks
end

--- Innermost unit range, memoised per changedtick (the span list is one walk
--- of the whole file, and the cursor stays inside one unit for many moves).
---@param entry table
---@param lnum integer
---@return integer first, integer last
local function unit_range_cached(entry, lnum)
  if not entry.spans then
    entry.spans = M.unit_spans(entry.scan.masked, entry.scan.defs)
  end
  for _, span in ipairs(entry.spans) do
    if span.first <= lnum and lnum <= span.last then
      return span.first, span.last
    end
  end
  return 1, #entry.scan.masked
end

-- ---------------------------------------------------------------------------
-- The request
-- ---------------------------------------------------------------------------

--- Answer textDocument/documentHighlight.
---
--- Synchronous: andrew.fortran.lsp's dispatcher hands the return value
--- straight to the RPC callback.
---@param params { textDocument: { uri: string }, position: { line: integer, character: integer } }
---@return table[]|nil highlights DocumentHighlight[], or nil when there is nothing to say
function M.highlight(params)
  local uri = params and params.textDocument and params.textDocument.uri
  local position = params and params.position
  if not uri or not position then
    return nil
  end

  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      return nil
    end
  end

  local lnum, col = lsp.from_pos(position)
  local entry = analysis(bufnr)
  local masked = entry.scan.masked[lnum]
  if not masked then
    return nil
  end

  -- The token under the cursor, taken from the MASKED line so a comment or a
  -- string literal holds no identifiers at all.
  local target
  for _, tok in ipairs(tokens_of(entry, lnum)) do
    if tok.col <= col and col < tok.col + #tok.lname then
      target = tok.lname
      break
    end
    if tok.col > col then
      break
    end
  end
  if not target then
    return nil
  end
  if KEYWORD_SET[target] and not entry.declared[target] then
    return nil
  end

  local first, last = unit_range_cached(entry, lnum)
  local len = #target
  local out = {}
  for l = first, last do
    local line = entry.scan.masked[l]
    for _, tok in ipairs(tokens_of(entry, l)) do
      if tok.lname == target then
        local kind = READ
        if entry.decl_at[l .. ":" .. tok.col] or M.is_assignment_target(line, tok.col, len) then
          kind = WRITE
        end
        out[#out + 1] = { range = lsp.name_range(l, tok.col, len), kind = kind }
      end
    end
  end

  if #out == 0 then
    return nil
  end
  return out
end

return M
