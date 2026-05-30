local base = require("andrew.vault.completion_base")
local pat = require("andrew.vault.patterns")

local _prefix_index = nil

--- Build tag completion items from the vault index.
---@param vault_path string
---@param callback fun(items: table[])
local function build(_vault_path, callback)
  _prefix_index = nil -- clear stale index before every rebuild
  local idx = base.get_ready_index()
  if not idx then
    callback({})
    return
  end

  local counts = idx:tags_with_counts()

  -- Sorted tag list for efficient child detection
  local all_tags = {}
  for tag, _ in pairs(counts) do
    all_tags[#all_tags + 1] = tag
  end
  table.sort(all_tags)

  -- Pre-compute which tags have children (O(N) via sorted scan)
  local has_children_set = {}
  for i, tag in ipairs(all_tags) do
    local prefix = tag .. "/"
    for j = i + 1, #all_tags do
      if all_tags[j]:sub(1, #prefix) == prefix then
        has_children_set[tag] = true
        break
      elseif all_tags[j] > prefix then
        break
      end
    end
  end

  -- Build completion items
  local items = {}
  for _, tag in ipairs(all_tags) do
    local count = counts[tag]
    local has_children = has_children_set[tag] or false

    items[#items + 1] = base.make_item("#" .. tag, tag, tag,
      has_children and base.KIND.Folder or base.KIND.Keyword, {
      sortText = base.freq_sort_text(count, tag),
      description = has_children
        and base.count_label(count) .. " +"
        or base.count_label(count),
    })
  end

  -- Pre-index: prefix_string -> { immediate = items[], descendants = items[] }
  local prefix_idx = {}
  for _, item in ipairs(items) do
    local tag = item.filterText -- e.g., "project/sub/deep"
    local pos = 0
    while true do
      pos = tag:find("/", pos + 1)
      if not pos then break end
      local prefix = tag:sub(1, pos) -- e.g., "project/", "project/sub/"
      if not prefix_idx[prefix] then
        prefix_idx[prefix] = { immediate = {}, descendants = {} }
      end
      local entry = prefix_idx[prefix]
      entry.descendants[#entry.descendants + 1] = item
      -- Immediate child: no "/" in the remainder after prefix
      local remainder = tag:sub(pos + 1)
      if remainder ~= "" and not remainder:find("/") then
        entry.immediate[#entry.immediate + 1] = item
      end
    end
  end
  _prefix_index = prefix_idx

  callback(items)
end

--- Prefix-aware tag completion with hierarchical drill-down.
---@param self table
---@param ctx table
---@param items table[]
---@param callback fun(response: table)
local function get_completions(self, ctx, items, callback)
  local before = ctx.line:sub(1, ctx.cursor[2])

  -- Only trigger after a # that looks like a tag start
  if not before:match(pat.TAG_TRIGGER) and not before:match("^#[%w_/-]*$") then
    callback(base.empty_response)
    return
  end

  -- Exclude markdown headings
  local trimmed = vim.trim(before)
  if trimmed:match("^#+%s") or trimmed:match("^#+$") then
    callback(base.empty_response)
    return
  end

  -- Extract the typed text after #
  local typed = before:match(pat.TAG_COMPLETION) or ""

  -- Detect hierarchy drill-down: typed prefix ends with /
  local parent_prefix = typed:match("^(.+/)$")

  if parent_prefix then
    -- Fast path: use pre-built prefix index
    local indexed = _prefix_index and _prefix_index[parent_prefix]
    if indexed then
      local filtered = #indexed.immediate > 0 and indexed.immediate or indexed.descendants
      callback(base.response(filtered))
    else
      -- No entries for this prefix
      callback(base.empty_response)
    end
  else
    -- Flat mode: return all items
    callback(base.response(items))
  end
end

local source = base.create_source({
  name = "tags",
  build = build,
  get_completions = get_completions,
})

function source:get_trigger_characters()
  return { "#", "/" }
end

return source
