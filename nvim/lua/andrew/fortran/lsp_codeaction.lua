-- Quickfixes for the three things that make a Fortran MPI/OpenMP file wrong in
-- a way nothing on this machine reports: no `use omp_lib`, no `include
-- 'mpif.h'`, and a `call MPI_...` missing its mandatory trailing `ierror`.
--
-- WHY THESE ARE CODE ACTIONS AND NOT SNIPPETS
--
-- All three are edits at a position the user cannot see from where the cursor
-- is. The `include` belongs after the last `use` line of a header that may be
-- forty lines up; the `ierror` belongs before a closing paren that may be
-- three continuation lines down. A snippet inserts at the cursor, which is
-- exactly the wrong place in every case.
--
-- WHERE THE OFFER COMES FROM
--
-- Two sources, because clients differ. `params.context.diagnostics` carries
-- whatever the client decided was under the cursor -- which for nvim's
-- vim.lsp.buf.code_action is the diagnostics at the cursor LINE, and for a
-- programmatic buf_request_sync is frequently an empty list. So when the
-- context is empty the analysis is re-run (andrew.fortran.lsp_diagnostics
-- .compute, sharing the cached project signature index with the published
-- diagnostics) and filtered to the requested range. The offer is then the same
-- either way, which is the only way a quickfix is testable without a client.
--
-- EVERY ACTION IS A PURE `edit`
--
-- No `command`. A command is a second round trip through the server for an
-- edit that is fully known now, and it is the half of the protocol that nvim
-- applies with the fewest guarantees about ordering. `edit.changes[uri]` is
-- applied by vim.lsp.util.apply_workspace_edit with the client's own offset
-- encoding -- utf-8 here (see andrew.fortran.lsp), so the byte columns the
-- scanner produces need no conversion.
local M = {}

local scan = require("andrew.fortran.scan")
local IH = require("andrew.fortran.lsp_inlayhint")
local D = require("andrew.fortran.lsp_diagnostics")

M.KIND = "quickfix"

M.TITLE_OMP_LIB = "Add `!$ use omp_lib`"
M.TITLE_MPIF_H = "Add `include 'mpif.h'`"
M.TITLE_IERROR = "Add the missing `ierror` argument"

--- The default name for the status argument when the buffer offers no example.
M.DEFAULT_STATUS = "ierr"

-- ---------------------------------------------------------------------------
-- Buffer facts
-- ---------------------------------------------------------------------------

--- Is `pat` present on any raw line?
---
--- RAW, not masked: `include 'mpif.h'` has its string literal blanked by
--- scan.mask, and `!$ use omp_lib` is a comment to the masker. Both of the
--- things being looked for here are invisible in masked text.
---@param lines string[]
---@param pat string a Lua pattern, matched against the lowercased line
---@return boolean
local function any_line(lines, pat)
  for _, line in ipairs(lines) do
    if line:lower():find(pat) then
      return true
    end
  end
  return false
end

--- Does the buffer already say `use omp_lib`?
---@param lines string[]
---@return boolean
function M.has_omp_lib(lines)
  return any_line(lines, "%f[%w_]use%s+omp_lib%f[%W]")
end

--- Does the buffer already have an MPI binding in scope?
---
--- The `use` half is delegated to andrew.fortran.lsp_diagnostics so that the
--- spellings the diagnostic recognises (`use :: mpi_f08`, `use mpi, only: ...`)
--- are exactly the spellings that suppress the include quickfix. Offering
--- `include 'mpif.h'` to a buffer that already says `use mpi_f08` would put two
--- bindings of the same names in one scope, which is a hard error.
---@param lines string[]
---@return boolean
function M.has_mpi_binding(lines)
  return any_line(lines, "%f[%w_]include%s*['\"]%s*mpif%.h")
    or D.uses_module(lines, "mpi")
    or D.uses_module(lines, "mpi_f08")
end

--- Does the buffer carry an OpenMP sentinel at all?
---@param lines string[]
---@param fixed boolean
---@return boolean
function M.has_omp_directive(lines, fixed)
  for _, line in ipairs(lines) do
    if D.sentinel(line, fixed) then
      return true
    end
  end
  return false
end

--- Does the buffer reference any MPI name?
---@param buf_scan table
---@return boolean
function M.has_mpi_call(buf_scan)
  for _, masked in ipairs(buf_scan.masked) do
    if masked:find("%f[%w_]mpi_%a") then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Where a declaration goes
-- ---------------------------------------------------------------------------

--- The 1-based line a `use`/`include` statement should be inserted BEFORE.
---
--- After the program/module/subroutine/function header, after any `use` lines
--- already there, and before `implicit none` -- which is the one ordering
--- Fortran actually enforces: a USE statement must precede IMPLICIT, and
--- INCLUDE is expanded in place so it has to sit where its declarations are
--- legal. Blank and comment lines between the `use` statements are walked over
--- but never become the target, so the insertion lands against code.
---@param lines string[]
---@param buf_scan table
---@return integer lnum 1-based, integer header 1-based (0 when there is none)
function M.insert_point(lines, buf_scan)
  local header = 0
  for _, d in ipairs(buf_scan.defs) do
    local k = d.kind
    if k == "program" or k == "module" or k == "submodule" or k == "subroutine" or k == "function" then
      if header == 0 or d.lnum < header then
        header = d.lnum
      end
    end
  end

  local at = header + 1
  local target = at
  while at <= #lines do
    local masked = buf_scan.masked[at] or ""
    if masked:match("^%s*use%f[%W]") then
      at = at + 1
      target = at
    elseif masked:match("^%s*$") then
      at = at + 1
    else
      break
    end
  end
  return target, header
end

--- The indentation an inserted statement should carry.
---
--- Fixed form is not a style question: columns 1-6 are reserved, so a
--- statement starts at column 7 and a `!$` sentinel starts at column 1. Free
--- form copies whatever the surrounding code does.
---@param lines string[]
---@param target integer
---@param header integer
---@param fixed boolean
---@return string
function M.indent_for(lines, target, header, fixed)
  if fixed then
    return string.rep(" ", 6)
  end
  local ref = lines[target]
  local indent = ref and ref ~= "" and ref:match("^[ \t]*") or ""
  if indent == "" then
    indent = ((lines[header] or ""):match("^[ \t]*") or "") .. "  "
  end
  return indent
end

--- A whole-line insertion at `lnum` (1-based).
---@param uri string
---@param lnum integer
---@param text string
---@return table WorkspaceEdit
local function line_insert(uri, lnum, text)
  local pos = { line = lnum - 1, character = 0 }
  return { changes = { [uri] = { { range = { start = pos, ["end"] = pos }, newText = text .. "\n" } } } }
end

-- ---------------------------------------------------------------------------
-- The status-argument name
-- ---------------------------------------------------------------------------

--- What this buffer calls the MPI status argument.
---
--- The most common variable passed LAST to a correctly-formed MPI call, taken
--- from the raw line so the user's own casing survives (`IERR`, `ierr`,
--- `mpi_err` are all real in this corpus). A file with no correct call to copy
--- falls back to `ierr`, which is what every example in the registry uses.
---@param lines string[]
---@param buf_scan table
---@param sigs table
---@param fixed boolean
---@return string
function M.status_name(lines, buf_scan, sigs, fixed)
  local counts, order = {}, {}
  for _, site in ipairs(IH.call_sites(buf_scan, sigs)) do
    local entry = D.mpi_subroutine(site.lname)
    if entry then
      local slots, closed = IH.arg_slots(buf_scan.masked, site.lnum, site.open, fixed)
      local _, total = D.arity(entry)
      if closed and #slots == total and total > 0 then
        local last = slots[#slots]
        if last and not last.empty and last.text:match("^[%a_][%w_]*$") then
          local raw = lines[last.lnum] or ""
          local name = raw:sub(last.col, last.col + #last.text - 1)
          if name:match("^[%a_][%w_]*$") then
            if counts[name] == nil then
              counts[name] = 0
              order[#order + 1] = name
            end
            counts[name] = counts[name] + 1
          end
        end
      end
    end
  end

  local best, best_n = nil, 0
  for _, name in ipairs(order) do
    if counts[name] > best_n then
      best, best_n = name, counts[name]
    end
  end
  return best or M.DEFAULT_STATUS
end

-- ---------------------------------------------------------------------------
-- The ierror fix
-- ---------------------------------------------------------------------------

--- The edit that adds the missing status argument to the call the diagnostic
--- `d` points at.
---
--- The insertion point is the closing paren reported by arg_slots, NOT the end
--- of the diagnostic's line: a continued call closes somewhere below, and
--- appending to the head line would put the argument inside the first
--- continuation instead of at the end of the list.
---@param uri string
---@param buf_scan table
---@param fixed boolean
---@param d table the mpiArgumentCount diagnostic
---@param status string
---@return table|nil WorkspaceEdit
function M.ierror_edit(uri, buf_scan, fixed, d, status)
  local lnum = d.range.start.line + 1
  local name_col = d.range.start.character + 1
  local name_len = d.range["end"].character - d.range.start.character
  local masked = buf_scan.masked[lnum]
  if not masked or name_len <= 0 then
    return nil
  end
  local open = IH.paren_after(masked, name_col, name_len)
  if not open then
    return nil
  end
  local _, closed, close_lnum, close_col = IH.arg_slots(buf_scan.masked, lnum, open, fixed)
  if not closed or not close_lnum then
    return nil
  end
  local pos = { line = close_lnum - 1, character = close_col - 1 }
  return { changes = { [uri] = { { range = { start = pos, ["end"] = pos }, newText = ", " .. status } } } }
end

-- ---------------------------------------------------------------------------
-- Assembly
-- ---------------------------------------------------------------------------

--- Is this diagnostic an "ierror is missing" report?
---@param d table
---@return boolean
local function is_ierror(d)
  local data = d and d.data
  if type(data) ~= "table" or data.rule ~= "mpiArgumentCount" then
    return false
  end
  local missing = data.missing
  return type(missing) == "table" and #missing == 1 and tostring(missing[1]):lower() == "ierror"
end

--- Drop diagnostics that repeat a (code, range) already seen.
---
--- Both sources can produce the same report: a client that forwards the OpenMP
--- warning still leaves `ierror_diags` empty, which sends the provider down the
--- re-derivation path, which recomputes that same warning. Two entries in one
--- action's `diagnostics` array is one underline claimed twice -- nvim then
--- counts the action as fixing two problems.
---@param list table[]
---@return table[]
local function dedupe(list)
  local seen, out = {}, {}
  for _, d in ipairs(list) do
    local r = d.range or {}
    local s, e = r.start or {}, r["end"] or {}
    local key = table.concat({
      tostring(d.code),
      s.line or -1,
      s.character or -1,
      e.line or -1,
      e.character or -1,
    }, ":")
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = d
    end
  end
  return out
end

--- Diagnostics from `list` whose start line lies inside `range`.
---@param list table[]
---@param range table|nil
---@return table[]
local function in_range(list, range)
  if not range or not range.start then
    return list
  end
  local first = range.start.line
  local last = (range["end"] or range.start).line
  local out = {}
  for _, d in ipairs(list) do
    local line = d.range and d.range.start and d.range.start.line
    if line and line >= first and line <= last then
      out[#out + 1] = d
    end
  end
  return out
end

--- textDocument/codeAction.
---@param params table
---@param cb fun(err: table|nil, result: table[]|nil)
function M.actions(params, cb)
  local uri = params and params.textDocument and params.textDocument.uri
  if not uri then
    return cb(nil, nil)
  end
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return cb(nil, nil)
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local fixed = IH.is_fixed(bufnr, path)
  local buf_scan = scan.scan_lines(lines, { fixed = fixed })

  local ctx = (params.context or {}).diagnostics or {}
  local ierror_diags = {}
  local omp_diags = {}
  for _, d in ipairs(ctx) do
    if is_ierror(d) then
      ierror_diags[#ierror_diags + 1] = d
    elseif type(d.data) == "table" and d.data.rule == "ompDirectiveWithoutFlag" then
      omp_diags[#omp_diags + 1] = d
    end
  end

  -- `use mpi_f08` makes the trailing `ierror` OPTIONAL, so there is no missing
  -- argument to add there -- and a stale mpiArgumentCount forwarded by the
  -- client must not resurrect the offer.
  local f08 = D.mpi_binding(lines) == "mpi_f08"

  --- Build the answer once every diagnostic input is in hand.
  local function finish(sigs)
    local out = {}
    local target, header = M.insert_point(lines, buf_scan)
    omp_diags = dedupe(omp_diags)
    ierror_diags = f08 and {} or dedupe(ierror_diags)

    if M.has_omp_directive(lines, fixed) and not M.has_omp_lib(lines) then
      local indent = M.indent_for(lines, target, header, fixed)
      -- The sentinel MUST be in column 1 in fixed form, so the statement is
      -- pushed to column 7 by padding after `!$` rather than by indenting it.
      local text = fixed and ("!$" .. string.rep(" ", 4) .. "use omp_lib") or (indent .. "!$ use omp_lib")
      out[#out + 1] = {
        title = M.TITLE_OMP_LIB,
        kind = M.KIND,
        isPreferred = true,
        diagnostics = #omp_diags > 0 and omp_diags or nil,
        edit = line_insert(uri, target, text),
      }
    end

    if M.has_mpi_call(buf_scan) and not M.has_mpi_binding(lines) then
      local indent = M.indent_for(lines, target, header, fixed)
      out[#out + 1] = {
        title = M.TITLE_MPIF_H,
        kind = M.KIND,
        isPreferred = true,
        edit = line_insert(uri, target, indent .. "include 'mpif.h'"),
      }
    end

    if #ierror_diags > 0 then
      local status = M.status_name(lines, buf_scan, sigs or {}, fixed)
      for _, d in ipairs(ierror_diags) do
        local edit = M.ierror_edit(uri, buf_scan, fixed, d, status)
        if edit then
          out[#out + 1] = {
            title = M.TITLE_IERROR,
            kind = M.KIND,
            isPreferred = true,
            diagnostics = { d },
            edit = edit,
          }
        end
      end
    end

    cb(nil, out)
  end

  if #ierror_diags > 0 and not f08 then
    -- The client already told us what is wrong; the signature index is only
    -- needed to pick the status name, and call_sites over a seeded MPI table
    -- answers that without touching ripgrep.
    local sigs = {}
    local ok, mpi = pcall(require, "andrew.fortran.mpi")
    if ok then
      mpi.seed(sigs)
    end
    return finish(sigs)
  end

  -- No usable context: re-derive the diagnostics for this buffer and keep the
  -- ones inside the requested range, so `vim.lsp.buf.code_action` on the call
  -- line offers the fix whether or not the client forwards diagnostics.
  D.compute(bufnr, function(diags)
    for _, d in ipairs(in_range(diags, params.range)) do
      if is_ierror(d) then
        ierror_diags[#ierror_diags + 1] = d
      elseif type(d.data) == "table" and d.data.rule == "ompDirectiveWithoutFlag" then
        omp_diags[#omp_diags + 1] = d
      end
    end
    local sigs = {}
    local ok, mpi = pcall(require, "andrew.fortran.mpi")
    if ok then
      mpi.seed(sigs)
    end
    finish(sigs)
  end)
end

return M
