-- =============================================================================
-- Capability-gated LSP keymaps (LazyVim's `has` mechanism)
-- =============================================================================
-- Ported from LazyVim v16, which keeps this list in the nvim-lspconfig spec
-- under `opts.servers["*"].keys` and binds it through `Snacks.keymap.set`
-- (lazyvim/plugins/lsp/init.lua:78-114, lazyvim/plugins/lsp/keymaps.lua:42-65).
-- We do not use snacks.keymap, so `M.on_attach(buf)` re-evaluates the whole
-- list on every LspAttach instead. LspAttach fires once PER CLIENT, so a second
-- server attaching to the same buffer adds any keys its capabilities unlock --
-- which is the same convergent behaviour snacks gets from its dirty-buffer
-- debounce, minus support for capabilities registered dynamically long after
-- attach (client/registerCapability). No server used here does that.
--
-- The point of `has` is that a key is bound ONLY when some attached client
-- actually advertises the method. Previously every key was bound
-- unconditionally, so e.g. <leader>ca existed on buffers whose server has no
-- codeActionProvider and answered with "No code actions available".
--
-- NOTE this module deliberately lives OUTSIDE lua/andrew/plugins/. lazy.lua:42
-- does `{ import = "andrew.plugins.lsp" }`, which imports EVERY file in that
-- directory as a plugin spec -- a non-spec module placed there is parsed as one
-- and dumped to the messages area at every startup. Siblings of
-- andrew.lsp_filetypes, which exists at this level for the same reason.
--
-- Method names are resolved through vim.lsp.protocol._request_name_to_server_capability
-- (nvim 0.12.5). Every string below was verified to be present in that table --
-- an unknown method makes supports_method() fall through to the dynamic
-- registration path and answer false, so a typo silently unbinds the key
-- forever. NOTE LazyVim itself has one: it gates workspace symbols on
-- "workspace/symbols", which is not a method (the real one is singular,
-- "workspace/symbol"), so that keymap never binds upstream. We use the
-- singular form.

local M = {}

-- ---------------------------------------------------------------------------
-- Source-action metatable (LazyVim util/lsp.lua:52-64)
-- ---------------------------------------------------------------------------
-- M.action["source.organizeImports"] returns a function that requests exactly
-- that code-action kind and applies it without a prompt. `apply = true` only
-- auto-applies when exactly ONE action survives filtering (nvim buf.lua:1323);
-- with several you still get the picker. `only` matching is hierarchical, so
-- "source" also matches "source.organizeImports", "source.fixAll", etc.
M.action = setmetatable({}, {
  __index = function(_, action)
    return function()
      vim.lsp.buf.code_action({
        apply = true,
        context = {
          only = { action },
          diagnostics = {},
        },
      })
    end
  end,
})

-- ---------------------------------------------------------------------------
-- Capability probes
-- ---------------------------------------------------------------------------

--- True when at least one client attached to `buf` supports `method`.
--- Accepts a bare name ("codeAction" -> "textDocument/codeAction") or a fully
--- qualified one ("workspace/willRenameFiles"), or a list of either (any match).
---@param buf integer
---@param method string|string[]|nil
---@return boolean
function M.has(buf, method)
  if not method then
    return true
  end
  local methods = type(method) == "string" and { method } or method
  for _, m in ipairs(methods) do
    m = m:find("/") and m or ("textDocument/" .. m)
    if #vim.lsp.get_clients({ bufnr = buf, method = m }) > 0 then
      return true
    end
  end
  return false
end

--- Every code-action KIND the buffer's clients advertise, static + dynamic.
--- Used to gate <leader>co: a server can support codeAction generally without
--- offering source.organizeImports, and binding the key anyway produces a
--- keypress that can only ever say "no actions".
---@param buf integer
---@return string[]
function M.code_action_kinds(buf)
  local ret = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    vim.list_extend(ret, vim.tbl_get(client, "server_capabilities", "codeActionProvider", "codeActionKinds") or {})

    -- Dynamic registrations live off the client object and the accessor has
    -- moved between nvim versions; never let a probe break attach.
    local ok, regs = pcall(function()
      return client.dynamic_capabilities and client.dynamic_capabilities:get("textDocument/codeAction", { bufnr = buf })
    end)
    if ok then
      for _, reg in ipairs(regs or {}) do
        vim.list_extend(ret, vim.tbl_get(reg, "registerOptions", "codeActionKinds") or {})
      end
    end
  end
  return ret
end

--- True when `kind` is an organize-imports source action.
---
--- Servers NAMESPACE their source actions: ruff advertises
--- `source.organizeImports.ruff`, never the bare kind. The original predicate
--- was anchored `^source%.organizeImports%.?$`, which matches only the bare
--- kind or the bare kind with a trailing dot -- so <leader>co could never bind,
--- not even in a Python buffer with ruff attached. Found by an empirical
--- keymap diff, 2026-09-06.
---
--- A plain prefix test would be wrong in the other direction: it would also
--- match a hypothetical `source.organizeImportsAggressively`. A kind qualifies
--- when it is exactly the base kind, or the base kind followed by a `.` segment.
---@param kind string
---@return boolean
function M.is_organize_imports_kind(kind)
  return kind == "source.organizeImports" or kind:find("^source%.organizeImports%.") ~= nil
end

-- ---------------------------------------------------------------------------
-- Helpers used by the key list
-- ---------------------------------------------------------------------------

local function fzf(picker, opts)
  return function()
    require("fzf-lua")[picker](opts)
  end
end

--- Go to declaration, falling back to definition when no client supports it.
--- Kept from the pre-port config: fortls advertises no declarationProvider, so
--- LazyVim's bare `vim.lsp.buf.declaration` would simply fail there.
local function goto_declaration()
  if M.has(0, "declaration") then
    vim.lsp.buf.declaration()
    return
  end
  require("fzf-lua").lsp_definitions()
end

--- Go to implementation, falling back to definition when the server cannot
--- answer -- including when it answers by crashing.
---
--- fortls advertises `implementationProvider: true` but only implements it for
--- TYPE-BOUND procedures. On a plain subroutine or function -- which is nearly
--- everything in an F77-descended codebase -- it raises
--- `-32603 'NoneType' object has no attribute 'get_type'` out of
--- langserver.py:1172. Handing that straight to fzf-lua puts a server stack
--- trace on the screen for what is, to the user, an ordinary jump.
---
--- So the request is made once up front and the picker is opened only if some
--- client actually returned locations; an error or an empty answer falls back
--- to definitions, which is what the user wanted from the key anyway. Same
--- shape as goto_declaration above and as andrew.fortran's `gr`: probe, then
--- dispatch. buf_request_all collects a per-client `err` without notifying, so
--- the crash stays invisible.
local function goto_implementation()
  local buf = vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/implementation" })
  if #clients == 0 then
    require("fzf-lua").lsp_definitions()
    return
  end

  local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)
  vim.lsp.buf_request_all(buf, "textDocument/implementation", params, function(results)
    for _, res in pairs(results or {}) do
      local r = res.result
      -- A Location answers as a bare table with a uri; a Location[] as a list.
      if type(r) == "table" and (r.uri ~= nil or #r > 0) then
        vim.schedule(function()
          require("fzf-lua").lsp_implementations()
        end)
        return
      end
    end
    vim.schedule(function()
      require("fzf-lua").lsp_definitions()
    end)
  end)
end

--- fzf-lua's answer to LazyVim's `Snacks.picker.lsp_config()`.
--- fzf-lua ships no LSP-info picker of any kind (verified against the pinned
--- commit: the provider table has no lsp_clients/lsp_info entry), so this is a
--- hand-rolled fzf_exec over the attached clients. Enter opens the native
--- healthcheck, which is what <leader>li used to do directly.
local function lsp_info()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  local entries = {}
  for _, c in ipairs(clients) do
    local root = c.root_dir or (c.config and c.config.root_dir) or "-"
    entries[#entries + 1] = string.format("%s  (id %d)  %s", c.name, c.id, root)
  end
  if #entries == 0 then
    entries = { "(no LSP clients attached to this buffer)" }
  end

  require("fzf-lua").fzf_exec(entries, {
    prompt = "LSP Clients> ",
    winopts = { title = " LSP Info ", title_pos = "center" },
    actions = {
      ["default"] = function()
        vim.cmd("checkhealth vim.lsp")
      end,
    },
  })
end

--- Document / workspace symbol picker, Fortran-aware.
---
--- fortls (like every Fortran LSP) answers documentSymbol and workspace/symbol
--- with DEFINITIONS only, so searching for a subroutine finds the line that
--- declares it and none of the lines that call it. In a Fortran buffer these
--- keys therefore go to andrew.fortran.symbols, which merges the definitions
--- with every `call NAME` and every `NAME(` that names a project procedure.
--- Every other filetype keeps the plain fzf-lua LSP picker.
---
--- Required lazily: andrew.fortran pulls in the scanner and, for a Fortran
--- buffer, ripgrep. Nothing of that should load because a Lua buffer attached.
---@param scope "document"|"workspace"
---@return function
local function symbols(scope)
  return function()
    require("andrew.fortran").symbol_picker(scope)()
  end
end

--- References, Fortran-aware. Mirrors symbols() above: in a Fortran buffer this
--- goes to andrew.fortran, which asks fortls first and falls back to the
--- project scanner when the server has never heard of the name -- the normal
--- case for COMMON-block variables in include files. Bound here as well as on
--- FileType because LspAttach fires last and would otherwise clobber the
--- buffer-local binding with the plain LSP picker.
---@return function
local function references()
  return function()
    require("andrew.fortran").reference_picker()()
  end
end

--- Signature help. Mirrors the <C-k> handler in lspconfig.lua (including its
--- Python/ty preference and the popup-kind marker the floating-preview patch
--- reads) so gK and <C-k> cannot drift apart.
local function signature_help()
  vim.b.lsp_popup_kind = "signature"
  vim.lsp.buf.signature_help()
end

--- Snacks.words reference jump. Requires `words = { enabled = true }` in the
--- snacks opts -- the module sets needs_setup, and without it jump() is a
--- silent no-op because no extmarks are ever placed.
local function words_jump(count, cycle)
  return function()
    Snacks.words.jump(count * vim.v.count1, cycle)
  end
end

-- ---------------------------------------------------------------------------
-- The key list
-- ---------------------------------------------------------------------------
-- Shape mirrors LazyVim's: { lhs, rhs, desc =, mode =, has =, enabled =, nowait = }.
--   has     -- LSP method(s); the key is skipped unless a client advertises one
--   enabled -- extra predicate run with the buffer, for finer gating than `has`
M._keys = {
  -- Navigation. All four pickers stay on fzf-lua rather than moving to
  -- snacks.picker, which is installed but deliberately not enabled here.
  { "gd", fzf("lsp_definitions"), desc = "Goto Definition", has = "definition" },
  { "gr", references(), desc = "References", nowait = true, has = "references" },
  { "gI", goto_implementation, desc = "Goto Implementation", has = "implementation" },
  { "gy", fzf("lsp_typedefs"), desc = "Goto T[y]pe Definition", has = "typeDefinition" },
  -- Deliberately un-gated: the fallback IS the feature.
  { "gD", goto_declaration, desc = "Goto Declaration" },
  { "gK", signature_help, desc = "Signature Help", has = "signatureHelp" },

  -- Code actions.
  {
    "<leader>ca",
    -- fzf-lua's code_actions registers itself as vim.ui.select only for the
    -- duration of the call and restores the previous handler afterwards, so
    -- snacks.nvim keeps ownership of every other vim.ui.select in the config
    -- (the vault's scope/type/link-fix prompts included). `silent` suppresses
    -- the "registering ui_select" info message that would otherwise fire on
    -- every invocation. The default "codeaction" previewer renders the action's
    -- diff in the preview pane; switching to "codeaction_native" additionally
    -- pipes it through git-delta, which is NOT installed here.
    fzf("lsp_code_actions", { silent = true }),
    desc = "Code Action",
    mode = { "n", "x" },
    has = "codeAction",
  },
  { "<leader>cA", M.action.source, desc = "Source Action", has = "codeAction" },
  {
    "<leader>co",
    M.action["source.organizeImports"],
    desc = "Organize Imports",
    has = "codeAction",
    enabled = function(buf)
      for _, kind in ipairs(M.code_action_kinds(buf)) do
        if M.is_organize_imports_kind(kind) then
          return true
        end
      end
      return false
    end,
  },

  -- Codelens. Off until asked for: nvim 0.12 does not display lenses unless
  -- codelens is enabled for the buffer, which is what <leader>cC does.
  { "<leader>cc", vim.lsp.codelens.run, desc = "Run Codelens", mode = { "n", "x" }, has = "codeLens" },
  {
    "<leader>cC",
    function()
      -- LazyVim uses vim.lsp.codelens.refresh(), which nvim 0.12.5 deprecated
      -- (runtime lua/vim/lsp/codelens.lua:552, slated for removal in 0.13) --
      -- calling it would print a deprecation notice on every press. enable()
      -- is the replacement it forwards to.
      vim.lsp.codelens.enable(true, { bufnr = 0 })
    end,
    desc = "Refresh & Display Codelens",
    has = "codeLens",
  },

  -- Rename.
  { "<leader>cr", vim.lsp.buf.rename, desc = "Rename", has = "rename" },
  {
    "<leader>cR",
    function()
      -- Snacks.rename is a plain utility (no needs_setup), and it fires the
      -- LSP willRenameFiles/didRenameFiles round-trip so imports follow the
      -- file. nvim-lsp-file-operations is already installed and handles the
      -- server side; this is the keymap it never had.
      Snacks.rename.rename_file()
    end,
    desc = "Rename File",
    has = { "workspace/didRenameFiles", "workspace/willRenameFiles" },
  },

  -- Symbols and call hierarchy.
  --
  -- LazyVim spends <leader>cs / <leader>cS on Trouble's symbols and LSP views;
  -- here both are fzf-lua symbol pickers, lowercase = document, uppercase =
  -- workspace. That makes them aliases of <leader>ss / <leader>sS, which keep
  -- the LazyVim spelling. Trouble is unaffected and still owns <leader>x.
  --
  -- In Fortran buffers all four also list CALL SITES -- see symbols() above.
  -- andrew.fortran binds the same four keys on FileType, so they work with no
  -- LSP attached; these bindings just win the race when fortls does attach.
  { "<leader>cs", symbols("document"), desc = "Symbols", has = "documentSymbol" },
  { "<leader>cS", symbols("workspace"), desc = "Workspace Symbols", has = "workspace/symbol" },
  { "<leader>ss", symbols("document"), desc = "LSP Symbols", has = "documentSymbol" },
  { "<leader>sS", symbols("workspace"), desc = "LSP Workspace Symbols", has = "workspace/symbol" },
  { "gai", fzf("lsp_incoming_calls"), desc = "C[a]lls Incoming", has = "callHierarchy/incomingCalls" },
  { "gao", fzf("lsp_outgoing_calls"), desc = "C[a]lls Outgoing", has = "callHierarchy/outgoingCalls" },

  -- Reference jumps (Snacks.words).
  { "]]", words_jump(1), desc = "Next Reference", has = "documentHighlight" },
  { "[[", words_jump(-1), desc = "Prev Reference", has = "documentHighlight" },
  { "<a-n>", words_jump(1, true), desc = "Next Reference", has = "documentHighlight" },
  { "<a-p>", words_jump(-1, true), desc = "Prev Reference", has = "documentHighlight" },

  -- Meta.
  { "<leader>cl", lsp_info, desc = "Lsp Info" },
}

-- ---------------------------------------------------------------------------
-- Attach
-- ---------------------------------------------------------------------------

--- Bind every key whose capability gate passes, buffer-locally.
---@param buf integer
function M.on_attach(buf)
  for _, key in ipairs(M._keys) do
    local ok = M.has(buf, key.has)
    if ok and key.enabled then
      ok = key.enabled(buf)
    end
    if ok then
      vim.keymap.set(key.mode or "n", key[1], key[2], {
        buffer = buf,
        silent = true,
        nowait = key.nowait,
        desc = key.desc,
      })
    end
  end
end

return M
