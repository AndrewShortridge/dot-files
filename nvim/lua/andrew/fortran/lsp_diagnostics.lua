-- Pushed diagnostics for the two Fortran mistakes no compiler on this machine
-- reports: an OpenMP directive in a project that is not built with -fopenmp,
-- and an MPI call that is missing its mandatory trailing `ierror`.
--
-- WHY THESE TWO AND NOTHING ELSE
--
-- Both are SILENT. That is the whole selection rule -- gfortran already
-- reports everything it can see, and andrew.fortran.diag already feeds it into
-- the same buffer, so a rule that duplicates the compiler is pure noise.
--
--   * `!$OMP PARALLEL DO` without -fopenmp is an ordinary comment. The file
--     compiles, the tests pass, and the loop runs single-threaded forever.
--     There is no warning available anywhere: to gfortran it is a comment, and
--     a comment is not something a compiler remarks on. Hence `tags = {1}`
--     (DiagnosticTag.Unnecessary) -- the line really is dead code as built.
--   * `call MPI_Comm_rank(MPI_COMM_WORLD, rank)` is a legal external call with
--     two arguments. The F77 `mpif.h` binding has no explicit interface, so
--     nothing checks the count; MPI then writes its status through a dummy
--     that was never passed and the program corrupts a stack slot or crashes
--     somewhere unrelated. `-fallow-argument-mismatch` -- which this config
--     sets deliberately, because the typeless MPI buffers need it (see
--     linting.lua) -- demotes even the accidental cross-call check to a
--     warning. The interface data to catch it properly is already in the
--     registry, generated from the installed `mpi.mod`. The rule is gated on
--     the binding the BUFFER has in scope: `use mpi_f08` makes `ierror`
--     optional, so the same call is correct there and reporting it would be a
--     false Error on the file that did it right (design §A1's binding_note).
--
-- PUSHED, NOT PULLED
--
-- The server hands each notification a `publish(uri, diagnostics)` bound to
-- `dispatchers.notification("textDocument/publishDiagnostics", ...)`. That is
-- the only route by which `codeDescription.href` survives: nvim's
-- vim/lsp/diagnostic.lua stashes the whole raw LSP diagnostic under
-- `user_data.lsp`, which is where lspconfig.lua's float `format` and
-- <leader>cH read the href from. A pull-model handler returning the same table
-- would lose it.
--
-- WHEN IT RUNS
--
-- didOpen and didSave only -- never on a keystroke. Rule 2 needs the
-- ripgrep-backed project signature index (to tell the standard binding from a
-- project's own `MPI_SEND` wrapper), and that is a subprocess. The index is
-- shared with andrew.fortran.lsp_inlayhint and built at most once per root, so
-- a save costs one buffer scan and no I/O at all.
local M = {}

local scan = require("andrew.fortran.scan")
local IH = require("andrew.fortran.lsp_inlayhint")

--- The `source` field of every diagnostic here, matching the server name.
M.SOURCE = "fortran-extras"

--- Rule name -> LSP DiagnosticSeverity.
M.SEVERITY = { ompDirectiveWithoutFlag = 2, mpiArgumentCount = 1 }

--- LSP DiagnosticTag.Unnecessary.
M.TAG_UNNECESSARY = 1

--- The rule reference the hrefs point into, relative to the config directory.
M.DOC = "doc/fortran-extras.md"

--- The documentation URL for a rule.
---
--- ONE template, like basedpyright's getDocumentationUrlForDiagnostic
--- (languageServerBase.ts:2020-2027): `<website>/#<rule>`. Ours is a local
--- file because the rules are local; `vim.ui.open` (bound to <leader>cH in
--- lspconfig.lua) opens a `file://` URL as happily as an https one. The anchor
--- is the LOWERCASED rule name because that is what a markdown renderer makes
--- of a `## ompDirectiveWithoutFlag` heading.
---@param code string
---@return string
function M.href(code)
  return ("file://%s/%s#%s"):format(vim.fn.stdpath("config"), M.DOC, code:lower())
end

-- ---------------------------------------------------------------------------
-- Which modules a buffer has in scope
-- ---------------------------------------------------------------------------

--- Does `stmt` open with a USE of module `mod`?
---
--- Every spelling the standard allows: `use mpi_f08`, `use :: mpi_f08`,
--- `use, intrinsic :: omp_lib`, and any of them with a trailing `, only: ...`
--- rename list. The `%f[%W]` frontier is what keeps `omp_lib` from matching
--- `omp_lib_kinds` -- `_` is a word character, so the two names are distinct
--- and each has to be asked for by name. Fortran is case-insensitive, so the
--- caller passes a LOWERCASED line.
---@param stmt string a lowercased line (or the tail of one)
---@param mod string lowercase module name
---@return boolean
local function use_of(stmt, mod)
  return stmt:match("^%s*use%s+" .. mod .. "%f[%W]") ~= nil
    or stmt:match("^%s*use%s*::%s*" .. mod .. "%f[%W]") ~= nil
    or stmt:match("^%s*use%s*,[^:]*::%s*" .. mod .. "%f[%W]") ~= nil
end

--- Does any line of the buffer `use` module `mod`?
---@param lines string[]
---@param mod string lowercase module name
---@return boolean
function M.uses_module(lines, mod)
  for _, line in ipairs(lines) do
    if use_of(line:lower(), mod) then
      return true
    end
  end
  return false
end

--- Which MPI Fortran binding this buffer has in scope.
---
--- The one difference that matters to rule 2: in `mpi_f08` the trailing
--- `ierror` is an OPTIONAL dummy (MPI-3.0 §17.1.6, and every entry's
--- `binding_note` says so), while in `mpi` / `mpif.h` it is mandatory and
--- omitting it is the single most common Fortran MPI bug. A buffer that says
--- `use mpi_f08` and omits `ierror` is therefore CORRECT, and the rule must
--- stand down rather than report the file that did it right.
---
--- A buffer carrying BOTH modules (a mixed-binding transition file) is read as
--- `mpi_f08`: being permissive costs a missed report, being strict costs a
--- false Error on legal code.
---@param lines string[]
---@return string "mpi_f08" or "mpi" -- `mpi` is also the answer when nothing binds
function M.mpi_binding(lines)
  return M.uses_module(lines, "mpi_f08") and "mpi_f08" or "mpi"
end

-- ---------------------------------------------------------------------------
-- Is this project built with -fopenmp?
-- ---------------------------------------------------------------------------

--- Build files read to answer it. A handful of small files at the project
--- root, read with readfile -- NOT a ripgrep pass, which would run on every
--- save of every .f90 to answer a question whose inputs change once a year.
M.BUILD_FILES = { "Makefile", "GNUmakefile", "makefile", "makefile.in", "CMakeLists.txt", "fpm.toml" }

--- Globs of further build fragments at the root.
M.BUILD_GLOBS = { "*.mk" }

local openmp_cache = {}

--- Drop the cached answer for `root` (or every root).
---@param root string|nil
function M.invalidate_openmp(root)
  if root then
    openmp_cache[root] = nil
  else
    openmp_cache = {}
  end
end

--- Does this project compile with OpenMP enabled?
---
--- Precedence:
---   1. `vim.g.fortran_openmp` when set -- the escape hatch, and the documented
---      way to silence the rule for a tree whose build system this cannot see
---      (a module file, a CI script, an IDE project).
---   2. The build files at the root, matched on the substring `openmp`, which
---      covers `-fopenmp`, `-qopenmp`, `FOPENMP=`, `find_package(OpenMP)` and
---      `OpenMP_Fortran_FLAGS` in one test.
---   3. NOT built with it. That asymmetry is the point of the rule: the
---      hazardous state is the default one, and a project with no build file
---      this understands is precisely where a directive is most likely to be
---      silently ignored.
---@param root string
---@return boolean
function M.openmp_enabled(root)
  local g = vim.g.fortran_openmp
  if g ~= nil then
    return g == true or g == 1
  end
  local cached = openmp_cache[root]
  if cached ~= nil then
    return cached
  end

  local paths = {}
  for _, name in ipairs(M.BUILD_FILES) do
    paths[#paths + 1] = root .. "/" .. name
  end
  for _, glob in ipairs(M.BUILD_GLOBS) do
    vim.list_extend(paths, vim.fn.glob(root .. "/" .. glob, false, true))
  end

  local found = false
  for _, path in ipairs(paths) do
    if vim.fn.filereadable(path) == 1 then
      local ok, content = pcall(vim.fn.readfile, path)
      if ok and type(content) == "table" then
        for _, line in ipairs(content) do
          if line:lower():find("openmp", 1, true) then
            found = true
            break
          end
        end
      end
    end
    if found then
      break
    end
  end

  openmp_cache[root] = found
  return found
end

-- ---------------------------------------------------------------------------
-- Rule 1 -- ompDirectiveWithoutFlag
-- ---------------------------------------------------------------------------

--- The OpenMP sentinel on `line`, if it carries one.
---
--- Free form spells it `!$OMP` (or the conditional-compilation `!$`) anywhere
--- on the line; fixed form demands column 1 and allows `C`, `c` and `*` as the
--- comment character. Read from the RAW line on purpose: scan.mask blanks
--- everything from `!` onwards, which is exactly what makes the rest of this
--- module safe and exactly what would make this rule see nothing.
---
--- WHAT FOLLOWS THE `$` IS PART OF THE SENTINEL (OpenMP 5.2 §3.2.2, §3.1)
---
--- `!$omp` must be followed by whitespace (a directive name comes next), and
--- the conditional-compilation sentinel `!$` must be followed by a space, a
--- tab, or the end of the line -- the two spaces of `!$  x = 1` are what turns
--- the sentinel into columns of the statement. Anything else after the `$` is
--- ANOTHER vendor's sentinel and none of our business: `!$acc parallel loop`
--- is OpenACC, `!$dir` is a compiler directive, and reporting either as an
--- OpenMP conditional-compilation line is a false positive on a line that has
--- nothing to do with -fopenmp.
---@param line string
---@param fixed boolean|nil
---@return { col: integer, len: integer, kind: string }|nil col/len are 1-based bytes
function M.sentinel(line, fixed)
  local col
  if fixed then
    local first = line:sub(1, 1)
    if first ~= "!" and first ~= "c" and first ~= "C" and first ~= "*" then
      return nil
    end
    if line:sub(2, 2) ~= "$" then
      return nil
    end
    col = 1
  else
    col = line:match("^%s*()!%$")
    if not col then
      return nil
    end
  end

  local head = line:sub(col)
  local kind, len
  if head:match("^[!cC*]%$[oO][mM][pP]%f[%W]") then
    kind, len = "directive", 5
  elseif head:match("^[!cC*]%$[ \t]") or head:match("^[!cC*]%$$") then
    kind, len = "conditional", 2
  else
    -- `!$acc`, `!$dir`, `!$x=1`: a `$` glued to a word is someone else's
    -- sentinel, never OpenMP's.
    return nil
  end

  -- Extend the range over the directive word, so the underline lands on
  -- `!$OMP PARALLEL` rather than on a bare sentinel nobody can see.
  local gap, word = head:sub(len + 1):match("^([ \t]*)([%a_][%w_]*)")
  if word then
    len = len + #gap + #word
  end
  return { col = col, len = len, kind = kind }
end

--- Is this conditional-compilation line the `!$ use omp_lib` idiom?
---
--- `!$ use omp_lib` is the ONE conditional line that is supposed to be a
--- comment without the flag: it is how a file stays compilable both ways, and
--- it is exactly what the "Add `!$ use omp_lib`" quickfix inserts. Reporting
--- it would mean the quickfix creates a fresh instance of the warning it just
--- fixed, one line above the old one.
---@param line string raw line
---@param s table the sentinel M.sentinel returned for it
---@return boolean
function M.is_omp_lib_guard(line, s)
  if s.kind ~= "conditional" then
    return false
  end
  local stmt = line:sub(s.col + 2):lower()
  return use_of(stmt, "omp_lib") or use_of(stmt, "omp_lib_kinds")
end

--- The message for one sentinel kind.
---@param kind string
---@return string
local function omp_message(kind)
  if kind == "directive" then
    return "`!$OMP` directive in a project built without -fopenmp; it is a comment and the loop runs single-threaded"
  end
  return "`!$` conditional-compilation line in a project built without -fopenmp; "
    .. "it is a comment and the statement never runs"
end

-- ---------------------------------------------------------------------------
-- Rule 2 -- mpiArgumentCount
-- ---------------------------------------------------------------------------

local mpi_origin = nil

--- The registry entry for an MPI SUBROUTINE with a known interface, or nil.
---
--- Functions are excluded outright: `t = MPI_Wtime()` takes no arguments and a
--- count rule on a function reference cannot tell a call from an array
--- section. Only the `mpi` half of the registry qualifies -- the OpenMP
--- runtime has explicit interfaces in `omp_lib`, so gfortran already checks it
--- and a second opinion here would only ever be wrong.
---@param lname string lowercase name
---@return table|nil entry
function M.mpi_subroutine(lname)
  local ok, registry = pcall(require, "andrew.fortran.registry")
  if not ok then
    return nil
  end
  if not mpi_origin then
    mpi_origin = registry.names()
  end
  if mpi_origin[lname] ~= "mpi" then
    return nil
  end
  local e = registry.get(lname)
  if not e or e.kind ~= "subroutine" or type(e.interface) ~= "table" or #e.interface == 0 then
    return nil
  end
  return e
end

--- How many arguments the binding accepts: every dummy, and the mandatory
--- prefix. The registry is generated from `mpi.mod`, the `mpi` binding, which
--- has no optional dummies at all -- the range exists so that a regenerated
--- registry carrying optionals cannot start reporting false errors.
---
--- `binding` is the buffer's own answer from M.mpi_binding. Under `mpi_f08`
--- the trailing `ierror` is optional, so the same generated interface accepts
--- one fewer argument; the data does not change, the binding in scope does.
---@param entry table
---@param binding string|nil "mpi" (default) or "mpi_f08"
---@return integer required, integer total
function M.arity(entry, binding)
  local total = #entry.interface
  local required = total
  for i, d in ipairs(entry.interface) do
    if d.optional then
      required = i - 1
      break
    end
  end
  if binding == "mpi_f08" and total > 0 then
    local last = (entry.interface[total].name or ""):lower()
    if last == "ierror" or last == "ierr" then
      required = math.min(required, total - 1)
    end
  end
  return required, total
end

--- The message for a wrong argument count.
---@param entry table
---@param given integer
---@param missing string[]
---@param binding string the binding the buffer actually has in scope
---@return string
local function mpi_message(entry, given, missing, binding)
  local required, total = M.arity(entry, binding)
  local expects = ("%d %s"):format(total, total == 1 and "argument" or "arguments")
  if required ~= total then
    expects = ("%d or %d arguments"):format(required, total)
  end
  local msg = ("%s expects %s in the `%s` binding, %d given"):format(
    entry.name or entry.kind,
    expects,
    binding,
    given
  )
  if #missing > 0 then
    local quoted = {}
    for i, name in ipairs(missing) do
      quoted[i] = "`" .. name .. "`"
    end
    msg = msg .. " — " .. table.concat(quoted, ", ") .. (#missing == 1 and " is mandatory" or " are mandatory")
  end
  return msg
end

--- Start column (1-based) of the callee name whose `(` is at `open`.
---@param masked string
---@param open integer
---@return integer|nil
local function callee_start(masked, open)
  return masked:sub(1, open - 1):match("()[%a_][%w_]*%s*$")
end

-- ---------------------------------------------------------------------------
-- The analysis
-- ---------------------------------------------------------------------------

--- Diagnose one file's worth of lines.
---
--- PURE: no buffer, no autocmd, no subprocess. Everything the rules cannot
--- work out from the text arrives in `opts`, which is what makes the whole
--- thing testable on a fixture and what keeps `on_change` off the ripgrep path
--- on every keystroke.
---@param lines string[]
---@param opts { openmp: boolean|nil, fixed: boolean|nil, project: table<string, boolean>|nil, sigs: table|nil,
---            binding: string|nil }|nil
---@return table[] LSP Diagnostic[]
function M.analyse(lines, opts)
  opts = opts or {}
  local fixed = opts.fixed == true
  local project = opts.project or {}
  -- The MPI binding is a property of the BUFFER, not of the project: one tree
  -- routinely holds `use mpi_f08` and `include 'mpif.h'` files side by side.
  local binding = opts.binding or M.mpi_binding(lines)
  local out = {}

  -- Rule 1: OpenMP sentinels in a project not built with -fopenmp.
  if opts.openmp ~= true then
    for lnum, line in ipairs(lines) do
      local s = M.sentinel(line, fixed)
      if s and M.is_omp_lib_guard(line, s) then
        s = nil
      end
      if s then
        out[#out + 1] = {
          range = {
            start = { line = lnum - 1, character = s.col - 1 },
            ["end"] = { line = lnum - 1, character = s.col - 1 + s.len },
          },
          severity = M.SEVERITY.ompDirectiveWithoutFlag,
          source = M.SOURCE,
          code = "ompDirectiveWithoutFlag",
          codeDescription = { href = M.href("ompDirectiveWithoutFlag") },
          -- The line is genuinely dead code AS BUILT, which is what
          -- Unnecessary means. Following basedpyright, the tag comes from the
          -- rule's identity and not from its severity
          -- (languageServerBase.ts:2183-2189).
          tags = { M.TAG_UNNECESSARY },
          message = omp_message(s.kind),
          data = { rule = "ompDirectiveWithoutFlag", sentinel = s.kind },
        }
      end
    end
  end

  -- Rule 2: MPI calls whose argument count disagrees with the binding.
  local sigs = opts.sigs
  if not sigs then
    sigs = {}
    local ok, mpi = pcall(require, "andrew.fortran.mpi")
    if ok then
      mpi.seed(sigs)
    end
  end

  local buf_scan = scan.scan_lines(lines, { fixed = fixed })
  for _, site in ipairs(IH.call_sites(buf_scan, sigs)) do
    -- A project that defines its own MPI_SEND wrapper owns the name: the
    -- wrapper's real dummy list is what the call must match, and the standard
    -- binding says nothing about it.
    if not project[site.lname] then
      local entry = M.mpi_subroutine(site.lname)
      if entry then
        local slots, closed = IH.arg_slots(buf_scan.masked, site.lnum, site.open, fixed)
        -- An unclosed list is a statement the walker could not follow to its
        -- end (truncated, over the continuation budget, unbalanced). Its count
        -- is a lower bound, not a count, and reporting it would fire on every
        -- half-typed line.
        if closed then
          local given = #slots
          local required, total = M.arity(entry, binding)
          if given < required or given > total then
            local missing = {}
            for i = given + 1, required do
              missing[#missing + 1] = entry.interface[i].name
            end
            local masked = buf_scan.masked[site.lnum] or ""
            local col = callee_start(masked, site.open) or site.open
            out[#out + 1] = {
              range = {
                start = { line = site.lnum - 1, character = col - 1 },
                ["end"] = { line = site.lnum - 1, character = col - 1 + #site.lname },
              },
              severity = M.SEVERITY.mpiArgumentCount,
              source = M.SOURCE,
              code = "mpiArgumentCount",
              -- The Open MPI man page beats a local rule reference whenever
              -- the entry carries one: it documents the routine the user got
              -- wrong, not the rule that noticed.
              codeDescription = { href = entry.href or M.href("mpiArgumentCount") },
              message = mpi_message(entry, given, missing, binding),
              data = { rule = "mpiArgumentCount", callee = site.lname, missing = missing },
            }
          end
        end
      end
    end
  end

  table.sort(out, function(a, b)
    if a.range.start.line ~= b.range.start.line then
      return a.range.start.line < b.range.start.line
    end
    return a.range.start.character < b.range.start.character
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- Buffer entry points
-- ---------------------------------------------------------------------------

--- Diagnose one loaded buffer, resolving everything `analyse` needs first.
---
--- Shared with andrew.fortran.lsp_codeaction, which needs the same answers to
--- decide what to offer -- so a quickfix is offered on exactly the lines the
--- diagnostic is published for, even when the client sends an empty
--- `context.diagnostics`.
---@param bufnr integer
---@param cb fun(diagnostics: table[])
function M.compute(bufnr, cb)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return cb({})
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local root = scan.project_root(vim.fn.fnamemodify(path, ":h"))
  local fixed = IH.is_fixed(bufnr, path)
  local openmp = M.openmp_enabled(root)

  IH.ensure_signatures(root, function(sigs)
    -- Anything the project itself defines is not the standard binding. The
    -- index marks builtins explicitly, so the test is a field read rather than
    -- a second scan.
    local project = {}
    for lname, sig in pairs(sigs) do
      if sig.builtin ~= true then
        project[lname] = true
      end
    end
    local ok, res = pcall(M.analyse, lines, { openmp = openmp, fixed = fixed, project = project, sigs = sigs })
    cb(ok and res or {})
  end)
end

--- textDocument/didOpen and textDocument/didSave.
---@param params table
---@param publish fun(uri: string, diagnostics: table[])
function M.on_change(params, publish)
  local uri = params and params.textDocument and params.textDocument.uri
  if not uri or type(publish) ~= "function" then
    return
  end
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  -- The filetype gate is the server's, not a guess: a .h include file can be
  -- opened by the same client and is not Fortran source to diagnose.
  local ok, lsp = pcall(require, "andrew.fortran.lsp")
  if ok and not lsp.FILETYPES[vim.bo[bufnr].filetype] then
    return
  end
  M.compute(bufnr, function(diagnostics)
    publish(uri, diagnostics)
  end)
end

--- textDocument/didClose. A closed document must have its diagnostics
--- withdrawn explicitly -- nvim keeps the last published list otherwise, and
--- it would reappear against the next buffer to take the number.
---@param params table
---@param publish fun(uri: string, diagnostics: table[])
function M.on_close(params, publish)
  local uri = params and params.textDocument and params.textDocument.uri
  if uri and type(publish) == "function" then
    publish(uri, {})
  end
end

--- Re-read the build files when one is written: adding `-fopenmp` to the
--- Makefile must clear every directive warning in the project, and the cache
--- would otherwise hold the old answer until nvim restarts.
function M.setup_invalidation()
  local group = vim.api.nvim_create_augroup("FortranExtrasOpenmpFlag", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "Makefile", "makefile", "GNUmakefile", "makefile.in", "*.mk", "CMakeLists.txt", "fpm.toml" },
    callback = function()
      M.invalidate_openmp()
    end,
  })
end

M.setup_invalidation()

return M
