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

-- Write output with proper JSON formatting
local out_file = io.open(output_path, "w")
if not out_file then
  print("Error: Cannot write to " .. output_path)
  os.exit(1)
end

-- Manual JSON encoding for simple string->string table
local function encode_docs(tbl)
  local parts = {}
  for k, v in pairs(tbl) do
    if type(k) == "string" and type(v) == "string" then
      -- Escape special characters in JSON strings
      local escaped = v
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
      table.insert(parts, string.format('  "%s": "%s"', k, escaped))
    end
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n}"
end

out_file:write(encode_docs(docs))
out_file:close()

print("Extracted " .. count .. " documentation entries to " .. output_path)
