local engine = require("andrew.vault.engine")
local notify = require("andrew.vault.notify")
local text_utils = require("andrew.vault.text_utils")
local vault_index = require("andrew.vault.vault_index")

local M = {}

--- Check if a file in the index already has a given tag (case-insensitive, exact).
---@param idx table vault index instance
---@param rel_path string relative path of the file
---@param tag string tag name to check
---@return boolean
local function file_has_tag(idx, rel_path, tag)
  local entry = idx:get_entry(rel_path)
  if not entry then return false end
  return vault_index.tag_matches(entry.tags, tag, { exact = true, case_insensitive = true })
end

--- Get all files from the index that contain a given tag (case-insensitive, exact).
---@param idx table vault index instance
---@param tag string tag name to find
---@return string[] abs_paths list of absolute file paths
local function files_with_tag(idx, tag)
  local files = {}
  for _, entry in pairs(idx:snapshot_files()) do
    if vault_index.tag_matches(entry.tags, tag, { exact = true, case_insensitive = true }) then
      files[#files + 1] = entry.abs_path
    end
  end
  return files
end

--- Escape a string for use in Lua gsub patterns.
---@param s string
---@return string
local function pattern_escape(s)
  return s:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
end

local split_lines = text_utils.split_lines

local function reload_buffers(paths)
  local path_set = {}
  for _, p in ipairs(paths) do path_set[p] = true end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local bufname = vim.api.nvim_buf_get_name(buf)
      if path_set[bufname] then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("edit!")
        end)
      end
    end
  end
end


--- Collect all unique tags from the vault via the vault index.
---@param callback fun(tags: string[])
local function collect_tags(callback)
  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local tags = idx:all_tags()
    vim.schedule(function() callback(tags) end)
    return
  end
  -- Index not ready yet; return empty and let caller retry
  vim.schedule(function() callback({}) end)
end

M.collect_tags = collect_tags

--- Show notes containing a specific tag using fzf-lua grep.
---@param tag string the tag name (without #)
function M.search_tag(tag)
  if not tag or tag == "" then
    notify.warn("no tag specified")
    return
  end

  local fzf = require("fzf-lua")
  -- Search for both inline #tag and frontmatter "- tag" occurrences
  local pattern = "#" .. fzf.utils.rg_escape(tag) .. "\\b|^\\s+- " .. fzf.utils.rg_escape(tag) .. "\\s*$"
  fzf.grep(engine.vault_fzf_opts("Tag #" .. tag, {
    search = pattern,
    no_esc = true,
    rg_opts = engine.rg_base_opts(),
  }))
end

--- Hierarchical tag tree picker.
--- Shows tags in an indented tree with file counts per level.
--- Selecting a tag runs search_tag() to find all notes with that tag.
function M.tag_tree()
  local tag_tree = require("andrew.vault.tag_tree")

  local idx = vault_index.current()
  if not idx or not idx:is_ready() then
    notify.index_not_ready()
    return
  end

  local tag_counts = idx:tags_with_counts()
  if not next(tag_counts) then
    notify.no_tags()
    return
  end

  local root = tag_tree.build_tree(tag_counts)
  local entries = tag_tree.flatten(root)

  local fzf = require("fzf-lua")
  fzf.fzf_exec(entries, {
    prompt = "Tag tree> ",
    fzf_opts = {
      ["--ansi"] = "",
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      ["--no-sort"] = "",
      ["--header"] = "  ▸/▾ = has children  (direct/total)  Enter = search tag",
    },
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local full_tag = selected[1]:match("^([^\t]+)")
          if full_tag then
            M.search_tag(full_tag)
          end
        end
      end,
    },
  })
end

--- Two-step tag picker:
--- 1. Show all unique tags in the vault
--- 2. On selection, show all notes containing that tag
function M.tags()
  collect_tags(function(tags)
    if #tags == 0 then
      notify.no_tags()
      return
    end

    local fzf = require("fzf-lua")
    fzf.fzf_exec(tags, {
      prompt = "Vault tags> ",
      actions = {
        ["default"] = function(selected)
          if selected and selected[1] then
            M.search_tag(selected[1])
          end
        end,
      },
    })
  end)
end

--- Add a tag to multiple notes at once.
--- Prompts for a tag name, then opens fzf-lua multi-select to pick notes.
--- Inserts the tag into each selected file's YAML frontmatter.
function M.add_tag()
  vim.ui.input({ prompt = "Tag to add: " }, function(tag)
    if not tag or vim.trim(tag) == "" then
      return
    end
    tag = vim.trim(tag)

    local fzf = require("fzf-lua")
    local fd = engine.fd_bin()
    if not fd then
      notify.warn("fd/fdfind not found")
      return
    end
    local cmd = fd .. " --type f --extension md --base-directory " .. vim.fn.shellescape(engine.vault_path)

    fzf.fzf_exec(cmd, engine.vault_fzf_opts("Add #" .. tag .. " to", {
      fzf_opts = { ["--multi"] = "" },
      actions = {
        ["default"] = function(selected)
          if not selected or #selected == 0 then
            return
          end

          local updated = 0
          local modified_paths = {}
          -- Use vault index to skip files that already have the tag
          local idx = vault_index.current()
          for _, rel in ipairs(selected) do
            local clean = rel:gsub("^%./", "")
            local path = clean:match("^/") and clean or engine.vault_path .. "/" .. clean
            -- Index-based existence check: skip file entirely if tag already present
            if idx and idx:is_ready() and file_has_tag(idx, clean, tag) then
              goto continue
            end
            do -- scope block for local variables
            local content = engine.read_file(path)
            if content then

              local lines = split_lines(content)

              local new_lines = {}
              local modified = false

              -- Check if file has frontmatter
              if #lines > 0 and lines[1] == "---" then
                local fm_end = nil
                for i = 2, #lines do
                  if lines[i] == "---" then
                    fm_end = i
                    break
                  end
                end

                if fm_end then
                  -- Find existing tags: field
                  local tags_line = nil
                  for i = 2, fm_end - 1 do
                    if lines[i]:match("^tags:") then
                      tags_line = i
                      break
                    end
                  end

                  if tags_line then
                    -- Find last tag entry after tags_line
                    local insert_at = tags_line
                    for i = tags_line + 1, fm_end - 1 do
                      if lines[i]:match("^%s+%- ") then
                        insert_at = i
                      else
                        break
                      end
                    end
                    -- Check if tag already exists
                    local already = false
                    for i = tags_line + 1, insert_at do
                      local existing = lines[i]:match("^%s+-%s+(.+)$")
                      if existing then
                        existing = existing:gsub("^[\"'](.+)[\"']$", "%1")
                        if vim.trim(existing) == tag then
                          already = true
                          break
                        end
                      end
                    end
                    if not already then
                      for i = 1, insert_at do
                        new_lines[#new_lines + 1] = lines[i]
                      end
                      new_lines[#new_lines + 1] = "  - " .. tag
                      for i = insert_at + 1, #lines do
                        new_lines[#new_lines + 1] = lines[i]
                      end
                      modified = true
                    end
                  else
                    -- No tags: field — add before closing ---
                    for i = 1, fm_end - 1 do
                      new_lines[#new_lines + 1] = lines[i]
                    end
                    new_lines[#new_lines + 1] = "tags:"
                    new_lines[#new_lines + 1] = "  - " .. tag
                    for i = fm_end, #lines do
                      new_lines[#new_lines + 1] = lines[i]
                    end
                    modified = true
                  end
                end
              else
                -- No frontmatter — create one
                new_lines[#new_lines + 1] = "---"
                new_lines[#new_lines + 1] = "tags:"
                new_lines[#new_lines + 1] = "  - " .. tag
                new_lines[#new_lines + 1] = "---"
                for i = 1, #lines do
                  new_lines[#new_lines + 1] = lines[i]
                end
                modified = true
              end

              if modified then
                local out = io.open(path, "w")
                if out then
                  out:write(table.concat(new_lines, "\n"))
                  -- Preserve original trailing newline
                  if content:match("\n$") then
                    out:write("\n")
                  end
                  out:close()
                  updated = updated + 1
                  modified_paths[#modified_paths + 1] = path
                end
              end
            end
            end -- do block
            ::continue::
          end

          vim.schedule(function()
            reload_buffers(modified_paths)
            notify.info("added #" .. tag .. " to " .. updated .. " file(s)")
          end)
        end,
      },
    }))
  end)
end

--- Remove a tag from all notes that contain it.
--- Shows available tags via fzf, then removes the selected tag from
--- both YAML frontmatter and inline #tag occurrences in every matching file.
function M.remove_tag()
  collect_tags(function(tags)
    if #tags == 0 then
      notify.no_tags()
      return
    end

    local fzf = require("fzf-lua")
    fzf.fzf_exec(tags, {
      prompt = "Remove tag> ",
      actions = {
        ["default"] = function(selected)
          if not selected or not selected[1] then
            return
          end
          local tag = selected[1]

          -- Find all files containing this tag via vault index
          local idx = vault_index.current()
          if not idx or not idx:is_ready() then
            notify.index_not_ready()
            return
          end

          local files = files_with_tag(idx, tag)

          if #files == 0 then
            notify.info("tag #" .. tag .. " not found in any files")
            return
          end

          local escaped_tag = pattern_escape(tag)
          local updated = 0
          for _, path in ipairs(files) do
            local content = engine.read_file(path)
            if content then

              local lines = split_lines(content)

              local new_lines = {}
              local modified = false
              local in_frontmatter = false
              local in_tags_block = false
              local fm_count = 0

              for i, line in ipairs(lines) do
                local skip = false

                -- Track frontmatter boundaries
                if line == "---" then
                  fm_count = fm_count + 1
                  if fm_count == 1 then
                    in_frontmatter = true
                  elseif fm_count == 2 then
                    in_frontmatter = false
                    in_tags_block = false
                  end
                end

                if in_frontmatter then
                  -- Detect tags: field
                  if line:match("^tags:") then
                    in_tags_block = true
                  elseif in_tags_block then
                    if line:match("^%s+%- ") then
                      -- Check if this is the tag to remove
                      local entry = line:match("^%s+-%s+(.+)$")
                      if entry then
                        entry = entry:gsub("^[\"'](.+)[\"']$", "%1")
                        if vim.trim(entry) == tag then
                          skip = true
                          modified = true
                        end
                      end
                    else
                      in_tags_block = false
                    end
                  end
                end

                if not skip then
                  -- Remove inline #tag occurrences outside frontmatter
                  if not in_frontmatter and fm_count >= 2 then
                    local cleaned = line:gsub("#" .. escaped_tag .. "(%f[%s%p%z])", "")
                    -- Also handle #tag at end of line
                    cleaned = cleaned:gsub("#" .. escaped_tag .. "$", "")
                    if cleaned ~= line then
                      -- Clean up extra whitespace left behind
                      cleaned = cleaned:gsub("%s+$", "")
                      modified = true
                      line = cleaned
                    end
                  end
                  new_lines[#new_lines + 1] = line
                end
              end

              -- Clean up empty tags: field (tags: with no entries after it)
              local final_lines = {}
              for i, line in ipairs(new_lines) do
                if line:match("^tags:%s*$") then
                  -- Check if next line is NOT a tag entry
                  local next_line = new_lines[i + 1]
                  if not next_line or not next_line:match("^%s+%- ") then
                    modified = true
                    -- skip this empty tags: line
                  else
                    final_lines[#final_lines + 1] = line
                  end
                else
                  final_lines[#final_lines + 1] = line
                end
              end

              if modified then
                local out = io.open(path, "w")
                if out then
                  out:write(table.concat(final_lines, "\n"))
                  if content:match("\n$") then
                    out:write("\n")
                  end
                  out:close()
                  updated = updated + 1
                end
              end
            end
          end

          reload_buffers(files)

          notify.info("removed #" .. tag .. " from " .. updated .. " file(s)")
        end,
      },
    })
  end)
end

function M.setup()
  engine.register_cache({
    name = "tags",
    module = "andrew.vault.tags",
    invalidate = function() end,
    stats = function()
      local idx = vault_index.current()
      return {
        entries = idx and idx:is_ready() and #idx:all_tags() or 0,
      }
    end,
  })

  do
    local profiler = require("andrew.vault.memory_profiler")
    profiler.register_cache({
      name = "tags",
      get_size = function()
        local idx = vault_index.current()
        return idx and idx:is_ready() and #idx:all_tags() or 0
      end,
      get_capacity = function() return nil end,
      get_hits = function() return 0 end, -- no local cache; reads vault index directly
      get_misses = function() return 0 end, -- no local cache; reads vault index directly
      get_evictions = function() return 0 end, -- no local cache; reads vault index directly
    })
  end

  vim.api.nvim_create_user_command("VaultTags", function(opts)
    if opts.args and opts.args ~= "" then
      M.search_tag(opts.args)
    else
      M.tags()
    end
  end, {
    nargs = "?",
    desc = "Browse vault tags or search for a specific tag",
  })

  vim.keymap.set("n", "<leader>vft", function()
    M.tags()
  end, { desc = "Find: tags", silent = true })

  vim.api.nvim_create_user_command("VaultTagTree", function()
    M.tag_tree()
  end, {
    desc = "Browse vault tags in a hierarchical tree view",
  })

  vim.keymap.set("n", "<leader>vfT", function()
    M.tag_tree()
  end, { desc = "Find: tag tree", silent = true })

  vim.api.nvim_create_user_command("VaultTagAdd", function()
    M.add_tag()
  end, {
    desc = "Add a tag to multiple vault notes",
  })

  vim.api.nvim_create_user_command("VaultTagRemove", function()
    M.remove_tag()
  end, {
    desc = "Remove a tag from all vault notes",
  })

  vim.keymap.set("n", "<leader>vga", function()
    M.add_tag()
  end, { desc = "Tag: add to notes", silent = true })

  vim.keymap.set("n", "<leader>vgr", function()
    M.remove_tag()
  end, { desc = "Tag: remove from notes", silent = true })

  -- Palette registrations
  local palette = require("andrew.vault.command_palette")
  palette.register_command("VaultTags", "Browse vault tags or search for a specific tag", "Tags", function()
    M.tags()
  end, "<leader>vft")
  palette.register_command("VaultTagTree", "Browse vault tags in a hierarchical tree view", "Tags", function()
    M.tag_tree()
  end, "<leader>vfT")
  palette.register_command("VaultTagAdd", "Add a tag to multiple vault notes", "Tags", function()
    M.add_tag()
  end, "<leader>vga")
  palette.register_command("VaultTagRemove", "Remove a tag from all vault notes", "Tags", function()
    M.remove_tag()
  end, "<leader>vgr")
end

return M
