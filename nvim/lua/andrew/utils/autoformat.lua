-- =============================================================================
-- Format-on-save gate
-- =============================================================================
-- LazyVim carries a whole formatter registry (lazyvim/util/format.lua) whose
-- only job here would be to let conform beat the LSP formatter -- something
-- conform already does on its own via lsp_fallback. What is worth porting is
-- the TOGGLE: vim.b.autoformat overrides vim.g.autoformat, both default to on,
-- and format-on-save consults them (LazyVim util/format.lua:84-96).
--
-- Before this, formatting on save was unconditional and there was no way to
-- suppress it short of :noautocmd w.
--
-- Both save paths in plugins/formatting/conform.lua consult enabled(); if you
-- add a third, gate it here too or <leader>uf will look broken.

local M = {}

--- Is format-on-save active for this buffer?
--- Buffer-local setting wins; otherwise the global; otherwise on.
---@param buf integer|nil
---@return boolean
function M.enabled(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local b = vim.b[buf].autoformat
  if b ~= nil then
    return b
  end
  return vim.g.autoformat ~= false
end

--- Snacks toggle definition for <leader>uf / <leader>uF.
--- Snacks ships no format toggle of its own (its toggle.lua has factories for
--- inlay hints, diagnostics, dim, words, ... but nothing for formatting), so
--- this is a hand-rolled Snacks.toggle.new.
---@param buffer boolean|nil  true for the buffer-local toggle
function M.snacks_toggle(buffer)
  return Snacks.toggle({
    name = "Auto Format (" .. (buffer and "Buffer" or "Global") .. ")",
    get = function()
      if not buffer then
        return vim.g.autoformat ~= false
      end
      return M.enabled(0)
    end,
    set = function(state)
      if buffer then
        -- The buffer toggle writes true/false, never nil: an explicit buffer
        -- value is what lets this buffer disagree with the global (LazyVim
        -- does the same, util/format.lua:30-37).
        vim.b.autoformat = state
      else
        -- Flipping the GLOBAL clears the buffer override (nil, not false), so
        -- the buffer stops disagreeing and follows the global again.
        vim.g.autoformat = state
        vim.b.autoformat = nil
      end
    end,
  })
end

return M
