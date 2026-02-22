local engine = require("andrew.vault.engine")

local M = {}

--- Extract the current visual selection into a new note.
--- Prompts for a note name, creates the note with the selected text,
--- and replaces the selection with a wikilink to the new note.
function M.extract()
  -- Get visual selection range
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line == 0 or end_line == 0 then
    vim.notify("Vault: no selection", vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  if #lines == 0 then
    vim.notify("Vault: empty selection", vim.log.levels.WARN)
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
    vim.notify("Extracted to [[" .. name .. "]]", vim.log.levels.INFO)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("VaultExtract", function()
    M.extract()
  end, { desc = "Extract selection to new vault note", range = true })

  local group = vim.api.nvim_create_augroup("VaultExtract", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("v", "<leader>vex", function()
        local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
        vim.api.nvim_feedkeys(esc, "nx", false)
        vim.schedule(function()
          M.extract()
        end)
      end, { buffer = ev.buf, desc = "Edit: extract to note", silent = true })
    end,
  })
end

return M
