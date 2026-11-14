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

--- Extract the word surrounding the cursor from the completion context.
--- `vim.fn.expand("<cword>")` cannot be used on its own: while typing in INSERT
--- mode the cursor sits one byte PAST the last character, which is off the end
--- of the line, and <cword> then evaluates to "" — so the source produced no
--- suggestions at all in real use. The context line/column are authoritative.
---@param ctx table|nil blink.cmp.Context
---@return string
local function word_at_cursor(ctx)
  local line = ctx and ctx.line
  local col = ctx and ctx.cursor and ctx.cursor[2]
  if type(line) == "string" and type(col) == "number" then
    local head = line:sub(1, col):match("[%a'][%a']*$") or ""
    local tail = line:sub(col + 1):match("^[%a']*") or ""
    local word = head .. tail
    if word ~= "" then return word end
  end
  -- Fallback for a nil/odd context. pcall: expand("<cword>") raises E348 when
  -- there is genuinely no word under the cursor (e.g. an empty line).
  local ok, cword = pcall(vim.fn.expand, "<cword>")
  return (ok and cword) or ""
end

--- Spell suggestions depend on the WHOLE word typed so far, not on a stable
--- item set that blink can re-filter locally. A complete response
--- (is_incomplete_* = false) makes blink cache the first answer for the trigger
--- context and never re-query, so the empty result for the first typed letter
--- stuck for the rest of the word and the source produced nothing. Marking every
--- response incomplete makes blink re-ask on each keystroke.
---@param items table[]
---@return table
local function incomplete_response(items)
  return { is_incomplete_forward = true, is_incomplete_backward = true, items = items }
end

--- Get completions: spell suggestions for the word under cursor.
---@param _ctx blink.cmp.Context
---@param callback fun(response: blink.cmp.CompletionResponse)
function M:get_completions(_ctx, callback)
  -- Get the word under cursor
  local word = word_at_cursor(_ctx)
  if not word or word == "" then
    callback(incomplete_response({}))
    return
  end

  -- Only suggest corrections for misspelled words.
  -- vim.fn.spellbadword() returns {"word", "type"} for bad words, {"", ""} otherwise.
  local bad = vim.fn.spellbadword(word)
  if not bad or not bad[1] or bad[1] == "" then
    callback(incomplete_response({}))
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

  callback(incomplete_response(items))
end

return M
