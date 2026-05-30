--- blink.cmp spell suggestion source for markdown buffers.
--- Provides vim.fn.spellsuggest() results as completion items.
---
--- Only activates when the cursor is on a misspelled word (identified by
--- vim's spell checking). This avoids polluting the completion menu with
--- spell suggestions for correctly-spelled words.

local base = require("andrew.vault.completion_base")

--- @class blink.cmp.SpellSource : blink.cmp.Source
local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

--- Check if spell source should be enabled.
--- Only provide completions when spell checking is active.
function M:enabled()
  return vim.wo.spell
end

--- Get completions: spell suggestions for the word under cursor.
---@param _ctx blink.cmp.Context
---@param callback fun(response: blink.cmp.CompletionResponse)
function M:get_completions(_ctx, callback)
  -- Get the word under cursor
  local word = vim.fn.expand("<cword>")
  if not word or word == "" then
    callback(base.empty_response)
    return
  end

  -- Only suggest corrections for misspelled words.
  -- vim.fn.spellbadword() returns {"word", "type"} for bad words, {"", ""} otherwise.
  local bad = vim.fn.spellbadword(word)
  if not bad or not bad[1] or bad[1] == "" then
    callback(base.empty_response)
    return
  end

  -- Get suggestions (limit to 10 for performance)
  local suggestions = vim.fn.spellsuggest(word, 10)
  local items = {}
  for i, suggestion in ipairs(suggestions) do
    items[i] = base.make_item(suggestion, suggestion, word, base.KIND.Text, {
      sortText = base.order_sort_text(i),
      description = "Spell",
      data = { source = "spell" },
    })
  end

  callback(base.response(items))
end

return M
