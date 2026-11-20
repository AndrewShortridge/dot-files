-- Functions Neovim 0.13 renamed or replaced, under one name each.
--
-- 0.13 deprecates the old names (removal: 0.14 for `vim.hl.on_yank`, 0.15 for
-- the `vim.uri_*` ones; `nvim_win_set_width` has no date) and 0.12 has only the
-- old ones, so a caller that names either is wrong on one of the two. Callers use
-- this module instead and the config runs on both. Once 0.12 is no longer a
-- fallback: call the 0.13 functions directly and delete this file.
--
-- A `disable-next-line: deprecated` here marks a 0.12 name being read. This
-- module is the only place one may be written.

local M = {}

local has_uri_module = vim.uri ~= nil

---@diagnostic disable-next-line: deprecated
local uri_to_bufnr_before_0_13 = vim.uri_to_bufnr
---@diagnostic disable-next-line: deprecated
local uri_from_bufnr_before_0_13 = vim.uri_from_bufnr
---@diagnostic disable-next-line: deprecated
local uri_from_fname_before_0_13 = vim.uri_from_fname
---@diagnostic disable-next-line: deprecated
local uri_to_fname_before_0_13 = vim.uri_to_fname
---@diagnostic disable-next-line: deprecated
local win_set_width_before_0_13 = vim.api.nvim_win_set_width
---@diagnostic disable-next-line: deprecated
local on_yank_before_0_13 = vim.hl.on_yank

--- The buffer of a URI, created (not loaded) when there is none yet.
---@type fun(uri: string): integer
M.uri_to_buffer = has_uri_module and vim.uri.to_buf or uri_to_bufnr_before_0_13

--- The `file://` URI of a buffer's name.
---@type fun(buffer: integer): string
M.uri_from_buffer = has_uri_module and vim.uri.from_buf or uri_from_bufnr_before_0_13

--- The `file://` URI of a file path.
---@type fun(file_name: string): string
M.uri_from_file_name = has_uri_module and vim.uri.from_fname or uri_from_fname_before_0_13

--- The file path of a URI.
---@type fun(uri: string): string
M.uri_to_file_name = has_uri_module and vim.uri.to_fname or uri_to_fname_before_0_13

--- Set the width of a window, as `:vertical resize` does. With its default
--- anchor nvim_win_resize() gave every window of 300 random split layouts the
--- width nvim_win_set_width() gave it.
---@type fun(window: integer, width: integer)
M.set_window_width = vim.api.nvim_win_resize
    and function(window, width)
      vim.api.nvim_win_resize(window, width, -1, {})
    end
  or win_set_width_before_0_13

--- Flash the text of a TextYankPost event.
---@type fun(opts?: { higroup?: string, timeout?: integer })
M.highlight_yanked_text = vim.hl.hl_op or on_yank_before_0_13

return M
