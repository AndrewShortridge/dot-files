local config = require("andrew.vault.config")
local hl_coord = require("andrew.vault.highlight_coordinator")
local M = {}

M.enabled = config.highlight_marks.enabled
M.ns = vim.api.nvim_create_namespace("vault_highlight_hl")

local _nav_cache = {}

-- -----------------------------------------------------------------------
-- Toggle
-- -----------------------------------------------------------------------

M.toggle = hl_coord.make_toggle(M, "highlight marks")

-- -----------------------------------------------------------------------
-- Navigation (via factory)
-- -----------------------------------------------------------------------

--- Pipeline-aware wrapper around scan_highlights. When the transform pipeline
--- is active and the parse cache is warm for the current buffer, iterate cached
--- tokens instead of doing a full buffer scan.
local function scan_highlights_pipeline_aware(lines, start_line, code_excl, fm_start, fm_end, callback)
    local parse_cache = require("andrew.vault.line_parse_cache")
    local bufnr = vim.api.nvim_get_current_buf()
    local iter = parse_cache.pipeline_token_iter(bufnr, "highlight")
    if not iter then return end
    for line_nr, token in iter do
        -- token.start_col/end_col are 0-indexed exclusive;
        -- scan_highlights callback expects 1-indexed s and e
        callback(line_nr, token.start_col + 1, token.end_col)
    end
end

local jump_highlight = hl_coord.make_scan_nav(_nav_cache, scan_highlights_pipeline_aware, function(row, s, _e)
    return row + 1, s
end)

-- -----------------------------------------------------------------------
-- Setup
-- -----------------------------------------------------------------------

function M.setup()
    local palette = require("andrew.vault.command_palette")
    local group = vim.api.nvim_create_augroup("VaultHighlightHL", { clear = true })

    hl_coord.setup_buf_cleanup(group, M.ns, { _nav_cache })

    -- Commands
    vim.api.nvim_create_user_command("VaultHighlightToggle", function()
        M.toggle()
    end, { desc = "Toggle ==highlight== rendering" })

    hl_coord.make_refresh_command("VaultHighlightRefresh", "Refresh ==highlight== marks in current buffer")

    -- FileType autocmd removed: now dispatched via event_dispatch.lua

    -- Palette registrations
    palette.register_command("VaultHighlightToggle", "Toggle ==highlight== rendering", "Debug", function()
        M.toggle()
    end)
    palette.register_command("VaultHighlightRefresh", "Refresh ==highlight== marks in current buffer", "Debug", function()
        vim.cmd("VaultHighlightRefresh")
    end)
    palette.register_keymap("]h", "Next ==highlight==", "Debug", function()
        jump_highlight(1)
    end, true)
    palette.register_keymap("[h", "Previous ==highlight==", "Debug", function()
        jump_highlight(-1)
    end, true)

end

--- Called by event_dispatch.lua on FileType markdown.
--- @param ev table autocmd event args
function M.on_ft_markdown(ev)
    hl_coord.register_nav_keymaps(ev, jump_highlight, "]h", "[h", "Next ==highlight==", "Previous ==highlight==")
end

return M
