-- Custom blink.cmp source for Fortran keywords
-- Provides completions from fortran-docs.json with documentation preview

local docs = require("andrew.fortran.docs")

local source = {}

-- Cache for pre-built completion items
local cached_items = nil

-- Categorize keyword for completion kind
local function get_kind(keyword)
  -- Use LSP CompletionItemKind values
  -- 3 = Function, 14 = Keyword
  if keyword:match("^mpi") or keyword:match("^MPI") then
    return 3 -- Function (MPI calls)
  elseif keyword:match("^omp") or keyword:match("^OMP") then
    return 14 -- Keyword (OpenMP directives)
  else
    return 3 -- Function (default for intrinsics/subroutines)
  end
end

-- Build and cache completion items once
local function get_items()
  if cached_items then
    return cached_items
  end

  cached_items = {}
  local keywords = docs.keywords()
  local all_docs = docs.load()

  for _, kw in ipairs(keywords) do
    local doc_text = all_docs[kw] or ""
    table.insert(cached_items, {
      label = kw,
      kind = get_kind(kw),
      documentation = {
        kind = "markdown",
        value = doc_text,
      },
    })
  end

  return cached_items
end

-- Constructor
function source.new(opts)
  local self = setmetatable({}, { __index = source })
  self.opts = opts or {}
  -- Pre-build cache on source creation
  get_items()
  return self
end

-- Only enable for Fortran filetypes
function source:enabled()
  local ft = vim.bo.filetype
  return ft == "fortran"
    or ft:match("^fortran")
    or ft == "f90"
    or ft == "f95"
end

-- Main completion function - returns cached items instantly
function source:get_completions(ctx, callback)
  callback({
    is_incomplete_forward = false,
    is_incomplete_backward = false,
    items = get_items(),
  })
end

-- Resolve documentation (already included, just return item)
function source:resolve(item, callback)
  callback(item)
end

return source
