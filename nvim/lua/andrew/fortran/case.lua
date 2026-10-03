-- =============================================================================
-- Fortran procedure-name capitalization rule
-- =============================================================================
-- House style: every intrinsic procedure and every procedure the project
-- defines is written in FULL CAPITALS -- `SQRT(x)`, `CALL HEATING(t)`,
-- `SUBROUTINE HEATING(t)`. Fortran is case-insensitive, so this is purely a
-- readability convention and rewriting to it can never change semantics.
--
-- Reported as diagnostics in a namespace of its own, so the rule coexists with
-- the compiler diagnostics from nvim-lint instead of competing for the same
-- namespace (:FortranCaseClear wipes only these).
--
-- WHAT IS CHECKED
--   NAME(              invocation position, NAME an intrinsic or a defined
--                      procedure. Fortran spells calls and array indexing
--                      identically, so an unknown NAME is never flagged.
--   CALL NAME          any amount of whitespace between the two, tabs included
--   SUBROUTINE NAME    the definition and its END terminator, so a renamed
--   END SUBROUTINE NAME   procedure does not end up half-capitalized
--   DO IF SELECT CASE  language keywords, by class -- see
--                      andrew.fortran.keywords for the lists and for what is
--                      deliberately left out of them
--   USE PHYSICS        module, submodule, program and derived-type NAMES,
--   TYPE(STATE)        wherever they appear next to the keyword that
--                      introduces or references them
--   .AND. .TRUE.       logical operators and literals -- matched by their
--                      dots, so the letters are rewritten and the dots are not
--
-- KEYWORDS ARE NOT RESERVED in Fortran: `integer :: if` is legal, so every
-- keyword is also a possible variable name. Uppercasing one either way is
-- semantically free, but capitalizing a variable is noise, so three positional
-- guards suppress the shapes in which a variable of that name gets written:
--
--   right of a `::`   the entity-declaration list is variable names
--   after a `%`       `obj%count` is a component reference
--   followed by `=`   `format = '(A)'`, `iostat=ios`, `p => x`, `type == 3`.
--                     A keyword introduces or terminates a statement, so it is
--                     never followed by `=` in any form.
--
-- WHAT IS NOT
--   Type specifications. `real(8) :: x` is a declaration and `y = real(i)` is
--   an intrinsic call, and they are the same six characters -- the difference
--   is context. Names that are both a type keyword and an intrinsic (real,
--   integer, character, logical, len, int, char, ...) are skipped in
--   declaration position; see is_type_spec_context.
--   Statements that look like calls: write, read, allocate, if, ... are
--   keywords, not procedures, and are absent from the intrinsic list.
--
-- CONFIGURATION (all optional, read live so :lua vim.g.x = y takes effect)
--   vim.g.fortran_case_check       = false  -- disable the on-save check
--   vim.g.fortran_case_severity    = "WARN" -- ERROR | WARN | INFO | HINT
--   vim.g.fortran_case_intrinsics  = false  -- stop checking intrinsics
--   vim.g.fortran_case_defined     = false  -- stop checking project procedures
--   vim.g.fortran_case_documented  = true   -- also check snippets/fortran-docs.json names
--   vim.g.fortran_case_all_calls   = true   -- also require CALL targets the
--                                              project does not define (MPI,
--                                              BLAS and other external libs)
--   vim.g.fortran_case_keywords    = false  -- stop checking language keywords
--                                  = { "control", "unit" }  -- or name the
--                                     classes to check; see andrew.fortran.keywords
--   vim.g.fortran_case_units       = false  -- stop checking module / type /
--                                              program / submodule NAMES

local scan = require("andrew.fortran.scan")
local intrinsics = require("andrew.fortran.intrinsics")
local keywords = require("andrew.fortran.keywords")

local M = {}

M.ns = vim.api.nvim_create_namespace("fortran_case")

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

--- Resolve vim.g.fortran_case_keywords into the set of keywords to check.
--- `false` disables the rule, a list names the classes, anything else (nil or
--- true) means every class.
---@return table<string, string> lowercase keyword -> class name
function M.keyword_set()
  local setting = vim.g.fortran_case_keywords
  if setting == false then
    return {}
  end
  if type(setting) == "table" then
    return keywords.set(setting)
  end
  return keywords.set(nil)
end

--- The dotted half of the same setting: `.AND.`, `.TRUE.`.
---@return table<string, string> lowercase undotted word -> label
function M.dotted_set()
  local setting = vim.g.fortran_case_keywords
  if setting == false then
    return {}
  end
  if type(setting) == "table" then
    return keywords.dotted_set(setting)
  end
  return keywords.dotted_set(nil)
end

---@return { enabled: boolean, severity: integer, intrinsics: boolean, defined: boolean, documented: boolean, all_calls: boolean, keyword_set: table<string, string> }
function M.options()
  local sev = vim.g.fortran_case_severity
  return {
    enabled = vim.g.fortran_case_check ~= false,
    severity = (type(sev) == "string" and vim.diagnostic.severity[sev:upper()]) or vim.diagnostic.severity.WARN,
    intrinsics = vim.g.fortran_case_intrinsics ~= false,
    defined = vim.g.fortran_case_defined ~= false,
    documented = vim.g.fortran_case_documented == true,
    all_calls = vim.g.fortran_case_all_calls == true,
    units = vim.g.fortran_case_units ~= false,
    keyword_set = M.keyword_set(),
    dotted_set = M.dotted_set(),
  }
end

-- ---------------------------------------------------------------------------
-- Known-name sets
-- ---------------------------------------------------------------------------

-- Kinds from scan.lua that name something callable. Modules and derived types
-- are definitions too, but they are not procedures and the rule is about
-- procedures.
local CALLABLE_KINDS = { subroutine = true, ["function"] = true, interface = true }

-- Program units that are NOT procedures. Their names are checked too, but by a
-- rule of their own: `type(State)` puts the name inside parentheses belonging
-- to the KEYWORD, so the invocation-position scan never sees it.
local UNIT_KINDS = { module = true, submodule = true, program = true, type = true }

-- The keywords a unit name can follow. `end` forms are covered for free --
-- `end module physics` contains `module physics`.
local UNIT_REF_KEYWORDS = {
  "module", "submodule", "program", "type", "class", "interface", "use", "extends", "import",
}

-- Statements whose `::` entity list NAMES existing procedures rather than
-- declaring new variables. The distinction matters: in `real :: heating` the
-- name is a new variable and must be left alone, while in
-- `public :: Heating` it is the procedure and must be capitalized.
local NAME_LIST_STATEMENTS = {
  public = true, private = true, protected = true,
  external = true, intrinsic = true, import = true,
}

--- Build the lowercase name -> source-label map the checker matches against.
---@param project_defs table[]|nil records from scan.project_definitions
---@param opts table from M.options()
---@return table<string, string>
function M.known_names(project_defs, opts)
  local known = {}

  if opts.intrinsics then
    for name in pairs(intrinsics.set) do
      known[name] = "intrinsic"
    end
  end

  if opts.documented then
    local ok, docs = pcall(require, "andrew.fortran.docs")
    if ok then
      for _, kw in ipairs(docs.keywords()) do
        known[kw:lower()] = known[kw:lower()] or "documented"
      end
    end
  end

  if opts.defined then
    for _, d in ipairs(project_defs or {}) do
      if CALLABLE_KINDS[d.kind] then
        -- A project definition wins the label: "defined subroutine" is more
        -- useful in the message than "intrinsic" when a project shadows one.
        known[d.lname] = "defined"
      end
    end
  end

  -- Unit names go in as well, so a structure constructor `State(1.0)` is
  -- caught by the invocation-position scan like any other call.
  if opts.units then
    for _, d in ipairs(project_defs or {}) do
      if UNIT_KINDS[d.kind] then
        known[d.lname] = known[d.lname] or "defined"
      end
    end
  end

  return known
end

--- Just the non-procedure unit names, for the keyword-adjacent rule.
---@param project_defs table[]|nil
---@param opts table
---@return table<string, string> lowercase name -> kind
function M.known_units(project_defs, opts)
  local units = {}
  if not opts.units then
    return units
  end
  for _, d in ipairs(project_defs or {}) do
    if UNIT_KINDS[d.kind] then
      units[d.lname] = d.kind
    end
  end
  return units
end

-- ---------------------------------------------------------------------------
-- Context suppression
-- ---------------------------------------------------------------------------

--- True when an occurrence of a type-keyword intrinsic is a type SPECIFICATION
--- rather than a call.
---
--- Two shapes cover it:
---   `real(8) :: x`                 declaration -- name sits left of the `::`
---   `real(8) function Foo(x)`      prefix -- name is the statement's first
---                                  token and a word follows its parentheses
---@param masked string
---@param col integer 1-based column of the name
---@param name string lowercase name
---@return boolean
function M.is_type_spec_context(masked, col, name)
  local dcol = masked:find("::", 1, true)
  if dcol and col < dcol then
    return true
  end

  if masked:sub(1, col - 1):match("^%s*$") then
    local ps = masked:match("^%s*()%(", col + #name)
    if not ps then
      return true
    end
    local _, pe = masked:find("^%b()", ps)
    if pe and masked:sub(pe + 1):match("^%s*[%a_]") then
      return true
    end
  end

  return false
end

--- True when a keyword-shaped token is being used as a variable name.
---
--- Fortran reserves nothing, so each of these positions is legal for a
--- variable called `if`, `count` or `status`, and none of them is a position a
--- genuine keyword is ever written in.
---@param masked string
---@param tok { lname: string, col: integer }
---@param dcol integer|nil column of the line's `::`, if any
---@return boolean
function M.is_variable_position(masked, tok, dcol)
  -- Right of a `::`: the entity-declaration list, i.e. names being declared.
  if dcol and tok.col > dcol then
    return true
  end

  -- After a `%`: a derived-type component reference.
  if scan.prev_nonspace(masked, tok.col) == "%" then
    return true
  end

  -- Followed by `=`: an assignment (`format = '(A)'`), a keyword argument
  -- (`iostat=ios`), a pointer assignment (`p => x`) or a comparison
  -- (`if (type == 3)`). A genuine keyword is never followed by `=` in any of
  -- those forms -- keywords introduce or terminate statements -- so the test
  -- needs no exception for `==`, and adding one only lets variable names
  -- through on the comparison side.
  if masked:match("^%s*=", tok.col + #tok.lname) then
    return true
  end

  return false
end

-- ---------------------------------------------------------------------------
-- Line scanning
-- ---------------------------------------------------------------------------

-- Definition keywords whose trailing name is the procedure name, in both
-- `SUBROUTINE Foo` and `END SUBROUTINE Foo` position.
local NAMED_UNIT_KEYWORDS = { "subroutine", "function" }

--- Every capitalization violation on one line.
---@param raw string
---@param masked string
---@param lnum integer 1-based
---@param known table<string, string>
---@param opts table
---@param out table accumulator
function M.scan_line(raw, masked, lnum, known, opts, out)
  local seen = {}

  ---@param lname string
  ---@param col integer
  ---@param source string
  local function consider(lname, col, source)
    if seen[col] then
      return
    end
    local actual = raw:sub(col, col + #lname - 1)
    if actual == actual:upper() then
      return
    end
    seen[col] = true
    out[#out + 1] = {
      lnum = lnum,
      col = col,
      name = actual,
      upper = actual:upper(),
      source = source,
    }
  end

  -- 1. Invocation position: NAME(
  local refs = {}
  scan._scan_paren_names(masked, raw, lnum, refs)
  for _, ref in ipairs(refs) do
    local source = known[ref.lname]
    if source and not (intrinsics.type_spec[ref.lname] and M.is_type_spec_context(masked, ref.col, ref.lname)) then
      consider(ref.lname, ref.col, source)
    end
  end

  -- 2. CALL NAME, with arbitrary whitespace between them.
  local calls = {}
  scan._scan_call_statements(masked, raw, lnum, calls)
  for _, call in ipairs(calls) do
    local source = known[call.lname]
    if not source and opts.all_calls then
      source = "call target"
    end
    if source then
      consider(call.lname, call.col, source)
    end
  end

  -- 3. SUBROUTINE Foo / END FUNCTION Foo -- the definition and its terminator.
  for _, kw in ipairs(NAMED_UNIT_KEYWORDS) do
    local ks, ke = scan._find_word(masked, kw)
    while ks do
      local lname, col = scan._ident_at(masked, ke + 1)
      if lname and known[lname] then
        consider(lname, col, known[lname])
      end
      ks, ke = scan._find_word(masked, kw, ke + 1)
    end
  end

  -- 4. Language keywords: DO, IF, SELECT CASE, END SUBROUTINE, ...
  --
  -- One identifier pass over the line and a hash lookup per token, rather than
  -- a whole-line search per keyword -- there are well over a hundred of them.
  local kwset = opts.keyword_set
  if kwset and next(kwset) ~= nil then
    local dcol = masked:find("::", 1, true)
    for _, tok in ipairs(scan.identifiers(masked)) do
      if kwset[tok.lname] and not M.is_variable_position(masked, tok, dcol) then
        consider(tok.lname, tok.col, "keyword")

        -- `intent(in)`. IN / OUT / INOUT are keywords only inside these
        -- parentheses; everywhere else they are ordinary variable names.
        if tok.lname == "intent" then
          local _, _, acol, arg = masked:find("^%s*%(%s*()([%a_]+)", tok.col + #tok.lname)
          if arg and keywords.intent_arguments[arg] then
            consider(arg, acol, "keyword")
          end
        end
      end
    end
  end

  -- 5. Module / submodule / program / derived-type NAMES.
  --
  -- These are not procedures, so nothing above finds them: `type(State)` puts
  -- the name inside parentheses that belong to the `type` KEYWORD, and
  -- `use physics` has no parentheses at all. Each is located relative to the
  -- keyword that introduces or references it, which is also what keeps a
  -- variable that happens to share the name out of it.
  local units = opts.unit_names
  if units and next(units) ~= nil then
    for _, kw in ipairs(UNIT_REF_KEYWORDS) do
      local ks, ke = scan._find_word(masked, kw)
      while ks do
        local lname, col = M.unit_name_after(masked, ke + 1)
        if lname and units[lname] then
          consider(lname, col, "defined")
        end
        ks, ke = scan._find_word(masked, kw, ke + 1)
      end
    end
  end

  -- 6. Import and access lists: `use m, only: Heating`, `public :: Heating`.
  --
  -- These name procedures with no parentheses and no `call`, so nothing above
  -- reaches them -- and without this rule a procedure's calls get capitalized
  -- while the line that exports it does not.
  local list_from = nil
  local os_, oe = scan._find_word(masked, "only")
  if os_ then
    list_from = masked:match("^%s*:()", oe + 1)
  end
  if not list_from then
    local first = masked:match("^%s*([%a_][%w_]*)")
    if first and NAME_LIST_STATEMENTS[first] then
      local dcol2 = masked:find("::", 1, true)
      list_from = dcol2 and (dcol2 + 2) or nil
    end
  end
  if list_from then
    for _, tok in ipairs(scan.identifiers(masked:sub(list_from))) do
      local source = known[tok.lname]
      if source then
        consider(tok.lname, list_from + tok.col - 1, source)
      end
    end
  end

  -- 7. Dotted logical operators and literals: .AND., .TRUE.
  --
  -- Matched by their dots rather than as identifiers, because `and` and `true`
  -- are legal variable names but `.and.` cannot be anything else. None of the
  -- variable-position guards apply for the same reason -- and applying the
  -- `::` guard here would wrongly skip `logical :: flag = .true.`.
  local dotted = opts.dotted_set
  if dotted and next(dotted) ~= nil then
    local init = 1
    while true do
      local s, e, col, word = masked:find("%.()(%a+)%.", init)
      if not s then
        break
      end
      local label = dotted[word]
      if label then
        consider(word, col, label)
      end
      init = e
    end
  end
end

--- The unit name following a unit keyword, allowing for the shapes a name can
--- be written in: `type(State)`, `type :: State`, `type, extends(b) :: D`,
--- and the bare `use physics` / `end module physics`.
---@param masked string
---@param from integer first column after the keyword
---@return string|nil lname, integer|nil col
function M.unit_name_after(masked, from)
  for _, pattern in ipairs({
    "^%s*%(%s*()([%a_][%w_]*)",     -- type(State)
    "^%s*::%s*()([%a_][%w_]*)",     -- type :: State
    "^%s*,.-::%s*()([%a_][%w_]*)",  -- type, extends(base) :: Derived
    "^%s+()([%a_][%w_]*)",          -- use physics
  }) do
    local _, _, col, name = masked:find(pattern, from)
    if name then
      return name, col
    end
  end
  return nil, nil
end

--- Every capitalization violation in a list of lines.
---@param lines string[]
---@param known table<string, string>
---@param opts table|nil
---@return table[] occurrences with lnum (1-based), col (1-based), name, upper, source
function M.scan_lines(lines, known, opts)
  opts = opts or M.options()
  local out = {}
  local fixed = opts.fixed
  for lnum, raw in ipairs(lines) do
    M.scan_line(raw, scan.mask(raw, fixed), lnum, known, opts, out)
  end

  -- The four rules run in rule order, not column order, so a line can emit
  -- `Heating` before the `call` in front of it. Nothing downstream depends on
  -- the order -- replacements are the same width as what they replace -- but
  -- diagnostics and the quickfix list read as source order, so sort.
  table.sort(out, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

---@param occurrences table[]
---@param severity integer
---@return vim.Diagnostic[]
function M.to_diagnostics(occurrences, severity)
  local diags = {}
  for _, occ in ipairs(occurrences) do
    diags[#diags + 1] = {
      lnum = occ.lnum - 1,
      col = occ.col - 1,
      end_lnum = occ.lnum - 1,
      end_col = occ.col - 1 + #occ.name,
      severity = severity,
      source = "fortran-case",
      code = "uppercase",
      message = string.format("%s '%s' should be '%s'", occ.source, occ.name, occ.upper),
    }
  end
  return diags
end

-- ---------------------------------------------------------------------------
-- Buffer entry points
-- ---------------------------------------------------------------------------

--- Resolve the project's defined-procedure set, then invoke `cb`.
--- Falls back to a buffer-only scan when ripgrep is unavailable.
---@param bufnr integer
---@param cb fun(known: table<string, string>, opts: table)
local function with_known(bufnr, cb)
  local opts = M.options()
  opts.fixed = scan.is_fixed(bufnr)

  local function resolve(defs)
    opts.unit_names = M.known_units(defs, opts)
    cb(M.known_names(defs, opts), opts)
  end

  if not (opts.defined or opts.units) or vim.fn.executable("rg") ~= 1 then
    resolve(nil)
    return
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  local root = scan.project_root(name ~= "" and vim.fn.fnamemodify(name, ":h") or nil)
  scan.project_definitions(root, resolve)
end

--- Check `bufnr` and publish diagnostics.
---@param bufnr integer|nil
---@param cb fun(count: integer)|nil
function M.check(bufnr, cb)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  with_known(bufnr, function(known, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local occurrences = M.scan_lines(lines, known, opts)
    vim.diagnostic.set(M.ns, bufnr, M.to_diagnostics(occurrences, opts.severity))
    if cb then
      cb(#occurrences)
    end
  end)
end

--- Uppercase every flagged name in `bufnr`.
---
--- Replacements are the same byte length as what they replace, so columns
--- stay valid and the edits can be applied in any order.
---@param bufnr integer|nil
---@param cb fun(count: integer)|nil
function M.fix(bufnr, cb)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  with_known(bufnr, function(known, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local occurrences = M.scan_lines(lines, known, opts)
    for _, occ in ipairs(occurrences) do
      vim.api.nvim_buf_set_text(
        bufnr, occ.lnum - 1, occ.col - 1, occ.lnum - 1, occ.col - 1 + #occ.name, { occ.upper }
      )
    end
    vim.diagnostic.set(M.ns, bufnr, {})
    if cb then
      cb(#occurrences)
    end
  end)
end

--- Drop this rule's diagnostics from every buffer.
function M.clear()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    vim.diagnostic.reset(M.ns, bufnr)
  end
end

-- ---------------------------------------------------------------------------
-- Workspace entry points
-- ---------------------------------------------------------------------------

--- Apply `fn(path, lines)` to every Fortran source under the project root.
---@param root string
---@param fn fun(path: string, lines: string[])
---@return integer files visited
local function each_source_file(root, fn)
  local files = {}
  for _, glob in ipairs(scan.file_globs()) do
    for _, pattern in ipairs({ glob, glob:upper() }) do
      vim.list_extend(files, vim.fn.globpath(root, "**/" .. pattern, false, true))
    end
  end

  local seen = {}
  local count = 0
  for _, path in ipairs(files) do
    if not seen[path] and vim.fn.filereadable(path) == 1 then
      seen[path] = true
      count = count + 1
      fn(path, vim.fn.readfile(path))
    end
  end
  return count
end

--- Fixed- or free-form masking for a file read off disk.
---
--- The workspace passes never set `opts.fixed` at all, so every `.f` / `.for`
--- source was masked as free form -- and `fix_workspace` then UPPERCASED names
--- it found inside `C`-in-column-1 comments, rewriting the file on disk.
---@param path string
---@return boolean
local function fixed_for_path(path)
  return scan.FIXED_EXTENSIONS[(path:lower():match("%.(%w+)$") or "")] == true
end

--- Check every file in the project, publish diagnostics and fill the quickfix
--- list. Buffers are loaded lazily so the diagnostics survive a later jump.
---
--- `wopts.quickfix = false` suppresses the quickfix list, which matters when
--- the caller is the workspace COMPILER lint: that one fills the quickfix list
--- with its own findings, and two writers would leave whichever finished last
--- in sole possession of it. The diagnostics are set either way.
---@param cb fun(count: integer, files: integer)|nil
---@param wopts { quickfix?: boolean }|nil
function M.check_workspace(cb, wopts)
  local use_quickfix = not (wopts and wopts.quickfix == false)
  local opts = M.options()
  local root = scan.project_root()

  local function run(defs)
    opts.unit_names = M.known_units(defs, opts)
    local known = M.known_names(defs, opts)
    local qf, total, files = {}, 0, 0
    files = each_source_file(root, function(path, lines)
      opts.fixed = fixed_for_path(path)
      local occurrences = M.scan_lines(lines, known, opts)
      if #occurrences > 0 then
        local bufnr = vim.fn.bufnr(path, true)
        vim.fn.bufload(bufnr)
        vim.diagnostic.set(M.ns, bufnr, M.to_diagnostics(occurrences, opts.severity))
        for _, occ in ipairs(occurrences) do
          total = total + 1
          qf[#qf + 1] = {
            filename = path,
            lnum = occ.lnum,
            col = occ.col,
            text = string.format("%s '%s' should be '%s'", occ.source, occ.name, occ.upper),
            type = "W",
          }
        end
      end
    end)

    if #qf > 0 and use_quickfix then
      vim.fn.setqflist(qf)
      vim.cmd("copen")
    end
    if cb then
      cb(total, files)
    end
  end

  if (opts.defined or opts.units) and vim.fn.executable("rg") == 1 then
    scan.project_definitions(root, run)
  else
    run(nil)
  end
end

--- Rewrite every file in the project. Files open in a buffer are edited
--- through the buffer so the change is undoable and the user is not left with
--- a stale buffer over a changed file; the rest are rewritten on disk.
---@param cb fun(count: integer, files: integer)|nil
function M.fix_workspace(cb)
  local opts = M.options()
  local root = scan.project_root()

  local function run(defs)
    opts.unit_names = M.known_units(defs, opts)
    local known = M.known_names(defs, opts)
    local total, changed = 0, 0
    each_source_file(root, function(path, lines)
      opts.fixed = fixed_for_path(path)
      local occurrences = M.scan_lines(lines, known, opts)
      if #occurrences == 0 then
        return
      end
      changed = changed + 1
      total = total + #occurrences

      local bufnr = vim.fn.bufnr(path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        for _, occ in ipairs(occurrences) do
          vim.api.nvim_buf_set_text(
            bufnr, occ.lnum - 1, occ.col - 1, occ.lnum - 1, occ.col - 1 + #occ.name, { occ.upper }
          )
        end
        vim.diagnostic.set(M.ns, bufnr, {})
      else
        for _, occ in ipairs(occurrences) do
          local line = lines[occ.lnum]
          lines[occ.lnum] = line:sub(1, occ.col - 1) .. occ.upper .. line:sub(occ.col + #occ.name)
        end
        vim.fn.writefile(lines, path)
      end
    end)

    if cb then
      cb(total, changed)
    end
  end

  if (opts.defined or opts.units) and vim.fn.executable("rg") == 1 then
    scan.project_definitions(root, run)
  else
    run(nil)
  end
end

return M
