-- =============================================================================
-- Fortran symbol pickers: definitions AND call sites
-- =============================================================================
-- fortls answers `textDocument/documentSymbol` and `workspace/symbol` with
-- DEFINITIONS only. Searching for `Heating` therefore finds the one line that
-- declares it and none of the places it is used, which is backwards from how
-- you actually read Fortran -- `call Heating(...)` is the interesting line.
--
-- These two pickers merge both halves into one list:
--
--   [subroutine] the definition, from a scan equivalent to fortls's own
--   [call]       every `call NAME`, with arbitrary whitespace between the two
--   [ref]        every `NAME(` where NAME is a procedure the project defines
--   [var]        every declared variable, including COMMON block members
--   [arg]        every dummy argument of a procedure header
--   [common]     every COMMON block name
--   [varref]     every USE of a declared variable
--
-- The `ref` class is restricted to project-defined names on purpose. Fortran
-- spells a function call and an array reference identically -- `Heating(t)`
-- and `arr(i)` are the same syntax -- so the only sound way to tell them apart
-- without full semantic analysis is to ask whether the project defines a
-- procedure by that name. An unrestricted `NAME(` scan would bury the results
-- under every array index in the file.
--
-- SCALE. Variable references dominate the list: on the fifteen-thousand-line
-- project this was measured against they are 19505 rows against 2085
-- declarations, 462 call sites and 114 definitions. That is by request -- every
-- reference is in the picker so it can be jumped to -- and it is only usable
-- because fzf matches the first field alone, so a query narrows 22000 rows to
-- the handful that name the symbol you typed. M.references (bound to `gr`, and
-- :FortranReferences) still exists for the narrower question: every use of ONE
-- name, with no other symbol in the list.
--
-- ENTRY LAYOUT. Rows are laid out the way fzf-lua lays out LSP document
-- symbols -- location first, then the symbol -- so a Fortran picker and a
-- basedpyright picker read the same:
--
--     9:19  [󰀫 Variable] T_e_new
--    10:17  [󰀫 Variable] ixcell
--
-- Each row is nbsp-separated fields, and fzf is told `--with-nth 2..` so the
-- FIRST one never appears:
--
--   code/solver.f90:12:17:<nbsp>  12:17<nbsp>[󰊕 Call] Heating
--   \____________________/        \_____/  \_______________/
--     parsed, never shown          shown       shown + searched
--
-- Field 1 is what fzf-lua's path.entry_to_file reads: it splits on the nbsp,
-- takes the first part shaped like `path:lnum:col:` and hands back the jump
-- target. Its trailing colon is load-bearing -- without it the column runs into
-- the next field and comes back as 0. fzf reports the ORIGINAL line on
-- selection, not the `--with-nth` view, so hiding the field costs nothing.
--
-- `--nth 2` then scopes matching to the symbol -- indices count fields of the
-- `--with-nth` VIEW, so field 2 there is field 3 here. Without it, matching
-- runs over the location too and a short query like "dift" fuzzy-matches a
-- subsequence spread across a file path, burying every real hit.

local scan = require("andrew.fortran.scan")

local M = {}

-- Separator between the searchable half of an entry and its location.
--
-- This MUST be the character fzf-lua's path.entry_to_file splits on, or the
-- picker opens looking correct and jumps nowhere. Read out of fzf-lua so the
-- two cannot drift; the fallback is U+2002 EN SPACE, its value today, and
-- exists for headless tests that run without the plugin on the runtimepath.
local SEPARATOR_FALLBACK = "\226\128\130"

---@return string
function M.separator()
  local ok, utils = pcall(require, "fzf-lua.utils")
  if ok and type(utils.nbsp) == "string" and utils.nbsp ~= "" then
    return utils.nbsp
  end
  return SEPARATOR_FALLBACK
end

-- ---------------------------------------------------------------------------
-- Symbol presentation
-- ---------------------------------------------------------------------------
-- Rows are styled the way fzf-lua styles LSP symbols, which is what you see
-- from basedpyright and every other server: a bracketed, coloured
-- `<glyph> <Kind>` block, then the name, with nested symbols indented under
-- their container.
--
-- The glyph, the colour, the bracket wrapper and the indent unit are all read
-- out of the user's own `lsp.symbols` fzf-lua config rather than reinvented,
-- so a Fortran subroutine and a Python function look identical and stay that
-- way if the config changes.
--
-- The KIND NAMES are Fortran's, not the LSP's -- `Subroutine`, not `Function`;
-- `Common`, not `Object` -- because that is the vocabulary of the language you
-- are reading. Each maps to an LSP SymbolKind only to borrow its glyph and
-- highlight group.
local KINDS = {
  program      = { label = "Program",    lsp = "Module" },
  module       = { label = "Module",     lsp = "Module" },
  submodule    = { label = "Submodule",  lsp = "Namespace" },
  subroutine   = { label = "Subroutine", lsp = "Function" },
  ["function"] = { label = "Function",   lsp = "Function" },
  interface    = { label = "Interface",  lsp = "Interface" },
  type         = { label = "Type",       lsp = "Struct" },
  common       = { label = "Common",     lsp = "Object" },
  var          = { label = "Variable",   lsp = "Variable" },
  arg          = { label = "Argument",   lsp = "TypeParameter" },
  -- `call NAME` and `NAME(...)` are both invocations; the distinction between
  -- the two scans is an implementation detail, not something to read past.
  call         = { label = "Call",       lsp = "Method" },
  ref          = { label = "Call",       lsp = "Method" },
  varref       = { label = "Ref",        lsp = "Variable" },
}

-- fzf-lua derives a symbol's colour from `"@" .. kind:lower()`, and most
-- colorschemes define only a handful of those: here `@function`, `@variable`,
-- `@module`, `@property`, `@constant`, `@constructor` and `@operator` have
-- colours and `@method`, `@interface`, `@struct`, `@namespace`, `@object` and
-- `@typeparameter` do not. Taking that literally would leave every call site
-- and every dummy argument grey, which reads as broken rather than faithful,
-- so each kind carries fallbacks and the first group the colorscheme actually
-- paints wins. A kind fzf-lua already colours never reaches this table.
local HL_FALLBACKS = {
  Method        = { "@function.method", "@function" },
  Interface     = { "@type.definition", "@type", "Type" },
  Struct        = { "@type", "Type", "Structure" },
  Namespace     = { "@module", "@namespace" },
  Object        = { "@constant", "Constant" },
  TypeParameter = { "@variable.parameter", "@parameter", "Identifier" },
  Field         = { "@variable.member", "Identifier" },
}

-- Resolved highlight per LSP kind. "Does this group have a colour" is the only
-- question being cached, so the answer stands until the colorscheme changes.
local hl_cache = {}

--- The highlight group to paint `kind` with: fzf-lua's own choice when the
--- colorscheme defines it, else the first fallback it does define.
---@param utils table fzf-lua.utils
---@param preferred string
---@param kind string LSP SymbolKind name
---@return string
local function resolve_hl(utils, preferred, kind)
  if hl_cache[kind] then
    return hl_cache[kind]
  end

  local chosen = preferred
  -- ansi_from_hl returns the string unchanged when the group paints nothing.
  if utils.ansi_from_hl(preferred, "x") == "x" then
    for _, candidate in ipairs(HL_FALLBACKS[kind] or {}) do
      if utils.ansi_from_hl(candidate, "x") ~= "x" then
        chosen = candidate
        break
      end
    end
  end
  hl_cache[kind] = chosen
  return chosen
end

--- fzf-lua's LSP symbol styling config, or nil when fzf-lua is not loadable
--- (headless specs).
---
--- The MODULE is cached, the config table is not: `require` is looked up once
--- but the three fields below are re-read every call, so a runtime change to
--- `lsp.symbols` still takes effect. Caching matters -- this is called once per
--- entry, and a `pcall(require, ...)` per row costs half a second on the
--- twenty-thousand-row workspace picker.
---@return table|nil
local fzf_config = nil
local function symbol_config()
  if fzf_config == nil then
    local ok, cfg = pcall(require, "fzf-lua.config")
    fzf_config = (ok and type(cfg) == "table") and cfg or false
  end
  if not fzf_config or type(fzf_config.globals) ~= "table" then
    return nil
  end
  local lsp = fzf_config.globals.lsp
  return lsp and lsp.symbols or nil
end

-- One block per kind against twenty thousand rows, so this is memoized.
local block_cache = {}

--- Drop every resolved style. Called on a colorscheme change, and by the specs
--- when they swap a stubbed fzf-lua config in and out.
function M._reset_style_cache()
  fzf_config, hl_cache, block_cache = nil, {}, {}
end

-- Invalidation is an autocmd rather than a key recomputed per row: reading
-- `vim.g.colors_name` and formatting a table address twenty thousand times cost
-- 1.5 SECONDS on the workspace picker, against a few microseconds for a
-- colorscheme change nobody makes mid-picker.
local watching_colorscheme = false
local function watch_colorscheme()
  if watching_colorscheme then
    return
  end
  watching_colorscheme = true
  vim.api.nvim_create_autocmd({ "ColorScheme", "OptionSet" }, {
    group = vim.api.nvim_create_augroup("FortranSymbolStyle", { clear = true }),
    callback = function(ev)
      if ev.event ~= "OptionSet" or ev.match == "background" then
        M._reset_style_cache()
      end
    end,
  })
end

--- The indent unit for one nesting level, mirroring fzf-lua's `child_prefix`.
---@return string
function M.child_prefix()
  local cfg = symbol_config()
  local prefix = cfg and cfg.child_prefix
  if prefix == nil or prefix == true then
    return "  "
  end
  return type(prefix) == "string" and prefix or ""
end

--- The bracketed kind block for one record.
---
--- `plain` and `styled` differ by however many escape bytes the colour costs,
--- and a glyph is several bytes but one or two cells, so neither byte length
--- lines a column up. `width` is what is actually drawn.
---@param item table
---@return { plain: string, styled: string, width: integer }
function M.kind_block(item)
  watch_colorscheme()
  local cached = block_cache[item.kind]
  if cached then
    return cached
  end

  local kind = KINDS[item.kind] or { label = item.kind, lsp = "Object" }
  local cfg = symbol_config()
  local text, styled = kind.label, nil

  if cfg then
    local style = tonumber(cfg.symbol_style)
    local icon = cfg.symbol_icons and cfg.symbol_icons[kind.lsp]
    if icon and (style == 1 or style == 2) then
      text = style == 2 and icon or (icon .. " " .. kind.label)
    end
    if type(cfg.symbol_hl) == "function" then
      local ok, utils = pcall(require, "fzf-lua.utils")
      if ok then
        local hl = resolve_hl(utils, cfg.symbol_hl(kind.lsp), kind.lsp)
        styled = utils.ansi_from_hl(hl, text)
      end
    end
  end
  styled = styled or text

  local plain, out
  if cfg and type(cfg.symbol_fmt) == "function" then
    plain = cfg.symbol_fmt(text, {}) or text
    out = cfg.symbol_fmt(styled, {}) or styled
  else
    plain, out = "[" .. text .. "]", "[" .. styled .. "]"
  end

  local block = { plain = plain, styled = out, width = vim.fn.strdisplaywidth(plain) }
  block_cache[item.kind] = block
  return block
end

-- Upper bound on the padding used to line columns up. One absurdly long name
-- or path should not push every other row off the screen.
local MAX_NAME_COLUMN = 48
local MAX_LOCATION_COLUMN = 56

--- The two escape sequences fzf-lua paints line and column numbers with, and
--- the reset. Fetched once per build: `ansi_from_hl` returns the sequence as
--- its second value, so a row costs two concatenations instead of two calls.
---@return { linenr: string, colnr: string, clear: string }
local function location_ansi()
  local ok, utils = pcall(require, "fzf-lua.utils")
  if not ok or type(utils.ansi_from_hl) ~= "function" then
    return { linenr = "", colnr = "", clear = "" }
  end
  local cfg = select(2, pcall(require, "fzf-lua.config"))
  local hls = (type(cfg) == "table" and (cfg.globals or cfg.defaults) or {}).hls or {}
  local _, linenr = utils.ansi_from_hl(hls.path_linenr or "FzfLuaPathLineNr", "x")
  local _, colnr = utils.ansi_from_hl(hls.path_colnr or "FzfLuaPathColNr", "x")
  return {
    linenr = linenr or "",
    colnr = colnr or "",
    clear = (linenr or colnr) and (utils.ansi_escseq or {}).clear or "",
  }
end

-- Ordering when two records land on the same byte: a definition outranks a
-- call, which outranks a bare reference. Without this the `NAME(` scan would
-- report every definition line twice, once as [subroutine] and once as [ref].
local PRECEDENCE = {
  program = 1, module = 1, submodule = 1, subroutine = 1, ["function"] = 1,
  type = 1, interface = 1,
  common = 2, var = 2, arg = 2,
  call = 3,
  ref = 4,
  -- A variable reference has no entry: the default rank is below every named
  -- one, which is exactly where it belongs. `dift` on its own COMMON line is
  -- both a declaration and an occurrence, and the declaration is the row worth
  -- keeping.
}

--- Merge, de-duplicate and sort scan records into fzf entries.
---@param items table[] records with path/lnum/col/name/kind and optional text
---@param root string used to shorten displayed paths
---@param lines_for fun(path: string): string[]|nil source of the display text
---@param opts { show_path?: boolean, source_column?: boolean }|nil
---@return string[]
function M.build_entries(items, root, lines_for, opts)
  opts = opts or {}
  local best = {}
  local order = {}

  for _, item in ipairs(items) do
    local key = table.concat({ item.path or "", item.lnum, item.col }, ":")
    local prev = best[key]
    if not prev then
      best[key] = item
      order[#order + 1] = key
    elseif (PRECEDENCE[item.kind] or 9) < (PRECEDENCE[prev.kind] or 9) then
      best[key] = item
    end
  end

  local records = {}
  for _, key in ipairs(order) do
    records[#records + 1] = best[key]
  end

  table.sort(records, function(a, b)
    local pa, pb = a.path or "", b.path or ""
    if pa ~= pb then
      return pa < pb
    end
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)

  local prefix = root and (root:gsub("/*$", "") .. "/") or nil
  local separator = M.separator()
  local indent_unit = M.child_prefix()
  local indent_width = vim.fn.strdisplaywidth(indent_unit)
  local ansi = location_ansi()

  -- Two passes: the first builds every field, the second pads the location and
  -- symbol columns to a common width so they line up.
  --
  -- Padding is measured on PLAIN text and applied to STYLED text. The two
  -- differ by however many bytes the colour escapes cost, and a glyph is
  -- several bytes wide but one or two cells, so neither `#s` nor `%-Ns` can
  -- align a coloured row -- only the display width can.
  local rows, loc_width, sym_width = {}, 0, 0
  for _, rec in ipairs(records) do
    local path = rec.path or ""
    local display_path = path
    if prefix and path:sub(1, #prefix) == prefix then
      display_path = path:sub(#prefix + 1)
    end

    local depth = rec.depth or 0
    local block = M.kind_block(rec)
    -- Fortran identifiers and paths are ASCII, and so are the indent and the
    -- separating space, so the only cell width that is not a byte count is the
    -- kind block's -- which the cache already measured.
    local symbol_cells = depth * indent_width + block.width + 1 + #rec.name
    sym_width = math.max(sym_width, symbol_cells)

    local numbers = ansi.linenr .. rec.lnum .. ansi.clear
      .. ":" .. ansi.colnr .. rec.col .. ansi.clear
    local location = opts.show_path and (display_path .. ":" .. numbers) or numbers
    local location_cells = #tostring(rec.lnum) + 1 + #tostring(rec.col)
      + (opts.show_path and (#display_path + 1) or 0)
    loc_width = math.max(loc_width, location_cells)

    local source
    if opts.source_column then
      source = rec.text
      if not source and lines_for then
        local lines = lines_for(path)
        source = lines and lines[rec.lnum]
      end
      source = (source or rec.name):gsub("^%s+", ""):gsub("%s+$", "")
    end

    rows[#rows + 1] = {
      parse = string.format("%s:%d:%d:", display_path, rec.lnum, rec.col),
      location = location,
      location_cells = location_cells,
      symbol = string.rep(indent_unit, depth) .. block.styled .. " " .. rec.name,
      symbol_cells = symbol_cells,
      source = source,
    }
  end

  loc_width = math.min(loc_width, MAX_LOCATION_COLUMN)
  sym_width = math.min(sym_width, MAX_NAME_COLUMN)

  local entries = {}
  for _, row in ipairs(rows) do
    local loc_pad = string.rep(" ", math.max(0, loc_width - row.location_cells))
    -- The line number reads as a column of numbers, so it is right-aligned
    -- when it stands alone and left-aligned when a path leads it.
    local location = opts.show_path and (row.location .. loc_pad) or (loc_pad .. row.location)

    local fields = { row.parse, location, row.symbol }
    if row.source then
      fields[3] = row.symbol .. string.rep(" ", math.max(0, sym_width - row.symbol_cells))
      fields[4] = row.source
    end
    entries[#entries + 1] = table.concat(fields, separator)
  end

  return entries
end

--- Open an fzf-lua picker over pre-built `path:lnum:col:text` entries.
---@param entries string[]
---@param title string
---@param root string
---@param opts { prompt?: string, whole_row?: boolean, empty?: string }|nil
local function pick(entries, title, root, opts)
  opts = opts or {}
  local fzf = require("fzf-lua")
  if #entries == 0 then
    vim.notify(opts.empty or "No Fortran symbols found", vim.log.levels.WARN)
    return
  end
  local fzf_opts = {
    ["--delimiter"] = M.separator(),
    -- Hide field 1, the machine-readable location. See the entry-layout note
    -- at the top of this file.
    ["--with-nth"] = "2..",
    -- Prefer hits that start at the name rather than somewhere inside it.
    ["--tiebreak"] = "begin",
    ["--multi"] = true,
  }
  if not opts.whole_row then
    -- Match the symbol alone. Field 2 OF THE VIEW is field 3 of the entry.
    fzf_opts["--nth"] = "2"
  end
  fzf.fzf_exec(entries, {
    prompt = opts.prompt or "Fortran Symbols> ",
    cwd = root,
    previewer = "builtin",
    -- A TABLE keyed by the fzf binding, never the bare function: fzf-lua
    -- normalizes `actions` by indexing it, so passing a function leaves the
    -- picker with no `enter` binding at all and <CR> silently does nothing.
    actions = { ["enter"] = fzf.actions.file_edit_or_qf },
    winopts = { title = " " .. title .. " ", title_pos = "center" },
    fzf_opts = fzf_opts,
  })
end

--- True when `ft` is one of the Fortran filetypes this config uses.
---@param ft string
---@return boolean
function M.is_fortran(ft)
  return ft == "fortran" or ft == "fortran_free" or ft == "fortran_fixed"
end

-- ---------------------------------------------------------------------------
-- Document symbols: definitions + call sites in the current buffer
-- ---------------------------------------------------------------------------

--- Definitions, declarations, calls and references in the current buffer, from
--- the BUFFER (so unsaved edits are included).
---
--- The project is still consulted, for two sets that cannot be derived from one
--- file: which names are procedures (that decides whether `Foo(x)` on screen is
--- a call or an array index) and which names are declared variables. The second
--- matters more than it sounds -- in F77-descended code the declarations live
--- in `.h` includes, so a buffer that uses fifty variables often declares none
--- of them.
---
--- Rows are indented by program-unit nesting, the way an LSP client indents
--- nested documentSymbol children.
function M.document()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    vim.notify("Buffer has no file name", vim.log.levels.WARN)
    return
  end
  local root = scan.project_root(vim.fn.fnamemodify(path, ":h"))
  local buf_scan = scan.scan_buffer(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local function finish(project_defs, project_decls)
    local procedures = {}
    for _, d in ipairs(project_defs or {}) do
      procedures[d.lname] = true
    end
    for _, d in ipairs(buf_scan.defs) do
      procedures[d.lname] = true
    end

    local variables = {}
    for _, list in ipairs({ project_decls or {}, buf_scan.decls }) do
      for _, d in ipairs(list) do
        if d.kind ~= "common" then
          variables[d.lname] = true
        end
      end
    end

    local depths = scan.nesting_depths(buf_scan.masked, buf_scan.defs)
    local items = {}
    local function take(list, filter)
      for _, rec in ipairs(list) do
        if not filter or filter(rec) then
          rec.path = path
          rec.depth = depths[rec.lnum] or 0
          items[#items + 1] = rec
        end
      end
    end

    take(buf_scan.defs)
    take(buf_scan.decls)
    take(buf_scan.calls)
    take(buf_scan.refs, function(rec)
      return procedures[rec.lname]
    end)
    take(scan.variable_refs(buf_scan.masked, lines, variables))

    -- No path column: every row is this file.
    local entries = M.build_entries(items, root, function()
      return lines
    end)
    pick(entries, "Fortran Document Symbols", root)
  end

  if vim.fn.executable("rg") ~= 1 then
    finish(nil, nil)
    return
  end
  scan.project_definitions(root, function(defs)
    scan.project_declarations(root, function(decls)
      finish(defs, decls)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Workspace symbols: definitions + call sites across the project
-- ---------------------------------------------------------------------------

--- Project-wide definitions, declarations, call sites and variable references.
--- Reads from DISK via ripgrep, so unsaved changes in the current buffer are
--- not reflected -- same contract as every other grep-backed picker here.
---
--- Flat, not indented: this is the workspace list, and an LSP client's
--- workspace/symbol answer is flat too.
function M.workspace()
  local root = scan.project_root()

  -- Two independent chains: definitions must precede the call scan (which
  -- needs the procedure names) and declarations must precede the reference
  -- scan (which needs the variable names), but the two chains need nothing
  -- from each other. Running them at the same time halves the wait, and the
  -- reference scan is the long pole.
  local items, pending = {}, 2

  local function done()
    pending = pending - 1
    if pending == 0 then
      pick(
        M.build_entries(items, root, nil, { show_path = true }),
        "Fortran Workspace Symbols",
        root
      )
    end
  end

  --- Unique lowercase names of one kind class, for the follow-up scan.
  local function unique(records, skip_kind)
    local names, seen = {}, {}
    for _, d in ipairs(records) do
      if d.kind ~= skip_kind and not seen[d.lname] then
        seen[d.lname] = true
        names[#names + 1] = d.lname
      end
    end
    return names
  end

  scan.project_definitions(root, function(defs)
    vim.list_extend(items, defs)
    scan.project_calls(root, unique(defs), function(calls)
      vim.list_extend(items, calls)
      done()
    end)
  end)

  scan.project_declarations(root, function(decls)
    vim.list_extend(items, decls)
    scan.project_variable_refs(root, unique(decls, "common"), function(varrefs)
      vim.list_extend(items, varrefs)
      done()
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- References: every use of ONE name
-- ---------------------------------------------------------------------------

--- Every occurrence of `name` across the project, classified.
---
--- This is the variable half of "find usages". fortls answers
--- textDocument/references only for symbols it understands, which in
--- F77-descended code excludes most of them: a name declared by appearing in a
--- COMMON block inside a `.h` include, with no type declaration anywhere
--- because IMPLICIT typing gave it one, is not a symbol any Fortran server has
--- heard of. The scanner has no such gap -- it reads include files, ignores
--- comments and string literals, and needs no server running.
---
--- Matching here runs over the WHOLE row, not just the name: every row names
--- the same symbol, so the useful way to narrow is by file or by surrounding
--- code.
---@param name string|nil defaults to the word under the cursor
function M.references(name)
  name = name and name:gsub("^%s+", ""):gsub("%s+$", "") or vim.fn.expand("<cword>")
  if not name:match("^[%a_][%w_]*$") then
    vim.notify("Not a Fortran identifier: " .. name, vim.log.levels.WARN)
    return
  end
  local root = scan.project_root()
  scan.project_references(root, name, function(refs)
    pick(
      M.build_entries(refs, root, nil, { show_path = true, source_column = true }),
      "Fortran References: " .. name,
      root,
      {
        prompt = "Fortran References> ",
        whole_row = true,
        empty = "No references to " .. name,
      }
    )
  end)
end

return M
