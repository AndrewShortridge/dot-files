-- =============================================================================
-- LSP floating-window presentation (border, title, size cap, wrap)
-- =============================================================================
-- Wraps vim.lsp.util.open_floating_preview so every LSP float in this config
-- gets the same border, a truthful title, line numbers and a size CAP.
--
-- NOTE this module deliberately lives OUTSIDE lua/andrew/plugins/. lazy.lua
-- does `{ import = "andrew.plugins.lsp" }`, which imports EVERY file in that
-- directory as a plugin spec -- a non-spec module placed there is parsed as one
-- and dumped to the messages area at every startup. Sibling of
-- andrew.lsp_keymaps and andrew.lsp_filetypes, which are at this level for the
-- same reason. It also has to be requireable from a spec without lazy.nvim:
-- while this code lived inside the lspconfig spec's `config` function there was
-- no way to test it at all, and the two defects below shipped unnoticed.
--
-- WHY A CAP AND NOT A SIZE
--
-- The previous version SET every float to
-- `clamp(0.5*columns,40,120) x clamp(0.3*lines,8,40)`, which is wrong in both
-- directions and was measured wrong in both directions on 2026-09-13:
--   * a 2-line fortls hover (`INTEGER :: nsz`) was inflated to 18 rows of
--     mostly empty float;
--   * a 151-line intrinsic doc was cut to 18 rows -- 84 buffer lines shown in a
--     15-line window, i.e. 82% of it off-screen.
-- Neovim already sizes the float to its contents; all this layer legitimately
-- wants is an upper bound, so the fractions became maxima and the minima were
-- dropped entirely.
--
-- WHY WRAP IS SET EXPLICITLY
--
-- open_floating_preview's own default is `opts.wrap = opts.wrap ~= false`
-- (vim/lsp/util.lua:1682, applied at :1796), yet the captured float came back
-- with `wrap=false` and long lines cut off horizontally -- something later in
-- the chain (the resize below included) can lose it. So the option is passed
-- AND the window option is set after creation, and a spec asserts it.

local M = {}

-- =============================================================================
-- Float size bounds
-- =============================================================================
-- Fractions of the editor, capped absolutely. These are MAXIMA: a float
-- smaller than this stays smaller.
M.SIZE = {
  width_frac = 0.50,  -- at most 50% of editor width
  height_frac = 0.30, -- at most 30% of editor height
  max_width = 120,    -- absolute ceiling in columns
  max_height = 40,    -- absolute ceiling in lines
}

--- The float's maximum size for the current editor dimensions.
---@return integer max_w columns
---@return integer max_h lines
function M.max_size()
  local max_w = math.min(math.floor(vim.o.columns * M.SIZE.width_frac), M.SIZE.max_width)
  local max_h = math.min(math.floor(vim.o.lines * M.SIZE.height_frac), M.SIZE.max_height)
  -- A float still has to be able to exist: one column, one line.
  return math.max(max_w, 1), math.max(max_h, 1)
end

--- Shrink `winid` to at most max_size(), never grow it, and keep it wrapping.
---
--- Some LSP clients ignore max_width/max_height, which is why the size is
--- re-checked after the window exists rather than only passed as an option.
---@param winid integer|nil
function M.enforce_float_size(winid)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end

  local cfg = vim.api.nvim_win_get_config(winid)

  -- Only floating windows (those with relative positioning) have a size we own.
  if not (cfg and cfg.relative and cfg.relative ~= "") then
    return
  end

  local max_w, max_h = M.max_size()

  -- CAP, never set: math.min only. A 3-line hover stays 3 lines.
  local new_cfg = vim.deepcopy(cfg)
  new_cfg.width = math.min(cfg.width, max_w)
  new_cfg.height = math.min(cfg.height, max_h)
  pcall(vim.api.nvim_win_set_config, winid, new_cfg)
end

-- =============================================================================
-- The wrapper
-- =============================================================================
local _orig_open_floating_preview = nil

--- Install the wrapper. Idempotent -- calling it twice must not stack two
--- layers of wrapping, since the lspconfig spec's `config` can re-run.
function M.setup()
  if _orig_open_floating_preview then
    return
  end
  _orig_open_floating_preview = vim.lsp.util.open_floating_preview

  vim.lsp.util.open_floating_preview = function(contents, syntax, opts, ...)
    opts = opts or {}

    -- Rounded borders for all LSP floats.
    opts.border = opts.border or "rounded"

    -- Title from what the float IS, not from which language server this config
    -- happened to be tuned for last. The previous titles were the literal
    -- strings "PY-LSP Function Documentation Preview" and "TY Function
    -- Parameter Popup" -- so every Fortran hover, on every probe, was labelled
    -- PY-LSP. A caller-supplied title always wins: nvim's own signature_help
    -- passes the function's name as the title, which is strictly better than
    -- anything derivable here.
    if not opts.title then
      local kind = vim.b.lsp_popup_kind
      if kind == "signature" then
        opts.title = "Signature Help"
      elseif kind == "hover" then
        opts.title = "Documentation"
      else
        opts.title = "LSP Preview"
      end
    end
    opts.title_pos = opts.title_pos or "left"

    -- Wrap unless the caller explicitly said not to; see the header.
    if opts.wrap == nil then
      opts.wrap = true
    end

    -- The buffer the marker lives on, captured BEFORE the float exists. On the
    -- focus-reuse path (`focus_id` set and the float already open -- the second
    -- `K`) open_floating_preview enters the float window, so the current buffer
    -- afterwards is the FLOAT's, and clearing the marker there leaves the
    -- source buffer marked "hover" for the rest of the session: the next
    -- unrelated float in it is titled "Documentation" instead of "LSP Preview".
    local src = vim.api.nvim_get_current_buf()

    local bufnr, winid = _orig_open_floating_preview(contents, syntax, opts, ...)

    if winid and vim.api.nvim_win_is_valid(winid) then
      vim.wo[winid].number = true
      vim.wo[winid].relativenumber = true
      vim.wo[winid].wrap = opts.wrap ~= false

      M.enforce_float_size(winid)
    end

    -- Reset the kind marker, on the buffer it was READ from. It is set by the
    -- K handler, by the <C-k>/gK signature handlers and by andrew.lsp_keymaps,
    -- and used to be set and never cleared -- so an unrelated float opened
    -- later in the same buffer (a diagnostic float, a plugin's preview)
    -- inherited whichever kind was last requested and got titled
    -- "Documentation" for no reason.
    if vim.api.nvim_buf_is_valid(src) then
      vim.b[src].lsp_popup_kind = nil
    end

    return bufnr, winid
  end
end

--- Restore the original open_floating_preview (tests; never used at runtime).
function M.teardown()
  if _orig_open_floating_preview then
    vim.lsp.util.open_floating_preview = _orig_open_floating_preview
    _orig_open_floating_preview = nil
  end
end

return M
