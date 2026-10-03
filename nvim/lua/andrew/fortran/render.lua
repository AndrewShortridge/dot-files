-- Markdown rendering for every Fortran documentation payload: hover,
-- completion documentation, signature help, completion detail, and the
-- docstring normaliser that turns a `!>` comment block into markdown.
--
-- WHY THIS IS A SEPARATE, PURE MODULE
--
-- Four LSP methods have to agree about what a procedure looks like. If hover
-- builds its own string, completion builds a second one and signatureHelp a
-- third, they drift the moment one of them is edited -- and the drift is only
-- visible to a human watching a float, never to a test. Everything here takes
-- a registry Entry and returns a string or a plain LSP table: no buffers, no
-- clients, no plugins, nothing from `vim.*` except `vim.split` and the one
-- option `vim.g.fortran_signature_display`. That is what makes the target
-- output (design A1-A5) assertable byte-for-byte in a spec.
--
-- WHY THE FENCE CARRIES TWO PARTS
--
-- basedpyright can print `def f(a: int, b: str) -> None` because Python types
-- live in the argument list. Fortran types live in declarations, so a call
-- line alone says nothing. The fence therefore carries the basedpyright-shaped
-- call line and then the typed dummy block, indented two spaces with the `::`
-- column aligned -- which is exactly what fortls's own `--hover_signature`
-- prints, so a float from either server reads the same way.
--
-- PORTED CONVENTIONS (basedpyright, via the recovered TypeScript)
--   * `(kind) ` prefix INSIDE the fence            tooltipUtils.ts:106,161
--   * one dummy per line at 4 spaces, ONLY when
--     there is more than one dummy                 tooltipUtils.ts:311-322
--   * bare `---\n` between fence and prose, only
--     when both halves are non-empty               hoverProvider.ts:147-151
--   * `[start,end]` byte offsets recorded as the
--     signature label is concatenated              signatureHelpProvider.ts:254-295
--   * documentation on the ACTIVE parameter only   signatureHelpProvider.ts:304-314
--   * `labelDetails.description` = provenance      completionProvider.ts:1121-1125
--
-- DELIBERATELY NOT PORTED (design A11): `&nbsp;` indentation (renders
-- literally in a nvim float), markdown/HTML escaping (registry prose is
-- authored as markdown), reST directives/roles/tables, the epytext leading
-- dot. Where upstream would have emitted `&nbsp;` this module trims the
-- indent instead, because four literal spaces in markdown become a code block.
local M = {}

-- ---------------------------------------------------------------------------
-- Small string helpers (no vim.* beyond vim.split)
-- ---------------------------------------------------------------------------

---@param s string
---@return string
local function trim_end(s)
  return (s:gsub("%s+$", ""))
end

---@param s string
---@return string
local function trim_start(s)
  return (s:gsub("^%s+", ""))
end

---@param s string
---@return string
local function trim(s)
  return trim_end(trim_start(s))
end

---@param s string|nil
---@return boolean
local function is_blank(s)
  return s == nil or s:match("%S") == nil
end

---@param s string
---@param suffix string
---@return boolean
local function ends_with(s, suffix)
  return #s >= #suffix and s:sub(-#suffix) == suffix
end

---@param s string
---@return string[]
local function lines_of(s)
  return vim.split(s, "\n", { plain = true })
end

--- Leading-space count, upstream `_countLeadingSpaces`.
---@param s string
---@return integer
local function indent_of(s)
  local lead = s:match("^ *")
  return #lead
end

-- ===========================================================================
-- Signatures
-- ===========================================================================

-- `'\n' + ' '.repeat(functionParamIndentOffset)`, tooltipUtils.ts:59,301-303.
local PAREN_INDENT = "\n" .. string.rep(" ", 4)

--- Literal port of `formatSignature` (tooltipUtils.ts:311-322):
--- only break the list when the display is formatted AND there is more than
--- one part -- which is why a 0- or 1-dummy procedure stays on one line even
--- in `formatted` mode (design A3).
---@param parts string[]|nil
---@param formatted boolean|nil
---@return string
function M.paren_list(parts, formatted)
  parts = parts or {}
  if formatted and #parts > 1 then
    return "(" .. PAREN_INDENT .. table.concat(parts, "," .. PAREN_INDENT) .. "\n)"
  end
  return "(" .. table.concat(parts, ", ") .. ")"
end

--- Resolve the display mode: explicit opts, then `vim.g`, then "formatted"
--- (mirrors configOptions.ts:1496). Read once per request, never cached.
---@param opts table|nil
---@return string
local function display_mode(opts)
  local d = opts and opts.display
  if d == nil then
    d = vim.g.fortran_signature_display
  end
  return d == "compact" and "compact" or "formatted"
end

--- The attribute column of a declaration: `integer, intent(out), optional`.
---@param p table one entry of Entry.interface
---@return string
local function decl_attrs(p)
  local a = p.type or "integer"
  if p.intent then
    a = a .. ", intent(" .. p.intent .. ")"
  end
  if p.optional then
    a = a .. ", optional"
  end
  return a
end

--- The name column of a declaration: the dummy name with its shape attached,
--- `recvbuf(*)`. Fortran spells the shape on the name, not on the type.
---@param p table
---@return string
local function decl_name(p)
  return (p.name or "") .. (p.dim or "")
end

---@param entry table
---@return string[]
local function dummy_names(entry)
  local names = {}
  for i, p in ipairs(entry.interface or {}) do
    names[i] = p.name or ""
  end
  return names
end

--- The fence BODY -- no `(kind) ` prefix, no fence markers.
--- Procedures get the call line plus the aligned dummy block; constants get
--- the name plus a `parameter` declaration; every other kind is one line.
---@param entry table
---@param opts table|nil `{ display = "formatted"|"compact", name = string }`
---@return string
function M.format_signature(entry, opts)
  if not entry then
    return ""
  end
  -- `name` overrides the display name on the FIRST line only (hover passes the
  -- spelling under the cursor); declarations keep the canonical case.
  local shown = (opts and opts.name) or entry.name or ""
  local kind = entry.kind

  if kind == "subroutine" or kind == "function" then
    local iface = entry.interface
    local first
    if iface then
      local names = {}
      for i, p in ipairs(iface) do
        names[i] = decl_name(p)
      end
      first = shown .. M.paren_list(names, display_mode(opts) == "formatted")
    else
      first = entry.signature or shown
    end

    local rows = {}
    for _, p in ipairs(iface or {}) do
      rows[#rows + 1] = { decl_attrs(p), decl_name(p) }
    end
    if kind == "function" and entry.result_type then
      rows[#rows + 1] = { entry.result_type, entry.name or shown }
    end

    -- fortls aligns the `::` column across the whole block (fortls-baseline A.2).
    local width = 0
    for _, r in ipairs(rows) do
      if #r[1] > width then
        width = #r[1]
      end
    end
    local out = { first }
    for _, r in ipairs(rows) do
      out[#out + 1] = "  " .. r[1] .. string.rep(" ", width - #r[1]) .. " :: " .. r[2]
    end
    return table.concat(out, "\n")
  end

  if kind == "constant" then
    local ty = entry.type or entry.result_type or "integer"
    local decl = "  " .. ty .. ", parameter :: " .. (entry.name or shown)
    if entry.value then
      decl = decl .. " = " .. entry.value
    end
    return shown .. "\n" .. decl
  end

  -- directive | clause | keyword | type | module: the one-line signature,
  -- or the display name when the entry carries none (design A4).
  return entry.signature or shown
end

-- ===========================================================================
-- Prose body
-- ===========================================================================

--- Entry.summary is authored without a trailing period (data model); the
--- renderer supplies one so every float ends its first sentence.
---@param s string
---@return string
local function sentence(s)
  s = trim(s)
  if s == "" then
    return s
  end
  if s:match("[%.%?!:;]$") then
    return s
  end
  return s .. "."
end

--- Case-insensitive lookup into Entry.params, keyed by dummy name.
---@param entry table
---@param name string
---@return string|nil
local function param_text(entry, name)
  local p = entry.params
  if not p or not name then
    return nil
  end
  return p[name] or p[name:lower()]
end

---@param names string[]
---@param sep string
---@return string
local function ticked(names, sep)
  local out = {}
  for i, n in ipairs(names) do
    out[i] = "`" .. n .. "`"
  end
  return table.concat(out, sep)
end

--- The provenance/standard/see-also trailer, one paragraph, joined with ` · `.
---@param entry table
---@return string|nil
local function trailer(entry)
  local parts = {}
  local mod = entry.module
  if mod == "mpi" then
    local s = "**Binding** `mpi` (`include 'mpif.h'`)"
    if entry.binding_note and entry.binding_note ~= "" then
      s = s .. "; " .. entry.binding_note
    end
    parts[#parts + 1] = s
  elseif mod == "omp_lib" then
    parts[#parts + 1] = "**Module** `omp_lib` (`!$ use omp_lib`)"
  elseif entry.binding_note and entry.binding_note ~= "" then
    parts[#parts + 1] = "**Binding** " .. entry.binding_note
  end
  if entry.standard and entry.standard ~= "" then
    parts[#parts + 1] = "**Standard** " .. entry.standard
  end
  if entry.see_also and #entry.see_also > 0 then
    parts[#parts + 1] = "**See also** " .. ticked(entry.see_also, ", ")
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " · ")
end

--- Everything below the `---`: summary, description, parameters, returns,
--- valid-on, example, trailer. Each block is its own paragraph; empty blocks
--- are omitted entirely (never left as an empty header).
---@param entry table
---@return string
function M.body(entry)
  if not entry then
    return ""
  end
  local blocks = {}

  if entry.summary and entry.summary ~= "" then
    blocks[#blocks + 1] = sentence(entry.summary)
  end
  if entry.description and entry.description ~= "" then
    blocks[#blocks + 1] = trim_end(entry.description)
  end

  if entry.interface and entry.params then
    local items = {}
    for _, p in ipairs(entry.interface) do
      local txt = param_text(entry, p.name)
      if txt and txt ~= "" then
        items[#items + 1] = "- `" .. p.name .. "` — " .. trim_end(txt)
      end
    end
    if #items > 0 then
      blocks[#blocks + 1] = "**Parameters**\n" .. table.concat(items, "\n")
    end
  end

  if entry.result and entry.result ~= "" then
    blocks[#blocks + 1] = "**Returns** " .. trim_end(entry.result)
  end

  if entry.valid_on and #entry.valid_on > 0 then
    blocks[#blocks + 1] = "**Valid on** " .. ticked(entry.valid_on, " ")
  end

  if entry.example and entry.example ~= "" then
    blocks[#blocks + 1] = "**Example**\n```fortran\n" .. trim_end(entry.example) .. "\n```"
  end

  local tail = trailer(entry)
  if tail then
    blocks[#blocks + 1] = tail
  end

  return table.concat(blocks, "\n\n")
end

-- ===========================================================================
-- Hover / completion documentation
-- ===========================================================================

--- Shared shape of hover and completion documentation. `prefix` is the
--- `(kind) ` marker; completion passes "" because its `detail` field already
--- carries the kind (completionProviderUtils.ts:116-123).
---@param entry table
---@param prefix string
---@param label string|nil
---@return table MarkupContent
local function markup(entry, prefix, label)
  local sig = M.format_signature(entry, { name = label })
  local value = ""
  if sig ~= "" then
    value = "```fortran\n" .. prefix .. sig .. "\n```\n"
  end
  local prose = M.body(entry)
  -- hoverProvider.ts:147-151: the rule appears only when BOTH halves exist.
  if value ~= "" and prose ~= "" then
    value = value .. "---\n"
  end
  value = value .. prose
  return { kind = "markdown", value = trim_end(value) }
end

--- Hover payload. `label` replaces the display name on the first line only
--- (the spelling under the cursor); the `(kind) ` prefix is emitted either way.
---@param entry table
---@param label string|nil
---@return table MarkupContent
function M.hover(entry, label)
  if not entry then
    return { kind = "markdown", value = "" }
  end
  local prefix = entry.kind and ("(" .. entry.kind .. ") ") or ""
  return markup(entry, prefix, label)
end

--- Completion documentation: hover minus the `(kind) ` prefix (design A6).
---@param entry table
---@return table MarkupContent
function M.completion_doc(entry)
  if not entry then
    return { kind = "markdown", value = "" }
  end
  return markup(entry, "", nil)
end

-- ===========================================================================
-- Signature help
-- ===========================================================================

--- First paragraph of a description, for the signature's own documentation.
---@param s string|nil
---@return string
local function first_paragraph(s)
  if not s or s == "" then
    return ""
  end
  local para = vim.split(s, "\n\n", { plain = true })[1]
  return trim_end(para or "")
end

--- lsp.SignatureInformation. The label is ALWAYS compact, whatever
--- `fortran_signature_display` says (signatureHelpProvider.ts:237-295), and
--- every parameter's `[start, end)` byte offsets are recorded BEFORE the name
--- is appended, so they cannot drift out of step with the label.
---@param entry table
---@param active integer|nil 0-based active parameter index (LSP convention)
---@return table
function M.signature(entry, active)
  if not entry then
    return { label = "", parameters = {} }
  end
  local iface = entry.interface or {}
  local label = (entry.name or "") .. "("
  local params = {}
  for i, p in ipairs(iface) do
    if i > 1 then
      label = label .. ", "
    end
    local name = p.name or ""
    params[i] = {
      label = { #label, #label + #name },
      documentation = { kind = "markdown", value = "" },
    }
    label = label .. name
  end
  label = label .. ")"

  local info = { label = label, parameters = params }

  local doc = sentence(entry.summary or "")
  local first = first_paragraph(entry.description)
  if first ~= "" then
    doc = (doc ~= "" and (doc .. "\n\n") or "") .. first
  end
  if doc ~= "" then
    info.documentation = { kind = "markdown", value = doc }
  end

  if active ~= nil then
    info.activeParameter = active
    local p = iface[active + 1]
    if p then
      -- nvim appends parameter documentation with NO separator
      -- (vim/lsp/util.lua, right after the active-offset block), so we ship
      -- the rule inside the value -- basedpyright's own bug, fixed here.
      local value = "---\n`" .. decl_attrs(p) .. " :: " .. decl_name(p) .. "`"
      local txt = param_text(entry, p.name)
      if txt and txt ~= "" then
        value = value .. "\n\n" .. trim_end(txt)
      end
      params[active + 1].documentation.value = value
    end
  end

  return info
end

-- ===========================================================================
-- Completion detail
-- ===========================================================================

--- `detail` is the kind; `labelDetails.detail` is the compact argument list
--- and `labelDetails.description` the provenance column blink.cmp renders on
--- the right (completionProvider.ts:1121-1125).
---@param entry table
---@return string detail
---@return table labelDetails
function M.detail(entry)
  if not entry then
    return "", {}
  end
  local ld = { description = entry.module or entry.standard }
  if (entry.kind == "subroutine" or entry.kind == "function") and entry.interface then
    ld.detail = M.paren_list(dummy_names(entry), false)
  end
  return entry.kind, ld
end

-- ===========================================================================
-- Docstring -> markdown (design D1)
-- ===========================================================================
--
-- A port of basedpyright's docStringConversion.ts / docStringUtils.ts, cut
-- down to the rules that mean something in Fortran. It is a state machine
-- whose states are named entries of `M._states`, driven by a loop with the
-- upstream PROGRESS GUARD: if one pass changes neither the state nor the line
-- number, the loop breaks instead of spinning (docStringConversion.ts:135-167).
--
-- Fortran-specific: doc-comment leaders (`!>`, `!!`, `!<`, `!`) are stripped
-- before the normalisation pre-pass, and a sentinel blank line is prepended so
-- that EVERY real line takes part in the common-indent computation -- upstream
-- exempts line 1 because it sits on the `"""`, which has no Fortran analogue.
--
-- Two deliberate divergences, both noted because they are visible in output:
--   * `~~~` is never a fence opener (upstream treats exactly three tildes as
--     one); D1 wants `~~~`/`+++` underlines to become `---`, and Fortran doc
--     comments do not use tilde fences.
--   * literal/`@code` block bodies are printed with the block indent removed
--     and blank lines preserved. Upstream keeps the indent (it fits Python's
--     4-space docstring body) and its blank-line dedup can eat blank lines
--     inside a code block.

--- `/^\s*[#`~=-]{3,}/`
---@param line string|nil
---@return boolean
local function is_header(line)
  if line == nil then
    return false
  end
  return line:match("^%s*[#`~=%-][#`~=%-][#`~=%-]") ~= nil
end

--- Upstream `PotentialHeaders`: a separator line made of repeated runs of one
--- of `= - ~ +` collapses its whitespace into that character.
---@param line string
---@return string|nil
local function collapse_header(line)
  local body = trim(line)
  if body == "" then
    return nil
  end
  local ch = body:sub(1, 1)
  if not ch:match("[=%-~%+]") then
    return nil
  end
  local runs = 0
  for tok in body:gmatch("%S+") do
    if not tok:match("^%" .. ch .. "+$") then
      return nil
    end
    runs = runs + 1
  end
  if runs < 2 then
    return nil
  end
  return (body:gsub("%s", ch))
end

--- Upstream `_preprocessTextLine`: reST literal-block markers and ``x`` ticks.
---@param line string
---@return string
local function preprocess(line)
  if line:match("^%s*::%s*$") then
    return ""
  end
  line = line:gsub("%s+::$", "")
  line = line:gsub("(%S)%s*::$", "%1:")
  line = line:gsub("``", "`")
  return line
end

--- Strip one Fortran doc-comment leader, preserving the indentation that
--- follows it. `!$` (an OpenMP sentinel) is never a doc comment.
---@param line string
---@return string
local function strip_leader(line)
  if line:match("^%s*!%$") then
    return line
  end
  local lead, tail = line:match("^(%s*)![!<>]?(.*)$")
  if lead == nil then
    return line
  end
  return lead .. tail
end

--- Upstream `cleanAndSplitDocString` (docStringUtils.ts:15-59).
---@param raw string
---@return string[]
local function clean_and_split(raw)
  local text = raw:gsub("\r", ""):gsub("\t", "        ")
  local lines = lines_of(text)

  local min_indent = nil
  for i, line in ipairs(lines) do
    if #lines <= 1 or i > 1 then
      local stripped = trim_start(line)
      if stripped ~= "" then
        local n = #line - #stripped
        if min_indent == nil or n < min_indent then
          min_indent = n
        end
      end
    end
  end
  min_indent = min_indent or 0

  local out = {}
  for i, line in ipairs(lines) do
    if i == 1 then
      out[i] = trim(line)
    else
      out[i] = trim_end(line:sub(min_indent + 1))
    end
  end

  while #out > 0 and out[1] == "" do
    table.remove(out, 1)
  end
  while #out > 0 and out[#out] == "" do
    table.remove(out)
  end
  return out
end

-- --- converter -------------------------------------------------------------

local Conv = {}
Conv.__index = Conv

function Conv:cur()
  return self.lines[self.lnum]
end

function Conv:line_at(i)
  if i < 1 then
    return nil
  end
  return self.lines[i]
end

function Conv:indent()
  return indent_of(self:cur() or "")
end

function Conv:prev_indent()
  return indent_of(self:line_at(self.lnum - 1) or "")
end

function Conv:within_block()
  local line = self:cur() or ""
  return line:sub(self.block_indent + 1)
end

function Conv:outside_block()
  return self:indent() < self.block_indent
end

function Conv:eat()
  self.lnum = self.lnum + 1
end

function Conv:append(text)
  self.out = self.out .. text
  self.skip_empty = false
  self.in_fields = false
end

--- Upstream `_appendLine`: blank lines are deduplicated, text lines are not.
function Conv:append_line(line)
  if not is_blank(line) then
    self.out = self.out .. line .. "\n"
    self.skip_empty = false
  elseif not self.skip_empty then
    self.out = self.out .. "\n"
    self.skip_empty = true
  end
  self.in_fields = false
end

--- Raw append used for fenced content, so blank lines inside code survive.
function Conv:append_raw(line)
  self.out = self.out .. line .. "\n"
  self.skip_empty = false
  self.in_fields = false
end

function Conv:trim_and_append_line(line)
  self.out = trim_end(self.out)
  self.skip_empty = false
  self:append_line()
  self:append_line(line)
end

function Conv:push_state(next_state)
  self.stack[#self.stack + 1] = self.state
  self.state = next_state
end

function Conv:pop_state()
  self.state = table.remove(self.stack) or "text"
end

--- Upstream `_appendTextLine`, minus escaping and inline-code tracking.
function Conv:append_text_line(line)
  line = preprocess(line)
  local collapsed = collapse_header(line)
  if collapsed then
    line = collapsed
  end
  if line:match("^%s*~~~+%s*$") then
    line = line:gsub("~", "-")
  elseif line:match("^%s*%+%+%++%s*$") then
    line = line:gsub("%+", "-")
  end
  self:append(line)
  self.out = self.out .. "\n"
end

--- Upstream `_formatPlainTextIndent`: a change of indent between consecutive
--- non-blank lines becomes a markdown hard break. Where upstream would then
--- re-indent with `&nbsp;` we trim instead (design A11).
function Conv:format_plain_text_indent(line)
  local prev = self:line_at(self.lnum - 1)
  local prev_indent = self:prev_indent()
  local curr_indent = self:indent()
  local breakable = self.out ~= ""
    and not is_blank(prev)
    and not ends_with(self.out, "  \n")
    and not ends_with(self.out, "\n\n")

  if curr_indent > prev_indent and breakable and not is_header(prev) then
    self.out = self.out:sub(1, -2) .. "  \n"
  end
  if prev_indent > curr_indent and breakable then
    self.out = self.out:sub(1, -2) .. "  \n"
  end
  return trim_start(line)
end

-- --- block openers ---------------------------------------------------------

---@return boolean
local function begin_fence(c)
  local line = c:cur()
  if line:match("^%s*````") then
    return false
  end
  local ticks, lang = line:match("^%s*(```)(%w*)")
  if not ticks then
    return false
  end
  c.block_indent = c:indent()
  c.fence_str = ticks
  c:append_line(ticks .. lang)
  c:push_state("fence")
  c:eat()
  return true
end

---@return boolean
local function begin_code(c)
  local line = c:cur()
  local lang = line:match("^%s*@code%s*{%.?([%w_+]+)%s*}%s*$")
  if not lang and not line:match("^%s*@code%s*$") then
    return false
  end
  c.block_indent = c:indent()
  c.fence_str = "```"
  c:append_line("```" .. (lang or "fortran"))
  c:push_state("code")
  c:eat()
  return true
end

--- Upstream `_beginLiteralBlock`: the previous line must be blank and the
--- paragraph before it must end with `::`.
---@return boolean
local function begin_literal(c)
  local prev = c:line_at(c.lnum - 1)
  if prev == nil or not is_blank(prev) then
    return false
  end
  local found = false
  local i = c.lnum - 2
  while i >= 1 do
    local line = c:line_at(i)
    if is_blank(line) then
      i = i - 1
    elseif ends_with(line, "::") then
      found = true
      break
    else
      return false
    end
  end
  if not found then
    return false
  end
  c:append_line("```")
  if c:indent() == 0 then
    c:push_state("literal_single")
    c.block_indent = 0
  else
    c:push_state("literal")
    c.block_indent = c:indent()
  end
  return true
end

--- Ordered field markers (docStringUtils.ts:127-158). Returns name, type, text.
---@param line string
---@return string|nil, string|nil, string|nil
local function match_field(line)
  local body = trim_start(line):gsub("^!>%s*", "")
  local name, text = body:match("^[@\\]param%s+([%a_][%w_]*)%s+(.+)$")
  if name then
    return name, nil, text
  end
  local n2, ty, t2 = body:match("^([%a_][%w_]*)%s+%(([^()]*)%)%s*:%s*(.+)$")
  if n2 then
    return n2, ty, t2
  end
  local n3, t3 = body:match("^([%a_][%w_]*):%s+(.+)$")
  if n3 then
    return n3, nil, t3
  end
  return nil, nil, nil
end

--- Field list -> markdown bullet. The continuation rule is upstream's: a line
--- belongs to the field only when it is indented STRICTLY MORE than the marker
--- (docStringUtils.ts:210-237).
---@return boolean
local function begin_field_list(c)
  local name, ty, text = match_field(c:cur())
  if not name then
    return false
  end
  local marker_indent = c:indent()
  local was_field = c.in_fields
  c:eat()
  while true do
    local line = c:cur()
    if line == nil or is_blank(line) then
      break
    end
    if indent_of(line) > marker_indent then
      text = text .. " " .. trim(line)
      c:eat()
    else
      break
    end
  end
  if not was_field and c.out ~= "" then
    -- a markdown list needs a blank line after a paragraph
    c.out = trim_end(c.out) .. "\n\n"
    c.skip_empty = false
  end
  local item = "- `" .. name .. "`"
  if ty and ty ~= "" then
    item = item .. " (`" .. ty .. "`)"
  end
  c:append_line(item .. " — " .. trim_end(text))
  c.in_fields = true
  return true
end

--- Upstream `_beginList`, including the "halve indents >= 4" rule that keeps a
--- deep list item from being read as an indented code block.
---@return boolean
local function begin_list(c)
  local line = c:cur()
  local dash = line:match("^( *)%-%s")
  local star = line:match("^( *)%*%s")
  local number = line:match("^( *)%d+%.%s")

  if dash or star then
    local lead = dash or star
    if #lead >= 4 then
      line = string.rep(" ", math.floor(#lead / 2)) .. trim_start(line)
    elseif star and #lead == 0 then
      line = " " .. line
    end
    c:append_text_line(line)
    c:eat()
    if c.state ~= "list" then
      c:push_state("list")
    end
    return true
  end

  if number then
    c:append_text_line(line)
    c:eat()
    return true
  end
  return false
end

-- --- states ----------------------------------------------------------------

--- The state machine. Exposed so a spec can prove the progress guard fires.
M._states = {}

M._states.text = function(c)
  if is_blank(c:cur()) then
    c.state = "empty"
    return
  end
  -- fixed dispatch order (docStringConversion.ts:225-263), Fortran-ised
  if begin_fence(c) then
    return
  end
  if begin_code(c) then
    return
  end
  if begin_literal(c) then
    return
  end
  if begin_field_list(c) then
    return
  end
  if begin_list(c) then
    return
  end
  c:append_text_line(c:format_plain_text_indent(c:cur()))
  c:eat()
end

M._states.empty = function(c)
  if is_blank(c:cur()) then
    c:append_line()
    c:eat()
    return
  end
  c.state = "text"
end

M._states.fence = function(c)
  local line = c:cur()
  if line:match("^%s*```") and not line:match("^%s*````") and c:indent() == c.block_indent then
    c.fence_str = "```"
    c:append_line(c.fence_str)
    c:append_line()
    c:pop_state()
  else
    c:append_raw(line)
  end
  c:eat()
end

M._states.code = function(c)
  local line = c:cur()
  if line:match("^%s*@endcode%s*$") then
    c:trim_and_append_line("```")
    c:append_line()
    c:pop_state()
  else
    c:append_raw(c:within_block())
  end
  c:eat()
end

M._states.literal = function(c)
  if is_blank(c:cur()) then
    c:append_line()
    c:eat()
    return
  end
  if c:outside_block() and is_blank(c:line_at(c.lnum - 1)) then
    c:trim_and_append_line("```")
    c:append_line()
    c:pop_state()
    return
  end
  c:append_raw(c:within_block())
  c:eat()
end

M._states.literal_single = function(c)
  c:append_line(c:cur())
  c:append_line("```")
  c:append_line()
  c:pop_state()
  c:eat()
end

M._states.list = function(c)
  if is_blank(c:cur()) or c:outside_block() then
    c:pop_state()
    return
  end
  if not begin_list(c) then
    c:append_text_line(trim_start(c:cur()))
    c:eat()
  end
end

--- Normalise a Fortran doc comment into markdown.
---@param text string|nil
---@return string
function M.doc_to_markdown(text)
  if not text or text == "" then
    return ""
  end

  local stripped = {}
  for i, line in ipairs(lines_of(text)) do
    stripped[i] = strip_leader(line)
  end
  -- sentinel: every real line must take part in the common-indent pass
  table.insert(stripped, 1, "")

  local c = setmetatable({
    lines = clean_and_split(table.concat(stripped, "\n")),
    lnum = 1,
    state = "text",
    stack = {},
    out = "",
    skip_empty = true,
    in_fields = false,
    block_indent = 0,
    fence_str = "```",
  }, Conv)

  while c:cur() ~= nil do
    local before_state, before_line = c.state, c.lnum
    local fn = M._states[c.state]
    if not fn then
      break
    end
    fn(c)
    -- PROGRESS GUARD (docStringConversion.ts:145-150): a pass that changes
    -- neither the state nor the line number would spin forever.
    if c.state == before_state and c.lnum == before_line then
      break
    end
  end

  -- close any block still open at EOF
  if c.state == "fence" or c.state == "literal" or c.state == "code" then
    c:trim_and_append_line(c.fence_str or "```")
  end

  return trim(c.out)
end

return M
