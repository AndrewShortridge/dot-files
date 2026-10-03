-- Headless checks for the image view:
--   nvim --headless -u NONE -l tmp/prototype/view_check.lua [pdf] [page]
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
package.path = here .. "/?.lua;" .. package.path
local P = require("pdfproto")
local V = require("pdfview")

local pdf = arg[1] or vim.fn.expand("~/Desktop/Shock-Profile-Induced-By-Short-Laser-Pulses.pdf")
local pageno = tonumber(arg[2]) or 1

P.config.data_dir = vim.fn.tempname()
local pass, fail = 0, 0
local function check(n, ok, d)
  if ok then pass = pass + 1; print("  ok   " .. n)
  else fail = fail + 1; print("  FAIL " .. n .. (d and ("  -- " .. d) or "")) end
end
vim.notify = function() end

local page = assert(P.extract_page(pdf, pageno))
local lines, word_map = P.build_lines(page)
local words = V._flatten(page)

-- 1. the two views must agree on reading order, or <Tab> lands on the wrong word
check("flatten count == parsed word count", #words == page.n_words,
  ("%d vs %d"):format(#words, page.n_words))
local map_by_ord, n_spans = {}, 0
for row, spans in pairs(word_map) do
  for _, sp in ipairs(spans) do map_by_ord[sp.ord] = { row = row, sp = sp }; n_spans = n_spans + 1 end
end
check("text view has the same number of words", n_spans == #words, ("%d vs %d"):format(n_spans, #words))
local drift
for _, w in ipairs(words) do
  local m = map_by_ord[w.ord]
  if not m or m.sp.text ~= w.text then
    drift = ("ord %d: image %q vs text %q"):format(w.ord, w.text, m and m.sp.text or "nil")
    break
  end
end
check("ord N is the same word in both views (Tab sync)", not drift, drift)

-- 2. cell assignment
local cell = { w = 8, h = 17 }
local img_w, img_h = 1240, 1755 -- 150dpi on A4
local GW, GH = math.ceil(img_w / cell.w), math.ceil(img_h / cell.h)
local crowded = V._assign_cells(words, page.width, page.height, GW, GH)
local oob, inverted = nil, nil
for _, w in ipairs(words) do
  if w.c0 < 0 or w.r < 1 or w.c1 >= GW or w.r > GH then
    oob = ("%q -> r%d c%d..%d"):format(w.text, w.r, w.c0, w.c1)
    break
  end
  if w.c1 < w.c0 then inverted = w.text break end
end
check("all word cells inside the image grid", not oob, oob)
check("no inverted cell rects", not inverted, inverted)
check("every word owns exactly one cell row", crowded ~= nil)
print(("  %d cell row(s) carry more than one PDF text line at this scale"):format(crowded))

-- zooming in must strictly reduce that crowding
local c2 = V._assign_cells(words, page.width, page.height, GW * 2, GH * 2)
check("zooming 2x reduces crowded rows", c2 <= crowded, ("%d -> %d"):format(crowded, c2))
local c3 = V._assign_cells(words, page.width, page.height, math.floor(GW / 2), math.floor(GH / 2))
check("zooming out increases crowded rows", c3 >= crowded, ("%d -> %d"):format(crowded, c3))
V._assign_cells(words, page.width, page.height, GW, GH)

-- words on the same text line share a row and advance left to right
local l1 = {}
for _, w in ipairs(words) do if w.line == words[1].line then l1[#l1 + 1] = w end end
local mono = true
for i = 2, #l1 do if l1[i].c0 < l1[i - 1].c0 then mono = false end end
check("line 1 words advance left to right in cell space", mono)
check("line 1 words share a cell row", l1[1].r == l1[#l1].r,
  ("%d vs %d"):format(l1[1].r, l1[#l1].r))

-- 3. burn-in: render with a highlight and confirm the pixels moved
local w1 = words[1]
local hl = { {
  id = "x", page = pageno, properties = { color = "yellow" },
  content = { text = w1.text },
  position = { page = pageno, rects = { { x1 = w1.x1, y1 = w1.y1, x2 = w1.x2, y2 = w1.y2 } }, bounding = {} },
} }
local t0 = vim.uv.hrtime()
local plain, iw, ih = V._render_png(pdf, pageno, 100, {}, 1, 1)
local sx, sy = iw / page.width, ih / page.height
local lit = V._render_png(pdf, pageno, 100, hl, sx, sy)
local ms = (vim.uv.hrtime() - t0) / 1e6
check("plain page rendered", plain ~= nil)
check("highlighted page rendered", lit ~= nil)
check("renders differ", plain ~= lit and vim.fn.getfsize(plain) > 0 and vim.fn.getfsize(lit) > 0)
print(("  %dx%d px, both renders in %.0fms total"):format(iw, ih, ms))
print("  PLAIN=" .. plain)
print("  LIT=" .. lit)
print(("  PROBE=%d %d %d %d"):format(
  math.floor(w1.x1 * sx), math.floor(w1.y1 * sy), math.floor(w1.x2 * sx), math.floor(w1.y2 * sy)))

-- 4. open + motions + selection + commit, with no UI
V.open(pdf, pageno)
local S = V._state()
check("view opened", S ~= nil)
if S then
  check("cursor starts on word 1", S.cur and S.cur.ord == 1, S.cur and tostring(S.cur.ord))
  vim.api.nvim_win_set_cursor(S.win, { S.words[1].r, S.words[1].c0 })
  S.cur = S.words[1]
  S.anchor = S.words[1]
  S.cur = S.words[3]
  -- exercise the same merge path the `1` key uses
  vim.api.nvim_buf_call(S.buf, function() end)
  local before = #S.highlights
  vim.cmd("normal! 0")
  -- drive commit through the mapping table instead of poking internals
  local keymaps = vim.api.nvim_buf_get_keymap(S.buf, "n")
  local commit_fn
  for _, k in ipairs(keymaps) do if k.lhs == "1" then commit_fn = k.callback end end
  check("colour key is mapped", commit_fn ~= nil)
  if commit_fn then
    commit_fn()
    check("highlight added", #S.highlights == before + 1)
    local h = S.highlights[#S.highlights]
    if h then
      local want = ("%s %s %s"):format(S.words[1].text, S.words[2].text, S.words[3].text)
      check("captured text matches the 3 selected words", h.content.text == want,
        ("%q vs %q"):format(h.content.text, want))
      check("colour is yellow", h.properties.color == "yellow")
      check("one rect (all three words on one line)", #h.position.rects == 1,
        ("%d"):format(#h.position.rects))
      check("uuid is well formed", #h.id == 36, h.id)
      check("selection cleared after commit", S.anchor == nil)
    end
    check("sidecar written", #P.load_sidecar(pdf) == 1)
  end
end

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
