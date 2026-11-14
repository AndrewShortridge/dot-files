#!/usr/bin/env -S nvim -l
-- =============================================================================
-- gen-omp.lua -- generate lua/andrew/fortran/data/openmp.lua
-- =============================================================================
--
-- WHY THIS EXISTS
--
-- Eighteen of the OpenMP entries in the shipped prose had a usage line and no
-- typed interface at all -- every `omp_*_lock`, every `omp_set_*` -- so hover
-- could say what a routine was for but not what to pass it, and the 31-entry
-- hand-written `openmp.SIGNATURES` table was the only thing feeding inlay
-- hints. gfortran ships `omp_lib.f90`: 917 lines of ordinary Fortran holding
-- the whole runtime interface, fully typed, with intents. That is the source.
--
-- Two things it does NOT contain: the directives and clauses (`!$OMP PARALLEL`,
-- `PRIVATE(list)`) -- they are syntax, not a library, so they come entirely
-- from `snippets/overrides/openmp.lua` -- and any documentation whatsoever,
-- which comes from the parsed prose.
--
-- The `*_8` twins (`omp_set_num_threads_8`) are skipped: they are the
-- integer(8) overloads of the specific generic interface above them and carry
-- no information a user needs.
--
-- Output is byte-idempotent (sorted keys at every level), so
-- `tests/fortran_registry_fresh_spec.lua` can regenerate and compare bytes.
--
-- Usage:  nvim -l snippets/gen-omp.lua [--out <dir>] [--prose <file>]
--                                     [--overrides-dir <dir>]
--
-- NOTE ON DUPLICATION: gen-mpi.lua carries its own copy of the serializer.
-- Two ~100-line copies beat a third module that only two offline scripts
-- require, and the generators must run standalone under `-u NONE`. The ONE
-- thing they share is `snippets/fortran-overrides.lua`, because "where do the
-- hand-authored tables live" must have exactly one answer.

local M = {}

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

local PROSE = prose_path or (script_dir .. "/parsed-mpi-omp.json")

local function die(msg)
  io.stderr:write("gen-omp: " .. msg .. "\n")
  os.exit(1)
end

--- `$(gfortran -print-file-name=finclude)/omp_lib.f90`
local function omp_lib_path()
  local out = vim.fn.system({ "gfortran", "-print-file-name=finclude" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local dir = vim.trim(out)
  if dir == "" or dir == "finclude" then
    return nil
  end
  local p = dir .. "/omp_lib.f90"
  if vim.fn.filereadable(p) ~= 1 then
    return nil
  end
  return p
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

local function serialize(tbl)
  local out = { "return " }
  emit(tbl, "", out)
  out[#out + 1] = "\n"
  return table.concat(out)
end

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

-- ---------------------------------------------------------------------------
-- omp_lib.f90 reader
-- ---------------------------------------------------------------------------

--- Fold continuations, drop comments and preprocessor lines, normalise spacing.
---@param path string
---@return string[] statements
local function statements(path)
  local fh = io.open(path, "r")
  if not fh then
    return {}
  end
  local out, pending = {}, nil
  for raw in fh:lines() do
    local line = raw
    -- `!GCC$` directives and `#if`/`#endif` carry nothing this needs
    if line:match("^%s*#") or line:match("^%s*!") then
      line = ""
    else
      line = line:gsub("%s*!.*$", "")
    end
    line = vim.trim(line)
    if line ~= "" then
      -- a continued line may also START with `&`
      line = line:gsub("^&%s*", "")
      local cont = line:match("^(.-)%s*&$")
      if cont then
        pending = (pending and (pending .. " ") or "") .. cont
      else
        if pending then
          line = pending .. " " .. line
          pending = nil
        end
        out[#out + 1] = (line:gsub("%s+", " "))
      end
    end
  end
  fh:close()
  return out
end

--- `integer (4)` -> `integer`, `integer (omp_lock_kind)` -> `integer(omp_lock_kind)`.
local function norm_type(t)
  t = vim.trim(t):lower():gsub("%s*%(%s*", "("):gsub("%s*%)", ")")
  t = t:gsub("%s+", " ")
  t = t:gsub("^(%a+)%(kind=", "%1(")
  if t == "integer(4)" then
    return "integer"
  elseif t == "logical(4)" then
    return "logical"
  elseif t == "real(4)" then
    return "real"
  elseif t == "real(8)" then
    return "double precision"
  end
  return t
end

--- Split a comma-separated list, ignoring commas inside parentheses.
local function split_top(s)
  local parts, depth, cur = {}, 0, {}
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
    end
    if c == "," and depth == 0 then
      parts[#parts + 1] = vim.trim(table.concat(cur))
      cur = {}
    else
      cur[#cur + 1] = c
    end
  end
  local last = vim.trim(table.concat(cur))
  if last ~= "" then
    parts[#parts + 1] = last
  end
  return parts
end

--- Parse one declaration statement into { {name=, type=, intent=, optional=, dim=}, ... }
local function parse_decl(stmt)
  local lhs, rhs = stmt:match("^(.-)%s*::%s*(.+)$")
  if not lhs or not rhs then
    return nil
  end
  local pieces = split_top(lhs)
  local ty = norm_type(pieces[1] or "")
  local intent, optional = nil, false
  for i = 2, #pieces do
    local a = pieces[i]:lower():gsub("%s", "")
    local it = a:match("^intent%((%a+)%)$")
    if it then
      intent = it
    elseif a == "optional" then
      optional = true
    end
  end
  local out = {}
  for _, ent in ipairs(split_top(rhs)) do
    local nm, dim = ent:match("^([%a_][%w_]*)%s*(%b())$")
    if not nm then
      nm = ent:match("^([%a_][%w_]*)$")
    end
    if nm then
      local d = { name = nm:lower(), type = ty }
      if intent then
        d.intent = intent
      end
      if optional then
        d.optional = true
      end
      if dim then
        d.dim = (dim:gsub("%s", ""))
      end
      out[#out + 1] = d
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Build from the machine source
-- ---------------------------------------------------------------------------

local src = omp_lib_path()
if not src then
  die("cannot find omp_lib.f90 via `gfortran -print-file-name=finclude`")
end

local data = {}
local n_sub, n_fun, n_const, n_type, n_skipped8 = 0, 0, 0, 0, 0

do
  local stmts = statements(src)
  local mod = nil
  local proc = nil -- { key, kind, args = {}, decls = {} }
  for _, st in ipairs(stmts) do
    local low = st:lower()
    local mname = low:match("^module%s+([%a_][%w_]*)$")
    if mname then
      mod = mname
    elseif low:match("^end%s+module") then
      mod = nil
    elseif proc then
      if low:match("^end%s+subroutine") or low:match("^end%s+function") then
        if not proc.key:match("_8$") then
          local e = {
            name = proc.key,
            kind = proc.kind,
            module = "omp_lib",
          }
          local iface = {}
          for _, a in ipairs(proc.args) do
            local d = proc.decls[a] or { name = a }
            iface[#iface + 1] = d
          end
          e.interface = iface
          e.signature = proc.key .. "(" .. table.concat(proc.args, ", ") .. ")"
          if proc.kind == "function" then
            local r = proc.decls[proc.key]
            e.result_type = r and r.type or nil
            n_fun = n_fun + 1
          else
            n_sub = n_sub + 1
          end
          data[proc.key] = data[proc.key] or e
        else
          n_skipped8 = n_skipped8 + 1
        end
        proc = nil
      else
        local ds = parse_decl(st)
        for _, d in ipairs(ds or {}) do
          proc.decls[d.name] = d
        end
      end
    else
      local kind, nm, args = low:match("^(subroutine)%s+([%a_][%w_]*)%s*(%b())")
      if not kind then
        kind, nm, args = low:match("^(function)%s+([%a_][%w_]*)%s*(%b())")
      end
      if kind and nm then
        local list = {}
        for _, a in ipairs(split_top(args:sub(2, -2))) do
          if a ~= "" then
            list[#list + 1] = a
          end
        end
        proc = { key = nm, kind = kind, args = list, decls = {} }
      elseif mod then
        -- constants
        local decl = st:match("^(.*)$")
        if low:find("parameter", 1, true) and low:find("::", 1, true) then
          local lhs, rhs = decl:match("^(.-)%s*::%s*(.+)$")
          if lhs and rhs and lhs:lower():find("parameter", 1, true) then
            local ty = norm_type(split_top(lhs)[1] or "integer")
            for _, ent in ipairs(split_top(rhs)) do
              local nm2, val = ent:match("^([%a_][%w_]*)%s*=%s*(.+)$")
              if nm2 then
                local key = nm2:lower()
                if not data[key] then
                  data[key] = {
                    name = key,
                    kind = "constant",
                    module = "omp_lib",
                    type = ty,
                    value = vim.trim(val),
                    section = mod,
                  }
                  n_const = n_const + 1
                end
              end
            end
          end
        end
        local tname = low:match("^type%s+([%a_][%w_]*)$")
        if tname and not data[tname] then
          data[tname] = {
            name = tname,
            kind = "type",
            module = "omp_lib",
            signature = "type(" .. tname .. ")",
            section = mod,
          }
          n_type = n_type + 1
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Overrides (agent DATA authors these: directives, clauses, the module entry)
-- ---------------------------------------------------------------------------

local overrides = {}
local overrides_present = false
do
  -- One door onto the hand-authored tables (snippets/fortran-overrides.lua),
  -- so "where do overrides live" has a single answer. `dofile` and not
  -- `require`: this script runs under `-u NONE` with no package.path.
  local loader = dofile(script_dir .. "/fortran-overrides.lua")
  local t, present, err = loader.load("openmp", overrides_dir)
  if err then
    die("overrides/openmp.lua: " .. err)
  end
  overrides = t
  overrides_present = present
end

-- --- the machine's keys are not the override's to write -------------------
--
-- Argument order, the typed dummy list, a function's result type and a
-- constant's value come from `omp_lib.f90`, and an override that disagrees is
-- a data bug. Declining to OVERWRITE them is not enough: an override on an
-- entry the machine source happens not to know would have INJECTED an
-- `interface` no compiler ever vouched for, and every inlay hint and
-- signature-help offset downstream would have been built from it. So carrying
-- the key at all is fatal, whether or not a machine value exists to protect.
--
-- It is fatal only on the kinds `omp_lib.f90` describes. A directive or clause
-- is syntax, not a library symbol: there is no machine record of `PRIVATE`, so
-- its `signature` is the override's to give and always has been.
local MACHINE_OWNED = { interface = true, signature = true, result_type = true, value = true }
local MACHINE_KINDS = { subroutine = true, ["function"] = true, constant = true }

local override_keys = vim.tbl_keys(overrides)
table.sort(override_keys)
for _, lname in ipairs(override_keys) do
  local o = overrides[lname]
  local kind = (data[lname] and data[lname].kind) or (type(o) == "table" and o.kind) or nil
  if type(o) == "table" and kind and MACHINE_KINDS[kind] then
    for _, k in ipairs({ "interface", "result_type", "signature", "value" }) do
      if MACHINE_OWNED[k] and o[k] ~= nil then
        die(("overrides/openmp.lua: %s (%s) sets `%s`, which the compiler owns -- "
          .. "remove it; argument order and types come from omp_lib.f90"):format(lname, kind, k))
      end
    end
  end
end

-- An override entry the machine source knows nothing about -- every directive
-- and clause -- is ADDED whole.
for lname, o in pairs(overrides) do
  if not data[lname] then
    data[lname] = {
      name = o.name or lname:upper(),
      kind = o.kind or "directive",
      module = o.module or "OpenMP",
    }
  end
end

-- ---------------------------------------------------------------------------
-- Prose
-- ---------------------------------------------------------------------------
--
-- The prose keys three different ways and this is the whole mapping:
--   * a runtime routine is keyed by its real name (`omp_get_wtime`);
--   * a directive or clause is keyed `omp_<word>` OR `omp<word>` -- both
--     spellings exist, sometimes BOTH for the same construct, in which case the
--     longer body wins (the `omp_barrier` 883 B stub used to shadow the
--     `ompbarrier` 3414 B treatment; design C3);
--   * six keys are unreachable legacy and are dropped outright.

local LEGACY_DROP = {
  ["omp barrier"] = true,
  ["!$omp atomic"] = true,
  ompreduce = true,
  ompdosimd = true,
  omp_parallel_do = true,
  omp_parallel_do_simd = true,
}

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

--- Registry key for a prose key; nil when the entry is dropped.
local function registry_key(pkey)
  if LEGACY_DROP[pkey] then
    return nil
  end
  if data[pkey] then
    return pkey -- a runtime routine, or a directive an override already added
  end
  if pkey == "omp_lib" then
    return "omp_lib"
  end
  local w = pkey:match("^omp_(.+)$") or pkey:match("^omp(.+)$")
  if not w then
    return nil
  end
  w = w:gsub("%s+", "_")
  if not w:match(IDENT) then
    return nil
  end
  return w
end

-- pick the longer body when two prose keys land on the same registry key
local chosen = {}
do
  local keys = {}
  for k, v in pairs(prose) do
    if type(v) == "table" and k:match("^omp") then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  for _, pkey in ipairs(keys) do
    local rk = registry_key(pkey)
    if rk then
      local cur = chosen[rk]
      local body = type(prose[pkey].description) == "string" and #prose[pkey].description or 0
      if not cur or body > cur.body then
        chosen[rk] = { pkey = pkey, body = body }
      end
    end
  end
end

local PROSE_FIELDS = { "summary", "description", "result", "see_also", "standard" }

local shadowed = {}
do
  local rks = {}
  for rk in pairs(chosen) do
    rks[#rks + 1] = rk
  end
  table.sort(rks)
  for _, rk in ipairs(rks) do
    local p = prose[chosen[rk].pkey]
    local e = data[rk]
    if not e then
      -- a directive or clause with prose but no override yet: keep the prose,
      -- and let the override supply `kind`/`signature` on the next run.
      local title = type(p.title) == "string" and p.title or rk
      if rk == "omp_lib" then
        -- the module itself, not a construct: `registry.directive("omp")`
        -- answers with this entry on a `!$OMP` line.
        e = { name = "omp_lib", kind = "module", module = "omp_lib", signature = "use omp_lib" }
      else
        e = {
          name = rk:upper(),
          kind = title:match("^[%a_][%w_]*%b()$") and "clause" or "directive",
          module = "OpenMP",
        }
      end
      if title:match("^[%a_][%w_]*%b()$") then
        e.signature = title:gsub("^([%a_][%w_]*)", function(x) return x:upper() end)
      end
      data[rk] = e
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
          params[k] = cv
        end
      end
      if next(params) then
        e.params = params
      end
    end
    shadowed[#shadowed + 1] = rk .. "<-" .. chosen[rk].pkey
  end
end

-- ---------------------------------------------------------------------------
-- Apply the override field values (highest precedence except machine truth)
-- ---------------------------------------------------------------------------

-- The four keys of MACHINE_OWNED never get this far -- carrying one on a
-- procedure or constant is fatal at load time -- so this loop only has to keep
-- the compiler's `kind` and dedent the hand-authored prose.
for lname, o in pairs(overrides) do
  local e = data[lname]
  if e then
    for k, v in pairs(o) do
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
end

-- A procedure's signature is ALWAYS regenerated from its interface; a
-- directive's or clause's comes from the override and is left alone.
for _, e in pairs(data) do
  if e.interface then
    local names = {}
    for i, d in ipairs(e.interface) do
      names[i] = d.name
    end
    e.signature = e.name .. "(" .. table.concat(names, ", ") .. ")"
  end
end

for lname, e in pairs(data) do
  if not lname:match(IDENT) then
    die("key is not an identifier: " .. lname)
  end
  if not e.name or not e.kind then
    die(lname .. ": missing name or kind")
  end
end

data._meta = {
  generator = "snippets/gen-omp.lua",
  source = "$(gfortran -print-file-name=finclude)/omp_lib.f90",
  source_version = "GCC " .. vim.trim(vim.fn.system({ "gfortran", "-dumpversion" })),
  overrides = overrides_present and "snippets/overrides/openmp.lua" or "none (not present at generation time)",
}

vim.fn.mkdir(out_dir, "p")
local out_path = out_dir .. "/openmp.lua"
local fh = assert(io.open(out_path, "w"))
fh:write(serialize(data))
fh:close()

local n_total, kinds = 0, {}
for k, e in pairs(data) do
  if k ~= "_meta" then
    n_total = n_total + 1
    kinds[e.kind] = (kinds[e.kind] or 0) + 1
  end
end
local ks = {}
for k, v in pairs(kinds) do
  ks[#ks + 1] = k .. "=" .. v
end
table.sort(ks)
io.stderr:write(("gen-omp: %s -- %d entries (%s); %d `_8` twins skipped; overrides: %s\n")
  :format(out_path, n_total, table.concat(ks, " "), n_skipped8,
    overrides_present and "present" or "MISSING"))

return M
