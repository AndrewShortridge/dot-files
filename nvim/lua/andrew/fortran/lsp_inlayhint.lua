-- Inlay hints for Fortran call sites: the callee's dummy-argument names,
-- shown against the actual arguments.
--
--       CALL HEATING(depth:A, temp:N)
--
-- WHY THIS IS WORTH MORE IN FORTRAN THAN ANYWHERE ELSE
--
-- Fortran 77 has no keyword arguments. Every call is positional, argument
-- intent is invisible at the call site, and the legacy trees this config is
-- aimed at routinely pass eight or ten scalars into a subroutine defined in
-- another file. Reading `CALL DIFFUSE(N, DT, F, T, Q, W, 0, 1)` tells you
-- nothing at all without opening diffuse.f. In Python the same feature is a
-- convenience; here it is the difference between reading a call and guessing.
--
-- fortls does not advertise inlayHintProvider, so this is additive: it can
-- never collide with it (see "THE ONE DESIGN RULE" in andrew.fortran.lsp).
--
-- HOW THE SIGNATURES ARE FOUND
--
-- One ripgrep pass for `subroutine|function`, grouped by file, each file read
-- once. Every hit line is re-scanned by the SAME code that scans a buffer
-- (scan._scan_definitions for the procedure name, scan._scan_declarations for
-- its dummy arguments), so a header inside a comment or a string is dropped
-- for free, and continued headers are followed to their end.
--
-- WHY `NAME(` IS FILTERED BY THE SIGNATURE INDEX
--
-- Fortran spells a function call and an array reference identically:
-- `Heating(t)` and `arr(i)` are the same syntax, and no amount of local
-- analysis separates them. The only sound filter is "is NAME a procedure this
-- project defines", which is exactly what the signature index answers. A local
-- array sharing a name with a procedure defined elsewhere will still get
-- hints; that is the same trade scan.project_calls already makes, and it is
-- the price of not having a type system.
local M = {}

local scan = require("andrew.fortran.scan")

--- LSP InlayHintKind.Parameter.
M.KIND_PARAMETER = 2

--- LSP InlayHintKind.Type -- the return-type hints.
M.KIND_TYPE = 1

--- Which hint families are enabled.
---
--- `vim.g.fortran_inlay_hints` is ABSENT by default and both families are on.
--- The table is read as a set of OVERRIDES, not as an exhaustive statement: a
--- field that is missing keeps its default, which is on. The two families are
--- independent (argument names annotate a call's actual arguments, return
--- types annotate its value), so `{ argument_names = false }` has to mean
--- "keep the return types" -- reading it as "turn everything else off as well"
--- silently disables a feature the user never mentioned.
---
--- `vim.g.fortran_inlay_hints = false` is the way to turn BOTH off. That
--- leaves the inlayHint capability advertised, so <leader>uh keeps working.
---@return { argument_names: boolean, return_types: boolean }
function M.settings()
  local g = vim.g.fortran_inlay_hints
  -- `0` as well as `false`, because a vimscript `let g:fortran_inlay_hints = 0`
  -- arrives here as a number.
  if g == false or g == 0 then
    return { argument_names = false, return_types = false }
  end
  if type(g) ~= "table" then
    return { argument_names = true, return_types = true }
  end
  local function on(v)
    return v ~= false and v ~= 0
  end
  return { argument_names = on(g.argument_names), return_types = on(g.return_types) }
end

--- How many lines a single continued statement may span before the walk gives
--- up. Real headers and calls run to a dozen continuations at the outside; the
--- cap exists so an unbalanced paren cannot walk the whole file.
M.MAX_CONTINUATION = 40

-- ---------------------------------------------------------------------------
-- Source form
-- ---------------------------------------------------------------------------

--- Extensions that mean fixed source form. Everything else -- .f90 and its
--- successors -- is free form. Listed rather than pattern-matched: `.fpp` is
--- fixed and `.f95` is free, and no readable pattern separates them.
M.FIXED_EXTENSIONS = { f = true, ["for"] = true, ftn = true, fpp = true, f77 = true }

--- Is this a fixed-form continuation line?
---
--- Fixed form reserves columns 1-5 for a statement label and column 6 for the
--- continuation marker: any character there other than a blank or `0` means
--- "this line continues the previous statement".
---@param line string
---@return boolean
function M.is_fixed_continuation(line)
  if #line < 6 then
    return false
  end
  if not line:sub(1, 5):match("^%s*$") then
    return false
  end
  local c = line:sub(6, 6)
  return c ~= " " and c ~= "0" and c ~= "\t" and c ~= ""
end

--- Does a free-form line continue? Returns the last statement column too, so
--- the trailing `&` is not scanned as part of an argument.
---@param line string
---@return integer last, boolean continues
function M.free_extent(line)
  local amp = line:match("()&%s*$")
  if amp then
    return amp - 1, true
  end
  return #line, false
end

--- Is this file fixed form?
---@param bufnr integer|nil
---@param path string|nil
---@return boolean
function M.is_fixed(bufnr, path)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local ft = vim.bo[bufnr].filetype
    if ft == "fortran_fixed" then
      return true
    end
    if ft == "fortran_free" then
      return false
    end
  end
  local name = path or (bufnr and vim.api.nvim_buf_get_name(bufnr)) or ""
  return M.FIXED_EXTENSIONS[(name:lower():match("%.(%w+)$") or "")] == true
end

-- ---------------------------------------------------------------------------
-- Argument-list walking
-- ---------------------------------------------------------------------------

--- Finish a slot: its position is its first non-blank character, its text the
--- whole thing trimmed.
---
--- The text comes from the MASKED line, so it is lowercased and has string
--- literals blanked. It is only ever compared against a dummy name and never
--- shown to anyone, so that is exactly what is wanted -- Fortran is
--- case-insensitive and the comparison should be too. A slot that is entirely blank (`CALL F(A,,B)`, or the
--- empty list `F()`) has no position and is recorded as a hole so that the
--- POSITIONS of the arguments after it stay correct.
---@param slot table|nil
---@return table|nil
local function close_slot(slot)
  if not slot then
    return nil
  end
  local first = nil
  local chars = {}
  for _, part in ipairs(slot.parts) do
    chars[#chars + 1] = part.ch
    if not first and part.ch:match("%S") then
      first = part
    end
  end
  local text = vim.trim(table.concat(chars))
  if not first or text == "" then
    return { empty = true }
  end
  return { lnum = first.lnum, col = first.col, text = text }
end

--- Walk the parenthesised list opened at (first_lnum, open_col).
---
--- Returns one entry per top-level argument, in order, each with the 1-based
--- (lnum, col) of its first non-blank character; entries for blank arguments
--- carry `empty = true` and no position. The second return is whether the list
--- actually closed -- an unclosed list means the statement was truncated or
--- malformed and its hints are not trustworthy. A closed list also reports the
--- 1-based (lnum, col) of the `)` itself: the return-type hint sits just after
--- it, and the "add the missing ierror" quickfix inserts just before it.
---
--- Commas inside nested parentheses do not split, and commas inside string
--- literals cannot appear at all: `masked` has had every literal blanked
--- length-preservingly by scan.mask, which is what makes a plain character
--- walk sound here.
---@param masked string[] masked lines, 1-based
---@param first_lnum integer line holding the `(`
---@param open_col integer 1-based column of the `(`
---@param fixed boolean
---@return table[] slots, boolean closed, integer|nil close_lnum, integer|nil close_col
function M.arg_slots(masked, first_lnum, open_col, fixed)
  local slots = {}
  local depth, slot = 0, nil
  local lnum = first_lnum
  local budget = M.MAX_CONTINUATION

  while lnum <= #masked and budget > 0 do
    budget = budget - 1
    local line = masked[lnum] or ""
    local from, to = 1, #line

    if lnum == first_lnum then
      from = open_col
    elseif fixed then
      if not M.is_fixed_continuation(line) then
        return slots, false
      end
      -- Columns 1-6 are never statement text in fixed form.
      from = 7
    else
      from = line:match("^%s*&()") or 1
    end

    local continues = true
    if not fixed then
      to, continues = M.free_extent(line)
    end

    local i = from
    while i <= to do
      local ch = line:sub(i, i)
      if ch == "(" then
        depth = depth + 1
        if depth == 1 then
          slot = { parts = {} }
        else
          slot.parts[#slot.parts + 1] = { lnum = lnum, col = i, ch = ch }
        end
      elseif ch == ")" then
        depth = depth - 1
        if depth == 0 then
          slots[#slots + 1] = close_slot(slot)
          -- A single blank slot is the empty list `F()`, not one blank
          -- argument. Nothing else can produce exactly one empty slot.
          if #slots == 1 and slots[1].empty then
            return {}, true, lnum, i
          end
          return slots, true, lnum, i
        end
        slot.parts[#slot.parts + 1] = { lnum = lnum, col = i, ch = ch }
      elseif ch == "," and depth == 1 then
        slots[#slots + 1] = close_slot(slot)
        slot = { parts = {} }
      elseif depth >= 1 then
        slot.parts[#slot.parts + 1] = { lnum = lnum, col = i, ch = ch }
      end
      i = i + 1
    end

    if not fixed and not continues then
      return slots, false
    end
    lnum = lnum + 1
  end
  return slots, false
end

-- ---------------------------------------------------------------------------
-- Signature index
-- ---------------------------------------------------------------------------

--- The dummy arguments of the procedure header starting at `lines[lnum]`.
---
--- Continuations are followed by re-entering scan._scan_declarations with the
--- state it returned, which is how scan.project_declarations does it -- with
--- one addition: that state only tracks the free-form `&`, so a fixed-form
--- continuation is detected here and the state forced active. Columns 1-6 are
--- blanked first, because the marker in column 6 is not statement text and
--- walk_entities would otherwise read it as the start of an entity.
---@param lines string[]
---@param lnum integer
---@param fixed boolean
---@return string[] names, integer last_lnum
function M.header_args(lines, lnum, fixed)
  local found = {}
  local raw = lines[lnum] or ""
  local state = scan._scan_declarations(scan.mask(raw, fixed), raw, lnum, found, { active = false })
  local at = lnum
  local budget = M.MAX_CONTINUATION

  while budget > 0 do
    budget = budget - 1
    local nxt = lines[at + 1]
    if not nxt then
      break
    end
    if fixed then
      if not M.is_fixed_continuation(scan.mask(nxt, fixed)) then
        break
      end
      state.active = true
    elseif not state.active then
      break
    end
    at = at + 1
    local masked = scan.mask(nxt, fixed)
    if fixed then
      masked = string.rep(" ", 6) .. masked:sub(7)
    end
    state = scan._scan_declarations(masked, nxt, at, found, state)
  end

  local names = {}
  for _, d in ipairs(found) do
    if d.kind == "arg" then
      names[#names + 1] = d.name
    end
  end
  return names, at
end

--- Procedure name -> signature, for the whole project.
---
--- `cb` receives a map keyed by LOWERCASE name:
---   { name = "HEATING", args = { "T", "K" }, path = ..., lnum = ... }
---
--- The first definition of a name wins. An explicit INTERFACE block declares
--- the same header, so a name can legitimately be found twice with identical
--- dummy names; when they disagree the real definition and the interface have
--- drifted apart, which is ftnchek's problem to report, not this one's.
---@param root string
---@param cb fun(sigs: table<string, table>)
function M.build_signatures(root, cb)
  scan.rg_lines(root, [[(?i)\b(?:subroutine|function)\b]], function(records)
    local by_path, order = {}, {}
    for _, rec in ipairs(records) do
      if not by_path[rec.path] then
        by_path[rec.path] = {}
        order[#order + 1] = rec.path
      end
      by_path[rec.path][#by_path[rec.path] + 1] = rec.lnum
    end

    local sigs = {}
    for _, path in ipairs(order) do
      local lnums = by_path[path]
      table.sort(lnums)
      local ok, lines = pcall(vim.fn.readfile, path)
      if ok and type(lines) == "table" then
        local fixed = M.is_fixed(nil, path)
        local consumed = {}
        for _, lnum in ipairs(lnums) do
          if not consumed[lnum] then
            local defs = {}
            local raw = lines[lnum] or ""
            scan._scan_definitions(scan.mask(raw, fixed), raw, lnum, defs)
            for _, d in ipairs(defs) do
              if (d.kind == "subroutine" or d.kind == "function") and not sigs[d.lname] then
                local args, last = M.header_args(lines, lnum, fixed)
                for l = lnum + 1, last do
                  consumed[l] = true
                end
                sigs[d.lname] = { name = d.name, args = args, path = path, lnum = lnum }
              end
            end
          end
        end
      end
    end
    -- Builtins fill GAPS only, and only after the project scan, so a project
    -- that defines its own MPI_SEND wrapper keeps the wrapper's real dummy
    -- names. MPI routines live in the library, never in the source, so
    -- without this the six positional arguments of
    -- `MPI_BCAST(crita, 1, MPI_DOUBLE_PRECISION, 0, MPI_COMM_WORLD, ierr)`
    -- got no hints at all -- the case the feature is best at.
    for _, mod in ipairs({ "andrew.fortran.mpi", "andrew.fortran.openmp" }) do
      local ok, builtins = pcall(require, mod)
      if ok then
        builtins.seed(sigs)
      end
    end

    cb(sigs)
  end, scan.all_globs())
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local cache = {}

--- Drop the signature index for `root` (or all roots).
---@param root string|nil
function M.invalidate(root)
  if root then
    cache[root] = nil
  else
    cache = {}
  end
end

--- Signature index for `root`, built at most once per root until invalidated.
--- Concurrent callers queue on the in-flight build rather than starting a
--- second ripgrep.
---
--- Public because andrew.fortran.lsp_diagnostics needs the SAME index to tell
--- a standard MPI binding from a project-defined wrapper of the same name, and
--- a second ripgrep pass on every `:w` is not a cost worth paying twice.
---@param root string
---@param cb fun(sigs: table<string, table>)
function M.ensure_signatures(root, cb)
  local e = cache[root]
  if e and e.sigs then
    return cb(e.sigs)
  end
  if e and e.waiters then
    e.waiters[#e.waiters + 1] = cb
    return
  end
  cache[root] = { waiters = { cb } }
  M.build_signatures(root, function(sigs)
    local entry = cache[root]
    if not entry then
      -- Invalidated while the build was in flight; the result describes a
      -- state that no longer exists, so it is answered but not stored.
      return cb(sigs)
    end
    entry.sigs = sigs
    local waiters = entry.waiters or {}
    entry.waiters = nil
    for _, w in ipairs(waiters) do
      w(sigs)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Result types
-- ---------------------------------------------------------------------------

local result_types = nil

--- LOWERCASE builtin function name -> declared result type.
---
--- Read from the registry rather than from the seeded signature index, because
--- mpi.seed/openmp.seed copy only `name` and `args` into it -- they were
--- written for argument-name hints, which never needed a result type. Keeping
--- the lookup here means neither of those modules has to change.
---
--- Only the registry's own entries appear, so a PROJECT function is never
--- given a return-type hint: fortls owns those, and a textual scan has no way
--- to recover the result type of `REAL*8 FUNCTION ENERGY(...)` reliably enough
--- to print it as if it were fact.
---@return table<string, string>
function M.result_types()
  if result_types then
    return result_types
  end
  local out = {}
  local ok, registry = pcall(require, "andrew.fortran.registry")
  if ok then
    for lname, sig in pairs(registry.signatures()) do
      if type(sig.result_type) == "string" and sig.result_type ~= "" then
        out[lname] = sig.result_type
      end
    end
  end
  result_types = out
  return out
end

-- ---------------------------------------------------------------------------
-- Call sites in a buffer
-- ---------------------------------------------------------------------------

--- Column of the `(` opening NAME's argument list, or nil.
--- Only whitespace may separate them -- `Foo (x)` is a legal call, `Foo x`
--- is not a call at all.
---@param masked string
---@param name_col integer
---@param name_len integer
---@return integer|nil
function M.paren_after(masked, name_col, name_len)
  return masked:match("^%s*()%(", name_col + name_len)
end

--- Every call site in `bufnr` whose callee has a known signature.
---
--- Both spellings are collected: `CALL NAME(...)` from the scanner's `calls`,
--- and `NAME(...)` from its `refs` (a function reference). The two overlap on
--- a CALL statement -- `scan_paren_names` matches the same name -- so sites
--- are keyed by (lnum, open paren column) and the first wins.
---
--- A procedure's OWN header is excluded: `SUBROUTINE HEATING(T, K)` is a
--- `NAME(` hit for HEATING, and labelling a definition's dummy arguments with
--- their own names is pure noise.
---@param buf_scan table result of scan.scan_buffer
---@param sigs table<string, table>
---@return { lname: string, lnum: integer, open: integer }[]
function M.call_sites(buf_scan, sigs)
  local sites, seen = {}, {}
  local defined_here = {}
  for _, d in ipairs(buf_scan.defs) do
    defined_here[d.lnum .. "\0" .. d.lname] = true
  end

  local function take(rec)
    if not sigs[rec.lname] then
      return
    end
    if defined_here[rec.lnum .. "\0" .. rec.lname] then
      return
    end
    local masked = buf_scan.masked[rec.lnum]
    if not masked then
      return
    end
    local open = M.paren_after(masked, rec.col, #rec.name)
    if not open then
      return
    end
    local key = rec.lnum .. "\0" .. open
    if seen[key] then
      return
    end
    seen[key] = true
    sites[#sites + 1] = { lname = rec.lname, lnum = rec.lnum, open = open }
  end

  for _, rec in ipairs(buf_scan.calls) do
    take(rec)
  end
  for _, rec in ipairs(buf_scan.refs) do
    take(rec)
  end
  table.sort(sites, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.open < b.open
  end)
  return sites
end

--- Build the hints for one buffer.
---
--- Two families, gated independently by M.settings():
---
---   ARGUMENT NAMES, against each actual argument. A hint is suppressed when
---   the actual argument is spelled the same as the dummy, which in Fortran is
---   the common case for pass-through wrappers and would otherwise double
---   every name on screen. Comparison is case-insensitive because Fortran is.
---
---   RETURN TYPES, just after the closing paren of a call to a BUILTIN
---   function whose result type the registry knows -- `t = omp_get_wtime(): double precision`.
---   This is the one hint that carries paddingLeft (a leading space, because
---   it abuts the `)`); argument-name hints carry paddingRight and never
---   paddingLeft. Fortran's implicit typing is exactly what makes it worth
---   printing: `t = mpi_wtime()` under IMPLICIT NONE is a compile error and
---   under implicit typing is a silently truncated REAL.
---@param buf_scan table
---@param sigs table<string, table>
---@param fixed boolean
---@param first integer 1-based first line to emit for
---@param last integer 1-based last line to emit for
---@return table[] LSP InlayHint[]
function M.build_hints(buf_scan, sigs, fixed, first, last)
  local hints = {}
  local want = M.settings()
  if not (want.argument_names or want.return_types) then
    return hints
  end
  local rtypes = want.return_types and M.result_types() or {}
  for _, site in ipairs(M.call_sites(buf_scan, sigs)) do
    -- A call may open above the requested range and reach into it, so the
    -- window is widened on the way in and the HINTS are filtered on the way
    -- out. Filtering sites by line instead would drop the hints on the
    -- continuation lines of a call whose head is just off screen.
    if site.lnum >= first - M.MAX_CONTINUATION and site.lnum <= last then
      local sig = sigs[site.lname]
      local slots, closed, close_lnum, close_col = M.arg_slots(buf_scan.masked, site.lnum, site.open, fixed)
      if closed then
        if want.argument_names then
          for i, slot in ipairs(slots) do
            local dummy = sig.args[i]
            if
              dummy
              and not slot.empty
              and slot.lnum >= first
              and slot.lnum <= last
              and slot.text:lower() ~= dummy:lower()
            then
              hints[#hints + 1] = {
                position = { line = slot.lnum - 1, character = slot.col - 1 },
                label = dummy .. ":",
                kind = M.KIND_PARAMETER,
                paddingRight = true,
              }
            end
          end
        end
        local rtype = sig.builtin == true and rtypes[site.lname] or nil
        if rtype and close_lnum and close_lnum >= first and close_lnum <= last then
          hints[#hints + 1] = {
            -- Just AFTER the `)`: close_col is 1-based, so the 0-based
            -- character one past it is close_col itself.
            position = { line = close_lnum - 1, character = close_col },
            label = ": " .. rtype,
            kind = M.KIND_TYPE,
            paddingLeft = true,
            -- Deliberately empty, like every hint here: accepting `: double
            -- precision` into an expression writes invalid Fortran.
            textEdits = {},
          }
        end
      end
    end
  end
  return hints
end

-- ---------------------------------------------------------------------------
-- LSP entry point
-- ---------------------------------------------------------------------------

--- textDocument/inlayHint.
---@param params table
---@param cb fun(err: table|nil, result: table[]|nil)
function M.inlay(params, cb)
  local uri = params and params.textDocument and params.textDocument.uri
  if not uri then
    return cb(nil, nil)
  end
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return cb(nil, nil)
  end
  -- Both families off: answer before the ripgrep-backed signature index is
  -- touched, so a user who turned hints off pays nothing for the capability
  -- still being advertised.
  local want = M.settings()
  if not (want.argument_names or want.return_types) then
    return cb(nil, {})
  end
  local range = params.range or {}
  local first = ((range.start or {}).line or 0) + 1
  local last = ((range["end"] or {}).line or (vim.api.nvim_buf_line_count(bufnr) - 1)) + 1

  local path = vim.api.nvim_buf_get_name(bufnr)
  local root = scan.project_root(vim.fn.fnamemodify(path, ":h"))
  M.ensure_signatures(root, function(sigs)
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      return cb(nil, nil)
    end
    local ok, res = pcall(function()
      local buf_scan = scan.scan_buffer(bufnr)
      return M.build_hints(buf_scan, sigs, M.is_fixed(bufnr, path), first, last)
    end)
    cb(nil, ok and res or nil)
  end)
end

--- Rebuild the signature index when a Fortran file is written: a dummy
--- argument added or renamed changes every call site's hints, and a stale
--- index would show the old names indefinitely.
function M.setup_invalidation()
  local group = vim.api.nvim_create_augroup("FortranInlayHintCache", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.f", "*.F", "*.for", "*.FOR", "*.ftn", "*.fpp", "*.f90", "*.F90", "*.f95", "*.f03", "*.f08" },
    callback = function()
      M.invalidate()
    end,
  })
end

M.setup_invalidation()

return M
