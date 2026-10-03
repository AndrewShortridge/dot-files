-- callHierarchy for Fortran, served by andrew.fortran.lsp.
--
-- WHY THIS EXISTS
--
-- fortls answers references (`gr`) but has no callHierarchyProvider, so `gai`
-- and `gao` -- fzf-lua's lsp_incoming_calls / lsp_outgoing_calls -- were never
-- bound in a Fortran buffer. The data has been sitting in andrew.fortran.scan
-- since the symbol picker was built: definitions, `call NAME` statements and
-- `NAME(` candidates, each with a path, a line and a byte column. What was
-- missing is the two structural questions a call hierarchy asks that a flat
-- list of call sites cannot answer:
--
--   incoming: which program unit CONTAINS this call site?
--   outgoing: which call sites are inside THIS unit's body, and no other's?
--
-- Both are answered from the same unit open/close accounting that
-- scan.nesting_depths already does for the document picker's indentation. It
-- is reused literally rather than reimplemented: a unit defined on line L at
-- depth d ends on the first line after L whose depth is back down to d. That
-- is the `end` line, because nesting_depths decrements BEFORE it assigns.
--
-- THE FOUR TRAPS
--
-- 1. `Foo(x)` is a function call or an array index depending on nothing but
--    whether the project defines a procedure called Foo. scan.lua says so in
--    as many words. Every paren candidate here is filtered against the
--    project's definition set; unfiltered, a call hierarchy is a list of
--    array subscripts.
--
-- 2. A definition header is itself a `NAME(` hit. `subroutine Heating(t)`
--    produces a paren candidate for `heating` at exactly the column of its own
--    definition, so without a filter every procedure calls itself once. Both
--    the project pass and the per-file pass drop any candidate sitting on a
--    known definition position.
--
-- 3. `call Foo(x)` is found TWICE by scan.project_calls -- once by the `call`
--    keyword pass and once by the paren pass, at the same path/line/column.
--    Deduplication is by position, not by record identity.
--
-- 4. For OUTGOING calls, LSP puts `fromRanges` in the CALLER's document, not
--    the callee's. The ranges are where the caller invokes, the `to` item is
--    where the callee lives, and they are usually in different files.
--    (fzf-lua then labels outgoing hits with the CURRENT buffer regardless of
--    what we send -- see call_hierarchy_handler -- so `gao` reads correctly
--    when invoked on a procedure in the buffer you are in, which is the only
--    way anyone invokes it.)
--
-- CACHING
--
-- A picker expansion must not re-walk the tree. scan.project_definitions and
-- scan.project_calls are ripgrep passes over every Fortran file in the root;
-- the workspace symbol picker measures ~349ms for a project of that size, and
-- `gai` fires one request per expansion. So each root gets one cached
-- definition index and one cached call index, both built at most once and
-- shared by every in-flight request (a second request arriving mid-scan joins
-- the waiter list rather than starting a second rg). The cache is dropped
-- whenever a Fortran buffer is written; M.invalidate(root) and M.reset() are
-- the explicit hooks.
--
-- ASYNC
--
-- Every entry point takes (params, cb) and never blocks: the rg passes call
-- back through vim.schedule. A cursor sitting on a DEFINITION is the one case
-- answered without touching the project at all -- the buffer already proves
-- what the symbol is -- which keeps the common `gai`-on-a-header path off the
-- ripgrep round trip entirely.

local scan = require("andrew.fortran.scan")
local flsp = require("andrew.fortran.lsp")

local M = {}

-- ---------------------------------------------------------------------------
-- Kinds
-- ---------------------------------------------------------------------------

-- LSP SymbolKind numbers. A Fortran SUBROUTINE is reported as Function (12)
-- and not Method (6): Method means "member of a type", and a subroutine is a
-- free-standing program unit even when it lives inside a module. The one
-- Fortran construct that really is a method -- a type-bound `procedure ::` --
-- resolves to the module subroutine it binds, which is what gets reported.
-- This also matches andrew.fortran.symbols, whose KINDS table already maps
-- both `subroutine` and `function` onto the LSP's Function.
local SYMBOL_KIND = {
  subroutine = 12, -- Function
  ["function"] = 12, -- Function
  program = 2, -- Module
  module = 2, -- Module
  submodule = 3, -- Namespace
  interface = 11, -- Interface
  type = 23, -- Struct
}
local KIND_FILE = 1 -- SymbolKind.File, for a call site outside any unit

-- What may be the SUBJECT of a call hierarchy. A module or a derived type has
-- no body of its own to call from and cannot be called, so `gai` on one
-- answers nothing rather than answering about its contained procedures.
local PROC_KINDS = { subroutine = true, ["function"] = true, program = true }

-- Definition kinds that OPEN a nesting level. Mirrors scan.lua's
-- UNIT_END_KEYWORDS, which is what nesting_depths counts; a unit missing from
-- here would make every span after it end one `end` too early.
local UNIT_KINDS = {
  program = true,
  module = true,
  submodule = true,
  subroutine = true,
  ["function"] = true,
  type = true,
  interface = true,
}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

---@param path string
---@param lnum integer
---@param col integer
---@return string
local function poskey(path, lnum, col)
  return path .. "\0" .. lnum .. "\0" .. col
end

---@param path string
---@return string absolute path
local function abspath(path)
  return vim.fn.fnamemodify(path, ":p")
end

--- The loaded buffer holding `path`, if any.
---@param path string
---@return integer|nil
local function loaded_buf(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and abspath(vim.api.nvim_buf_get_name(buf)) == path then
      return buf
    end
  end
  return nil
end

--- Lines of `path`, preferring a loaded buffer so unsaved edits are visible.
---
--- ripgrep necessarily sees the file on disk, so on a DIRTY buffer the call
--- positions and the unit spans can disagree by however many lines the edit
--- moved. That is unavoidable without reindexing on every keystroke, and the
--- failure mode is a call attributed to the neighbouring unit, not an error.
---@param path string
---@return string[] lines, boolean from_buffer
local function file_lines(path)
  local buf = loaded_buf(path)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false), true
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}, false
end

-- ---------------------------------------------------------------------------
-- Program unit spans
-- ---------------------------------------------------------------------------

---@class fortran.ch.Unit
---@field name string source-cased name
---@field lname string lowercase name
---@field kind string scanner definition kind
---@field lnum integer 1-based definition line
---@field col integer 1-based byte column of the name
---@field last integer 1-based line of the unit's `end` (or the last line)

---@class fortran.ch.Spans
---@field units fortran.ch.Unit[]
---@field lines string[]
---@field scan table result of scan.scan_lines

--- Definition line + closing line for every program unit in `lines`.
---
--- The closing line is read off scan.nesting_depths rather than recounted:
--- that function is the config's single answer to "does `end` close a unit or
--- a construct", and `end if` closing a subroutine is exactly the bug a second
--- implementation would reintroduce.
---@param lines string[]
---@return fortran.ch.Spans
local function build_spans(lines)
  local res = scan.scan_lines(lines)
  local depths = scan.nesting_depths(res.masked, res.defs)
  local n = #lines
  local units = {}

  for _, d in ipairs(res.defs) do
    if UNIT_KINDS[d.kind] then
      local base = depths[d.lnum] or 0
      local last = n
      for l = d.lnum + 1, n do
        if (depths[l] or 0) <= base then
          last = l
          break
        end
      end
      units[#units + 1] = {
        name = d.name,
        lname = d.lname,
        kind = d.kind,
        lnum = d.lnum,
        col = d.col,
        last = last,
      }
    end
  end

  return { units = units, lines = lines, scan = res }
end

--- The innermost unit containing `lnum`.
---
--- Spans nest, so "innermost" is simply the containing unit that starts last:
--- a call inside a CONTAINS-ed subroutine belongs to that subroutine, not to
--- the module wrapped around it.
---@param spans fortran.ch.Spans
---@param lnum integer
---@return fortran.ch.Unit|nil
local function enclosing(spans, lnum)
  local best
  for _, u in ipairs(spans.units) do
    if u.lnum <= lnum and lnum <= u.last then
      if not best or u.lnum > best.lnum then
        best = u
      end
    end
  end
  return best
end

--- The unit defined at `lnum` (optionally named `lname`).
---@param spans fortran.ch.Spans
---@param lnum integer
---@param lname string|nil
---@return fortran.ch.Unit|nil
local function unit_at(spans, lnum, lname)
  for _, u in ipairs(spans.units) do
    if u.lnum == lnum and (lname == nil or u.lname == lname) then
      return u
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Per-root project cache
-- ---------------------------------------------------------------------------

---@class fortran.ch.Project
---@field root string
---@field spans table<string, fortran.ch.Spans> per-file spans, disk-backed only
---@field defs table[]|nil every project definition
---@field by_lname table<string, table[]>|nil definitions keyed by lowercase name
---@field defpos table<string, boolean>|nil path/line/col of every definition
---@field names string[]|nil unique lowercase defined names
---@field calls table[]|nil deduplicated project call sites
---@field calls_by_lname table<string, table[]>|nil

---@type table<string, fortran.ch.Project>
local cache = {}

---@param root string
---@return fortran.ch.Project
local function entry(root)
  local e = cache[root]
  if not e then
    e = { root = root, spans = {} }
    cache[root] = e
  end
  return e
end

--- Drop one root's cache, or every root when `root` is nil.
---
--- The explicit invalidation hook. Anything that changes what ripgrep would
--- find -- a write, a checkout, a new file -- must go through here or the
--- hierarchy answers from the tree as it was.
---@param root string|nil
function M.invalidate(root)
  if root then
    cache[root] = nil
  else
    cache = {}
  end
end

--- Drop every cache. Exported for the specs.
function M.reset()
  cache = {}
end

--- Spans for a file, cached only when nothing has it open.
---
--- A loaded buffer can change under us with no event this module sees, so its
--- spans are recomputed each time; a file on disk cannot change without a
--- write, and a write invalidates the whole root.
---@param e fortran.ch.Project
---@param path string
---@return fortran.ch.Spans
local function spans_for(e, path)
  local cached = e.spans[path]
  if cached then
    return cached
  end
  local lines, from_buffer = file_lines(path)
  local spans = build_spans(lines)
  if not from_buffer then
    e.spans[path] = spans
  end
  return spans
end

--- Ensure the project's definition index, then hand the cache entry to `cb`.
---
--- Requests arriving while a scan is in flight join the waiter list. Without
--- that, holding down the expansion key in the picker would start one ripgrep
--- per keypress over the whole tree.
---@param root string
---@param cb fun(e: fortran.ch.Project)
local function ensure_defs(root, cb)
  local e = entry(root)
  if e.defs then
    return cb(e)
  end
  if e.def_waiters then
    e.def_waiters[#e.def_waiters + 1] = cb
    return
  end
  e.def_waiters = { cb }

  scan.project_definitions(root, function(defs)
    local by_lname, defpos, names, seen = {}, {}, {}, {}
    for _, d in ipairs(defs) do
      d.path = abspath(d.path)
      defpos[poskey(d.path, d.lnum, d.col)] = true
      local bucket = by_lname[d.lname]
      if not bucket then
        bucket = {}
        by_lname[d.lname] = bucket
      end
      bucket[#bucket + 1] = d
      if not seen[d.lname] then
        seen[d.lname] = true
        names[#names + 1] = d.lname
      end
    end
    e.defs, e.by_lname, e.defpos, e.names = defs, by_lname, defpos, names

    local waiters = e.def_waiters
    e.def_waiters = nil
    for _, w in ipairs(waiters or {}) do
      w(e)
    end
  end)
end

--- Ensure the project's call index (definitions first), then call `cb`.
---@param root string
---@param cb fun(e: fortran.ch.Project)
local function ensure_calls(root, cb)
  ensure_defs(root, function(e)
    if e.calls then
      return cb(e)
    end
    if e.call_waiters then
      e.call_waiters[#e.call_waiters + 1] = cb
      return
    end
    e.call_waiters = { cb }

    scan.project_calls(root, e.names or {}, function(calls)
      local out, by_lname, seen = {}, {}, {}
      for _, c in ipairs(calls) do
        c.path = abspath(c.path)
        local key = poskey(c.path, c.lnum, c.col)
        -- Trap 2: a definition header is its own paren candidate.
        -- Trap 3: `call Foo(x)` is reported by both passes at one position.
        if not e.defpos[key] and not seen[key] then
          seen[key] = true
          out[#out + 1] = c
          local bucket = by_lname[c.lname]
          if not bucket then
            bucket = {}
            by_lname[c.lname] = bucket
          end
          bucket[#bucket + 1] = c
        end
      end
      e.calls, e.calls_by_lname = out, by_lname

      local waiters = e.call_waiters
      e.call_waiters = nil
      for _, w in ipairs(waiters or {}) do
        w(e)
      end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- CallHierarchyItem construction
-- ---------------------------------------------------------------------------

--- Range covering whole lines `first`..`last` of `lines`.
---@param lines string[]
---@param first integer
---@param last integer
---@return table
local function line_range(lines, first, last)
  return {
    start = flsp.to_pos(first, 1),
    ["end"] = flsp.to_pos(last, #(lines[last] or "") + 1),
  }
end

--- A CallHierarchyItem for a unit, given its file's spans.
---@param root string
---@param path string
---@param spans fortran.ch.Spans
---@param unit fortran.ch.Unit
---@return table
local function item_for_unit(root, path, spans, unit)
  return {
    name = unit.name,
    kind = SYMBOL_KIND[unit.kind] or 12,
    detail = unit.kind,
    uri = vim.uri_from_fname(path),
    range = line_range(spans.lines, unit.lnum, unit.last),
    selectionRange = flsp.name_range(unit.lnum, unit.col, #unit.lname),
    -- `data` round-trips to incoming/outgoing so neither has to re-derive the
    -- root or re-find the definition the item came from.
    data = {
      lname = unit.lname,
      kind = unit.kind,
      root = root,
      path = path,
      lnum = unit.lnum,
      col = unit.col,
    },
  }
end

--- A CallHierarchyItem for a project definition record.
---@param e fortran.ch.Project
---@param def table
---@return table|nil
local function item_for_def(e, def)
  local spans = spans_for(e, def.path)
  local unit = unit_at(spans, def.lnum, def.lname)
  if unit then
    return item_for_unit(e.root, def.path, spans, unit)
  end
  -- The definition line is known but its file no longer parses to a unit
  -- there (stale index, or an rg hit inside a construct the span builder does
  -- not open). The name and position are still right, so answer with a
  -- single-line item rather than nothing.
  return {
    name = def.name,
    kind = SYMBOL_KIND[def.kind] or 12,
    detail = def.kind,
    uri = vim.uri_from_fname(def.path),
    range = flsp.name_range(def.lnum, def.col, #def.lname),
    selectionRange = flsp.name_range(def.lnum, def.col, #def.lname),
    data = {
      lname = def.lname,
      kind = def.kind,
      root = e.root,
      path = def.path,
      lnum = def.lnum,
      col = def.col,
    },
  }
end

--- The best definition for `lname`, preferring a real procedure over an
--- interface body (an `interface` block declares the same name as the module
--- procedure it describes, and the procedure is what you want to jump to).
---@param e fortran.ch.Project
---@param lname string
---@return table|nil
local function best_def(e, lname)
  local bucket = e.by_lname and e.by_lname[lname]
  if not bucket or #bucket == 0 then
    return nil
  end
  for _, d in ipairs(bucket) do
    if PROC_KINDS[d.kind] then
      return d
    end
  end
  return bucket[1]
end

--- A CallHierarchyItem standing in for a callee with no definition in the
--- project -- an intrinsic, an MPI entry point, a library routine. `call
--- MPI_INIT(ierr)` is unambiguously a call and belongs in the outgoing list;
--- the only honest position for it is the call site itself.
---@param root string
---@param path string
---@param site table
---@return table
local function item_for_external(root, path, site)
  return {
    name = site.name,
    kind = 12, -- Function
    detail = "external",
    uri = vim.uri_from_fname(path),
    range = flsp.name_range(site.lnum, site.col, #site.lname),
    selectionRange = flsp.name_range(site.lnum, site.col, #site.lname),
    data = { lname = site.lname, root = root, path = path, external = true },
  }
end

-- ---------------------------------------------------------------------------
-- Request helpers
-- ---------------------------------------------------------------------------

--- The record in `records` whose name covers byte column `col` on `lnum`.
---@param records table[]
---@param lnum integer
---@param col integer
---@return table|nil
local function token_at(records, lnum, col)
  for _, r in ipairs(records) do
    if r.lnum == lnum and col >= r.col and col <= r.col + #r.lname - 1 then
      return r
    end
  end
  return nil
end

--- Root and absolute path for a document URI.
---@param uri string
---@return string root, string path
local function root_for_uri(uri)
  local path = abspath(vim.uri_to_fname(uri))
  return scan.project_root(vim.fn.fnamemodify(path, ":h")), path
end

--- The item's identity, tolerating a client that dropped `data`.
---@param item table|nil
---@return string|nil lname, string|nil root, string|nil path
local function item_identity(item)
  if type(item) ~= "table" or type(item.uri) ~= "string" then
    return nil, nil, nil
  end
  local data = type(item.data) == "table" and item.data or {}
  local root, path = root_for_uri(item.uri)
  local lname = data.lname or (type(item.name) == "string" and item.name:lower()) or nil
  return lname, data.root or root, data.path or path
end

--- Call sites inside one file, deduplicated and restricted to real calls.
---
--- `calls` are `call NAME` statements and are always calls. `refs` are `NAME(`
--- candidates and are calls only when the project defines NAME as a procedure
--- (trap 1), and never when they sit on NAME's own definition header (trap 2).
---@param spans fortran.ch.Spans
---@param known table<string, boolean> lowercase project procedure names
---@return table[] sites sorted by line then column
local function local_sites(spans, known)
  local defpos = {}
  for _, d in ipairs(spans.scan.defs) do
    defpos[d.lnum .. "\0" .. d.col] = true
  end

  local out, seen = {}, {}
  local function add(rec)
    local key = rec.lnum .. "\0" .. rec.col
    if defpos[key] or seen[key] then
      return
    end
    seen[key] = true
    out[#out + 1] = rec
  end

  for _, c in ipairs(spans.scan.calls) do
    add(c)
  end
  for _, r in ipairs(spans.scan.refs) do
    if known[r.lname] then
      add(r)
    end
  end

  table.sort(out, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- textDocument/prepareCallHierarchy
-- ---------------------------------------------------------------------------

--- Identify the procedure under the cursor.
---
--- Three shapes count: the cursor on a procedure's own header, on the callee
--- of a `call` statement, and on a `NAME(` reference that the project defines
--- as a procedure. Everything else -- an array subscript, a variable, a
--- keyword, a module name -- answers nil, which is what makes `gai` on an
--- array quietly do nothing instead of listing its subscripts.
---@param params table textDocument/prepareCallHierarchy params
---@param cb fun(err: table|nil, result: table[]|nil)
function M.prepare(params, cb)
  local uri = params and params.textDocument and params.textDocument.uri
  if type(uri) ~= "string" or not params.position then
    return cb(nil, nil)
  end

  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end
  local lnum, col = flsp.from_pos(params.position)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local spans = build_spans(lines)
  local root, path = root_for_uri(uri)

  -- On a definition: the buffer already proves what this is, so answer now
  -- and keep the common case off the ripgrep round trip entirely.
  local def = token_at(spans.scan.defs, lnum, col)
  if def then
    if not PROC_KINDS[def.kind] then
      return cb(nil, nil)
    end
    local unit = unit_at(spans, def.lnum, def.lname)
    if unit then
      return cb(nil, { item_for_unit(root, path, spans, unit) })
    end
  end

  local site = token_at(spans.scan.calls, lnum, col)
  local from_ref = false
  if not site then
    site = token_at(spans.scan.refs, lnum, col)
    from_ref = site ~= nil
  end
  if not site then
    return cb(nil, nil)
  end

  ensure_defs(root, function(e)
    local target = best_def(e, site.lname)
    if target and PROC_KINDS[target.kind] then
      return cb(nil, { item_for_def(e, target) })
    end
    if from_ref then
      -- Trap 1: with no project definition, `Foo(x)` is an array index.
      return cb(nil, nil)
    end
    -- A `call` to something the project does not define is still a call.
    cb(nil, { item_for_external(root, path, site) })
  end)
end

-- ---------------------------------------------------------------------------
-- callHierarchy/incomingCalls
-- ---------------------------------------------------------------------------

--- Every call site of the item's name, grouped by the unit that contains it.
---@param params table { item = CallHierarchyItem }
---@param cb fun(err: table|nil, result: table[]|nil)
function M.incoming(params, cb)
  local item = params and params.item
  local lname, root = item_identity(item)
  if not lname or not root then
    return cb(nil, nil)
  end

  ensure_calls(root, function(e)
    local sites = e.calls_by_lname and e.calls_by_lname[lname]
    if not sites or #sites == 0 then
      return cb(nil, nil)
    end

    -- Group by (file, containing unit). A file with several units contributes
    -- one entry per unit that calls, not one entry per file.
    local groups, order = {}, {}
    for _, site in ipairs(sites) do
      local spans = spans_for(e, site.path)
      local unit = enclosing(spans, site.lnum)
      local key = site.path .. "\0" .. (unit and unit.lnum or 0)
      local group = groups[key]
      if not group then
        local from
        if unit then
          from = item_for_unit(root, site.path, spans, unit)
        else
          -- A call outside every program unit: an include fragment, or a file
          -- whose opening unit is malformed. The file is the only caller
          -- identity available.
          from = {
            name = vim.fn.fnamemodify(site.path, ":t"),
            kind = KIND_FILE,
            detail = "file",
            uri = vim.uri_from_fname(site.path),
            range = line_range(spans.lines, site.lnum, site.lnum),
            selectionRange = flsp.name_range(site.lnum, site.col, #site.lname),
            data = { root = root, path = site.path },
          }
        end
        group = { from = from, fromRanges = {}, sort = { site.path, unit and unit.lnum or 0 } }
        groups[key] = group
        order[#order + 1] = group
      end
      group.fromRanges[#group.fromRanges + 1] = flsp.name_range(site.lnum, site.col, #site.lname)
    end

    for _, group in ipairs(order) do
      table.sort(group.fromRanges, function(a, b)
        if a.start.line ~= b.start.line then
          return a.start.line < b.start.line
        end
        return a.start.character < b.start.character
      end)
      group.sort = nil
    end
    table.sort(order, function(a, b)
      if a.from.uri ~= b.from.uri then
        return a.from.uri < b.from.uri
      end
      return a.from.range.start.line < b.from.range.start.line
    end)

    cb(nil, order)
  end)
end

-- ---------------------------------------------------------------------------
-- callHierarchy/outgoingCalls
-- ---------------------------------------------------------------------------

--- Every procedure called from inside the item's own body.
---
--- "Its own body" excludes CONTAINS-ed procedures: a call in a contained
--- subroutine is that subroutine's outgoing call, not its host's. The test is
--- the innermost enclosing unit, not the line range, which is why the span
--- table is consulted per site rather than compared against once.
---
--- fromRanges are in the CALLER's document (trap 4) -- the item's file, not
--- the callee's.
---@param params table { item = CallHierarchyItem }
---@param cb fun(err: table|nil, result: table[]|nil)
function M.outgoing(params, cb)
  local item = params and params.item
  local lname, root, path = item_identity(item)
  if not lname or not root or not path then
    return cb(nil, nil)
  end
  local data = type(item.data) == "table" and item.data or {}
  local def_lnum = data.lnum or (item.selectionRange and item.selectionRange.start.line + 1)

  ensure_defs(root, function(e)
    local spans = spans_for(e, path)
    local unit = def_lnum and unit_at(spans, def_lnum, lname)
    if not unit then
      -- No definition line to trust (an external item, or a stale one). Fall
      -- back to the first unit of that name in the file.
      for _, u in ipairs(spans.units) do
        if u.lname == lname then
          unit = u
          break
        end
      end
    end
    if not unit then
      return cb(nil, nil)
    end

    local known = {}
    for _, d in ipairs(e.defs or {}) do
      if PROC_KINDS[d.kind] then
        known[d.lname] = true
      end
    end

    local groups, order = {}, {}
    for _, site in ipairs(local_sites(spans, known)) do
      if enclosing(spans, site.lnum) == unit then
        local group = groups[site.lname]
        if not group then
          local target = best_def(e, site.lname)
          local to = target and PROC_KINDS[target.kind] and item_for_def(e, target)
            or item_for_external(root, path, site)
          group = { to = to, fromRanges = {} }
          groups[site.lname] = group
          order[#order + 1] = group
        end
        -- Trap 4: the range is where the CALLER invokes, in the caller's file.
        group.fromRanges[#group.fromRanges + 1] = flsp.name_range(site.lnum, site.col, #site.lname)
      end
    end

    if #order == 0 then
      return cb(nil, nil)
    end
    cb(nil, order)
  end)
end

-- ---------------------------------------------------------------------------
-- Invalidation
-- ---------------------------------------------------------------------------

-- Writing a Fortran file changes what ripgrep would find, so the cached
-- indexes for its root stop being true at that moment. Registered here rather
-- than in lsp.lua so the provider owns its own cache lifetime and cannot be
-- loaded without it.
do
  local group = vim.api.nvim_create_augroup("FortranCallHierarchyCache", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if not flsp.FILETYPES[vim.bo[ev.buf].filetype] then
        return
      end
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name == "" then
        return
      end
      M.invalidate(scan.project_root(vim.fn.fnamemodify(abspath(name), ":h")))
    end,
  })
end

return M
