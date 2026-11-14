-- =============================================================================
-- File Finder Backend Switch
-- =============================================================================
-- <leader>ff and <leader><space> (core/keymaps.lua) both call find_files().
--
-- Two backends, both fully configured. DEFAULT_BACKEND below names the one
-- those keys open; the other stays one command away.
--
--   "fzf"     -- fzf-lua's files picker, with the real fzf binary doing the
--                matching. Everything about it is set once in
--                plugins/fzf-lua.lua's setup(): what it lists
--                (`files = { cmd = ... }`), its actions and keymaps, and the
--                look it shares with every other fzf-lua picker
--                (utils/fzf_look.lua: the snacks picker's layout, the
--                `telescope` profile's colours, <C-d> / <C-u> paging the
--                preview). Nothing about the look is passed from here.
--   "snacks"  -- Snacks.picker.files, set up the way craftzdog's dotfiles do
--                (https://github.com/craftzdog/dotfiles): the stock picker
--                with `hidden = true`, configured in plugins/snacks.lua under
--                `picker.sources.files`. No fzf binary involved; snacks runs
--                fd and ranks the results with its own matcher.
--
-- Switch for the running session, no restart needed:
--
--   :let g:file_picker_backend = "snacks"
--
-- Only the FILE finder is switched. Grep, recent files, buffers, LSP pickers
-- and everything else under <leader>f / <leader>s are fzf-lua whichever
-- backend is chosen here.

local M = {}

local DEFAULT_BACKEND = "fzf"

local open_file_finder = {
  fzf = function()
    require("fzf-lua").files(require("andrew.utils.obsidian").picker_opts())
  end,
  snacks = function()
    Snacks.picker.files(require("andrew.utils.obsidian").snacks_picker_opts())
  end,
}

--- Open the file finder in the current working directory, using the backend
--- named by `vim.g.file_picker_backend` (default: DEFAULT_BACKEND).
function M.find_files()
  local backend = vim.g.file_picker_backend or DEFAULT_BACKEND
  local open = open_file_finder[backend]
  if not open then
    local known_backends = vim.tbl_keys(open_file_finder)
    table.sort(known_backends)
    vim.notify(
      ("file picker: unknown g:file_picker_backend %q (expected one of: %s)"):format(
        tostring(backend),
        table.concat(known_backends, ", ")
      ),
      vim.log.levels.ERROR
    )
    return
  end
  open()
end

return M
