-- Tagging compiler "declared but never used" warnings as DiagnosticTag.Unnecessary.
--
-- WHY THIS EXISTS
--
-- gfortran already reports unused variables under -Wall, and the Fortran
-- linter in lua/andrew/plugins/linting.lua already parses that output --
-- `-fdiagnostics-plain-output` is in its argument list, so every warning
-- arrives as a single `file:line:col: Warning: ...` line that parsers.gcc
-- matches cleanly. The information was simply being discarded: the diagnostic
-- was built with a severity and a message and nothing else, so an unused
-- variable looked exactly like any other warning.
--
-- An LSP server would report this with DiagnosticTag.Unnecessary (value 1) and
-- the editor would dim the name in place. That is the effect we want, and
-- Neovim can produce it -- but NOT through the field an LSP server would use.
--
-- THE FIELD IS `_tags`, NOT `tags`
--
-- `tags` is the LSP WIRE spelling. The only thing that understands it is
-- vim/lsp/diagnostic.lua's tags_lsp_to_vim, which translates it into `_tags`
-- on the way in from a server. nvim-lint never goes through that path -- it
-- calls vim.diagnostic.set directly -- so a `tags = { 1 }` field is inert and
-- is silently dropped. The renderer reads:
--
--     vim/diagnostic.lua:1835   if diagnostic._tags then
--     vim/diagnostic.lua:1836     if diagnostic._tags.unnecessary then
--
-- so `_tags = { unnecessary = true }` is what actually reaches
-- DiagnosticUnnecessary.
--
-- THE SPAN HAS TO BE RECOVERED
--
-- gfortran's caret points at the LAST byte of the offending name, not the
-- first:
--
--       REAL*8 A, UNUSEDV
--                       ^ col 23, and the name starts at col 17
--
-- and the linter supplies no `end_col`, so vim.diagnostic collapses the range
-- to a single byte. Underline/dim on one byte of a nine-byte name is
-- invisible, which would make the tag look like it had not worked at all. The
-- name is quoted in the message, so the span is recoverable: take its length
-- back from the caret, and confirm against the source line when one is
-- available.
local M = {}

--- gfortran warning flags that mean "declared/assigned and never used".
--- Only flags whose subject is a NAME belong here -- the span recovery below
--- depends on the message quoting one.
M.FLAGS = {
  ["-Wunused-variable"] = true,
  ["-Wunused-dummy-argument"] = true,
  ["-Wunused-parameter"] = true,
  ["-Wunused-label"] = true,
  ["-Wunused-function"] = true,
  ["-Wunused-const-variable"] = true,
}

-- Compilers that do not print a flag in brackets. Matched on the message text
-- itself, anchored so a message merely CONTAINING the word "unused" (for
-- instance an error about an unused-but-required interface) is not swept in.
--   gfortran  Unused variable 'x' declared at (1)
--   nagfor    Unused local variable X
--   ifort     This variable has not been used
local TEXT_PATTERNS = {
  "^Unused ",
  "^Unused$",
  "has not been used",
  "is never used",
}

--- The `-Wxxx` flag gcc appends in brackets, or nil.
---@param msg string
---@return string|nil
function M.flag(msg)
  return msg:match("%[(%-W[%w%-]+)%]%s*$")
end

--- Does this compiler message report an unused name?
---
--- The flag is authoritative when present: gcc prints it for every warning, so
--- a message WITH a bracketed flag that is not in M.FLAGS is definitively not
--- an unused-name warning and must not fall through to the text patterns
--- (`-Wmaybe-uninitialized` says "is used uninitialized", which contains
--- neither pattern, but `-Wunused-value` -- deliberately absent from M.FLAGS
--- because it names no identifier -- would otherwise slip through).
---@param msg string
---@return boolean
function M.is_unused(msg)
  if type(msg) ~= "string" then
    return false
  end
  local flag = M.flag(msg)
  if flag then
    return M.FLAGS[flag] == true
  end
  for _, pat in ipairs(TEXT_PATTERNS) do
    if msg:find(pat) then
      return true
    end
  end
  return false
end

--- The identifier a compiler quoted in its message, or nil.
---
--- Three quoting styles, all of which gfortran has shipped: U+2018/U+2019
--- typographic quotes (the default in a UTF-8 locale, and what
--- -fdiagnostics-plain-output still emits), the older `name' pair, and plain
--- ASCII apostrophes under LC_ALL=C.
---@param msg string
---@return string|nil
function M.quoted_name(msg)
  local name = msg:match("\226\128\152([%a_][%w_]*)\226\128\153")
    or msg:match("`([%a_][%w_]*)'")
    or msg:match("'([%a_][%w_]*)'")
  return name
end

--- Case-insensitive equality for a slice of `line`.
---@param line string
---@param first integer 1-based, inclusive
---@param last integer 1-based, inclusive
---@param name string
---@return boolean
local function slice_is(line, first, last, name)
  if first < 1 or last > #line then
    return false
  end
  return line:sub(first, last):lower() == name:lower()
end

--- Recover the source span of the name an unused-warning is about.
---
--- Returns 1-based columns with `stop` EXCLUSIVE, matching how the caller then
--- converts to vim.diagnostic's 0-based `col`/`end_col`.
---
--- The caret is treated as the last byte of the name, which is what gfortran
--- emits; when a source line is supplied that guess is verified before it is
--- used, and a case-insensitive search of the line is the fallback (gfortran
--- lowercases the name in the message, so the comparison cannot be exact).
--- With no line to check against, the arithmetic is returned unverified --
--- which is the situation in the workspace lint, where the diagnostic belongs
--- to a file that may not be loaded.
---@param msg string
---@param line string|nil the source line, when available
---@param caret integer 1-based column reported by the compiler
---@return integer|nil start, integer|nil stop
function M.name_span(msg, line, caret)
  local name = M.quoted_name(msg)
  if not name or type(caret) ~= "number" then
    return nil, nil
  end
  local guess = caret - #name + 1
  if not line then
    if guess < 1 then
      return nil, nil
    end
    return guess, caret + 1
  end
  if slice_is(line, guess, caret, name) then
    return guess, caret + 1
  end
  -- The caret was somewhere else (a continued statement, a COMMON member
  -- reported at the block, a compiler that points at the first byte). Fall
  -- back to the first whole-word occurrence on the line.
  local lower, lname = line:lower(), name:lower()
  local init = 1
  while true do
    local s, e = lower:find(lname, init, true)
    if not s then
      return nil, nil
    end
    local before = line:sub(s - 1, s - 1)
    local after = line:sub(e + 1, e + 1)
    if not before:match("[%w_]") and not after:match("[%w_]") then
      return s, e + 1
    end
    init = s + 1
  end
end

--- Tag a diagnostic in place when its message reports an unused name.
---
--- `diag` is a vim.diagnostic entry: 0-based `lnum`/`col`, and the compiler's
--- 1-based caret column is therefore `diag.col + 1`. Returns the same table so
--- it can be used inline.
---@param diag table
---@param line string|nil the source line, when available
---@return table diag
function M.tag(diag, line)
  if not M.is_unused(diag.message) then
    return diag
  end
  diag._tags = diag._tags or {}
  diag._tags.unnecessary = true
  local first, stop = M.name_span(diag.message, line, (diag.col or 0) + 1)
  if first then
    diag.col = first - 1
    diag.end_lnum = diag.lnum
    diag.end_col = stop - 1
  end
  return diag
end

--- The source line for a diagnostic, or nil when the buffer cannot supply one.
---@param bufnr integer|nil
---@param lnum integer 0-based
---@return string|nil
function M.buf_line(bufnr, lnum)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return (vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false))[1]
end

return M
