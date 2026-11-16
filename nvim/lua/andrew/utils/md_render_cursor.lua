-- =============================================================================
-- md-render: carrying the cursor between the rendered view and the source
-- =============================================================================
-- md-render's rendered view is a different buffer with different text: markup
-- is gone (`**bold**` reads `bold`, a link has lost its URL), icons and box
-- characters are added, and paragraphs are re-wrapped, so one source line can
-- be several rendered lines and several source lines can be one. A (line,
-- column) in one therefore says nothing about the column in the other, and
-- md-render does not try: swapping either way puts the cursor in the first
-- column.
--
-- What the two buffers do share is their WORDS, in the same order. So: split a
-- stretch of each into words, line the two lists up with a diff, and the word
-- under the cursor names its counterpart in the other buffer. Words that exist
-- on one side only -- the host and path of a link, an icon, the "Properties"
-- heading of the frontmatter block -- are what the diff reports as changes,
-- and are skipped.
--
-- Nothing here knows which side is which: the buffer the cursor is in is the
-- ORIGIN, the one it is going to is the TARGET.
--
-- Pure text in, position out: no md-render API and no buffer access, which is
-- why it lives apart from plugins/md-render.lua (the caller) and is tested on
-- its own in tests/md_render_cursor_spec.lua.

local M = {}

---@class MdRenderCursorWord
---@field text string
---@field line integer buffer line, 1-based
---@field start_col integer byte column of the first byte, 0-based
---@field end_col integer byte column after the last byte

---@class MdRenderCursorStretch a run of consecutive buffer lines
---@field lines string[]
---@field first_line integer buffer line number of `lines[1]`

--- Letters, digits, underscore, and every byte of a multi-byte character. The
--- columns the API takes are bytes, so nothing here needs decoding.
local WORD_PATTERN = "()([%w_\128-\255]+)()"

---@param stretch MdRenderCursorStretch
---@return MdRenderCursorWord[]
local function words_in(stretch)
  local words = {}
  for line_offset, line in ipairs(stretch.lines) do
    for start_position, text, end_position in line:gmatch(WORD_PATTERN) do
      words[#words + 1] = {
        text = text,
        line = stretch.first_line + line_offset - 1,
        start_col = start_position - 1,
        end_col = end_position - 1,
      }
    end
  end
  return words
end

--- Which target word each origin word corresponds to.
---@param origin_words MdRenderCursorWord[]
---@param target_words MdRenderCursorWord[]
---@return table<integer, integer> target_index_of origin word index -> target word index, for words on both sides
local function align(origin_words, target_words)
  local target_index_of = {}
  if #origin_words == 0 or #target_words == 0 then
    return target_index_of
  end

  local function one_word_per_line(words)
    local texts = {}
    for index, word in ipairs(words) do
      texts[index] = word.text
    end
    return table.concat(texts, "\n") .. "\n"
  end

  local hunks = vim.text.diff(one_word_per_line(origin_words), one_word_per_line(target_words), {
    result_type = "indices",
  }) --[[@as integer[][] ]]

  -- Everything between two hunks is identical on both sides, word for word.
  local origin_index, target_index = 1, 1
  local function pair_up_to(origin_end)
    while origin_index < origin_end do
      target_index_of[origin_index] = target_index
      origin_index, target_index = origin_index + 1, target_index + 1
    end
  end
  for _, hunk in ipairs(hunks) do
    local origin_start, origin_count, target_start, target_count =
      hunk[1], hunk[2], hunk[3], hunk[4]
    -- A side with nothing in the hunk gives the line BEFORE it, not its first.
    if origin_count == 0 then
      origin_start = origin_start + 1
    end
    if target_count == 0 then
      target_start = target_start + 1
    end
    pair_up_to(origin_start)
    origin_index, target_index = origin_start + origin_count, target_start + target_count
  end
  pair_up_to(#origin_words + 1)
  return target_index_of
end

--- The origin word the cursor position is read against, and how the cursor
--- sits relative to it. On a word: that word. Between words, or on a word the
--- target does not have: the NEXT shared one on the line, so that whatever
--- closes the previous word (`**bold** text`, cursor on the space) stays on the
--- far side; the previous one only at the end of a line. The second return
--- value is the cursor's byte distance from the start of the word (`"start"`)
--- or from its end (`"end"`).
---@param origin_words MdRenderCursorWord[]
---@param target_index_of table<integer, integer>
---@param cursor_line integer
---@param cursor_col integer
---@return integer? origin_index
---@return integer? distance
---@return ("start"|"end")? measured_from
local function anchor_word(origin_words, target_index_of, cursor_line, cursor_col)
  local previous_index
  for origin_index, word in ipairs(origin_words) do
    if word.line == cursor_line and target_index_of[origin_index] then
      if cursor_col < word.end_col then
        -- On this word, or before it with no shared word in between.
        return origin_index, cursor_col - word.start_col, "start"
      end
      previous_index = origin_index
    elseif word.line > cursor_line then
      break
    end
  end
  if previous_index then
    return previous_index, cursor_col - origin_words[previous_index].end_col, "end"
  end
end

--- Map a cursor in one of the two buffers to the same place in the other.
---
--- Both sides are given as a stretch of lines around the place in question;
--- they need not cover the same text, only overlap around the cursor.
---@param origin MdRenderCursorStretch the buffer the cursor is in
---@param cursor [integer, integer] its position there, (1,0)-indexed like nvim_win_get_cursor()
---@param target MdRenderCursorStretch the buffer it is going to
---@return [integer, integer]? position (1,0)-indexed position in the target; nil when no word on the cursor's line could be found there
function M.counterpart_position(origin, cursor, target)
  local origin_words = words_in(origin)
  local target_words = words_in(target)
  local target_index_of = align(origin_words, target_words)

  local origin_index, distance, measured_from =
    anchor_word(origin_words, target_index_of, cursor[1], cursor[2])
  if not origin_index then
    return nil
  end
  local target_word = target_words[target_index_of[origin_index]]
  local target_line = target.lines[target_word.line - target.first_line + 1]

  local target_col
  if measured_from == "end" then
    target_col = target_word.end_col + distance
  else
    target_col = target_word.start_col + distance
    -- Before the word: not further back than the word before it in the target.
    -- In the source that is where a skipped URL or opening markup would be; in
    -- the view, the text of the link whose URL the cursor was in.
    local target_word_before = target_words[target_index_of[origin_index] - 1]
    if distance < 0 and target_word_before and target_word_before.line == target_word.line then
      target_col = math.max(target_col, target_word_before.end_col)
    end
  end
  return { target_word.line, math.max(0, math.min(target_col, #target_line - 1)) }
end

return M
