-- Fortran custom syntax highlighting module
--
-- Colours the library names andrew.fortran.registry documents -- the MPI
-- bindings, the OpenMP runtime and its constants, and the OpenMP directives
-- and clauses -- in groups the user's themes link into their palette. The
-- Fortran statement keywords are tree-sitter's and are left alone.
--
-- WHY THE REGISTRY AND NOT THE DOCS FILE
--
-- This list used to come from snippets/fortran-docs.json, which is GENERATED
-- from the VS Code snippets: ~210 of its 388 keys are snippet abbreviations,
-- not Fortran names. So ordinary variables called `count`, `mat`, `dp`, `pi`
-- or `flush` were painted as library names (omp-audit S3b). The registry holds
-- only names that exist, and it is the same source hover and completion answer
-- from, so what is coloured, what is hoverable and what is completable are now
-- one set.
--
-- WHY EXTMARKS AND NOT `syntax match`
--
-- This module used to register `syntax match FortranMPIKeyword /\c\<mpi_init\>/
-- containedin=ALL` for every documented keyword. Those rules DID register --
-- `synID()` on `MPI_INIT` answered `FortranMPIKeyword` -- and nothing was ever
-- drawn. andrew.plugins.treesitter enables tree-sitter highlighting for
-- fortran, tree-sitter paints with extmarks at priority 100, and regex-syntax
-- highlighting sits at priority 0 underneath. Since the parser has a capture
-- for every identifier, every one of these rules lost. `matchadd(..., 1000)`
-- does not help either: match priority only orders matches against syntax, not
-- against the extmark layer. The colours appeared on exactly one kind of file:
-- one over 20000 lines, where treesitter.lua's `disable` predicate turns the
-- tree-sitter highlighter off entirely.
--
-- So the paint has to happen in the same layer, above it: extmarks in a
-- dedicated namespace at priority 150.
--
-- WHY INCREMENTAL
--
-- `syntax match` was free to register because the regex engine only ever runs
-- over the lines being drawn. Extmarks are not: placing one per keyword over a
-- whole buffer is work proportional to the file, and Fortran files here run to
-- 20k lines. So only the VISIBLE range of each window showing the buffer is
-- ever painted, refreshed on scroll/resize and -- via nvim_buf_attach's
-- on_lines -- for just the changed lines on an edit, debounced so a burst of
-- keystrokes costs one pass.
--
-- WHY COMMENTS ARE SKIPPED TWICE
--
-- scan.mask blanks comments and string literals length-preservingly, which is
-- what keeps `MPI_INIT` inside a `!` comment or a 'call MPI_INIT here' string
-- from being coloured (the old regex path coloured both). When a fortran
-- tree-sitter parser is available its (comment)/(string_literal) nodes are
-- consulted as well, so a construct the hand-written masker gets wrong still
-- comes out uncoloured. Neither path is required: with no parser the masker
-- alone decides, and nothing throws.
--
-- OpenMP directive lines are the deliberate exception. `!$OMP PARALLEL DO` is
-- a comment to both the masker and the parser -- it is a comment to a compiler
-- without -fopenmp, which is the whole hazard andrew.fortran.openmp exists to
-- surface -- so directive lines are recognised by openmp.is_directive and
-- handled on their own path rather than being masked away.
local M = {}

--- Above tree-sitter's 100, below anything a user would add by hand for
--- diagnostics or search. See the header for why this number is the fix.
M.PRIORITY = 150

--- The three groups, with the link targets the user's colours depend on.
--- Re-applied on ColorScheme: these are plain `link =` definitions and a
--- colorscheme's `hi clear` removes them outright, so without the autocmd a
--- single light/dark switch (<leader>ub) permanently dropped the custom
--- keyword, MPI and OpenMP colouring. tests/theme_switch_spec.lua guards it.
M.LINKS = {
  FortranCustomKeyword = "Function",
  FortranMPIKeyword = "Constant",
  FortranOMPKeyword = "PreProc",
}

local NS = vim.api.nvim_create_namespace("fortran_custom_highlight")

--- Debounce for the edit/scroll refresh. Long enough that a fast typist pays
--- for one pass per pause, short enough that the colour lands before the eye
--- leaves the line.
local DEBOUNCE_MS = 40

--- Extra lines painted above and below the viewport, so a one-line scroll or a
--- `zz` does not expose an unpainted edge before the debounce fires.
local MARGIN = 8

--- Namespace, exposed for tests and for anyone inspecting the marks.
---@return integer
function M.namespace()
  return NS
end

function M.setup_highlights()
  for group, target in pairs(M.LINKS) do
    vim.api.nvim_set_hl(0, group, { link = target })
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("FortranHighlights", { clear = true }),
    callback = function()
      for group, target in pairs(M.LINKS) do
        vim.api.nvim_set_hl(0, group, { link = target })
      end
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Word list
-- ---------------------------------------------------------------------------

--- Categorize a keyword based on its name
function M.categorize(keyword)
  if keyword:match("^mpi") or keyword:match("^MPI") then
    return "FortranMPIKeyword"
  elseif keyword:match("^omp") or keyword:match("^OMP") then
    return "FortranOMPKeyword"
  else
    return "FortranCustomKeyword"
  end
end

local word_group = nil

--- Which group each of registry.names()'s origins paints in.
---
--- The mapping is what M.categorize would answer for the names in each file,
--- read off the file instead of off the spelling: every MPI name matches
--- `^mpi` and every OpenMP runtime name `^omp`.
---
--- The registry's third file, `keywords`, is deliberately absent. Those are
--- the 93 Fortran STATEMENT keywords -- `program`, `integer`, `call`, `do`,
--- `end` -- and colouring them is tree-sitter's job, done correctly and
--- already. Painting them here would put an extmark at priority 150 over
--- tree-sitter's own and recolour every keyword in the file as
--- FortranCustomKeyword (linked to Function). They are in the registry so
--- that hover and completion can answer for them, not so that this module
--- paints them.
local ORIGIN_GROUP = {
  mpi = "FortranMPIKeyword",
  openmp = "FortranOMPKeyword",
}

--- Lowercase name -> highlight group, built once from the REGISTRY.
---
--- This used to read all 388 keys of snippets/fortran-docs.json. That file is
--- generated from the VS Code snippets, so ~210 of its keys are snippet
--- ABBREVIATIONS rather than Fortran names, and ordinary variables called
--- `count`, `mat`, `dp`, `pi` or `flush` were being painted as library names
--- and hovered with an unrelated snippet body (omp-audit S3b). The registry
--- holds only names that exist: MPI's bindings, the omp_lib runtime and its
--- constants, the Fortran statement keywords. So the coloured set, the
--- hoverable set and the completable set are now ONE set.
---
--- Only identifier-shaped keys can ever match a token, so a multi-word
--- directive key (`parallel_do`) is dropped here -- directive lines are
--- painted by paint_directive, which resolves whole words against the
--- directive index. Lookup is by the LOWERCASE spelling because Fortran is
--- case-insensitive and scan.mask hands back lowercased text.
---
--- An origin with no entry in ORIGIN_GROUP contributes nothing: see there for
--- why the statement keywords are left to tree-sitter.
---@return table<string, string>
function M.words()
  if word_group then
    return word_group
  end
  word_group = {}
  local ok, names = pcall(function()
    return require("andrew.fortran.registry").names()
  end)
  if ok and type(names) == "table" then
    for lname, origin in pairs(names) do
      local group = ORIGIN_GROUP[origin]
      if group and type(lname) == "string" and lname:match("^[%a_][%w_]*$") then
        word_group[lname] = group
      end
    end
  end
  return word_group
end

--- Drop the cached word list (after registry.reset(), or in a test).
function M.reset_words()
  word_group = nil
end

-- ---------------------------------------------------------------------------
-- Comment / string masking
-- ---------------------------------------------------------------------------

--- Lowercased, comment- and string-blanked copy of `raw`, same byte length,
--- or nil when the whole line is a comment/directive-free preprocessor line.
---
--- The two fast paths matter: they run for every visible line on every scroll.
--- A line with no `!`, quote or fixed-form column-1 marker cannot contain a
--- comment or a literal, so `:lower()` (one C-level pass) is exactly what
--- scan.mask would have produced byte for byte, without its per-byte table.
---@param raw string
---@param fixed boolean
---@return string|nil
function M.masked(raw, fixed)
  if raw == "" then
    return nil
  end
  if fixed then
    local first = raw:sub(1, 1)
    -- Fixed-form comment markers live in column 1 only.
    if first == "c" or first == "C" or first == "*" or first == "!" then
      return nil
    end
  end
  if raw:find("^%s*#") then
    return nil
  end
  if not raw:find("[!'\"]") then
    return raw:lower()
  end
  local masked = require("andrew.fortran.scan").mask(raw, fixed)
  if not masked:find("%S") then
    return nil
  end
  return masked
end

-- ---------------------------------------------------------------------------
-- Tree-sitter comment / string ranges
-- ---------------------------------------------------------------------------

local TS_QUERY = "[(comment) (string_literal)] @fortran_hl_skip"
local ts_query = nil
local ts_query_tried = false

--- Byte ranges of every comment and string literal the fortran parser sees in
--- `[first, last)`, as `skip[row] = { {scol, ecol}, ... }` (0-based cols, ecol
--- exclusive; a multi-row node contributes a full-line entry for its interior
--- rows). nil when there is no parser or no query -- the caller then relies on
--- the masker alone.
---@param bufnr integer
---@param first integer 0-based
---@param last integer 0-based exclusive
---@return table<integer, integer[][]>|nil
function M.ts_skip(bufnr, first, last)
  local okp, parser = pcall(vim.treesitter.get_parser, bufnr, "fortran")
  if not okp or not parser then
    return nil
  end
  if not ts_query_tried then
    ts_query_tried = true
    local okq, q = pcall(vim.treesitter.query.parse, "fortran", TS_QUERY)
    ts_query = okq and q or nil
  end
  if not ts_query then
    return nil
  end
  -- NEVER force a parse here. `parser:parse({first, last})` on a 5000-line
  -- Fortran buffer with a dirty tree measured 85-95 ms -- per keystroke, since
  -- every edit dirties the tree. That is precisely the typing stutter this
  -- module must not cause, and it would be paid to refine an answer the masker
  -- already has right.
  --
  -- So the tree is read only when it is already current, which with the
  -- tree-sitter highlighter enabled (andrew.plugins.treesitter) is the normal
  -- state: it re-parses on redraw, well inside the debounce. While a burst of
  -- keystrokes is in flight the answer comes from scan.mask alone, and the next
  -- viewport refresh picks the tree back up.
  --
  -- Validity is asked for THIS ROW RANGE only, and with injections excluded:
  -- the highlighter parses lazily, region by region, so `is_valid()` for the
  -- whole document is false almost all the time on a large file even though the
  -- fifty lines on screen are perfectly up to date.
  local okv, valid = pcall(parser.is_valid, parser, true, { first, 0, last, 0 })
  if not okv or not valid then
    return nil
  end
  local trees = parser:trees()
  if not trees or not next(trees) then
    return nil
  end

  local skip = {}
  local function add(row, scol, ecol)
    local list = skip[row]
    if not list then
      list = {}
      skip[row] = list
    end
    list[#list + 1] = { scol, ecol }
  end

  local ok = pcall(function()
    for _, tree in pairs(trees) do
      for _, node in ts_query:iter_captures(tree:root(), bufnr, first, last) do
        local sr, sc, er, ec = node:range()
        if er == sr then
          add(sr, sc, ec)
        else
          add(sr, sc, math.huge)
          for row = sr + 1, er - 1 do
            add(row, 0, math.huge)
          end
          add(er, 0, ec)
        end
      end
    end
  end)
  if not ok then
    return nil
  end
  return skip
end

--- Is `[scol, ecol)` inside one of `ranges`?
---@param ranges integer[][]|nil
---@param scol integer 0-based
---@return boolean
local function in_ranges(ranges, scol)
  if not ranges then
    return false
  end
  for _, r in ipairs(ranges) do
    if scol >= r[1] and scol < r[2] then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

local function mark(bufnr, row, scol, ecol, group)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, scol, {
    end_row = row,
    end_col = ecol,
    hl_group = group,
    priority = M.PRIORITY,
  })
end

--- Paint one OpenMP directive line.
---
--- The sentinel (`!$`, `C$`, `*$`) is coloured outright; the words after it are
--- coloured when registry.directive resolves them, which is the SAME door
--- hover and completion go through -- so `PARALLEL`, `DO` and `PRIVATE` colour,
--- the structural `END` does not (it names no construct), and a clause argument
--- the user happens to call `sum` does not either, because the directive index
--- holds no intrinsics.
---@param bufnr integer
---@param row integer 0-based
---@param raw string
local function paint_directive(bufnr, row, raw)
  local registry = require("andrew.fortran.registry")
  local group = "FortranOMPKeyword"
  local s = raw:find("[!cC%*]%$")
  if s then
    mark(bufnr, row, s - 1, s + 1, group)
  end
  local init = (s or 0) + 2
  while true do
    local ws, we, word = raw:find("([%a_][%w_]*)", init)
    if not ws then
      break
    end
    if registry.directive(word) then
      mark(bufnr, row, ws - 1, we, group)
    end
    init = we + 1
  end
end

--- Clear and repaint `[first, last)` (0-based, `last` exclusive).
---
--- Clearing is scoped to the same range: on an edit the rest of the buffer's
--- marks must survive, and on a scroll repainting a range that is already
--- painted has to be idempotent.
---@param bufnr integer
---@param first integer
---@param last integer
function M.paint(bufnr, first, last)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  first = math.max(0, first)
  last = math.min(count, last)
  if first >= last then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, NS, first, last)
  if not M.enabled() then
    return
  end

  local words = M.words()
  if next(words) == nil then
    return
  end

  local scan = require("andrew.fortran.scan")
  local openmp = require("andrew.fortran.openmp")
  local fixed = scan.is_fixed(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, last, false)
  local skip = M.ts_skip(bufnr, first, last)

  for i, raw in ipairs(lines) do
    local row = first + i - 1
    if raw ~= "" then
      if openmp.is_directive(raw) then
        paint_directive(bufnr, row, raw)
      else
        local masked = M.masked(raw, fixed)
        if masked then
          local ranges = skip and skip[row]
          local init = 1
          while true do
            local ws, we, word = masked:find("([%a_][%w_]*)", init)
            if not ws then
              break
            end
            local group = words[word]
            if group and not in_ranges(ranges, ws - 1) then
              mark(bufnr, row, ws - 1, we, group)
            end
            init = we + 1
          end
        end
      end
    end
  end
end

--- Union of the visible ranges of every window showing `bufnr`, padded by
--- MARGIN. Returns nil when the buffer is not on screen.
---@param bufnr integer
---@return integer|nil first 0-based, integer|nil last exclusive
function M.viewport(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local first, last
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local info = vim.fn.getwininfo(win)[1]
    if info then
      local lo = math.max(0, (info.topline or 1) - 1 - MARGIN)
      local hi = (info.botline or 1) + MARGIN
      first = (first == nil or lo < first) and lo or first
      last = (last == nil or hi > last) and hi or last
    end
  end
  return first, last
end

-- ---------------------------------------------------------------------------
-- Per-buffer lifecycle
-- ---------------------------------------------------------------------------

---@type table<integer, { timer: uv.uv_timer_t|nil, lo: integer|nil, hi: integer|nil, group: integer }>
local state = {}

--- Is the feature on? Off means: attached, but painting nothing.
---@return boolean
function M.enabled()
  return vim.g.fortran_highlight ~= false and vim.g.fortran_highlight ~= 0
end

local function stop_timer(st)
  if st.timer then
    pcall(st.timer.stop, st.timer)
    if not st.timer:is_closing() then
      pcall(st.timer.close, st.timer)
    end
    st.timer = nil
  end
end

--- Queue `[lo, hi)` for painting, coalescing with anything already queued.
--- `lo`/`hi` nil means "whatever is visible when the timer fires".
local function schedule(bufnr, lo, hi)
  local st = state[bufnr]
  if not st then
    return
  end
  if lo == nil then
    st.lo, st.hi = nil, nil
    st.viewport = true
  elseif not st.viewport then
    st.lo = (st.lo == nil or lo < st.lo) and lo or st.lo
    st.hi = (st.hi == nil or hi > st.hi) and hi or st.hi
  end

  if not st.timer then
    local ok, timer = pcall(vim.uv.new_timer)
    if not ok or not timer then
      return
    end
    st.timer = timer
  end
  st.timer:stop()
  st.timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    local cur = state[bufnr]
    if not cur then
      return
    end
    local a, b, vp = cur.lo, cur.hi, cur.viewport
    cur.lo, cur.hi, cur.viewport = nil, nil, false
    if not vim.api.nvim_buf_is_loaded(bufnr) then
      return
    end
    local vlo, vhi = M.viewport(bufnr)
    if vp or a == nil then
      a, b = vlo, vhi
    elseif vlo then
      -- Only the on-screen part of an edit needs paint now; the rest is
      -- painted by the viewport refresh if it ever scrolls into view.
      a, b = math.max(a, vlo), math.min(b, vhi)
    end
    if a and b and a < b then
      M.paint(bufnr, a, b)
    end
  end))
end

--- WinScrolled and WinResized match their pattern against the WINDOW ID, not
--- the buffer, so `buffer = bufnr` on them produces a `<buffer=N>` pattern that
--- can never fire -- which is how a scroll silently stopped repainting during
--- development. They have to be global, and they dispatch to whichever attached
--- buffers are currently on screen.
---
--- Created with the first attach and deleted with the last, so nothing outlives
--- the feature being in use.
local view_group = nil

local function ensure_view_autocmds()
  if view_group then
    return
  end
  view_group = vim.api.nvim_create_augroup("FortranHighlightView", { clear = true })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "WinEnter" }, {
    group = view_group,
    callback = function()
      for bufnr in pairs(state) do
        if vim.api.nvim_buf_is_loaded(bufnr) and #vim.fn.win_findbuf(bufnr) > 0 then
          schedule(bufnr, nil, nil)
        end
      end
    end,
  })
end

local function drop_view_autocmds()
  if view_group and next(state) == nil then
    pcall(vim.api.nvim_del_augroup_by_id, view_group)
    view_group = nil
  end
end

--- Paint the visible range of `bufnr` now, no debounce. Returns the range.
---@param bufnr integer
function M.refresh(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local lo, hi = M.viewport(bufnr)
  if not lo then
    return
  end
  M.paint(bufnr, lo, hi)
end

--- Drop every mark this module made in `bufnr`.
---@param bufnr integer
function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  end
end

--- Tear down everything attached to `bufnr`. Safe to call twice; called from
--- BufWipeout, from a filetype change away from Fortran, and from
--- nvim_buf_attach's on_detach, so it must be.
---@param bufnr integer
function M.detach(bufnr)
  local st = state[bufnr]
  if not st then
    return
  end
  state[bufnr] = nil
  stop_timer(st)
  if st.group then
    pcall(vim.api.nvim_del_augroup_by_id, st.group)
  end
  drop_view_autocmds()
  M.clear(bufnr)
end

--- True while `bufnr` is attached (test hook).
---@param bufnr integer
---@return boolean
function M.attached(bufnr)
  return state[bufnr] ~= nil
end

--- Number of attached buffers (test hook for leak checks).
---@return integer
function M.attached_count()
  return vim.tbl_count(state)
end

local function is_fortran(bufnr)
  local ft = vim.bo[bufnr].filetype
  return ft == "fortran" or ft == "fortran_free" or ft == "fortran_fixed"
    or ft == "f90" or ft == "f95"
end

--- Attach to a Fortran buffer: paint what is visible, then keep it painted.
---
--- Idempotent -- FileType can fire more than once for the same buffer (a
--- `:setfiletype`, a modeline, reloading the file), and attaching twice would
--- double every extmark and every timer.
---@param bufnr integer|nil
function M.attach(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if state[bufnr] or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local group = vim.api.nvim_create_augroup("FortranHighlightBuf" .. bufnr, { clear = true })
  state[bufnr] = { group = group }

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, b, _, first, last_old, last_new)
      if not state[b] then
        return true -- detach
      end
      -- Stale marks in the replaced span go now, not on the debounce: the
      -- range shrinks when lines are deleted, and marks left in the gap would
      -- be drawn on the wrong text until the timer fired.
      pcall(vim.api.nvim_buf_clear_namespace, b, NS, first, math.max(last_old, last_new))
      schedule(b, first, math.max(last_old, last_new) + 1)
    end,
    on_detach = function(_, b)
      vim.schedule(function()
        M.detach(b)
      end)
    end,
    on_reload = function(_, b)
      schedule(b, nil, nil)
    end,
  })

  ensure_view_autocmds()

  -- The rest do support a buffer-local pattern. CursorHold is the belt for the
  -- braces: it catches any way the viewport moved that WinScrolled missed.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "CursorHold", "InsertLeave" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      schedule(bufnr, nil, nil)
    end,
  })

  -- A buffer that stops being Fortran must stop being painted, and a wiped
  -- buffer must not leave a timer or an augroup behind.
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    buffer = bufnr,
    callback = function()
      if not is_fortran(bufnr) then
        M.detach(bufnr)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.detach(bufnr)
    end,
  })

  M.refresh(bufnr)
end

--- Backwards-compatible name: this used to register `syntax match` rules.
M.apply = M.attach

--- Flip the feature for the session and repaint (or unpaint) every attached
--- buffer. Bound to :FortranHighlightToggle in andrew.fortran.init.
---@return boolean now on?
function M.toggle()
  local now = not M.enabled()
  vim.g.fortran_highlight = now
  for bufnr in pairs(state) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      if now then
        M.refresh(bufnr)
      else
        M.clear(bufnr)
      end
    end
  end
  return now
end

return M
