-- =============================================================================
-- textDocument/signatureHelp for the in-process `fortran-extras` server
-- =============================================================================
--
-- WHY THIS EXISTS
--
-- fortls is genuinely good at signature help for procedures the project
-- defines: per-parameter documentation, the right activeParameter, the real
-- dummy names out of the real header. It is useless for the two families this
-- project reads most. `omp_set_num_threads(` comes back with `parameters: []`,
-- and `MPI_Comm_rank(` comes back with no result at all -- `mpif.h` is a stub
-- to it and a `.mod` file is binary. So the six positional arguments of
-- `MPI_Send(buf, count, datatype, dest, tag, comm, ierror)` -- the call where
-- knowing which slot you are in matters most, because Fortran 77 has no
-- keyword arguments to remind you -- are unlabelled.
--
-- Unlike hover, a false positive here is cheap: nvim does not concatenate
-- signature help from two clients, it CYCLES them (`Signature Help: <client>
-- (1/2)`, `<C-s>` to switch). The ownership rule is still applied, because the
-- project's own `MPI_SEND` wrapper must describe itself and not the library.
--
-- HOW THE CALLEE IS FOUND
--
-- Walk FORWARD over the logical statement, not backward from the cursor. A
-- Fortran statement can be spread over continuation lines, so "the innermost
-- unclosed `(` before the cursor" is not a local question -- and walking
-- backwards over `&` boundaries, fixed-form column rules and nested parens is
-- the kind of code that is wrong in one direction only and nobody notices.
-- Instead the statement's first line is found (by asking each preceding line
-- whether it continues), and a single forward pass maintains a stack of open
-- parens with a comma count each. At the cursor the top of the stack IS the
-- innermost unclosed call, and its comma count IS `activeParameter`. Nesting
-- falls out for free: in `MPI_Send(size(a), ` the cursor after `size(` sees
-- `size` on top, and after `size(a), ` sees `MPI_Send` with one comma.
--
-- Every line is scanned MASKED, so a paren inside a comment or a string
-- literal cannot open a call -- which is also why a cursor sitting inside a
-- comment answers nothing.
local M = {}

local lsp = require("andrew.fortran.lsp")
local hover = require("andrew.fortran.lsp_hover")
local inlay = require("andrew.fortran.lsp_inlayhint")
local registry = require("andrew.fortran.registry")
local render = require("andrew.fortran.render")
local scan = require("andrew.fortran.scan")

--- How far back a continued statement may reach. Shares lsp_inlayhint's cap
--- so an unbalanced paren cannot walk the whole file from either end.
M.MAX_CONTINUATION = inlay.MAX_CONTINUATION

-- ---------------------------------------------------------------------------
-- Locating the enclosing call
-- ---------------------------------------------------------------------------

--- First line of the logical statement that `lnum` belongs to.
---
--- Continuation is asked of the MASKED previous line: a trailing `&` inside a
--- comment (`x = 1 ! a & b`) is not a continuation, and masking is what makes
--- the test a plain suffix match.
---@param lines string[] 1-based raw lines
---@param lnum integer
---@param fixed boolean
---@return integer
function M.statement_start(lines, lnum, fixed)
  local at = lnum
  local budget = M.MAX_CONTINUATION
  while at > 1 and budget > 0 do
    budget = budget - 1
    if fixed then
      if not inlay.is_fixed_continuation(lines[at] or "") then
        break
      end
    else
      local _, continues = inlay.free_extent(scan.mask(lines[at - 1] or "", fixed))
      if not continues then
        break
      end
    end
    at = at - 1
  end
  return at
end

--- The innermost unclosed call at (lnum, col).
---
--- Returns the callee's lowercase name, the number of depth-0 commas between
--- its `(` and the cursor, and the line the `(` is on. A `(` with no
--- identifier immediately before it (a grouping paren, `(a + b) * c`) yields a
--- nil name and still counts its commas, so it cannot be mistaken for its
--- enclosing call.
---@param lines string[] 1-based raw lines
---@param lnum integer 1-based cursor line
---@param col integer 1-based byte column of the cursor
---@param fixed boolean|nil
---@return string|nil callee lowercase
---@return integer commas
function M.enclosing_call(lines, lnum, col, fixed)
  local start = M.statement_start(lines, lnum, fixed)
  local stack = {}

  for l = start, lnum do
    local masked = scan.mask(lines[l] or "", fixed)
    local from = 1
    if l > start then
      -- Continuation lines: fixed form reserves columns 1-6 for the label and
      -- the marker; free form may lead with `&`, which is not statement text.
      from = fixed and 7 or (masked:match("^%s*&()") or 1)
    end
    local to = #masked
    if not fixed then
      to = (inlay.free_extent(masked))
    end
    if l == lnum then
      to = math.min(to, col - 1)
    end

    local i = from
    while i <= to do
      local ch = masked:sub(i, i)
      if ch == "(" then
        stack[#stack + 1] = {
          name = masked:sub(from, i - 1):match("([%a_][%w_]*)%s*$"),
          commas = 0,
        }
      elseif ch == ")" then
        if #stack > 0 then
          table.remove(stack)
        end
      elseif ch == "," and #stack > 0 then
        stack[#stack].commas = stack[#stack].commas + 1
      end
      i = i + 1
    end
  end

  local top = stack[#stack]
  if not top then
    return nil, 0
  end
  return top.name, top.commas
end

-- ---------------------------------------------------------------------------
-- The answer
-- ---------------------------------------------------------------------------

--- Signature help for (lnum, col) in `lines`, with no buffer and no client.
---@param lines string[]|nil 1-based raw source lines
---@param lnum integer|nil 1-based cursor line
---@param col integer|nil 1-based byte column
---@param opts { fixed?: boolean, locals?: table, project?: table }|nil
---@return table|nil lsp.SignatureHelp
function M.answer(lines, lnum, col, opts)
  opts = opts or {}
  if type(lines) ~= "table" or type(lnum) ~= "number" or type(col) ~= "number" then
    return nil
  end
  local line = lines[lnum]
  if type(line) ~= "string" then
    return nil
  end

  -- A directive line carries no calls. `!$OMP PARALLEL DO REDUCTION(+:sum)`
  -- would otherwise read REDUCTION as a callee with one argument.
  if require("andrew.fortran.openmp").is_directive(line) then
    return nil
  end

  local callee, commas = M.enclosing_call(lines, lnum, col, opts.fixed)
  if not callee then
    return nil
  end

  -- Only procedures with a real interface. `x = a(i, ` names an array, and an
  -- entry with no `interface` (a constant, a keyword) has no parameters to
  -- point at.
  local entry = registry.get(callee)
  if not entry or (entry.kind ~= "subroutine" and entry.kind ~= "function") then
    return nil
  end
  local iface = entry.interface
  if type(iface) ~= "table" or #iface == 0 then
    return nil
  end

  -- Same ownership rule as hover: a project that defines its own MPI_SEND
  -- wrapper gets fortls's description of the wrapper, not the library's.
  if hover.is_project_symbol(callee, opts.locals, opts.project) then
    return nil
  end

  -- Clamped, not dropped. Fortran happily lets you write more actual
  -- arguments than the interface has dummies; the float should keep pointing
  -- at the last parameter rather than blank out mid-call.
  local active = math.min(commas, #iface - 1)

  return {
    signatures = { render.signature(entry, active) },
    activeSignature = 0,
    activeParameter = active,
  }
end

-- ---------------------------------------------------------------------------
-- LSP entry point
-- ---------------------------------------------------------------------------

--- textDocument/signatureHelp.
---
--- The cheap half runs first, exactly as in lsp_hover: the callee is resolved
--- against the registry before the buffer is scanned or the project index is
--- built, so typing `(` after an array name -- which is most `(` in Fortran --
--- costs a mask and a character walk and nothing else.
---@param params table
---@param cb fun(err: table|nil, result: table|nil)
function M.signature(params, cb)
  local uri = params and params.textDocument and params.textDocument.uri
  local pos = params and params.position
  if not (uri and pos) then
    return cb(nil, nil)
  end
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return cb(nil, nil)
  end
  if not lsp.FILETYPES[vim.bo[bufnr].filetype] then
    return cb(nil, nil)
  end

  local lnum, col = lsp.from_pos(pos)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local base = { fixed = scan.is_fixed(bufnr) }

  local probe = M.answer(lines, lnum, col, base)
  if not probe then
    return cb(nil, nil)
  end

  local opts = vim.tbl_extend("force", base, { locals = hover.buffer_locals(bufnr) })
  local root = scan.project_root(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h"))
  hover.project_signatures(root, function(sigs)
    opts.project = sigs
    local ok, res = pcall(M.answer, lines, lnum, col, opts)
    cb(nil, ok and res or nil)
  end)
end

return M
