-- Guards the three bugs that made the page not render:
--   1. placing before kitty detection returned  -> nothing drawn
--   2. conceal=false                            -> snacks emits the page as
--                                                  virtual lines below line 1,
--                                                  unreachable by the cursor
--   3. a single-line range                      -> only one row can overlay
--
-- Snacks is stubbed, so this asserts what *we* ask snacks for, headlessly.
--   nvim --headless -u NONE -l tmp/prototype/placement_check.lua
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
package.path = here .. "/?.lua;" .. package.path

local pass, fail = 0, 0
local function check(n, ok, d)
  if ok then pass = pass + 1; print("  ok   " .. n)
  else fail = fail + 1; print("  FAIL " .. n .. (d and ("  -- " .. d) or "")) end
end

local detect_calls, placed = 0, nil
local GRID_W, GRID_H = 96, 60

_G.Snacks = {
  image = {
    config = { force = true },
    supports_terminal = function() return true end,
    terminal = {
      detect = function(cb) detect_calls = detect_calls + 1; cb() end,
      env = function() return { name = "kitty", supported = true, placeholders = true } end,
      size = function() return { cell_width = 8, cell_height = 17 } end,
    },
    util = { fit = function(_, cells)
      return { width = math.min(cells.width, GRID_W), height = math.min(cells.height, GRID_H) }
    end },
    placement = {
      ns = vim.api.nvim_create_namespace("stub"),
      new = function(buf, src, opts)
        placed = { buf = buf, src = src, opts = opts }
        return {
          close = function() end,
          ready = function() return true end,
          state = function()
            return { loc = { 1, 0, width = opts.width, height = opts.height }, wins = {}, hidden = false }
          end,
        }
      end,
    },
  },
}

local P = require("pdfproto")
local V = require("pdfview")
P.config.data_dir = vim.fn.tempname()
vim.notify = function() end

local pdf = arg[1] or vim.fn.expand("~/Desktop/Shock-Profile-Induced-By-Short-Laser-Pulses.pdf")
V.open(pdf, 1)
local S = V._state()

check("waited for terminal detection before drawing", detect_calls >= 1,
  ("detect called %d times"):format(detect_calls))
check("a placement was created", placed ~= nil)

if placed then
  local o = placed.opts
  check("conceal is on (overlay path, not virtual lines)", o.conceal == true, tostring(o.conceal))
  check("range spans every grid row", o.range and o.range[1] == 1 and o.range[3] == S.gh,
    o.range and ("{%d,%d,%d,%d} vs gh=%d"):format(o.range[1], o.range[2], o.range[3], o.range[4], S.gh))
  check("range is more than one line (snacks can_overlay)", o.range[3] - o.range[1] >= 1)
  check("explicit cell size passed", o.width == S.gw and o.height == S.gh,
    ("%sx%s vs %dx%d"):format(tostring(o.width), tostring(o.height), S.gw, S.gh))
  check("auto_resize off (we drive re-render)", o.auto_resize == false)
  check("anchored at line 1", o.pos[1] == 1 and o.pos[2] == 0)
  check("source is the composited png", placed.src == S.png, tostring(placed.src))
  check("png exists on disk", vim.fn.filereadable(placed.src) == 1)
end

-- the buffer must be a real grid, or the cursor has nowhere to go
check("buffer has one line per grid row", vim.api.nvim_buf_line_count(S.buf) == S.gh,
  ("%d vs %d"):format(vim.api.nvim_buf_line_count(S.buf), S.gh))
local l1 = vim.api.nvim_buf_get_lines(S.buf, 0, 1, false)[1]
check("each line is one cell per grid column", #l1 == S.gw, ("%d vs %d"):format(#l1, S.gw))
check("grid matches what fit() returned", S.gw == GRID_W or S.gw == S.cols,
  ("gw=%d cols=%d"):format(S.gw, S.cols))

-- and every word must be reachable inside it
local bad
for _, w in ipairs(S.words) do
  if w.r < 1 or w.r > S.gh or w.c0 < 0 or w.c1 >= S.gw then
    bad = ("%q -> r%d c%d..%d (grid %dx%d)"):format(w.text, w.r, w.c0, w.c1, S.gw, S.gh)
    break
  end
end
check("every word sits inside the drawn grid", not bad, bad)
check("cursor landed on word 1", S.cur and S.cur.ord == 1)

-- a repaint after a highlight must re-place with the same contract
local before = placed.src
S.anchor, S.cur = S.words[1], S.words[2]
for _, k in ipairs(vim.api.nvim_buf_get_keymap(S.buf, "n")) do
  if k.lhs == "1" then k.callback() end
end
check("repaint produced a new composited png", placed.src ~= before, placed.src)
check("repaint kept conceal + full range", placed.opts.conceal == true and placed.opts.range[3] == S.gh)
check("highlight recorded", #S.highlights == 1)

-- page navigation, and the cross-page sidecar merge
check("page count detected", S.n_pages == 6, tostring(S.n_pages))
local p1_words, p1_hl = #S.words, #S.highlights
check("page 1 has a highlight before moving", p1_hl == 1)

V.page_step(1)
S = V._state()
check("moved to page 2", S.page == 2, tostring(S.page))
check("page 2 has its own text", #S.words ~= p1_words, ("%d vs %d"):format(#S.words, p1_words))
check("page 2 starts with no highlights", #S.highlights == 0, ("%d"):format(#S.highlights))
check("page 2 grid rebuilt", S.gw > 0 and S.gh > 0)
check("buffer resized for page 2", vim.api.nvim_buf_line_count(S.buf) == S.gh)

-- highlight page 2 too, then confirm both pages survive in one sidecar
S.anchor, S.cur = S.words[1], S.words[2]
for _, k in ipairs(vim.api.nvim_buf_get_keymap(S.buf, "n")) do
  if k.lhs == "3" then k.callback() end
end
local all = P.load_sidecar(pdf)
check("sidecar holds both pages", #all == 2, ("%d entries"):format(#all))
local pages = {}
for _, h in ipairs(all) do pages[h.page] = h.properties.color end
check("page 1 highlight preserved (yellow)", pages[1] == "yellow", tostring(pages[1]))
check("page 2 highlight added (red)", pages[2] == "red", tostring(pages[2]))

V.page_step(-1)
S = V._state()
check("back on page 1", S.page == 1)
check("page 1 highlight reloaded from disk", #S.highlights == 1, ("%d"):format(#S.highlights))

V.set_page(99)
check("forward clamp at the last page", V._state().page == 6, tostring(V._state().page))
V.set_page(0)
check("backward clamp at page 1", V._state().page == 1, tostring(V._state().page))

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
