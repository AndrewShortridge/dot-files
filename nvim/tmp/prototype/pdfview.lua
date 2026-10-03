-- pdfview.lua -- image-first PDF page view: see the real page, select text on it.
--
-- The page is rendered by poppler and shown via snacks/kitty, so figures,
-- equations and layout are exactly as they are in the PDF. Invisibly behind
-- the image sits a cell grid: every word from `pdftotext -bbox-layout` owns a
-- rectangle of terminal cells, so the cursor can walk the page word by word.
--
-- Snacks draws the image with unicode placeholder extmarks, which means the
-- buffer text underneath is not visible -- so nvim's own Visual highlight
-- cannot be seen over the page. Selection feedback therefore comes from a
-- footer readout while you select, and from the highlight being composited
-- into the page image once you confirm.

local proto = require("pdfproto")
local IO = require("image_ops")

local M = {}

M.config = {
  max_dpi = 220,
  min_dpi = 48,
  fallback_cell = { w = 8, h = 17 }, -- if the terminal will not tell us
  default_color = "yellow",
}

local S = nil -- active view
local gen = 0

----------------------------------------------------------------------
-- geometry
----------------------------------------------------------------------

--- snacks detects kitty from an async DA3 reply. Placing an image before that
--- reply lands leaves `env().placeholders` unset and nothing is drawn -- so
--- every entry point goes through here first.
local function with_terminal(fn)
  if not (_G.Snacks and _G.Snacks.image) then return fn() end
  local ok = pcall(function() Snacks.image.terminal.detect(fn) end)
  if not ok then fn() end
end

--- How many cells snacks will actually use for this image in this window.
local function fit_grid(png, cols, rows)
  local ok, sz = pcall(function()
    return Snacks.image.util.fit(png, { width = cols, height = rows })
  end)
  if ok and sz and (sz.width or 0) > 0 and (sz.height or 0) > 0 then
    return sz.width, sz.height
  end
  local iw, ih = IO.png_dim(png)
  local cell = M.config.fallback_cell
  if not iw then return cols, rows end
  return math.min(cols, math.ceil(iw / cell.w)), math.min(rows, math.ceil(ih / cell.h))
end

local function cell_size()
  local ok, sz = pcall(function() return Snacks.image.terminal.size() end)
  if ok and sz and (sz.cell_width or 0) > 1 and (sz.cell_height or 0) > 1 then
    return { w = sz.cell_width, h = sz.cell_height }
  end
  return M.config.fallback_cell
end

--- Flatten a parsed page into reading order, matching pdfproto.build_lines so
--- `ord` means the same thing in both views.
local function flatten(page)
  local words, line_idx = {}, 0
  for _, block in ipairs(page.blocks) do
    for _, line in ipairs(block.lines) do
      if #line.words > 0 then
        line_idx = line_idx + 1
        for _, w in ipairs(line.words) do
          words[#words + 1] = {
            ord = #words + 1,
            line = line_idx,
            text = w.text,
            x1 = w.x1, y1 = w.y1, x2 = w.x2, y2 = w.y2,
          }
        end
      end
    end
  end
  return words
end

--- Attach terminal-cell rectangles to each word for the current render scale.
--- One cell row per word, chosen by its vertical centre. A word's ink is
--- usually taller than a terminal cell, so anchoring to the centre keeps the
--- grid unambiguous instead of letting every word straddle two rows.
--- Returns how many cell rows carry more than one PDF text line, which is the
--- honest measure of how much resolution the terminal is costing you.
local function assign_cells(words, page_w, page_h, gw, gh)
  local rows = {}
  for _, w in ipairs(words) do
    w.c0 = math.max(0, math.min(gw - 1, math.floor(w.x1 / page_w * gw)))
    w.c1 = math.max(w.c0, math.min(gw - 1, math.ceil(w.x2 / page_w * gw) - 1))
    w.r = math.max(1, math.min(gh, math.floor(((w.y1 + w.y2) / 2) / page_h * gh) + 1))
    rows[w.r] = rows[w.r] or {}
    rows[w.r][w.line] = true
  end
  local crowded = 0
  for _, ls in pairs(rows) do
    if vim.tbl_count(ls) > 1 then crowded = crowded + 1 end
  end
  return crowded
end

----------------------------------------------------------------------
-- page rendering
----------------------------------------------------------------------

--- Total pages, via poppler. nil if pdfinfo is unavailable.
local page_counts = {}
local function page_count(pdf)
  if page_counts[pdf] ~= nil then return page_counts[pdf] or nil end
  local n = false
  if vim.fn.executable("pdfinfo") == 1 then
    local r = vim.system({ "pdfinfo", pdf }, { text = true }):wait()
    if r.code == 0 then n = tonumber((r.stdout or ""):match("Pages:%s+(%d+)")) or false end
  end
  page_counts[pdf] = n
  return n or nil
end
M.page_count = page_count

local function base_ppm(pdf, page, dpi)
  local dir = proto.config.data_dir or (vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/data")
  vim.fn.mkdir(dir, "p")
  local prefix = ("%s/%s-p%d-r%d"):format(dir, vim.fn.fnamemodify(pdf, ":t:r"), page, dpi)
  local ppm = prefix .. ".ppm"
  if vim.fn.filereadable(ppm) == 0 then
    local r = vim.system({
      "pdftoppm", "-r", tostring(dpi), "-f", tostring(page), "-l", tostring(page),
      "-singlefile", pdf, prefix,
    }, { text = true }):wait()
    if r.code ~= 0 then return nil, "pdftoppm: " .. (r.stderr or "") end
  end
  return ppm
end

--- Composite the page's highlights into a fresh PNG and return its path.
local function render_png(pdf, page, dpi, highlights, sx, sy)
  local ppm, err = base_ppm(pdf, page, dpi)
  if not ppm then return nil, err end

  local img
  img, err = IO.read_ppm(ppm)
  if not img then return nil, err end

  local rects = {}
  for _, h in ipairs(highlights) do
    for _, r in ipairs(h.position.rects) do
      rects[#rects + 1] = {
        x0 = r.x1 * sx, y0 = r.y1 * sy,
        x1 = r.x2 * sx, y1 = r.y2 * sy,
        color = h.properties.color,
      }
    end
  end
  if #rects > 0 then IO.highlight_rects(img, rects) end

  gen = gen + 1
  local out = ppm:gsub("%.ppm$", "") .. "-g" .. gen .. ".png"
  local ok
  ok, err = IO.write_png(out, img)
  if not ok then return nil, err end
  return out, img.w, img.h
end

----------------------------------------------------------------------
-- footer readout (the selection feedback the image cannot give us)
----------------------------------------------------------------------

local function close_footer()
  if S and S.footer_win and vim.api.nvim_win_is_valid(S.footer_win) then
    vim.api.nvim_win_close(S.footer_win, true)
  end
  if S then S.footer_win, S.footer_buf = nil, nil end
end

local function footer(lines)
  if not S then return end
  if not (S.footer_buf and vim.api.nvim_buf_is_valid(S.footer_buf)) then
    S.footer_buf = vim.api.nvim_create_buf(false, true)
  end
  vim.bo[S.footer_buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.footer_buf, 0, -1, false, lines)
  vim.bo[S.footer_buf].modifiable = false

  local w = vim.api.nvim_win_get_width(S.win)
  local cfg = {
    relative = "win", win = S.win, anchor = "SW",
    row = vim.api.nvim_win_get_height(S.win), col = 0,
    width = w, height = #lines,
    style = "minimal", border = "none", focusable = false, zindex = 200,
  }
  if S.footer_win and vim.api.nvim_win_is_valid(S.footer_win) then
    vim.api.nvim_win_set_config(S.footer_win, cfg)
  else
    S.footer_win = vim.api.nvim_open_win(S.footer_buf, false, cfg)
    vim.wo[S.footer_win].winhl = "Normal:PdfViewFooter"
  end
end

----------------------------------------------------------------------
-- word lookup / motions
----------------------------------------------------------------------

local function word_at_cursor()
  if not S then return nil end
  local pos = vim.api.nvim_win_get_cursor(S.win)
  local row, col = pos[1], pos[2]
  for _, w in ipairs(S.words) do
    if row == w.r and col >= w.c0 and col <= w.c1 then return w end
  end
  -- nothing exactly under the cursor: fall back to the nearest word
  local best, bd
  for _, w in ipairs(S.words) do
    local dr = math.abs(w.r - row)
    local dc = math.max(w.c0 - col, col - w.c1, 0)
    local d = dr * 40 + dc
    if not bd or d < bd then best, bd = w, d end
  end
  return best
end

local function goto_word(w)
  if not (S and w) then return end
  pcall(vim.api.nvim_win_set_cursor, S.win, { w.r, w.c0 })
  S.cur = w
  M.update_footer()
end

local function step(delta)
  local w = S.cur or word_at_cursor()
  if not w then return end
  goto_word(S.words[math.min(#S.words, math.max(1, w.ord + delta))])
end

local function step_line(delta)
  local w = S.cur or word_at_cursor()
  if not w then return end
  local target = w.line + delta
  local cx = (w.x1 + w.x2) / 2
  local best, bd
  for _, o in ipairs(S.words) do
    if o.line == target then
      local d = math.abs((o.x1 + o.x2) / 2 - cx)
      if not bd or d < bd then best, bd = o, d end
    end
  end
  if best then goto_word(best) end
end

local function line_edge(last)
  local w = S.cur or word_at_cursor()
  if not w then return end
  local best
  for _, o in ipairs(S.words) do
    if o.line == w.line then
      if not best or (last and o.ord > best.ord) or (not last and o.ord < best.ord) then best = o end
    end
  end
  if best then goto_word(best) end
end

----------------------------------------------------------------------
-- selection + highlighting
----------------------------------------------------------------------

local function selection()
  if not (S and S.anchor) then return nil end
  local a, b = S.anchor.ord, (S.cur or S.anchor).ord
  if a > b then a, b = b, a end
  local out = {}
  for i = a, b do out[#out + 1] = S.words[i] end
  return out
end

function M.update_footer()
  if not S then return end
  local w = S.cur
  local left = ("  p%d%s   word %d/%d   %s")
    :format(S.page, S.n_pages and ("/" .. S.n_pages) or "",
      w and w.ord or 0, #S.words, w and ('"' .. w.text .. '"') or "-")
  local right = ("%d highlight(s)   [v]select  []p[p]page  [Tab]text  [x]del  [q]quit  ")
    :format(#S.highlights)
  local width = vim.api.nvim_win_get_width(S.win)
  local pad = math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right))
  local l1 = left .. string.rep(" ", pad) .. right

  local sel = selection()
  local l2
  if sel then
    local txt = {}
    for _, x in ipairs(sel) do txt[#txt + 1] = x.text end
    txt = table.concat(txt, " ")
    if #txt > width - 46 then txt = txt:sub(1, math.max(10, width - 49)) .. "..." end
    l2 = ("  SELECT %d word(s): %s   [1]yel [2]blu [3]red [4]pur  [Esc]cancel")
      :format(#sel, '"' .. txt .. '"')
  else
    l2 = "  press v to start a selection, then move with w/b/j/k and pick a colour"
  end
  footer({ l1, l2 })
end

local function commit(color)
  local sel = selection()
  if not sel or #sel == 0 then return end

  -- merge the selected words into one rect per text line
  local by_line, order = {}, {}
  for _, w in ipairs(sel) do
    if not by_line[w.line] then by_line[w.line] = {}; order[#order + 1] = w.line end
    table.insert(by_line[w.line], w)
  end
  local rects, texts = {}, {}
  for _, ln in ipairs(order) do
    local x1, y1, x2, y2, chunk
    chunk = {}
    for _, w in ipairs(by_line[ln]) do
      x1 = math.min(x1 or w.x1, w.x1); y1 = math.min(y1 or w.y1, w.y1)
      x2 = math.max(x2 or w.x2, w.x2); y2 = math.max(y2 or w.y2, w.y2)
      chunk[#chunk + 1] = w.text
    end
    rects[#rects + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    texts[#texts + 1] = table.concat(chunk, " ")
  end

  local bx1, by1, bx2, by2
  for _, r in ipairs(rects) do
    bx1 = math.min(bx1 or r.x1, r.x1); by1 = math.min(by1 or r.y1, r.y1)
    bx2 = math.max(bx2 or r.x2, r.x2); by2 = math.max(by2 or r.y2, r.y2)
  end

  table.insert(S.highlights, {
    id = proto.uuid(),
    page = S.page,
    position = {
      page = S.page,
      bounding = { x1 = bx1, y1 = by1, x2 = bx2, y2 = by2, width = S.geom.width, height = S.geom.height },
      rects = rects,
    },
    content = { text = table.concat(texts, " ") },
    properties = { color = color },
  })

  S.anchor = nil
  M.save()
  M.repaint()
end

function M.save()
  if not S then return end
  -- keep highlights from other pages that are already on disk
  local all = proto.load_sidecar(S.pdf)
  local keep = {}
  for _, h in ipairs(all) do
    if h.page ~= S.page then keep[#keep + 1] = h end
  end
  for _, h in ipairs(S.highlights) do keep[#keep + 1] = h end
  proto.save_highlights(S.pdf, keep)
end

function M.delete_at_cursor()
  local w = S and (S.cur or word_at_cursor())
  if not w then return end
  local cx, cy = (w.x1 + w.x2) / 2, (w.y1 + w.y2) / 2
  for i = #S.highlights, 1, -1 do
    for _, r in ipairs(S.highlights[i].position.rects) do
      if cx >= r.x1 and cx <= r.x2 and cy >= r.y1 and cy <= r.y2 then
        table.remove(S.highlights, i)
        M.save()
        return M.repaint()
      end
    end
  end
  vim.notify("pdfview: no highlight under the cursor", vim.log.levels.WARN)
end

----------------------------------------------------------------------
-- painting
----------------------------------------------------------------------

function M.repaint()
  if not S then return end
  local keep_ord = (S.cur or {}).ord

  local png, w, h = render_png(S.pdf, S.page, S.dpi, S.highlights, S.sx or 1, S.sy or 1)
  if not png then
    return vim.notify("pdfview: " .. tostring(w), vim.log.levels.ERROR)
  end
  S.img_w, S.img_h, S.png = w, h, png
  S.sx, S.sy = w / S.geom.width, h / S.geom.height

  -- the cell grid is whatever snacks will draw, so words line up with the page
  local gw, gh = fit_grid(png, S.cols, S.rows)
  S.gw, S.gh = gw, gh
  S.crowded = assign_cells(S.words, S.geom.width, S.geom.height, gw, gh)

  if S.placement then pcall(function() S.placement:close() end) end

  vim.bo[S.buf].modifiable = true
  local blank = string.rep(" ", gw)
  local lines = {}
  for i = 1, gh do lines[i] = blank end
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false

  if not (_G.Snacks and _G.Snacks.image) then
    return vim.notify("pdfview: snacks.image not loaded -- page written to " .. png, vim.log.levels.WARN)
  end
  if not Snacks.image.supports_terminal() then
    return vim.notify(
      "pdfview: this terminal has no kitty graphics protocol.\n"
        .. "Run inside kitty/ghostty, or set image.force = true in the snacks setup.\n"
        .. "Page written to " .. png, vim.log.levels.ERROR)
  end

  -- conceal + a range spanning every row is what makes snacks overlay the
  -- image onto real buffer lines. Without it the whole page is emitted as
  -- virtual lines below line 1 and the cursor cannot reach any of it.
  local ok, err = pcall(function()
    S.placement = Snacks.image.placement.new(S.buf, png, {
      type = "image",
      conceal = true,
      pos = { 1, 0 },
      range = { 1, 0, gh, 0 },
      width = gw,
      height = gh,
      auto_resize = false,
    })
  end)
  if not ok then
    vim.notify("pdfview: snacks placement failed: " .. tostring(err) .. "\npng: " .. png, vim.log.levels.WARN)
  end

  if keep_ord then M.goto_ord(keep_ord) end
  M.update_footer()

  -- if snacks ends up drawing a different size than we planned, re-derive the
  -- grid from what it actually drew rather than leaving the words misaligned
  vim.defer_fn(function()
    if not (S and S.placement) then return end
    local ok2, st = pcall(function() return S.placement:state() end)
    if ok2 and st and st.loc and (st.loc.width ~= S.gw or st.loc.height ~= S.gh) then
      S.gw, S.gh = st.loc.width, st.loc.height
      S.crowded = assign_cells(S.words, S.geom.width, S.geom.height, S.gw, S.gh)
      M.update_footer()
    end
  end, 300)
end

----------------------------------------------------------------------
-- open / close / toggle
----------------------------------------------------------------------

function M.close()
  if not S then return end
  close_footer()
  if S.placement then pcall(function() S.placement:close() end) end
  local buf = S.buf
  S = nil
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
end

--- Jump to the text view, landing on the same word.
function M.to_text()
  if not S then return end
  local ord = (S.cur or word_at_cursor() or {}).ord
  local pdf, page = S.pdf, S.page
  M.close()
  proto.open(pdf, page)
  if ord then
    local st = proto._state()
    for row, spans in pairs(st.word_map) do
      for _, sp in ipairs(spans) do
        if sp.ord == ord then
          pcall(vim.api.nvim_win_set_cursor, 0, { row, sp.c0 })
          return
        end
      end
    end
  end
end

local function open_impl(pdf, pageno)
  pdf = vim.fn.fnamemodify(vim.fn.expand(pdf), ":p")
  pageno = tonumber(pageno) or 1

  local page, err = proto.extract_page(pdf, pageno)
  if not page then return vim.notify("pdfview: " .. err, vim.log.levels.ERROR) end

  vim.api.nvim_set_hl(0, "PdfViewFooter", { bg = "#1c1c22", fg = "#c8c8d0" })

  local win = vim.api.nvim_get_current_win()
  local cell = cell_size()
  local cols = vim.api.nvim_win_get_width(win)
  local rows = math.max(4, vim.api.nvim_win_get_height(win) - 2) -- footer takes 2

  local zoom = M._next_zoom or 1
  M._next_zoom = nil
  -- dpi only controls render sharpness; the cell grid comes from snacks
  local scale = math.min(cols * cell.w / page.width, rows * cell.h / page.height)
  local dpi = math.max(M.config.min_dpi, math.min(M.config.max_dpi, math.floor(72 * scale * zoom)))

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, ("pdfview://%s#p%d"):format(vim.fn.fnamemodify(pdf, ":t"), pageno))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "pdfview"
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false
  vim.wo[win].fillchars = "eob: "
  vim.wo[win].conceallevel = 3
  vim.wo[win].concealcursor = "nvic"
  vim.wo[win].list = false

  local all = proto.load_sidecar(pdf)
  local mine = {}
  for _, h in ipairs(all) do if h.page == pageno then mine[#mine + 1] = h end end

  S = {
    pdf = pdf, page = pageno, geom = page, buf = buf, win = win,
    cell = cell, cols = cols, rows = rows, dpi = dpi, zoom = zoom,
    n_pages = page_count(pdf),
    words = flatten(page), highlights = mine,
    anchor = nil, cur = nil,
  }

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, silent = true, nowait = true })
  end
  map("w", function() step(1) end, "next word")
  map("l", function() step(1) end, "next word")
  map("<Right>", function() step(1) end, "next word")
  map("b", function() step(-1) end, "prev word")
  map("h", function() step(-1) end, "prev word")
  map("<Left>", function() step(-1) end, "prev word")
  map("j", function() step_line(1) end, "line down")
  map("<Down>", function() step_line(1) end, "line down")
  map("k", function() step_line(-1) end, "line up")
  map("<Up>", function() step_line(-1) end, "line up")
  map("0", function() line_edge(false) end, "line start")
  map("$", function() line_edge(true) end, "line end")
  map("gg", function() goto_word(S.words[1]) end, "first word")
  map("G", function() goto_word(S.words[#S.words]) end, "last word")
  map("v", function()
    if S.anchor then S.anchor = nil else S.anchor = S.cur or word_at_cursor() end
    M.update_footer()
  end, "start/stop selection")
  map("<Esc>", function() S.anchor = nil; M.update_footer() end, "cancel selection")
  map("<CR>", function() commit(M.config.default_color) end, "confirm (yellow)")
  map("1", function() commit("yellow") end, "confirm yellow")
  map("2", function() commit("blue") end, "confirm blue")
  map("3", function() commit("red") end, "confirm red")
  map("4", function() commit("purple") end, "confirm purple")
  map("x", M.delete_at_cursor, "delete highlight")
  map("r", function() local p, pg = S.pdf, S.page; M.close(); M.open(p, pg) end, "refit + rerender")
  map("?", M.debug, "debug")
  map("]p", function() M.page_step(1) end, "next page")
  map("[p", function() M.page_step(-1) end, "previous page")
  map("<PageDown>", function() M.page_step(1) end, "next page")
  map("<PageUp>", function() M.page_step(-1) end, "previous page")
  map("gp", function()
    local n = vim.v.count
    if n > 0 then M.set_page(n) else
      vim.ui.input({ prompt = ("Go to page (1-%s): "):format(S.n_pages or "?") }, function(a)
        if a and tonumber(a) then M.set_page(tonumber(a)) end
      end)
    end
  end, "go to page")
  map("+", function() M.zoom(1.5) end, "zoom in")
  map("=", function() M.zoom(1.5) end, "zoom in")
  map("-", function() M.zoom(1 / 1.5) end, "zoom out")
  map("0z", function() M.zoom(nil) end, "zoom reset")
  map("<Tab>", M.to_text, "switch to text view")
  map("q", function() M.close() end, "close")

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if S then S.cur = word_at_cursor(); M.update_footer() end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufDelete" }, {
    buffer = buf, callback = function() close_footer() end,
  })

  M.repaint()
  goto_word(S.words[1])
  vim.notify(("pdfview: %s p%d%s -- %dx%dpx @%ddpi (zoom %.1fx), %d words on a %dx%d cell grid; %d crowded row(s)")
    :format(vim.fn.fnamemodify(pdf, ":t"), pageno, S.n_pages and ("/" .. S.n_pages) or "",
      S.img_w or 0, S.img_h or 0, dpi, zoom,
      #S.words, S.gw or 0, S.gh or 0, S.crowded or 0))
end

--- Every entry point waits for kitty detection before drawing.
function M.open(pdf, pageno)
  with_terminal(function() open_impl(pdf, pageno) end)
end

--- What is actually going on, when the page does not look like a page.
function M.debug()
  local out = { "pdfview debug", "" }
  local function add(k, v) out[#out + 1] = ("  %-22s %s"):format(k, tostring(v)) end
  add("TERM", os.getenv("TERM"))
  add("KITTY_WINDOW_ID", os.getenv("KITTY_WINDOW_ID") or "unset")
  add("KITTY_PID", os.getenv("KITTY_PID") or "unset")
  add("SNACKS_KITTY", os.getenv("SNACKS_KITTY") or "unset")
  add("Snacks loaded", _G.Snacks ~= nil)
  if _G.Snacks and Snacks.image then
    local env = Snacks.image.terminal.env()
    add("env.name", env.name)
    add("env.supported", env.supported)
    add("env.placeholders", env.placeholders)
    add("supports_terminal()", Snacks.image.supports_terminal())
    add("config.force", Snacks.image.config.force)
    local ok, sz = pcall(function() return Snacks.image.terminal.size() end)
    if ok and sz then add("cell px", ("%sx%s"):format(sz.cell_width, sz.cell_height)) end
    add("magick", vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1)
  end
  out[#out + 1] = ""
  if not S then
    add("view", "not open")
  else
    add("pdf", S.pdf)
    add("page / zoom", ("%d of %s / %.2fx"):format(S.page, tostring(S.n_pages or "?"), S.zoom or 1))
    add("png", S.png)
    add("png size", ("%dx%d px @%ddpi"):format(S.img_w or 0, S.img_h or 0, S.dpi))
    add("window cells", ("%dx%d"):format(S.cols, S.rows))
    add("grid cells", ("%dx%d"):format(S.gw or 0, S.gh or 0))
    add("buffer lines", vim.api.nvim_buf_line_count(S.buf))
    add("words / crowded", ("%d / %d"):format(#S.words, S.crowded or 0))
    add("highlights", #S.highlights)
    add("placement", S.placement ~= nil)
    if S.placement then
      local ok, st = pcall(function() return S.placement:state() end)
      add("placement:ready()", (pcall(function() return S.placement:ready() end)))
      if ok and st then
        add("drawn loc", ("row %s col %s  %sx%s cells"):format(st.loc[1], st.loc[2], st.loc.width, st.loc.height))
        add("drawn in wins", #st.wins)
        add("hidden", st.hidden)
      end
      local marks = vim.api.nvim_buf_get_extmarks(S.buf, Snacks.image.placement.ns, 0, -1, {})
      add("snacks extmarks", #marks)
    end
  end
  vim.api.nvim_echo({ { table.concat(out, "\n") } }, true, {})
  return out
end

--- Jump to another page, keeping zoom. Highlights for that page load from the
--- shared sidecar.
function M.set_page(n)
  if not S then return end
  local total = S.n_pages
  n = math.max(1, total and math.min(total, n) or n)
  if n == S.page then return end
  local pdf, zoom = S.pdf, S.zoom
  M._next_zoom = zoom
  M.close()
  M.open(pdf, n)
end

function M.page_step(d)
  if S then M.set_page(S.page + d) end
end

--- Re-render at a different scale. Zooming in is how you get a finer cursor
--- grid than the terminal's cell size would otherwise allow.
function M.zoom(factor)
  if not S then return end
  local pdf, page, ord = S.pdf, S.page, (S.cur or {}).ord
  M._next_zoom = factor and math.max(0.5, math.min(6, (S.zoom or 1) * factor)) or 1
  M.close()
  M.open(pdf, page)
  vim.schedule(function() M.goto_ord(ord) end)
end

--- Used by the text view's <Tab> to land on the same word here.
function M.goto_ord(ord)
  if not (S and ord) then return end
  goto_word(S.words[math.min(#S.words, math.max(1, ord))])
end

function M.setup()
  vim.api.nvim_create_user_command("PdfProtoView", function(o)
    M.open(o.fargs[1], o.fargs[2])
  end, { nargs = "+", complete = "file", desc = "View a PDF page as an image and select text on it" })
  vim.api.nvim_create_user_command("PdfViewDebug", M.debug, { desc = "Why the page is not rendering" })
end

M._state = function() return S end
M._flatten = flatten
M._assign_cells = assign_cells
M._render_png = render_png

return M
