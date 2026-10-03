-- Headless verification -- no UI, no plugins:
--   nvim --headless -u NONE -l tmp/prototype/check.lua [path/to.pdf] [page]
--
-- Asserts the round-trip that the whole design rests on:
--   buffer selection -> page-point rects -> back to buffer positions.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
package.path = here .. "/?.lua;" .. package.path
local P = require("pdfproto")

local pdf = arg[1] or vim.fn.expand("~/Desktop/Shock-Profile-Induced-By-Short-Laser-Pulses.pdf")
local pageno = tonumber(arg[2]) or 1

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(("  ok   %s"):format(name))
  else
    fail = fail + 1
    print(("  FAIL %s%s"):format(name, detail and ("  -- " .. detail) or ""))
  end
end

print(("pdfproto check: %s page %d"):format(pdf, pageno))

local page, err = P.extract_page(pdf, pageno)
if not page then
  print("FATAL: " .. err)
  os.exit(1)
end
print(("  page %.0f x %.0f pts, %d blocks, %d words")
  :format(page.width, page.height, #page.blocks, page.n_words))

check("page has words", page.n_words > 0)
check("page has sane dimensions", page.width > 100 and page.height > 100)

local lines, word_map = P.build_lines(page)
print(("  %d buffer rows"):format(#lines))
print(("  row 1: %s"):format((lines[1] or ""):sub(1, 70)))

check("buffer rows produced", #lines > 0)

-- every word span must slice its own text back out of the buffer line
local mismatch = nil
for row, spans in pairs(word_map) do
  for _, s in ipairs(spans) do
    local got = lines[row]:sub(s.c0 + 1, s.c1)
    if got ~= s.text then
      mismatch = ("row %d: map says %q, buffer has %q"):format(row, s.text, got)
      break
    end
  end
  if mismatch then break end
end
check("every word span slices back to its own text", not mismatch, mismatch)

-- monotonic, non-overlapping spans per row
local overlap = nil
for row, spans in pairs(word_map) do
  for i = 2, #spans do
    if spans[i].c0 < spans[i - 1].c1 then
      overlap = ("row %d word %d"):format(row, i)
      break
    end
  end
end
check("spans do not overlap", not overlap, overlap)

-- ROUND TRIP: select the first 5 words of the first populated row,
-- derive rects, then derive buffer positions back from those rects alone.
local target_row
for r = 1, #lines do
  if word_map[r] and #word_map[r] >= 3 then target_row = r break end
end

if not target_row then
  print("FATAL: no row with >= 3 words")
  os.exit(1)
end

local spans = word_map[target_row]
local last = math.min(5, #spans)
local sel_c0, sel_c1 = spans[1].c0, spans[last].c1 - 1
print(("  round-trip over row %d cols [%d,%d]: %q")
  :format(target_row, sel_c0, sel_c1, lines[target_row]:sub(sel_c0 + 1, sel_c1 + 1)))

-- replicate the selection -> rects step (mirrors rects_from_selection)
local rx1, ry1, rx2, ry2, texts = nil, nil, nil, nil, {}
for _, s in ipairs(spans) do
  if s.c0 <= sel_c1 and (s.c1 - 1) >= sel_c0 then
    rx1 = math.min(rx1 or s.x1, s.x1); ry1 = math.min(ry1 or s.y1, s.y1)
    rx2 = math.max(rx2 or s.x2, s.x2); ry2 = math.max(ry2 or s.y2, s.y2)
    table.insert(texts, s.text)
  end
end
local rects = { { x1 = rx1, y1 = ry1, x2 = rx2, y2 = ry2 } }
check("selection produced a rect", rx1 ~= nil)
check("rect has positive area", rx2 > rx1 and ry2 > ry1,
  rx1 and ("%.2f..%.2f x %.2f..%.2f"):format(rx1, rx2, ry1, ry2))

local back = P.positions_from_rects(word_map, rects)
check("rects map back to exactly one row", #back == 1, ("got %d"):format(#back))
if #back == 1 then
  check("recovered row matches", back[1].row == target_row,
    ("%d vs %d"):format(back[1].row, target_row))
  check("recovered start col matches", back[1].c0 == sel_c0,
    ("%d vs %d"):format(back[1].c0, sel_c0))
  check("recovered end col matches", back[1].c1 == sel_c1 + 1,
    ("%d vs %d"):format(back[1].c1, sel_c1 + 1))
end

-- JSON sidecar round-trip
local doc = { pdf = pdf, highlights = { {
  id = "test-uuid", page = pageno,
  position = { page = pageno, rects = rects,
    bounding = { x1 = rx1, y1 = ry1, x2 = rx2, y2 = ry2, width = page.width, height = page.height } },
  content = { text = table.concat(texts, " ") },
  properties = { color = "yellow" },
} } }
local decoded = vim.json.decode(vim.json.encode(doc))
check("json round-trips rects", math.abs(decoded.highlights[1].position.rects[1].x1 - rx1) < 1e-6)
local back2 = P.positions_from_rects(word_map, decoded.highlights[1].position.rects)
check("decoded rects still map to the same span",
  #back2 == 1 and back2[1].row == target_row and back2[1].c0 == sel_c0)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
