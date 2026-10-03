-- =============================================================================
-- Fortran language keywords, by class
-- =============================================================================
-- The second half of the capitalization rule: `DO`, `IF`, `SELECT CASE`,
-- `END SUBROUTINE`. Kept apart from andrew.fortran.intrinsics because the two
-- are checked by different rules -- an intrinsic is only a call when it is in
-- invocation position, whereas a keyword is a keyword wherever it appears.
--
-- WHY CLASSES: "capitalize the keywords" means different things to different
-- code bases. Someone may want control flow shouted and declarations left
-- alone. `vim.g.fortran_case_keywords` takes a list of the class names below
-- so that is one variable, not a fork.
--
-- WHAT IS DELIBERATELY ABSENT, and why -- Fortran has no reserved words, so
-- every one of these is a legal variable name, and the guards in case.lua
-- (skip right of `::`, skip when followed by `=`, skip after `%`) only cover
-- the positions where a variable of that name would normally be written:
--
--   value, data, target, key       too common as variable names; the guards
--                                  do not cover `y = value`
--   in, out, inout                 `real :: in, out` is ordinary; these are
--                                  handled positionally instead, only inside
--                                  `intent(...)` -- see case.lua
--   len, kind                      always written `len=` / `kind=`, which the
--                                  `=` guard skips, and both are intrinsics
--                                  already covered by the procedure rule
--   unit, file, status, iostat,    I/O specifiers. All are written `name=`
--   err, form, access, action,     inside the parentheses, so the `=` guard
--   position, recl, exist, ...     would skip every one of them anyway
--   error                          only appears in `error stop`; far too
--                                  common a variable name to risk
--   go, to                         `go to` is archaic; `goto` is listed
--
-- Logical operators and literals (.and. .or. .not. .true. .false.) ARE covered,
-- as the dotted `operator` class -- see DOTTED_CLASSES below.

local M = {}

---@type table<string, string[]>
M.classes = {
  -- Control constructs and the statements that transfer control.
  control = {
    "if", "then", "else", "elseif", "endif",
    "do", "enddo", "while", "concurrent",
    "select", "selectcase", "selecttype", "case", "default", "endselect",
    "end",
    "cycle", "exit", "continue", "goto",
    "where", "elsewhere", "endwhere",
    "forall", "endforall",
    "associate", "endassociate",
    "block", "endblock",
    "critical", "endcritical",
    "return", "stop", "call",
  },

  -- Program units and the keywords that introduce or qualify them.
  unit = {
    "program", "endprogram",
    "module", "endmodule", "submodule", "endsubmodule",
    "subroutine", "endsubroutine",
    "function", "endfunction",
    "interface", "endinterface", "abstract",
    "contains", "use", "only", "import",
    "result", "recursive", "pure", "elemental", "impure",
    "entry", "procedure", "generic", "operator", "assignment",
  },

  -- Type specifiers and declaration attributes.
  declaration = {
    "implicit", "none",
    "integer", "real", "complex", "logical", "character", "double", "precision",
    "type", "endtype", "class",
    "dimension", "allocatable", "pointer", "optional", "parameter", "save",
    "external", "intrinsic", "public", "private", "protected", "sequence",
    "bind", "volatile", "asynchronous", "contiguous", "codimension",
    "extends", "deferred", "nopass", "pass", "non_overridable",
    "intent",
    "common", "equivalence", "namelist", "enum", "enumerator",
  },

  -- I/O statements. The specifier names inside their parentheses are not
  -- listed; see the note above.
  io = {
    "write", "read", "print", "open", "close", "inquire",
    "rewind", "backspace", "endfile", "flush", "wait", "format",
  },

  -- Dynamic memory statements.
  memory = { "allocate", "deallocate", "nullify" },

  -- Logical / relational operators and logical literals. These are DOTTED --
  -- `.AND.`, `.TRUE.` -- and are matched by the dots, not as identifiers.
  --
  -- The dots are what makes them safe. `and`, `not` and `true` are all legal
  -- Fortran variable names (nothing is reserved), so a bare identifier scan
  -- would have to guess; `.and.` cannot be anything else. Only the letters are
  -- rewritten, so the surrounding dots and the byte length are untouched.
  operator = {
    "and", "or", "not", "eqv", "neqv",
    "true", "false",
    "eq", "ne", "lt", "le", "gt", "ge",
  },
}

--- Classes whose members are written between dots rather than as identifiers.
--- They are selected by name like any other class, but reached through
--- `dotted_set` instead of `set`.
---@type table<string, true>
M.DOTTED_CLASSES = { operator = true }

-- `.TRUE.` is a literal, not an operator; the distinction only shows up in the
-- diagnostic message, so it lives here rather than in a class of its own.
local DOTTED_LABELS = { ["true"] = "logical constant", ["false"] = "logical constant" }

--- Every class name, sorted, for command completion and error messages.
---@return string[]
function M.class_names()
  local names = {}
  for name in pairs(M.classes) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- Lowercase identifier -> class, for the requested classes.
--- Dotted classes are excluded; they are not identifiers.
---@param classes string[]|nil nil means every class
---@return table<string, string>
function M.set(classes)
  local wanted = classes or M.class_names()
  local out = {}
  for _, class in ipairs(wanted) do
    if not M.DOTTED_CLASSES[class] then
      for _, word in ipairs(M.classes[class] or {}) do
        out[word] = class
      end
    end
  end
  return out
end

--- Lowercase undotted word -> label, for the requested DOTTED classes.
--- `.and.` is stored as `and`: the scan matches the dots and rewrites only the
--- letters between them.
---@param classes string[]|nil nil means every class
---@return table<string, string>
function M.dotted_set(classes)
  local wanted = classes or M.class_names()
  local out = {}
  for _, class in ipairs(wanted) do
    if M.DOTTED_CLASSES[class] then
      for _, word in ipairs(M.classes[class] or {}) do
        out[word] = DOTTED_LABELS[word] or "operator"
      end
    end
  end
  return out
end

--- The keywords that may follow `intent(`. Checked positionally rather than by
--- name, because `in` and `out` are ordinary variable names everywhere else.
---@type table<string, true>
M.intent_arguments = { ["in"] = true, out = true, inout = true }

return M
