-- textDocument/completion + completionItem/resolve for Fortran.
--
-- WHY THIS EXISTS
--
-- This replaces `andrew.fortran.blink-source`, a blink.cmp source that handed
-- the SAME 388 items to every completion round in every context. Three things
-- were wrong with that and none of them could be fixed where it lived:
--
--   * It never saw the line. On `!$OMP PARALLEL DO PRIV` it offered the same
--     list it offers in a declaration, so the menu's top entries were the
--     PARITY intrinsic and a snippet, and the OpenMP clause was eighth.
--   * It had no `textEdit`, so blink inserted the LABEL -- and the labels were
--     documentation keys, not Fortran. Accepting the clause entry wrote
--     `!$OMP PARALLEL DO omp_private`, which is not a program.
--   * It shipped every markdown body on every keystroke, because a blink
--     source has nowhere to put a lazy document.
--
-- An LSP completion has the three fields that fix all of it: `textEdit` says
-- what to INSERT (`PRIVATE($1)`) independently of what to SHOW (`PRIVATE(…)`),
-- `filterText` says what to MATCH (`private`) independently of both, and
-- `resolveProvider` keeps the prose off the wire until one item is selected.
-- The request carries the line and the cursor, so the answer can depend on
-- where the cursor is.
--
-- THE CONTEXT RULE
--
-- Two contexts, decided from the line alone:
--
--   half-typed sentinel (`!$OM`) the `$` trigger's window  -> `OMP <DIRECTIVE>`
--   directive line (`!$OMP …`)   right after the sentinel -> DIRECTIVES
--                                after a directive word   -> that directive's CLAUSES
--   ordinary line                identifier prefix        -> the registry
--
-- The two never mix. Off a directive line no clause is ever offered -- `private`
-- there is the Fortran statement, `do` is the loop -- and on a directive line
-- nothing from MPI or the keyword list is, because the words on that line are
-- clause names and clause arguments.
--
-- WHY NO INTRINSICS
--
-- blink concatenates the item lists of every attached client and does not
-- dedupe (`sources/lsp/init.lua:78-85`). fortls already returns the Fortran
-- intrinsics, so every intrinsic we added would appear twice. We answer
-- exactly what fortls cannot: MPI, OpenMP, the statement keywords.
--
-- SORT BUCKETS
--
-- basedpyright's `XX.YYYY.name` scheme (`completionProvider.ts:3604-3629`):
--
--   00  a syntactically required keyword -- on a directive line, the directives
--       and clauses ARE the grammar, so they outrank everything
--   09  a normal symbol: MPI and omp_lib procedures, constants, modules
--   10  a Fortran statement keyword
--   12  a name that merely REPEATS a VS Code snippet prefix in ./snippets
--
-- Bucket 12 is the one lesson worth carrying over from the blink source: those
-- items used to outrank the snippet of the same name, so `ompdo<CR>` inserted
-- the literal word instead of expanding the block. It was a `score_offset`
-- there; it is a sort bucket here, which is the portable spelling.

local M = {}

local openmp = require("andrew.fortran.openmp")
local registry = require("andrew.fortran.registry")
local render = require("andrew.fortran.render")

--- LSP CompletionItemKind for each registry kind.
local KIND = {
  subroutine = 3, -- Function
  ["function"] = 3,
  module = 9, -- Module
  constant = 21, -- Constant
  keyword = 14, -- Keyword
  directive = 14,
  clause = 14,
  type = 22, -- Struct
}

--- Sort buckets, above.
local B_GRAMMAR, B_SYMBOL, B_KEYWORD, B_SNIPPET = 0, 9, 10, 12

--- Modules worth offering after `use`. `mpi` is not a registry entry of its
--- own (the 700 MPI names are), but `use mpi` is the line this config's
--- project actually writes, so it is offered without documentation rather
--- than not offered at all.
local USE_EXTRA = { { lname = "mpi", name = "mpi" } }

-- ---------------------------------------------------------------------------
-- Snippet prefixes
-- ---------------------------------------------------------------------------

---@type table<string, boolean>|nil
local snippet_triggers = nil
---@type table[]|nil
local ordinary = nil
---@type table[]|nil
local directives = nil

--- This config's own snippets directory, resolved from THIS file's path.
---
--- Not `stdpath("config")`: every spec in this repo runs under `nvim -u NONE`,
--- where the two differ. Same rule as `registry.data_dir`.
---@return string
local function snippet_dir()
  local src = debug.getinfo(1, "S").source
  local path = src:sub(1, 1) == "@" and src:sub(2) or src
  return vim.fn.fnamemodify(path, ":p:h:h:h:h") .. "/snippets"
end

--- Every VS Code snippet prefix this config contributes, lowercased.
---
--- Ported from `blink-source.lua:get_snippet_triggers`. A registry name that
--- is also a snippet prefix (`mpi_init`, `do`, `if`) must not outrank the
--- snippet of that name, or accepting it inserts the bare word where the user
--- was expanding a block -- so it lands in sort bucket 12.
---@return table<string, boolean>
function M.snippet_prefixes()
  if snippet_triggers then
    return snippet_triggers
  end
  snippet_triggers = {}

  local dir = snippet_dir()
  local pkg = io.open(dir .. "/package.json", "r")
  if not pkg then
    return snippet_triggers
  end
  local ok, manifest = pcall(vim.json.decode, pkg:read("*a"))
  pkg:close()
  if not ok or type(manifest) ~= "table" then
    return snippet_triggers
  end

  for _, entry in ipairs((manifest.contributes or {}).snippets or {}) do
    local rel = type(entry) == "table" and entry.path
    if type(rel) == "string" then
      local f = io.open(dir .. "/" .. rel:gsub("^%./", ""), "r")
      if f then
        local ok_snips, snips = pcall(vim.json.decode, f:read("*a"))
        f:close()
        if ok_snips and type(snips) == "table" then
          for _, snip in pairs(snips) do
            local prefix = type(snip) == "table" and snip.prefix
            if type(prefix) == "string" then
              prefix = { prefix }
            end
            if type(prefix) == "table" then
              for _, p in ipairs(prefix) do
                if type(p) == "string" then
                  snippet_triggers[p:lower()] = true
                end
              end
            end
          end
        end
      end
    end
  end
  return snippet_triggers
end

--- Drop every cache. Tests call this after `registry.reset()`.
function M.reset()
  snippet_triggers, ordinary, directives = nil, nil, nil
end

-- ---------------------------------------------------------------------------
-- Candidate sets
-- ---------------------------------------------------------------------------

--- Every completable non-directive entry, sorted, as `{lname, entry, origin}`.
---
--- Built from `registry.names()` rather than `registry.entries()` because the
--- LOWERCASE KEY is what `data.k` must carry -- an entry's display name is not
--- always its key (`double precision` is keyed `doubleprecision`).
---@return table[]
local function ordinary_candidates()
  if ordinary then
    return ordinary
  end
  ordinary = {}
  for lname, origin in pairs(registry.names()) do
    local e = registry.get(lname)
    if e then
      ordinary[#ordinary + 1] = { lname = lname, entry = e, origin = origin }
    end
  end
  table.sort(ordinary, function(a, b)
    return a.lname < b.lname
  end)
  return ordinary
end

--- Every directive and clause, sorted, as `{lname, entry}`.
---
--- `registry.entries()` cannot answer this: directives and clauses are kept
--- out of the general index on purpose (a bare `private` off a directive line
--- is the Fortran statement), so they are read from the raw table that
--- `registry.load()` returns.
---@return table[] directives, table[] clauses
local function directive_candidates()
  if directives then
    return directives[1], directives[2]
  end
  local dirs, clauses = {}, {}
  local files = registry.load()
  for lname, e in pairs(files.openmp or {}) do
    if lname ~= "_meta" and type(e) == "table" then
      if e.kind == "directive" then
        dirs[#dirs + 1] = { lname = lname, entry = e }
      elseif e.kind == "clause" then
        clauses[#clauses + 1] = { lname = lname, entry = e }
      end
    end
  end
  local by_name = function(a, b)
    return a.lname < b.lname
  end
  table.sort(dirs, by_name)
  table.sort(clauses, by_name)
  directives = { dirs, clauses }
  return dirs, clauses
end

-- ---------------------------------------------------------------------------
-- Line context
-- ---------------------------------------------------------------------------

--- The identifier being typed, ending at `col` (0-based byte offset).
---@param line string
---@param col integer
---@return string prefix lowercase, "" when none
local function typed_prefix(line, col)
  local before = line:sub(1, col)
  return (before:match("([%a_][%w_]*)$") or ""):lower()
end

--- Length-preserving comment/string mask of `line`, lowercased.
---@param line string
---@param fixed boolean|nil
---@return string
local function masked(line, fixed)
  if not line:find("[!'\"]") and not fixed then
    return line:lower()
  end
  return require("andrew.fortran.scan").mask(line, fixed and true or false)
end

--- True when the cursor at `col` sits inside a comment or a string literal.
---
--- The test is on the last non-blank byte at or before the cursor: if masking
--- blanked it, the cursor is inside something that is not code. That covers
--- both `! call MPI_Comm_r|` (the whole tail is blanked) and a cursor sitting
--- one space past a `'literal'`.
---@param line string
---@param col integer 0-based byte offset
---@param fixed boolean|nil
---@return boolean
local function in_comment(line, col, fixed)
  local m = masked(line, fixed)
  local i = col
  while i > 0 and line:sub(i, i):match("%s") do
    i = i - 1
  end
  if i == 0 then
    return false
  end
  return m:sub(i, i) ~= line:sub(i, i):lower()
end

--- `line` with a bare `!$` conditional-compilation sentinel blanked out.
---
--- `!$ use omp_lib` is ORDINARY Fortran that only compiles under -fopenmp, so
--- the text after the sentinel must complete like code -- but the masker (and
--- every compiler without the flag) sees a comment and blanks the whole line.
--- Blanking just the two sentinel bytes is length-preserving, so every column
--- still means what it meant. Directive lines never reach here, and neither
--- does `!$acc`: an OpenACC line is a comment to a Fortran compiler and must
--- complete like one.
---@param line string
---@return string
local function code_view(line)
  local kind, sentinel = openmp.sentinel(line)
  if kind ~= "conditional" or not sentinel then
    return line
  end
  return (" "):rep(sentinel) .. line:sub(sentinel + 1)
end

--- Where the cursor sits on an OpenMP directive line.
---
--- Returns `nil` when `line` is not an `!$OMP` line at all -- a bare `!$`
--- sentinel is conditional compilation of ORDINARY Fortran, so `!$ use
--- omp_lib` completes like code and not like a directive, and `!$acc` is
--- OpenACC, whose clause names are not the ones in this registry.
---
--- `openmp.sentinel` has already established that `omp` follows the `$`
--- immediately and as a whole token, so the directive word starts three bytes
--- past it. `!$ omp parallel` -- a space between the two -- is a conditional
--- line under the OpenMP 5.2 §3.2.2 grammar, not a directive.
---@param line string
---@param col integer 0-based byte offset
---@param prefix string the identifier being typed
---@return { clause: boolean, head: string }|nil
local function directive_context(line, col, prefix)
  local kind, sentinel = openmp.sentinel(line)
  if kind ~= "directive" or not sentinel then
    return nil
  end
  local omp_end = sentinel + 3
  -- Text between the `OMP` token and the first byte of the typed prefix.
  local pstart = col - #prefix
  local head = pstart >= omp_end and line:sub(omp_end + 1, pstart) or ""
  return { clause = head:find("%S") ~= nil, head = head }
end

--- The half-typed sentinel under the cursor: `!$`, `!$O`, `!$OM`, `!$OMP`.
---
--- `$` is this server's ONE completion trigger character (design E1), and
--- until this window existed it triggered nothing a user could use: at `!$`
--- the typed prefix is empty so the answer was zero items, and at `!$OM` the
--- sentinel was blanked by `code_view` and `om` completed as ordinary code --
--- 168 `omp_lib` runtime routines, every one of them illegal on a directive
--- line. Inside the window the only legal continuation is `OMP ` plus a
--- directive name, so that is the whole list.
---
--- The tail must be blank: a cursor parked in front of existing text is an
--- edit of a line that already has a directive on it, not a fresh sentinel.
---@param line string
---@param col integer 0-based byte offset of the cursor
---@return integer|nil send 1-based byte index of the sentinel's `$`
local function sentinel_window(line, col)
  local before = line:sub(1, col)
  local _, send = before:find("^%s*[!cC%*]%$")
  if not send then
    return nil
  end
  if not before:sub(send + 1):match("^[oO]?[mM]?[pP]?$") then
    return nil
  end
  if line:sub(col + 1):find("%S") then
    return nil
  end
  return send
end

--- The directive entry named by the words of `head`, longest match first.
---
--- `head` on `!$OMP PARALLEL DO PRIVATE(i) SHA|` is ` PARALLEL DO PRIVATE(i) `,
--- whose leading identifier words are PARALLEL, DO, PRIVATE; `parallel_do`
--- resolves and `parallel_do_private` does not, so PARALLEL DO wins. Knowing
--- WHICH directive is what makes `NOWAIT` disappear from a `PARALLEL DO` line,
--- where it is illegal.
---@param head string
---@return table|nil
local function head_directive(head)
  local words = {}
  for word in head:gmatch("[%a_][%w_]*") do
    words[#words + 1] = word:lower()
  end
  for n = #words, 1, -1 do
    local e = registry.directive(table.concat(words, "_", 1, n))
    if e and e.kind == "directive" then
      return e
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Item construction
-- ---------------------------------------------------------------------------

---@param lnum integer 0-based line
---@param col integer 0-based byte offset of the cursor
---@param prefix string
---@return table
local function edit_range(lnum, col, prefix)
  return {
    start = { line = lnum, character = col - #prefix },
    ["end"] = { line = lnum, character = col },
  }
end

--- `XX.YYYY.name`, the shape every sortText in this module has.
---@param bucket integer
---@param rank integer
---@param lname string
---@return string
local function sort_text(bucket, rank, lname)
  return ("%02d.%04d.%s"):format(bucket, rank, lname)
end

--- True when `p` is a prefix of any spelling of the multi-word name `lname`.
---
--- A directive is keyed `parallel_do` and displayed `PARALLEL DO`, and both
--- `par` and `paralleldo` are things a user types for it.
---@param lname string
---@param p string lowercase
---@return boolean
local function matches(lname, p)
  if p == "" then
    return true
  end
  if lname:sub(1, #p) == p then
    return true
  end
  local spaced = lname:gsub("_", " ")
  local flat = lname:gsub("_", "")
  return spaced:sub(1, #p) == p or flat:sub(1, #p) == p
end

--- What blink should MATCH this directive on.
---
--- `filterText` defaults to the displayed spelling (`parallel do`, so `par`
--- matches). A user typing the run-together spelling gets the run-together
--- filterText instead, so `paralleldo` matches by prefix rather than relying
--- on the fuzzy matcher bridging the space.
---@param lname string
---@param p string lowercase typed prefix
---@return string
local function filter_text(lname, p)
  local spaced = lname:gsub("_", " ")
  if p ~= "" and spaced:sub(1, #p) ~= p then
    local flat = lname:gsub("_", "")
    if flat:sub(1, #p) == p then
      return flat
    end
  end
  return spaced
end

--- A directive item: `PARALLEL DO` -> `!$OMP PARALLEL DO`.
---@param lname string
---@param entry table
---@param range table
---@param p string
---@return table
local function directive_item(lname, entry, range, p)
  local detail, label_details = render.detail(entry)
  return {
    label = entry.name,
    kind = KIND.directive,
    detail = detail,
    labelDetails = label_details,
    filterText = filter_text(lname, p),
    -- Upper case: case.lua already enforces upper for directive lines.
    textEdit = { range = range, newText = entry.name },
    sortText = sort_text(B_GRAMMAR, 0, lname),
    data = { k = lname, directive = true },
  }
end

--- A directive item inside the sentinel window: `!$OM|` -> `!$OMP PARALLEL DO`.
---
--- The edit replaces the half-typed `OMP` as well as adding the directive, so
--- it has to carry the word itself; `filterText` is the same string in lower
--- case, which is what the user is typing at that point (`om`, `omp p`).
---@param lname string
---@param entry table
---@param range table start just past the `$`, end at the cursor
---@return table
local function sentinel_item(lname, entry, range)
  local detail, label_details = render.detail(entry)
  local text = "OMP " .. entry.name
  return {
    label = text,
    kind = KIND.directive,
    detail = detail,
    labelDetails = label_details,
    filterText = text:lower(),
    insertTextFormat = 1,
    textEdit = { range = range, newText = text },
    sortText = sort_text(B_GRAMMAR, 0, lname),
    data = { k = lname, directive = true },
  }
end

--- A clause item: `PRIVATE(…)` shown, `PRIVATE($1)` inserted, `private` matched.
---
--- A snippet, not the bare `PRIVATE(` design A7 asked for. That text was
--- chosen on the assumption that nvim-autopairs would close the paren; it does
--- not, and cannot -- autopairs reacts to TYPED keys, and blink's own
--- `auto_brackets` only fires for Function and Method items. Accepting the
--- clause therefore left `PRIVATE(` unbalanced. `insertTextFormat = 2` with a
--- `$1` between the parens leaves the cursor where the list goes and the paren
--- closed; blink expands it through `snippets.preset = "luasnip"`.
--- A clause that takes no argument list (`NOWAIT`) keeps plain text: a snippet
--- with no placeholder would only cost an expansion.
---@param lname string
---@param entry table
---@param range table
---@return table
local function clause_item(lname, entry, range)
  local takes_args = type(entry.signature) == "string" and entry.signature:find("(", 1, true) ~= nil
  local detail, label_details = render.detail(entry)
  return {
    label = takes_args and (entry.name .. "(…)") or entry.name,
    kind = KIND.clause,
    detail = detail,
    labelDetails = label_details,
    filterText = entry.name:lower(),
    insertTextFormat = takes_args and 2 or 1,
    textEdit = { range = range, newText = takes_args and (entry.name .. "($1)") or entry.name },
    sortText = sort_text(B_GRAMMAR, 9999, lname),
    data = { k = lname, directive = true },
  }
end

--- An ordinary item: an MPI or omp_lib name, a constant, a keyword, a module.
---@param cand table {lname, entry, origin}
---@param range table
---@return table
local function ordinary_item(cand, range)
  local entry = cand.entry
  local detail, label_details = render.detail(entry)
  local bucket = B_SYMBOL
  if M.snippet_prefixes()[cand.lname] then
    bucket = B_SNIPPET
  elseif cand.origin == "keyword" then
    bucket = B_KEYWORD
  end
  return {
    label = entry.name,
    kind = KIND[entry.kind] or 3,
    detail = detail,
    labelDetails = label_details,
    filterText = entry.name,
    textEdit = { range = range, newText = entry.name },
    sortText = sort_text(bucket, 9999, cand.lname),
    data = { k = cand.lname },
  }
end

-- ---------------------------------------------------------------------------
-- The answer
-- ---------------------------------------------------------------------------

--- Completion items for `line` with the cursor at byte `col`.
---
--- Pure: no buffer, no window, no plugin. `opts.line` is the 0-based line
--- number the ranges are built against, `opts.trigger_kind` the LSP
--- `context.triggerKind`, `opts.fixed` whether the file is fixed form.
---@param line string
---@param col integer 0-based byte offset of the cursor
---@param opts { line: integer|nil, trigger_kind: integer|nil, fixed: boolean|nil }|nil
---@return table[]
function M.items(line, col, opts)
  if type(line) ~= "string" then
    return {}
  end
  opts = opts or {}
  col = math.max(0, math.min(col or #line, #line))
  local lnum = opts.line or 0
  local p = typed_prefix(line, col)
  local range = edit_range(lnum, col, p)
  local out = {}

  -- The `$` trigger's own window, ahead of everything: inside it the line is
  -- not yet a directive line AND not code, so neither branch below answers it.
  local send = sentinel_window(line, col)
  if send then
    local dirs = directive_candidates()
    local srange = {
      start = { line = lnum, character = send },
      ["end"] = { line = lnum, character = col },
    }
    for _, c in ipairs(dirs) do
      out[#out + 1] = sentinel_item(c.lname, c.entry, srange)
    end
    return out
  end

  local ctx = directive_context(line, col, p)
  if ctx then
    local dirs, clauses = directive_candidates()
    if not ctx.clause then
      for _, c in ipairs(dirs) do
        if matches(c.lname, p) then
          out[#out + 1] = directive_item(c.lname, c.entry, range, p)
        end
      end
      return out
    end
    -- A clause position. When the directive is identifiable, its own clause
    -- list decides; `valid_on` is the fallback for the directives that carry
    -- no list, and an unidentifiable head offers everything.
    local dir = head_directive(ctx.head)
    local allowed = nil
    if dir and type(dir.clauses) == "table" then
      allowed = {}
      for _, name in ipairs(dir.clauses) do
        allowed[name:lower()] = true
      end
    end
    for _, c in ipairs(clauses) do
      local ok = true
      if allowed then
        ok = allowed[c.entry.name:lower()] == true
      elseif dir and type(c.entry.valid_on) == "table" then
        ok = false
        for _, on in ipairs(c.entry.valid_on) do
          ok = ok or on:lower():gsub(" ", "_") == (dir.name or ""):lower():gsub(" ", "_")
        end
      end
      if ok and matches(c.lname, p) then
        out[#out + 1] = clause_item(c.lname, c.entry, range)
      end
    end
    return out
  end

  -- Ordinary code.
  local code = code_view(line)
  if in_comment(code, col, opts.fixed) then
    return {}
  end
  -- An empty prefix on a keystroke would dump the whole registry into the
  -- menu. Only an explicit invoke (<C-space>) gets that.
  if p == "" and opts.trigger_kind ~= 1 then
    return {}
  end

  local before = masked(code, opts.fixed):sub(1, col)
  local after_use = before:find("%f[%w_]use%s+[%w_]*$") ~= nil
  local after_call = before:find("%f[%w_]call%s+[%w_]*$") ~= nil

  for _, c in ipairs(ordinary_candidates()) do
    local kind = c.entry.kind
    local want
    if after_use then
      want = kind == "module"
    elseif after_call then
      want = kind == "subroutine"
    else
      want = true
    end
    if want and matches(c.lname, p) then
      out[#out + 1] = ordinary_item(c, range)
    end
  end
  if after_use then
    for _, extra in ipairs(USE_EXTRA) do
      if matches(extra.lname, p) then
        out[#out + 1] = {
          label = extra.name,
          kind = KIND.module,
          detail = "module",
          labelDetails = { description = extra.name },
          filterText = extra.name,
          textEdit = { range = range, newText = extra.name },
          sortText = sort_text(B_SYMBOL, 9999, extra.lname),
          data = { k = extra.lname },
        }
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- LSP entry points
-- ---------------------------------------------------------------------------

--- textDocument/completion.
---@param params table
---@param cb fun(err: table|nil, result: table|nil)
function M.complete(params, cb)
  local uri = params and params.textDocument and params.textDocument.uri
  local pos = params and params.position
  if not (uri and pos) then
    return cb(nil, nil)
  end
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return cb(nil, nil)
  end
  local lnum = pos.line or 0
  local line = (vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false) or {})[1]
  if not line then
    return cb(nil, nil)
  end
  local ok, items = pcall(M.items, line, pos.character or #line, {
    line = lnum,
    trigger_kind = (params.context or {}).triggerKind,
    fixed = require("andrew.fortran.scan").is_fixed(bufnr),
  })
  return cb(nil, { isIncomplete = false, items = ok and items or {} })
end

--- completionItem/resolve -- adds exactly one field, `documentation`.
---
--- The initial list carries no prose at all: 900 markdown bodies is what the
--- old blink source shipped on every keystroke, and this is the mechanism
--- that removes it. `data.k` is the registry key, so the lookup is one hash.
---@param item table
---@param cb fun(err: table|nil, result: table|nil)
function M.resolve(item, cb)
  if type(item) ~= "table" then
    return cb(nil, item)
  end
  local data = item.data
  local k = type(data) == "table" and data.k or nil
  if type(k) ~= "string" then
    return cb(nil, item)
  end
  local entry
  if data.directive then
    entry = registry.directive(k)
  else
    entry = registry.get(k)
  end
  if not entry then
    return cb(nil, item)
  end
  item.documentation = render.completion_doc(entry)
  return cb(nil, item)
end

return M
