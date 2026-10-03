-- End-to-end smoke test of the interactive path, headless:
--   nvim --headless -u NONE -l tmp/prototype/smoke.lua [path/to.pdf] [page]
-- Opens the buffer, makes a real visual selection, highlights it, and checks
-- that extmarks, the JSON sidecar and the hls__ markdown all come out right.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
package.path = here .. "/?.lua;" .. package.path
local P = require("pdfproto")

local pdf = arg[1] or vim.fn.expand("~/Desktop/Shock-Profile-Induced-By-Short-Laser-Pulses.pdf")
local pageno = tonumber(arg[2]) or 1

-- isolate: never touch the real data dir
P.config.data_dir = vim.fn.tempname()
P.setup()

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then pass = pass + 1; print("  ok   " .. name)
  else fail = fail + 1; print("  FAIL " .. name .. (detail and ("  -- " .. detail) or "")) end
end

vim.notify = function() end -- quiet

P.open(pdf, pageno)
local st = P._state()
check("document opened", st ~= nil)
check("buffer is not modifiable", vim.bo[st.buf].modifiable == false)
check("starts with zero highlights", #st.highlights == 0)

-- find a row with several words and select the first three of them
local row
for r = 1, #st.lines do
  if st.word_map[r] and #st.word_map[r] >= 3 then row = r break end
end
local spans = st.word_map[row]
local c_start, c_end = spans[1].c0, spans[3].c1 - 1

vim.api.nvim_win_set_cursor(0, { row, c_start })
vim.api.nvim_feedkeys("v", "x", false)
vim.api.nvim_win_set_cursor(0, { row, c_end })
check("in visual mode", vim.fn.mode() == "v", "mode=" .. vim.fn.mode())

P.highlight("blue")

check("one highlight recorded", #st.highlights == 1, ("got %d"):format(#st.highlights))
local h = st.highlights[1]
if h then
  local want = ("%s %s %s"):format(spans[1].text, spans[2].text, spans[3].text)
  check("captured text matches selection", h.content.text == want,
    ("%q vs %q"):format(h.content.text, want))
  check("has a uuid", type(h.id) == "string" and #h.id == 36, tostring(h.id))
  check("page recorded", h.page == pageno)
  check("color recorded", h.properties.color == "blue")
  check("one rect for a one-row selection", #h.position.rects == 1)
  check("bounding carries page size",
    h.position.bounding.width == st.page_geom.width and h.position.bounding.height == st.page_geom.height)
end

local marks = vim.api.nvim_buf_get_extmarks(st.buf, vim.api.nvim_create_namespace("pdfproto"), 0, -1, { details = true })
check("extmark painted", #marks == 1, ("got %d"):format(#marks))
if marks[1] then
  check("extmark on the selected row", marks[1][2] == row - 1)
  check("extmark start col matches", marks[1][3] == c_start)
  check("extmark end col matches", marks[1][4].end_col == c_end + 1,
    ("%s vs %d"):format(tostring(marks[1][4].end_col), c_end + 1))
  check("extmark uses the blue group", marks[1][4].hl_group == "PdfProtoBlue", tostring(marks[1][4].hl_group))
end

-- persistence: reload the sidecar from disk and re-derive positions
local reloaded = P.load_sidecar(pdf)
check("sidecar persisted", #reloaded == 1)
if reloaded[1] then
  local back = P.positions_from_rects(st.word_map, reloaded[1].position.rects)
  check("reload re-derives the same span from geometry alone",
    #back == 1 and back[1].row == row and back[1].c0 == c_start and back[1].c1 == c_end + 1,
    back[1] and ("row %d [%d,%d)"):format(back[1].row, back[1].c0, back[1].c1) or "none")
end

-- deletion
vim.api.nvim_win_set_cursor(0, { row, c_start + 1 })
P.delete_at_cursor()
check("highlight deleted", #st.highlights == 0)
check("extmarks cleared",
  #vim.api.nvim_buf_get_extmarks(st.buf, vim.api.nvim_create_namespace("pdfproto"), 0, -1, {}) == 0)

-- markdown export (re-add one first)
table.insert(st.highlights, {
  id = "0f5d1c00-0000-4000-8000-000000000001", page = pageno,
  position = { page = pageno, rects = {}, bounding = {} },
  content = { text = "sample highlight" }, properties = { color = "yellow" },
})
local md = P.export_markdown()
local body = table.concat(vim.fn.readfile(md), "\n")
check("md has file:: property", body:match("file:: %["))
check("md has ls-type:: annotation", body:match("ls%-type:: annotation") ~= nil)
check("md has hl-page::", body:match("hl%-page:: " .. pageno) ~= nil)
check("md has hl-color::", body:match("hl%-color:: yellow") ~= nil)
check("md has id::", body:match("id:: 0f5d1c00") ~= nil)

print(("\n%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
