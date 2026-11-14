-- =============================================================================
-- LSP Client Capabilities
-- =============================================================================
-- What this config tells every language server it can handle, on top of
-- Neovim's own defaults.
--
-- The completion block is a COPY of what blink.cmp's get_lsp_capabilities()
-- returns. It is copied rather than called because capabilities are sent once,
-- in `initialize`, when a server starts -- i.e. when a file is opened -- and
-- calling into blink there loaded blink.cmp and LuaSnip (28-58 ms) before the
-- first paint, only to read a constant table. blink now loads on InsertEnter.
--
-- tests/lsp_capabilities_drift_spec.lua compares this copy against the
-- installed blink.cmp, so a blink update that changes its capabilities fails a
-- test instead of silently under-advertising to every server.
--
-- At the andrew.* level, NOT under plugins/lsp/, because lazy.lua imports every
-- file under andrew/plugins/lsp as a plugin spec.

local M = {}

--- blink.cmp's completion capabilities (blink/cmp/sources/lib/init.lua).
---@type table
M.COMPLETION = {
  textDocument = {
    completion = {
      completionItem = {
        snippetSupport = true,
        commitCharactersSupport = false,
        documentationFormat = { "markdown", "plaintext" },
        deprecatedSupport = true,
        preselectSupport = false,
        tagSupport = { valueSet = { 1 } },
        insertReplaceSupport = true,
        resolveSupport = {
          properties = {
            "documentation",
            "detail",
            "additionalTextEdits",
            "command",
            "data",
          },
        },
        insertTextModeSupport = {
          valueSet = { 1 },
        },
        labelDetailsSupport = true,
      },
      completionList = {
        itemDefaults = {
          "commitCharacters",
          "editRange",
          "insertTextFormat",
          "insertTextMode",
          "data",
        },
      },
      contextSupport = true,
      insertTextMode = 1,
    },
  },
}

return M
