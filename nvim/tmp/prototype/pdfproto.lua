-- pdfproto.lua -- single-page PDF highlight prototype.
--
-- Proves the load-bearing piece of the design: a bidirectional map between
-- buffer (row, col) and PDF page geometry, built from `pdftotext -bbox-layout`.
--
-- Highlights are stored as GEOMETRY (page-point rects), never as buffer
-- offsets. On load they are re-derived back into buffer positions, so the
-- round-trip is what actually gets exercised when you test this.
--
-- Hard deps: pdftotext, pdftoppm (poppler). Image pane is optional (snacks.nvim).

local M = {}

M.config = {
  dpi = 150,
  data_dir = nil, -- defaults to <this file's dir>/data
  default_color = "yellow",
  colors = {
    yellow = "#5c5320",
    blue   = "#1e3a5f",
    red    = "#5c2020",
    purple = "#43265c",
  },
}

local NS = vim.api.nvim_create_namespace("pdfproto")
local state = nil -- single active document; prototype scope

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

local function uuid()
  local t = "0123456789abcdef"
  local out = {}
  for i = 1, 32 do
    if i == 13 then
      out[i] = "4"
    elseif i == 17 then
      local v = math.random(1, 4)
      out[i] = ("89ab"):sub(v, v)
    else
      local n = math.random(1, 16)
      out[i] = t:sub(n, n)
    end
  end
  local s = table.concat(out)
  return ("%s-%s-%s-%s-%s"):format(s:sub(1, 8), s:sub(9, 12), s:sub(13, 16), s:sub(17, 20), s:sub(21, 32))
end

local function unescape(s)
  s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
  s = s:gsub("&#x(%x+);", function(h) return vim.fn.nr2char(tonumber(h, 16)) end)
  s = s:gsub("&#(%d+);", function(d) return vim.fn.nr2char(tonumber(d)) end)
  return (s:gsub("&amp;", "&")) -- last, so &amp;lt; survives correctly
end

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":h")
end

local function data_dir()
  local d = M.config.data_dir or (this_dir() .. "/data")
  vim.fn.mkdir(d, "p")
  return d
end

----------------------------------------------------------------------
-- 1. extraction: pdftotext -bbox-layout -> words with page geometry
----------------------------------------------------------------------

--- Parse one page of `pdftotext -bbox-layout` XHTML.
--- @return table|nil page  { width, height, blocks = { { lines = { { words = {...} } } } } }
--- @return string|nil err
function M.extract_page(pdf, pageno)
  if vim.fn.executable("pdftotext") == 0 then
    return nil, "pdftotext not found (install poppler-utils)"
  end
  if vim.fn.filereadable(pdf) == 0 then
    return nil, "not readable: " .. pdf
  end

  local res = vim.system({
    "pdftotext", "-bbox-layout", "-f", tostring(pageno), "-l", tostring(pageno), pdf, "-",
  }, { text = true }):wait()

  if res.code ~= 0 then
    return nil, "pdftotext failed: " .. (res.stderr or "")
  end

  local page = nil
  local block, line
  local n_words = 0

  for raw in (res.stdout or ""):gmatch("[^\n]+") do
    local w, h = raw:match('<page width="([%d%.%-]+)"%s+height="([%d%.%-]+)"')
    if w then
      page = { width = tonumber(w), height = tonumber(h), blocks = {} }
      goto continue
    end
    if not page then goto continue end

    if raw:match("^%s*<block") then
      block = { lines = {} }
      table.insert(page.blocks, block)
      goto continue
    end

    if raw:match("^%s*<line") then
      line = { words = {} }
      -- a stray <line> outside a <block> still needs a home
      if not block then
        block = { lines = {} }
        table.insert(page.blocks, block)
      end
      table.insert(block.lines, line)
      goto continue
    end

    do
      local x1, y1, x2, y2, text = raw:match(
        '<word xMin="([%d%.%-eE]+)"%s+yMin="([%d%.%-eE]+)"%s+xMax="([%d%.%-eE]+)"%s+yMax="([%d%.%-eE]+)">(.-)</word>'
      )
      if x1 and line then
        text = unescape(text)
        -- poppler emits empty <word> nodes for some glyphs/ligatures; they carry
        -- geometry but no text, so they cannot be selected. Drop them.
        if text ~= "" and text:match("%S") then
          table.insert(line.words, {
            text = text,
            x1 = tonumber(x1), y1 = tonumber(y1),
            x2 = tonumber(x2), y2 = tonumber(y2),
          })
          n_words = n_words + 1
        end
      end
    end

    ::continue::
  end

  if not page then return nil, "no <page> in pdftotext output (page " .. pageno .. " out of range?)" end
  page.n_words = n_words
  return page
end

----------------------------------------------------------------------
-- 2. layout: page geometry -> buffer lines + word_map
----------------------------------------------------------------------

--- Flatten a parsed page into buffer lines plus a row -> words index.
--- word_map[row] = { { c0, c1, x1, y1, x2, y2, text } }  (c0 inclusive, c1 exclusive, byte cols)
function M.build_lines(page)
  local lines, word_map = {}, {}
  local row = 0
  local ord = 0

  for bi, block in ipairs(page.blocks) do
    for _, line in ipairs(block.lines) do
      if #line.words > 0 then
        row = row + 1
        local parts, spans, col = {}, {}, 0
        for i, w in ipairs(line.words) do
          if i > 1 then
            table.insert(parts, " ")
            col = col + 1
          end
          table.insert(parts, w.text)
          ord = ord + 1
          table.insert(spans, {
            ord = ord,
            c0 = col, c1 = col + #w.text,
            x1 = w.x1, y1 = w.y1, x2 = w.x2, y2 = w.y2,
            text = w.text,
          })
          col = col + #w.text
        end
        lines[row] = table.concat(parts)
        word_map[row] = spans
      end
    end
    if bi < #page.blocks then
      row = row + 1
      lines[row] = ""
    end
  end

  return lines, word_map
end

----------------------------------------------------------------------
-- 3. geometry <-> buffer position
----------------------------------------------------------------------

--- Buffer selection -> per-row merged rects (the highlight's geometry).
local function rects_from_selection(word_map, r1, c1, r2, c2)
  local rects, texts = {}, {}
  for row = r1, r2 do
    local spans = word_map[row]
    if spans then
      local lo = (row == r1) and c1 or 0
      local hi = (row == r2) and c2 or math.huge
      local rx1, ry1, rx2, ry2, chunk = nil, nil, nil, nil, {}
      for _, s in ipairs(spans) do
        if s.c0 <= hi and (s.c1 - 1) >= lo then
          rx1 = math.min(rx1 or s.x1, s.x1)
          ry1 = math.min(ry1 or s.y1, s.y1)
          rx2 = math.max(rx2 or s.x2, s.x2)
          ry2 = math.max(ry2 or s.y2, s.y2)
          table.insert(chunk, s.text)
        end
      end
      if rx1 then
        table.insert(rects, { x1 = rx1, y1 = ry1, x2 = rx2, y2 = ry2 })
        table.insert(texts, table.concat(chunk, " "))
      end
    end
  end
  return rects, table.concat(texts, " ")
end

--- Geometry -> buffer positions. The inverse of the above; used on load so the
--- stored rects (not stale buffer offsets) drive what gets painted.
--- @return table list of { row, c0, c1 }
function M.positions_from_rects(word_map, rects)
  local out = {}
  local EPS = 0.5
  for row, spans in pairs(word_map) do
    local lo, hi
    for _, s in ipairs(spans) do
      local cx = (s.x1 + s.x2) / 2
      local cy = (s.y1 + s.y2) / 2
      for _, r in ipairs(rects) do
        if cx >= r.x1 - EPS and cx <= r.x2 + EPS and cy >= r.y1 - EPS and cy <= r.y2 + EPS then
          lo = math.min(lo or s.c0, s.c0)
          hi = math.max(hi or s.c1, s.c1)
          break
        end
      end
    end
    if lo then table.insert(out, { row = row, c0 = lo, c1 = hi }) end
  end
  table.sort(out, function(a, b) return a.row < b.row end)
  return out
end

local function bounding_of(rects, page)
  local x1, y1, x2, y2
  for _, r in ipairs(rects) do
    x1 = math.min(x1 or r.x1, r.x1)
    y1 = math.min(y1 or r.y1, r.y1)
    x2 = math.max(x2 or r.x2, r.x2)
    y2 = math.max(y2 or r.y2, r.y2)
  end
  return { x1 = x1, y1 = y1, x2 = x2, y2 = y2, width = page.width, height = page.height }
end

----------------------------------------------------------------------
-- 4. storage (Logseq-shaped, JSON instead of EDN)
----------------------------------------------------------------------

local function sidecar_path(pdf)
  return data_dir() .. "/" .. vim.fn.fnamemodify(pdf, ":t:r") .. ".hl.json"
end

--- Standalone writer, so the image view can share the same sidecar.
function M.save_highlights(pdf, highlights)
  local path = sidecar_path(pdf)
  local fd = io.open(path, "w")
  if not fd then return nil, "cannot write " .. path end
  fd:write(vim.json.encode({ pdf = pdf, highlights = highlights }))
  fd:close()
  return path
end

function M.save()
  if not state then return end
  return M.save_highlights(state.pdf, state.highlights)
end

function M.load_sidecar(pdf)
  local path = sidecar_path(pdf)
  local fd = io.open(path, "r")
  if not fd then return {} end
  local body = fd:read("*a")
  fd:close()
  local ok, doc = pcall(vim.json.decode, body)
  if not ok or type(doc) ~= "table" then return {} end
  return doc.highlights or {}
end

--- Emit the Logseq `hls__<name>.md` page shape.
function M.export_markdown()
  if not state then return nil, "no document open" end
  local base = vim.fn.fnamemodify(state.pdf, ":t:r")
  local out = {
    ("file:: [%s](file://%s)"):format(vim.fn.fnamemodify(state.pdf, ":t"), state.pdf),
    ("file-path:: file://%s"):format(state.pdf),
    "",
  }
  for _, h in ipairs(state.highlights) do
    table.insert(out, "- " .. (h.content.text or ""))
    table.insert(out, "  ls-type:: annotation")
    table.insert(out, "  hl-page:: " .. h.page)
    table.insert(out, "  hl-color:: " .. (h.properties.color or "yellow"))
    table.insert(out, "  id:: " .. h.id)
  end
  local path = data_dir() .. "/hls__" .. base .. ".md"
  local fd = io.open(path, "w")
  if not fd then return nil, "cannot write " .. path end
  fd:write(table.concat(out, "\n") .. "\n")
  fd:close()
  return path
end

----------------------------------------------------------------------
-- 5. rendering into the buffer
----------------------------------------------------------------------

local function ensure_hl_groups()
  for name, bg in pairs(M.config.colors) do
    vim.api.nvim_set_hl(0, "PdfProto" .. name:sub(1, 1):upper() .. name:sub(2), { bg = bg })
  end
end

local function hl_group(color)
  color = color or M.config.default_color
  return "PdfProto" .. color:sub(1, 1):upper() .. color:sub(2)
end

function M.render()
  if not state then return end
  vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
  for _, h in ipairs(state.highlights) do
    local positions = M.positions_from_rects(state.word_map, h.position.rects)
    h._positions = positions
    for _, p in ipairs(positions) do
      pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, p.row - 1, p.c0, {
        end_row = p.row - 1,
        end_col = p.c1,
        hl_group = hl_group(h.properties.color),
        priority = 200,
      })
    end
  end
end

----------------------------------------------------------------------
-- 6. actions
----------------------------------------------------------------------

local function visual_range()
  local mode = vim.fn.mode()
  local a = vim.fn.getpos("v")
  local b = vim.fn.getpos(".")
  local r1, c1, r2, c2 = a[2], a[3] - 1, b[2], b[3] - 1
  if r1 > r2 or (r1 == r2 and c1 > c2) then
    r1, c1, r2, c2 = r2, c2, r1, c1
  end
  if mode == "V" then c1, c2 = 0, math.huge end
  return r1, c1, r2, c2
end

function M.highlight(color)
  if not state then return end
  local r1, c1, r2, c2 = visual_range()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)

  local rects, text = rects_from_selection(state.word_map, r1, c1, r2, c2)
  if #rects == 0 then
    vim.notify("pdfproto: selection covers no words", vim.log.levels.WARN)
    return
  end

  local h = {
    id = uuid(),
    page = state.page,
    position = {
      page = state.page,
      bounding = bounding_of(rects, state.page_geom),
      rects = rects,
    },
    content = { text = text },
    properties = { color = color or M.config.default_color },
  }
  table.insert(state.highlights, h)
  M.render()
  M.save()
  vim.notify(("pdfproto: highlighted %d rect(s), %d chars"):format(#rects, #text))
end

function M.delete_at_cursor()
  if not state then return end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2]
  for i = #state.highlights, 1, -1 do
    for _, p in ipairs(state.highlights[i]._positions or {}) do
      if p.row == row and col >= p.c0 and col < p.c1 then
        table.remove(state.highlights, i)
        M.render()
        M.save()
        vim.notify("pdfproto: deleted highlight")
        return
      end
    end
  end
  vim.notify("pdfproto: no highlight under cursor", vim.log.levels.WARN)
end

function M.jump(dir)
  if not state then return end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rows = {}
  for _, h in ipairs(state.highlights) do
    for _, p in ipairs(h._positions or {}) do table.insert(rows, p) end
  end
  table.sort(rows, function(a, b) return a.row < b.row end)
  if dir > 0 then
    for _, p in ipairs(rows) do
      if p.row > row then return vim.api.nvim_win_set_cursor(0, { p.row, p.c0 }) end
    end
  else
    for i = #rows, 1, -1 do
      if rows[i].row < row then return vim.api.nvim_win_set_cursor(0, { rows[i].row, rows[i].c0 }) end
    end
  end
  vim.notify("pdfproto: no more highlights", vim.log.levels.WARN)
end

--- The manual-test workhorse: prove the word under the cursor maps to real
--- page coordinates.
function M.debug_at_cursor()
  if not state then return vim.notify("pdfproto: nothing open") end
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1], pos[2]
  local spans = state.word_map[row]
  if not spans then return vim.notify(("row %d: no words (block gap)"):format(row)) end
  for _, s in ipairs(spans) do
    if col >= s.c0 and col < s.c1 then
      local scale = M.config.dpi / 72
      vim.notify(table.concat({
        ("word      %q"):format(s.text),
        ("buffer    row %d, cols [%d,%d)"):format(row, s.c0, s.c1),
        ("pdf pts   x %.2f..%.2f   y %.2f..%.2f"):format(s.x1, s.x2, s.y1, s.y2),
        ("px @%ddpi x %.0f..%.0f   y %.0f..%.0f"):format(M.config.dpi,
          s.x1 * scale, s.x2 * scale, s.y1 * scale, s.y2 * scale),
        ("page      %d  (%.0f x %.0f pts)"):format(state.page, state.page_geom.width, state.page_geom.height),
      }, "\n"))
      return
    end
  end
  vim.notify(("row %d col %d: between words"):format(row, col))
end

function M.list()
  if not state then return end
  local items = {}
  for _, h in ipairs(state.highlights) do
    local p = (h._positions or {})[1]
    table.insert(items, {
      bufnr = state.buf,
      lnum = p and p.row or 1,
      col = (p and p.c0 or 0) + 1,
      text = ("[%s] %s"):format(h.properties.color, (h.content.text or ""):sub(1, 90)),
    })
  end
  if #items == 0 then return vim.notify("pdfproto: no highlights") end
  vim.fn.setloclist(0, items, "r")
  vim.cmd("lopen")
end

----------------------------------------------------------------------
-- 7. optional image pane (the fragile part -- everything above works without it)
----------------------------------------------------------------------

function M.image()
  if not state then return end
  if vim.fn.executable("pdftoppm") == 0 then
    return vim.notify("pdfproto: pdftoppm not found", vim.log.levels.ERROR)
  end
  local prefix = data_dir() .. "/" .. vim.fn.fnamemodify(state.pdf, ":t:r") .. "-p" .. state.page
  local png = prefix .. ".png"
  if vim.fn.filereadable(png) == 0 then
    local r = vim.system({
      "pdftoppm", "-png", "-r", tostring(M.config.dpi),
      "-f", tostring(state.page), "-l", tostring(state.page),
      "-singlefile", state.pdf, prefix,
    }, { text = true }):wait()
    if r.code ~= 0 then
      return vim.notify("pdfproto: pdftoppm failed: " .. (r.stderr or ""), vim.log.levels.ERROR)
    end
  end

  if not _G.Snacks or not _G.Snacks.image then
    return vim.notify("pdfproto: rendered " .. png .. "\n(snacks.nvim not loaded -- open it externally)")
  end

  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].bufhidden = "wipe"
  local ok, err = pcall(function()
    _G.Snacks.image.placement.new(buf, png, {
      type = "image",
      inline = false,
      conceal = false,
      pos = { 1, 0 },
    })
  end)
  if not ok then
    vim.notify("pdfproto: snacks placement failed: " .. tostring(err) .. "\npng at " .. png, vim.log.levels.WARN)
  end
end

----------------------------------------------------------------------
-- 8. open
----------------------------------------------------------------------

function M.open(pdf, pageno)
  pdf = vim.fn.fnamemodify(vim.fn.expand(pdf), ":p")
  pageno = tonumber(pageno) or 1

  local page, err = M.extract_page(pdf, pageno)
  if not page then
    return vim.notify("pdfproto: " .. err, vim.log.levels.ERROR)
  end

  local lines, word_map = M.build_lines(page)
  ensure_hl_groups()

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, ("pdfproto://%s#p%d"):format(vim.fn.fnamemodify(pdf, ":t"), pageno))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "pdfproto"
  vim.api.nvim_set_current_buf(buf)
  vim.wo.wrap = false
  vim.wo.number = true
  vim.wo.cursorline = true

  state = {
    pdf = pdf,
    page = pageno,
    page_geom = page,
    buf = buf,
    lines = lines,
    word_map = word_map,
    highlights = M.load_sidecar(pdf),
  }
  -- only keep highlights for this page
  local keep = {}
  for _, h in ipairs(state.highlights) do
    if h.page == pageno then table.insert(keep, h) end
  end
  state.highlights = keep

  M.render()

  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, desc = desc, silent = true })
  end
  map("v", "<leader>hy", function() M.highlight("yellow") end, "Highlight yellow")
  map("v", "<leader>hb", function() M.highlight("blue") end, "Highlight blue")
  map("v", "<leader>hr", function() M.highlight("red") end, "Highlight red")
  map("v", "<leader>hp", function() M.highlight("purple") end, "Highlight purple")
  map("n", "<leader>hd", M.delete_at_cursor, "Delete highlight")
  map("n", "<leader>hl", M.list, "List highlights")
  map("n", "<leader>hi", M.image, "Show page image")
  map("n", "<leader>h?", M.debug_at_cursor, "Debug word geometry")
  map("n", "<Tab>", function()
    local pos = vim.api.nvim_win_get_cursor(0)
    local ord
    for _, sp in ipairs(state.word_map[pos[1]] or {}) do
      if pos[2] >= sp.c0 and pos[2] < sp.c1 then ord = sp.ord break end
      if not ord and sp.c0 >= pos[2] then ord = sp.ord end
    end
    local pdf, page = state.pdf, state.page
    local ok, view = pcall(require, "pdfview")
    if not ok then return vim.notify("pdfproto: pdfview not on package.path", vim.log.levels.WARN) end
    view.open(pdf, page)
    view.goto_ord(ord)
  end, "Switch to image view")
  map("n", "]p", function() M.open(state.pdf, state.page + 1) end, "Next page")
  map("n", "[p", function()
    if state.page > 1 then M.open(state.pdf, state.page - 1) end
  end, "Previous page")
  map("n", "]h", function() M.jump(1) end, "Next highlight")
  map("n", "[h", function() M.jump(-1) end, "Prev highlight")

  vim.notify(("pdfproto: %s p%d -- %d words, %d rows, %d highlight(s)")
    :format(vim.fn.fnamemodify(pdf, ":t"), pageno, page.n_words, #lines, #state.highlights))
end

function M.setup()
  math.randomseed(tonumber(tostring(vim.uv.hrtime()):sub(-9)))
  vim.api.nvim_create_user_command("PdfProtoOpen", function(o)
    M.open(o.fargs[1], o.fargs[2])
  end, { nargs = "+", complete = "file", desc = "Open a PDF page as a highlightable buffer" })
  vim.api.nvim_create_user_command("PdfProtoImage", M.image, {})
  vim.api.nvim_create_user_command("PdfProtoList", M.list, {})
  vim.api.nvim_create_user_command("PdfProtoDebug", M.debug_at_cursor, {})
  vim.api.nvim_create_user_command("PdfProtoExport", function()
    local p, e = M.export_markdown()
    vim.notify(p and ("pdfproto: wrote " .. p) or ("pdfproto: " .. e))
  end, {})
end

M.uuid = uuid
M._state = function() return state end

return M
