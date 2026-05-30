local engine = require("andrew.vault.engine")
local notify = require("andrew.vault.notify")

local M = {}

--- Extract the current visual selection into a new note.
--- Prompts for a note name, creates the note with the selected text,
--- and replaces the selection with a wikilink to the new note.
function M.extract()
  -- Get visual selection range
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line == 0 or end_line == 0 then
    notify.warn("no selection")
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  if #lines == 0 then
    notify.warn("empty selection")
    return
  end

  local content = table.concat(lines, "\n")

  engine.run(function()
    local name = engine.input({ prompt = "New note name: " })
    if not name or name == "" then return end

    -- Build the note content with frontmatter
    local note = table.concat({
      "---",
      "type: note",
      "created: " .. engine.today(),
      "tags: []",
      "---",
      "",
      "# " .. name,
      "",
      content,
      "",
    }, "\n")

    -- Remember the current buffer before write_note switches away
    local original_buf = vim.api.nvim_get_current_buf()

    -- Write the note
    engine.write_note(name, note)

    -- Go back to the original buffer and replace selection with wikilink
    vim.api.nvim_set_current_buf(original_buf)
    vim.api.nvim_buf_set_lines(0, start_line - 1, end_line, false, { "[[" .. name .. "]]" })
    notify.info("extracted to [[" .. name .. "]]")
  end)
end

return M
