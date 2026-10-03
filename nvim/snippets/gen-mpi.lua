#!/usr/bin/env -S nvim -l
-- =============================================================================
-- gen-mpi.lua -- generate lua/andrew/fortran/data/mpi.lua
-- =============================================================================
--
-- WHY THIS EXISTS
--
-- The MPI documentation this config shipped was hand-written prose, and prose
-- lies: `mpi_allreduce` spelled the last dummy `ierr` in its usage line and
-- `ierror` in its interface fence; `mpi_isend` and `mpi_irecv` listed
-- `datatype, dest, tag` in one place and `dest, tag, datatype` in the other --
-- a real correctness bug, because inlay hints label positional arguments from
-- that order. Five routines had no typed interface at all.
--
-- gfortran's `.mod` files are gzip'd text holding the compiler's own symbol
-- table, so the installed MPI can answer all of it: exact dummy names, order,
-- intents, kinds and array specs for every routine in the F90 `mpi` binding.
-- This script reads that, merges the hand prose for everything a compiler
-- cannot know (what a routine is FOR), and writes a plain Lua table.
--
-- The project uses `include 'mpif.h'` (229 files), which is the F77 spelling of
-- the same F90 binding: every handle is `integer` and `ierror` is NOT optional.
-- So `interface` comes from `mpi.mod` and never from `mpi_f08_interfaces.mod`;
-- the f08 module is read ONLY to say, in `binding_note`, how the other binding
-- spells the same argument.
--
-- The output is version-coupled to this install (Open MPI 5.0.10 + gfortran
-- 14.3, module format 15), so it is generated offline and COMMITTED. Nothing at
-- runtime parses a `.mod`. `tests/fortran_registry_fresh_spec.lua` re-runs this
-- script into a temp dir and compares bytes, which is why every table is
-- emitted with sorted keys: the output must be byte-idempotent.
--
-- Usage:  nvim -l snippets/gen-mpi.lua [--out <dir>] [--prose <file>]
--                                     [--overrides-dir <dir>]
--
-- NOTE ON DUPLICATION: gen-omp.lua carries its own copy of the serializer and
-- the merge helpers. Two ~100-line copies beat a third module that only two
-- offline scripts require, and the generators are deliberately standalone --
-- they must run with `-u NONE` and no package.path set up. The ONE thing they
-- do share is `snippets/fortran-overrides.lua`, because "where do the
-- hand-authored tables live" must have exactly one answer.

local M = {}

-- ---------------------------------------------------------------------------
-- Arguments
-- ---------------------------------------------------------------------------

local script_dir = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h")
local repo = vim.fn.fnamemodify(script_dir, ":h")

local out_dir = repo .. "/lua/andrew/fortran/data"
local prose_path = nil
-- `--overrides-dir` exists for the specs: the guard below is a die(), and the
-- only way to prove a die() fires is to hand the generator an override file
-- that trips it, from a temp dir, without touching the committed one.
local overrides_dir = nil
do
  local argv = vim.v.argv
  for i = 1, #argv do
    if argv[i] == "--out" and argv[i + 1] then
      out_dir = argv[i + 1]
    end
    if argv[i] == "--prose" and argv[i + 1] then
      prose_path = argv[i + 1]
    end
    if argv[i] == "--overrides-dir" and argv[i + 1] then
      overrides_dir = argv[i + 1]
    end
  end
end

local MOD_MPI = vim.fn.expand("~/miniconda3/include/mpi.mod")
local MOD_F08 = vim.fn.expand("~/miniconda3/include/mpi_f08_interfaces.mod")
local INCLUDE_DIR = vim.fn.expand("~/miniconda3/include")
-- The parsed prose lives next to this script so the generator is reproducible
-- from a clean checkout; `--prose <path>` points it elsewhere.
local PROSE = prose_path or (script_dir .. "/parsed-mpi-omp.json")

local EXPECTED_HEADER = "GFORTRAN module version '15'"

local function die(msg)
  io.stderr:write("gen-mpi: " .. msg .. "\n")
  os.exit(1)
end

-- ---------------------------------------------------------------------------
-- gfortran .mod reader
-- ---------------------------------------------------------------------------
--
-- A `.mod` is gzip'd s-expression text wrapped at ~72 columns, so it must be
-- tokenised rather than matched line by line. Layout:
--
--     GFORTRAN module version '15' created from mpi-ignore-tkr.F90
--     (...) (...) (...)                     -- operator / generic / common tables
--     ( <id> '<name>' '<module>' '' <ns> ( <body> )   ... repeated ... )
--     ( '<name>' <ambiguous> <id> ... )      -- the exported-name table
--
-- The symbol table is ONE top-level list holding a flat sequence of records.

---@param path string
---@return string|nil
local function zcat(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local f = io.popen("zcat " .. vim.fn.shellescape(path) .. " 2>/dev/null", "r")
  if not f then
    return nil
  end
  local t = f:read("*a")
  f:close()
  if t == nil or t == "" then
    return nil
  end
  return t
end

--- Tokenise: "(" / ")" / bare atom (string) / quoted atom ({ str = "..." }).
---@param s string
---@return table[]
local function lex(s)
  local toks, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == " " or c == "\n" or c == "\t" or c == "\r" then
      i = i + 1
    elseif c == "(" or c == ")" then
      toks[#toks + 1] = c
      i = i + 1
    elseif c == "'" then
      local buf, j = {}, i + 1
      while j <= n do
        local ch = s:sub(j, j)
        if ch == "'" then
          if s:sub(j + 1, j + 1) == "'" then
            buf[#buf + 1] = "'"
            j = j + 2
          else
            j = j + 1
            break
          end
        else
          buf[#buf + 1] = ch
          j = j + 1
        end
      end
      toks[#toks + 1] = { str = table.concat(buf) }
      i = j
    else
      local j = i
      while j <= n and not s:sub(j, j):match("[%s()']") do
        j = j + 1
      end
      toks[#toks + 1] = s:sub(i, j - 1)
      i = j
    end
  end
  return toks
end

---@param toks table[]
---@param pos integer index of the "(" token
---@return table, integer
local function read_list(toks, pos)
  local out = {}
  pos = pos + 1
  while true do
    local t = toks[pos]
    if t == nil then
      die("unterminated list in module file")
    end
    if t == ")" then
      return out, pos + 1
    end
    if t == "(" then
      local sub
      sub, pos = read_list(toks, pos)
      out[#out + 1] = sub
    else
      out[#out + 1] = t
      pos = pos + 1
    end
  end
end

--- Parse a whole module into { header, recs = { [id] = rec }, order = { rec } }.
---@param text string
---@return table
local function parse_mod(text)
  local nl = text:find("\n")
  local header = text:sub(1, (nl or 1) - 1)
  local toks = lex(text:sub((nl or 0) + 1))
  local forms, pos = {}, 1
  while toks[pos] do
    if toks[pos] ~= "(" then
      die("unexpected top-level token in module: " .. tostring(toks[pos]))
    end
    local f
    f, pos = read_list(toks, pos)
    forms[#forms + 1] = f
  end
  -- the symbol table is the one top-level list that starts <id> '<name>'
  local syms
  for _, f in ipairs(forms) do
    if type(f[1]) == "string" and f[1]:match("^%d+$") and type(f[2]) == "table" and f[2].str then
      syms = f
      break
    end
  end
  local recs, order = {}, {}
  local i = 1
  while syms and i <= #syms do
    local id = tonumber(syms[i])
    i = i + 1
    local strs = {}
    while type(syms[i]) == "table" and syms[i].str ~= nil do
      strs[#strs + 1] = syms[i].str
      i = i + 1
    end
    while type(syms[i]) == "string" do
      i = i + 1
    end
    local body = syms[i]
    i = i + 1
    local r = { id = id, name = strs[1], module = strs[2], body = body }
    recs[id] = r
    order[#order + 1] = r
  end
  return { header = header, recs = recs, order = order }
end

-- ---------------------------------------------------------------------------
-- Record accessors
-- ---------------------------------------------------------------------------
--
-- A record body is a fixed-position list. Verified against `mpi_comm_rank`,
-- `mpi_isend`, `mpi_wtime`, `mpi_waitall`, `mpi_sendrecv`, `mpi_comm_self`:
--
--   [1] attribute list   (PROCEDURE|VARIABLE|PARAMETER <intent> ... [OPTIONAL] [DUMMY])
--   [2] component list   (derived types only)
--   [3] type spec        (INTEGER 4 0 0 0 INTEGER ())
--   [4] formal namespace id
--   [6] formal argument ids   (1129 1130 1131)   -- procedures
--   [7] array spec (rank corank SHAPE lo1 hi1 lo2 hi2 ...) OR the value expr

local function has_attr(rec, word)
  for _, t in ipairs(rec.body[1] or {}) do
    if t == word then
      return true
    end
  end
  return false
end

local SHAPES = {
  EXPLICIT = true,
  ASSUMED_SHAPE = true,
  ASSUMED_SIZE = true,
  DEFERRED = true,
  ASSUMED_RANK = true,
  IMPLIED_SHAPE = true,
}

--- Render a `.mod` expression atom. Only CONSTANT is common in MPI bounds.
local function expr_text(e)
  if type(e) ~= "table" then
    return nil
  end
  if e[1] == "CONSTANT" then
    local v = e[4]
    if type(v) == "table" and v.str then
      return v.str
    end
    return nil
  end
  if e[1] == "VARIABLE" then
    return nil
  end
  return nil
end

--- Map the array spec list to a Fortran dimension suffix: "(*)", "(6)", "(6, *)".
---@return string|nil
local function dim_of(spec)
  if type(spec) ~= "table" or #spec < 3 then
    return nil
  end
  local rank = tonumber(spec[1])
  local shape = spec[3]
  if not rank or rank < 1 or not SHAPES[shape] then
    return nil
  end
  local parts, idx = {}, 4
  for d = 1, rank do
    local lo, hi = spec[idx], spec[idx + 1]
    idx = idx + 2
    local hit = expr_text(hi)
    local lot = expr_text(lo)
    if shape == "ASSUMED_SHAPE" or shape == "DEFERRED" then
      parts[d] = ":"
    elseif hit == nil then
      parts[d] = "*" -- assumed size: no upper bound on the last dimension
    elseif lot == "1" then
      parts[d] = hit
    elseif lot then
      parts[d] = lot .. ":" .. hit
    else
      parts[d] = hit
    end
  end
  return "(" .. table.concat(parts, ", ") .. ")"
end

local function array_spec(rec)
  local e = rec.body[7]
  if type(e) == "table" and SHAPES[e[3] or ""] then
    return e
  end
  return nil
end

--- Derived-type name as the MPI standard spells it: `Mpi_comm` -> `MPI_Comm`.
local function derived_name(n)
  if type(n) ~= "string" then
    return "?"
  end
  local rest = n:match("^[Mm][Pp][Ii]_(.*)$")
  if not rest then
    return n
  end
  return "MPI_" .. rest:sub(1, 1):upper() .. rest:sub(2):lower()
end

--- Fortran type text for a dummy or a function result.
---
--- `ASSUMED` is how gfortran records the ignore-TKR choice buffers that
--- `mpi-ignore-tkr.F90` builds with `!GCC$ ATTRIBUTES NO_ARG_CHECK`: the dummy
--- has no type, no kind and no rank of its own and accepts any actual argument.
--- There is no Fortran spelling for that in the F90 binding, so the registry
--- says `<any type>` -- the same thing the MPI standard calls a "choice buffer"
--- and mpi_f08 spells `type(*), dimension(..)`.
local function type_of(rec, mod)
  local ts = rec.body[3]
  if type(ts) ~= "table" then
    return nil
  end
  local base, kind = ts[1], ts[2]
  if base == "ASSUMED" then
    return "<any type>"
  elseif base == "INTEGER" then
    return kind == "4" and "integer" or ("integer(" .. kind .. ")")
  elseif base == "REAL" then
    if kind == "8" then
      return "double precision"
    elseif kind == "4" then
      return "real"
    end
    return "real(" .. kind .. ")"
  elseif base == "COMPLEX" then
    if kind == "8" then
      return "double complex"
    elseif kind == "4" then
      return "complex"
    end
    return "complex(" .. kind .. ")"
  elseif base == "LOGICAL" then
    return kind == "4" and "logical" or ("logical(" .. kind .. ")")
  elseif base == "CHARACTER" then
    return "character(len=*)"
  elseif base == "DERIVED" or base == "CLASS" then
    local dr = mod.recs[tonumber(kind)]
    return "type(" .. derived_name(dr and dr.name) .. ")"
  elseif base == "UNKNOWN" then
    -- a dummy procedure (MPI_Comm_create_keyval's copy/delete callbacks)
    if has_attr(rec, "PROCEDURE") then
      return "external"
    end
    return nil
  end
  return nil
end

local INTENT = { IN = "in", OUT = "out", INOUT = "inout" }

--- One `interface[i]` element from a dummy record.
local function dummy_entry(rec, mod)
  local e = { name = rec.name }
  e.type = type_of(rec, mod)
  local intent = INTENT[(rec.body[1] or {})[2] or ""]
  if intent then
    e.intent = intent
  end
  if has_attr(rec, "OPTIONAL") then
    e.optional = true
  end
  local spec = array_spec(rec)
  if spec then
    e.dim = dim_of(spec)
  end
  return e
end

-- ---------------------------------------------------------------------------
-- Display names
-- ---------------------------------------------------------------------------

--- `mpi_comm_rank` -> `MPI_Comm_rank` (MPI's own mixed case: prefix upper,
--- first word capitalised, the rest lower). `*_fn` names are the predefined
--- callbacks, which the standard writes entirely upper (`MPI_COMM_DUP_FN`).
local function display_name(lname)
  if lname:match("_fn$") then
    return lname:upper()
  end
  local rest = lname:match("^mpi_(.*)$")
  if not rest then
    return lname
  end
  return "MPI_" .. rest:sub(1, 1):upper() .. rest:sub(2)
end

-- ---------------------------------------------------------------------------
-- Serializer -- sorted keys at every level, two-space indent, no trailing WS
-- ---------------------------------------------------------------------------

local IDENT = "^[%a_][%w_]*$"

-- Lua's own reserved words are legal registry keys (`do`, `if`, `end` are all
-- OpenMP constructs) but may not be written bare in a table constructor.
local RESERVED = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

--- Quote one line of a string as a Lua literal (no newlines inside).
local function q1(s)
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "\\r"):gsub("\t", "\\t")
  s = s:gsub("\n", "\\n")
  return '"' .. s .. '"'
end

--- Quote a string so the emitted Lua loads back byte-identically AND reads in a
--- diff: a multi-line description is emitted as one quoted chunk per source
--- line, joined with `..`, so a 20-line description is 20 lines in the file
--- rather than one 2 kB line.
---
--- It deliberately does NOT use Lua's backslash-newline continuation: that
--- escape inserts a newline of its own, so `"a\n\<newline>b"` loads as `a\n\nb`
--- and every paragraph in the corpus would silently double.
---@param s string
---@param ind string indent of the line this value starts on
---@return string
local function q(s, ind)
  if not s:find("\n", 1, true) then
    return q1(s)
  end
  local lines = {}
  local from = 1
  while true do
    local nl = s:find("\n", from, true)
    if not nl then
      lines[#lines + 1] = s:sub(from)
      break
    end
    lines[#lines + 1] = s:sub(from, nl - 1) .. "\n"
    from = nl + 1
  end
  local parts = {}
  for i, l in ipairs(lines) do
    parts[i] = q1(l)
  end
  return table.concat(parts, " ..\n" .. ind .. "  ")
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    n = n + 1
  end
  return n == #t
end

local emit
--- @param v any
--- @param ind string current indent
--- @param out string[] accumulator
emit = function(v, ind, out)
  local tv = type(v)
  if tv == "string" then
    out[#out + 1] = q(v, ind)
  elseif tv == "number" or tv == "boolean" then
    out[#out + 1] = tostring(v)
  elseif tv == "table" then
    if next(v) == nil then
      out[#out + 1] = "{}"
      return
    end
    local nind = ind .. "  "
    out[#out + 1] = "{\n"
    if is_array(v) then
      for _, item in ipairs(v) do
        out[#out + 1] = nind
        emit(item, nind, out)
        out[#out + 1] = ",\n"
      end
    else
      local keys = {}
      for k in pairs(v) do
        keys[#keys + 1] = k
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        out[#out + 1] = nind
        if type(k) == "string" and k:match(IDENT) and not RESERVED[k] then
          out[#out + 1] = k .. " = "
        else
          out[#out + 1] = "[" .. q1(tostring(k)) .. "] = "
        end
        emit(v[k], nind, out)
        out[#out + 1] = ",\n"
      end
    end
    out[#out + 1] = ind .. "}"
  else
    die("cannot serialize " .. tv)
  end
end

---@param tbl table
---@return string
local function serialize(tbl)
  local out = { "return " }
  emit(tbl, "", out)
  out[#out + 1] = "\n"
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Prose
-- ---------------------------------------------------------------------------

--- Strip trailing blanks per line and the final newline: they would become
--- trailing whitespace in the generated file, and markdown hard-breaks are not
--- used anywhere in this corpus.
local function clean(s)
  if type(s) ~= "string" then
    return nil
  end
  s = s:gsub("[ \t]+\n", "\n"):gsub("%s+$", "")
  if s == "" then
    return nil
  end
  return s
end

--- Undo the hanging indent the markdown reflow left behind.
---
--- Prose in `parsed-mpi-omp.json` arrives reflowed, as
--- `"...within **comm**,\n counting from ZERO..."` -- the first line flush and
--- every continuation line carrying the SAME small indent (one space in the
--- descriptions, two in the `**Returns**` blocks). Markdown does not care, but
--- nvim's float renders the spaces literally, so 306 lines of MPI hover used to
--- open with a stray column or two. Design A11 puts the conversion here
--- ("convert once, at generation time") rather than in the renderer, which
--- would pay for it on every keystroke and could not be seen in a `git diff`.
---
--- The rule is deliberately narrow. It fires only on the artifact's exact
--- shape and leaves anything it does not recognise completely alone:
---   * the first line must be flush left -- a wholly indented block is a
---     literal, not a reflowed paragraph;
---   * every non-blank continuation line outside a fence must carry the SAME
---     indent, and that indent must be > 0. One flush continuation line, or one
---     line indented differently, and the whole field is left as authored --
---     that is what protects `mpi_status_size`'s 4-space literal block;
---   * a markdown list anywhere in the field disqualifies it outright: under a
---     `- ` item an indent is continuation and means something. OpenMP's
---     `schedule` is the case -- a real list whose 2-space continuations must
---     survive;
---   * the interior of a ```-fence is never touched: indentation there is the
---     code's own. The fence markers sit outside and dedent with the prose.
---@param s string|nil
---@return string|nil
local function dedent(s)
  if type(s) ~= "string" or not s:find("\n", 1, true) then
    return s
  end
  local lines = vim.split(s, "\n", { plain = true })
  if lines[1]:match("^%s") then
    return s
  end
  local n, fenced = nil, false
  for i = 1, #lines do
    local l = lines[i]
    local marker = l:match("^%s*```") ~= nil
    if marker or not fenced then
      if l:find("\t", 1, true) or l:match("^%s*[%-%*%+] ") or l:match("^%s*%d+%.[ \t]") then
        return s
      end
      if i > 1 and l:match("%S") then
        local w = #(l:match("^ *"))
        if w == 0 or (n ~= nil and n ~= w) then
          return s
        end
        n = w
      end
    end
    if marker then
      fenced = not fenced
    end
  end
  if n == nil then
    return s
  end
  local pat = "^" .. string.rep(" ", n)
  fenced = false
  for i = 2, #lines do
    local l = lines[i]
    local marker = l:match("^%s*```") ~= nil
    if marker or not fenced then
      lines[i] = (l:gsub(pat, "", 1))
    end
    if marker then
      fenced = not fenced
    end
  end
  return table.concat(lines, "\n")
end

--- Fields that hold human prose, and so get `dedent`. `example` is NOT one of
--- them: it is code, and its indentation is meaning.
local PROSE_TEXT = { summary = true, description = true, result = true, binding_note = true }

--- Prose argument names normalised for comparison with `interface`:
--- `ierr` -> `ierror` (the F90 binding's own spelling) and `recvbuf(*)` ->
--- `recvbuf` (array specs belong in `interface[i].dim`, not in the name).
local function norm_arg(a)
  a = a:lower():gsub("%b()", ""):gsub("%s", "")
  if a == "ierr" then
    return "ierror"
  end
  return a
end

-- The argument-order gate below is a HARD error, never a warning: `mpi_isend`
-- and `mpi_irecv` really do contradict themselves in the shipped prose (usage
-- line `dest, tag, datatype`, interface fence `datatype, dest, tag`), and an
-- inlay hint built from the wrong one is a silent correctness bug. As of the
-- current corpus nothing trips it, because `parse_md.py` already takes
-- `sig_args` from the typed interface fence where one exists -- and because
-- `norm_arg` folds `ierr` to `ierror` first, which is the ONLY normalisation
-- applied and is needed by exactly two entries, `mpi_allreduce` and
-- `mpi_reduce` (both spell the status argument `ierr` in their usage line and
-- `ierror` in their interface; the compiler says `ierror`).

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local text = zcat(MOD_MPI)
if not text then
  die("cannot read " .. MOD_MPI .. " (is Open MPI installed?)")
end
local header = text:sub(1, (text:find("\n") or 1) - 1)
if not header:find(EXPECTED_HEADER, 1, true) then
  die(("%s is %q, expected %q -- refusing to parse a different module format")
    :format(MOD_MPI, header, EXPECTED_HEADER))
end

local mod = parse_mod(text)

-- f08 twin, for binding_note only
local f08 = nil
do
  local t = zcat(MOD_F08)
  if t and t:find(EXPECTED_HEADER, 1, true) then
    f08 = parse_mod(t)
  end
end

local prose = {}
do
  local f = io.open(PROSE, "r")
  if f then
    local raw = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, raw)
    if ok then
      prose = decoded
    end
  end
end

-- --- collect routines ------------------------------------------------------

local routines = {} -- lname -> { rec, dummies }
local generics = {} -- lname of every GENERIC record, so `_cptr` can fold into it
for _, r in ipairs(mod.order) do
  if type(r.body[1]) == "table" and r.body[1][1] == "PROCEDURE" and r.name and has_attr(r, "GENERIC") then
    generics[r.name] = true
  end
end

local skipped_sizeof = 0
for _, r in ipairs(mod.order) do
  local attrs = r.body[1]
  if type(attrs) == "table" and attrs[1] == "PROCEDURE" and r.name and r.name:match("^mpi_")
      and not has_attr(r, "GENERIC") and not r.name:match("_f08$") then
    local key = r.name
    if key:match("^mpi_sizeof_.+_r%d+$") or key:match("^mpi_sizeof_.+_scalar$") then
      -- 192 TKR expansions of the MPI_Sizeof generic; nobody writes those names
      skipped_sizeof = skipped_sizeof + 1
      key = nil
    elseif key:match("_cptr$") and generics[key:gsub("_cptr$", "")] then
      -- MPI_Alloc_mem / MPI_Win_allocate: the only specific of a generic whose
      -- other specific takes an INTEGER baseptr. Publish it under the name a
      -- user actually writes.
      key = key:gsub("_cptr$", "")
    end
    if key and not routines[key] then
      routines[key] = r
    end
  end
end

local sizeof_any_type = false
-- MPI_Sizeof: one entry, from the generic. Its 192 specifics differ only in the
-- type and rank of `x`, which is exactly what `<any type>` means here.
if generics.mpi_sizeof then
  local spec
  for _, r in ipairs(mod.order) do
    if r.name == "mpi_sizeof_character_scalar" then
      spec = r
    end
  end
  if spec then
    routines.mpi_sizeof = spec
    -- `x` is the generic's choice argument: the 192 specifics differ only in
    -- its type and rank, which is exactly what `<any type>` means here.
    sizeof_any_type = true
  end
end

-- --- f08 binding notes -----------------------------------------------------

local function f08_note(lname)
  if not f08 then
    return nil
  end
  local want = lname .. "_f08"
  local rec
  for _, r in ipairs(f08.order) do
    if r.name == want then
      rec = r
      break
    end
  end
  if not rec then
    return nil
  end
  local spelled, ierror_opt = {}, false
  for _, did in ipairs(rec.body[6] or {}) do
    local d = f08.recs[tonumber(did)]
    if d then
      local t = type_of(d, f08)
      if d.name == "ierror" and has_attr(d, "OPTIONAL") then
        ierror_opt = true
      end
      if t and t:match("^type%(") then
        spelled[#spelled + 1] = ("%s as %s"):format(d.name, t)
      end
    end
  end
  local parts = {}
  if #spelled == 1 then
    parts[#parts + 1] = "mpi_f08 spells " .. spelled[1]
  elseif #spelled > 1 then
    local last = table.remove(spelled)
    parts[#parts + 1] = "mpi_f08 spells " .. table.concat(spelled, ", ") .. " and " .. last
  end
  if ierror_opt then
    if #parts > 0 then
      parts[#parts + 1] = "ierror is OPTIONAL"
    else
      parts[#parts + 1] = "mpi_f08 makes ierror OPTIONAL"
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "; ")
end

-- --- build procedure entries -----------------------------------------------

local data = {}
local n_sub, n_fun, n_const = 0, 0, 0
local ierr_normalised = {}

for lname, rec in pairs(routines) do
  local e = {
    name = display_name(lname),
    kind = has_attr(rec, "FUNCTION") and "function" or "subroutine",
    module = "mpi",
  }
  local iface, names = {}, {}
  for _, did in ipairs(rec.body[6] or {}) do
    local d = mod.recs[tonumber(did)]
    if d then
      iface[#iface + 1] = dummy_entry(d, mod)
      names[#names + 1] = d.name
    end
  end
  if lname == "mpi_sizeof" and sizeof_any_type and iface[1] then
    iface[1].type = "<any type>"
    iface[1].dim = nil
  end
  e.interface = iface
  e.signature = e.name .. "(" .. table.concat(names, ", ") .. ")"
  if e.kind == "function" then
    e.result_type = type_of(rec, mod)
  end
  e.href = ("https://www.open-mpi.org/doc/current/man3/%s.3.php"):format(e.name)
  local note = f08_note(lname)
  if note then
    e.binding_note = note
  end
  if e.kind == "function" then
    n_fun = n_fun + 1
  else
    n_sub = n_sub + 1
  end
  data[lname] = e
end

-- --- constants from mpif*.h ------------------------------------------------
--
-- `parameter (NAME=value)` gives the value; the matching declaration a few
-- lines above gives the type. The sentinels (MPI_IN_PLACE, MPI_STATUS_IGNORE,
-- ...) are COMMON-block variables with a declaration and no parameter, so they
-- appear with a type and no value -- which is the truth about them.

local function eval_int(v)
  if v:match("^[%d%s%+%-%*/%(%)]+$") then
    local ok, n = pcall(load, "return " .. v)
    if ok and n then
      local ok2, r = pcall(n)
      if ok2 and type(r) == "number" and r == math.floor(r) then
        return tostring(math.floor(r))
      end
    end
  end
  return v
end

do
  local files = vim.fn.glob(INCLUDE_DIR .. "/mpif*.h", false, true)
  table.sort(files)
  for _, path in ipairs(files) do
    local base = vim.fn.fnamemodify(path, ":t")
    local fh = io.open(path, "r")
    if fh then
      local decl_type = {}
      local lines = {}
      for line in fh:lines() do
        lines[#lines + 1] = line
      end
      fh:close()
      for _, line in ipairs(lines) do
        if not line:match("^%s*!") then
          local ty, nm = line:match("^%s*(integer%s*%b()?)%s+([%a_][%w_]*)")
          if not ty then
            ty, nm = line:match("^%s*(integer)%s+([%a_][%w_]*)")
          end
          if not ty then
            ty, nm = line:match("^%s*(logical)%s+([%a_][%w_]*)")
          end
          if not ty then
            ty, nm = line:match("^%s*(character)%s+([%a_][%w_]*)")
          end
          if not ty then
            ty, nm = line:match("^%s*(double%s+precision)%s+([%a_][%w_]*)")
          end
          if ty and nm and nm:lower() ~= "parameter" then
            decl_type[nm:lower()] = (ty:gsub("%s+", " "))
          end
          local pn, pv = line:match("^%s*parameter%s*%(%s*([%a_][%w_]*)%s*=%s*(.-)%s*%)%s*$")
          if pn and pv and pn:lower():match("^mpi_") then
            local lname = pn:lower()
            if not data[lname] then
              data[lname] = {
                name = pn:upper(),
                kind = "constant",
                module = "mpi",
                value = eval_int(pv),
                type = decl_type[lname] or "integer",
                section = base,
                binding_note = "value as installed here (Open MPI 5.0.10, " .. base .. ")",
              }
              n_const = n_const + 1
            end
          end
        end
      end
      -- declaration-only sentinels in this file
      for _, line in ipairs(lines) do
        if not line:match("^%s*!") then
          local ty, nm = line:match("^%s*(integer)%s+(MPI_[%w_]*)")
          if not ty then
            ty, nm = line:match("^%s*(character)%s+(MPI_[%w_]*)")
          end
          if ty and nm then
            local lname = nm:lower()
            if not data[lname] then
              data[lname] = {
                name = nm:upper(),
                kind = "constant",
                module = "mpi",
                type = ty,
                section = base,
                binding_note = "declared in " .. base .. " as installed here (Open MPI 5.0.10)",
              }
              n_const = n_const + 1
            end
          end
        end
      end
    end
  end
end

-- --- load the overrides, and create shells for the entries they ADD ---------
--
-- An override key that no machine source knows (MPI_STATUS_IGNORE has no
-- `parameter` line; the `mpi_f08` module is not a symbol at all) becomes a
-- whole entry. That happens BEFORE the prose merge so those entries can pick
-- up the prose too; the override's own field values are applied after it, so
-- they still win.

local overrides = {}
do
  -- One door onto the hand-authored tables (snippets/fortran-overrides.lua),
  -- so "where do overrides live" has a single answer. `dofile` and not
  -- `require`: this script runs under `-u NONE` with no package.path.
  local loader = dofile(script_dir .. "/fortran-overrides.lua")
  local t, _, err = loader.load("mpi", overrides_dir)
  if err then
    die("overrides/mpi.lua: " .. err)
  end
  overrides = t
end

-- --- the machine's keys are not the override's to write -------------------
--
-- Argument order, the typed dummy list and a constant's value come from the
-- compiler, and an override that disagrees is a data bug, not a preference.
-- Declining to OVERWRITE them is not enough: an override on an entry the
-- machine source happens not to know would have INJECTED an `interface` that
-- no `.mod` ever vouched for, and every inlay hint and signature-help offset
-- downstream would have been built from it. So carrying the key at all is
-- fatal, whether or not a machine value exists to protect.
local MACHINE_OWNED = { interface = true, signature = true, result_type = true, value = true }
--- ... on the kinds a machine source describes. A `module` entry (`mpi_f08`)
--- has no compiler record, so its `signature` is the override's to give.
local MACHINE_KINDS = { subroutine = true, ["function"] = true, constant = true }

local override_keys = vim.tbl_keys(overrides)
table.sort(override_keys)
for _, lname in ipairs(override_keys) do
  local o = overrides[lname]
  local kind = (data[lname] and data[lname].kind) or (type(o) == "table" and o.kind) or nil
  if type(o) == "table" and kind and MACHINE_KINDS[kind] then
    for _, k in ipairs({ "interface", "result_type", "signature", "value" }) do
      if MACHINE_OWNED[k] and o[k] ~= nil then
        die(("overrides/mpi.lua: %s (%s) sets `%s`, which the compiler owns -- "
          .. "remove it; argument order and types come from mpi.mod"):format(lname, kind, k))
      end
    end
  end
end

local orphan_overrides = {}
for lname, o in pairs(overrides) do
  if not data[lname] then
    if o.kind then
      -- deliberate: the override declares what the entry IS, so it is added
      data[lname] = {
        name = o.name or lname:upper(),
        kind = o.kind,
        module = o.module or "mpi",
      }
      if o.kind == "constant" then
        n_const = n_const + 1
      end
    else
      -- a `standard`/`summary` patch for a name no machine source knows: a
      -- typo, a deprecated routine, or a generic with no specific in this
      -- build. Never invent an entry from one; say so instead.
      orphan_overrides[#orphan_overrides + 1] = lname
    end
  end
end
table.sort(orphan_overrides)
if #orphan_overrides > 0 then
  io.stderr:write("gen-mpi: overrides for names this install does not have: "
    .. table.concat(orphan_overrides, ", ") .. "\n")
end

-- --- merge the prose -------------------------------------------------------
--
-- Prose only ever fills a field that is still empty. Keys are visited in sorted
-- order, exact names before the legacy snippet-prefix aliases (`mpibcast` for
-- `mpi_bcast`), so the result does not depend on hash order.

local PROSE_FIELDS = { "summary", "description", "result", "see_also", "standard" }

local function merge_prose(lname, p)
  local e = data[lname]
  if not e then
    return
  end
  -- argument-order gate (design C3, failure mode 2)
  if e.interface and type(p.sig_args) == "table" and #p.sig_args > 0 then
    local got, want = {}, {}
    for i, a in ipairs(p.sig_args) do
      got[i] = norm_arg(a)
    end
    for i, d in ipairs(e.interface) do
      want[i] = d.name
    end
    local same = #got == #want
    if same then
      for i = 1, #got do
        if got[i] ~= want[i] then
          same = false
        end
      end
    end
    if not same then
      die(("%s: prose sig_args disagree with the compiler's interface\n  prose: %s\n  .mod : %s")
        :format(lname, table.concat(got, ", "), table.concat(want, ", ")))
    end
    for _, a in ipairs(p.sig_args) do
      if a:lower():gsub("%b()", "") == "ierr" then
        ierr_normalised[#ierr_normalised + 1] = lname
      end
    end
  end
  for _, f in ipairs(PROSE_FIELDS) do
    local v = p[f]
    if type(v) == "string" then
      v = clean(v)
      if PROSE_TEXT[f] then
        v = dedent(v)
      end
    end
    if v ~= nil and v ~= vim.NIL and e[f] == nil then
      e[f] = v
    end
  end
  local ex = clean(p.example_code)
  if ex and e.example == nil then
    e.example = ex
  end
  if type(p.params) == "table" and e.params == nil then
    local params = {}
    for k, v in pairs(p.params) do
      local cv = dedent(clean(v))
      if cv then
        params[norm_arg(k)] = cv
      end
    end
    if next(params) then
      e.params = params
    end
  end
end

do
  local exact, alias = {}, {}
  for key, p in pairs(prose) do
    if type(p) == "table" and key:match("^mpi") then
      if data[key] then
        exact[#exact + 1] = key
      else
        local alt = key:gsub("^mpi", "mpi_")
        if data[alt] then
          alias[#alias + 1] = key
        end
      end
    end
  end
  table.sort(exact)
  table.sort(alias)
  for _, k in ipairs(exact) do
    merge_prose(k, prose[k])
  end
  for _, k in ipairs(alias) do
    merge_prose((k:gsub("^mpi", "mpi_")), prose[k])
  end
end

-- --- apply the override field values ---------------------------------------

-- `kind` still belongs to the machine where the machine has one: the override
-- files spell it for the entries they ADD (above), not to reclassify a
-- compiler-known routine. The four keys of MACHINE_OWNED never get this far --
-- carrying one is fatal at load time.
for lname, o in pairs(overrides) do
  local e = data[lname]
  for k, v in pairs(e and o or {}) do
    if k == "kind" and e[k] ~= nil then
      -- keep the compiler's classification
    elseif PROSE_TEXT[k] and type(v) == "string" then
      e[k] = dedent(v)
    elseif k == "params" and type(v) == "table" then
      local params = {}
      for pk, pv in pairs(v) do
        params[pk] = type(pv) == "string" and dedent(pv) or pv
      end
      e[k] = params
    else
      e[k] = v
    end
  end
end

-- The signature is ALWAYS regenerated from `interface`, after any rename, so a
-- prose usage line can never reach it (design C3, failure modes 1, 3 and 4).
for _, e in pairs(data) do
  if e.interface then
    local names = {}
    for i, d in ipairs(e.interface) do
      names[i] = d.name
    end
    e.signature = e.name .. "(" .. table.concat(names, ", ") .. ")"
  end
end

-- --- validate --------------------------------------------------------------

for lname, e in pairs(data) do
  if not lname:match(IDENT) then
    die("key is not an identifier: " .. lname)
  end
  if not e.name or not e.kind then
    die(lname .. ": missing name or kind")
  end
end

data._meta = {
  generator = "snippets/gen-mpi.lua",
  source = "~/miniconda3/include/mpi.mod",
  source_f08 = "~/miniconda3/include/mpi_f08_interfaces.mod",
  source_constants = "~/miniconda3/include/mpif*.h",
  source_version = header,
  install = "Open MPI 5.0.10",
}

-- --- write -----------------------------------------------------------------

vim.fn.mkdir(out_dir, "p")
local out_path = out_dir .. "/mpi.lua"
local fh = assert(io.open(out_path, "w"))
fh:write(serialize(data))
fh:close()

local n_total = 0
for k in pairs(data) do
  if k ~= "_meta" then
    n_total = n_total + 1
  end
end
table.sort(ierr_normalised)
local uniq, seen = {}, {}
for _, v in ipairs(ierr_normalised) do
  if not seen[v] then
    seen[v] = true
    uniq[#uniq + 1] = v
  end
end
io.stderr:write(("gen-mpi: %s -- %d entries (%d subroutine, %d function, %d constant); %d mpi_sizeof specifics folded\n")
  :format(out_path, n_total, n_sub, n_fun, n_const, skipped_sizeof))
io.stderr:write("gen-mpi: prose spelled the status argument `ierr` in: " .. table.concat(uniq, ", ") .. "\n")

return M
