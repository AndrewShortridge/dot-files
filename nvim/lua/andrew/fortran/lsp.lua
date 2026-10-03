-- An in-process language server for Fortran, written in Lua.
--
-- WHY THIS EXISTS
--
-- fortls 3.2.2 advertises exactly eleven capabilities. Four keymap families in
-- andrew.lsp_keymaps are gated on capabilities it does not have, so in a
-- Fortran buffer they are silently never bound:
--
--   ]]  [[  <a-n>  <a-p>   gated on documentHighlight
--   gai gao              gated on callHierarchy/incomingCalls|outgoingCalls
--
-- and one capability nothing was waiting on, added because Fortran gains more
-- from it than any other language here: inlayHint, which labels the actual
-- arguments of a call with the callee's dummy names. F77 has no keyword
-- arguments, so a positional call to a subroutine in another file is otherwise
-- unreadable without opening that file.
--
-- The data to answer both is already in andrew.fortran.scan -- it emits call
-- sites, definitions and variable references with positions, and has done
-- since the symbol picker was built. What was missing was a way to hand that
-- data to Neovim through the channel the keymaps actually watch.
--
-- vim.lsp.start accepts a FUNCTION as `cmd`. It is handed the dispatchers and
-- returns an object with request/notify/is_closing/terminate -- an LSP server
-- that is a Lua table, with no process, no socket and no serialisation. Neovim
-- cannot tell the difference, so M.has() starts returning true and the six
-- keymaps above bind themselves with no change to andrew.lsp_keymaps at all.
--
-- THE ONE DESIGN RULE
--
-- Own what fortls cannot answer; stay silent where it can. No
-- definitionProvider, no referencesProvider, no renameProvider -- fortls
-- answers those, frequently better than a textual scan can (its references
-- are genuinely scope-aware).
--
-- hover, signatureHelp and completion ARE advertised, because fortls returns
-- nothing for the things this project reads most: every MPI name (mpif.h is
-- a stub to it and .mod files are binary), every `!$OMP` directive and clause,
-- every Fortran keyword, and a bare one-line signature for omp_lib. For those
-- three methods the negative half of the rule moves from the capability to
-- the ANSWER: each handler returns nil whenever fortls would answer -- a word
-- that is a project-defined symbol, or no word at all -- so the two-section
-- "# fortls / # fortran-extras" float that vim.lsp.buf.hover builds when two
-- clients answer (buf.lua:141-145) can only appear on a genuine mismatch.
-- The registry (andrew.fortran.registry) is the single source for all three.
--
-- POSITION ENCODING
--
-- The scanner reports 1-based BYTE columns. LSP's default is UTF-16, and a
-- non-ASCII byte anywhere earlier in the line -- a comment, a string, an
-- accented name in a header -- would shift every column after it. Rather than
-- convert on every token, the server declares `positionEncoding = "utf-8"`,
-- which makes byte offsets the wire format and the conversion a subtraction.
local M = {}

local NAME = "fortran-extras"

M.FILETYPES = { fortran = true, fortran_fixed = true, fortran_free = true, f90 = true, f95 = true }

-- ---------------------------------------------------------------------------
-- Position helpers
-- ---------------------------------------------------------------------------

--- Scanner record position -> LSP Position (0-based, utf-8/byte).
---@param lnum integer 1-based line
---@param col integer 1-based byte column
---@return { line: integer, character: integer }
function M.to_pos(lnum, col)
  return { line = lnum - 1, character = col - 1 }
end

--- LSP Position -> scanner coordinates.
---
--- The two fields are type-checked rather than trusted. A position arrives
--- over a wire this server does not control: a client that omits `character`
--- sends it as `vim.NIL` (a userdata, not nil), and the arithmetic below then
--- throws "attempt to perform arithmetic on field 'character' (a userdata
--- value)" out of a handler -- an error reply where the correct answer is
--- simply "no result". Every caller already treats a nil line/column as "no
--- position", so returning nil is the cheap, uniform failure.
---@param pos { line: integer, character: integer }|nil
---@return integer|nil lnum 1-based, integer|nil col 1-based
function M.from_pos(pos)
  if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
    return nil
  end
  return pos.line + 1, pos.character + 1
end

--- The range covering a name of `len` bytes starting at (lnum, col).
---@param lnum integer
---@param col integer
---@param len integer
---@return { start: table, ["end"]: table }
function M.name_range(lnum, col, len)
  return { start = M.to_pos(lnum, col), ["end"] = M.to_pos(lnum, col + len) }
end

-- ---------------------------------------------------------------------------
-- Capabilities
-- ---------------------------------------------------------------------------

--- Exactly the providers fortls does not have. See "THE ONE DESIGN RULE".
---@return table
function M.capabilities()
  return {
    positionEncoding = "utf-8",
    -- The buffer is read directly out of Neovim, so no document sync is
    -- needed beyond knowing which buffers are open -- plus `save`, which is
    -- not about the text either. nvim gates the didSave NOTIFICATION on this
    -- field being present (vim/lsp/client.lua only registers the BufWritePost
    -- handler when textDocumentSync.save is set), and didSave is when the
    -- pushed diagnostics are recomputed. Without it they are published once on
    -- didOpen and never again. `includeText = false` because the text is read
    -- straight from the buffer.
    textDocumentSync = { openClose = true, change = 0, save = { includeText = false } },
    documentHighlightProvider = true,
    callHierarchyProvider = true,
    -- Not a keymap gate like the two above -- nothing was waiting on it. This
    -- one is additive: fortls has no inlayHintProvider, so declaring it here
    -- cannot collide, and Fortran 77's entirely positional calls are where
    -- argument-name hints are worth the most. Toggled with <leader>uh.
    inlayHintProvider = true,
    -- The documentation surface: MPI, OpenMP and keywords, none of which
    -- fortls documents. Handlers answer nil for anything fortls owns -- see
    -- "THE ONE DESIGN RULE" for why the guard is in the answer, not here.
    hoverProvider = true,
    -- `(` and `,` are exactly fortls's own triggers. `)` (basedpyright has it)
    -- is left out: it would retrigger after every array reference.
    signatureHelpProvider = { triggerCharacters = { "(", "," } },
    -- `$` ONLY. blink unions trigger characters across clients, so a " "
    -- trigger would open a completion round on every space in every Fortran
    -- buffer; `$` follows `!` on a directive line and means nothing else.
    -- `(` means array indexing far more often than a clause argument and
    -- signatureHelp owns it; `%` is fortls's and we have no component data.
    -- resolveProvider keeps the documentation bodies off the wire until one
    -- item is selected -- the old blink source shipped all 388 on every
    -- keystroke.
    completionProvider = {
      resolveProvider = true,
      triggerCharacters = { "$" },
      completionItem = { labelDetailsSupport = true },
    },
    -- Quickfixes for the two pushed diagnostics (missing `use omp_lib`,
    -- missing `include 'mpif.h'`, missing `ierror`). fortls advertises
    -- codeActionProvider too (--enable_code_actions); nvim merges the two
    -- lists in the picker, so a second provider costs nothing.
    codeActionProvider = { codeActionKinds = { "quickfix" } },
  }
end

-- ---------------------------------------------------------------------------
-- Request dispatch
-- ---------------------------------------------------------------------------

--- Provider modules, required lazily so a broken provider cannot stop the
--- server from starting -- and so the scanner is not pulled in until a request
--- actually needs it.
---@param mod string
---@return table|nil
local function provider(mod)
  local ok, m = pcall(require, "andrew.fortran." .. mod)
  if not ok then
    vim.schedule(function()
      vim.notify(("fortran-extras: %s unavailable: %s"):format(mod, m), vim.log.levels.WARN)
    end)
    return nil
  end
  return m
end

--- method -> function(params, cb). Each handler owns its own error trapping:
--- an error raised inside a handler must become an empty answer, never an
--- exception thrown across the RPC boundary into Neovim's dispatch loop.
M.handlers = {
  ["initialize"] = function(_, cb)
    cb(nil, { capabilities = M.capabilities(), serverInfo = { name = NAME, version = "1" } })
  end,

  ["shutdown"] = function(_, cb)
    cb(nil, nil)
  end,

  ["textDocument/documentHighlight"] = function(params, cb)
    local p = provider("lsp_highlight")
    cb(nil, p and p.highlight(params) or nil)
  end,

  ["textDocument/prepareCallHierarchy"] = function(params, cb)
    local p = provider("lsp_callhierarchy")
    if not p then
      return cb(nil, nil)
    end
    p.prepare(params, cb)
  end,

  ["callHierarchy/incomingCalls"] = function(params, cb)
    local p = provider("lsp_callhierarchy")
    if not p then
      return cb(nil, nil)
    end
    p.incoming(params, cb)
  end,

  ["callHierarchy/outgoingCalls"] = function(params, cb)
    local p = provider("lsp_callhierarchy")
    if not p then
      return cb(nil, nil)
    end
    p.outgoing(params, cb)
  end,

  ["textDocument/inlayHint"] = function(params, cb)
    local p = provider("lsp_inlayhint")
    if not p then
      return cb(nil, nil)
    end
    p.inlay(params, cb)
  end,

  -- Documentation surface. Each provider answers nil where fortls would
  -- answer, so the capability can be advertised without double floats.
  ["textDocument/hover"] = function(params, cb)
    local p = provider("lsp_hover")
    if not p then
      return cb(nil, nil)
    end
    p.hover(params, cb)
  end,

  ["textDocument/signatureHelp"] = function(params, cb)
    local p = provider("lsp_signature")
    if not p then
      return cb(nil, nil)
    end
    p.signature(params, cb)
  end,

  ["textDocument/completion"] = function(params, cb)
    local p = provider("lsp_completion")
    if not p then
      return cb(nil, nil)
    end
    p.complete(params, cb)
  end,

  ["completionItem/resolve"] = function(item, cb)
    local p = provider("lsp_completion")
    if not p then
      return cb(nil, item)
    end
    p.resolve(item, cb)
  end,

  ["textDocument/codeAction"] = function(params, cb)
    local p = provider("lsp_codeaction")
    if not p then
      return cb(nil, nil)
    end
    p.actions(params, cb)
  end,
}

--- Notification handlers: method -> function(params, publish).
---
--- Diagnostics are PUSHED. `publish(uri, diagnostics)` is the server's own
--- dispatchers.notification bound to "textDocument/publishDiagnostics", which
--- routes through vim/lsp/diagnostic.lua and stashes the raw LSP diagnostic
--- at user_data.lsp -- the only way `codeDescription.href` reaches the
--- client side. Pull diagnostics would drop it.
M.notifications = {
  ["textDocument/didOpen"] = function(params, publish)
    local p = provider("lsp_diagnostics")
    if p then
      p.on_change(params, publish)
    end
  end,
  ["textDocument/didSave"] = function(params, publish)
    local p = provider("lsp_diagnostics")
    if p then
      p.on_change(params, publish)
    end
  end,
  ["textDocument/didClose"] = function(params, publish)
    local p = provider("lsp_diagnostics")
    if p then
      p.on_close(params, publish)
    end
  end,
}

--- Dispatch one request.
---
--- Any error inside a handler is reported as an empty result rather than an
--- RPC error: a scanner fault should degrade a keymap to "no results", not
--- surface a stack trace over a keypress.
---@param method string
---@param params table
---@param cb fun(err: table|nil, result: any)
function M.dispatch(method, params, cb)
  local h = M.handlers[method]
  if not h then
    -- Unknown method. Answering nil rather than MethodNotFound keeps a
    -- mis-gated caller quiet instead of logging on every keypress.
    return cb(nil, nil)
  end
  local ok, err = pcall(h, params or {}, cb)
  if not ok then
    vim.schedule(function()
      vim.notify(("fortran-extras: %s failed: %s"):format(method, err), vim.log.levels.WARN)
    end)
    cb(nil, nil)
  end
end

-- ---------------------------------------------------------------------------
-- The "process"
-- ---------------------------------------------------------------------------

--- Build the RPC client object vim.lsp.start expects from a function `cmd`.
---
--- `dispatchers.notification` is the server's only channel back to Neovim
--- outside a request/response pair; it carries the pushed diagnostics.
---@param dispatchers table
---@return table
function M.server(dispatchers)
  local closing = false
  local next_id = 0
  --- Push one document's diagnostics. Scheduled for the same reason replies
  --- are: nothing may arrive inside the notification that triggered it.
  ---@param uri string
  ---@param diagnostics table[]
  local function publish(uri, diagnostics)
    if closing or not (dispatchers and dispatchers.notification) then
      return
    end
    vim.schedule(function()
      if not closing then
        dispatchers.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = diagnostics or {} })
      end
    end)
  end
  return {
    publish = publish,
    --- Answer a request.
    ---
    --- The reply is ALWAYS scheduled, never delivered inside this call. Half
    --- the handlers here are synchronous (documentHighlight reads the buffer
    --- and returns), and a synchronous reply is a shape no out-of-process
    --- server can produce -- so callers written against real servers break on
    --- it. Snacks.words is the one that bit: its update() does
    ---     vim.lsp.buf.document_highlight()
    ---     M.clear()                        -- vim.lsp.buf.clear_references()
    --- on the assumption that the reply cannot have arrived yet. Answering in
    --- the same tick meant the highlights were applied and then immediately
    --- wiped, which made `]]`, `[[`, `<a-n>` and `<a-p>` silent no-ops in every
    --- Fortran buffer and the reference underline never appear.
    request = function(method, params, cb, notify_reply_callback)
      next_id = next_id + 1
      local id = next_id
      M.dispatch(method, params, function(err, result)
        vim.schedule(function()
          cb(err, result)
          if notify_reply_callback then
            notify_reply_callback(id)
          end
        end)
      end)
      return true, id
    end,
    notify = function(method, params)
      if method == "exit" then
        closing = true
        return true
      end
      local h = M.notifications[method]
      if h then
        local ok, err = pcall(h, params or {}, publish)
        if not ok then
          vim.schedule(function()
            vim.notify(("fortran-extras: %s failed: %s"):format(method, err), vim.log.levels.WARN)
          end)
        end
      end
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Attach
-- ---------------------------------------------------------------------------

--- Start (or reuse) the server for `bufnr`.
---
--- vim.lsp.start reuses an existing client whose name and root_dir match, so
--- the whole project shares one instance and the provider caches with it.
---@param bufnr integer
---@return integer|nil client id
function M.attach(bufnr)
  if not M.FILETYPES[vim.bo[bufnr].filetype] then
    return nil
  end
  local root = require("andrew.fortran.scan").project_root(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h"))
  return vim.lsp.start({
    name = NAME,
    cmd = M.server,
    root_dir = root,
  }, { bufnr = bufnr })
end

--- Attach on FileType, for every Fortran buffer.
function M.setup()
  local group = vim.api.nvim_create_augroup("FortranExtrasLsp", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = vim.tbl_keys(M.FILETYPES),
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  -- Buffers already open when setup() runs (the module is loaded from the
  -- lspconfig spec, which is itself ft-gated, so the triggering buffer is
  -- always one of these).
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.attach(buf)
    end
  end
end

return M
