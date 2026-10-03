-- ftnchek: cross-file argument and COMMON-layout checking for Fortran 77.
--
-- WHAT IT DOES THAT NOTHING ELSE HERE DOES
--
-- Every other checker in this config is single-translation-unit. gfortran
-- -fsyntax-only compiles one file and knows nothing about its callers; fortls
-- indexes names but never compares a call site against the callee's dummy
-- arguments; the scanner is textual. So the two mistakes that actually bite in
-- a legacy F77 tree are invisible to all of them:
--
--   * a CALL whose argument count or types disagree with the SUBROUTINE
--   * a COMMON block laid out differently in two files -- the classic silent
--     data corruption, where /BLK1/ A,B,N in one file and /BLK1/ A,N,B in
--     another means writing a REAL*8 through an INTEGER slot
--
-- ftnchek finds both by reading the whole program at once. It is not an LSP
-- shape at all -- there is no request for "is this COMMON block consistent
-- across the project" -- so it is wired as a project-wide pass, alongside the
-- existing workspace lint rather than inside it.
--
-- IT IS A FORTRAN 77 TOOL, AND THAT IS NOT A FOOTNOTE
--
-- Version 3.3 is from 2004 and predates everything modern. Pointed at a
-- free-form .f90 it does not merely miss things, it misparses: `module mymod`
-- becomes "identifier MODULEMYMOD has embedded space", `call f(size=n)` becomes
-- "unexpected '='", and a real file from a modern project produced two
-- syntax errors that do not exist. A checker that reports phantom errors is
-- worse than no checker, so FIXED_FORM_GLOBS deliberately excludes .f90 and
-- friends. Set vim.g.fortran_ftnchek_globs to override, knowing the above.
--
-- OUTPUT FORMAT
--
-- ftnchek wraps its messages to 79 columns by default and writes locations as
-- prose ("in module MAIN line 7 file main.f"), which is unparseable. `-wrap=0`
-- changes the whole shape to one location-prefixed line per fact:
--
--   "main.f", line 2: Warning: Common block BLK1 data type mismatch at position 2:
--   "main.f", line 2:    Variable B in module MAIN is type real*8
--   "cooling.f", line 2:    Variable N in module COOLING is type intg
--
-- A finding is therefore a HEADER line (its text begins at column 1 of the
-- message) followed by DETAIL lines (indented), and the details carry their
-- own locations -- which is the point: the caller and the callee are in
-- different files, and a diagnostic is wanted at both ends.
local M = {}

M.NS_NAME = "fortran_ftnchek"

--- Fixed-form Fortran only. See "IT IS A FORTRAN 77 TOOL" above.
M.FIXED_FORM_GLOBS = { "*.f", "*.for", "*.ftn", "*.fpp" }

--- `-wrap=0` makes the output line-oriented (see "OUTPUT FORMAT").
--- `-quiet` drops the per-file "0 syntax errors detected" banners.
--- `-nonovice` drops the paragraph of explanation appended to each message.
M.DEFAULT_ARGS = { "-wrap=0", "-quiet", "-nonovice" }

-- ---------------------------------------------------------------------------
-- Parsing
-- ---------------------------------------------------------------------------

--- Split one output line into its location prefix and message text.
---
--- Three prefix spellings occur: `line N`, `line N col C` (syntax errors) and
--- `near line N` (a fault attributed to a statement rather than a token).
---
--- Exactly ONE space is consumed after the colon. That is load-bearing: a
--- header is written `: Warning...` and a detail `:    Variable B...`, so
--- after removing the single separating space the remaining indentation is
--- what distinguishes them, and nothing else does.
---@param line string
---@return string|nil path, integer|nil lnum, integer|nil col, string|nil text
function M.split_loc(line)
  local path, rest = line:match('^"(.-)",%s*(.*)$')
  if not path then
    return nil, nil, nil, nil
  end
  local lnum, col, text
  lnum, col, text = rest:match("^near%s+line%s+(%d+)%s+col%s+(%d+):%s?(.*)$")
  if not lnum then
    lnum, text = rest:match("^near%s+line%s+(%d+):%s?(.*)$")
  end
  if not lnum then
    lnum, col, text = rest:match("^line%s+(%d+)%s+col%s+(%d+):%s?(.*)$")
  end
  if not lnum then
    lnum, text = rest:match("^line%s+(%d+):%s?(.*)$")
  end
  if not lnum then
    return nil, nil, nil, nil
  end
  return path, tonumber(lnum), tonumber(col), text
end

--- Severity of a header message, or nil when the text is not a header.
---@param text string
---@return integer|nil
function M.severity(text)
  local word = text:match("^(%a+)")
  if word == "Warning" then
    return vim.diagnostic.severity.WARN
  elseif word == "Error" then
    return vim.diagnostic.severity.ERROR
  end
  return nil
end

--- Parse ftnchek's output into findings.
---
--- Pure: no buffers, no filesystem. A finding is
---   { path, lnum, col, severity, message, details = {{path,lnum,col,text}} }
--- with `details` in output order.
---
--- Lines that are not location-prefixed (the version banner, `File x.f:`,
--- source echoes with their caret, ` 1 warning issued in file x.f`) carry no
--- position and are dropped. An indented line arriving before any header is
--- also dropped rather than guessed at.
---@param output string
---@return table[]
function M.parse(output)
  local findings = {}
  local current = nil
  for line in (output or ""):gmatch("[^\r\n]+") do
    local path, lnum, col, text = M.split_loc(line)
    if path then
      if text:match("^%s") then
        local trimmed = vim.trim(text)
        local nth = trimmed:match("^and at position (%d+):$")
        if nth and current then
          -- ftnchek reports several disagreeing positions under ONE headline,
          -- separating them with ` and at position N:`. Folding those into the
          -- first position's details would mis-attribute every fact after the
          -- first, so each opens a fresh finding carrying the headline with
          -- its own position substituted in.
          local base = current.base or current.message
          current = {
            path = path,
            lnum = lnum,
            col = col,
            severity = current.severity,
            message = (base:gsub("at position %d+:$", "at position " .. nth .. ":")),
            base = base,
            details = {},
          }
          findings[#findings + 1] = current
        elseif current then
          current.details[#current.details + 1] = {
            path = path,
            lnum = lnum,
            col = col,
            text = trimmed,
          }
        end
      else
        local sev = M.severity(text)
        if sev then
          current = {
            path = path,
            lnum = lnum,
            col = col,
            severity = sev,
            message = text,
            details = {},
          }
          findings[#findings + 1] = current
        end
      end
    end
  end
  return findings
end

--- Turn findings into per-location diagnostics.
---
--- Both ends of a cross-file finding get a marker. The header location gets
--- the headline; a detail whose location differs from the header's gets
--- `headline -> detail`, because a bare "Actual arg A in module MAIN is in
--- common block BLK1" sitting on line 7 of main.f says nothing on its own
--- about which subprogram disagreed.
---
--- A detail at the SAME location as its header is folded away: it would
--- duplicate a marker already on that line.
---@param findings table[]
---@return { path: string, lnum: integer, col: integer, message: string, severity: integer }[]
function M.diagnostics(findings)
  local out, seen = {}, {}
  local function add(path, lnum, col, message, severity)
    local key = ("%s\0%d\0%s"):format(path, lnum, message)
    if seen[key] then
      return
    end
    seen[key] = true
    out[#out + 1] = {
      path = path,
      lnum = lnum,
      col = col or 1,
      message = message,
      severity = severity,
    }
  end
  for _, f in ipairs(findings) do
    add(f.path, f.lnum, f.col, f.message, f.severity)
    for _, d in ipairs(f.details) do
      if d.path ~= f.path or d.lnum ~= f.lnum then
        add(d.path, d.lnum, d.col, f.message .. " -> " .. d.text, f.severity)
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

--- Fixed-form sources under `root`, via ripgrep (so .gitignore is honoured).
---@param root string
---@param cb fun(files: string[])
function M.files(root, cb)
  if vim.fn.executable("rg") ~= 1 then
    vim.notify("ftnchek: needs ripgrep (rg) on PATH to find sources", vim.log.levels.ERROR)
    return cb({})
  end
  local globs = vim.g.fortran_ftnchek_globs or M.FIXED_FORM_GLOBS
  local cmd = { "rg", "--files", "--no-messages" }
  for _, glob in ipairs(globs) do
    cmd[#cmd + 1] = "--iglob"
    cmd[#cmd + 1] = glob
  end
  cmd[#cmd + 1] = root
  vim.system(cmd, { text = true }, function(res)
    local files = {}
    for _, f in ipairs(vim.split(res.stdout or "", "\n", { plain = true })) do
      if f ~= "" then
        files[#files + 1] = f
      end
    end
    table.sort(files)
    vim.schedule(function()
      cb(files)
    end)
  end)
end

--- `-include=DIR` for every directory an INCLUDE could name.
---
--- ftnchek resolves `INCLUDE 'common.h'` relative to these, and in the trees
--- this is aimed at the whole declaration section lives in such a header --
--- without them every COMMON member is undeclared and the COMMON checks have
--- nothing to compare.
---@param root string
---@return string[]
function M.include_args(root)
  local args = { "-include=" .. root }
  for _, sub in ipairs({ "code", "include", "inc" }) do
    local dir = root .. "/" .. sub
    if vim.fn.isdirectory(dir) == 1 then
      args[#args + 1] = "-include=" .. dir
    end
  end
  return args
end

--- Run ftnchek over the project and hand back parsed findings.
---@param opts { root: string?, args: string[]? }|nil
---@param cb fun(findings: table[], files: string[], err: string|nil)
function M.run(opts, cb)
  opts = opts or {}
  if vim.fn.executable("ftnchek") ~= 1 then
    return cb({}, {}, "ftnchek is not on PATH")
  end
  local root = opts.root or require("andrew.fortran.scan").project_root(vim.fn.expand("%:p:h"))
  M.files(root, function(files)
    if #files == 0 then
      return cb({}, {}, "no fixed-form Fortran sources under " .. root)
    end
    local cmd = { "ftnchek" }
    vim.list_extend(cmd, opts.args or vim.g.fortran_ftnchek_args or M.DEFAULT_ARGS)
    vim.list_extend(cmd, M.include_args(root))
    vim.list_extend(cmd, files)
    vim.system(cmd, { text = true, cwd = root }, function(res)
      -- ftnchek exits 0 whatever it finds, and writes findings to stdout;
      -- stderr carries only failures to open a file. Both are parsed so a
      -- half-readable tree still yields what it can.
      local output = (res.stdout or "") .. "\n" .. (res.stderr or "")
      -- Parsing is deferred rather than done here: vim.system's on_exit runs
      -- in a FAST EVENT CONTEXT, and M.severity reads vim.diagnostic.severity,
      -- whose first touch lazy-loads vim/diagnostic.lua -- which calls
      -- nvim_create_augroup and dies with E5560. The failure is invisible
      -- (the callback simply never fires) so it costs an afternoon.
      vim.schedule(function()
        cb(M.parse(output), files, nil)
      end)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Front door
-- ---------------------------------------------------------------------------

local ns = nil
local function namespace()
  ns = ns or vim.api.nvim_create_namespace(M.NS_NAME)
  return ns
end

--- Drop every ftnchek diagnostic.
function M.clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    vim.diagnostic.reset(namespace(), buf)
  end
end

--- Run the check and publish diagnostics plus a quickfix list.
---@param opts { root: string?, args: string[]?, quickfix: boolean? }|nil
function M.check(opts)
  opts = opts or {}
  M.run(opts, function(findings, files, err)
    if err then
      vim.notify("ftnchek: " .. err, vim.log.levels.WARN)
      return
    end
    M.clear()
    local diags = M.diagnostics(findings)
    local by_buf, qf = {}, {}
    for _, d in ipairs(diags) do
      -- bufnr(path, true) creates the buffer entry; bufload is what makes
      -- vim.diagnostic.set stick, since diagnostics on an unloaded buffer are
      -- discarded when it is later loaded from disk.
      local buf = vim.fn.bufnr(d.path, true)
      vim.fn.bufload(buf)
      by_buf[buf] = by_buf[buf] or {}
      table.insert(by_buf[buf], {
        lnum = d.lnum - 1,
        col = math.max(0, d.col - 1),
        message = d.message,
        severity = d.severity,
        source = "ftnchek",
      })
      qf[#qf + 1] = {
        filename = d.path,
        lnum = d.lnum,
        col = d.col,
        text = d.message,
        type = d.severity == vim.diagnostic.severity.ERROR and "E" or "W",
      }
    end
    for buf, list in pairs(by_buf) do
      vim.diagnostic.set(namespace(), buf, list)
    end
    if opts.quickfix ~= false then
      vim.fn.setqflist(qf)
    end
    if #diags == 0 then
      vim.notify(("ftnchek: clean (%d file(s))"):format(#files), vim.log.levels.INFO)
    else
      if opts.quickfix ~= false then
        vim.cmd("copen")
      end
      vim.notify(
        ("ftnchek: %d finding(s) across %d file(s)"):format(#findings, #files),
        vim.log.levels.WARN
      )
    end
  end)
end

return M
