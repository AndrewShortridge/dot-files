-- Fortran custom features module
-- Provides syntax highlighting and hover documentation for custom keywords,
-- symbol/call-site pickers, and the procedure-name capitalization rule.
local M = {}

local FT_PATTERN = { "fortran", "fortran_fixed", "fortran_free", "f90", "f95" }

-- Source extensions, for the autocmds that need a file pattern rather than a
-- filetype. Kept in step with andrew.fortran.scan's rg globs.
local FILE_PATTERN = {
  "*.f90", "*.F90", "*.f95", "*.F95", "*.f03", "*.F03", "*.f08", "*.F08",
  "*.f18", "*.F18", "*.f", "*.F", "*.for", "*.FOR",
}

-- ---------------------------------------------------------------------------
-- Symbol pickers (definitions + call sites)
-- ---------------------------------------------------------------------------

--- Dispatcher for the four symbol keymaps. In a Fortran buffer these open the
--- merged definitions+calls picker (andrew.fortran.symbols); everywhere else
--- they are the plain fzf-lua LSP pickers they have always been.
---
--- Bound here on FileType as well as in andrew.lsp_keymaps on LspAttach. Both
--- bindings resolve to this same function, so whichever fires last wins
--- harmlessly -- and the Fortran picker keeps working when fortls is not
--- running at all, which the capability-gated LSP binding cannot do.
---@param scope "document"|"workspace"
---@return function
function M.symbol_picker(scope)
  return function()
    local symbols = require("andrew.fortran.symbols")
    if symbols.is_fortran(vim.bo.filetype) then
      symbols[scope]()
      return
    end
    require("fzf-lua")[scope == "document" and "lsp_document_symbols" or "lsp_live_workspace_symbols"]()
  end
end

local SYMBOL_KEYS = {
  { "<leader>cs", "document", "Symbols (defs + calls)" },
  { "<leader>cS", "workspace", "Workspace Symbols (defs + calls)" },
  { "<leader>ss", "document", "LSP Symbols (defs + calls)" },
  { "<leader>sS", "workspace", "LSP Workspace Symbols (defs + calls)" },
}

--- `gr`, Fortran-aware, with the LSP first and the scanner as the fallback.
---
--- The symbol pickers list variable DECLARATIONS but not variable references --
--- there are two thousand declarations in a project against thirty-five
--- thousand identifier tokens, and only the first of those is an index. Chasing
--- one variable's uses is this key.
---
--- fortls is asked first, because when it can answer it answers with scope
--- awareness that a textual scan cannot match. It frequently cannot: a name
--- declared by appearing in a COMMON block inside a `.h` include, typed only by
--- IMPLICIT, is not a symbol it has ever seen, and the request comes back
--- empty. That empty answer -- not the absence of a server -- is what selects
--- the scanner, so `gr` behaves the same whether or not fortls is running.
---@return function
function M.reference_picker()
  return function()
    local symbols = require("andrew.fortran.symbols")
    if not symbols.is_fortran(vim.bo.filetype) then
      require("fzf-lua").lsp_references()
      return
    end

    local buf = vim.api.nvim_get_current_buf()
    local clients = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/references" })
    if #clients == 0 then
      symbols.references()
      return
    end

    local params = vim.lsp.util.make_position_params(0, clients[1].offset_encoding)
    params.context = { includeDeclaration = true }
    vim.lsp.buf_request_all(buf, "textDocument/references", params, function(results)
      for _, res in pairs(results or {}) do
        if type(res.result) == "table" and #res.result > 0 then
          vim.schedule(function()
            require("fzf-lua").lsp_references()
          end)
          return
        end
      end
      vim.schedule(function()
        symbols.references()
      end)
    end)
  end
end

local function bind_symbol_keys(buf)
  for _, spec in ipairs(SYMBOL_KEYS) do
    vim.keymap.set("n", spec[1], M.symbol_picker(spec[2]), {
      buffer = buf,
      silent = true,
      desc = spec[3],
    })
  end
  vim.keymap.set("n", "gr", M.reference_picker(), {
    buffer = buf,
    silent = true,
    nowait = true,
    desc = "References (LSP, else scan)",
  })
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup()
  local highlight = require("andrew.fortran.highlight")

  -- Setup highlight groups once
  highlight.setup_highlights()

  -- Attach the extmark highlighter to each Fortran buffer. Scheduled rather
  -- than deferred by a timer: the only thing it has to wait for is the window
  -- actually showing the buffer, so `w0`/`w$` answer a real viewport.
  vim.api.nvim_create_autocmd("FileType", {
    pattern = FT_PATTERN,
    group = vim.api.nvim_create_augroup("FortranCustomHighlight", { clear = true }),
    callback = function(ev)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          highlight.attach(ev.buf)
        end
      end)
    end,
  })

  -- Symbol keymaps, bound per Fortran buffer.
  vim.api.nvim_create_autocmd("FileType", {
    pattern = FT_PATTERN,
    group = vim.api.nvim_create_augroup("FortranSymbolKeys", { clear = true }),
    callback = function(ev)
      bind_symbol_keys(ev.buf)
    end,
  })

  -- Capitalization rule: re-check on read and on write. Scheduled off the
  -- event -- the check shells out to ripgrep for the project's defined
  -- procedures, and that has no business happening during buffer setup.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    pattern = FILE_PATTERN,
    group = vim.api.nvim_create_augroup("FortranCaseCheck", { clear = true }),
    callback = function(ev)
      local case = require("andrew.fortran.case")
      if not case.options().enabled then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          case.check(ev.buf)
        end
      end)
    end,
  })

  -- The in-process Lua language server. It advertises only the capabilities
  -- fortls lacks (documentHighlight, callHierarchy), which is what makes
  -- ]] [[ <a-n> <a-p> gai gao bind in a Fortran buffer -- andrew.lsp_keymaps
  -- gates those on capabilities, and until now nothing supplied them.
  require("andrew.fortran.lsp").setup()

  M.setup_commands()
end

function M.setup_commands()
  local command = vim.api.nvim_create_user_command

  command("FortranSymbols", function()
    require("andrew.fortran.symbols").document()
  end, { desc = "Fortran: document symbols and call sites" })

  command("FortranSymbolsWorkspace", function()
    require("andrew.fortran.symbols").workspace()
  end, { desc = "Fortran: workspace symbols and call sites" })

  command("FortranReferences", function(opts)
    require("andrew.fortran.symbols").references(opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
    desc = "Fortran: every use of a name (default: word under cursor)",
  })

  command("FortranCaseCheck", function(opts)
    local case = require("andrew.fortran.case")
    if opts.args == "workspace" then
      case.check_workspace(function(count, files)
        vim.notify(count == 0
          and string.format("Fortran case: %d file(s) clean", files)
          or string.format("Fortran case: %d name(s) to capitalize in %d file(s)", count, files))
      end)
    else
      case.check(0, function(count)
        vim.notify(count == 0
          and "Fortran case: clean"
          or string.format("Fortran case: %d name(s) to capitalize", count))
      end)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "workspace" }
    end,
    desc = "Fortran: check procedure-name capitalization",
  })

  command("FortranCaseFix", function(opts)
    local case = require("andrew.fortran.case")
    if opts.args == "workspace" then
      -- Rewriting every file in the project is not something to do by
      -- accident, and files not open in a buffer are written straight to disk
      -- with no undo history.
      local answer = vim.fn.confirm(
        "Uppercase every intrinsic and defined procedure name across the whole project?",
        "&Yes\n&No", 2, "Question"
      )
      if answer ~= 1 then
        vim.notify("Fortran case: cancelled", vim.log.levels.INFO)
        return
      end
      case.fix_workspace(function(count, files)
        vim.notify(string.format("Fortran case: capitalized %d name(s) in %d file(s)", count, files))
      end)
    else
      case.fix(0, function(count)
        vim.notify(string.format("Fortran case: capitalized %d name(s)", count))
      end)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "workspace" }
    end,
    desc = "Fortran: uppercase procedure names",
  })

  command("FortranHighlightToggle", function()
    local now = require("andrew.fortran.highlight").toggle()
    vim.notify("Fortran keyword highlighting: " .. (now and "on" or "off"))
  end, { desc = "Fortran: toggle the custom keyword/MPI/OpenMP colouring" })

  command("FortranCaseClear", function()
    require("andrew.fortran.case").clear()
    vim.notify("Fortran case: diagnostics cleared")
  end, { desc = "Fortran: clear capitalization diagnostics" })

  command("FortranCaseToggle", function()
    local case = require("andrew.fortran.case")
    local now = not case.options().enabled
    vim.g.fortran_case_check = now
    if now then
      case.check(0)
    else
      case.clear()
    end
    vim.notify("Fortran case check: " .. (now and "on" or "off"))
  end, { desc = "Fortran: toggle the capitalization check" })
end

return M
