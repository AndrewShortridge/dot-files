-- vault_index_chunker.lua — Heading-based content chunking for incremental parsing
-- Pure functions: split markdown files into chunks at heading boundaries,
-- compute digests, diff against cached chunks, merge parsed data.

local M = {}

local pat = require("andrew.vault.patterns")

--- Split file lines into chunks at heading boundaries.
--- Frontmatter is always its own chunk. Each heading starts a new chunk.
--- Tracks code fence state to avoid splitting on headings inside fenced code blocks.
---@param lines string[] File lines (1-indexed content)
---@return table[] chunks Array of {start_line, end_line, lines}
---@return boolean has_fm Whether the file has frontmatter (first chunk is FM)
function M.chunk_by_headings(lines)
  local chunks = {}
  local current = { start_line = 1, lines = {} }
  local in_frontmatter = false
  local has_fm = false
  local in_code_fence = false

  for i, line in ipairs(lines) do
    -- Handle frontmatter boundaries (only line 1 can start frontmatter)
    if i == 1 and line:match(pat.FM_OPEN) then
      in_frontmatter = true
      has_fm = true
      current.lines[#current.lines + 1] = line
      goto continue
    end

    if in_frontmatter then
      current.lines[#current.lines + 1] = line
      if line:match(pat.FM_OPEN) then
        -- End of frontmatter: finalize this chunk
        in_frontmatter = false
        current.end_line = i
        chunks[#chunks + 1] = current
        current = { start_line = i + 1, lines = {} }
      end
      goto continue
    end

    -- Track code fence state to avoid false heading matches (backtick and tilde)
    if pat.is_code_fence(line) then
      in_code_fence = not in_code_fence
    end

    -- Heading boundary: start a new chunk (if current has content)
    -- Only match headings outside of fenced code blocks
    if not in_code_fence and line:match("^#+%s") and #current.lines > 0 then
      current.end_line = i - 1
      chunks[#chunks + 1] = current
      current = { start_line = i, lines = {} }
    end

    current.lines[#current.lines + 1] = line

    ::continue::
  end

  -- Finalize last chunk
  if #current.lines > 0 then
    current.end_line = #lines
    chunks[#chunks + 1] = current
  end

  return chunks, has_fm
end

--- Compute SHA256 digest of a chunk's content.
---@param chunk_lines string[] Lines in the chunk
---@return string digest Hex-encoded SHA256 hash
function M.chunk_digest(chunk_lines)
  local content = table.concat(chunk_lines, "\n")
  return vim.fn.sha256(content)
end

--- Compare new chunks against cached chunks, return indices of changed chunks.
---@param new_chunks table[] Chunks with digest computed
---@param cached_chunks table[]|nil Previously cached chunks
---@return integer[] changed_indices 1-indexed list of chunks that need re-parsing
function M.diff_chunks(new_chunks, cached_chunks)
  if not cached_chunks then
    -- No cache: all chunks are new
    local indices = {}
    for i = 1, #new_chunks do indices[i] = i end
    return indices
  end

  -- If chunk count changed, structure shifted — re-parse all
  if #new_chunks ~= #cached_chunks then
    local indices = {}
    for i = 1, #new_chunks do indices[#indices + 1] = i end
    return indices
  end

  -- Same count: compare digests positionally
  local changed = {}
  for i = 1, #new_chunks do
    if new_chunks[i].digest ~= cached_chunks[i].digest then
      changed[#changed + 1] = i
    end
  end

  return changed
end

--- Merge parsed_data from all chunks into flat entry fields.
--- Tags are deduplicated across chunks using a set, since hierarchical parent
--- tags (e.g. "project" from "project/active") may appear in multiple chunks.
---@param chunks table[] Chunks with parsed_data
---@return table merged { headings, block_ids, outlinks, tasks, inline_fields, tags }
function M.merge_chunk_data(chunks)
  local merged = {
    headings = {},
    block_ids = {},
    outlinks = {},
    tasks = {},
    inline_fields = {},
    tags = {},
  }
  local tag_set = {}
  for _, chunk in ipairs(chunks) do
    local pd = chunk.parsed_data
    if pd then
      vim.list_extend(merged.headings, pd.headings or {})
      vim.list_extend(merged.block_ids, pd.block_ids or {})
      vim.list_extend(merged.outlinks, pd.outlinks or {})
      vim.list_extend(merged.tasks, pd.tasks or {})
      -- inline_fields is a key-value table, not an array
      for k, v in pairs(pd.inline_fields or {}) do
        merged.inline_fields[k] = v
      end
      -- Deduplicate tags across chunks via set
      for _, tag in ipairs(pd.tags or {}) do
        tag_set[tag] = true
      end
    end
  end
  -- Convert tag set to sorted array (matching extract_tags output format)
  for tag in pairs(tag_set) do
    merged.tags[#merged.tags + 1] = tag
  end
  table.sort(merged.tags)
  return merged
end

--- Check if chunking should fall back to full re-parse.
--- Returns true if too many chunks changed (beyond fallback_threshold).
---@param changed_indices integer[]
---@param total_chunks integer
---@param threshold number Fraction (0-1) above which to fall back
---@return boolean should_fallback
function M.should_fallback(changed_indices, total_chunks, threshold)
  if total_chunks == 0 then return true end
  return #changed_indices / total_chunks > threshold
end

--- Return debug info for a file's chunk state.
---@param chunks table[]|nil Cached chunks array
---@return string[] lines Human-readable debug lines
function M.debug_info(chunks)
  if not chunks then
    return { "  No chunk data cached" }
  end
  local lines = {}
  lines[#lines + 1] = string.format("  Chunks: %d", #chunks)
  for i, chunk in ipairs(chunks) do
    local pd = chunk.parsed_data
    local parts = {}
    if pd then
      if pd.headings and #pd.headings > 0 then parts[#parts + 1] = #pd.headings .. "h" end
      if pd.tasks and #pd.tasks > 0 then parts[#parts + 1] = #pd.tasks .. "t" end
      if pd.outlinks and #pd.outlinks > 0 then parts[#parts + 1] = #pd.outlinks .. "l" end
      if pd.block_ids and #pd.block_ids > 0 then parts[#parts + 1] = #pd.block_ids .. "b" end
      if pd.tags and #pd.tags > 0 then parts[#parts + 1] = #pd.tags .. "g" end
    end
    local summary = #parts > 0 and (" [" .. table.concat(parts, ",") .. "]") or ""
    lines[#lines + 1] = string.format(
      "  [%d] L%d-%d (%d lines) digest=%s%s",
      i, chunk.start_line, chunk.end_line,
      chunk.end_line - chunk.start_line + 1,
      chunk.digest and chunk.digest:sub(1, 8) or "none",
      summary
    )
  end
  return lines
end

return M
