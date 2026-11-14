-- =============================================================================
-- Fortran source scanning (pure Lua, no plugin dependencies)
-- =============================================================================
-- Shared substrate for the Fortran symbol picker (andrew.fortran.symbols) and
-- the capitalization checker (andrew.fortran.case). Everything here is plain
-- Lua over a list of lines so it can be unit-tested headlessly and reused
-- against both a live buffer (unsaved edits included) and ripgrep output.
--
-- WHY NOT TREESITTER: the fortran grammar is installed, but it parses only
-- what it can and silently degrades on the fixed-form / preprocessed / vendor
-- -extension code this config is aimed at, and a partial parse quietly drops
-- call sites. Line scanning over a masked line is uniform and total.
--
-- WHY NOT THE LSP: fortls answers documentSymbol with DEFINITIONS only -- the
-- exact gap this module exists to close. Its reference search does find call
-- sites, but only one symbol at a time (that is `gr`), never as a browsable
-- list of every call in a file or project.
--
-- THE CENTRAL TRICK is `mask()`: every scan runs against a byte-for-byte
-- length-preserving copy of the line in which comments and string literals
-- have been blanked and everything else lowercased. That gives, in one pass:
--   * case-insensitivity (Fortran is case-insensitive; Lua patterns are not),
--   * comment/string immunity (a `call` inside a string is not a call),
--   * and exact column mapping back into the ORIGINAL line, because the mask
--     never changes byte offsets. Names are always extracted from the raw
--     line by index, so the picker shows real source casing.

local M = {}

-- ---------------------------------------------------------------------------
-- Line masking
-- ---------------------------------------------------------------------------

---@param c string single byte, or "" past the end of the line
---@return boolean
local function is_word_byte(c)
  return c ~= "" and c:match("[%w_]") ~= nil
end

--- Blank out comments and string literals, lowercase the rest.
--- The result has EXACTLY the same byte length as `line`.
---@param line string
---@param fixed boolean|nil true for fixed-form source (column-1 comment markers)
---@return string
function M.mask(line, fixed)
  local n = #line
  if n == 0 then
    return line
  end

  -- Fixed-form: c/C/*/! in column 1 comments out the whole line.
  if fixed then
    local first = line:sub(1, 1)
    if first == "c" or first == "C" or first == "*" or first == "!" then
      return string.rep(" ", n)
    end
  end

  -- Preprocessor directives are not Fortran statements.
  if line:match("^%s*#") then
    return string.rep(" ", n)
  end

  local out = {}
  local quote = nil
  local i = 1
  while i <= n do
    local ch = line:sub(i, i)
    if quote then
      out[i] = " "
      if ch == quote then
        if line:sub(i + 1, i + 1) == quote then
          -- Doubled delimiter is an escaped quote, still inside the literal.
          out[i + 1] = " "
          i = i + 1
        else
          quote = nil
        end
      end
    elseif ch == "'" or ch == '"' then
      quote = ch
      out[i] = " "
    elseif ch == "!" then
      for j = i, n do
        out[j] = " "
      end
      break
    else
      out[i] = ch:lower()
    end
    i = i + 1
  end

  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Primitive locators (all operate on a MASKED line)
-- ---------------------------------------------------------------------------

--- Find `kw` as a whole word. Plain (non-pattern) search, so `kw` may not
--- contain magic characters -- every caller passes a literal keyword.
---@param masked string
---@param kw string lowercase keyword
---@param init integer|nil
---@return integer|nil start, integer|nil stop
local function find_word(masked, kw, init)
  local s, e = masked:find(kw, init or 1, true)
  while s do
    if not is_word_byte(masked:sub(s - 1, s - 1)) and not is_word_byte(masked:sub(e + 1, e + 1)) then
      return s, e
    end
    s, e = masked:find(kw, s + 1, true)
  end
  return nil, nil
end
M._find_word = find_word

--- First identifier at or after `from`, skipping only whitespace.
--- Returns the LOWERCASE name (matching is case-insensitive) together with its
--- column, so callers can slice the raw line for the source-cased spelling.
---@param masked string
---@param from integer
---@return string|nil lname, integer|nil col 1-based start column, integer|nil stop
local function ident_at(masked, from)
  local s, e, name = masked:find("^%s*([%a_][%w_]*)", from)
  if not s then
    return nil, nil, nil
  end
  return name, e - #name + 1, e
end
M._ident_at = ident_at

-- ---------------------------------------------------------------------------
-- Definitions
-- ---------------------------------------------------------------------------

-- Keywords that introduce a named program unit, in the order we try them.
-- `type` and `interface` are handled separately: `type(foo) :: x` is a
-- declaration, not a definition, and `interface` is frequently unnamed.
local UNIT_KEYWORDS = { "subroutine", "function", "module", "program", "submodule" }

--- True when the text before `pos` on a masked line ends in the word `end`,
--- i.e. this is `end subroutine Foo`, not a definition.
---@param masked string
---@param pos integer column of the unit keyword
---@return boolean
local function preceded_by_end(masked, pos)
  local before = masked:sub(1, pos - 1)
  return before:match("[%s]end%s*$") ~= nil or before:match("^end%s*$") ~= nil
end

--- Record one occurrence, taking the displayed name from the RAW line so the
--- picker and the case checker see the spelling that is actually in the file.
---@param out table accumulator
---@param raw string
---@param lname string lowercase name as matched
---@param col integer 1-based start column
---@param kind string
---@param lnum integer
local function emit(out, raw, lname, col, kind, lnum)
  out[#out + 1] = {
    name = raw:sub(col, col + #lname - 1),
    lname = lname,
    kind = kind,
    lnum = lnum,
    col = col,
  }
end

--- Extract every program-unit definition on one masked line.
---@param masked string
---@param lnum integer
---@param out table accumulator
local function scan_definitions(masked, raw, lnum, out)
  raw = raw or masked
  for _, kw in ipairs(UNIT_KEYWORDS) do
    local ks, ke = find_word(masked, kw)
    while ks do
      local skip = preceded_by_end(masked, ks)

      -- `module procedure foo` re-declares, it does not define a module.
      -- `module subroutine foo` / `module function foo` are handled by the
      -- subroutine/function pass, so the `module` pass must ignore them.
      local name, col = ident_at(masked, ke + 1)
      if kw == "module" and name then
        if name == "procedure" or name == "subroutine" or name == "function" then
          skip = true
        end
      end

      -- `submodule (parent) child`
      if kw == "submodule" and not skip then
        local ps, pe = masked:find("^%s*%b()", ke + 1)
        if ps then
          name, col = ident_at(masked, pe + 1)
        end
      end

      -- A `function` result clause (`result(x)`) is not a definition, and
      -- neither is the word inside `end function`. Both are covered above.
      if not skip and name then
        emit(out, raw, name, col, kw, lnum)
      end
      ks, ke = find_word(masked, kw, ke + 1)
    end
  end

  -- Derived types: `type :: Name`, `type, extends(x) :: Name`, `type Name`.
  -- Excludes `type(Name) :: var` (a declaration) and `end type Name`.
  local ts, te = find_word(masked, "type")
  if ts and not preceded_by_end(masked, ts) and masked:sub(1, ts - 1):match("^%s*$") then
    local rest = masked:sub(te + 1)
    local name = rest:match("^%s*::%s*([%a_][%w_]*)") or rest:match("^%s*,.-::%s*([%a_][%w_]*)")
    if not name then
      -- Bare `type Name` -- but not `type(kind) ...`
      local bare = rest:match("^%s+([%a_][%w_]*)%s*$")
      name = bare
    end
    if name then
      local col = masked:find(name, te + 1, true)
      emit(out, raw, name, col or (te + 1), "type", lnum)
    end
  end

  -- Named interface blocks: `interface Name` (but not bare `interface`,
  -- `abstract interface`, or `end interface`).
  local is, ie = find_word(masked, "interface")
  if is and not preceded_by_end(masked, is) then
    local name, col = ident_at(masked, ie + 1)
    if name then
      emit(out, raw, name, col, "interface", lnum)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Declarations: variables, dummy arguments and COMMON blocks
-- ---------------------------------------------------------------------------
-- Procedures are only half the symbols in a Fortran project, and in the F77
-- -descended code this config is aimed at the other half is invisible to every
-- other tool: `dift` is declared by appearing in a COMMON block inside a `.h`
-- include, has no type declaration anywhere (IMPLICIT typing), and so is not a
-- symbol fortls has ever heard of.
--
-- What is recognised, and nothing else:
--
--   COMMON /DIFFST/ dift, difx(0:n)   -> [common] DIFFST, [var] dift, difx
--   REAL*8 DEPTHZ(nlcz)               -> [var] DEPTHZ
--   INTEGER, PARAMETER :: n = 10      -> [var] n
--   PARAMETER (ITTM = 9)              -> [var] ITTM
--   DIMENSION a(10)                   -> [var] a
--   SUBROUTINE Diffuse(nnode, dt)     -> [arg] nnode, [arg] dt
--
-- REFERENCES to variables are deliberately NOT collected here. There are 35398
-- identifier tokens in the project this was built against and only a few
-- hundred declarations; folding every occurrence of every variable into the
-- symbol list would turn a browsable index into a grep dump. Chasing one
-- variable's uses is a different question with its own answer -- see
-- M.project_references and the Fortran `gr` fallback.

-- Type keywords that can open a declaration statement. `double` needs a
-- following `precision`/`complex`, and `type`/`class` need an immediate `(`;
-- both are checked in consume_type_spec.
local DECL_TYPE_KEYWORDS = {
  integer = true, real = true, complex = true, logical = true,
  character = true, double = true, type = true, class = true,
}

--- Column at which the statement proper begins, past indentation and any
--- leading statement label (`100 CONTINUE`).
---@param masked string
---@return integer
local function statement_start(masked)
  return masked:match("^%s*%d+%s+()") or masked:match("^%s*()") or 1
end

--- Column just past a top-level `::`, or nil when the statement has none.
--- Depth-aware, so the `::` cannot be found inside `character(len=n) ::`'s
--- own parentheses -- and, more usefully, a `::` in an attribute's argument
--- would not be mistaken for the separator either.
---@param masked string
---@param from integer
---@return integer|nil
local function find_dcolon(masked, from)
  local depth = 0
  for i = from, #masked do
    local ch = masked:sub(i, i)
    if ch == "(" or ch == "[" then
      depth = depth + 1
    elseif ch == ")" or ch == "]" then
      depth = depth - 1
    elseif depth == 0 and ch == ":" and masked:sub(i + 1, i + 1) == ":" then
      return i + 2
    end
  end
  return nil
end

--- Walk a comma-separated entity list, emitting the identifier that OPENS each
--- entity and nothing else.
---
--- The list is walked byte by byte rather than split on commas because commas
--- appear inside array bounds (`grid(nx,ny), edge(0:n)` is two entities, not
--- four) and inside initialisers alike; only a depth counter tells the
--- separators apart. And after a name is taken the walker stops emitting until
--- the next depth-0 comma, which is what makes `INTEGER :: n = size(arr)`
--- yield `n` and not `size`.
---
---@param masked string
---@param raw string
---@param lnum integer
---@param from integer
---@param out table accumulator
---@param kind string
---@param st { depth: integer, expect: boolean, until_close: boolean|nil }
---@param stop_slash boolean|nil stop at a depth-0 `/` (COMMON block delimiter)
---@return integer stopped_at, string reason "end" | "cont" | "slash"
local function walk_entities(masked, raw, lnum, from, out, kind, st, stop_slash)
  local n = #masked
  local i = from
  while i <= n do
    local ch = masked:sub(i, i)
    if ch == "&" then
      -- Line continuation. Everything after it on this line is nothing.
      return i, "cont"
    elseif ch == "(" or ch == "[" then
      st.depth = st.depth + 1
      st.expect = false
    elseif ch == ")" or ch == "]" then
      st.depth = st.depth - 1
      if st.until_close and st.depth <= 0 then
        return i, "end"
      end
      if st.depth < 0 then
        st.depth = 0
      end
    elseif st.depth == 0 or (st.until_close and st.depth == 1) then
      if ch == "," then
        st.expect = true
      elseif ch == ";" then
        return i, "end"
      elseif ch == "/" and stop_slash then
        return i, "slash"
      elseif ch:match("[%a_]") then
        local _, e, word = masked:find("^([%a_][%w_]*)", i)
        if st.expect then
          emit(out, raw, word, i, kind, lnum)
          st.expect = false
        end
        i = e
      end
    end
    i = i + 1
  end
  return n + 1, "end"
end

--- Scan a COMMON statement from `pos`, which is either just past the `common`
--- keyword or, when resuming, the start of a continuation line.
---
--- COMMON alternates block names and entity lists -- `COMMON /a/ x,y /b/ z` --
--- so this loops between the two until the line runs out.
---@param resuming boolean true when continuing a list from a previous line
local function common_from(masked, raw, lnum, pos, out, state, resuming)
  while true do
    if not resuming then
      local col, name = masked:match("^%s*/()([%a_][%w_]*)/", pos)
      if col then
        emit(out, raw, name, col, "common", lnum)
        pos = col + #name + 1
      else
        -- Blank common: `COMMON // x` or `COMMON x`.
        local blank = masked:match("^%s*//()", pos)
        if blank then
          pos = blank
        end
      end
      state.st = { depth = 0, expect = true }
    end
    resuming = false

    local stop, reason = walk_entities(masked, raw, lnum, pos, out, "var", state.st, true)
    if reason == "cont" then
      state.active, state.mode = true, "common"
      return
    elseif reason == "slash" then
      pos = stop
    else
      state.active = false
      return
    end
  end
end

--- Consume a type specification at `pos`; returns the column just past it, or
--- nil when the statement does not open with one.
---@param masked string
---@param pos integer
---@return integer|nil
local function consume_type_spec(masked, pos)
  local _, e, word = masked:find("^([%a_][%w_]*)", pos)
  if not word or not DECL_TYPE_KEYWORDS[word] then
    return nil
  end
  local i = e + 1

  if word == "double" then
    local _, e2, w2 = masked:find("^%s*([%a_][%w_]*)", i)
    if w2 ~= "precision" and w2 ~= "complex" then
      return nil
    end
    return e2 + 1
  end

  if word == "type" or word == "class" then
    -- Only the parenthesised forms declare a variable. `TYPE :: Name` and
    -- `TYPE, EXTENDS(b) :: Name` DEFINE a derived type (scan_definitions has
    -- those), and `TYPE IS (t)` / `CLASS IS (t)` are SELECT TYPE guards.
    local _, pe = masked:find("^%s*%b()", i)
    return pe and pe + 1 or nil
  end

  -- Optional kind or length selector: `(8)`, `(len=17)`, `*8`, `*(*)`.
  local _, pe = masked:find("^%s*%b()", i)
  if pe then
    return pe + 1
  end
  local _, se = masked:find("^%s*%*%s*%d+", i)
  if se then
    return se + 1
  end
  local _, ce = masked:find("^%s*%*%s*%b()", i)
  if ce then
    return ce + 1
  end
  return i
end

--- Dummy arguments of a `SUBROUTINE`/`FUNCTION` header, if this line is one.
--- Self-guarding: it finds the keyword itself, so it can be tried on any line.
local function args_from(masked, raw, lnum, out, state)
  local ks, ke
  for _, kw in ipairs({ "subroutine", "function" }) do
    local s, e = find_word(masked, kw)
    if s and (not ks or s < ks) then
      ks, ke = s, e
    end
  end
  if not ks or preceded_by_end(masked, ks) then
    return
  end
  local _, ne = masked:find("^%s*[%a_][%w_]*", ke + 1)
  if not ne then
    return
  end
  local _, _, open = masked:find("^%s*()%(", ne + 1)
  if not open then
    return
  end
  state.st = { depth = 1, expect = true, until_close = true }
  state.kind = "arg"
  local _, reason = walk_entities(masked, raw, lnum, open + 1, out, "arg", state.st)
  state.active, state.mode = reason == "cont", "list"
end

--- Extract every declared name on one masked line.
---
--- `state` carries an unfinished entity list across a `&` continuation and is
--- returned for the caller to pass back on the next line. A caller with no
--- continuation context (a single line out of ripgrep) can pass a fresh table
--- and ignore it, at the cost of missing the tail of continued statements.
---@param masked string
---@param raw string
---@param lnum integer
---@param out table accumulator
---@param state table|nil
---@return table state
local function scan_declarations(masked, raw, lnum, out, state)
  raw = raw or masked
  state = state or {}

  if state.active then
    -- Continuation line; an optional leading `&` precedes the rest of the list.
    local from = masked:match("^%s*&()") or 1
    if state.mode == "common" then
      common_from(masked, raw, lnum, from, out, state, true)
    else
      local _, reason = walk_entities(masked, raw, lnum, from, out, state.kind or "var", state.st)
      state.active = reason == "cont"
    end
    return state
  end

  local pos = statement_start(masked)
  local word = masked:match("^([%a_][%w_]*)", pos)
  if not word then
    return state
  end

  if word == "common" then
    common_from(masked, raw, lnum, pos + #word, out, state, false)
    return state
  end

  if word == "parameter" then
    local _, _, open = masked:find("^%s*()%(", pos + #word)
    if open then
      state.st = { depth = 1, expect = true, until_close = true }
      state.kind = "var"
      local _, reason = walk_entities(masked, raw, lnum, open + 1, out, "var", state.st)
      state.active, state.mode = reason == "cont", "list"
    end
    return state
  end

  if word == "dimension" then
    local from = find_dcolon(masked, pos) or (pos + #word)
    state.st = { depth = 0, expect = true }
    state.kind = "var"
    local _, reason = walk_entities(masked, raw, lnum, from, out, "var", state.st)
    state.active, state.mode = reason == "cont", "list"
    return state
  end

  local after = consume_type_spec(masked, pos)
  if after then
    local dcolon = find_dcolon(masked, after)
    if not dcolon and masked:match("^%s*([%a_][%w_]*)", after) == "function" then
      -- `REAL(8) FUNCTION Energy(t)` is a definition, not a declaration. Its
      -- name belongs to scan_definitions; its dummy arguments belong here.
      args_from(masked, raw, lnum, out, state)
      return state
    end
    state.st = { depth = 0, expect = true }
    state.kind = "var"
    local _, reason = walk_entities(masked, raw, lnum, dcolon or after, out, "var", state.st)
    state.active, state.mode = reason == "cont", "list"
    return state
  end

  args_from(masked, raw, lnum, out, state)
  return state
end

-- ---------------------------------------------------------------------------
-- Call sites
-- ---------------------------------------------------------------------------

--- Every `call NAME` on one masked line.
---
--- Whitespace between `call` and the name is arbitrary -- Fortran does not care
--- whether there are two spaces or eight, and neither does this: find_word
--- locates the keyword and ident_at skips `%s*` to the name. Tabs included.
---@param masked string
---@param lnum integer
---@param out table accumulator
local function scan_call_statements(masked, raw, lnum, out)
  raw = raw or masked
  local ks, ke = find_word(masked, "call")
  while ks do
    local name, col = ident_at(masked, ke + 1)
    if name then
      emit(out, raw, name, col, "call", lnum)
    end
    ks, ke = find_word(masked, "call", ke + 1)
  end
end

--- Every `NAME(` occurrence on one masked line, whatever NAME is.
--- Callers filter by a known-name set; unfiltered this also matches array
--- indexing, `if (`, and every other parenthesised construct.
---
--- Whitespace before the paren is allowed (`Foo (x)` is a legal call).
---@param masked string
---@param lnum integer
---@param out table accumulator
local function scan_paren_names(masked, raw, lnum, out)
  raw = raw or masked
  local init = 1
  while true do
    local s, e, name = masked:find("([%a_][%w_]*)%s*%(", init)
    if not s then
      break
    end
    if not is_word_byte(masked:sub(s - 1, s - 1)) then
      emit(out, raw, name, s, "ref", lnum)
    end
    init = e
  end
end

--- Every identifier token on a masked line, in source order.
---
--- One pass, so a caller can test a hundred keywords per line with a hash
--- lookup each instead of a hundred whole-line searches.
---
--- A token preceded by a word byte is skipped: that is the exponent in a
--- literal like `1.0e5`, where `e5` matches the identifier pattern but is not
--- an identifier.
---@param masked string
---@return { lname: string, col: integer }[]
function M.identifiers(masked)
  local out = {}
  local init = 1
  while true do
    local s, e, word = masked:find("([%a_][%w_]*)", init)
    if not s then
      break
    end
    if not is_word_byte(masked:sub(s - 1, s - 1)) then
      out[#out + 1] = { lname = word, col = s }
    end
    init = e + 1
  end
  return out
end

--- Last non-blank byte before `col`, or "" at the start of the line.
---@param masked string
---@param col integer
---@return string
function M.prev_nonspace(masked, col)
  for i = col - 1, 1, -1 do
    local ch = masked:sub(i, i)
    if not ch:match("%s") then
      return ch
    end
  end
  return ""
end

--- Every occurrence of a KNOWN name on a masked line.
---
--- The set is what makes this usable. An unfiltered identifier scan reports
--- every keyword, every intrinsic and every loop bound; filtered to the names
--- the project actually declares, it reports uses of variables and nothing
--- else. Positions that are also a declaration or a call are reported here too
--- and are resolved by the picker's precedence, not by guessing here.
---@param masked string
---@param raw string
---@param lnum integer
---@param known table<string, boolean> lowercase declared names
---@param out table accumulator
local function scan_known_names(masked, raw, lnum, known, out)
  raw = raw or masked
  for _, tok in ipairs(M.identifiers(masked)) do
    if known[tok.lname] then
      emit(out, raw, tok.lname, tok.col, "varref", lnum)
    end
  end
end
M._scan_known_names = scan_known_names

-- Program units, for the nesting depth the document picker indents by. A
-- construct (`if`, `do`, `select`, `block`) is deliberately absent: `end if`
-- must not close a subroutine.
local UNIT_END_KEYWORDS = {
  program = true, module = true, submodule = true, subroutine = true,
  ["function"] = true, type = true, interface = true,
}

--- Nesting depth of each line, counted in open program units.
---
--- Used to indent the document picker the way an LSP client indents nested
--- documentSymbol children. A definition line sits at the depth of its
--- CONTAINER, and everything up to the matching `end` sits one deeper.
---
--- Bare `end` closes a unit (F77 writes nothing else); `end subroutine`,
--- `endfunction` and friends close one too. `end if` / `end do` / `end select`
--- close a construct and are ignored, which is the whole reason this is a
--- keyword test and not a bracket count.
---@param masked_lines string[]
---@param defs table[] definitions, used to know which lines OPEN a unit
---@return integer[] depth per line number
function M.nesting_depths(masked_lines, defs)
  local opens = {}
  for _, d in ipairs(defs or {}) do
    if UNIT_END_KEYWORDS[d.kind] then
      opens[d.lnum] = (opens[d.lnum] or 0) + 1
    end
  end

  local depths, depth = {}, 0
  for lnum, masked in ipairs(masked_lines) do
    local endkw = masked:match("^%s*end%s*([%a_]*)")
    if endkw and (endkw == "" or UNIT_END_KEYWORDS[endkw]) then
      depth = math.max(0, depth - 1)
    end

    depths[lnum] = depth

    if not endkw or (endkw ~= "" and not UNIT_END_KEYWORDS[endkw]) then
      -- An unnamed or abstract `interface` block opens a unit that no
      -- definition record marks, but `end interface` will close one.
      local unnamed_interface = masked:match("^%s*interface%s*$")
        or masked:match("^%s*abstract%s+interface%s*$")
      depth = depth + (opens[lnum] or 0) + (unnamed_interface and 1 or 0)
    end
  end
  return depths
end

-- ---------------------------------------------------------------------------
-- Whole-file scanning
-- ---------------------------------------------------------------------------

--- Scan a list of source lines.
---
--- Continuation handling: a line whose statement part ends with `call &` puts
--- the callee on the following line. That is the only continuation shape that
--- can hide a call site from a line-oriented scan (`call Foo(a, &` keeps the
--- name on the first line), so it is the only one special-cased.
---@param lines string[]
---@param opts { fixed?: boolean }|nil
---@return { defs: table[], calls: table[], refs: table[], decls: table[], masked: string[] }
function M.scan_lines(lines, opts)
  opts = opts or {}
  local fixed = opts.fixed
  local defs, calls, refs, decls, masked_lines = {}, {}, {}, {}, {}
  local pending_call = false
  -- Carried across lines so a COMMON block or entity list broken by `&` is
  -- scanned as the one statement it is.
  local decl_state = { active = false }

  for lnum, line in ipairs(lines) do
    local masked = M.mask(line, fixed)
    masked_lines[lnum] = masked

    if pending_call then
      -- Continuation line; an optional leading `&` precedes the callee.
      local from = 1
      local amp = masked:match("^%s*()&")
      if amp then
        from = amp + 1
      end
      local name, col = ident_at(masked, from)
      if name then
        emit(calls, line, name, col, "call", lnum)
      end
      pending_call = false
    end

    scan_definitions(masked, line, lnum, defs)
    scan_call_statements(masked, line, lnum, calls)
    scan_paren_names(masked, line, lnum, refs)
    scan_declarations(masked, line, lnum, decls, decl_state)

    -- `call` with nothing after it but a continuation marker.
    if masked:match("%f[%w_]call%s*&%s*$") or masked:match("^%s*call%s*&%s*$") then
      pending_call = true
    end
  end

  return { defs = defs, calls = calls, refs = refs, decls = decls, masked = masked_lines }
end

--- Every use of a declared name across already-masked lines.
---@param masked_lines string[]
---@param raw_lines string[]
---@param known table<string, boolean> lowercase declared names
---@return table[]
function M.variable_refs(masked_lines, raw_lines, known)
  local out = {}
  for lnum, masked in ipairs(masked_lines) do
    scan_known_names(masked, raw_lines[lnum], lnum, known, out)
  end
  return out
end

--- Extensions that mean fixed-form source. Kept in step with
--- andrew.fortran.lsp_inlayhint.FIXED_EXTENSIONS.
M.FIXED_EXTENSIONS = { f = true, ["for"] = true, ftn = true, fpp = true, f77 = true }

--- Is this buffer fixed-form source?
---
--- `filetype == "fortran_fixed"` alone is NOT enough: Neovim's own ftdetect
--- sets plain `fortran` for every Fortran file and records the form in
--- `b:fortran_fixed_source` instead, so a `.f` file opened normally never
--- matched and was masked as free form. The visible symptom was a
--- capitalization diagnostic planted inside a `C`-in-column-1 COMMENT, which
--- fixed-form masking blanks and free-form masking does not.
---@param bufnr integer
---@return boolean
function M.is_fixed(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "fortran_fixed" then
    return true
  end
  if ft == "fortran_free" then
    return false
  end
  local fixed = vim.b[bufnr].fortran_fixed_source
  if fixed ~= nil then
    return fixed == 1 or fixed == true
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return M.FIXED_EXTENSIONS[(name:lower():match("%.(%w+)$") or "")] == true
end

--- Convenience wrapper for a buffer (sees unsaved changes).
---@param bufnr integer|nil
---@return { defs: table[], calls: table[], refs: table[], decls: table[], masked: string[] }
function M.scan_buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.scan_lines(lines, { fixed = M.is_fixed(bufnr) })
end

-- ---------------------------------------------------------------------------
-- Project discovery
-- ---------------------------------------------------------------------------

--- Root markers match linting.lua's get_fortran_project_root so the symbol
--- picker, the capitalization check and the workspace linter all agree on what
--- "the project" is.
local ROOT_MARKERS = { ".git", ".fortls", "code" }

--- Walk up from `start` looking for a project marker.
---
--- The loop terminates on a FIXED POINT, not on "/" -- see the note in
--- linting.lua: vim.fs.dirname returns its argument unchanged one level below
--- root, and a `while path ~= "/"` loop hangs nvim outright for any file with
--- no marker above it.
---@param start string|nil directory to start from (default: current file's dir)
---@return string
function M.project_root(start)
  local path = start or vim.fn.expand("%:p:h")
  if path == "" then
    path = vim.uv.cwd() or "."
  end
  while path ~= "/" and path ~= "" do
    for _, marker in ipairs(ROOT_MARKERS) do
      local candidate = path .. "/" .. marker
      if vim.fn.isdirectory(candidate) == 1 or vim.fn.filereadable(candidate) == 1 then
        return path
      end
    end
    local parent = vim.fs.dirname(path)
    if parent == path then
      break
    end
    path = parent
  end
  return start or vim.fn.expand("%:p:h")
end

-- Case-insensitive globs: rg's --iglob '*.f90' matches .F90 too, so each
-- extension is listed once.
local FILE_GLOBS = { "*.f90", "*.f95", "*.f03", "*.f08", "*.f18", "*.f", "*.for", "*.ftn", "*.fpp" }

-- Fortran INCLUDE files. Kept apart from FILE_GLOBS because these are read but
-- never REWRITTEN: the capitalization fixer stays on source files, where the
-- extension is proof the file is Fortran. `.h` is ambiguous -- it is also a C
-- header -- but a Fortran tree that says `INCLUDE 'common.h'` keeps its whole
-- declaration section there, and reading one costs nothing: mask() blanks
-- preprocessor lines, and nothing in a C header matches Fortran declaration
-- syntax (`int x;` and `char *s;` name no Fortran type).
local INCLUDE_GLOBS = { "*.inc", "*.fh", "*.h" }

---@return string[]
function M.file_globs()
  return vim.deepcopy(FILE_GLOBS)
end

---@return string[]
function M.include_globs()
  return vim.deepcopy(INCLUDE_GLOBS)
end

--- Source files plus include files: what the symbol pickers read.
---@return string[]
function M.all_globs()
  local globs = M.file_globs()
  vim.list_extend(globs, INCLUDE_GLOBS)
  return globs
end

-- ---------------------------------------------------------------------------
-- ripgrep-backed project scanning
-- ---------------------------------------------------------------------------

--- Build the rg argv for a line-oriented search restricted to Fortran sources.
---@param root string
---@param pattern string a Rust-regex pattern (already case-insensitive via (?i))
---@param globs string[]|nil file globs to search (default: source files only)
---@return string[]
function M.rg_cmd(root, pattern, globs)
  local cmd = { "rg", "--no-heading", "--line-number", "--color=never", "--no-messages" }
  for _, glob in ipairs(globs or FILE_GLOBS) do
    cmd[#cmd + 1] = "--iglob"
    cmd[#cmd + 1] = glob
  end
  cmd[#cmd + 1] = "-e"
  cmd[#cmd + 1] = pattern
  cmd[#cmd + 1] = root
  return cmd
end

--- Split one `path:lnum:text` rg line.
---
--- Parsed with a NON-greedy path capture anchored on the first `:%d+:`, so a
--- colon inside the source text cannot be mistaken for the separator. A colon
--- in a *filename* still would; rg offers no way to disambiguate short of
--- --json, and Fortran source trees do not contain such names.
---@param out_line string
---@return string|nil path, integer|nil lnum, string|nil text
function M.parse_rg_line(out_line)
  local path, lnum, text = out_line:match("^(.-):(%d+):(.*)$")
  if not path then
    return nil, nil, nil
  end
  return path, tonumber(lnum), text
end

--- Run rg and hand back parsed `{ path, lnum, text }` records.
---@param root string
---@param pattern string
---@param cb fun(records: { path: string, lnum: integer, text: string }[])
---@param globs string[]|nil file globs to search (default: source files only)
function M.rg_lines(root, pattern, cb, globs)
  if vim.fn.executable("rg") ~= 1 then
    vim.notify("Fortran scan needs ripgrep (rg) on PATH", vim.log.levels.ERROR)
    cb({})
    return
  end
  vim.system(M.rg_cmd(root, pattern, globs), { text = true }, function(res)
    local records = {}
    for _, out_line in ipairs(vim.split(res.stdout or "", "\n", { plain = true })) do
      if out_line ~= "" then
        local path, lnum, text = M.parse_rg_line(out_line)
        if path then
          records[#records + 1] = { path = path, lnum = lnum, text = text }
        end
      end
    end
    vim.schedule(function()
      cb(records)
    end)
  end)
end

-- Patterns handed to ripgrep. rg is only a LINE FILTER here -- every hit is
-- re-scanned in Lua by the same code that scans a buffer, so rg's regex never
-- decides what counts as a definition or a call. That keeps buffer results and
-- project results byte-identical in shape and immune to comment/string hits.
M.DEF_PATTERN = [[(?i)\b(?:subroutine|function|module|program|submodule|type|interface)\b]]
M.CALL_PATTERN = [[(?i)\bcall\b]]
-- `call &` with the callee on the following line. rg is line-oriented, so this
-- pass only LOCATES such statements; the callee is read out of the file.
M.CONT_CALL_PATTERN = [[(?i)\bcall[ \t]*&[ \t]*$]]
-- Lines that OPEN a declaration statement, plus every procedure header (for
-- its dummy arguments). Anchored at the statement so a `real` in an expression
-- is not a hit; the `subroutine|function` branch is unanchored because those
-- headers carry prefixes (`pure elemental real(8) function f(x)`).
-- Continuation lines are deliberately NOT matched: they are reached by
-- following `&` from the statement that owns them, which is the only way to
-- know which list they belong to.
M.DECL_PATTERN = [[(?i)(?:^[ \t]*(?:\d+[ \t]+)?(?:common\b|dimension\b|parameter[ \t]*\(|integer\b|real\b|complex\b|logical\b|character\b|double[ \t]+(?:precision|complex)\b|type[ \t]*\(|class[ \t]*\()|\b(?:subroutine|function)\b)]]

--- Escape a Fortran identifier for use inside a Rust regex alternation.
--- Identifiers are `[A-Za-z_][A-Za-z0-9_]*`, none of which is a regex
--- metacharacter, so this is an assertion rather than a transformation.
---@param name string
---@return string|nil
local function safe_ident(name)
  return name:match("^[%a_][%w_]*$") and name or nil
end

--- Pattern matching `NAME(` for any NAME in `names`.
---@param names string[]
---@return string|nil pattern, nil when no usable names
function M.ref_pattern(names)
  local alts = {}
  for _, name in ipairs(names) do
    local ok = safe_ident(name)
    if ok then
      alts[#alts + 1] = ok
    end
  end
  if #alts == 0 then
    return nil
  end
  table.sort(alts)
  return [[(?i)\b(?:]] .. table.concat(alts, "|") .. [[)[ \t]*\(]]
end

--- Every program-unit definition in the project.
---@param root string
---@param cb fun(defs: table[]) entries carry path/name/kind/lnum/col/text
function M.project_definitions(root, cb)
  M.rg_lines(root, M.DEF_PATTERN, function(records)
    local defs = {}
    for _, rec in ipairs(records) do
      local found = {}
      scan_definitions(M.mask(rec.text), rec.text, rec.lnum, found)
      for _, d in ipairs(found) do
        d.path = rec.path
        d.text = rec.text
        defs[#defs + 1] = d
      end
    end
    cb(defs)
  end, M.all_globs())
end

--- Every call site in the project: `call NAME` for any NAME, plus `NAME(` for
--- the names in `known`.
---
--- Restricting the paren form to known names is what makes this precise. An
--- unrestricted `NAME(` search cannot tell `Heating(t)` from `array(i)` --
--- Fortran spells a function call and an array reference identically -- so the
--- only sound filter is "is this a name the project actually defines".
---@param root string
---@param known string[] defined names (from project_definitions)
---@param cb fun(calls: table[])
function M.project_calls(root, known, cb)
  local collected = {}
  local pending = 1

  local function done()
    pending = pending - 1
    if pending == 0 then
      cb(collected)
    end
  end

  local function absorb(records, scanner)
    for _, rec in ipairs(records) do
      local found = {}
      scanner(M.mask(rec.text), rec.text, rec.lnum, found)
      for _, c in ipairs(found) do
        c.path = rec.path
        c.text = rec.text
        collected[#collected + 1] = c
      end
    end
    done()
  end

  M.rg_lines(root, M.CALL_PATTERN, function(records)
    absorb(records, scan_call_statements)
  end, M.all_globs())

  -- Continued call statements: `call &` on one line, the callee on the next.
  -- A line-oriented search cannot see across that break, so these few hits are
  -- resolved by reading the file. There is normally a handful per project, and
  -- each file is read at most once.
  pending = pending + 1
  M.rg_lines(root, M.CONT_CALL_PATTERN, function(records)
    local file_lines = {}
    for _, rec in ipairs(records) do
      local lines = file_lines[rec.path]
      if lines == nil then
        local ok, read = pcall(vim.fn.readfile, rec.path)
        lines = ok and read or {}
        file_lines[rec.path] = lines
      end
      local lnum = rec.lnum + 1
      while lnum <= #lines do
        local raw = lines[lnum]
        local masked = M.mask(raw)
        local from = 1
        local amp = masked:match("^%s*()&")
        if amp then
          from = amp + 1
        end
        local lname, col = ident_at(masked, from)
        if lname then
          collected[#collected + 1] = {
            name = raw:sub(col, col + #lname - 1),
            lname = lname,
            kind = "call",
            lnum = lnum,
            col = col,
            path = rec.path,
            text = raw,
          }
          break
        end
        if not masked:match("^%s*$") then
          break
        end
        lnum = lnum + 1
      end
    end
    done()
  end, M.all_globs())

  local pattern = M.ref_pattern(known)
  if pattern then
    pending = pending + 1
    local known_set = {}
    for _, name in ipairs(known) do
      known_set[name:lower()] = true
    end
    M.rg_lines(root, pattern, function(records)
      for _, rec in ipairs(records) do
        local found = {}
        scan_paren_names(M.mask(rec.text), rec.text, rec.lnum, found)
        for _, c in ipairs(found) do
          if known_set[c.lname] then
            c.path = rec.path
            c.text = rec.text
            collected[#collected + 1] = c
          end
        end
      end
      done()
    end, M.all_globs())
  end
end

--- Every declared variable, dummy argument and COMMON block in the project.
---
--- Unlike the definition and call passes this cannot work from ripgrep's
--- output alone: a COMMON block routinely spans four continuation lines and the
--- names on lines two to four are just identifiers, indistinguishable from any
--- other text. So rg locates the lines that OPEN a declaration and, whenever
--- one of those is left unfinished by a `&`, the file is read and the statement
--- followed to its end. Files are read at most once and only when a
--- continuation actually needs them.
---@param root string
---@param cb fun(decls: table[]) entries carry path/name/kind/lnum/col/text
function M.project_declarations(root, cb)
  M.rg_lines(root, M.DECL_PATTERN, function(records)
    -- Group by file so continuations can be resolved with one read, and so a
    -- line already consumed as somebody else's continuation is not re-scanned
    -- as a statement of its own.
    local by_path, order = {}, {}
    for _, rec in ipairs(records) do
      local bucket = by_path[rec.path]
      if not bucket then
        bucket = { lnums = {}, text = {} }
        by_path[rec.path] = bucket
        order[#order + 1] = rec.path
      end
      if bucket.text[rec.lnum] == nil then
        bucket.lnums[#bucket.lnums + 1] = rec.lnum
        bucket.text[rec.lnum] = rec.text
      end
    end

    local decls = {}
    for _, path in ipairs(order) do
      local bucket = by_path[path]
      table.sort(bucket.lnums)
      local lines, consumed = nil, {}

      for _, lnum in ipairs(bucket.lnums) do
        if not consumed[lnum] then
          local found = {}
          local raw = bucket.text[lnum]
          local state = scan_declarations(M.mask(raw), raw, lnum, found, { active = false })
          local at = lnum

          while state.active do
            if not lines then
              local ok, read = pcall(vim.fn.readfile, path)
              lines = ok and read or {}
            end
            at = at + 1
            if at > #lines then
              break
            end
            consumed[at] = true
            bucket.text[at] = lines[at]
            state = scan_declarations(M.mask(lines[at]), lines[at], at, found, state)
          end

          for _, d in ipairs(found) do
            d.path = path
            d.text = bucket.text[d.lnum]
            decls[#decls + 1] = d
          end
        end
      end
    end

    cb(decls)
  end, M.all_globs())
end

--- Every occurrence of one name across the project, classified.
---
--- This is the answer to "where is `dift` used", which the symbol pickers
--- deliberately do not answer for variables -- see the note above
--- scan_declarations. Each hit is re-scanned so that an occurrence inside a
--- comment or a string literal is dropped, and so the definition, the
--- declaration and the call sites are labelled rather than buried in a flat
--- list of textual matches.
---@param root string
---@param name string a Fortran identifier
---@param cb fun(refs: table[])
function M.project_references(root, name, cb)
  local ident = safe_ident(name)
  if not ident then
    cb({})
    return
  end
  local lname = ident:lower()

  M.rg_lines(root, [[(?i)\b]] .. ident .. [[\b]], function(records)
    local refs = {}
    for _, rec in ipairs(records) do
      local masked = M.mask(rec.text)

      -- Classify by asking the same scanners the pickers use, then matching on
      -- column. A name that no scanner claims is an ordinary reference.
      local kind_at = {}
      local found = {}
      scan_definitions(masked, rec.text, rec.lnum, found)
      scan_declarations(masked, rec.text, rec.lnum, found, { active = false })
      scan_call_statements(masked, rec.text, rec.lnum, found)
      for _, f in ipairs(found) do
        if f.lname == lname and not kind_at[f.col] then
          kind_at[f.col] = f.kind
        end
      end

      local init = 1
      while true do
        local s, e = find_word(masked, lname, init)
        if not s then
          break
        end
        refs[#refs + 1] = {
          name = rec.text:sub(s, e),
          lname = lname,
          -- An occurrence no scanner claimed. `ref` would be wrong: the symbol
          -- pickers use that for `NAME(` where NAME is a known procedure, and
          -- it reads as a call site.
          kind = kind_at[s] or "varref",
          lnum = rec.lnum,
          col = s,
          path = rec.path,
          text = rec.text,
        }
        init = s + 1
      end
    end
    cb(refs)
  end, M.all_globs())
end

--- Pattern matching any whole word in `names`.
---@param names string[]
---@return string|nil
function M.word_pattern(names)
  local alts = {}
  for _, name in ipairs(names) do
    local ok = safe_ident(name)
    if ok then
      alts[#alts + 1] = ok
    end
  end
  if #alts == 0 then
    return nil
  end
  table.sort(alts)
  return [[(?i)\b(?:]] .. table.concat(alts, "|") .. [[)\b]]
end

--- Every use of every declared variable in the project.
---
--- This is the bulk of the workspace picker -- roughly twenty thousand rows on
--- a fifteen-thousand-line project against six hundred definitions and calls --
--- so it is a single ripgrep pass with one alternation over the declared names,
--- and each matching line is tokenised once. Filtering by the declared set is
--- what keeps keywords, intrinsics and numeric literals out.
---@param root string
---@param names string[] declared names (from project_declarations)
---@param cb fun(refs: table[])
function M.project_variable_refs(root, names, cb)
  local pattern = M.word_pattern(names)
  if not pattern then
    cb({})
    return
  end
  local known = {}
  for _, name in ipairs(names) do
    known[name:lower()] = true
  end

  M.rg_lines(root, pattern, function(records)
    local refs = {}
    for _, rec in ipairs(records) do
      local found = {}
      scan_known_names(M.mask(rec.text), rec.text, rec.lnum, known, found)
      for _, r in ipairs(found) do
        r.path = rec.path
        r.text = rec.text
        refs[#refs + 1] = r
      end
    end
    cb(refs)
  end, M.all_globs())
end

-- Exposed for the specs and for case.lua, which reuses the same locators.
M._scan_definitions = scan_definitions
M._scan_call_statements = scan_call_statements
M._scan_paren_names = scan_paren_names
M._scan_declarations = scan_declarations

return M
