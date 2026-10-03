-- =============================================================================
-- textDocument/hover for the in-process `fortran-extras` server
-- =============================================================================
--
-- WHY THIS EXISTS
--
-- `K` used to be a keymap closure in lspconfig.lua that read
-- `snippets/fortran-docs.json` directly and opened its own float. That cost
-- four defects at once, every one of them invisible to a test because the
-- logic lived inside a keymap:
--
--   * the float was opened with `focus = false` and no `focus_id`, so a
--     150-line intrinsic doc was shown in 18 rows with no way to scroll it;
--   * it had no hover `range`, so nothing was highlighted under the cursor;
--   * when nothing matched it fell through to `vim.lsp.buf.hover()` only
--     after the JSON had already answered -- and the JSON answers for 74
--     short snippet abbreviations (`dp`, `mat`, `pi`, `flush`), so hovering
--     the user's OWN variable named `dp` showed a snippet's documentation;
--   * on `!$OMP PARALLEL DO REDUCTION(+:sum)` it resolved `sum` through the
--     general doc table and showed the SUM intrinsic, which has nothing to do
--     with the reduction operator under the cursor.
--
-- Moving the answer here makes `K` plain `vim.lsp.buf.hover()`, which brings
-- `focus_id` (a scrollable float), the range highlight and the correct "No
-- information available" message for free -- and puts the rule in a function
-- a spec can call.
--
-- THE ANSWER RULE (design section B2), in order
--
--   1. No identifier under the byte position -> nil. The word is found in the
--      RAW line so a word inside `!$OMP ...` -- which masking blanks, because
--      it IS a comment to the compiler -- is still found; on an ordinary line
--      the masked line is consulted, so a word inside a `!` comment or a
--      string literal answers nil.
--   2. On an OpenMP directive line, ONLY the directive/clause index is
--      consulted, and a miss answers nil rather than falling through. A bare
--      word on a directive line is a clause argument or one of the user's
--      variables; it is never an intrinsic.
--   3. A project-defined symbol answers nil. fortls owns it, with scope
--      awareness a textual scan cannot match, and this is also what stops the
--      snippet keys from shadowing local variables.
--   4. Registry, then -- only for a name that really is a Fortran intrinsic,
--      and only when fortls is NOT attached -- the legacy JSON prose. Miss ->
--      nil. fortls documents every standard intrinsic itself, so serving the
--      prose alongside it is exactly the double answer rule B2 forbids: `K` on
--      `size(a)` produced one float carrying both a `# fortls` and a
--      `# fortran-extras` banner. The prose is kept for the no-fortls case so
--      a machine without the server installed still gets something.
--
-- Steps 3 and 4 are ordered as written, but `M.hover` runs a cheap probe
-- first: when steps 1, 2 and 4 cannot produce an answer at all there is no
-- point paying for the project index, so the buffer is never scanned and
-- ripgrep is never started for a hover over an ordinary variable.
local M = {}

local lsp = require("andrew.fortran.lsp")
local registry = require("andrew.fortran.registry")
local render = require("andrew.fortran.render")
local scan = require("andrew.fortran.scan")

-- ---------------------------------------------------------------------------
-- The word under the cursor
-- ---------------------------------------------------------------------------

--- The identifier spanning 1-based byte column `col` of `line`.
---
--- Two different lines are searched on purpose. The RAW line locates the word,
--- because `scan.mask` blanks a whole `!$OMP` line (it is a comment) and the
--- directive documentation would be unreachable otherwise. The MASKED line
--- then vetoes the hit on any line that is NOT a directive: a word inside a
--- comment or a string literal masks to blanks, and hovering it must answer
--- nothing rather than documenting the word it happens to spell.
---@param line string|nil
---@param col integer|nil 1-based byte column
---@param fixed boolean|nil fixed-form source
---@return string|nil word source-cased spelling
---@return integer|nil scol 1-based start column
---@return integer|nil ecol 1-based end column (inclusive)
function M.word_at(line, col, fixed)
  if type(line) ~= "string" or type(col) ~= "number" then
    return nil
  end
  local openmp = require("andrew.fortran.openmp")
  local directive = openmp.is_directive(line)
  local masked = directive and line or scan.mask(line, fixed)
  local init = 1
  while init <= #line do
    local s, e = line:find("[%a_][%w_]*", init)
    if not s or s > col then
      return nil
    end
    if col <= e then
      -- Survived masking? mask() lowercases what it keeps and blanks the rest.
      if not directive and masked:sub(s, e) ~= line:sub(s, e):lower() then
        return nil
      end
      return line:sub(s, e), s, e
    end
    init = e + 1
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- The "fortls owns it" oracle
-- ---------------------------------------------------------------------------

--- Names defined or declared in one buffer, lowercase.
---
--- Both halves matter. `defs` carries the procedures the file defines, which
--- is what makes `K` on a call to a local subroutine silent so fortls's own
--- (scope-aware, signature-carrying) hover is the only answer. `decls` carries
--- dummy arguments, locals and parameters, which is what stops the legacy
--- JSON's `dp`, `mat`, `count` and `pi` keys from documenting a variable of
--- the same name -- the shadowing bug that motivated the whole rule.
---
--- Cached per buffer on `changedtick`: hover is a keypress, and rescanning a
--- 3000-line file on each one is exactly the cost this config avoids
--- elsewhere.
---@param bufnr integer
---@return table<string, true>
local locals_cache = {}
function M.buffer_locals(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_loaded(bufnr)) then
    return {}
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = locals_cache[bufnr]
  if c and c.tick == tick then
    return c.names
  end
  local names = {}
  local ok, res = pcall(scan.scan_buffer, bufnr)
  if ok and type(res) == "table" then
    for _, list in ipairs({ res.defs or {}, res.decls or {} }) do
      for _, rec in ipairs(list) do
        if rec.lname then
          names[rec.lname] = true
        end
      end
    end
  end
  locals_cache[bufnr] = { tick = tick, names = names }
  return names
end

--- Drop the cached buffer scan (tests, and BufDelete).
---@param bufnr integer|nil
function M.invalidate_locals(bufnr)
  if bufnr then
    locals_cache[bufnr] = nil
  else
    locals_cache = {}
  end
end

-- The project-wide half of the oracle is the signature index lsp_inlayhint
-- already builds and caches per root, invalidated on BufWritePost. Reusing it
-- means one ripgrep pass per project rather than one per feature, and means
-- hover and inlay hints can never disagree about what the project defines.
--
-- It is reached through the module's own export when that export exists, and
-- otherwise through a local cache over the same builder -- the fallback is
-- here so a checkout where lsp_inlayhint has not (yet) exported it degrades to
-- a second ripgrep rather than to no ownership check at all, which would be a
-- correctness bug (double floats) rather than a performance one.
local sig_cache = {}

--- The project's procedure signatures for `root`, built at most once.
---@param root string
---@param cb fun(sigs: table<string, table>)
function M.project_signatures(root, cb)
  local ok, inlay = pcall(require, "andrew.fortran.lsp_inlayhint")
  if not ok then
    return cb({})
  end
  if type(inlay.ensure_signatures) == "function" then
    return inlay.ensure_signatures(root, cb)
  end
  local e = sig_cache[root]
  if e and e.sigs then
    return cb(e.sigs)
  end
  if e and e.waiters then
    e.waiters[#e.waiters + 1] = cb
    return
  end
  sig_cache[root] = { waiters = { cb } }
  inlay.build_signatures(root, function(sigs)
    local entry = sig_cache[root]
    if not entry then
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

--- Drop the fallback signature cache.
---@param root string|nil
function M.invalidate(root)
  if root then
    sig_cache[root] = nil
  else
    sig_cache = {}
  end
end

--- Would fortls answer for this name?
---
--- `sig.builtin` marks the MPI/OpenMP entries lsp_inlayhint seeds into the
--- index to give library calls argument hints. Those are OURS, not the
--- project's -- treating them as project symbols would silence every MPI
--- hover, which is the one thing this server exists to provide.
---@param lname string lowercase name
---@param locals table<string, true>|nil names from the current buffer
---@param project table<string, table>|nil the signature index for the root
---@return boolean
function M.is_project_symbol(lname, locals, project)
  if locals and locals[lname] then
    return true
  end
  if project then
    local sig = project[lname]
    if type(sig) == "table" and sig.builtin ~= true then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- The answer
-- ---------------------------------------------------------------------------

--- The hover for column `col` of `line`, with no buffer and no client.
---
--- `opts.locals` and `opts.project` are the two halves of the ownership oracle
--- (step 3); leaving them nil means "nothing is owned by fortls", which is the
--- shape every pure spec case wants and which `M.hover` never uses.
---
--- `opts.fortls` is the third half of the same oracle, for the ONE class of
--- name the other two cannot see: a standard intrinsic belongs to no project
--- and to no buffer, yet fortls answers for it. `M.hover` sets it from the
--- attached clients; a pure spec passes it explicitly.
---@param line string|nil the RAW source line
---@param col integer|nil 1-based byte column
---@param opts { lnum?: integer, fixed?: boolean, filetype?: string, locals?: table, project?: table, fortls?: boolean }|nil
---@return table|nil lsp.Hover
function M.answer(line, col, opts)
  opts = opts or {}

  -- Step 1a: this server answers for Fortran only. The filetype is checked
  -- only when the caller supplies one, so a pure spec need not fake a buffer.
  if opts.filetype ~= nil and not lsp.FILETYPES[opts.filetype] then
    return nil
  end

  -- Step 1b: a word, in code, under the cursor.
  local word, scol, ecol = M.word_at(line, col, opts.fixed)
  if not word then
    return nil
  end
  local range = lsp.name_range(opts.lnum or 1, scol, ecol - scol + 1)

  -- Step 2: a directive line is a closed world.
  if require("andrew.fortran.openmp").is_directive(line) then
    local entry = registry.directive(word)
    if not entry then
      return nil
    end
    return { contents = render.hover(entry), range = range }
  end

  -- Step 3: fortls owns the project's own names.
  if M.is_project_symbol(word:lower(), opts.locals, opts.project) then
    return nil
  end

  -- Step 4: the registry, then the legacy prose.
  local entry = registry.get(word)
  if entry then
    -- The canonical spelling, not the cursor's: `mpi_comm_rank` typed in lower
    -- case still documents itself as `MPI_Comm_rank`, which is how the
    -- standard spells it and how the rest of the float refers to it.
    return { contents = render.hover(entry), range = range }
  end

  -- The legacy `snippets/fortran-docs.json` is the last resort and is gated
  -- twice.
  --
  -- On fortls being ABSENT, because fortls knows the standard intrinsics: with
  -- it attached, `K` on `size(a)` returned prose here AND a fortls hover, and
  -- vim.lsp.buf.hover concatenated the two into a single ~320-line float under
  -- `# fortls` / `# fortran-extras` banners (buf.lua:141-145). Rule B2 says
  -- this server is silent wherever fortls would answer, and the 82 intrinsics
  -- the JSON covers are precisely such names. Nothing is lost on a machine
  -- that has no fortls, which is the case this branch now exists for.
  --
  -- And on the name being a real intrinsic, because without that gate the
  -- JSON's ~210 snippet abbreviations (`dp`, `mat`, `pi`, `vec`, ...) answer
  -- for ordinary variables -- the F4 defect.
  local intrinsics = require("andrew.fortran.intrinsics")
  if not opts.fortls and intrinsics.is(word) then
    local ok, docs = pcall(require, "andrew.fortran.docs")
    local prose = ok and docs.get(word) or nil
    if type(prose) == "string" and prose ~= "" then
      return { contents = { kind = "markdown", value = prose }, range = range }
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- LSP entry point
-- ---------------------------------------------------------------------------

--- textDocument/hover.
---@param params table
---@param cb fun(err: table|nil, result: table|nil)
function M.hover(params, cb)
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
  if not (lnum and col) then
    return cb(nil, nil)
  end
  local line = (vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false) or {})[1]
  if not line then
    return cb(nil, nil)
  end
  -- Asked per request rather than cached: fortls attaches asynchronously after
  -- this server does (it is a process; this one is a Lua table), so a value
  -- computed once at attach time would say "no fortls" for the whole session
  -- of every buffer opened first. The call is a scan of the client list, which
  -- has a handful of entries.
  local base = {
    lnum = lnum,
    fixed = scan.is_fixed(bufnr),
    fortls = #vim.lsp.get_clients({ bufnr = bufnr, name = "fortls" }) > 0,
  }

  -- The probe. Steps 1, 2 and 4 with no ownership information: when they
  -- cannot answer, ownership cannot change that, so the buffer is not scanned
  -- and the project index is not built. This is what keeps a hover over an
  -- ordinary variable free.
  local probe = M.answer(line, col, base)
  if not probe then
    return cb(nil, nil)
  end

  -- Step 2 never consults the oracle: a clause is ours whatever the project
  -- happens to call its variables.
  if require("andrew.fortran.openmp").is_directive(line) then
    return cb(nil, probe)
  end

  local opts = vim.tbl_extend("force", base, { locals = M.buffer_locals(bufnr) })
  local word = M.word_at(line, col, base.fixed)
  if word and opts.locals[word:lower()] then
    return cb(nil, nil)
  end

  local root = scan.project_root(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h"))
  M.project_signatures(root, function(sigs)
    opts.project = sigs
    local ok, res = pcall(M.answer, line, col, opts)
    cb(nil, ok and res or nil)
  end)
end

-- The buffer scan is keyed on changedtick, so a stale entry can only be held
-- for a buffer that no longer exists. Wiping it on BufDelete keeps the table
-- bounded by the number of OPEN buffers rather than by the number ever opened.
local group = vim.api.nvim_create_augroup("FortranHoverCache", { clear = true })
vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  group = group,
  callback = function(ev)
    M.invalidate_locals(ev.buf)
  end,
})
-- The fallback signature cache follows lsp_inlayhint's own invalidation rule:
-- a written header changes what the project defines, and a stale index would
-- keep answering hover for a procedure that no longer exists.
vim.api.nvim_create_autocmd("BufWritePost", {
  group = group,
  pattern = { "*.f", "*.F", "*.for", "*.FOR", "*.ftn", "*.fpp", "*.f90", "*.F90", "*.f95", "*.f03", "*.f08" },
  callback = function()
    M.invalidate()
  end,
})

return M
