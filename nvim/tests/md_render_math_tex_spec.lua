-- Spec for andrew.utils.md_render_math_tex: TeX equations become cell-exact
-- coverage masks (Contract v2), made by real pdftex and mutool runs.
--
-- WHAT THIS IS GUARDING
--
-- 1. A picture is an 8-bit greyscale PNG of exactly `columns*cell_width` by
--    `rows*cell_height` pixels, black ink on white, with its
--    "\nmdmath <columns> <rows> <scale>\n" record after IEND; an inline one is
--    always one row, shrunk to fit when it is taller. Sizes are those the
--    coloured pictures had before the masks.
-- 2. No colour anywhere: a look with a foreground is the same picture.
-- 3. One broken equation fails alone, with TeX's reason (`failure_of`); a run
--    that dies with nobody to blame is halved until the culprit is alone.
--    Half-typed TeX fails without a process at all.
-- 4. `on_settled` runs once per request, never inside `request`, also when
--    nothing had to be made.
-- 5. A second session finds what the first made on disk without running
--    anything.
-- 6. One batch at a time; what is asked meanwhile waits and goes in one
--    batch. Pages drawn by several mutool processes are the same files as
--    drawn by one.
-- 7. A run that never ends (2 s) or prints without end (stdout or stderr)
--    is killed, and only its equation fails.
-- 8. Something wrong with the environment (pdftex gone, cache not writable,
--    format will not build) is nil, not false, makes `is_available()` false
--    with a reason, warns once, and `retry()` recovers.
-- 9. The standby pdfTeX: used by the next batch, replaced after, stopped when
--    idle and on VimLeavePre with no process left; without FFI the runs are
--    plain spawns.
-- 10. Nothing is written outside the cache directory: not by TeX on behalf of
--     note content, not by kpathsea (`~/.texlive<year>`) for a missing font.
-- 11. Maintenance (on a worker thread) prunes old pictures beyond the budget,
--     keeps young and used ones, removes older layouts.
-- 12. Display environments (`align`, `\tag`) and Unicode in math typeset; a
--     glyph a font lacks is a failure, never a silently wrong picture.
--
-- Needs pdftex and mutool; says SKIP and passes without them. Takes ~18 s.
--
-- Run with: nvim --headless -u NONE -l tests/md_render_math_tex_spec.lua

local _H =
  dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local assert_eq, assert_true = _H.assert_eq, _H.assert_true

--- What a test started that must end even when it fails (child processes,
--- the directories they use): run after each test, whatever happened. A
--- failed kill -9 case once left a 38 MB pdfTeX for good.
---@type fun()[]
local cleanups = {}

---@param name string
---@param body fun()
local function test(name, body)
  _H.test(name, function()
    local is_done, problem = pcall(body)
    for index = #cleanups, 1, -1 do
      pcall(cleanups[index])
    end
    cleanups = {}
    if not is_done then
      error(problem, 0)
    end
  end)
end

local CONFIG_DIRECTORY = vim.fn.stdpath("config")
package.path = CONFIG_DIRECTORY .. "/lua/?.lua;" .. package.path

local MODULE_NAME = "andrew.utils.md_render_math_tex"

if vim.fn.executable("pdftex") == 0 or vim.fn.executable("mutool") == 0 then
  io.stdout:write("  SKIP: pdftex or mutool is not installed\n")
  _H.finish()
  return
end

-- Everything lives under one scratch root; HOME and the working directory
-- point into it too, so that a write anywhere but the cache shows up.
local scratch_root = vim.fn.tempname()
local cache_directory = scratch_root .. "/cache"
local scratch_home = scratch_root .. "/home"
local scratch_working_directory = scratch_root .. "/cwd"
for _, directory in ipairs({ scratch_home, scratch_working_directory }) do
  vim.fn.mkdir(directory, "p")
end
local real_home = vim.env.HOME
vim.env.HOME = scratch_home
vim.fn.chdir(scratch_working_directory)
-- With `openout_any=p` TeX may still write anywhere under TEXMFOUTPUT, so a
-- user who has it set must not widen the sandbox.
local real_texmfoutput = vim.env.TEXMFOUTPUT
vim.env.TEXMFOUTPUT = scratch_root

-- Every process the module starts goes through vim.system. A standby is a
-- pdftex started in a directory whose job.tex is a FIFO.
local original_system = vim.system
---@type { command: string[], is_standby: boolean, pid: integer? }[]
local spawned = {}
local processes_alive = 0
local most_processes_alive = 0
--- When it answers true for a command, starting it fails (as `vim.system`
--- does for a missing or unrunnable program).
---@type (fun(command: string[]): boolean)?
local refuse_spawn
---@diagnostic disable-next-line: duplicate-set-field
vim.system = function(command, options, on_exit)
  if refuse_spawn and refuse_spawn(command) then
    error("ENOENT: refused by the spec: " .. command[1])
  end
  local job_file = options and options.cwd and vim.uv.fs_lstat(options.cwd .. "/job.tex")
  local record = { command = command, is_standby = job_file and job_file.type == "fifo" or false }
  spawned[#spawned + 1] = record
  processes_alive = processes_alive + 1
  most_processes_alive = math.max(most_processes_alive, processes_alive)
  local process = original_system(command, options, function(result)
    processes_alive = processes_alive - 1
    if on_exit then
      on_exit(result)
    end
  end)
  record.pid = process.pid
  return process
end

--- Processes started that run `name`: TeX runs go through `/bin/sh -c 'ulimit
--- ...; exec "$@"'` and parallel mutools through a shell given "mutool" as
--- its argument, so the program is not always the first word.
---@param name string
---@param predicate? fun(record: table): boolean
---@return integer
local function count_spawned(name, predicate)
  local count = 0
  for _, record in ipairs(spawned) do
    if vim.tbl_contains(record.command, name) and (not predicate or predicate(record)) then
      count = count + 1
    end
  end
  return count
end

---@return integer
local function count_format_builds()
  return count_spawned("pdftex", function(record)
    return vim.tbl_contains(record.command, "-ini")
  end)
end

---@return integer
local function count_standbys()
  return count_spawned("pdftex", function(record)
    return record.is_standby
  end)
end

--- pdftex runs that were not a standby and not a format build.
---@return integer
local function count_plain_runs()
  return count_spawned("pdftex", function(record)
    return not record.is_standby and not vim.tbl_contains(record.command, "-ini")
  end)
end

--- Shells that started parallel mutools.
---@return integer
local function count_mutool_shells()
  return count_spawned("/bin/sh", function(record)
    return vim.tbl_contains(record.command, "mutool")
  end)
end

--- Stand-in programs, first on PATH until the returned function is called.
---@param programs table<string, string[]> name -> lines of a shell script
---@return fun() remove
local function fake_programs(programs)
  local directory = scratch_root .. "/fake-bin"
  vim.fn.mkdir(directory, "p")
  for name, lines in pairs(programs) do
    vim.fn.writefile(vim.list_extend({ "#!/bin/sh" }, lines), directory .. "/" .. name)
    vim.fn.setfperm(directory .. "/" .. name, "rwxr-xr-x")
  end
  local real_path = vim.env.PATH
  vim.env.PATH = directory .. ":" .. real_path
  return function()
    vim.env.PATH = real_path
    vim.fn.delete(directory, "rf")
  end
end

---@param milliseconds integer
local function let_run(milliseconds)
  vim.wait(milliseconds, function()
    return false
  end, 5)
end

---@param condition fun(): boolean
---@param milliseconds? integer
---@return boolean
local function wait_until(condition, milliseconds)
  return vim.wait(milliseconds or 5000, condition, 5)
end

--- What a session does on `:qa`: its VimLeavePre (the newest module
--- instance's; each `setup` replaces the autocmd of the one before).
local function end_session()
  vim.api.nvim_exec_autocmds("VimLeavePre", { group = "andrew_md_render_math_tex" })
  wait_until(function()
    return processes_alive == 0
  end)
end

--- A module instance with nothing in memory, as in a new session; the one
--- before ends first.
---@param directory string
---@param options? table more `setup` options
local function load_fresh_module(directory, options)
  if package.loaded[MODULE_NAME] then
    end_session()
  end
  package.loaded[MODULE_NAME] = nil
  local module = require(MODULE_NAME)
  module.setup(vim.tbl_extend("force", { cache_directory = directory }, options or {}))
  return module
end

--- A cache directory of its own, with the formats built so far (no rebuild).
---@param name string
---@return string
local function cache_with_formats(name)
  local directory = scratch_root .. "/" .. name
  vim.fn.mkdir(directory, "p")
  for _, file_name in ipairs(vim.fn.readdir(cache_directory)) do
    if file_name:match("%.fmt$") then
      vim.uv.fs_copyfile(cache_directory .. "/" .. file_name, directory .. "/" .. file_name)
    end
  end
  return directory
end

---@param path string
---@return string
local function read_bytes(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

---@param content string
---@param offset integer 1-based
---@return integer
local function big_endian(content, offset)
  local byte_1, byte_2, byte_3, byte_4 = content:byte(offset, offset + 3)
  return ((byte_1 * 256 + byte_2) * 256 + byte_3) * 256 + byte_4
end

---@class MathTexSpecRequest
---@field calls integer times on_settled ran
---@field was_called_inside_request boolean
---@field milliseconds number until it settled

--- Request and wait until settled, then a little longer to catch a second call.
---@return MathTexSpecRequest
local function request_and_wait(module, equations, look)
  local outcome = { calls = 0, was_called_inside_request = false }
  local has_returned = false
  local started = vim.uv.hrtime()
  module.request(equations, look, function()
    outcome.calls = outcome.calls + 1
    outcome.was_called_inside_request = outcome.was_called_inside_request or not has_returned
    outcome.milliseconds = outcome.milliseconds or (vim.uv.hrtime() - started) / 1e6
  end)
  has_returned = true
  wait_until(function()
    return outcome.calls > 0
  end, 20000)
  let_run(50)
  return outcome
end

local LOOK = { cell_width = 20, cell_height = 44 }

local T_M = { kind = "inline", tex = "T_m" }
local TALL_INLINE = { kind = "inline", tex = "R_{eq} = \\left(\\frac{3V}{4\\pi}\\right)^{1/3}" }
local RHO = { kind = "inline", tex = " \\rho(z) " }
local ALIGNED = {
  kind = "display",
  tex = "\\begin{aligned}\nE &= mc^2 \\\\\n\np &= \\gamma m v % momentum\n\\end{aligned}",
}
local MATRIX = { kind = "display", tex = "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}" }
local OPEN_FRACTION = { kind = "inline", tex = "\\frac{" }
local UNDEFINED_COMMAND = { kind = "inline", tex = "\\nosuchcommand x" }
local UNBALANCED = { kind = "inline", tex = "a}{b" }
local MISSING_RIGHT = { kind = "display", tex = "\\left( x" }

local GOOD = { T_M, TALL_INLINE, RHO, ALIGNED, MATRIX }
local BROKEN = { OPEN_FRACTION, UNDEFINED_COMMAND, UNBALANCED, MISSING_RIGHT }

local math_tex = load_fresh_module(cache_directory)

---@param module table
---@param equations table[]
---@return (table|false|nil)[] what `lookup` answers for each
local function lookup_each(module, equations)
  local answers = {}
  for index, equation in ipairs(equations) do
    answers[index] = module.lookup(equation, LOOK)
  end
  return answers
end

--- Makes `equations` alone, in a session and cache of their own (with a copy
--- of the format, to save building it), and asserts that each is byte for
--- byte the picture in `pictures`. That session ends before its cache goes (a
--- live standby's directory): `math_tex` is a new one afterwards.
---@param equations table[]
---@param pictures (table|false|nil)[] what `math_tex` made of them beside others
---@param cache_name string
---@param same_message string
local function assert_same_as_alone(equations, pictures, cache_name, same_message)
  local reference_cache = cache_with_formats(cache_name)
  local reference = load_fresh_module(reference_cache)
  request_and_wait(reference, equations, LOOK)
  for index, equation in ipairs(equations) do
    local alone = reference.lookup(equation, LOOK)
    assert_true(pictures[index] and alone, equation.tex .. " is a picture both ways:")
    assert_true(
      read_bytes(pictures[index].path) == read_bytes(alone.path),
      equation.tex .. same_message
    )
  end
  math_tex = load_fresh_module(cache_directory)
  vim.fn.delete(reference_cache, "rf")
end

--- How many files `work` opens with `io.open`, as the module reads pictures.
---@param work fun()
---@return integer
local function count_opens(work)
  local original_open = io.open
  local opens = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  io.open = function(...)
    opens = opens + 1
    return original_open(...)
  end
  work()
  io.open = original_open
  return opens
end

-- -----------------------------------------------------------------------------

test("half-typed TeX fails without a process, and says why", function()
  assert_eq(math_tex.lookup(OPEN_FRACTION, LOOK), false, "`\\frac{`:")
  assert_eq(math_tex.lookup(UNBALANCED, LOOK), false, "`a}{b`:")
  assert_eq(math_tex.lookup({ kind = "inline", tex = "  " }, LOOK), false, "blank:")
  assert_eq(math_tex.failure_of(OPEN_FRACTION, LOOK), "unbalanced braces", "reason:")
  assert_eq(math_tex.lookup(T_M, LOOK), nil, "`T_m`, not made yet:")
  assert_eq(math_tex.failure_of(T_M, LOOK), nil, "no reason for one not made:")
  -- No standby either: there is no format yet, and none is built for one.
  let_run(50)
  assert_eq(#spawned, 0, "processes started:")
end)

-- Broken ones between good ones: a failed equation that still made a PDF page
-- must not shift the pages of those after it.
local first_batch = request_and_wait(math_tex, {
  T_M,
  UNDEFINED_COMMAND,
  TALL_INLINE,
  MISSING_RIGHT,
  RHO,
  OPEN_FRACTION,
  ALIGNED,
  UNBALANCED,
  MATRIX,
}, LOOK)

test("a batch settles once, after request() has returned", function()
  assert_eq(first_batch.calls, 1, "on_settled calls:")
  assert_eq(first_batch.was_called_inside_request, false, "called inside request():")
end)

test("every picture is an 8-bit grey mask of exactly its cells, with its record", function()
  for _, equation in ipairs(GOOD) do
    local picture = math_tex.lookup(equation, LOOK)
    assert_true(picture, equation.tex .. " is a picture:")
    local content = read_bytes(picture.path)
    assert_eq(content:sub(13, 16), "IHDR", equation.tex .. " IHDR first:")
    assert_eq(big_endian(content, 17), picture.columns * LOOK.cell_width, equation.tex .. " width:")
    assert_eq(big_endian(content, 21), picture.rows * LOOK.cell_height, equation.tex .. " height:")
    assert_eq(content:byte(25), 8, equation.tex .. " bit depth:")
    assert_eq(content:byte(26), 0, equation.tex .. " colour type (grey):")
    assert_eq(content:byte(29), 0, equation.tex .. " interlace:")
    local _, iend_end = content:find("IEND....")
    assert_eq(
      content:sub(iend_end + 1),
      string.format("\nmdmath %d %d %s\n", picture.columns, picture.rows, picture.scale),
      equation.tex .. " record after IEND:"
    )
  end
end)

test("sizes are what the coloured pictures had before the masks", function()
  local function shape(equation)
    local picture = math_tex.lookup(equation, LOOK)
    return picture.columns .. "x" .. picture.rows .. " " .. picture.scale
  end
  -- Pinned from the pre-mask module at 20x44 cells (same TeX geometry).
  assert_eq(shape(T_M), "3x1 1", "T_m:")
  assert_eq(shape(RHO), "4x1 1", "rho(z):")
  assert_eq(shape(TALL_INLINE), "10x1 0.76523", "tall inline:")
  assert_eq(shape(MATRIX), "7x3 1", "pmatrix (display padding included):")
end)

test("inline pictures are one row; a tall one is shrunk, T_m is not", function()
  for _, equation in ipairs({ T_M, TALL_INLINE, RHO }) do
    assert_eq(math_tex.lookup(equation, LOOK).rows, 1, equation.tex .. " rows:")
  end
  assert_eq(math_tex.lookup(T_M, LOOK).scale, 1, "T_m scale:")
  local tall_scale = math_tex.lookup(TALL_INLINE, LOOK).scale
  assert_true(tall_scale < 1 and tall_scale > 0.5, "tall inline scale " .. tall_scale .. ":")
end)

test("display pictures are whole rows, more than one", function()
  assert_true(math_tex.lookup(ALIGNED, LOOK).rows >= 2, "aligned rows:")
  assert_true(math_tex.lookup(MATRIX, LOOK).rows >= 2, "pmatrix rows:")
end)

test("broken equations fail with TeX's reason and their batch-mates do not", function()
  for _, equation in ipairs(BROKEN) do
    assert_eq(math_tex.lookup(equation, LOOK), false, equation.tex .. ":")
    assert_true(math_tex.failure_of(equation, LOOK), equation.tex .. " has a reason:")
  end
  local reason = math_tex.failure_of(UNDEFINED_COMMAND, LOOK)
  assert_true(reason:find("Undefined control sequence", 1, true), "reason: " .. reason)
  assert_true(reason:find("\\nosuchcommand", 1, true), "where: " .. reason)
  assert_eq(math_tex.failure_of(T_M, LOOK), nil, "a picture has no reason:")
  -- Each good one was made in the same run as the broken ones.
  assert_eq(count_spawned("mutool"), 1, "mutool runs:")
end)

test("the colour is not part of a picture", function()
  local spawned_before = #spawned
  local in_red = { cell_width = 20, cell_height = 44, foreground = "FF0000" }
  assert_eq(math_tex.lookup(T_M, in_red), math_tex.lookup(T_M, LOOK), "same picture:")
  local outcome = request_and_wait(math_tex, GOOD, in_red)
  assert_eq(outcome.calls, 1, "on_settled calls:")
  assert_eq(#spawned, spawned_before, "processes started:")
end)

test("a request for what is already settled still calls back once, later", function()
  local spawned_before = #spawned
  local outcome = request_and_wait(math_tex, vim.list_extend(vim.deepcopy(GOOD), BROKEN), LOOK)
  assert_eq(outcome.calls, 1, "on_settled calls:")
  assert_eq(outcome.was_called_inside_request, false, "called inside request():")
  assert_eq(#spawned, spawned_before, "processes started:")
end)

test("lookup of a known picture does no I/O and is cheap", function()
  local microseconds
  local opens = count_opens(function()
    local started = vim.uv.hrtime()
    for _ = 1, 10000 do
      math_tex.lookup(T_M, LOOK)
    end
    microseconds = (vim.uv.hrtime() - started) / 1e3 / 10000
  end)
  assert_eq(opens, 0, "files opened:")
  assert_true(microseconds < 20, string.format("%.2f us per lookup:", microseconds))
end)

test("a second session on the same cache serves lookup from disk without a process", function()
  local first_session = math_tex
  local pictures = lookup_each(first_session, GOOD)
  local second_session = load_fresh_module(cache_directory)
  local spawned_before = #spawned
  for index, equation in ipairs(GOOD) do
    local picture = second_session.lookup(equation, LOOK)
    assert_true(picture, equation.tex .. " is a picture:")
    assert_eq(vim.deep_equal(picture, pictures[index]), true, equation.tex .. " same as made:")
  end
  local outcome = request_and_wait(second_session, GOOD, LOOK)
  assert_eq(outcome.calls, 1, "on_settled calls:")
  assert_eq(#spawned, spawned_before, "processes started:")
  math_tex = second_session
end)

test("overlapping requests are one batch at a time, coalesced, in order", function()
  local look = { cell_width = 10, cell_height = 23 }
  local mutool_runs_before = count_spawned("mutool")
  most_processes_alive = processes_alive
  local order = {}
  local calls = { 0, 0, 0 }
  math_tex.request(
    { { kind = "inline", tex = "x_1" }, { kind = "inline", tex = "y_1" } },
    look,
    function()
      calls[1] = calls[1] + 1
      order[#order + 1] = 1
    end
  )
  -- The other two arrive while the first run is going.
  math_tex.request({ { kind = "inline", tex = "x_2" } }, look, function()
    calls[2] = calls[2] + 1
    order[#order + 1] = 2
  end)
  math_tex.request(
    { { kind = "inline", tex = "x_3" }, { kind = "inline", tex = "x_1" } },
    look,
    function()
      calls[3] = calls[3] + 1
      order[#order + 1] = 3
    end
  )
  wait_until(function()
    return calls[1] > 0 and calls[2] > 0 and calls[3] > 0
  end, 20000)
  let_run(50)
  assert_eq(table.concat(calls, " "), "1 1 1", "on_settled calls per request:")
  assert_eq(table.concat(order, " "), "1 2 3", "order:")
  -- One run (pdftex or mutool) at a time, beside at most one standby.
  assert_true(most_processes_alive <= 2, "most processes alive at once: " .. most_processes_alive)
  assert_eq(count_spawned("mutool") - mutool_runs_before, 2, "batches for three requests:")
end)

test("another cell size is another picture", function()
  local other_cell = { cell_width = 10, cell_height = 23 }
  request_and_wait(math_tex, { T_M }, other_cell)
  local original = math_tex.lookup(T_M, LOOK)
  local smaller = math_tex.lookup(T_M, other_cell)
  assert_true(smaller, "made:")
  assert_true(smaller.path ~= original.path, "another file:")
  local content = read_bytes(smaller.path)
  assert_eq(
    big_endian(content, 17) .. "x" .. big_endian(content, 21),
    smaller.columns * 10 .. "x23",
    "size:"
  )
end)

test("an equation that never ends is killed at the time limit and fails alone", function()
  -- 500 ms instead of 2 s, to keep the spec short; the same code path.
  local session = load_fresh_module(cache_directory, { timeout_milliseconds = 500 })
  local endless = { kind = "inline", tex = "\\def\\x{\\x}\\x" }
  local neighbours = { { kind = "inline", tex = "n_1" }, { kind = "inline", tex = "n_2" } }
  local outcome = request_and_wait(session, { neighbours[1], endless, neighbours[2] }, LOOK)
  assert_eq(outcome.calls, 1, "on_settled calls:")
  assert_eq(session.lookup(endless, LOOK), false, "the endless one:")
  assert_eq(session.failure_of(endless, LOOK), "killed: ran longer than 500 ms", "reason:")
  assert_true(session.lookup(neighbours[1], LOOK), "the one before it is a picture:")
  assert_true(session.lookup(neighbours[2], LOOK), "the one after it is a picture:")
  assert_true(
    outcome.milliseconds > 450 and outcome.milliseconds < 2500,
    string.format("settled after %.0f ms:", outcome.milliseconds)
  )
  math_tex = load_fresh_module(cache_directory)
end)

test("an equation that prints without end is killed at the output cap and fails alone", function()
  local flood = {
    kind = "inline",
    tex = "\\def\\x{\\message{" .. string.rep("spam", 50) .. "}\\x}\\x",
  }
  local neighbours = { { kind = "inline", tex = "n_3" }, { kind = "inline", tex = "n_4" } }
  local outcome = request_and_wait(math_tex, { neighbours[1], flood, neighbours[2] }, LOOK)
  assert_eq(outcome.calls, 1, "on_settled calls:")
  assert_eq(math_tex.lookup(flood, LOOK), false, "the flooding one:")
  assert_true(math_tex.failure_of(flood, LOOK):find("^killed: printed"), "reason:")
  assert_true(math_tex.lookup(neighbours[1], LOOK), "the one before it is a picture:")
  assert_true(math_tex.lookup(neighbours[2], LOOK), "the one after it is a picture:")
  -- It prints ~30 MB a second: the time limit would let 60 MB through.
  assert_true(
    outcome.milliseconds < 1500,
    string.format("settled in %.0f ms, well before the time limit:", outcome.milliseconds)
  )
end)

test("an equation that floods stderr is killed at the same cap", function()
  -- `openin_any=p` refuses the path and says so on stderr, every time.
  local flood = { kind = "inline", tex = "\\def\\x{\\openin1=/etc/passwd \\x}\\x" }
  local neighbour = { kind = "inline", tex = "n_5" }
  local heap_before = collectgarbage("count")
  local outcome = request_and_wait(math_tex, { neighbour, flood }, LOOK)
  assert_eq(math_tex.lookup(flood, LOOK), false, "the flooding one:")
  assert_true(math_tex.failure_of(flood, LOOK):find("^killed: printed"), "reason:")
  assert_true(math_tex.lookup(neighbour, LOOK), "its neighbour:")
  assert_true(
    outcome.milliseconds < 1500,
    string.format("settled in %.0f ms, well before the time limit:", outcome.milliseconds)
  )
  assert_true(
    collectgarbage("count") - heap_before < 16 * 1024,
    "Lua heap grew by " .. math.floor(collectgarbage("count") - heap_before) .. " kB:"
  )
end)

test("nothing is written outside the cache directory", function()
  local outside = scratch_root .. "/written-by-tex"
  local hostile = {
    { kind = "inline", tex = "\\immediate\\write18{touch " .. outside .. "} a" },
    { kind = "inline", tex = "\\immediate\\openout1=" .. outside .. " \\immediate\\write1{x} b" },
    { kind = "inline", tex = "\\immediate\\openout1=../escaped \\immediate\\write1{x} c" },
    -- A missing font: without MKTEXTFM=0 kpathsea runs mktextfm, which creates
    -- ~/.texlive<year>/texmf-var/fonts/tfm/...
    { kind = "inline", tex = "\\font\\missing=nosuchfont \\missing d" },
    { kind = "inline", tex = "e" },
  }
  request_and_wait(math_tex, hostile, LOOK)
  assert_true(math_tex.lookup(hostile[5], LOOK), "the harmless one is a picture:")
  assert_eq(vim.fn.filereadable(outside), 0, "file named by note content:")
  assert_eq(table.concat(vim.fn.readdir(scratch_root), " "), "cache cwd home", "scratch root:")
  assert_eq(#vim.fn.readdir(scratch_home), 0, "entries in HOME:")
  assert_eq(#vim.fn.readdir(scratch_working_directory), 0, "entries in the working directory:")
  local in_cache = vim.fn.readdir(cache_directory)
  assert_eq(#in_cache, 3, "cache entries (" .. table.concat(in_cache, " ") .. "):")
  assert_true(in_cache[1]:match("^format%-v%d+%-%x+%.fmt$"), "the format:")
  assert_eq(in_cache[2] .. " " .. in_cache[3], "masks run", "the two directories:")
  for _, name in ipairs(vim.fn.readdir(cache_directory .. "/masks")) do
    assert_true(name:match("^%x+%.png$"), "only pictures in masks/: " .. name)
  end
  -- At most the parked standby's directory is left in run/.
  assert_true(#vim.fn.readdir(cache_directory .. "/run") <= 1, "run directories left:")
end)

test("what one equation does globally never shows in another's picture", function()
  local victims = {
    { kind = "inline", tex = "\\alpha" },
    { kind = "inline", tex = "z^{2}" },
  }
  request_and_wait(math_tex, {
    { kind = "inline", tex = "\\gdef\\alpha{WWWWWWWWWW}x" },
    victims[1],
    { kind = "inline", tex = "\\global\\catcode`\\^=12 y" },
    victims[2],
  }, LOOK)
  assert_same_as_alone(
    victims,
    lookup_each(math_tex, victims),
    "reference-cache",
    " made after the others is the same as made alone:"
  )
end)

test("a run with a page it did not report is not trusted", function()
  -- Ships a page of the very size the equation's own will have, ahead of
  -- it: without the check, the picture of `x` would be that page, a `W`.
  local extra_page = {
    kind = "inline",
    tex = "\\pdfpagewidth=39.75\\csname md@px\\endcsname "
      .. "\\pdfpageheight=43.75\\csname md@px\\endcsname "
      .. "\\csname tex_shipout:D\\endcsname\\hbox{W}x",
  }
  request_and_wait(math_tex, { extra_page }, LOOK)
  assert_eq(math_tex.lookup(extra_page, LOOK), false, "the one shipping a page of its own:")
end)

test("a run that dies with nobody to blame is halved until the culprit is alone", function()
  -- tcrm1000 has metrics but no Type 1 file: pdfTeX finds out only when it
  -- closes the PDF, after every equation ran clean.
  local culprit = { kind = "inline", tex = "\\hbox{\\font\\x=tcrm1000 \\x\\char181}" }
  local innocents = {}
  for index = 1, 5 do
    innocents[index] = { kind = "inline", tex = "h_{" .. index .. "}" }
  end
  local batch = vim.list_extend(
    { innocents[1], innocents[2], culprit },
    { innocents[3], innocents[4], innocents[5] }
  )
  local plain_runs_before = count_plain_runs() + count_standbys()
  request_and_wait(math_tex, batch, LOOK)
  assert_eq(math_tex.lookup(culprit, LOOK), false, "the culprit:")
  assert_true(
    math_tex.failure_of(culprit, LOOK):find("tcrm1000", 1, true),
    "reason names the font:"
  )
  for _, innocent in ipairs(innocents) do
    assert_true(math_tex.lookup(innocent, LOOK), innocent.tex .. " is a picture:")
  end
  -- 6 equations: whole, then halves of 3, then of 2 and 1 -- not one run per
  -- innocent.
  local runs = count_plain_runs() + count_standbys() - plain_runs_before
  assert_true(runs <= 6, "pdftex runs: " .. runs)
end)

test("align, equation, gather and \\tag typeset as display pictures", function()
  local displays = {
    { kind = "display", tex = "\\begin{align}\na &= b + c \\\\\nd &= e\n\\end{align}" },
    { kind = "display", tex = "\\begin{align*} x &= 1 \\tag{3.1} \\end{align*}" },
    { kind = "display", tex = "\\begin{equation} E = mc^2 \\end{equation}" },
    { kind = "display", tex = "\\begin{gather} a \\\\ b \\end{gather}" },
    { kind = "display", tex = "F = ma \\tag{2}" },
  }
  request_and_wait(math_tex, displays, LOOK)
  for _, display in ipairs(displays) do
    assert_true(
      math_tex.lookup(display, LOOK),
      display.tex .. ": " .. tostring(math_tex.failure_of(display, LOOK))
    )
  end
  assert_true(math_tex.lookup(displays[1], LOOK).rows >= 2, "align rows:")
  -- `\tag` adds the label beside it.
  local tagged = math_tex.lookup(displays[5], LOOK)
  request_and_wait(math_tex, { { kind = "display", tex = "F = ma" } }, LOOK)
  local untagged = math_tex.lookup({ kind = "display", tex = "F = ma" }, LOOK)
  assert_true(tagged.columns > untagged.columns, "tagged is wider:")
end)

test("Unicode in math typesets, or fails; a glyph is never dropped silently", function()
  local times = { kind = "inline", tex = "3 × 10^5" }
  local dropped = { kind = "inline", tex = "310^5" }
  local greek = { kind = "inline", tex = "α_i + β² = ρ₀ ≤ ∞" }
  local unknown = { kind = "inline", tex = "☃" }
  -- OT1 Computer Modern has no glyph 200: pdfTeX used to leave it out.
  local lost = { kind = "inline", tex = "x\\text{\\char200}" }
  -- inputenc makes these text commands; in a math font their slot is another
  -- glyph (`—` was drawn as `|`, `“` as `\`, `ł` as `l`).
  local text_only = {}
  for _, character in ipairs({ "—", "“", "ł", "¿", "℧", "\u{200C}" }) do
    text_only[#text_only + 1] = { kind = "inline", tex = "x " .. character .. " y" }
  end
  local in_text = { kind = "inline", tex = "\\text{x—y “z”}" }
  local angstrom = { kind = "inline", tex = "5\\,\\AA" }
  request_and_wait(
    math_tex,
    vim.list_extend({ times, dropped, greek, unknown, lost, in_text, angstrom }, text_only),
    LOOK
  )
  assert_true(math_tex.lookup(times, LOOK), "× typesets:")
  assert_true(
    math_tex.lookup(times, LOOK).columns > math_tex.lookup(dropped, LOOK).columns,
    "× is drawn (wider than without it):"
  )
  assert_true(math_tex.lookup(greek, LOOK), "Greek, ², ₀, ≤, ∞ typeset:")
  assert_eq(math_tex.lookup(unknown, LOOK), false, "a character outside the table:")
  assert_true(math_tex.failure_of(unknown, LOOK):find("Unicode", 1, true), "its reason:")
  assert_eq(math_tex.lookup(lost, LOOK), false, "a glyph the font lacks:")
  for _, equation in ipairs(text_only) do
    assert_eq(math_tex.lookup(equation, LOOK), false, equation.tex .. " (a text symbol in math):")
  end
  assert_true(
    math_tex.failure_of(text_only[1], LOOK):find("invalid in math mode", 1, true),
    "reason: " .. tostring(math_tex.failure_of(text_only[1], LOOK))
  )
  assert_true(math_tex.lookup(in_text, LOOK), "the same in \\text typesets:")
  assert_true(math_tex.lookup(angstrom, LOOK), "\\AA in math typesets:")
end)

test("pages drawn by several mutool processes are the same files as by one", function()
  local equations = {}
  for index = 1, 40 do
    equations[index] = { kind = "inline", tex = "q_{" .. index .. "} + \\sqrt{" .. index .. "}" }
  end
  local shell_runs_before = count_mutool_shells()
  request_and_wait(math_tex, equations, LOOK)
  local shell_runs = count_mutool_shells() - shell_runs_before
  if (vim.uv.available_parallelism() or 1) > 2 then
    assert_eq(shell_runs, 1, "one shell started the mutools:")
  end
  -- The same, five at a time (one mutool each), in a cache of their own.
  local serial_cache = cache_with_formats("serial-cache")
  local parallel_session = math_tex
  local serial = load_fresh_module(serial_cache)
  for first = 1, #equations, 5 do
    request_and_wait(serial, vim.list_slice(equations, first, first + 4), LOOK)
  end
  for _, equation in ipairs(equations) do
    local in_parallel = parallel_session.lookup(equation, LOOK)
    local alone = serial.lookup(equation, LOOK)
    assert_true(in_parallel and alone, equation.tex .. " made both ways:")
    assert_true(
      read_bytes(in_parallel.path) == read_bytes(alone.path),
      equation.tex .. " same bytes:"
    )
  end
  math_tex = load_fresh_module(cache_directory)
  vim.fn.delete(serial_cache, "rf")
end)

test("the standby is used, replaced, stopped when idle and on VimLeavePre", function()
  local session = load_fresh_module(cache_directory, { standby_idle_milliseconds = 600 })
  local standbys_before, plain_before = count_standbys(), count_plain_runs()
  -- A miss is the evidence of need: a standby starts (the format is there).
  assert_eq(session.lookup({ kind = "inline", tex = "s_{0}" }, LOOK), nil, "a miss:")
  assert_true(
    wait_until(function()
      return count_standbys() - standbys_before == 1
    end, 2000),
    "a standby started after the miss:"
  )
  let_run(300)
  request_and_wait(session, { { kind = "inline", tex = "s_{0}" } }, LOOK)
  assert_true(session.lookup({ kind = "inline", tex = "s_{0}" }, LOOK), "made by the standby:")
  assert_eq(count_plain_runs() - plain_before, 0, "plain pdftex runs:")
  assert_true(
    wait_until(function()
      return count_standbys() - standbys_before == 2
    end, 2000),
    "replaced right after use:"
  )
  -- Nothing missing for two idle periods: stopped, no process left.
  assert_true(
    wait_until(function()
      return processes_alive == 0
    end, 3000),
    "processes alive after the idle stop: " .. processes_alive
  )
  local standby_pid
  for _, record in ipairs(spawned) do
    if record.is_standby then
      standby_pid = record.pid
    end
  end
  assert_true(vim.uv.kill(standby_pid, 0) ~= 0, "the standby's pid is gone:")
  wait_until(function()
    return #vim.fn.readdir(cache_directory .. "/run") == 0
  end, 2000)
  assert_eq(#vim.fn.readdir(cache_directory .. "/run"), 0, "run directories left:")
  -- Another miss starts one again; VimLeavePre ends it.
  session.lookup({ kind = "inline", tex = "s_{1}" }, LOOK)
  assert_true(
    wait_until(function()
      return processes_alive == 1
    end, 2000),
    "a standby again:"
  )
  let_run(10)
  end_session()
  assert_eq(processes_alive, 0, "processes alive after VimLeavePre:")
  assert_eq(#vim.fn.readdir(cache_directory .. "/run"), 0, "run directories after VimLeavePre:")
  math_tex = load_fresh_module(cache_directory)
end)

test("without the FIFO the runs are plain spawns", function()
  local real_ffi = package.loaded.ffi
  package.loaded.ffi = {
    cdef = function() end,
    C = setmetatable({}, {
      __index = function()
        error("no FFI here")
      end,
    }),
  }
  local session = load_fresh_module(cache_directory)
  local standbys_before, plain_before = count_standbys(), count_plain_runs()
  session.lookup({ kind = "inline", tex = "f_{1}" }, LOOK)
  let_run(100)
  request_and_wait(session, { { kind = "inline", tex = "f_{1}" } }, LOOK)
  request_and_wait(session, { { kind = "inline", tex = "f_{2}" } }, LOOK)
  package.loaded.ffi = real_ffi
  assert_true(session.lookup({ kind = "inline", tex = "f_{1}" }, LOOK), "f_1 is a picture:")
  assert_true(session.lookup({ kind = "inline", tex = "f_{2}" }, LOOK), "f_2 is a picture:")
  assert_eq(count_standbys() - standbys_before, 0, "standbys:")
  assert_eq(count_plain_runs() - plain_before, 2, "plain runs:")
  assert_eq(#vim.fn.readdir(cache_directory .. "/run"), 0, "run directories left:")
  math_tex = load_fresh_module(cache_directory)
end)

test("a mutool that failed leaves nothing on disk and no false", function()
  local real_mutool = vim.fn.exepath("mutool")
  local remove_fakes = fake_programs({ mutool = { '"' .. real_mutool .. '" "$@"', "exit 1" } })
  local equation = { kind = "inline", tex = "m_{cut}" }
  local session = load_fresh_module(cache_directory)
  local outcome = request_and_wait(session, { equation }, LOOK)
  remove_fakes()
  assert_eq(outcome.calls, 1, "on_settled calls:")
  assert_eq(session.lookup(equation, LOOK), nil, "after a mutool that exited 1:")
  assert_eq(session.failure_of(equation, LOOK), nil, "no TeX reason:")
  assert_eq(load_fresh_module(cache_directory).lookup(equation, LOOK), nil, "on disk:")
  math_tex = load_fresh_module(cache_directory)
end)

test("a mutool or its shell that cannot start: nil, unavailable with a reason", function()
  local original_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function() end
  -- One page: mutool itself. Forty: one shell starts several (see the
  -- parallel test below).
  local cases = {
    {
      label = "mutool",
      count = 1,
      refuse = function(command)
        return command[1] == "mutool"
      end,
    },
    {
      label = "the shell of the parallel mutools",
      count = 40,
      refuse = function(command)
        return command[1] == "/bin/sh" and vim.tbl_contains(command, "mutool")
      end,
    },
  }
  for _, case in ipairs(cases) do
    local session = load_fresh_module(cache_directory)
    local equations = {}
    for index = 1, case.count do
      equations[index] = { kind = "inline", tex = "n_{" .. index .. "}^{" .. case.count .. "}" }
    end
    refuse_spawn = case.refuse
    local outcome = request_and_wait(session, equations, LOOK)
    refuse_spawn = nil
    assert_eq(outcome.calls, 1, case.label .. ": on_settled calls:")
    for _, equation in ipairs(equations) do
      assert_eq(session.lookup(equation, LOOK), nil, case.label .. ": " .. equation.tex .. ":")
    end
    assert_eq(session.is_available(), false, case.label .. ": available:")
    local reason = session.status().reason or ""
    assert_true(reason:find("mutool did not start", 1, true), case.label .. ": reason: " .. reason)
    session.retry()
    request_and_wait(session, { equations[1] }, LOOK)
    assert_true(session.lookup(equations[1], LOOK), case.label .. ": after retry():")
  end
  vim.notify = original_notify
  math_tex = load_fresh_module(cache_directory)
end)

test("pdftex gone mid-session: nil, unavailable with a reason, retry() recovers", function()
  local session = load_fresh_module(cache_directory)
  assert_eq(session.is_available(), true, "available at first:")
  local real_path, original_notify = vim.env.PATH, vim.notify
  vim.env.PATH = "/nonexistent"
  vim.notify = function() end
  local equation = { kind = "inline", tex = "s_2" }
  local outcome = request_and_wait(session, { equation }, LOOK)
  vim.env.PATH, vim.notify = real_path, original_notify
  assert_eq(outcome.calls, 1, "on_settled calls:")
  assert_eq(session.lookup(equation, LOOK), nil, "s_2:")
  assert_eq(session.is_available(), false, "available afterwards:")
  assert_true(session.status().reason:find("pdftex did not start", 1, true), "reason:")
  local builds_before = count_format_builds()
  session.retry()
  assert_eq(session.is_available(), true, "available after retry():")
  request_and_wait(session, { equation }, LOOK)
  assert_true(session.lookup(equation, LOOK), "s_2, with pdftex back:")
  assert_eq(count_format_builds() - builds_before, 0, "format builds:")
  math_tex = session
end)

test("a cache that cannot be written: nil, unavailable, retry() recovers", function()
  local session = load_fresh_module(cache_directory)
  local equation = { kind = "inline", tex = "r_{o}" }
  local original_notify = vim.notify
  vim.notify = function() end
  vim.fn.setfperm(cache_directory .. "/run", "r-xr-xr-x")
  local outcome = request_and_wait(session, { equation }, LOOK)
  vim.fn.setfperm(cache_directory .. "/run", "rwxr-xr-x")
  vim.notify = original_notify
  assert_eq(outcome.calls, 1, "on_settled calls:")
  assert_eq(session.lookup(equation, LOOK), nil, "r_o:")
  assert_eq(session.is_available(), false, "available:")
  assert_true(
    session.status().reason:find("cannot", 1, true),
    "reason: " .. tostring(session.status().reason)
  )
  session.retry()
  request_and_wait(session, { equation }, LOOK)
  assert_true(session.lookup(equation, LOOK), "made after retry():")
  math_tex = session
end)

test("a failed format build: nil, warns once, not tried again until retry()", function()
  local remove_fakes = fake_programs({ pdftex = { "echo '! I cannot build anything.'", "exit 1" } })
  local warnings = {}
  local original_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(message, level)
    warnings[#warnings + 1] = { message = message, level = level }
  end

  local builds_before = count_format_builds()
  local broken_session = load_fresh_module(scratch_root .. "/cwd/broken-cache")
  local equations = { { kind = "inline", tex = "u_1" }, { kind = "inline", tex = "u_2" } }
  local was_available_before = broken_session.is_available()
  local first = request_and_wait(broken_session, equations, LOOK)
  local builds_by_first = count_format_builds() - builds_before
  local second = request_and_wait(broken_session, { { kind = "inline", tex = "u_3" } }, LOOK)
  local builds_by_second = count_format_builds() - builds_before - builds_by_first
  local reason = broken_session.status().reason
  broken_session.retry()
  request_and_wait(broken_session, { { kind = "inline", tex = "u_3" } }, LOOK)
  local builds_after_retry = count_format_builds()
    - builds_before
    - builds_by_first
    - builds_by_second

  vim.notify = original_notify
  remove_fakes()
  end_session()
  vim.fn.delete(scratch_root .. "/cwd/broken-cache", "rf")

  assert_eq(first.calls .. " " .. second.calls, "1 1", "on_settled calls:")
  assert_eq(was_available_before, true, "available before the build:")
  assert_eq(broken_session.lookup(equations[1], LOOK), nil, "u_1:")
  assert_eq(broken_session.lookup(equations[2], LOOK), nil, "u_2:")
  assert_eq(broken_session.failure_of(equations[1], LOOK), nil, "no TeX reason for u_1:")
  assert_true(reason:find("I cannot build anything", 1, true), "reason: " .. tostring(reason))
  assert_eq(#warnings, 2, "warnings (one, and one after retry):")
  assert_eq(warnings[1].level, vim.log.levels.WARN, "warning level:")
  assert_eq(builds_by_first, 1, "format builds tried by the first request:")
  assert_eq(builds_by_second, 0, "format builds tried by the second request:")
  assert_eq(builds_after_retry, 1, "format builds after retry():")
  math_tex = load_fresh_module(cache_directory)
end)

test("a preamble that prints without end fails the build fast, with a reason", function()
  local preamble = scratch_root .. "/flood-preamble.tex"
  vim.fn.writefile({ "\\def\\x{\\message{flood flood flood flood}\\x}\\x" }, preamble)
  vim.g.md_render_math_preamble = preamble
  local original_notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function() end
  local flood_cache = scratch_root .. "/flood-cache"
  local session = load_fresh_module(flood_cache)
  local equation = { kind = "inline", tex = "f_{lood}" }
  local outcome = request_and_wait(session, { equation }, LOOK)
  vim.notify = original_notify
  vim.g.md_render_math_preamble = nil
  assert_eq(outcome.calls, 1, "settles:")
  assert_true(
    outcome.milliseconds < 5000,
    string.format("settled after %.0f ms:", outcome.milliseconds)
  )
  assert_eq(session.lookup(equation, LOOK), nil, "no picture:")
  assert_eq(session.is_available(), false, "unavailable:")
  local reason = session.status().reason or ""
  assert_true(reason:find("printed without end", 1, true), "reason: " .. reason)
  math_tex = load_fresh_module(cache_directory)
  vim.fn.delete(flood_cache, "rf")
end)

test("forget: the next lookup looks on disk again and it can be made again", function()
  local picture = math_tex.lookup(T_M, LOOK)
  assert_true(picture, "T_m is a picture:")
  os.remove(picture.path)
  assert_eq(math_tex.lookup(T_M, LOOK), picture, "still known in memory:")
  math_tex.forget(T_M, LOOK)
  assert_eq(math_tex.lookup(T_M, LOOK), nil, "after forget:")
  request_and_wait(math_tex, { T_M }, LOOK)
  local again = math_tex.lookup(T_M, LOOK)
  assert_true(again and vim.uv.fs_stat(again.path), "made again:")
end)

test("retry() forgets failures", function()
  assert_eq(math_tex.lookup(UNDEFINED_COMMAND, LOOK), nil, "a fresh session has none:")
  request_and_wait(math_tex, { UNDEFINED_COMMAND }, LOOK)
  assert_eq(math_tex.lookup(UNDEFINED_COMMAND, LOOK), false, "failed:")
  math_tex.retry()
  assert_eq(math_tex.lookup(UNDEFINED_COMMAND, LOOK), nil, "after retry():")
  assert_eq(math_tex.failure_of(UNDEFINED_COMMAND, LOOK), nil, "no reason after retry():")
end)

test("maintenance prunes old pictures beyond the budget, off the main thread", function()
  local maintenance_cache = scratch_root .. "/maintenance-cache"
  local masks = maintenance_cache .. "/masks"
  vim.fn.mkdir(masks, "p")
  -- Run directories are `<prefix>-<pid>-<counter>`: 999999999 and 999999998
  -- are above any pid_max, i.e. sessions that are gone.
  vim.fn.mkdir(maintenance_cache .. "/run/job-999999999-1", "p")
  local live_directory = string.format("%s/run/job-%d-99", maintenance_cache, vim.uv.os_getpid())
  vim.fn.mkdir(live_directory, "p")
  -- A standby of a crashed session still loading: something waits in `open`
  -- for the FIFO's writer.
  local orphan_directory = maintenance_cache .. "/run/job-999999998-1"
  vim.fn.mkdir(orphan_directory, "p")
  assert_eq(vim.fn.system({ "mkfifo", orphan_directory .. "/job.tex" }), "", "mkfifo:")
  local orphan_exit
  local orphan = original_system(
    { "sh", "-c", "cat job.tex > /dev/null" },
    { cwd = orphan_directory },
    function(result)
      orphan_exit = result.code
    end
  )
  cleanups[#cleanups + 1] = function()
    orphan:kill("sigkill")
    vim.fn.delete(maintenance_cache, "rf")
  end
  local some_mask = read_bytes(math_tex.lookup(RHO, LOOK).path)
  local now = os.time()
  local three_days_ago = now - 3 * 86400
  for index = 1, 12 do
    local path = string.format("%s/%032x.png", masks, index)
    local file = assert(io.open(path, "wb"))
    file:write(some_mask)
    file:close()
    -- 1-8 old, 9-12 young.
    if index <= 8 then
      vim.uv.fs_utime(path, three_days_ago, three_days_ago)
    end
  end
  -- Older layouts: a picture with its sidecar beside the format, a stale run
  -- directory.
  vim.fn.writefile({ "x" }, maintenance_cache .. "/0123.png")
  vim.fn.writefile({ "8 1 1" }, maintenance_cache .. "/0123.txt")
  vim.uv.fs_utime(maintenance_cache .. "/run/job-999999999-1", now - 7200, now - 7200)
  vim.uv.fs_utime(live_directory, now - 7200, now - 7200)
  -- Formats of other templates (another session's preamble): a young one is
  -- in use, an old one is not.
  vim.fn.writefile({ "x" }, maintenance_cache .. "/format-v5-aaaaaaaaaaaaaaaa.fmt")
  vim.fn.writefile({ "x" }, maintenance_cache .. "/format-v5-bbbbbbbbbbbbbbbb.fmt")
  vim.uv.fs_utime(
    maintenance_cache .. "/format-v5-bbbbbbbbbbbbbbbb.fmt",
    three_days_ago,
    three_days_ago
  )
  let_run(50)
  local session = load_fresh_module(maintenance_cache, { disk_budget_bytes = 6 * 4096 })
  assert_true(session.is_available(), "available (the current format's name is known):")
  local summary
  local started = vim.uv.hrtime()
  session.maintain(function(result)
    summary = result
  end)
  local call_milliseconds = (vim.uv.hrtime() - started) / 1e6
  assert_true(
    call_milliseconds < 5,
    string.format("maintain() returned after %.2f ms:", call_milliseconds)
  )
  assert_true(
    wait_until(function()
      return summary ~= nil
    end),
    "maintenance finished:"
  )
  local left = vim.fn.readdir(masks)
  -- 12 pictures in 12 blocks against a budget of 6: old ones go, oldest first,
  -- down to 80 % (4 blocks) -- but never a young one.
  assert_eq(summary.pruned, 8, "pruned:")
  assert_eq(#left, 4, "left: " .. table.concat(left, " "))
  for _, name in ipairs(left) do
    assert_true(tonumber(name:sub(1, 32), 16) >= 9, "a young one is left: " .. name)
  end
  assert_eq(vim.fn.filereadable(maintenance_cache .. "/0123.png"), 0, "old-layout picture:")
  assert_eq(vim.fn.filereadable(maintenance_cache .. "/0123.txt"), 0, "old-layout sidecar:")
  assert_eq(
    vim.fn.isdirectory(maintenance_cache .. "/run/job-999999999-1"),
    0,
    "stale run directory:"
  )
  assert_eq(vim.fn.isdirectory(live_directory), 1, "an old run directory of a live Neovim:")
  assert_true(
    wait_until(function()
      return orphan_exit ~= nil
    end, 2000),
    "what waited on a dead session's FIFO has ended:"
  )
  assert_eq(
    vim.fn.filereadable(maintenance_cache .. "/format-v5-aaaaaaaaaaaaaaaa.fmt"),
    1,
    "a young format of another template:"
  )
  assert_eq(
    vim.fn.filereadable(maintenance_cache .. "/format-v5-bbbbbbbbbbbbbbbb.fmt"),
    0,
    "an old format of another template:"
  )
  math_tex = load_fresh_module(cache_directory)
  vim.fn.delete(maintenance_cache, "rf")
end)

test("maintenance touches what this session read, so it is not pruned", function()
  local session = load_fresh_module(cache_directory, { disk_budget_bytes = 1 })
  local picture = session.lookup(RHO, LOOK)
  assert_true(picture, "read from disk:")
  local three_days_ago = os.time() - 3 * 86400
  -- Everything old; only the one this session read is touched.
  for _, name in ipairs(vim.fn.readdir(cache_directory .. "/masks")) do
    vim.uv.fs_utime(cache_directory .. "/masks/" .. name, three_days_ago, three_days_ago)
  end
  local summary
  session.maintain(function(result)
    summary = result
  end)
  wait_until(function()
    return summary ~= nil
  end)
  assert_true(summary.pruned > 0, "others pruned:")
  assert_true(vim.uv.fs_stat(picture.path), "the one read is kept:")
  math_tex = load_fresh_module(cache_directory)
end)

test("note content cannot forge the job protocol", function()
  local mates = {
    { kind = "inline", tex = "a" },
    { kind = "inline", tex = "y^{2}" },
    { kind = "inline", tex = "\\sqrt{b}" },
  }
  -- `\mde\mdi{2}` would end its page and open a forged one: every later
  -- picture of the batch shifted by one (review: 8 of 8 wrong, cached).
  local forger = { kind = "inline", tex = "q\\mde\\mdi{2}Z" }
  request_and_wait(math_tex, { mates[1], forger, mates[2], mates[3] }, LOOK)
  local in_batch = lookup_each(math_tex, mates)
  -- A forged BEGIN naming no item, then a flood that is killed at the output
  -- cap: used to raise in settle and leave every later request unanswered.
  local begin_forger = {
    kind = "inline",
    tex = "\\immediate\\write16{MDMATH BEGIN 7}\\def\\x{\\message{"
      .. string.rep("spam", 50)
      .. "}\\x}\\x",
  }
  request_and_wait(math_tex, { begin_forger }, LOOK)
  assert_eq(math_tex.lookup(begin_forger, LOOK), false, "the BEGIN forger:")
  assert_true(math_tex.failure_of(begin_forger, LOOK):find("^killed"), "its reason:")
  local after = { kind = "inline", tex = "f_{after}" }
  local outcome = request_and_wait(math_tex, { after }, LOOK)
  assert_eq(outcome.calls, 1, "a later request still settles:")
  assert_true(math_tex.lookup(after, LOOK), "and is a picture:")
  assert_same_as_alone(
    mates,
    in_batch,
    "forgery-reference",
    " beside the forger is the same as alone:"
  )
end)

test("a cache directory removed under a running session heals by itself", function()
  local heal_cache = cache_with_formats("heal-cache")
  local session = load_fresh_module(heal_cache)
  local equation = { kind = "inline", tex = "h_{eal}" }
  request_and_wait(session, { equation }, LOOK)
  assert_true(session.lookup(equation, LOOK), "made:")
  let_run(300)
  -- `masks/` and `run/` (with the parked standby's directory) removed.
  vim.fn.delete(heal_cache .. "/masks", "rf")
  vim.fn.delete(heal_cache .. "/run", "rf")
  -- What the adapter does when the terminal side finds the file missing.
  session.forget(equation, LOOK)
  assert_eq(session.lookup(equation, LOOK), nil, "gone:")
  local other = { kind = "inline", tex = "h_{other}" }
  local outcome = request_and_wait(session, { equation, other }, LOOK)
  -- The parked standby's FIFO went with `run/`: ended at once, not after
  -- the whole time limit (2032 ms before).
  assert_true(
    outcome.milliseconds < 1500,
    string.format("settled after %.0f ms:", outcome.milliseconds)
  )
  local picture = session.lookup(equation, LOOK)
  assert_true(picture and vim.uv.fs_stat(picture.path), "made again, without retry():")
  assert_true(session.lookup(other, LOOK), "and a new one:")
  assert_eq(session.is_available(), true, "still available:")
  math_tex = load_fresh_module(cache_directory)
  vim.fn.delete(heal_cache, "rf")
end)

test("memory stays bounded; a working set within the bound is not read again", function()
  local session = load_fresh_module(cache_directory, { remembered_picture_limit = 8 })
  for index = 1, 400 do
    session.lookup({ kind = "inline", tex = "miss_{" .. index .. "}" }, LOOK)
  end
  assert_true(session.status().remembered.absent <= 256, "absent entries bounded:")
  local equations = {}
  for index = 1, 20 do
    equations[index] = { kind = "inline", tex = "b_{" .. index .. "}" }
  end
  request_and_wait(session, equations, LOOK)
  local reader = load_fresh_module(cache_directory, { remembered_picture_limit = 8 })
  for _, equation in ipairs(equations) do
    assert_true(reader.lookup(equation, LOOK), equation.tex .. " from disk:")
  end
  local remembered = reader.status().remembered.pictures
  assert_true(remembered <= 16, "pictures remembered: " .. remembered)
  -- A working set of 8, looked up again and again.
  local working_set = load_fresh_module(cache_directory, { remembered_picture_limit = 8 })
  for index = 1, 8 do
    working_set.lookup(equations[index], LOOK)
  end
  local opens = count_opens(function()
    for _ = 1, 5 do
      for index = 1, 8 do
        working_set.lookup(equations[index], LOOK)
      end
    end
  end)
  assert_eq(opens, 0, "files opened for a working set within the bound:")
  math_tex = load_fresh_module(cache_directory)
end)

test("remembered pictures: two generations, an older one moves back, forget drops both", function()
  -- b_1..b_10 are on disk (the test above made them).
  local equations, pictures = {}, {}
  local session = load_fresh_module(cache_directory, { remembered_picture_limit = 8 })
  for index = 1, 10 do
    equations[index] = { kind = "inline", tex = "b_{" .. index .. "}" }
    pictures[index] = session.lookup(equations[index], LOOK)
    assert_true(pictures[index], equations[index].tex .. " from disk:")
  end
  -- 1..8 are the previous generation now, 9 and 10 the current one.
  local opens = count_opens(function()
    session.lookup(equations[1], LOOK)
  end)
  assert_eq(opens, 0, "a picture of the previous generation, read again:")
  opens = count_opens(function()
    session.lookup(equations[1], LOOK)
  end)
  assert_eq(opens, 0, "moved back into the current one, read again:")
  -- Its file gone (pruned): forgotten in the previous generation too.
  os.remove(pictures[3].path)
  session.forget(equations[3], LOOK)
  assert_eq(session.lookup(equations[3], LOOK), nil, "forgotten, then looked for on disk:")
  math_tex = load_fresh_module(cache_directory)
end)

test("a standby starts on a miss only, and is kept while misses keep coming", function()
  -- Maintenance tests above pruned some of them (made by a session of its
  -- own: `math_tex` may be one a failed test left ended).
  request_and_wait(load_fresh_module(cache_directory), GOOD, LOOK)
  local session = load_fresh_module(cache_directory, { standby_idle_milliseconds = 300 })
  local standbys_before = count_standbys()
  for _, equation in ipairs(GOOD) do
    assert_true(session.lookup(equation, LOOK), equation.tex .. " from disk:")
  end
  let_run(200)
  assert_eq(count_standbys() - standbys_before, 0, "standbys after hits only:")
  local miss = { kind = "inline", tex = "k_{" .. vim.uv.hrtime() .. "}" }
  session.lookup(miss, LOOK)
  assert_true(
    wait_until(function()
      return count_standbys() - standbys_before == 1
    end, 2000),
    "a standby after a miss:"
  )
  local standby_pid = spawned[#spawned].pid
  -- Three idle periods, with a miss every 100 ms.
  for _ = 1, 9 do
    let_run(100)
    session.lookup(miss, LOOK)
  end
  assert_eq(vim.uv.kill(standby_pid, 0), 0, "still alive while needed:")
  assert_eq(count_standbys() - standbys_before, 1, "the same standby:")
  assert_true(
    wait_until(function()
      return processes_alive == 0
    end, 2000),
    "stopped once nothing is missing:"
  )
  math_tex = load_fresh_module(cache_directory)
end)

test("the user preamble: its macros in every equation; a changed one is a new format", function()
  local preamble = scratch_root .. "/preamble.tex"
  vim.fn.writefile({ "\\newcommand{\\foo}{A}" }, preamble)
  vim.g.md_render_math_preamble = preamble
  local builds_before = count_format_builds()
  local session = load_fresh_module(cache_directory)
  local first = { kind = "inline", tex = "\\foo + 1" }
  local second = { kind = "inline", tex = "\\foo^{2}" }
  request_and_wait(session, { first, second }, LOOK)
  assert_true(session.lookup(first, LOOK), "\\foo in one equation:")
  assert_true(session.lookup(second, LOOK), "\\foo in another:")
  assert_eq(session.status().preamble, preamble, "status names it:")
  local narrow = session.lookup(first, LOOK)
  -- Edited, and the config sourced again (`setup` once more).
  vim.fn.writefile({ "\\newcommand{\\foo}{BBBBBBBB}" }, preamble)
  session.setup()
  assert_eq(session.lookup(first, LOOK), nil, "not the old picture:")
  request_and_wait(session, { first }, LOOK)
  local wide = session.lookup(first, LOOK)
  assert_true(wide and wide.columns > narrow.columns, "made with the new preamble:")
  assert_eq(count_format_builds() - builds_before, 2, "format builds:")
  -- A new session reads the right picture from disk.
  local next_session = load_fresh_module(cache_directory)
  assert_eq(next_session.lookup(first, LOOK).columns, wide.columns, "next session:")
  -- Changed back while one batch runs and another waits.
  local running = { kind = "inline", tex = "\\foo - 2" }
  local queued = { kind = "inline", tex = "\\foo^{3}" }
  local running_outcome = { calls = 0 }
  local queued_outcome = { calls = 0 }
  next_session.request({ running }, LOOK, function()
    running_outcome.calls = running_outcome.calls + 1
  end)
  next_session.request({ queued }, LOOK, function()
    queued_outcome.calls = queued_outcome.calls + 1
  end)
  vim.fn.writefile({ "\\newcommand{\\foo}{A}" }, preamble)
  next_session.setup()
  assert_true(
    wait_until(function()
      return running_outcome.calls == 1 and queued_outcome.calls == 1
    end),
    "both settle:"
  )
  local made_while_changing = next_session.lookup(running, LOOK)
  assert_true(
    not made_while_changing or made_while_changing.columns < wide.columns,
    "what ran with the old preamble is not taken for the new one:"
  )
  local queued_picture = next_session.lookup(queued, LOOK)
  assert_true(queued_picture, "the queued one is made:")
  assert_eq(
    queued_picture.columns,
    next_session.lookup(second, LOOK).columns,
    "with the preamble of now (\\foo^{3} as wide as \\foo^{2}):"
  )
  assert_eq(count_format_builds() - builds_before, 2, "no build for a format on disk:")
  vim.g.md_render_math_preamble = nil
  math_tex = load_fresh_module(cache_directory)
end)

test("quitting Neovim mid-batch or while a standby loads exits at once, leaving nothing", function()
  local child_cache = cache_with_formats("child-cache")
  local child = scratch_root .. "/child.lua"
  vim.fn.writefile({
    -- HOME is the scratch one by now: the config's own path, from the start.
    "package.path = "
      .. vim.inspect(CONFIG_DIRECTORY .. "/lua/?.lua;")
      .. " .. package.path",
    "local tex = require(" .. vim.inspect(MODULE_NAME) .. ")",
    "tex.setup({ cache_directory = os.getenv('CACHE') })",
    "local look = { cell_width = 20, cell_height = 44 }",
    "local mode, tag = os.getenv('MODE'), tostring(vim.uv.hrtime())",
    "local function equations(count)",
    "  local list = {}",
    "  for index = 1, count do list[index] = { kind = 'inline', tex = 'c_{' .. index .. '}^{' .. tag .. '}' } end",
    "  return list",
    "end",
    "local function miss() tex.lookup({ kind = 'inline', tex = 'm_{' .. tag .. '}' }, look) end",
    "if mode == 'first_request' then tex.request(equations(15), look, function() end)",
    "elseif mode == 'mid_raster' then tex.request(equations(150), look, function() end)",
    "  vim.wait(5000, function() return vim.fn.glob(os.getenv('CACHE') .. '/run/*/p-*.png') ~= '' end, 1)",
    "elseif mode == 'standby_loading' then miss()",
    "elseif mode == 'taken_loading' then miss(); vim.wait(3, function() return false end, 1);",
    "  tex.request(equations(1), look, function() end) end",
    "vim.defer_fn(function()",
    "  if os.getenv('ACTION') == 'kill9' then vim.uv.kill(vim.uv.os_getpid(), 9) else vim.cmd('qa!') end",
    "end, tonumber(os.getenv('DELAY')))",
    "vim.wait(10000, function() return false end, 5)",
    "vim.cmd('qa!')",
  }, child)
  -- The format of this template is built in it: quitting then must not warn.
  local build_cache = scratch_root .. "/child-build-cache"
  ---@return integer[] processes whose command line or working directory is
  --- in a child's cache (mutool's arguments are relative to its job's)
  local function left_behind()
    local pids = {}
    local prefix = scratch_root .. "/child-"
    for _, pid in ipairs(vim.fn.readdir("/proc")) do
      local file = pid:match("^%d+$") and io.open("/proc/" .. pid .. "/cmdline", "rb")
      if file then
        local command_line = file:read("*a") or ""
        file:close()
        local directory = vim.uv.fs_readlink("/proc/" .. pid .. "/cwd") or ""
        if command_line:find(prefix, 1, true) or directory:find(prefix, 1, true) then
          pids[#pids + 1] = tonumber(pid)
        end
      end
    end
    return pids
  end
  --- Before the cache goes (its FIFO is the only thing that could end a
  --- parked pdfTeX), and also when an assertion below fails.
  local function end_left_behind()
    for _, pid in ipairs(left_behind()) do
      vim.uv.kill(pid, "sigkill")
    end
  end
  cleanups[#cleanups + 1] = function()
    end_left_behind()
    vim.fn.delete(child_cache, "rf")
    vim.fn.delete(build_cache, "rf")
  end
  local cases = {
    { "first_request", "qa", 0 },
    { "first_request", "qa", 10 },
    { "first_request", "qa", 30 },
    { "first_request", "qa", 60 },
    -- While several mutools draw 150 pages (the first page is out): the
    -- whole process group goes, or they write on into what is removed.
    { "mid_raster", "qa", 0 },
    { "mid_raster", "qa", 0 },
    { "standby_loading", "qa", 2 },
    { "standby_loading", "qa", 10 },
    { "standby_loading", "qa", 20 },
    { "standby_loading", "qa", 400 },
    { "taken_loading", "qa", 0 },
    -- While the format is built (a cache without it).
    { "first_request", "qa", 50, build_cache },
    { "first_request", "qa", 200, build_cache },
  }
  if vim.fn.executable("setpriv") == 1 then
    -- Killed while its standby loads or is parked: nothing of Neovim's holds
    -- the FIFO, the parent-death signal ends pdfTeX.
    vim.list_extend(cases, {
      { "standby_loading", "kill9", 15 },
      { "standby_loading", "kill9", 25 },
      { "standby_loading", "kill9", 400 },
    })
  end
  for _, case in ipairs(cases) do
    local mode, action, delay, cache = case[1], case[2], case[3], case[4] or child_cache
    vim.fn.delete(child_cache .. "/masks", "rf")
    vim.fn.delete(build_cache, "rf")
    vim.fn.mkdir(build_cache, "p")
    local started = vim.uv.hrtime()
    -- `-S`, not `-l`: after a `-l` script Neovim exits without running the
    -- exit callbacks of what VimLeavePre killed, which a session does run.
    local result = original_system(
      { vim.v.progpath, "--headless", "-u", "NONE", "-S", child },
      { env = { CACHE = cache, MODE = mode, ACTION = action, DELAY = tostring(delay) } }
    ):wait(8000)
    local milliseconds = (vim.uv.hrtime() - started) / 1e6
    local label = string.format(
      "%s, %s after %d ms%s",
      mode,
      action,
      delay,
      case[4] and " (format build)" or ""
    )
    if action == "qa" then
      assert_eq(result.code, 0, label .. ": exit code:")
      -- What VimLeavePre killed reports nothing ("ran longer than ...").
      assert_true(
        not (result.stderr or ""):find("md-render math", 1, true),
        label .. ": warned: " .. (result.stderr or "")
      )
      assert_true(
        milliseconds < 4000,
        string.format("%s: exited after %.0f ms:", label, milliseconds)
      )
      -- Nothing started after VimLeavePre (it would leave its directory).
      local left = vim.fn.isdirectory(cache .. "/run") == 1 and vim.fn.readdir(cache .. "/run")
        or {}
      assert_eq(#left, 0, label .. ": run directories left: " .. table.concat(left, " "))
    end
    if mode == "mid_raster" then
      -- Killed with Neovim, not left to finish their pages.
      assert_eq(#left_behind(), 0, label .. ": processes right after the exit:")
    end
    wait_until(function()
      return #left_behind() == 0
    end, 1500)
    local left = #left_behind()
    end_left_behind()
    assert_eq(left, 0, label .. ": processes left:")
  end
end)

test("a protocol line out of order makes the run untrusted, not its pictures wrong", function()
  local real_pdftex = vim.fn.exepath("pdftex")
  -- As if an equation had printed a second `BEGIN 2` after `BEGIN 3`: the
  -- name list cannot know every way to print a line (`\GenericWarning`,
  -- `\typein` and more did), the order check does not need to.
  local remove_fakes = fake_programs({
    pdftex = {
      '"' .. real_pdftex .. '" "$@" > pdftex.out',
      "code=$?",
      "sed 's/^MDMATH BEGIN 3$/MDMATH BEGIN 3\\nMDMATH BEGIN 2/' pdftex.out",
      "exit $code",
    },
  })
  cleanups[#cleanups + 1] = remove_fakes
  -- Plain spawns only (no `setpriv`, so no standby): a killed standby would
  -- be this wrapper shell, not the pdfTeX under it.
  local bin = scratch_root .. "/order-bin"
  vim.fn.mkdir(bin, "p")
  for _, name in ipairs({ "mutool", "gzip", "sed" }) do
    vim.uv.fs_symlink(vim.fn.exepath(name), bin .. "/" .. name)
  end
  local real_path = vim.env.PATH
  vim.env.PATH = scratch_root .. "/fake-bin:" .. bin
  cleanups[#cleanups + 1] = function()
    vim.env.PATH = real_path
    vim.fn.delete(bin, "rf")
  end
  -- Another pdftex is another format: a cache of its own.
  local order_cache = scratch_root .. "/order-cache"
  cleanups[#cleanups + 1] = function()
    vim.fn.delete(order_cache, "rf")
  end
  local session = load_fresh_module(order_cache)
  local equations = {}
  for index = 1, 4 do
    equations[index] = { kind = "inline", tex = "o_{" .. index .. "} + " .. index }
  end
  local outcome = request_and_wait(session, equations, LOOK)
  assert_eq(outcome.calls, 1, "on_settled calls:")
  local pictures = lookup_each(session, equations)
  remove_fakes()
  assert_same_as_alone(equations, pictures, "order-reference", " is the same as alone:")
end)

test("a run killed before it began anything: nil, made on the next ask", function()
  local session = load_fresh_module(cache_directory)
  local equation = { kind = "inline", tex = "k_{" .. vim.uv.hrtime() .. "}" }
  local standbys_before = count_standbys()
  assert_eq(session.lookup(equation, LOOK), nil, "a miss:")
  assert_true(
    wait_until(function()
      return count_standbys() > standbys_before
    end, 2000),
    "a standby:"
  )
  let_run(300)
  -- Killed from outside (the OOM killer, `pkill pdftex`) in the tick a
  -- request of one equation takes it.
  vim.uv.kill(spawned[#spawned].pid, "sigkill")
  local outcome = request_and_wait(session, { equation }, LOOK)
  assert_eq(outcome.calls, 1, "on_settled calls:")
  assert_eq(session.lookup(equation, LOOK), nil, "not false:")
  assert_eq(session.failure_of(equation, LOOK), nil, "no reason:")
  request_and_wait(session, { equation }, LOOK)
  assert_true(session.lookup(equation, LOOK), "made on the next ask:")
  math_tex = session
end)

test("an error inside a callback ends its batch; later requests still settle", function()
  local original_notify = vim.notify
  local notifications = 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function()
    notifications = notifications + 1
  end
  cleanups[#cleanups + 1] = function()
    vim.notify = original_notify
  end
  --- `target[key]` raises once, for the first call `matches`; returns the undo.
  local function raise_once(target, key, matches)
    local original = target[key]
    local has_raised = false
    target[key] = function(...)
      if not has_raised and matches(...) then
        has_raised = true
        error("raised by the spec")
      end
      return original(...)
    end
    return function()
      target[key] = original
    end
  end
  local function is_job_log(path)
    return type(path) == "string" and path:find("/job%.log$") ~= nil
  end
  local places = {
    -- The first request of a session is a plain spawn: run_batch makes the
    -- job's log link.
    {
      label = "starting the batch",
      raise = function()
        return raise_once(vim.uv, "fs_symlink", function(_, link)
          return is_job_log(link)
        end)
      end,
      until_request_returns = true,
    },
    {
      label = "pdfTeX's exit",
      raise = function()
        return raise_once(vim.uv, "fs_stat", is_job_log)
      end,
    },
    {
      label = "mutool's exit",
      raise = function()
        return raise_once(vim.fs, "basename", function()
          return true
        end)
      end,
    },
  }
  local session = load_fresh_module(cache_directory)
  for index, place in ipairs(places) do
    local equation = { kind = "inline", tex = "e_{" .. index .. "}^{" .. vim.uv.hrtime() .. "}" }
    local undo = place.raise()
    cleanups[#cleanups + 1] = undo
    local outcome = { calls = 0 }
    session.request({ equation }, LOOK, function()
      outcome.calls = outcome.calls + 1
    end)
    if place.until_request_returns then
      undo()
    end
    wait_until(function()
      return outcome.calls > 0
    end, 5000)
    undo()
    assert_eq(outcome.calls, 1, place.label .. ": the request settles:")
    assert_eq(session.lookup(equation, LOOK), nil, place.label .. ": nil:")
    local later = { kind = "inline", tex = "l_{" .. index .. "}^{" .. vim.uv.hrtime() .. "}" }
    local later_outcome = request_and_wait(session, { later }, LOOK)
    assert_eq(later_outcome.calls, 1, place.label .. ": a later request settles:")
    assert_true(session.lookup(later, LOOK), place.label .. ": and is a picture:")
  end
  assert_eq(notifications, 1, "one notification for the three:")
  assert_eq(session.is_available(), true, "still available:")
  vim.notify = original_notify
  math_tex = load_fresh_module(cache_directory)
end)

test("the poll and the time limit of a standby batch end with it", function()
  -- Timers made from now on, by the function that made them: the poll
  -- (`write_when_ready`) and the time limit (`run_batch`) must be closed
  -- once their batch has settled, not live on holding its items.
  local original_new_timer = vim.uv.new_timer
  local made = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.uv.new_timer = function()
    local timer = original_new_timer()
    made[#made + 1] = { timer = timer, maker = debug.getinfo(2, "n").name }
    return timer
  end
  cleanups[#cleanups + 1] = function()
    vim.uv.new_timer = original_new_timer
  end
  ---@return string[] makers of batch timers still alive
  local function batch_timers_alive()
    local makers = {}
    for _, entry in ipairs(made) do
      if
        (entry.maker == "write_when_ready" or entry.maker == "run_batch")
        and not entry.timer:is_closing()
      then
        makers[#makers + 1] = entry.maker
      end
    end
    return makers
  end
  local session = load_fresh_module(cache_directory)
  local standbys_before = count_standbys()
  local first = { kind = "inline", tex = "t_{" .. vim.uv.hrtime() .. "}" }
  session.lookup(first, LOOK)
  wait_until(function()
    return count_standbys() == standbys_before + 1
  end, 2000)
  -- Taken while it loads: the job waits on the 2 ms poll.
  request_and_wait(session, { first }, LOOK)
  assert_true(session.lookup(first, LOOK), "made:")
  local makers = {}
  for _, entry in ipairs(made) do
    makers[entry.maker or "?"] = true
  end
  assert_true(makers.write_when_ready and makers.run_batch, "both timers were made:")
  assert_eq(table.concat(batch_timers_alive(), " "), "", "alive once it settled:")
  -- The next one dies while its job waits: the poll stops.
  wait_until(function()
    return count_standbys() == standbys_before + 2
  end, 2000)
  local second = { kind = "inline", tex = "t_{" .. vim.uv.hrtime() .. "}" }
  local outcome = { calls = 0 }
  session.request({ second }, LOOK, function()
    outcome.calls = outcome.calls + 1
  end)
  vim.uv.kill(spawned[#spawned].pid, "sigkill")
  wait_until(function()
    return outcome.calls > 0
  end, 2000)
  let_run(50)
  assert_eq(outcome.calls, 1, "settles:")
  assert_eq(table.concat(batch_timers_alive(), " "), "", "alive once it settled:")
  vim.uv.new_timer = original_new_timer
  math_tex = load_fresh_module(cache_directory)
end)

test("a preamble changed while its format is built: the new one is used", function()
  local preamble = scratch_root .. "/race-preamble.tex"
  -- A comment of its own: a new template, so a format build.
  local tag = tostring(vim.uv.hrtime())
  vim.fn.writefile({ "\\newcommand{\\foo}{A} % " .. tag }, preamble)
  vim.g.md_render_math_preamble = preamble
  cleanups[#cleanups + 1] = function()
    vim.g.md_render_math_preamble = nil
  end
  local builds_before = count_format_builds()
  local session = load_fresh_module(cache_directory)
  local equation = { kind = "inline", tex = "\\foo + 9" }
  local outcome = { calls = 0 }
  session.request({ equation }, LOOK, function()
    outcome.calls = outcome.calls + 1
  end)
  assert_true(
    wait_until(function()
      return count_format_builds() - builds_before == 1
    end, 2000),
    "building:"
  )
  vim.fn.writefile({ "\\newcommand{\\foo}{BBBBBBBB} % " .. tag }, preamble)
  session.setup()
  wait_until(function()
    return outcome.calls > 0
  end, 20000)
  local picture = session.lookup(equation, LOOK)
  local as_written = { kind = "inline", tex = "BBBBBBBB + 9" }
  request_and_wait(session, { as_written }, LOOK)
  assert_true(picture, "made:")
  assert_eq(picture.columns, session.lookup(as_written, LOOK).columns, "with the new preamble:")
  assert_eq(count_format_builds() - builds_before, 2, "format builds:")
  vim.g.md_render_math_preamble = nil
  math_tex = load_fresh_module(cache_directory)
end)

test("a format file removed under a session is built again, each time", function()
  local own_cache = cache_with_formats("format-gone-cache")
  cleanups[#cleanups + 1] = function()
    vim.fn.delete(own_cache, "rf")
  end
  local session = load_fresh_module(own_cache, { standby_idle_milliseconds = 50 })
  request_and_wait(session, { { kind = "inline", tex = "w_{arm}" } }, LOOK)
  local format_file = session.status().format
  local builds_before = count_format_builds()
  for round = 1, 2 do
    -- No standby: it would have the old format loaded already.
    wait_until(function()
      return processes_alive == 0
    end, 2000)
    os.remove(format_file)
    local equation = { kind = "inline", tex = "g_{" .. round .. "}" }
    request_and_wait(session, { equation }, LOOK)
    assert_true(session.lookup(equation, LOOK), "round " .. round .. ": made:")
    assert_eq(session.is_available(), true, "round " .. round .. ": available:")
  end
  assert_eq(count_format_builds() - builds_before, 2, "format builds:")
  math_tex = load_fresh_module(cache_directory)
end)

test("without setpriv there is no standby: plain spawns, and status() says why", function()
  local bin = scratch_root .. "/no-setpriv-bin"
  vim.fn.mkdir(bin, "p")
  for _, name in ipairs({ "pdftex", "mutool", "gzip" }) do
    vim.uv.fs_symlink(vim.fn.exepath(name), bin .. "/" .. name)
  end
  local real_path = vim.env.PATH
  vim.env.PATH = bin
  cleanups[#cleanups + 1] = function()
    vim.env.PATH = real_path
    vim.fn.delete(bin, "rf")
  end
  local session = load_fresh_module(cache_directory)
  local standbys_before = count_standbys()
  local equation = { kind = "inline", tex = "p_{" .. vim.uv.hrtime() .. "}" }
  assert_eq(session.lookup(equation, LOOK), nil, "a miss, which would start one:")
  request_and_wait(session, { equation }, LOOK)
  let_run(200)
  assert_true(session.lookup(equation, LOOK), "made:")
  assert_eq(count_standbys() - standbys_before, 0, "standbys:")
  assert_eq(session.status().standby_off, "setpriv is not installed", "status:")
  vim.env.PATH = real_path
  math_tex = load_fresh_module(cache_directory)
  assert_eq(math_tex.status().standby_off, nil, "with setpriv:")
end)

test("every pdftex run of this spec had -no-shell-escape", function()
  local runs = 0
  for _, record in ipairs(spawned) do
    if vim.tbl_contains(record.command, "pdftex") then
      runs = runs + 1
      assert_true(
        vim.tbl_contains(record.command, "-no-shell-escape"),
        table.concat(record.command, " ") .. ":"
      )
      if record.is_standby and vim.fn.executable("setpriv") == 1 then
        assert_true(vim.tbl_contains(record.command, "--pdeathsig"), "a standby under setpriv:")
      end
    end
  end
  assert_true(runs > 20 and count_format_builds() > 0, "runs checked: " .. runs)
end)

end_session()
vim.system = original_system
vim.env.HOME = real_home
vim.env.TEXMFOUTPUT = real_texmfoutput
vim.fn.chdir(real_home)
vim.fn.delete(scratch_root, "rf")
_H.finish()
