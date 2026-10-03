#!/usr/bin/env -S nvim -l
-- Extract documentation from new-snippets.json to fortran-docs.json
-- Run with: nvim -l extract-docs.lua

local script_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local snippets_path = script_dir .. "/new-snippets.json"
local output_path = script_dir .. "/fortran-docs.json"

-- Read snippets file
local file = io.open(snippets_path, "r")
if not file then
  print("Error: Cannot open " .. snippets_path)
  os.exit(1)
end

local content = file:read("*a")
file:close()

local snippets = vim.json.decode(content)
if not snippets then
  print("Error: Failed to parse JSON")
  os.exit(1)
end

-- Helper to safely convert value to string
local function to_string(val)
  if type(val) == "string" then
    return val
  elseif type(val) == "table" then
    local parts = {}
    for _, v in ipairs(val) do
      if type(v) == "string" then
        table.insert(parts, v)
      end
    end
    return table.concat(parts, "\n")
  end
  return tostring(val)
end

local docs = {}
local count = 0

for name, snippet in pairs(snippets) do
  -- Skip the special _documentation top-level key for now (complex structured docs)
  if name ~= "_documentation" and type(snippet) == "table" then
    -- Get the description (which contains markdown documentation)
    local description = snippet.description
    if description and type(description) == "string" and #description > 50 then
      -- Index by all prefixes
      local prefixes = snippet.prefix
      if prefixes then
        if type(prefixes) == "string" then
          prefixes = { prefixes }
        end

        for _, prefix in ipairs(prefixes) do
          if type(prefix) == "string" then
            local key = prefix:lower()
            -- Only store if we don't already have a longer entry
            if not docs[key] or #description > #docs[key] then
              docs[key] = description
              count = count + 1
            end
          end
        end
      end
    end

    -- Also check for structured documentation object
    if snippet.documentation and type(snippet.documentation) == "table" then
      local doc_obj = snippet.documentation
      local md = {}

      if doc_obj.name and type(doc_obj.name) == "string" then
        table.insert(md, "## " .. doc_obj.name)
      else
        table.insert(md, "## " .. name)
      end

      if doc_obj.synopsis and type(doc_obj.synopsis) == "table" then
        table.insert(md, "\n### Synopsis")
        if doc_obj.synopsis.usage then
          table.insert(md, to_string(doc_obj.synopsis.usage))
        end
      end

      if doc_obj.description and type(doc_obj.description) == "string" then
        table.insert(md, "\n### Description")
        table.insert(md, doc_obj.description)
      end

      if doc_obj.characteristics and type(doc_obj.characteristics) == "table" then
        table.insert(md, "\n### Characteristics")
        for _, char in ipairs(doc_obj.characteristics) do
          if type(char) == "string" then
            table.insert(md, "- " .. char)
          end
        end
      end

      if doc_obj.examples and type(doc_obj.examples) == "table" and doc_obj.examples.code then
        table.insert(md, "\n### Example")
        local code = to_string(doc_obj.examples.code)
        table.insert(md, "```fortran\n" .. code .. "\n```")
      end

      if doc_obj.standard and type(doc_obj.standard) == "string" then
        table.insert(md, "\n**Standard:** " .. doc_obj.standard)
      end

      local full_doc = table.concat(md, "\n")

      -- Index by prefixes
      local prefixes = snippet.prefix
      if prefixes then
        if type(prefixes) == "string" then
          prefixes = { prefixes }
        end
        for _, prefix in ipairs(prefixes) do
          if type(prefix) == "string" then
            local key = prefix:lower()
            docs[key] = full_doc
          end
        end
      end
    end
  end
end

-- MERGE into whatever fortran-docs.json already holds, rather than replacing
-- it. Only ~210 of its 388 entries come from new-snippets.json: the rest are
-- INTRINSIC docs (achar, allocated, dot_product, epsilon, ...) that were added
-- by hand, five of them as structured OBJECTS that andrew.fortran.docs.render
-- normalizes. A plain overwrite silently deleted all 178 of them, and hover on
-- SIZE, ALLOCATED and DOT_PRODUCT stopped working.
local merged = {}
local kept = 0
local existing_file = io.open(output_path, "r")
if existing_file then
  local existing_raw = existing_file:read("*a")
  existing_file:close()
  local ok_existing, existing = pcall(vim.json.decode, existing_raw)
  if not ok_existing or type(existing) ~= "table" then
    print("Error: " .. output_path .. " exists but does not parse; refusing to overwrite it")
    os.exit(1)
  end
  for k, v in pairs(existing) do
    merged[k] = v
    kept = kept + 1
  end
end

-- Longest wins, the same rule the extraction above already applies to its own
-- map. 206 of the pre-existing entries are the FULL structured rendering of a
-- routine (4.5 KB of Name/Synopsis/Description/Examples); what this script can
-- rebuild from `description` alone is a single 120-character sentence, so
-- replacing them unconditionally would downgrade hover for every one of them.
-- A new snippet, which has no entry yet, is still picked up.
local updated = 0
for k, v in pairs(docs) do
  local old = merged[k]
  if type(old) ~= "string" and old ~= nil then
    -- A structured entry outranks any extracted string: see the header of
    -- andrew.fortran.docs.render.
  elseif old == nil or #v > #old then
    merged[k] = v
    updated = updated + 1
  end
end

-- Write output with proper JSON formatting
local out_file = io.open(output_path, "w")
if not out_file then
  print("Error: Cannot write to " .. output_path)
  os.exit(1)
end

--- One entry, formatted the way the file already is: two-space indent, one
--- `"key": value` per line. Values are encoded by vim.json so a non-string
--- (the structured intrinsic entries) survives, and so does any control
--- character the hand-rolled escaper used to emit raw.
---@param tbl table
---@return string
local function encode_docs(tbl)
  local keys = {}
  for k in pairs(tbl) do
    if type(k) == "string" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)

  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = string.format("  %s: %s", vim.json.encode(k), vim.json.encode(tbl[k]))
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end

out_file:write(encode_docs(merged))
out_file:close()

print(string.format(
  "Extracted %d documentation entries (%d written, %d pre-existing kept) to %s",
  count, updated, kept, output_path
))
