-- =============================================================================
-- md-render: LaTeX math as typeset pictures in the rendered view
-- =============================================================================
-- md-render v3.11.2 only colours TeX: `$tex$` and the lines of a `$$` block
-- keep their raw TeX under `MdRenderMath`, mangled on the way -- its inline
-- passes run before its math pass, so `\mathbf{v}_i` comes out as
-- `\mathbf{v}i` in italics and `a \, b` as `a , b` (markdown.lua:1616-1643).
-- A `> $$` block in a callout is plain quoted text to it, and a ```math fence
-- a code block.
--
-- Here every equation is shown as a picture made by pdftex, drawn by Kitty's
-- Unicode placeholders: the picture is a run of placeholder cells IN THE TEXT
-- of the view (andrew.utils.md_render_math_kitty), so it is part of Neovim's
-- grid, scrolls, wraps and sits in floats like text, and md-render's own image
-- machinery is not involved. md_render_math_tex makes colour-free masks; the
-- colour (`MdRenderMath`'s foreground) is given to md_render_math_kitty, which
-- tints them, so a new colour scheme needs no TeX. Where no picture can be
-- shown -- while it is being made, in a heading md-render scales, without
-- terminal support or pdftex/mutool, when an inline picture would be wider
-- than its line or shrink below 0.6 of its size, when a display picture
-- would have to shrink below half its size, for a box beyond Kitty's 297
-- cells, when a picture's file went missing twice (until `:MdRenderMath
-- retry`), or with `vim.g.md_render_math = "text"` -- the equation is
-- Unicode text instead (andrew.utils.md_render_math_text); display text
-- wider than the line is wrapped by md-render as one line of text. TeX that
-- failed to compile, and everything under `vim.g.md_render_math = "off"`, is
-- left exactly as md-render shows it.
--
-- How, without changing md-render: six of its functions are wrapped.
--
--   preview.build_content (preview.lua:107)   one build: decides picture or
--     text mode and the look (cell size) once, and afterwards asks
--     md_render_math_tex for the pictures the build found missing, in document
--     order; more than VISIBLE_FIRST_THRESHOLD of them are asked for in two
--     requests, those on or near what a window on the view shows first
--     (`visible_source_ranges`: each window's own lines, not all between).
--     Not in Insert mode: what the last Insert-mode build of a view found
--     missing is asked for on leaving it, without a rebuild. The keys a build
--     waits for are left in `content.math_pending`; when they settle, only the
--     views whose content waits for one are rebuilt (or marked `dirty` when
--     hidden: a hidden view is reused as it was unless it is,
--     preview.lua:1957), each by `session:rebuild()` + `refresh_images()` as
--     `preview.rebuild_visible()` does (preview.lua:263-273).
--   ContentBuilder.render_document (content_builder.lua:1532)   keeps the
--     source lines, so that a block's TeX is read from the source and not from
--     md-render's output; finds the `$$` blocks md-render will read -- a `$$`
--     line at the content column of its list item (strip_container_indent,
--     content_builder.lua:1237-1277), outside code fences -- the only plain
--     blocks add_line draws, and none after a `$$` line the writer meant as a
--     delimiter that md-render does not read as one (see Limits); notes the
--     quoted lines md-render does not read as rows of the quote before them;
--     and rewrites ```math fences (fence.lua:26,50) into `$$` lines, LINE FOR
--     LINE so that every line number stays as it was, where md-render will
--     read them as one block.
--   markdown.render (markdown.lua:1486)   INLINE: each `$tex$` of the source
--     line becomes a run of U+00A0 as wide as what will be shown, BEFORE
--     md-render parses the line, and the picture's placeholder row (or the
--     text) replaces that run in what it returns, with every later highlight
--     and link moved by the byte difference. md-render then wraps the line,
--     sizes table columns and prefixes callouts with the true width. The 8th
--     return value of a heading, which its anchor is made from
--     (markdown.lua:1677, content_builder.lua:843-845), keeps the TeX. A `$`
--     pair md-render would take as math and pandoc does not (`US$3 or US$4`)
--     reaches it escaped. md-render pairs `$` after its passes over links,
--     emphasis, comments and tags (`$5 and see **$x$**` is `$5 and see $x$`
--     to it): on a line they may change, md-render is asked which `$` its
--     math pass pairs -- its `process_inline_math` (markdown.lua:1311,
--     1643), an upvalue of markdown.render, is watched -- and where that is
--     not what the line pairs, the line is left to it as written. A TeX
--     comment in an equation over two lines of a paragraph ends at its
--     line: the breaks md-render joined away come back.
--     ContentBuilder.add_markdown_line (content_builder.lua:776, 815) is
--     wrapped to learn the width a line will be wrapped at, which rows of it
--     show which equation's text, and which pictures it has.
--   ContentBuilder.add_line (content_builder.lua:110-114)   BLOCKS: md-render
--     emits every line of a `$$` block through it with exactly one whole-line
--     `MdRenderMath` highlight (content_builder.lua:2557-2565); the first
--     becomes the picture's rows, centred like md-render's images
--     (content_builder.lua:3102, 3116-3117), and every other row made from a
--     line inside the block is dropped (a TeX line starting with `|` comes as
--     a table row, content_builder.lua:1898). Where md-render's first row of
--     a block is no TeX row, the block is md-render's. A quoted block comes
--     as quote rows: md-render's `│ $$` row of its opening `> $$` becomes the
--     picture's rows (`quoted_blocks` pairs them, when the first is met) --
--     never a row that only comes from such a line (code showing one, a
--     paragraph). Which source line is being emitted is
--     `_current_source_line`, a private field (content_builder.lua:75). On
--     the rows of a line with pictures, a picture highlight md-render's wrap
--     put late (behind a callout's or heading's icon, in a footnote) is
--     moved onto its cells.
--   display_utils.apply_content_to_buffer (display_utils.lua:163-186)
--     applies every highlight, and its link colours, at the default extmark
--     priority, where which of two wins on a cell depends on where each
--     starts and in which order they were made (both seen deciding). The
--     foreground of a picture's cells names its image, so picture highlights
--     are kept from md-render and applied here instead, one extmark each,
--     above all of its highlights and with `spell = false`;
--     md_render_math_kitty is told which pictures the buffer shows now
--     (`kitty.mark`), so that the ones it no longer shows can be released.
--     Every `MdRenderMath` range also gets an extmark with `spell = false`:
--     TeX and its text are not words.
--
-- Also relied on: `preview._sessions` -- weak values (preview.lua:258): a
-- session lives as long as md-render holds it (`_toggle_sessions`, its
-- buffer's autocmds), so one found there for `equation_at` or `run_refresh`
-- is a live view, and this module keeps none itself --, `session.opts`
-- (the table every build of that view is given, preview.lua:238, 330, 364,
-- 550), `session.buf`, `session.source_bufnr`, `session.source_lines`
-- (preview.lua:236-239, 286-291), `session.content`, `session.dirty`,
-- `session._debounce_timer` (preview.lua:247-248, 1021-1023),
-- `session:refresh_source()` (preview.lua:351, before `:MdRenderMath
-- errors` lists a stale hidden view), `content.source_line_map`
-- (content_builder.lua:59, 112), the
-- builder's `lines`, `_source_breaks` (the rows added so far, and where each
-- line of a joined paragraph starts; content_builder.lua:110-114, 1787-1793)
-- and `add_wrapped_markdown` (content_builder.lua:346, display text wider
-- than the line), `vim.b.md_render` (set on every view buffer,
-- preview.lua:298), `markdown.heading_icon_prefix` (markdown.lua:387),
-- `text_size.spec_for` (text_size.lua:252), `setup_highlights()` (init.lua:84,
-- after a colour scheme cleared md-render's groups), md-render's rule for
-- what is inline math, duplicated in `inline_math_spans` below, its math
-- pass as an upvalue of markdown.render named `process_inline_math` that
-- takes each pair's two `$` out (without it, every line its other passes may
-- change is left to it), its rule for what is a `$$` line and a quote row,
-- followed in `read_container`, and `MdRenderMath` linking to `Special`
-- (init.lua:93).
--
-- `:MdRenderMath status|errors|retry|yank` (made in `setup()`; md-render's
-- plugin spec lists it as a command that loads md-render): the mode and why,
-- the failed equations of the note as a quickfix list with TeX's message,
-- forget every failure, yank the TeX under the cursor in a view
-- (`M.equation_at`).
--
-- Limits, md-render's and the terminal's:
--
--   * A table wider than the view is cut by md-render cell by display width
--     (markdown_table.lua:186). A diacritic has none, so the cut can fall
--     between a placeholder and its diacritics: that cell shows blank, and
--     the column is padded as if it were wider.
--   * Math in a heading md-render scales is text, drawn by OSC 66 in runs. A
--     character the terminal's font lacks (mathematical bold from `\mathbf`,
--     say) takes the whole run it is in into the fallback font, so a few
--     words around it look thinner.
--   * TeX on a `$$` line (`$$ a = b`, `c $$`, `$$ (1)`, `$$` and spaces, a
--     `$$` one to three columns past its list item's content) makes no
--     delimiter for md-render, and no block is drawn from it. Where md-render
--     joins such lines into a paragraph, the `$$...$$` in it is typeset as a
--     one-line `$$tex$$` (inline, in display style); otherwise they are shown
--     as md-render shows them alone. Where the writer meant one as a
--     delimiter, md-render pairs the `$$` lines after it otherwise than the
--     note: no plain block after it is drawn, and no quoted one after it in
--     its quote. Put `$$` on lines of their own, or `$$tex$$` on one line.
--
-- Set up before md_render_repaint.lua, which stays last. Pinned by
-- tests/md_render_math_spec.lua. Drop this file when upstream renders math.

local M = {}

--- An inline picture shrunk to fit its line below this fraction of its
--- natural size is not legible any more: shown as text instead.
local MIN_INLINE_PICTURE_SCALE = 0.6

--- The same for a display picture drawn into a box narrower than it: a
--- 106-column equation in a 40-column view would be drawn at 0.36.
local MIN_DISPLAY_PICTURE_SCALE = 0.5

--- Above every highlight md-render gives a view (default 4096, up to 4200).
--- The image id is the picture's foreground: a higher `fg` or `sp` over its
--- cells breaks it, a lower one is dropped by its `nocombine`.
local PICTURE_HIGHLIGHT_PRIORITY = 10000
M.PICTURE_HIGHLIGHT_PRIORITY = PICTURE_HIGHLIGHT_PRIORITY

--- One cell wide, blank, and neither whitespace to Lua patterns nor a break
--- to md-render's word wrap, so a run of it is one word of known width.
local FILLER = "\194\160"

local TEXT_HIGHLIGHT = "MdRenderMath"

--- What md-render turns an escaped `$` into until its inline passes are
--- over (U+F024, markdown.lua:138-162).
local ESCAPED_DOLLAR = "\239\128\164"

--- A callout's first line (markdown.lua:1511-1550).
local CALLOUT_TITLE = "^%s*>[>%s]*%[!%a+%][+-]?%s"

--- A `$$tex$$` on one line stays in its line, typeset as display math.
local DISPLAY_STYLE = "\\displaystyle "

local QUOTE_PREFIX = "^%s*>[>%s]*"

--- A `> $$` md-render shows as a row of its own: each quote level one `>`
--- and at most one space (split_quote_marker, content_builder.lua:1155),
--- then exactly `$$`. With more, md-render reads ` $$` or `$$ ` -- prose it
--- may join with the next line.
---@param line string
---@return boolean
local function is_quoted_delimiter(line)
  local position = line:find(">", 1, true)
  if not position or line:sub(1, position - 1):find("%S") then
    return false
  end
  while line:byte(position) == 62 do
    position = position + 1
    local byte = line:byte(position)
    if byte == 32 or byte == 9 then
      position = position + 1
    end
  end
  return line:sub(position) == "$$"
end

--- Quote levels of a quoted line as md-render reads them -- each a `>` and
--- at most one blank (split_quote_marker); `>    >` is one level and text --
--- and where its text starts.
---@param line string
---@return integer depth
---@return integer text_from
local function quote_levels(line)
  local position, depth = line:find(">", 1, true), 0
  while position and line:byte(position) == 62 do
    depth, position = depth + 1, position + 1
    local byte = line:byte(position)
    if byte == 32 or byte == 9 then
      position = position + 1
    end
  end
  return depth, position or 1
end

--- Up to this many new equations a build asks for in one request: a second
--- pdftex run costs about 45 ms more than one run doing both (Latency L1),
--- and a run of 40 settles in about 100 ms.
local VISIBLE_FIRST_THRESHOLD = 40

--- Entries per generation of a text memo. When `recent` is full it becomes
--- `older`, and what was in `older` and not asked for since is dropped: at
--- most twice this many entries, whatever the notes and however long the
--- session (about 0.5 kB each).
local TEXT_MEMO_LIMIT = 2048

local AUGROUP_NAME = "md-render-math"

local SUBCOMMANDS = { "status", "errors", "retry", "yank" }

--- Why no plain block is drawn below a line (`:MdRenderMath errors`, `status`).
local BLOCKS_LEFT_MESSAGE = "TeX on a `$$` line: the blocks below it are left to md-render"

local is_set_up = false

---@class MdRenderMathDocument
---@field builder table the ContentBuilder rendering it
---@field lines string[] the lines render_document was given, ```math fences rewritten
---@field block_opening? table<integer, integer> line inside a plain `$$` block -> its opening
---@field block_closing? table<integer, integer> a plain block's opening -> its closing
---@field quoted_fences? table<integer, integer> a rewritten quoted ```math fence's opening -> its closing
---@field quote_breaks? table<integer, boolean> quoted lines md-render does not read as rows of the quote before (`blocks_as_md_render_reads_them`)
---@field quoted_closing? table<integer, integer> a quoted block's opening `> $$` -> its closing; made when first needed
---@field line_offset integer source line of `lines[1]`, minus one
---@field max_width integer render_document's `max_width`
---@field base_indent string render_document's `indent`
---@field inline_width? integer width of the line add_markdown_line is wrapping
---@field skipped_from integer the block shown last: its picture or text stands for
---@field skipped_up_to integer the source lines after `skipped_from` up to this one
---@field skipped_prefix? string a quoted block's row prefix; nil for a plain block
---@field as_written_from integer the block left to md-render last: the source lines
---@field as_written_up_to integer after `as_written_from` up to this one
---@field is_emitting? boolean add_line calls are this module's own rows
---@field line_text? string the line add_markdown_line adds, until markdown.render has it
---@field text_items? { text: string, tex: string }[] its text items, in order
---@field text_item? integer the next of them to find in a row
---@field text_offset? integer bytes of it found so far
---@field row_pictures? table<string, string> picture group -> its cells, of the text whose rows add_line is given: the line add_markdown_line adds, or what md-render adds rows of itself since the last such line

---@class MdRenderMathPending
---@field keys string[] in the order the equations were met
---@field equations table<string, MdRenderMathEquation> by key
---@field lines table<string, integer> source line of each

---@class MdRenderMathFailure
---@field line integer source line
---@field equation MdRenderMathEquation

---@class MdRenderMathBuild
---@field is_picture_mode boolean
---@field look? MdRenderMathLook
---@field look_key? string `look` as the end of an equation key
---@field foreground? string "RRGGBB" the pictures are tinted in
---@field pending MdRenderMathPending equations without a picture yet
---@field failures? MdRenderMathFailure[] equations that did not compile
---@field blocks? table<integer, string> view line (0-based) -> TeX of the block shown on it
---@field texts? table<integer, { col: integer, end_col: integer, tex: string }[]> view line (0-based) -> inline text pieces on it
---@field document? MdRenderMathDocument the document being rendered
---@field blocks_left_from? integer source line of a `$$` line with TeX from which plain blocks are left to md-render

--- The build in progress; nil outside one, and with `vim.g.md_render_math`
--- "off".
---@type MdRenderMathBuild?
local build

--- Equation keys asked of md_render_math_tex and not settled yet.
---@type table<string, boolean>
local requested = {}

--- Equation keys that settled and still have no picture to show: not asked
--- for again until `:MdRenderMath retry`, so a misbehaving maker cannot make
--- the views rebuild for ever. Made and failed ones are not kept here:
--- `tex.lookup` answers for them.
---@type table<string, boolean>
local settled = {}

--- Picture highlight group -> the TeX it shows. md_render_math_kitty reuses
--- the groups of released pictures, so this is as large as the most pictures
--- alive at once; a reused group is given its new TeX by `cells_of`.
---@type table<string, string>
local picture_groups = {}

--- Paths of pictures whose file went missing and that were asked for again.
--- Missing once more after that: text until `:MdRenderMath retry`.
---@type table<string, boolean>
local remade = {}

--- The last Insert-mode build of a view, if it found pictures missing, by
--- the `opts` table of the view (preview.lua:238): asked for on leaving it.
---@type table<table, MdRenderMathBuild>
local owed = setmetatable({}, { __mode = "k" })

--- The look of the last picture build; the same table while the cell size
--- stays, so that what md_render_math_tex derives from it can be kept.
---@type MdRenderMathLook?
local current_look
local current_look_key

--- Foreground of the last build that showed pictures; nil when the last
--- build showed none (text, "off", no terminal support).
---@type string?
local last_picture_foreground

--- View buffers whose last apply showed pictures: under "off" they are told
--- once that they show none any more.
---@type table<integer, boolean>
local buffers_with_pictures = {}

--- Source lines read to find a document's blocks, ever: by the pre-pass and
--- the pairing of `> $$` lines. What the spec counts to show that a build
--- reads each line a bounded number of times (an unclosed `$$` once cost a
--- rescan per line).
local lines_read_for_blocks = 0

---@return integer
function M._lines_read_for_blocks()
  return lines_read_for_blocks
end

local is_refresh_queued = false
--- The next refresh rebuilds every view, not only those waiting.
local is_full_refresh_queued = false
--- Keys settled since the last refresh.
---@type table<string, boolean>?
local refresh_keys

-- -----------------------------------------------------------------------------
-- Sibling modules, required when first used
-- -----------------------------------------------------------------------------

local function tex_module()
  return require("andrew.utils.md_render_math_tex")
end

local function kitty_module()
  return require("andrew.utils.md_render_math_kitty")
end

local function text_module()
  return require("andrew.utils.md_render_math_text")
end

-- -----------------------------------------------------------------------------
-- Which `$` delimit inline math
-- -----------------------------------------------------------------------------

---@class MdRenderMathSpan
---@field first integer byte of the opening `$`
---@field last integer byte of the closing `$`
---@field tex string
---@field is_display boolean `$$tex$$` on one line

local DOLLAR, BACKTICK, DIGIT_ZERO, DIGIT_NINE = 36, 96, 48, 57

---@param code string
---@return string
local function masked_code(code)
  return string.rep("\1", #code)
end

--- The `$` pairs of a line by md-render's rule with pandoc's added: a
--- closing `$` followed by a digit does not close (`US$3 or US$4`).
---@param text string
---@param scanned string `text` with code spans and escapes masked, byte for byte
---@return MdRenderMathSpan[] spans
---@return boolean is_digit_refused a pair md-render would make was refused
local function scan_dollars(text, scanned)
  local spans = {}
  local is_digit_refused = false
  local position = scanned:find("[$`]")
  while position do
    if scanned:byte(position) == BACKTICK then
      -- An unmatched backtick: md-render sees code from here on.
      break
    end
    local resume = position + 1
    if scanned:byte(position + 1) == DOLLAR then
      local close = scanned:find("$$", position + 2, true)
      local tex = close and text:sub(position + 2, close - 1)
      if tex and tex:find("%S") then
        spans[#spans + 1] =
          { first = position, last = close + 1, tex = vim.trim(tex), is_display = true }
        resume = close + 2
      end
    else
      local close = scanned:find("$", position + 1, true)
      local tex = close and close > position + 1 and text:sub(position + 1, close - 1)
      if tex and not tex:find("^%s") and not tex:find("%s$") then
        local after = scanned:byte(close + 1)
        if after and after >= DIGIT_ZERO and after <= DIGIT_NINE then
          is_digit_refused = true
        else
          spans[#spans + 1] = { first = position, last = close, tex = tex, is_display = false }
          resume = close + 1
        end
      end
    end
    position = scanned:find("[$`]", resume)
  end
  return spans, is_digit_refused
end

--- The `$` md-render must see escaped to pair exactly `spans`. Its own rule
--- is walked pair by pair; where it pairs what `spans` does not, the opener
--- is escaped and the walk goes back only as far as that can change: to the
--- third `$` before it that is not escaped -- one whose closing `$` it was,
--- one that took it as the second `$` of `$$`, and a `$$` that failed on
--- blank TeX up to the `$$` it ended. The `$` are a linked list that an
--- escape takes one out of, so a line costs about one pass however many
--- pairs are refused.
---@param text string
---@param scanned string
---@param spans MdRenderMathSpan[]
---@return integer[] escapes
local function md_render_escapes(text, scanned, spans)
  -- Past an unmatched backtick md-render sees code (the matched ones are
  -- masked): no `$` there opens, though one may close.
  local stop = scanned:find("`", 1, true) or #scanned + 1
  local at, after, before = {}, {}, {}
  local position = scanned:find("$", 1, true)
  while position do
    at[#at + 1] = position
    position = scanned:find("$", position + 1, true)
  end
  for index = 1, #at do
    after[index], before[index] = index < #at and index + 1 or nil, index > 1 and index - 1 or nil
  end

  --- md-render's first pair from the `$` numbered `index` on: the numbers of
  --- its opening and closing `$` (the second of a closing `$$`).
  ---@param index integer
  ---@param came_from integer the byte the walk was at before
  ---@return integer? opening
  ---@return integer? closing
  local function pair_from(index, came_from)
    while index do
      local opening_at, next_index = at[index], after[index]
      if came_from < stop and opening_at > stop then
        return nil
      end
      if next_index and at[next_index] == opening_at + 1 then
        local close = after[next_index]
        while close and not (after[close] and at[after[close]] == at[close] + 1) do
          close = after[close]
        end
        if close and text:sub(opening_at + 2, at[close] - 1):find("%S") then
          return index, after[close]
        end
      elseif next_index then
        local tex = text:sub(opening_at + 1, at[next_index] - 1)
        if tex ~= "" and not tex:find("^%s") and not tex:find("%s$") then
          return index, next_index
        end
      end
      index, came_from = next_index, opening_at
    end
  end

  local escapes = {}
  -- `agreed`: md-render pairs as `spans` do before the `$` of this number.
  local span_index, from, agreed = 1, (#at > 0) and 1 or nil, 1
  local came_from = 0
  while from do
    local opening, closing = pair_from(from, came_from)
    if not opening then
      break
    end
    local span = spans[span_index]
    if span and span.first == at[opening] and span.last == at[closing] then
      span_index, from, came_from = span_index + 1, after[closing], at[closing]
      agreed = from or agreed
    else
      escapes[#escapes + 1] = at[opening]
      local resume, resume_from = after[opening], at[opening]
      local back = before[opening]
      for _ = 1, 3 do
        if not back or back < agreed then
          break
        end
        resume, resume_from, back = back, at[back] - 1, before[back]
      end
      -- Out of the list.
      if before[opening] then
        after[before[opening]] = after[opening]
      end
      if after[opening] then
        before[after[opening]] = before[opening]
      end
      if agreed == opening then
        agreed = after[opening] or agreed
      end
      from, came_from = resume, resume_from
    end
  end
  table.sort(escapes)
  return escapes
end

--- Bytes `from`..`to` of `text` into `pieces`, with a backslash before each
--- escaped `$` among them.
---@param pieces string[]
---@param text string
---@param from integer
---@param to integer
---@param escapes integer[]?
---@param next_escape integer index of the first escape not copied yet
---@return integer next_escape
local function copy_escaped(pieces, text, from, to, escapes, next_escape)
  while escapes and escapes[next_escape] and escapes[next_escape] <= to do
    local at = escapes[next_escape]
    pieces[#pieces + 1] = text:sub(from, at - 1)
    pieces[#pieces + 1] = "\\"
    from = at
    next_escape = next_escape + 1
  end
  pieces[#pieces + 1] = text:sub(from, to)
  return next_escape
end

--- markdown.render as `wrap_markdown_render` found it, and md-render's math
--- pass as it ran while a line was checked: the text the pass was given --
--- what its other inline passes left -- and the bytes there of the two `$`
--- of each pair it made. Watched through `process_inline_math`, an upvalue
--- of md-render's markdown.render (markdown.lua:1311, 1643);
--- `is_math_pass_watched` false where md-render no longer has it.
---@class MdRenderMathPass
---@field text string?
---@field openings integer[]
---@field closings integer[]

---@type (fun(text: string, ...): ...)?
local upstream_markdown_render
local is_math_pass_watched = false
---@type MdRenderMathPass?
local math_pass

--- Puts a watch on md-render's math pass. It is an upvalue of md-render's
--- markdown.render, which `render` is or holds: other modules wrap it first
--- (md_render_headings.lua:69). While `math_pass` is set, the pass notes
--- what it was given and paired: it takes each pair's two `$` out and gives
--- the TeX's highlight its place in what is left, so the k-th pair's `$`
--- were 2(k-1) bytes further on.
---@param render function
local function watch_math_pass(render)
  local functions, seen = { render }, { [render] = true }
  -- md-render's own function and two wrappers around it at most.
  for _ = 1, 3 do
    local held = {}
    for _, holder in ipairs(functions) do
      for index = 1, math.huge do
        local name, value = debug.getupvalue(holder, index)
        if name == nil then
          break
        end
        if name == "process_inline_math" and type(value) == "function" then
          debug.setupvalue(holder, index, function(text, group, highlights, links)
            local watching = math_pass
            if not watching then
              return value(text, group, highlights, links)
            end
            local before = #highlights
            local processed = value(text, group, highlights, links)
            watching.text, watching.openings, watching.closings = text, {}, {}
            for pair = before + 1, #highlights do
              local removed = 2 * (pair - before - 1)
              watching.openings[#watching.openings + 1] = highlights[pair].col + removed + 1
              watching.closings[#watching.closings + 1] = highlights[pair].end_col + removed + 2
            end
            return processed
          end)
          is_math_pass_watched = true
          return
        end
        if type(value) == "function" and not seen[value] then
          seen[value] = true
          held[#held + 1] = value
        end
      end
    end
    functions = held
  end
end

--- What may make md-render's math pass see other `$`, or other bytes next
--- to them, than the line has: md-render takes away `\r`, `%%` and HTML
--- comments, HTML tags, link targets and labels, the tails of long URLs,
--- and the markers of emphasis, highlights and strike-through
--- (markdown.lua:1487, 1596-1642). Markers count only right next to a `$`.
--- And a `$$tex$$` with a `$` in it or after it: md-render reads `$$` as a
--- literal `$` and pairs from the next one on, so the closing `$$`'s second
--- `$` may open for it.
local RESHAPED = { "\r", "%%", "](", "[[", "[^", "://" }

--- `*`, `_`, `=`, `~`.
local IS_MARKER = { [42] = true, [95] = true, [61] = true, [126] = true }

---@param text string
---@param scanned string
---@param spans MdRenderMathSpan[]
---@param ref_links table? md-render's reference definitions
---@return boolean
local function may_pair_otherwise(text, scanned, spans, ref_links)
  -- Plain searches and bytes: a pattern with a class is many times slower.
  for _, needle in ipairs(RESHAPED) do
    if text:find(needle, 1, true) then
      return true
    end
  end
  local position = text:find("<", 1, true)
  while position do
    local after = text:byte(position + 1)
    -- A tag or a comment: `<` and a letter, `/` or `!`.
    if
      after == 33
      or after == 47
      or (after and (after > 64 and after < 91 or after > 96 and after < 123))
    then
      return true
    end
    position = text:find("<", position + 1, true)
  end
  if ref_links ~= nil and next(ref_links) ~= nil and text:find("[", 1, true) then
    return true
  end
  for _, span in ipairs(spans) do
    if
      span.is_display
      and (
        scanned:find("$", span.first + 2, true) ~= span.last - 1
        or scanned:find("$", span.last + 1, true)
      )
    then
      return true
    end
  end
  position = scanned:find("$", 1, true)
  while position do
    if IS_MARKER[scanned:byte(position - 1)] or IS_MARKER[scanned:byte(position + 1)] then
      return true
    end
    position = scanned:find("$", position + 1, true)
  end
  return false
end

--- A `%%` or HTML comment md-render takes away before it finds code spans
--- and escapes (markdown.lua:1596-1619) that holds a `$`, a backtick or a
--- backslash, or follows a backslash: code and escapes may fall otherwise
--- than in the line, and a `$` be another one with the same number.
---@param text string
---@return boolean
local function is_comment_in_the_way(text)
  for _, pattern in ipairs({ "%%%%.-%%%%", "<!%-%-.-%-*%-%->" }) do
    for at, comment in text:gmatch("()(" .. pattern .. ")") do
      if comment:find("[$`\\]") or text:byte(at - 1) == 92 then
        return true
      end
    end
    text = text:gsub(pattern, "")
  end
  return false
end

--- What md-render's math pass is given for `text` with a backslash before
--- each `$` of `escapes`, asked with md-render's other arguments.
---@param text string
---@param escapes integer[]?
---@return MdRenderMathPass
local function math_pass_of(text, escapes, ...)
  local md_render_text = text
  if escapes then
    local pieces = {}
    copy_escaped(pieces, text, 1, #text, escapes, 1)
    md_render_text = table.concat(pieces)
  end
  local pass = { openings = {}, closings = {} }
  math_pass = pass
  upstream_markdown_render(md_render_text, ...)
  math_pass = nil
  return pass
end

--- Where md-render took `$` away -- in a link's target, a comment, a tag
--- (markdown.lua:1596-1631) --, which: it is asked once more with a mark of
--- its own in place of each `$` (U+100000 on), which the passes that take
--- text away take or leave as they would the `$`. The rank, among the `$`
--- its math pass is given, of each `$` of `text` that is given; nil where
--- the marks do not tell.
---@param text string
---@param dollars integer[] bytes of the `$` md-render can pair, ascending
---@param escapes integer[]?
---@param given_count integer `$` the math pass was given
---@return table<integer, integer>?
local function ranks_given(text, dollars, escapes, given_count, ...)
  local pieces, from, next_escape = {}, 1, 1
  for number, position in ipairs(dollars) do
    next_escape = copy_escaped(pieces, text, from, position - 1, escapes, next_escape)
    pieces[#pieces + 1] = "\244"
      .. string.char(
        0x80 + math.floor(number / 4096) % 16,
        0x80 + math.floor(number / 64) % 64,
        0x80 + number % 64
      )
    from = position + 1
  end
  copy_escaped(pieces, text, from, #text, escapes, next_escape)
  local pass = math_pass_of(table.concat(pieces), nil, ...)
  if not pass.text or pass.text:find("$", 1, true) then
    return nil
  end
  local rank, given, last = {}, 0, 0
  for high, middle, low in pass.text:gmatch("\244([\128-\143])([\128-\191])([\128-\191])") do
    local number = (high:byte() - 0x80) * 4096 + (middle:byte() - 0x80) * 64 + low:byte() - 0x80
    if number <= last or not dollars[number] then
      return nil
    end
    given, last = given + 1, number
    rank[dollars[number]] = given
  end
  return given == given_count and rank or nil
end

--- Whether md-render, given `text` with a backslash before each `$` of
--- `escapes` and the rest of its arguments, pairs after all its inline
--- passes exactly the `$` that `spans` pair: md-render is asked. The n-th
--- `$` its math pass is given is the line's n-th, but where it took some
--- away (`ranks_given`); a `$$tex$$` it may pair as `$tex$` or not at all.
--- TeX holding a comment md-render takes away fails too: its picture would
--- show what md-render hides.
---@param text string
---@param scanned string
---@param spans MdRenderMathSpan[]
---@param escapes integer[]?
---@return boolean
local function is_paired_alike(text, scanned, spans, escapes, ...)
  if not is_math_pass_watched or is_comment_in_the_way(text) then
    return false
  end
  local pass = math_pass_of(text, escapes, ...)
  if not pass.text then
    -- A callout's title, given back as written (markdown.lua:1544-1550).
    return true
  end

  local dollars, rank = {}, {}
  local position, next_escape = scanned:find("$", 1, true), 1
  while position do
    if escapes and escapes[next_escape] == position then
      next_escape = next_escape + 1
    else
      dollars[#dollars + 1] = position
      rank[position] = #dollars
    end
    position = scanned:find("$", position + 1, true)
  end
  local ordinal_of, given_count = {}, 0
  position = pass.text:find("$", 1, true)
  while position do
    given_count = given_count + 1
    ordinal_of[position] = given_count
    position = pass.text:find("$", position + 1, true)
  end
  if given_count ~= #dollars then
    rank = ranks_given(text, dollars, escapes, given_count, ...)
    if not rank then
      return false
    end
  end

  local closing_of, may_close, wanted = {}, {}, 0
  for _, span in ipairs(spans) do
    local opening, closing = rank[span.first], rank[span.last]
    if
      not opening
      or not closing
      or span.tex:find("%%", 1, true)
      or span.tex:find("<!--", 1, true)
    then
      return false
    end
    if span.is_display then
      may_close[opening + 1] = closing - 1
    else
      closing_of[opening] = closing
      wanted = wanted + 1
    end
  end
  for index, at in ipairs(pass.openings) do
    local opening, closing = ordinal_of[at], ordinal_of[pass.closings[index]]
    if not opening or not closing then
      return false
    end
    if closing_of[opening] == closing then
      wanted = wanted - 1
    elseif may_close[opening] ~= closing then
      return false
    end
  end
  return wanted == 0
end

--- DUPLICATE OF MD-RENDER'S RULE -- keep in step with markdown.lua:
---   * code spans go first, a backtick to the next one (protect_code_spans,
---     markdown.lua:62);
---   * then backslash escapes of ASCII punctuation, so `\$` is never a
---     delimiter (escape_backslashes, markdown.lua:138);
---   * then `$...$` (process_inline_math, markdown.lua:1311-1349): a `$` that
---     is not followed by `$` opens, the next `$` closes, and the TeX between
---     must be non-empty with no whitespace just inside either dollar; a `$`
---     after an unmatched backtick never opens. A failed opener is a literal
---     `$` and the scan goes on at the next byte.
--- Added here: `$$tex$$` on one line, which md-render shows as `$tex$`, and
--- pandoc's rule that a closing `$` followed by a digit does not close. Where
--- that refuses a pair md-render would make, the opener of every pair
--- md-render would make and this scan does not is returned in `escapes`: with
--- a backslash before each, md-render pairs exactly `spans` (the masked `$`
--- below stands for that `\$`, which md-render masks the same way).
--- md-render's other inline passes run before its math pass and can change
--- what it pairs (`$5 and see **$x$**` is `$5 and see $x$` to it): on a line
--- they may reshape, md-render is asked (`is_paired_alike`), and where it
--- pairs otherwise the line is left to it, as written.
--- Positions are those of `text`; the TeX is cut from `text` verbatim.
---@param text string
---@param ... any md-render's other arguments: `repo_base_url`, `autolinks`,
---   `ref_links`, `footnote_map` (markdown.lua:1486)
---@return MdRenderMathSpan[] spans
---@return integer[]? escapes bytes of `$` md-render must be told are literal, ascending
local function inline_math_spans(text, ...)
  -- Code spans, over the whole line first, as md-render does. Every step
  -- keeps byte positions: what is masked becomes as many \1.
  local scanned = text
  if scanned:find("`", 1, true) then
    scanned = scanned:gsub("`[^`]*`", masked_code)
  end
  -- Then escapes of ASCII punctuation: the 32 characters of
  -- `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~` (not `%p`, which follows the locale).
  if scanned:find("\\", 1, true) then
    scanned = scanned:gsub("\\[!-/:-@[-`{-~]", "\1\1")
  end
  local spans, is_digit_refused = scan_dollars(text, scanned)
  local escapes = is_digit_refused and md_render_escapes(text, scanned, spans) or nil
  if escapes and #escapes == 0 then
    escapes = nil
  end
  if
    (spans[1] or escapes)
    and may_pair_otherwise(text, scanned, spans, (select(3, ...)))
    and not is_paired_alike(text, scanned, spans, escapes, ...)
  then
    return {}
  end
  return spans, escapes
end
-- For the spec's proof against the scanner this one replaced.
M._inline_math_spans = inline_math_spans

-- -----------------------------------------------------------------------------
-- Text of an equation: a pure function of its TeX, kept across builds
-- -----------------------------------------------------------------------------

-- Zed's LineLayoutCache (gpui text_system/line_layout.rs:478-594: a hit in
-- the previous frame moves to the current one), swapped by size rather than
-- per build: two views are two builds, and each would evict the other's.

---@class MdRenderMathMemo
---@field recent table<string, table>
---@field older table<string, table>
---@field size integer entries in `recent`

---@return MdRenderMathMemo
local function new_memo()
  return { recent = {}, older = {}, size = 0 }
end

---@param memo MdRenderMathMemo
---@param key string
---@param value table
local function memo_put(memo, key, value)
  if memo.size >= TEXT_MEMO_LIMIT then
    memo.older, memo.recent, memo.size = memo.recent, {}, 0
  end
  memo.recent[key] = value
  memo.size = memo.size + 1
end

---@param memo MdRenderMathMemo
---@param key string
---@return table?
local function memo_get(memo, key)
  local value = memo.recent[key]
  if value == nil then
    value = memo.older[key]
    if value ~= nil then
      memo_put(memo, key, value)
    end
  end
  return value
end

local inline_text_memo, display_text_memo = new_memo(), new_memo()

---@class MdRenderMathShown
---@field text string what replaces the filler run
---@field group string its highlight
---@field cells integer its width

---@class MdRenderMathBlockShown
---@field rows string[]
---@field group string
---@field cells integer width of the widest row

--- An inline equation as text. Shared between builds: never changed.
---@param tex string
---@return MdRenderMathShown
local function inline_text_of(tex)
  local shown = memo_get(inline_text_memo, tex)
  if not shown then
    local text = text_module().inline(tex)
    shown = { text = text, group = TEXT_HIGHLIGHT, cells = vim.api.nvim_strwidth(text) }
    memo_put(inline_text_memo, tex, shown)
  end
  return shown
end

--- A display equation as rows of text. Shared between builds: never changed.
---@param tex string
---@return MdRenderMathBlockShown
local function display_text_of(tex)
  local shown = memo_get(display_text_memo, tex)
  if not shown then
    local rows = text_module().display(tex)
    local widest = 0
    for _, row in ipairs(rows) do
      widest = math.max(widest, vim.api.nvim_strwidth(row))
    end
    shown = { rows = rows, group = TEXT_HIGHLIGHT, cells = widest }
    memo_put(display_text_memo, tex, shown)
  end
  return shown
end

-- -----------------------------------------------------------------------------
-- Pictures and requests
-- -----------------------------------------------------------------------------

---@param equation MdRenderMathEquation
---@return string
local function key_of(equation)
  return equation.kind .. "\0" .. equation.tex .. assert(build).look_key
end

---@return MdRenderMathPending
local function new_pending()
  return { keys = {}, equations = {}, lines = {} }
end

---@param pending MdRenderMathPending
---@param key string
---@param equation MdRenderMathEquation
---@param source_line integer
local function add_pending(pending, key, equation, source_line)
  if not pending.equations[key] then
    pending.equations[key] = equation
    pending.lines[key] = source_line
    pending.keys[#pending.keys + 1] = key
  end
end

--- Note an equation that did not compile, for `:MdRenderMath errors`.
---@param equation MdRenderMathEquation
---@param source_line integer
local function note_failure(equation, source_line)
  local active_build = assert(build)
  local failures = active_build.failures or {}
  active_build.failures = failures
  failures[#failures + 1] = { line = source_line, equation = equation }
end

--- The picture of an equation, if there is one. One that is not made yet is
--- noted in `pending`, for the request at the end of the build; one that
--- failed is noted too.
---@param equation MdRenderMathEquation
---@param pending MdRenderMathPending
---@param source_line integer
---@return MdRenderMathPicture|false|nil
local function picture_of(equation, pending, source_line)
  local picture = tex_module().lookup(equation, assert(build).look)
  if picture == nil then
    local key = key_of(equation)
    if not settled[key] then
      add_pending(pending, key, equation, source_line)
    end
  elseif picture == false then
    note_failure(equation, source_line)
  end
  return picture
end

--- Placeholder rows of a picture; nil when md_render_math_kitty refuses the
--- box (more than `MAX_CELLS` either way) or cannot read the picture's file,
--- and text is shown instead. A file that is gone (pruned by another
--- session's cache maintenance) is made again, once.
---@param picture MdRenderMathPicture
---@param box? { columns: integer, rows: integer }
---@param shown_tex string the TeX as written, for `M.equation_at`
---@param equation MdRenderMathEquation
---@param pending MdRenderMathPending
---@param source_line integer
---@return string[]? rows
---@return string? group
local function cells_of(picture, box, shown_tex, equation, pending, source_line)
  local active_build = assert(build)
  local rows, group_or_reason = kitty_module().cells(picture, box, active_build.foreground)
  if rows then
    picture_groups[group_or_reason] = shown_tex
    if next(remade) ~= nil then
      remade[picture.path] = nil
    end
    return rows, group_or_reason
  end
  if group_or_reason == "missing" then
    tex_module().forget(equation, active_build.look)
    local key = key_of(equation)
    if remade[picture.path] then
      settled[key] = true
    else
      remade[picture.path] = true
      add_pending(pending, key, equation, source_line)
    end
  end
  return nil
end

---@return boolean
local function is_insert_mode()
  local mode = vim.api.nvim_get_mode().mode
  -- `niI` and friends: one Normal command typed from Insert mode.
  return mode:find("^[iR]") ~= nil or mode:find("^ni") ~= nil
end

--- The session that builds with `opts`, if any. A session's first build runs
--- in Session.new before it is registered (preview.lua:330, 347).
---@param opts table?
---@return table?
local function session_of(opts)
  if not opts then
    return nil
  end
  for _, session in pairs(require("md-render").preview._sessions) do
    if session.opts == opts then
      return session
    end
  end
end

--- The lines on screen in each of `windows`, through `map` when given.
---@param windows integer[]
---@param map integer[]? view line -> source line
---@return { [1]: integer, [2]: integer }[] ranges first and last line, one per window
local function lines_shown_in(windows, map)
  local ranges = {}
  for _, window in ipairs(windows) do
    local top, bottom = vim.fn.line("w0", window), vim.fn.line("w$", window)
    if map then
      top, bottom = map[top] or map[1], map[bottom] or map[#map]
    end
    ranges[#ranges + 1] = { top, bottom }
  end
  return ranges
end

--- Source lines on screen for the view built with `opts`, a range per
--- window:
---   1. windows showing the view (`session.buf`): their first and last
---      lines, through the `source_line_map` of the content they show (the
---      one being built is not applied yet; content_builder.lua:59, 112);
---   2. no window shows it (a first build, from Session.new, or a hidden
---      view): windows showing its source (`session.source_bufnr`) -- for a
---      first build the current window, which md-render's commands open the
---      view from, unless that is a view itself (`vim.b.md_render`, set on
---      each view buffer, preview.lua:298);
---   3. neither: the top of the note.
--- Two windows far apart on one note are two ranges, not all between.
---@param opts table?
---@return { [1]: integer, [2]: integer }[] ranges
local function visible_source_ranges(opts)
  local session = session_of(opts)
  local map = session and session.content and session.content.source_line_map
  local ranges = {}
  if session and map and #map > 0 then
    ranges = lines_shown_in(vim.fn.win_findbuf(session.buf), map)
  end
  if #ranges == 0 then
    local windows
    if session then
      windows = vim.fn.win_findbuf(session.source_bufnr)
    else
      local current = vim.api.nvim_get_current_win()
      windows = not vim.b[vim.api.nvim_win_get_buf(current)].md_render and { current } or {}
    end
    ranges = lines_shown_in(windows)
  end
  if #ranges == 0 then
    ranges[1] = { 1, vim.o.lines }
  end
  return ranges
end

---@param waiting table<string, any> keys a view's content waits for
---@param keys table<string, boolean>
---@return boolean
local function is_waiting_for(waiting, keys)
  for key in pairs(keys) do
    if waiting[key] then
      return true
    end
  end
  return false
end

--- Rebuild the views waiting for `refresh_keys` (every view after a full
--- refresh request), as `preview.rebuild_visible()` rebuilds one
--- (preview.lua:263-273); a hidden one is marked `dirty` instead. Once per
--- turn of the event loop however often it is asked. One view that fails to
--- rebuild does not keep the others waiting; the first failure is reported.
local function run_refresh()
  is_refresh_queued = false
  local keys, is_full = refresh_keys, is_full_refresh_queued
  refresh_keys, is_full_refresh_queued = nil, false
  local failure
  for view_bufnr, session in pairs(require("md-render").preview._sessions) do
    local waiting = session.content and session.content.math_pending
    if
      vim.api.nvim_buf_is_valid(view_bufnr)
      and (is_full or (waiting and is_waiting_for(waiting, keys)))
    then
      if #vim.fn.win_findbuf(view_bufnr) == 0 then
        session.dirty = true
      else
        local is_rebuilt, message = pcall(function()
          session:rebuild()
          session:refresh_images()
        end)
        failure = failure or (not is_rebuilt and message) or nil
      end
    end
  end
  if failure then
    vim.notify(
      "md-render math: a view could not be rebuilt: " .. tostring(failure),
      vim.log.levels.ERROR
    )
  end
end

local function queue_refresh()
  if not is_refresh_queued then
    is_refresh_queued = true
    vim.schedule(run_refresh)
  end
end

--- Rebuild the views that wait for one of `keys`, mark those hidden dirty.
---@param keys string[]
local function refresh_views_waiting_for(keys)
  refresh_keys = refresh_keys or {}
  for _, key in ipairs(keys) do
    refresh_keys[key] = true
  end
  queue_refresh()
end

--- Rebuild every view on screen, and have every hidden one rebuilt when it is
--- shown again: what every build decides (mode, look, colour) changed.
local function refresh_all_views()
  is_full_refresh_queued = true
  queue_refresh()
end

--- One request; its keys settle together.
---@param keys string[]
---@param pending MdRenderMathPending
---@param look MdRenderMathLook
local function request_pictures(keys, pending, look)
  if #keys == 0 then
    return
  end
  local equations = {}
  for index, key in ipairs(keys) do
    requested[key] = true
    equations[index] = pending.equations[key]
  end
  local function on_settled()
    local tex = tex_module()
    for index, key in ipairs(keys) do
      requested[key] = nil
      if tex.lookup(equations[index], look) == nil then
        settled[key] = true
      end
    end
    refresh_views_waiting_for(keys)
  end
  local is_requested, failure = pcall(tex_module().request, equations, look, on_settled)
  if not is_requested then
    for _, key in ipairs(keys) do
      requested[key] = nil
      settled[key] = true
    end
    vim.notify(
      "md-render math: pictures could not be requested: " .. tostring(failure),
      vim.log.levels.ERROR
    )
  end
end

--- Ask for the pictures a build found missing, except those already asked
--- for, in the order the build met them -- the view's order, top to bottom
--- (footnotes, which md-render shows last, come last). More than
--- VISIBLE_FIRST_THRESHOLD: those on or within a screen of what a window on
--- the view shows go first, as a request of their own (requests are served
--- in arrival order, and each settles by itself), so the screen does not
--- wait for the rest of the note.
---@param pending MdRenderMathPending
---@param look MdRenderMathLook
---@param opts table? the build's options, which name its view
local function request_missing_pictures(pending, look, opts)
  local keys, lines = {}, pending.lines
  for _, key in ipairs(pending.keys) do
    if not requested[key] and not settled[key] then
      keys[#keys + 1] = key
    end
  end
  if #keys <= VISIBLE_FIRST_THRESHOLD then
    request_pictures(keys, pending, look)
    return
  end
  -- Each window's lines and a screen of its height above and below.
  local near_from, near_to = {}, {}
  for index, range in ipairs(visible_source_ranges(opts)) do
    local margin = range[2] - range[1] + 1
    near_from[index], near_to[index] = range[1] - margin, range[2] + margin
  end
  local near, far = {}, {}
  for _, key in ipairs(keys) do
    local line, group = lines[key], far
    for index = 1, #near_from do
      if line >= near_from[index] and line <= near_to[index] then
        group = near
        break
      end
    end
    group[#group + 1] = key
  end
  request_pictures(near, pending, look)
  request_pictures(far, pending, look)
end

-- -----------------------------------------------------------------------------
-- One build
-- -----------------------------------------------------------------------------

--- "RRGGBB" of a highlight group's foreground, links followed.
---@param name string
---@return string?
local function foreground_of(name)
  local highlight = vim.api.nvim_get_hl(0, { name = name, link = false })
  return highlight.fg and string.format("%06X", highlight.fg) or nil
end

--- The colour pictures are tinted in. md-render defines its groups before a
--- view's FIRST build only (preview.lua:326); after a colour scheme cleared
--- them they are defined again here, or every picture would be tinted in
--- Normal's colour.
---@return string
local function picture_foreground()
  if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = TEXT_HIGHLIGHT })) then
    require("md-render").setup_highlights()
  end
  -- What snacks.nvim colours the same pictures with in the source.
  return foreground_of(TEXT_HIGHLIGHT)
    or foreground_of("Normal")
    or (vim.o.background == "light" and "000000" or "FFFFFF")
end

--- What this build shows equations as. nil: nothing, md-render has them.
---@return MdRenderMathBuild?
local function new_build()
  local setting = vim.g.md_render_math
  last_picture_foreground = nil
  if setting == "off" then
    return nil
  end
  local new = { is_picture_mode = false, pending = new_pending() }
  if setting == "text" then
    return new
  end
  local kitty, tex = kitty_module(), tex_module()
  if not (kitty.is_supported() and tex.is_available()) then
    return new
  end
  local cell_width, cell_height = kitty.cell_size()
  if not (cell_width and cell_height) then
    return new
  end
  if
    not current_look
    or current_look.cell_width ~= cell_width
    or current_look.cell_height ~= cell_height
  then
    current_look = { cell_width = cell_width, cell_height = cell_height }
    current_look_key = ("\0%dx%d"):format(cell_width, cell_height)
  end
  new.is_picture_mode = true
  new.look, new.look_key = current_look, current_look_key
  new.foreground = picture_foreground()
  last_picture_foreground = new.foreground
  return new
end

--- After a build: leave on its content what `:MdRenderMath`, `equation_at`
--- and the settle need, and ask for what is missing -- on leaving Insert mode
--- if the build was made in it: the equation being typed would cost a pdftex
--- run and a cache file per pause in typing. Its text shows meanwhile.
---@param this_build MdRenderMathBuild
---@param content table
---@param opts table?
local function finish_build(this_build, content, opts)
  if this_build.failures then
    content.math_failures = { look = this_build.look, entries = this_build.failures }
  end
  content.math_blocks, content.math_texts = this_build.blocks, this_build.texts
  content.math_blocks_left_from = this_build.blocks_left_from
  local pending = this_build.pending
  local has_pending = #pending.keys > 0
  if has_pending then
    content.math_pending = pending.equations
  end
  local is_owed = has_pending and is_insert_mode()
  if opts then
    owed[opts] = is_owed and this_build or nil
  end
  if has_pending and not is_owed then
    request_missing_pictures(pending, this_build.look, opts)
  end
end

local function wrap_build_content()
  local preview = require("md-render").preview
  local upstream_build_content = preview.build_content

  preview.build_content = function(lines, opts)
    if build then
      return upstream_build_content(lines, opts)
    end
    build = new_build()
    if not build then
      return upstream_build_content(lines, opts)
    end
    local this_build = build
    local is_built, content = pcall(upstream_build_content, lines, opts)
    build = nil
    if not is_built then
      error(content, 0)
    end
    finish_build(this_build, content, opts)
    return content
  end
end

-- -----------------------------------------------------------------------------
-- Inline: markdown.render
-- -----------------------------------------------------------------------------

--- Whether md-render draws this source line as a scaled heading. Its cells
--- are painted over at another size by OSC 66, so no picture can go there.
---@param text string
---@return boolean
local function is_scaled_heading(text)
  local markers = text:match("^(#+)%s")
  return markers ~= nil and require("md-render.text_size").spec_for(math.min(#markers, 6)) ~= nil
end

--- Cells in front of the wrapped content of a source line: quote bars, the
--- list marker (content_builder.lua add_wrapped_markdown), a heading's icon.
--- Close enough to keep a picture inside its line.
---@param text string
---@return integer
local function marker_width(text)
  local quote_markers = text:match("^[%s>]*") or ""
  local _, quote_count = quote_markers:gsub(">", "")
  local width = 2 * quote_count
  local rest = quote_count > 0 and text:sub(#quote_markers + 1) or text
  local list_marker = rest:match("^(%s*[-*+]%s)") or rest:match("^(%s*%d+[.)]%s)")
  if list_marker then
    width = width + #list_marker
    if rest:sub(#list_marker + 1):match("^%[[xX %-]%]") then
      width = width + 1
    end
  end
  local heading_markers = rest:match("^(#+)%s")
  if heading_markers then
    local markdown = require("md-render.markdown")
    width = width
      + vim.api.nvim_strwidth(markdown.heading_icon_prefix(math.min(#heading_markers, 6)))
  end
  return width
end

--- What an inline equation is shown as; nil to leave it to md-render.
---@param span MdRenderMathSpan
---@param width_limit integer? cells the picture may take
---@param pending MdRenderMathPending? where a missing picture is noted; nil: text, no picture
---@param source_line integer
---@return MdRenderMathShown?
local function inline_shown(span, width_limit, pending, source_line)
  if pending then
    local equation = {
      kind = "inline",
      tex = span.is_display and DISPLAY_STYLE .. span.tex or span.tex,
    }
    local picture = picture_of(equation, pending, source_line)
    if picture == false then
      return nil
    end
    -- Never drawn into a smaller box: Kitty centres a scaled picture in its
    -- box, and the baseline would be off the text's. Too wide is text.
    local fits = picture
      and picture.scale >= MIN_INLINE_PICTURE_SCALE
      and picture.columns <= kitty_module().MAX_CELLS
      and (not width_limit or picture.columns <= width_limit)
    if fits then
      local rows, group = cells_of(picture, nil, span.tex, equation, pending, source_line)
      if rows and group then
        return { text = rows[1], group = group, cells = picture.columns }
      end
    end
  end
  local shown = inline_text_of(span.tex)
  return shown.cells > 0 and shown or nil
end

--- The next run of whole fillers. Searched for as a byte sequence: the bytes
--- of U+00A0 also occur in other characters (`°` is C2 B0, `à` C3 A0).
---@param text string
---@param from integer
---@return integer? first
---@return integer? last
local function find_filler_run(text, from)
  local first = text:find(FILLER, from, true)
  if not first then
    return nil
  end
  local last = first + #FILLER - 1
  while text:sub(last + 1, last + #FILLER) == FILLER do
    last = last + #FILLER
  end
  return first, last
end

--- Whether md-render took filler into a link's target or other text of a
--- link (`$x$` inside a bare URL or autolink).
---@param links table[]
---@return boolean
local function is_filler_in_links(links)
  for _, link in ipairs(links or {}) do
    for _, value in pairs(link) do
      if type(value) == "string" and value:find(FILLER, 1, true) then
        return true
      end
    end
  end
  return false
end

--- Where the filler runs of `shown` ended up in md-render's text, in order.
--- Adjacent equations make one run, which is cut up again. nil when the runs
--- are not exactly the ones put in.
---@param rendered_text string
---@param shown MdRenderMathShown[]
---@return { first: integer, last: integer }[]?
local function filler_positions(rendered_text, shown)
  local positions = {}
  local run_first, run_last = find_filler_run(rendered_text, 1)
  for _, item in ipairs(shown) do
    if not run_first then
      return nil
    end
    local length = item.cells * #FILLER
    if run_last - run_first + 1 < length then
      return nil
    end
    positions[#positions + 1] = { first = run_first, last = run_first + length - 1 }
    run_first = run_first + length
    if run_first > run_last then
      run_first, run_last = find_filler_run(rendered_text, run_last + 1)
    end
  end
  if run_first then
    return nil
  end
  return positions
end

--- Replace bytes `first`..`last` of a rendered line, moving what comes after.
---@param rendered_text string
---@param highlights { col: integer, end_col: integer }[]
---@param links { col_start: integer, col_end: integer }[]
---@param first integer
---@param last integer
---@param replacement string
---@return string
local function splice(rendered_text, highlights, links, first, last, replacement)
  local end_col = last
  local grown_by = #replacement - (last - first + 1)
  for _, highlight in ipairs(highlights) do
    if highlight.col >= end_col then
      highlight.col = highlight.col + grown_by
    end
    if highlight.end_col >= end_col then
      highlight.end_col = highlight.end_col + grown_by
    end
  end
  for _, link in ipairs(links) do
    if link.col_start >= end_col then
      link.col_start = link.col_start + grown_by
    end
    if link.col_end >= end_col then
      link.col_end = link.col_end + grown_by
    end
  end
  return rendered_text:sub(1, first - 1) .. replacement .. rendered_text:sub(last + 1)
end

--- A heading's text as markdown.render takes it (markdown.lua:1487-1495),
--- from the line as written.
---@param text string
---@return string?
local function heading_content_of(text)
  local without_returns = text:gsub("\r", "")
  local leading = without_returns:match("^(%s*)") or ""
  local collapsed = leading .. without_returns:sub(#leading + 1):gsub("  +", " ")
  local _, content = collapsed:match("^(#+)%s+(.+)$")
  return content
end

--- Whether TeX holds a comment: a `%` not escaped (`\%` is a percent sign,
--- `\\%` a line break and then a comment).
---@param tex string
---@return boolean
local function has_tex_comment(tex)
  local position = tex:find("%", 1, true)
  while position do
    if #tex:sub(1, position - 1):match("\\*$") % 2 == 0 then
      return true
    end
    position = tex:find("%", position + 1, true)
  end
  return false
end

local function wrap_markdown_render()
  local markdown = require("md-render.markdown")
  local upstream_render = markdown.render
  upstream_markdown_render = upstream_render
  watch_math_pass(upstream_render)

  --- md-render's render of `md_render_text`, which stands for `text`: a
  --- heading's anchor is made from `text`, and where `text` was escaped the
  --- `$` comes back in link targets too -- md-render restores its
  --- placeholder for an escaped `$` in the text only (escape_backslashes,
  --- restore_backslashes, markdown.lua:138-162).
  local function render_standing_for(text, md_render_text, is_escaped, ...)
    local results = vim.F.pack_len(upstream_render(md_render_text, ...))
    if results[4] == "heading" and results[8] then
      results[8] = heading_content_of(text) or results[8]
    end
    if is_escaped then
      for _, link in ipairs(results[3] or {}) do
        for field, value in pairs(link) do
          if type(value) == "string" and value:find(ESCAPED_DOLLAR, 1, true) then
            link[field] = value:gsub(ESCAPED_DOLLAR, "$")
          end
        end
      end
    end
    return results
  end

  --- The line without pictures or text, escaped where it has to be.
  local function render_as_written(text, escapes, ...)
    if not escapes then
      return upstream_render(text, ...)
    end
    local escaped = {}
    copy_escaped(escaped, text, 1, #text, escapes, 1)
    return vim.F.unpack_len(render_standing_for(text, table.concat(escaped), true, ...))
  end

  markdown.render = function(text, ...)
    local document = build and build.document
    if not document or type(text) ~= "string" or not text:find("$", 1, true) then
      return upstream_render(text, ...)
    end
    local spans, escapes = inline_math_spans(text, ...)
    if escapes and text:find(CALLOUT_TITLE) then
      -- md-render gives a callout's title back as written, before its inline
      -- passes (markdown.lua:1511-1550): nothing pairs there, and nothing
      -- would take the backslash away.
      escapes = nil
    end
    if #spans == 0 and not escapes then
      return upstream_render(text, ...)
    end

    local can_show_picture = build.is_picture_mode and not is_scaled_heading(text)
    local width_limit = document.inline_width
      and math.max(1, document.inline_width - marker_width(text))
    -- A paragraph's lines arrive joined; where each starts is in
    -- `_source_breaks` for exactly this text (content_builder.lua:1787-1793).
    local first_line = document.builder._current_source_line
    local joined = document.builder._source_breaks
    local breaks = joined and joined.text == text and joined.breaks or nil
    local shown, shown_spans, pieces = {}, {}, {}
    -- The pictures this line misses; nil where it shows none. Noted in the
    -- build only if the line is shown with them: a line given back to
    -- md-render as written would never show the pictures asked for.
    local line_pending = can_show_picture and new_pending() or nil
    local copied_up_to, next_escape = 0, 1
    for _, span in ipairs(spans) do
      local source_line = first_line
      if breaks then
        for _, source_break in ipairs(breaks) do
          if source_break.pos <= span.first then
            source_line = source_break.src
          end
        end
      end
      if breaks and has_tex_comment(span.tex) then
        -- The paragraph's lines arrive joined by a space: the comment would
        -- run on over the next source lines. Their breaks come back.
        local tex = span.tex
        local tex_from = span.first + (span.is_display and 2 or 1)
        tex_from = tex_from + #text:sub(tex_from, span.last):match("^%s*")
        for index = #breaks, 1, -1 do
          local at = breaks[index].pos - tex_from
          if at >= 1 and at <= #tex and tex:sub(at, at) == " " then
            tex = tex:sub(1, at - 1) .. "\n" .. tex:sub(at + 1)
          end
        end
        span = { first = span.first, last = span.last, tex = tex, is_display = span.is_display }
      end
      local item = inline_shown(span, width_limit, line_pending, source_line)
      if item then
        next_escape =
          copy_escaped(pieces, text, copied_up_to + 1, span.first - 1, escapes, next_escape)
        pieces[#pieces + 1] = string.rep(FILLER, item.cells)
        copied_up_to = span.last
        shown[#shown + 1] = item
        shown_spans[#shown] = span
      end
    end
    if #shown == 0 then
      return render_as_written(text, escapes, ...)
    end
    copy_escaped(pieces, text, copied_up_to + 1, #text, escapes, next_escape)

    local results = render_standing_for(text, table.concat(pieces), escapes ~= nil, ...)
    local rendered_text, highlights, links = results[1], results[2], results[3]
    local positions = filler_positions(rendered_text, shown)
    if not positions or is_filler_in_links(links) then
      -- md-render did something to the line that is not understood here, or
      -- took the filler into a link target (`$x$` in a URL): it gets the
      -- line as written.
      return render_as_written(text, escapes, ...)
    end
    if line_pending then
      for _, key in ipairs(line_pending.keys) do
        add_pending(build.pending, key, line_pending.equations[key], line_pending.lines[key])
      end
    end
    local is_added_line = document.line_text == text
    if is_added_line or not document.inline_width then
      -- The line add_markdown_line adds, not a piece of it rendered again to
      -- find its source lines (content_builder.lua:812-822); or text whose
      -- rows md-render adds itself (a footnote, a table cell): its pictures,
      -- for the rows add_line is given next.
      local items
      for index, item in ipairs(shown) do
        if item.group ~= TEXT_HIGHLIGHT then
          document.row_pictures = document.row_pictures or {}
          document.row_pictures[item.group] = item.text
        elseif is_added_line then
          items = items or {}
          items[#items + 1] = { text = item.text, tex = shown_spans[index].tex }
        end
      end
      if is_added_line then
        document.line_text = nil
        document.text_items, document.text_item, document.text_offset = items, 1, 0
      end
    end
    -- Right to left: the positions still to do stay valid.
    for index = #shown, 1, -1 do
      local item, position = shown[index], positions[index]
      rendered_text =
        splice(rendered_text, highlights, links, position.first, position.last, item.text)
      highlights[#highlights + 1] = {
        col = position.first - 1,
        end_col = position.first - 1 + #item.text,
        hl = item.group,
      }
    end
    results[1] = rendered_text
    return vim.F.unpack_len(results)
  end
end

-- -----------------------------------------------------------------------------
-- Blocks: ContentBuilder.render_document, add_markdown_line and add_line
-- -----------------------------------------------------------------------------

--- TeX between two delimiter lines, without their indent. A quoted block's
--- lines lose as many quote markers as its opening line has, and no more:
--- a `>` that is TeX (`> 0`, or any `>` in a plain block) stays.
---@param lines string[]
---@param opening integer
---@param closing integer
---@param is_quoted boolean
---@return string
local function tex_between(lines, opening, closing, is_quoted)
  local marker_count = 0
  if is_quoted then
    marker_count = quote_levels(lines[opening])
  end
  local tex_lines = {}
  for index = opening + 1, closing - 1 do
    local line, from = lines[index], 1
    for _ = 1, marker_count do
      local _, marker_end = line:find("^%s*>%s?", from)
      if not marker_end then
        break
      end
      from = marker_end + 1
    end
    tex_lines[#tex_lines + 1] = (line:sub(from):gsub("^%s+", ""))
  end
  return table.concat(tex_lines, "\n")
end

--- The quoted blocks of a document, opening line -> closing line. A run of
--- quoted lines is one quote to md-render (content_builder.lua:1376-1390)
--- unless the pre-pass found a line where it is not (`quote_breaks`: another
--- list item's quote, or no quote row at all). In a run a `> $$` line opens
--- and the next one with as many `>` closes; a line with fewer, or the end
--- of the run, leaves the block unclosed, as md-render shows it. `> $$`
--- lines in a quoted code fence are code. A rewritten ```math fence is the
--- pair it was rewritten as (`quoted_fences`): a `> $$` written before it
--- is unclosed, and none pairs with its lines. And as for plain blocks (the
--- pre-pass): from a `$$` line the writer meant as a delimiter that is none
--- (`> $$ (1)`, `> $$ ` and blanks, `> tex $$` in a block, a `> $$` closing a
--- `> $$ tex`), the rest of the run is left as md-render shows it.
---@param lines string[]
---@param quoted_fences table<integer, integer>? a rewritten quoted fence's opening -> its closing
---@param quote_breaks table<integer, boolean>? quoted line -> whether it is a quote row (of a new quote)
---@return table<integer, integer>
local function quoted_blocks(lines, quoted_fences, quote_breaks)
  local fence = require("md-render.fence")
  local closing_of = {}
  local opening, opening_depth, open_fence, open_fence_depth = nil, 0, nil, 0
  local is_poisoned, is_opened_with_tex = false, false
  -- The lines of a rewritten fence, up to its closing, are its TeX.
  local fence_up_to = 0
  for index, line in ipairs(lines) do
    local byte = line:byte(1)
    -- A quoted line: `^%s*>`, looked for only where it can match.
    local is_quoted = byte == 62 or (byte and byte <= 32 and line:find("^%s*>") ~= nil)
    local quote_break = quote_breaks and quote_breaks[index]
    if not is_quoted or quote_break ~= nil then
      opening, open_fence, is_poisoned, is_opened_with_tex = nil, nil, false, false
      is_quoted = is_quoted and quote_break ~= false
    end
    -- Not a quote row, or TeX of a rewritten fence: nothing to pair.
    if is_quoted and index > fence_up_to then
      -- The line as md-render reads it: its quote levels and its text.
      local depth, text_from = quote_levels(line)
      local text = line:sub(text_from)
      if quoted_fences and quoted_fences[index] then
        closing_of[index], fence_up_to, opening = quoted_fences[index], quoted_fences[index], nil
      elseif open_fence and depth >= open_fence_depth then
        -- Closed by a line of its own quote: with more `>` it is code.
        if depth == open_fence_depth and fence.closes(text, open_fence) then
          open_fence = nil
        end
      elseif not is_poisoned then
        -- With fewer `>` than an open fence's: its quote ended, and it.
        open_fence = nil
        if is_quoted_delimiter(line) then
          if is_opened_with_tex then
            is_poisoned = true
          elseif opening and depth == opening_depth then
            closing_of[opening] = index
            opening = nil
          else
            -- A delimiter of another quote: the block before it is unclosed.
            opening, opening_depth = index, depth
          end
        elseif opening and depth < opening_depth then
          -- The inner quote ended: unclosed, as md-render shows it.
          opening = nil
        elseif text:find("$$", 1, true) then
          text = text:gsub("^%s+", "")
          if opening or text:find("^%$%$%s*$") then
            is_poisoned, opening = true, nil
          elseif text:find("^%$%$") and not text:find("$$", 3, true) then
            is_opened_with_tex = true
          else
            is_opened_with_tex = false
          end
        elseif not opening then
          -- Outside a block: a fence (inside one, its lines are TeX).
          open_fence, open_fence_depth = fence.opening(text), depth
          if not text:find("%S") then
            -- A blank line ends the paragraph a `> $$ tex` opened.
            is_opened_with_tex = false
          end
        end
      end
    end
  end
  lines_read_for_blocks = lines_read_for_blocks + #lines
  return closing_of
end

--- What a display equation is shown as; nil to leave it to md-render. A
--- table without `rows` is text too wide for the line, to be wrapped.
---@param tex string
---@param available integer cells the block may take
---@param source_line integer
---@return MdRenderMathBlockShown|MdRenderMathShown|nil
local function block_shown(tex, available, source_line)
  local active_build = assert(build)
  if active_build.is_picture_mode then
    local equation = { kind = "display", tex = tex }
    local picture = picture_of(equation, active_build.pending, source_line)
    if picture == false then
      return nil
    end
    if picture then
      -- Wider than the line, or than Kitty's placeholders reach: drawn into
      -- a smaller box, keeping its proportions, unless that is too small.
      local max_cells = kitty_module().MAX_CELLS
      local largest_columns = math.min(available, max_cells)
      local fit = math.min(1, largest_columns / picture.columns, max_cells / picture.rows)
      if fit * picture.scale >= MIN_DISPLAY_PICTURE_SCALE then
        local box
        if fit < 1 then
          box = {
            columns = math.min(
              largest_columns,
              math.max(1, math.ceil(picture.columns * fit - 1e-9))
            ),
            rows = math.min(max_cells, math.max(1, math.ceil(picture.rows * fit - 1e-9))),
          }
        end
        local rows, group = cells_of(picture, box, tex, equation, active_build.pending, source_line)
        if rows and group then
          return { rows = rows, group = group, cells = box and box.columns or picture.columns }
        end
      end
    end
  end
  local shown = display_text_of(tex)
  if shown.cells == 0 then
    return nil
  end
  if shown.cells <= available then
    return shown
  end
  -- Rows wider than the line would be wrapped by the window into each
  -- other: one line of text instead, which md-render wraps.
  local inline = inline_text_of(tex)
  return inline.cells > 0 and inline or nil
end

--- Columns of a line's leading whitespace, a tab to the next stop of four
--- (expand_leading_tabs, content_builder.lua:1180-1205), and where its text
--- starts.
---@param line string
---@return integer columns
---@return integer text_from
local function leading_columns(line)
  local first = line:byte(1)
  if first ~= 32 and first ~= 9 then
    return 0, 1
  end
  local leading = line:match("^[ \t]*")
  local columns = 0
  for position = 1, #leading do
    columns = leading:byte(position) == 9 and (columns + 4 - columns % 4) or (columns + 1)
  end
  return columns, #leading + 1
end

--- md-render's own (content_builder.lua:950-956).
---@param line string
---@return boolean
local function is_thematic_break(line)
  local stripped = line:gsub("%s", "")
  local first = stripped:sub(1, 1)
  return #stripped >= 3
    and (first == "-" or first == "*" or first == "_")
    and stripped == first:rep(#stripped)
end

--- A non-blank line outside fenced code as strip_container_indent reads it
--- (content_builder.lua:1237-1277): `item_columns`, the content columns of
--- the open list items, innermost last, is brought up to date, and the answer
--- is whether md-render, after taking the innermost column off, sees this
--- line's text at column 0 -- for a quote, whether it reads the markers as a
--- quote of one `>` and at most one space per level (split_quote_marker,
--- content_builder.lua:1155). Only there is a `$$` its delimiter (2557).
--- A quoted line is a row of a quote only up to three columns past the
--- item's content column (1259); quote rows of one item are one quote
--- (`quote_container`, 1305-1306, 1377-1380).
---@param item_columns integer[]
---@param line string
---@param prefix string the quote markers, "" for none
---@return boolean is_at_column
---@return integer text_from where the line's text starts
---@return integer? container a quote row's: its item's content column; nil for any other line
local function read_container(item_columns, line, prefix)
  local columns, text_from = leading_columns(line)
  while #item_columns > 0 and columns < item_columns[#item_columns] do
    item_columns[#item_columns] = nil
  end
  local base = item_columns[#item_columns] or 0
  if prefix ~= "" then
    if columns - base > 3 then
      return false, text_from, nil
    end
    return prefix:sub(text_from):gsub(">%s?", "") == "", text_from, base
  end
  local marker_byte = line:byte(text_from)
  if
    marker_byte == 45
    or marker_byte == 42
    or marker_byte == 43
    or (marker_byte and marker_byte >= DIGIT_ZERO and marker_byte <= DIGIT_NINE)
  then
    -- list_content_column (content_builder.lua:1163-1175).
    local marker, gap = line:match("^([-*+])( +)", text_from)
    if not marker then
      marker, gap = line:match("^(%d+[.)])( +)", text_from)
    end
    if marker and not is_thematic_break(line) then
      item_columns[#item_columns + 1] = columns + #marker + (#gap <= 4 and #gap or 1)
    end
  end
  return columns == base, text_from
end

--- Where md-render reads display blocks, before it reads the lines
--- (render_document, content_builder.lua:1546-1551):
---   * a plain `$$` block, from a line that is `$$` and nothing else at the
---     content column of its list item (`read_container`) to the next such
---     line, outside code fences and `:::note` containers (content_builder.lua:
---     2489-2552, 2557). One column deeper is prose md-render joins into the
---     item, which no block may end at. Recorded as `block_opening` (each
---     line inside -> the opening) and `block_closing` (opening -> closing),
---     the only plain blocks add_line draws.
---   * a ```math fence, rewritten LINE FOR LINE (no line number moves) to
---     `$$` lines -- also inside a callout -- where md-render will then read
---     one block: both lines at their column and no fence or `$$` line
---     between, which would open a fence or end the block; not in a
---     `<details>`; and not TeX that failed. An unquoted fence ends at an
---     unquoted line, a quoted one at a line of its quote's depth or with
---     its quote (content_builder.lua:1376-1390).
---   * the quoted lines md-render does not read as the next row of the quote
---     before them, for `quoted_blocks`: `quote_breaks`, a quote row of
---     another list item's quote -> true, a line indented four or more past
---     its item's content -> false (no quote row at all; `read_container`).
--- A `$$` line with anything else on it is md-render's. Where the writer
--- meant one as a delimiter -- `$$ (1)`, `$$` and blanks, `tex $$` closing
--- an open block, a `$$` closing a `$$ tex` -- md-render pairs the `$$`
--- lines after it otherwise than the note: from there on no plain block is
--- drawn and no ```math fence rewritten. No loop at all for a note without
--- `$$` or `math`.
---@param lines string[]
---@param line_offset integer source line of `lines[1]`, minus one
---@return string[] lines
---@return table<integer, integer>? block_opening
---@return table<integer, integer>? block_closing
---@return table<integer, integer>? quoted_fences a rewritten quoted fence's opening -> its closing
---@return table<integer, boolean>? quote_breaks
---@return integer? left_from source line from which plain blocks are left to md-render
local function blocks_as_md_render_reads_them(lines, line_offset)
  local has_math = false
  for index = 1, #lines do
    local line = lines[index]
    if line:find("$$", 1, true) or line:find("math", 1, true) then
      has_math = true
      break
    end
  end
  if not has_math then
    return lines
  end
  local fence = require("md-render.fence")
  local rewritten, block_opening, block_closing, quoted_fences, quote_breaks
  -- The code fence open, the quote markers of its opening line, and for a
  -- ```math fence the line it opened on.
  local open_fence, fence_prefix, math_line
  -- The opening of the plain `$$` block being read.
  local block_line
  local item_columns = {}
  local is_in_note = false
  -- `<details>` open around the line (content_builder.lua:1935-1965): a
  -- collapsed one hides a `$$` block and may show a code block (a fence
  -- that opens its body), so no ```math fence in one is rewritten.
  local details_depth = 0
  -- The list item whose quote the quoted lines before are rows of.
  local quote_container
  -- A `$$` line the writer meant as a delimiter and md-render does not read
  -- as one (TeX, a tag or blanks on it) was met: which later `$$` opens and
  -- which closes is no longer what the note says. No block after it is drawn.
  local is_poisoned = false
  local is_opened_with_tex = false
  -- The first such line, for `:MdRenderMath errors` and `status`.
  local poisoned_line
  ---@param index integer
  local function poison(index)
    is_poisoned, block_line = true, nil
    poisoned_line = poisoned_line or index
  end

  ---@param opening integer
  ---@param closing integer
  local function add_block(opening, closing)
    block_opening, block_closing = block_opening or {}, block_closing or {}
    block_closing[opening] = closing
    for inside = opening + 1, closing - 1 do
      block_opening[inside] = opening
    end
  end

  --- A ```math fence closes: rewritten if md-render will read one block.
  ---@param index integer
  local function close_math_fence(index)
    if fence_prefix == "" and is_poisoned then
      return
    end
    local columns = vim.list_slice(item_columns)
    local delimiter = fence_prefix .. open_fence.indent .. "$$"
    local is_at_column, _, container = read_container(columns, delimiter, fence_prefix)
    for between = math_line + 1, index - 1 do
      local line = lines[between]
      if line:find("%S") then
        local line_prefix = line:match(QUOTE_PREFIX) or ""
        local _, _, line_container = read_container(columns, line, line_prefix)
        local text = line:sub(#line_prefix + 1)
        if fence.opening(text) or text:find("^%s*%$%$%s*$") then
          return
        end
        if fence_prefix ~= "" and line_container ~= container then
          -- No row of the fence's quote to md-render (another item's quote,
          -- or indented four past it): that quote ends before the closing.
          return
        end
      end
    end
    local is_closing_at_column, _, closing_container =
      read_container(columns, delimiter, fence_prefix)
    if not (is_at_column and is_closing_at_column and closing_container == container) then
      return
    end
    if build and build.is_picture_mode then
      local tex = tex_between(lines, math_line, index, fence_prefix ~= "")
      local equation = { kind = "display", tex = tex }
      if tex_module().lookup(equation, build.look) == false then
        -- As md-render shows failed TeX: a code block.
        note_failure(equation, math_line + 1 + line_offset)
        return
      end
    end
    item_columns = columns
    rewritten = rewritten or vim.list_slice(lines)
    rewritten[math_line], rewritten[index] = delimiter, delimiter
    if fence_prefix == "" then
      add_block(math_line, index)
    else
      quoted_fences = quoted_fences or {}
      quoted_fences[math_line] = index
    end
  end

  for index, line in ipairs(lines) do
    local prefix = line:match("^%s*>[>%s]*")
    local rest = line
    if prefix then
      -- Fences are found in the text after md-render's quote levels.
      rest = line:sub((select(2, quote_levels(line))))
    else
      prefix = ""
      quote_container = nil
    end
    if
      open_fence
      and fence_prefix ~= ""
      and (prefix == "" or quote_levels(prefix) < quote_levels(fence_prefix))
    then
      -- The quote ended, and its fence with it.
      open_fence, math_line = nil, nil
    end
    if open_fence then
      -- An unquoted fence's lines are read whole: a `> ```` in it is code. A
      -- quoted one closes at a line of its own quote: with more `>` it is
      -- code too.
      local is_closing
      if fence_prefix == "" then
        is_closing = fence.closes(line, open_fence)
      else
        is_closing = fence.closes(rest, open_fence)
          and quote_levels(prefix) == quote_levels(fence_prefix)
      end
      if is_closing then
        if math_line then
          close_math_fence(index)
        end
        open_fence, math_line = nil, nil
      end
    elseif not block_line and fence.opening(rest) then
      -- Not read by strip_container_indent: a fence line keeps its indent.
      open_fence, fence_prefix = fence.opening(rest), prefix
      local is_math = open_fence.lang
        and open_fence.lang:lower() == "math"
        and not is_in_note
        and details_depth == 0
      math_line = is_math and index or nil
    elseif line:find("%S") then
      local is_at_column, text_from, container = read_container(item_columns, line, prefix)
      if prefix ~= "" then
        if not container or (quote_container and container ~= quote_container) then
          quote_breaks = quote_breaks or {}
          quote_breaks[index] = container ~= nil
        end
        quote_container = container
      end
      local first_byte = line:byte(text_from)
      if first_byte == 60 and prefix == "" then
        if line:find("^%s*<details") then
          details_depth = details_depth + 1
        elseif details_depth > 0 and line:find("^%s*</details>%s*$") then
          details_depth = details_depth - 1
        end
      end
      if is_at_column and prefix == "" then
        if first_byte == 58 and not block_line then
          -- A `:::note` (content_builder.lua:2489-2552) is quoted prose to
          -- md-render: no `$$` in it is a delimiter.
          local text = line:sub(text_from)
          if is_in_note then
            is_in_note = text ~= ":::"
          else
            is_in_note = text:find("^:::note%f[%s%z]") ~= nil
              or text:find("^:::message%f[%s%z]") ~= nil
          end
        elseif
          first_byte == 36
          and not is_in_note
          and not is_poisoned
          and line:find("^%$%$", text_from)
        then
          if line:find("^%$%$$", text_from) then
            if is_opened_with_tex then
              -- The writer closes a block opened as `$$ tex`; md-render
              -- opens one here. From here on the blocks are its own.
              poison(index)
            elseif block_line then
              add_block(block_line, index)
              block_line = nil
            else
              block_line = index
            end
          elseif line:find("^%$%$%s+$", text_from) then
            -- `$$` and trailing blanks: md-render reads a delimiter or
            -- prose, depending on the lines around it.
            poison(index)
          elseif block_line then
            -- `$$ (1)`: the writer closed the block, md-render did not.
            poison(index)
          elseif not line:find("$$", text_from + 2, true) then
            is_opened_with_tex = true
          end
        elseif (block_line or is_opened_with_tex) and line:find("$$", 1, true) then
          if block_line then
            -- `tex $$` inside an open block: the same.
            poison(index)
          else
            is_opened_with_tex = false
          end
        end
      elseif prefix == "" and line:find("$$", text_from, true) then
        if block_line then
          -- `tex $$`, or a `$$` off its column, inside an open block.
          poison(index)
        elseif is_opened_with_tex then
          is_opened_with_tex = false
        elseif
          not is_in_note
          and line:find("^%$%$%s*$", text_from)
          and leading_columns(line) - (item_columns[#item_columns] or 0) < 4
        then
          -- A `$$` one to three columns past its item's content: prose
          -- md-render joins into the item (four or more: code).
          poison(index)
        end
      end
    elseif prefix == "" then
      -- A blank line ends the paragraph a `$$ tex` opened: display math
      -- spans none, and md-render reads the `$$` lines after it as written.
      is_opened_with_tex = false
    end
  end
  lines_read_for_blocks = lines_read_for_blocks + #lines
  return rewritten or lines,
    block_opening,
    block_closing,
    quoted_fences,
    quote_breaks,
    poisoned_line and poisoned_line + line_offset
end
-- For the spec: only the lines of a ```math fence are ever rewritten.
M._blocks_as_md_render_reads_them = blocks_as_md_render_reads_them

---@param hl_groups table[]?
---@return boolean
local function is_block_math_line(hl_groups)
  local group = hl_groups and #hl_groups == 1 and hl_groups[1]
  return group and group.hl == TEXT_HIGHLIGHT and group.col == 0 and group.end_col == -1 or false
end

--- Highlights of a row prefix (callout bar), cut off where the prefix ends.
---@param hl_groups table[]?
---@param prefix_length integer
---@return table[]
local function prefix_highlights(hl_groups, prefix_length)
  local kept = {}
  for _, group in ipairs(hl_groups or {}) do
    if group.col < prefix_length then
      local copy = vim.deepcopy(group)
      if copy.end_col == -1 or copy.end_col > prefix_length then
        copy.end_col = prefix_length
      end
      kept[#kept + 1] = copy
    end
  end
  return kept
end

--- Note which view lines show a block's TeX, for `M.equation_at`.
---@param from integer first view line (0-based)
---@param to integer last view line (0-based)
---@param tex string
local function note_block_lines(from, to, tex)
  local active_build = assert(build)
  local blocks = active_build.blocks or {}
  active_build.blocks = blocks
  for line = from, to do
    blocks[line] = tex
  end
end

--- Text too wide for the line, wrapped by md-render as a line of text with
--- the block's indent and bar (content_builder.lua:346).
---@param builder table
---@param document MdRenderMathDocument
---@param shown MdRenderMathShown
---@param prefix string
---@param prefix_groups table[]
---@param tex string
local function add_wrapped_text(builder, document, shown, prefix, prefix_groups, tex)
  local indent = prefix:match("^%s*")
  local quote_prefix = prefix:sub(#indent + 1)
  local highlights = {}
  for _, group in ipairs(prefix_groups) do
    highlights[#highlights + 1] = {
      col = math.max(0, group.col - #indent),
      end_col = math.max(0, group.end_col - #indent),
      hl = group.hl,
    }
  end
  highlights[#highlights + 1] =
    { col = #quote_prefix, end_col = #quote_prefix + #shown.text, hl = shown.group }
  local first_line = #builder.lines
  document.is_emitting = true
  local is_added, failure = pcall(
    builder.add_wrapped_markdown,
    builder,
    quote_prefix .. shown.text,
    highlights,
    {},
    indent,
    math.max(1, document.max_width - vim.api.nvim_strwidth(indent)),
    quote_prefix
  )
  document.is_emitting = false
  if not is_added then
    error(failure, 0)
  end
  note_block_lines(first_line, #builder.lines - 1, tex)
end

--- Which bytes of a row md-render made from a line with text items show
--- which item, for `M.equation_at`. The items' pieces come in order; a wrap
--- can split one over two rows and drop the space it breaks at. A piece that
--- is not the next bytes of the next item is md-render's own `MdRenderMath`
--- (raw TeX that failed).
---@param builder table
---@param document MdRenderMathDocument
---@param text string the row
---@param hl_groups table[]
local function note_text_pieces(builder, document, text, hl_groups)
  local pieces
  for _, group in ipairs(hl_groups) do
    if group.hl == TEXT_HIGHLIGHT and group.end_col ~= -1 then
      pieces = pieces or {}
      pieces[#pieces + 1] = group
    end
  end
  if not pieces then
    return
  end
  table.sort(pieces, function(a, b)
    return a.col < b.col
  end)
  local active_build = assert(build)
  for _, piece in ipairs(pieces) do
    local item = document.text_items[document.text_item]
    if not item then
      return
    end
    local piece_text = text:sub(piece.col + 1, piece.end_col)
    local remaining = item.text:sub(document.text_offset + 1)
    local skipped = #remaining:match("^ *")
    if piece_text ~= "" and remaining:sub(skipped + 1, skipped + #piece_text) == piece_text then
      local texts = active_build.texts or {}
      active_build.texts = texts
      local on_line = texts[#builder.lines] or {}
      texts[#builder.lines] = on_line
      on_line[#on_line + 1] = { col = piece.col, end_col = piece.end_col, tex = item.tex }
      document.text_offset = document.text_offset + skipped + #piece_text
      if not item.text:find("%S", document.text_offset + 1) then
        document.text_item, document.text_offset = document.text_item + 1, 0
      end
    end
  end
end

local function wrap_content_builder()
  local ContentBuilder = require("md-render.content_builder").ContentBuilder
  local upstream_render_document = ContentBuilder.render_document
  local upstream_add_markdown_line = ContentBuilder.add_markdown_line
  local upstream_add_line = ContentBuilder.add_line

  ContentBuilder.render_document = function(self, lines, opts)
    if not build or build.document then
      return upstream_render_document(self, lines, opts)
    end
    opts = opts or {}
    local line_offset = opts.source_line_offset or 0
    local block_opening, block_closing, quoted_fences, quote_breaks, left_from
    lines, block_opening, block_closing, quoted_fences, quote_breaks, left_from =
      blocks_as_md_render_reads_them(lines, line_offset)
    local this_build = build
    this_build.blocks_left_from = left_from
    this_build.document = {
      builder = self,
      lines = lines,
      block_opening = block_opening,
      block_closing = block_closing,
      quoted_fences = quoted_fences,
      quote_breaks = quote_breaks,
      line_offset = line_offset,
      max_width = opts.max_width or 80,
      base_indent = opts.indent or "  ",
      skipped_from = 0,
      skipped_up_to = 0,
      as_written_from = 0,
      as_written_up_to = 0,
    }
    local results = vim.F.pack_len(pcall(upstream_render_document, self, lines, opts))
    this_build.document = nil
    if not results[1] then
      error(results[2], 0)
    end
    return unpack(results, 2, results.n)
  end

  ContentBuilder.add_markdown_line = function(self, text, indent, max_width, ...)
    local document = build and build.document
    if not document or document.builder ~= self then
      return upstream_add_markdown_line(self, text, indent, max_width, ...)
    end
    -- The width md-render wraps this line at (content_builder.lua:815).
    local outer_width = document.inline_width
    document.inline_width =
      math.max(1, (max_width or document.max_width) - vim.api.nvim_strwidth(indent or ""))
    -- The line whose text items the next rows show (`note_text_pieces`).
    local outer_text, outer_items = document.line_text, document.text_items
    local outer_item, outer_offset = document.text_item, document.text_offset
    document.line_text, document.text_items, document.row_pictures = text, nil, nil
    local results =
      vim.F.pack_len(pcall(upstream_add_markdown_line, self, text, indent, max_width, ...))
    document.inline_width = outer_width
    document.line_text, document.text_items = outer_text, outer_items
    document.text_item, document.text_offset = outer_item, outer_offset
    -- Its rows are added, and those of what was rendered before it.
    document.row_pictures = nil
    if not results[1] then
      error(results[2], 0)
    end
    return unpack(results, 2, results.n)
  end

  --- Rows of a shown block in place of the line md-render was adding.
  ---@param self table the builder
  ---@param document MdRenderMathDocument
  ---@param shown MdRenderMathBlockShown
  ---@param prefix string indent, and `│ ` in a callout
  ---@param prefix_groups table[] highlights of the prefix
  ---@param tex string
  local function add_block_rows(self, document, shown, prefix, prefix_groups, tex)
    local prefix_width = vim.api.nvim_strwidth(prefix)
    -- md-render centres an image in the line's max_width, which is the
    -- document's less the container indent (content_builder.lua:1803, 3102).
    local container_indent_width = math.max(0, #prefix:match("^%s*") - #document.base_indent)
    local line_width = math.max(1, document.max_width - container_indent_width)
    local col = math.max(prefix_width, math.floor((line_width - shown.cells) / 2))
    local padding = string.rep(" ", col - prefix_width)
    note_block_lines(#self.lines, #self.lines + #shown.rows - 1, tex)
    for _, row in ipairs(shown.rows) do
      local line = prefix .. padding .. row
      local groups = vim.deepcopy(prefix_groups)
      if row ~= "" then
        groups[#groups + 1] = { col = #prefix + #padding, end_col = #line, hl = shown.group }
      end
      upstream_add_line(self, line, #groups > 0 and groups or nil)
    end
  end

  ContentBuilder.add_line = function(self, text, hl_groups)
    local document = build and build.document
    if not document or document.builder ~= self or document.is_emitting then
      return upstream_add_line(self, text, hl_groups)
    end
    if document.row_pictures and hl_groups then
      -- md-render's wrap joins the words of a row by one space (wrap.lua:785)
      -- and places the highlights as if the row were cut out of the line
      -- (content_builder.lua:378-388; its footnotes alike, 3275-3279):
      -- behind two spaces -- a callout's or heading's icon has them, so has
      -- `a * b` once its stars are gone -- every highlight of the row is
      -- late by the bytes dropped. A picture's must cover exactly its cells:
      -- moved back onto the nearest run of them at or before where it was.
      for _, group in ipairs(hl_groups) do
        local cells = document.row_pictures[group.hl]
        if cells and text:sub(group.col + 1, group.end_col) ~= cells then
          local found, first = nil, text:find(cells, 1, true)
          while first and first <= group.col + 1 do
            found, first = first, text:find(cells, first + 1, true)
          end
          if found then
            group.col, group.end_col = found - 1, found - 1 + #cells
          end
        end
      end
    end
    if document.text_items and hl_groups then
      note_text_pieces(self, document, text, hl_groups)
    end
    local source_line = self._current_source_line
    if source_line > document.skipped_from and source_line <= document.skipped_up_to then
      -- Only what md-render emits for the block itself. After its loop it
      -- emits footnotes (and a picker's "... (truncated)") still stamped
      -- with the last source line, which can be the closing `$$`.
      if document.skipped_prefix == nil then
        -- Every row md-render makes from a line inside the block: a TeX
        -- line starting with `|` comes as a table row (content_builder.lua:1898).
        if source_line < document.skipped_up_to or is_block_math_line(hl_groups) then
          return
        end
      elseif vim.startswith(text, document.skipped_prefix) then
        if source_line == document.skipped_up_to then
          -- The closing `> $$`: the block is over.
          document.skipped_up_to = document.skipped_from
        end
        return
      end
    end
    if source_line > document.as_written_from and source_line <= document.as_written_up_to then
      -- The rest of a block left to md-render: decided at its first line.
      return upstream_add_line(self, text, hl_groups)
    end
    local body_line = source_line - document.line_offset
    local source_text = document.lines[body_line]
    if not source_text then
      return upstream_add_line(self, text, hl_groups)
    end
    local is_plain_block_line = is_block_math_line(hl_groups)
    local opening, closing
    if not is_plain_block_line and document.block_opening and document.block_opening[body_line] then
      -- md-render's first row of this block is not a TeX row (a table made
      -- of a TeX line starting with `|`): the whole block is md-render's.
      local block = document.block_opening[body_line]
      document.as_written_from = block + document.line_offset
      document.as_written_up_to = document.block_closing[block] + document.line_offset
      return upstream_add_line(self, text, hl_groups)
    end
    if is_plain_block_line then
      -- A block the pre-pass found where md-render reads one; any other
      -- (`$$  ` md-render takes for a delimiter, say) is md-render's.
      opening = document.block_opening and document.block_opening[body_line]
      if not opening then
        return upstream_add_line(self, text, hl_groups)
      end
      closing = document.block_closing[opening]
    else
      if not (is_quoted_delimiter(source_text) and text:find("│ %$%$%s*$")) then
        return upstream_add_line(self, text, hl_groups)
      end
      -- The row of a `> $$` line: its block's opening, or md-render's. The
      -- `> $$` lines are paired when the first is met, once for the document.
      local quoted_closing = document.quoted_closing
      if not quoted_closing then
        quoted_closing =
          quoted_blocks(document.lines, document.quoted_fences, document.quote_breaks)
        document.quoted_closing = quoted_closing
      end
      opening, closing = body_line, quoted_closing[body_line]
      if not closing then
        return upstream_add_line(self, text, hl_groups)
      end
    end
    local tex = tex_between(document.lines, opening, closing, not is_plain_block_line)

    local prefix, prefix_groups
    if is_plain_block_line then
      -- `text` is the display indent and the TeX line (content_builder.lua:2564).
      local tex_line = source_text:gsub("^%s+", "")
      prefix = vim.endswith(text, tex_line) and text:sub(1, #text - #tex_line) or text:match("^%s*")
      prefix_groups = {}
    else
      -- `text` is `<indent>│ $$` with the bar's highlight. Kept, so that
      -- md-render's callout styling (apply_alert_styling) colours the rows.
      prefix = text:match("^(.-)%$%$%s*$") or text:match("^%s*")
      prefix_groups = prefix_highlights(hl_groups, #prefix)
    end

    local available = math.max(1, document.max_width - vim.api.nvim_strwidth(prefix))
    -- Its TeX starts on the line after the opening (`:MdRenderMath errors`).
    local shown = tex:find("%S") and block_shown(tex, available, opening + 1 + document.line_offset)
    -- Shown or not, the rest of the block is decided. Rows of a quoted block
    -- start with its bar; a plain block's lines are known by their highlight.
    local from, up_to = opening + document.line_offset, closing + document.line_offset
    document.skipped_from, document.skipped_prefix = from, not is_plain_block_line and prefix or nil
    if not shown then
      document.skipped_up_to = from
      document.as_written_from, document.as_written_up_to = from, up_to
      return upstream_add_line(self, text, hl_groups)
    end
    document.skipped_up_to = up_to
    if shown.rows then
      add_block_rows(self, document, shown, prefix, prefix_groups, tex)
    else
      add_wrapped_text(self, document, shown, prefix, prefix_groups, tex)
    end
  end
end

-- -----------------------------------------------------------------------------
-- Picture highlights win; TeX and its text are not spell-checked
-- -----------------------------------------------------------------------------

--- Picture highlights are kept from md-render and applied here instead, once
--- each, above all of its highlights (why: the header), and without spell
--- checking: SpellBad's undercurl colour would replace the `sp` that names
--- the placement. Every `MdRenderMath` range -- text standing in for a
--- picture, raw TeX -- keeps md-render's highlight and gets a second extmark
--- that only turns spell checking off. Under "off" md-render applies the
--- content alone.
local function apply_math_highlights()
  local display_utils = require("md-render.display_utils")
  local upstream_apply_content_to_buffer = display_utils.apply_content_to_buffer

  --- Byte range of a highlight on its line, as md-render clamps it
  --- (display_utils.lua:176-177); nil when it is off the line.
  ---@return integer? col
  ---@return integer? end_col
  local function range_on(content, line, group)
    local line_text = content.lines[line + 1]
    if not line_text or group.col > #line_text then
      return nil
    end
    local end_col = group.end_col
    if end_col == -1 or end_col > #line_text then
      end_col = #line_text
    end
    return group.col, end_col
  end

  --- Tell md_render_math_kitty which pictures `buf` shows now.
  ---@param buf integer
  ---@param shown_groups table<string, true>
  local function mark(buf, shown_groups)
    kitty_module().mark(buf, shown_groups)
    if next(shown_groups) == nil then
      buffers_with_pictures[buf] = nil
    elseif not buffers_with_pictures[buf] then
      for bufnr in pairs(buffers_with_pictures) do
        if not vim.api.nvim_buf_is_valid(bufnr) then
          buffers_with_pictures[bufnr] = nil
        end
      end
      buffers_with_pictures[buf] = true
    end
  end

  display_utils.apply_content_to_buffer = function(buf, ns, content, ...)
    if
      vim.g.md_render_math == "off"
      or type(content) ~= "table"
      or type(content.highlights) ~= "table"
    then
      if not buffers_with_pictures[buf] then
        return upstream_apply_content_to_buffer(buf, ns, content, ...)
      end
      local results = vim.F.pack_len(upstream_apply_content_to_buffer(buf, ns, content, ...))
      mark(buf, {})
      return vim.F.unpack_len(results)
    end
    -- A line's highlights are copied only if a picture highlight has to be
    -- taken out of them.
    local other_highlights, picture_highlights, math_highlights = nil, {}, {}
    local shown_groups = {}
    for line_index, line_highlights in ipairs(content.highlights) do
      local others
      for group_index, group in ipairs(line_highlights.groups) do
        if picture_groups[group.hl] then
          others = others or vim.list_slice(line_highlights.groups, 1, group_index - 1)
          shown_groups[group.hl] = true
          picture_highlights[#picture_highlights + 1] =
            { line = line_highlights.line, group = group }
        else
          if others then
            others[#others + 1] = group
          end
          if group.hl == TEXT_HIGHLIGHT then
            math_highlights[#math_highlights + 1] = { line = line_highlights.line, group = group }
          end
        end
      end
      if others then
        other_highlights = other_highlights or vim.list_slice(content.highlights)
        other_highlights[line_index] = { line = line_highlights.line, groups = others }
      end
    end
    -- The same content to md-render, but for the picture highlights.
    local applied_content = other_highlights
        and setmetatable({ highlights = other_highlights }, { __index = content })
      or content
    local results = vim.F.pack_len(upstream_apply_content_to_buffer(buf, ns, applied_content, ...))
    for _, entry in ipairs(picture_highlights) do
      local col, end_col = range_on(content, entry.line, entry.group)
      if col then
        vim.api.nvim_buf_set_extmark(buf, ns, entry.line, col, {
          end_col = end_col,
          hl_group = entry.group.hl,
          priority = PICTURE_HIGHLIGHT_PRIORITY,
          spell = false,
        })
      end
    end
    for _, entry in ipairs(math_highlights) do
      local col, end_col = range_on(content, entry.line, entry.group)
      if col then
        vim.api.nvim_buf_set_extmark(buf, ns, entry.line, col, { end_col = end_col, spell = false })
      end
    end
    mark(buf, shown_groups)
    return vim.F.unpack_len(results)
  end
end

-- -----------------------------------------------------------------------------
-- The equation under the cursor
-- -----------------------------------------------------------------------------

--- The TeX of the inline equation whose text `shown` is, or is part of, on
--- a source line or another line of its paragraph (md-render joins a
--- paragraph's lines and gives each wrapped row the source line it starts
--- in). For text whose place md-render's rows do not tell (a table cell): an
--- equation whose whole text it is first, else the first containing it.
---@param source_lines string[]
---@param source_line integer
---@param shown string
---@return string?
local function inline_tex_showing(source_lines, source_line, shown)
  local containing
  local function on_line(line_number)
    local text = source_lines[line_number]
    if not text or not text:find("%S") then
      return nil, true
    end
    for _, span in ipairs((inline_math_spans(text))) do
      local span_text = inline_text_of(span.tex).text
      if span_text == shown then
        return span.tex
      end
      if not containing and span_text:find(shown, 1, true) then
        containing = span.tex
      end
    end
    return nil, false
  end
  local tex = on_line(source_line)
  if tex then
    return tex
  end
  for _, step in ipairs({ 1, -1 }) do
    local line_number = source_line + step
    while true do
      local found, is_paragraph_end = on_line(line_number)
      if found then
        return found
      end
      if is_paragraph_end then
        break
      end
      line_number = line_number + step
    end
  end
  return containing
end

--- The TeX of the picture or text shown at a place in a rendered view; nil
--- where there is none (prose, raw TeX md-render shows, another buffer).
---@param bufnr integer a view buffer
---@param line integer 0-based
---@param column integer 0-based byte
---@return string?
function M.equation_at(bufnr, line, column)
  local session = require("md-render").preview._sessions[bufnr]
  local content = session and session.content
  if not content then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    -1,
    { line, column },
    { line, column },
    { details = true, overlap = true }
  )
  local text_mark
  for _, mark in ipairs(marks) do
    local group = mark[4].hl_group
    if group and picture_groups[group] then
      return picture_groups[group]
    end
    if group == TEXT_HIGHLIGHT and (mark[4].end_row or line) == line then
      text_mark = mark
    end
  end
  local block_tex = content.math_blocks and content.math_blocks[line]
  if block_tex then
    return block_tex
  end
  -- Inline text: where md-render's rows put each item (`note_text_pieces`).
  for _, piece in ipairs(content.math_texts and content.math_texts[line] or {}) do
    if column >= piece.col and column < piece.end_col then
      return piece.tex
    end
  end
  local source_line = content.source_line_map and content.source_line_map[line + 1]
  if not (text_mark and source_line and session.source_lines) then
    return nil
  end
  local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
  local shown = line_text:sub(text_mark[3] + 1, text_mark[4].end_col)
  if not shown:find("%S") then
    return nil
  end
  return inline_tex_showing(session.source_lines, source_line, vim.trim(shown))
end

-- -----------------------------------------------------------------------------
-- :MdRenderMath
-- -----------------------------------------------------------------------------

--- The session of a view buffer, or of the note a source buffer shows (a
--- visible one first).
---@param bufnr integer
---@return table?
local function session_for(bufnr)
  local sessions = require("md-render").preview._sessions
  if sessions[bufnr] then
    return sessions[bufnr]
  end
  local found
  for view_bufnr, session in pairs(sessions) do
    if session.source_bufnr == bufnr and vim.api.nvim_buf_is_valid(view_bufnr) then
      if #vim.fn.win_findbuf(view_bufnr) > 0 then
        return session
      end
      found = found or session
    end
  end
  return found
end

--- What builds show equations as now and, as `new_build` decides it, why not
--- pictures, with the reasons the sibling modules give.
local function show_status()
  local kitty, tex_status = kitty_module(), tex_module().status()
  local is_supported, terminal_reason = kitty.is_supported()
  local cell_width, cell_height = kitty.cell_size()
  local terminal = is_supported and "pictures supported"
    or (terminal_reason or "no picture support")
  local tex = tex_status.is_available and "available" or (tex_status.reason or "not available")
  local setting = vim.g.md_render_math
  local mode, reason = "pictures", nil
  if setting == "off" or setting == "text" then
    mode, reason = setting, ('vim.g.md_render_math = "%s"'):format(setting)
  elseif not is_supported then
    mode, reason = "text", "terminal: " .. terminal
  elseif not tex_status.is_available then
    mode, reason = "text", "TeX: " .. tex
  elseif not cell_width then
    mode, reason = "text", "terminal: cell size unknown"
  end
  local in_flight, without_picture = 0, 0
  for _ in pairs(requested) do
    in_flight = in_flight + 1
  end
  for _ in pairs(settled) do
    without_picture = without_picture + 1
  end
  local lines = {
    ("md-render math: %s%s"):format(mode, reason and (" (" .. reason .. ")") or ""),
    ("  terminal: %s"):format(terminal),
    ("  cell size: %s"):format(
      cell_width and ("%dx%d px"):format(cell_width, cell_height) or "unknown"
    ),
    ("  TeX: %s"):format(tex),
  }
  for _, field in ipairs({ "pdftex", "mutool", "format", "preamble", "cache_directory" }) do
    if tex_status[field] then
      lines[#lines + 1] = ("    %s: %s"):format((field:gsub("_", " ")), tex_status[field])
    end
  end
  lines[#lines + 1] = ("  being made: %d; settled without a picture: %d"):format(
    in_flight,
    without_picture
  )
  local session = session_for(vim.api.nvim_get_current_buf())
  local left_from = session and session.content and session.content.math_blocks_left_from
  if left_from then
    lines[#lines + 1] = ("  line %d: %s"):format(left_from, BLOCKS_LEFT_MESSAGE)
  end
  vim.api.nvim_echo({ { table.concat(lines, "\n") } }, true, {})
end

local function list_errors()
  local session = session_for(vim.api.nvim_get_current_buf())
  if not session then
    vim.notify(
      "MdRenderMath errors: no rendered view of this note (:MdRender)",
      vim.log.levels.WARN
    )
    return
  end
  -- The view's last build is what is listed: bring it up to the source first
  -- (a hidden view is only marked `dirty` by an edit, preview.lua:1012-1020).
  if
    vim.api.nvim_buf_is_valid(session.source_bufnr)
    and not vim.deep_equal(
      session.source_lines,
      vim.api.nvim_buf_get_lines(session.source_bufnr, 0, -1, false)
    )
  then
    session:refresh_source()
    session:rebuild()
    session.dirty = false
  end
  local failures = session.content and session.content.math_failures
  local tex = tex_module()
  local items, seen, order = {}, {}, {}
  for _, entry in ipairs(failures and failures.entries or {}) do
    local equation = entry.equation
    local identity = entry.line .. "\0" .. equation.kind .. "\0" .. equation.tex
    if not seen[identity] then
      seen[identity] = true
      local written = equation.tex:gsub("^\\displaystyle ", ""):gsub("%s*\n%s*", " ")
      items[#items + 1] = {
        bufnr = session.source_bufnr,
        lnum = entry.line,
        text = ("%s  |  %s"):format(
          tex.failure_of(equation, failures.look) or "did not compile",
          written
        ),
      }
      order[items[#items]] = #items
    end
  end
  local left_from = session.content and session.content.math_blocks_left_from
  if left_from then
    items[#items + 1] =
      { bufnr = session.source_bufnr, lnum = left_from, text = BLOCKS_LEFT_MESSAGE }
    order[items[#items]] = #items
  end
  if #items == 0 then
    vim.notify("MdRenderMath errors: no equation of this note failed", vim.log.levels.INFO)
    return
  end
  -- In line order, those of one line as met: a failed ```math fence is
  -- noted by the pre-pass, before everything else.
  table.sort(items, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return order[a] < order[b]
  end)
  vim.fn.setqflist({}, " ", { title = "md-render math: failed equations", items = items })
  vim.cmd("copen")
end

local function retry()
  tex_module().retry()
  settled, remade = {}, {}
  refresh_all_views()
  vim.notify("MdRenderMath: failures forgotten, views rebuilt", vim.log.levels.INFO)
end

local function yank()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local tex = M.equation_at(vim.api.nvim_get_current_buf(), cursor[1] - 1, cursor[2])
  if not tex then
    vim.notify("MdRenderMath yank: no equation under the cursor", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg('"', tex)
  vim.notify("MdRenderMath: yanked " .. tex:gsub("%s*\n%s*", " "), vim.log.levels.INFO)
end

local function create_command()
  local actions = { status = show_status, errors = list_errors, retry = retry, yank = yank }
  vim.api.nvim_create_user_command("MdRenderMath", function(command)
    local action = actions[command.fargs[1]]
    if not action then
      vim.notify(
        "MdRenderMath: expected one of " .. table.concat(SUBCOMMANDS, ", "),
        vim.log.levels.ERROR
      )
      return
    end
    action()
  end, {
    nargs = 1,
    desc = "md-render math: " .. table.concat(SUBCOMMANDS, " | "),
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, SUBCOMMANDS)
    end,
  })
end

-- -----------------------------------------------------------------------------
-- Set-up
-- -----------------------------------------------------------------------------

local function create_autocmds()
  local group = vim.api.nvim_create_augroup(AUGROUP_NAME, { clear = true })
  -- What the last Insert-mode build of each view found missing is asked for
  -- without a rebuild. Not for a view md-render rebuilds within 150 ms
  -- anyway (its debounce, preview.lua:1021-1033): that build asks for what
  -- the text is by then, not a half-typed equation.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "*",
    callback = function()
      if next(owed) == nil or is_insert_mode() then
        return
      end
      local entries = owed
      owed = setmetatable({}, { __mode = "k" })
      for opts, entry in pairs(entries) do
        local session = session_of(opts)
        if not (session and session._debounce_timer) then
          request_missing_pictures(entry.pending, entry.look, opts)
        end
      end
    end,
  })
  -- The colour is given to md_render_math_kitty by each build: a new one is
  -- a rebuild, and no TeX. Text takes its colour from its highlight group,
  -- and "off" shows nothing of this module's. Compared once every
  -- `ColorScheme` autocmd has run: this one is made on the first `:MdRender`,
  -- before those of plugins loaded later, which may set the colour.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      vim.schedule(function()
        if last_picture_foreground and picture_foreground() ~= last_picture_foreground then
          refresh_all_views()
        end
      end)
    end,
  })
  -- A font size change in the terminal changes the cell size and arrives as
  -- a resize; md-render rebuilds only when the width changes
  -- (preview.lua:1762-1787).
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not (last_picture_foreground and current_look) then
        return
      end
      local cell_width, cell_height = kitty_module().cell_size()
      if
        cell_width
        and (cell_width ~= current_look.cell_width or cell_height ~= current_look.cell_height)
      then
        refresh_all_views()
      end
    end,
  })
  -- Whether pictures can be shown at all changed: the image id is a 24-bit
  -- foreground, and md_render_math_kitty learns about tmux passthrough late.
  local function refresh_unless_text_or_off()
    local setting = vim.g.md_render_math
    if setting ~= "off" and setting ~= "text" then
      refresh_all_views()
    end
  end
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "termguicolors",
    callback = refresh_unless_text_or_off,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "MdRenderMathTerminal",
    callback = refresh_unless_text_or_off,
  })
end

--- Wrap md-render's builder and renderer. Call once md-render has loaded,
--- before md_render_repaint.setup().
function M.setup()
  if is_set_up then
    return
  end
  is_set_up = true
  tex_module().setup({})
  kitty_module().setup()
  wrap_build_content()
  wrap_markdown_render()
  wrap_content_builder()
  apply_math_highlights()
  create_autocmds()
  create_command()
end

return M
