-- =============================================================================
-- Markdown Renderer Switch
-- =============================================================================
-- Which plugin renders a markdown FILE buffer. Two backends, both installed;
-- DEFAULT_BACKEND below names the one a markdown buffer opens with, the other
-- is one command away. The counterpart of utils/file_picker.lua.
--
--   "render-markdown"  -- render-markdown.nvim decorates the buffer you edit
--                         (plugins/render-markdown.lua). What this config has
--                         always done.
--   "md-render"        -- md-render.nvim's auto mode (`:help :MdRender-auto`,
--                         upstream calls it experimental): outside Insert mode
--                         the window shows a separate read-only rendered
--                         buffer, named `<file> [render]`; `i` `I` `a` `A` `o`
--                         `O` swap back to the source and enter Insert, and
--                         leaving Insert swaps to the rendered view again.
--                         render-markdown is switched off in that buffer, so
--                         the source is plain text while you type.
--
-- Switch for the running session, no restart needed:
--
--   :MarkdownRenderer md-render
--   :MarkdownRenderer render-markdown
--   :MarkdownRenderer                  (says which one is in use)
--
-- The command sets `vim.g.markdown_renderer` and applies it. Setting the
-- variable yourself works too (in init.lua, to change what a session starts
-- with), but then a buffer only follows once it is entered.
--
-- Exactly one backend is on in a buffer. A buffer is switched when it is the
-- current one: md-render's auto mode works on the current window and nothing
-- else, so a markdown buffer in another split keeps its renderer until you
-- enter it.
--
-- What is NOT switched:
--   * The vault's preview floats and blink.cmp's documentation window. Those
--     call render-markdown directly and stay with it under either backend.
--   * A window you swapped by hand with `:MdRender toggle`. Only views opened
--     by auto mode are taken back when switching away from md-render.
--   * Everything bound to the markdown buffer -- the vault keymaps, <leader>m,
--     callout folds, gitsigns. The rendered view is another buffer and has
--     none of them; they are back the moment you are in the source.

local M = {}

local DEFAULT_BACKEND = "md-render"

--- The backend currently on in a buffer is recorded in this buffer variable, so
--- a buffer is switched once per choice and anything done by hand afterwards
--- (`:MdRender auto off`, `:RenderMarkdown buf_toggle`) is left alone.
local APPLIED_BACKEND_VARIABLE = "markdown_renderer"

---@param bufnr integer
---@param is_enabled boolean
local function set_render_markdown(bufnr, is_enabled)
  local render_markdown = require("render-markdown")
  if render_markdown.get(bufnr) == is_enabled then
    return
  end
  -- set_buf() takes no buffer: it acts on the current one.
  vim.api.nvim_buf_call(bufnr, function()
    render_markdown.set_buf(is_enabled)
  end)
end

--- The buffer md-render renders `bufnr` into, if it has made one.
---@param bufnr integer
---@return integer?
local function md_render_view_of(bufnr)
  local view_name = vim.api.nvim_buf_get_name(bufnr) .. " [render]"
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[candidate].md_render and vim.api.nvim_buf_get_name(candidate) == view_name then
      return candidate
    end
  end
end

--- md-render's auto mode swaps the buffer of the CURRENT window, and swapping
--- to a read-only buffer mid-Insert would strand the edit.
---@param bufnr integer
---@return boolean
local function is_ready_for_md_render(bufnr)
  return vim.api.nvim_get_current_buf() == bufnr
    and vim.bo[bufnr].buftype == ""
    and vim.api.nvim_win_get_config(0).relative == ""
    and not vim.api.nvim_get_mode().mode:find("^[iR]")
end

---@class MarkdownRendererBackend
---@field can_enable fun(bufnr: integer): boolean whether enable() would work right now
---@field enable fun(bufnr: integer)
---@field disable fun(bufnr: integer)

---@type table<string, MarkdownRendererBackend>
local backends = {
  ["render-markdown"] = {
    can_enable = function()
      return true
    end,
    enable = function(bufnr)
      set_render_markdown(bufnr, true)
    end,
    disable = function(bufnr)
      set_render_markdown(bufnr, false)
    end,
  },
  ["md-render"] = {
    can_enable = is_ready_for_md_render,
    enable = function()
      require("md-render").preview.auto_on()
    end,
    disable = function(bufnr)
      -- Also keeps md-render unloaded for as long as it was never used.
      if not vim.b[bufnr].md_render_auto then
        return
      end
      local preview = require("md-render").preview
      local view = md_render_view_of(bufnr)
      for _, window in ipairs(view and vim.fn.win_findbuf(view) or {}) do
        vim.api.nvim_win_call(window, preview.toggle)
      end
      vim.api.nvim_buf_call(bufnr, preview.auto_off)
    end,
  },
}

---@return string[]
local function backend_names()
  local names = vim.tbl_keys(backends)
  table.sort(names)
  return names
end

---@param backend_name any
local function report_unknown_backend(backend_name)
  vim.notify_once(
    ("markdown renderer: unknown backend %q (expected one of: %s)"):format(
      tostring(backend_name),
      table.concat(backend_names(), ", ")
    ),
    vim.log.levels.ERROR
  )
end

--- The backend named by `vim.g.markdown_renderer` (default: DEFAULT_BACKEND).
---@return string? backend_name nil when the variable names no backend
function M.selected()
  local backend_name = vim.g.markdown_renderer or DEFAULT_BACKEND
  if backends[backend_name] then
    return backend_name
  end
  report_unknown_backend(backend_name)
end

--- Put a markdown buffer on the selected backend and take the others off it.
--- A no-op for a buffer that is already there, or that cannot be switched yet.
---@param bufnr integer
function M.sync(bufnr)
  local selected_name = M.selected()
  if not selected_name or vim.b[bufnr][APPLIED_BACKEND_VARIABLE] == selected_name then
    return
  end
  local selected_backend = backends[selected_name]
  if not selected_backend.can_enable(bufnr) then
    return
  end
  for backend_name, backend in pairs(backends) do
    if backend_name ~= selected_name then
      backend.disable(bufnr)
    end
  end
  vim.b[bufnr][APPLIED_BACKEND_VARIABLE] = selected_name
  -- The new backend goes on one tick AFTER the old one came off. render-markdown
  -- removes its decorations in a scheduled callback that gives up unless the
  -- buffer is still on screen (core/ui.lua, Updater:run), and enabling
  -- md-render is what takes it off screen. Done in the same tick, the source
  -- keeps render-markdown's decorations for good.
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr][APPLIED_BACKEND_VARIABLE] ~= selected_name then
      return
    end
    if selected_backend.can_enable(bufnr) then
      selected_backend.enable(bufnr)
    else
      -- Left with no renderer; picked up again the next time it is entered.
      vim.b[bufnr][APPLIED_BACKEND_VARIABLE] = nil
    end
  end)
end

--- Select a backend for the session and switch every markdown buffer that can
--- be switched now; the rest follow when they are entered.
---@param backend_name string
function M.use(backend_name)
  if not backends[backend_name] then
    report_unknown_backend(backend_name)
    return
  end
  vim.g.markdown_renderer = backend_name
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "markdown" then
      M.sync(bufnr)
    end
  end
end

function M.setup()
  -- FileType: a buffer becoming markdown. BufEnter: one that could not be
  -- switched while it was not current. InsertLeave: one that became markdown
  -- mid-Insert (a template that starts you typing).
  vim.api.nvim_create_autocmd({ "FileType", "BufEnter", "InsertLeave" }, {
    group = vim.api.nvim_create_augroup("markdown-renderer-switch", { clear = true }),
    callback = function(event)
      local bufnr = event.buf
      if vim.bo[bufnr].filetype ~= "markdown" or vim.b[bufnr][APPLIED_BACKEND_VARIABLE] == M.selected() then
        return
      end
      -- Scheduled: enabling md-render swaps the window's buffer, which must not
      -- happen inside the autocmd that is still entering the old one; and on
      -- FileType, render-markdown has to have attached before it can be turned
      -- off.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "markdown" then
          M.sync(bufnr)
        end
      end)
    end,
  })

  vim.api.nvim_create_user_command("MarkdownRenderer", function(command)
    if command.args == "" then
      vim.notify(
        ("markdown renderer: %s (available: %s)"):format(
          tostring(vim.g.markdown_renderer or DEFAULT_BACKEND),
          table.concat(backend_names(), ", ")
        )
      )
      return
    end
    M.use(command.args)
  end, {
    nargs = "?",
    complete = function(argument_lead)
      return vim.tbl_filter(function(backend_name)
        return vim.startswith(backend_name, argument_lead)
      end, backend_names())
    end,
    desc = "Markdown: choose the plugin that renders markdown buffers",
  })
end

return M
