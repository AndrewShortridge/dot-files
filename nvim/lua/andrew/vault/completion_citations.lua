-- =============================================================================
-- blink.cmp source: pandoc citekeys after `@`
-- =============================================================================
-- Type `@` in a markdown note (`[@`, `[@a; @`, `[-@`, or a bare in-text `@`)
-- and get the citekeys pandoc can resolve, with the matching Library note.
--
-- Where the keys come from. Library notes carry no citekey; the keys are
-- minted by Methods/manuscript-export/enl2csl.py from the EndNote library
-- and live in CSL-JSON files. Two kinds are read, deduplicated by key, in
-- this order:
--   1. the note's own `bibliography:` (string or list, relative to the
--      note's folder -- the convention in "Manuscript Export to Word with
--      EndNote References"). This is the file pandoc resolves against.
--   2. the vault-wide key databases in the provider's `opts.databases`
--      (globs relative to the vault root; default `temporary/*.json`,
--      where enl2csl.py writes its output beside the .enl).
-- A key found only in (2) while the note declares a bibliography is still
-- offered, flagged "not in bibliography", and sorted after the rest:
-- inserting it is legal markdown, but pandoc will warn "Citation not found"
-- until the JSON beside the note is regenerated.
--
-- Library matching. Every note under `<vault>/Library/` with a `title:` is
-- matched to a CSL entry by DOI, else by title normalised the way
-- enl2csl.py's normalise_title does (lowercase, [a-z0-9] only). A match adds
-- " · Library" to the menu row and the note path to the documentation.
--
-- Fresh item tables per query, same reason as latex/blink-source.lua: blink
-- mutates the items it is handed.

local fm_parser = require("andrew.vault.frontmatter_parser")
local file_cache = require("andrew.vault.file_cache")
local link_scan = require("andrew.vault.link_scan")

local source = {}

local KIND_REFERENCE = 18
local DEFAULT_DATABASES = { "temporary/*.json" }
local MAX_AUTHORS = 6

-- path -> { mtime_sec, mtime_nsec, size, entries }
local db_cache = {}

---@param title string
---@return string
function source.normalise_title(title)
  return (tostring(title):lower():gsub("[^%w]", ""))
end

---Byte index (1-based) of the `@` opening the citekey that ends at `col`, or
---nil when the cursor is not on a citation. pandoc keys: alphanumerics, `_`,
---and internal `:.#$%&-+?<>~/`. The `@` must start the line or follow
---whitespace, `[`, `;`, `-` (suppress-author `[-@key]`) or `(`, so e-mail
---addresses (`dongare@uconn.edu`) never open the menu.
---@param line string
---@param col integer  0-based cursor column (bytes before the cursor)
---@return integer?
function source.cite_start(line, col)
  local before = line:sub(1, col)
  local pos = before:match("()@[%w_:%.#%$%%&%+%?<>~/%-]*$")
  if not pos then
    return nil
  end
  if pos > 1 and not before:sub(pos - 1, pos - 1):match("[%s%[;%-%(]") then
    return nil
  end
  return pos
end

---@param path string
---@return table[]  CSL items (each with a string `id`), empty on any failure
local function load_db(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    db_cache[path] = nil
    return {}
  end
  local hit = db_cache[path]
  if hit and hit.sec == stat.mtime.sec and hit.nsec == stat.mtime.nsec and hit.size == stat.size then
    return hit.entries
  end
  local entries = {}
  local fd = io.open(path, "r")
  if fd then
    local text = fd:read("*a")
    fd:close()
    local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    if ok and type(data) == "table" then
      for _, e in ipairs(data) do
        if type(e) == "table" and type(e.id) == "string" and e.id ~= "" then
          entries[#entries + 1] = e
        end
      end
    else
      vim.notify_once("citations: " .. path .. " is not CSL-JSON", vim.log.levels.WARN)
    end
  end
  db_cache[path] = { sec = stat.mtime.sec, nsec = stat.mtime.nsec, size = stat.size, entries = entries }
  return entries
end

---@param value any  frontmatter value (string or list)
---@return string[]
local function as_list(value)
  if type(value) == "table" then
    return value
  end
  if value == nil or value == "" then
    return {}
  end
  return { tostring(value) }
end

---@param dir string
---@param p string
---@return string
local function resolve(dir, p)
  p = vim.fn.expand(p)
  if p:sub(1, 1) ~= "/" then
    p = dir .. "/" .. p
  end
  return vim.fs.normalize(p)
end

---Library notes keyed for matching: { by_doi = {}, by_title = {} } -> vault-relative path.
---@param root string
local function library_index(root)
  local by_doi, by_title = {}, {}
  local lib = root .. "/Library"
  for name, kind in vim.fs.dir(lib, { depth = 3 }) do
    if kind == "file" and name:sub(-3) == ".md" then
      local path = lib .. "/" .. name
      local lines = file_cache.read(path)
      local fm = lines and fm_parser.parse_lines(lines)
      if fm then
        local rel = "Library/" .. name
        local title = fm.fields.title
        if title and title ~= "" then
          local norm = source.normalise_title(title)
          by_title[norm] = by_title[norm] or rel
        end
        local doi = fm.fields.doi or fm.fields.DOI
        if type(doi) == "string" and doi ~= "" then
          by_doi[doi:lower()] = by_doi[doi:lower()] or rel
        end
      end
    end
  end
  return { by_doi = by_doi, by_title = by_title }
end

---@param e table  CSL item
---@return string?
local function year_of(e)
  local parts = e.issued and e.issued["date-parts"]
  local y = parts and parts[1] and parts[1][1]
  return y and tostring(y) or nil
end

---@param name table  CSL name
---@return string
local function name_str(name)
  if name.literal then
    return name.literal
  end
  local family = name.family or ""
  local initials = {}
  for w in (name.given or ""):gmatch("[^%s%.%-]+") do
    initials[#initials + 1] = w:sub(1, 1) .. "."
  end
  if #initials == 0 then
    return family
  end
  return table.concat(initials, " ") .. " " .. family
end

---@param e table  CSL item
---@param lib_rel string?
---@param db_rel string
---@param warn string?
---@return string
local function documentation(e, lib_rel, db_rel, warn)
  local out = {}
  if e.title then
    out[#out + 1] = "**" .. e.title .. "**"
    out[#out + 1] = ""
  end
  local names = e.author or e.editor or {}
  if #names > 0 then
    local shown = {}
    for i = 1, math.min(#names, MAX_AUTHORS) do
      shown[i] = name_str(names[i])
    end
    out[#out + 1] = table.concat(shown, ", ") .. (#names > MAX_AUTHORS and ", et al." or "")
  end
  local pub = {}
  if e["container-title"] then
    pub[#pub + 1] = "*" .. e["container-title"] .. "*"
  elseif e.publisher then
    pub[#pub + 1] = e.publisher
  end
  if e.volume then
    pub[#pub + 1] = e.volume
  end
  local y = year_of(e)
  if y then
    pub[#pub + 1] = "(" .. y .. ")"
  end
  if e.page then
    pub[#pub + 1] = e.page
  end
  if #pub > 0 then
    out[#out + 1] = table.concat(pub, " ")
  end
  if e.DOI then
    out[#out + 1] = "DOI: " .. e.DOI
  end
  out[#out + 1] = ""
  out[#out + 1] = "Library: " .. (lib_rel and ("`" .. lib_rel .. "`") or "no note")
  out[#out + 1] = "Key from: `" .. db_rel .. "`"
  if warn then
    out[#out + 1] = ""
    out[#out + 1] = "> [!warning] " .. warn
  end
  return table.concat(out, "\n")
end

---Paths of every key database for `bufnr`, the note's own bibliography first.
---@param bufnr integer
---@param root string?
---@param globs string[]
---@return string[] paths, table<string, true> own  (own = the note's bibliography files)
local function databases(bufnr, root, globs)
  local paths, seen, own = {}, {}, {}
  local file = vim.api.nvim_buf_get_name(bufnr)
  local fm = fm_parser.parse_buffer_cached(bufnr)
  if fm and file ~= "" then
    local dir = vim.fs.dirname(file)
    for _, p in ipairs(as_list(fm.fields.bibliography)) do
      local abs = resolve(dir, tostring(p))
      if not seen[abs] then
        seen[abs], own[abs] = true, true
        paths[#paths + 1] = abs
      end
    end
  end
  if root then
    for _, g in ipairs(globs) do
      for _, abs in ipairs(vim.fn.glob(root .. "/" .. g, true, true)) do
        abs = vim.fs.normalize(abs)
        if not seen[abs] then
          seen[abs] = true
          paths[#paths + 1] = abs
        end
      end
    end
  end
  return paths, own
end

---Completion item templates for `bufnr` (no textEdit yet).
---@param bufnr integer
---@param globs string[]
---@return table[]
function source.build(bufnr, globs)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local root = file ~= "" and vim.fs.root(file, ".obsidian") or nil
  local paths, own = databases(bufnr, root, globs)
  local declares_bib = next(own) ~= nil
  local lib = root and library_index(root) or { by_doi = {}, by_title = {} }

  local items, seen = {}, {}
  for _, path in ipairs(paths) do
    local db_rel = root and path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or path
    for _, e in ipairs(load_db(path)) do
      if not seen[e.id] then
        seen[e.id] = true
        local lib_rel = (e.DOI and lib.by_doi[e.DOI:lower()]) or (e.title and lib.by_title[source.normalise_title(e.title)])
        local missing = declares_bib and not own[path]
        local warn = missing and "Not in this note's `bibliography:`; pandoc will report it as not found." or nil
        local names = e.author or e.editor or {}
        local first = names[1] and (names[1].family or names[1].literal) or nil
        local desc = {}
        if first then
          desc[#desc + 1] = first .. (#names > 1 and " et al." or "")
        end
        desc[#desc + 1] = year_of(e)
        local description = table.concat(desc, " ")
        if lib_rel then
          description = description .. " · Library"
        end
        if missing then
          description = description .. " · not in bibliography"
        end
        items[#items + 1] = {
          label = e.id,
          filterText = e.id .. " " .. (e.title or ""),
          sortText = (missing and "1" or "0") .. e.id,
          kind = KIND_REFERENCE,
          labelDetails = { description = description },
          documentation = { kind = "markdown", value = documentation(e, lib_rel, db_rel, warn) },
        }
      end
    end
  end
  return items
end

function source.new(opts)
  local self = setmetatable({}, { __index = source })
  self.opts = opts or {}
  self.globs = self.opts.databases or DEFAULT_DATABASES
  return self
end

function source:enabled()
  return vim.bo.filetype == "markdown"
end

function source:get_trigger_characters()
  return { "@" }
end

function source:get_completions(ctx, callback)
  local empty = { is_incomplete_forward = false, is_incomplete_backward = false, items = {} }
  local at = source.cite_start(ctx.line, ctx.cursor[2])
  if not at then
    return callback(empty)
  end
  local bufnr = ctx.bufnr
  local row = ctx.cursor[1]
  if fm_parser.cursor_in_frontmatter(bufnr, row - 1) or link_scan.is_inside_code_span(ctx.line, at) then
    return callback(empty)
  end
  if link_scan.is_in_fenced_code_lines(vim.api.nvim_buf_get_lines(bufnr, 0, row, false), row) then
    return callback(empty)
  end

  -- Replace from just after `@` to the cursor, so keys with internal
  -- punctuation (which blink's [\w-] keyword does not cover) are replaced whole.
  local range = {
    start = { line = row - 1, character = at },
    ["end"] = { line = row - 1, character = ctx.cursor[2] },
  }
  local items = source.build(bufnr, self.globs)
  for _, item in ipairs(items) do
    item.textEdit = { newText = item.label, range = range }
  end
  callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
end

function source:resolve(item, callback)
  callback(item)
end

return source
