local engine = require("andrew.vault.engine")

local M = {}

local function current_note_name()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then
    return nil
  end
  return vim.fn.fnamemodify(bufname, ":t:r")
end

local function resolve_link(name)
  local vp = engine.vault_path
  local direct = vp .. "/" .. name .. ".md"
  if vim.fn.filereadable(direct) == 1 then
    return direct
  end
  local found = vim.fs.find(name .. ".md", {
    path = vp,
    type = "file",
    limit = 1,
  })
  return found[1]
end

function M.backlinks()
  local name = current_note_name()
  if not name then
    vim.notify("Vault: buffer has no filename", vim.log.levels.WARN)
    return
  end

  local fzf = require("fzf-lua")
  fzf.grep({
    search = "\\[\\[" .. fzf.utils.rg_escape(name) .. "([#|][^\\]]*)?\\]\\]",
    cwd = engine.vault_path,
    no_esc = true,
    rg_opts = '--column --line-number --no-heading --color=always --smart-case -C 2 --glob "*.md"',
    prompt = "Backlinks to " .. name .. "> ",
    file_icons = true,
    git_icons = false,
  })
end

local function heading_slug(text)
  return text:lower()
    :gsub("[^%w%s%-]", "")
    :gsub("%s+", "-")
    :gsub("%-+", "-")
    :gsub("^%-+", "")
    :gsub("%-+$", "")
end

local function nearest_heading_above_cursor()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, row, false)
  for i = #lines, 1, -1 do
    local heading_text = lines[i]:match("^#+%s+(.*)")
    if heading_text then
      return heading_text
    end
  end
  return nil
end

function M.heading_backlinks()
  local name = current_note_name()
  if not name then
    vim.notify("Vault: buffer has no filename", vim.log.levels.WARN)
    return
  end

  local heading = nearest_heading_above_cursor()
  if not heading then
    vim.notify("Vault: no heading above cursor, falling back to regular backlinks", vim.log.levels.INFO)
    M.backlinks()
    return
  end

  local fzf = require("fzf-lua")
  fzf.grep({
    search = "\\[\\[" .. fzf.utils.rg_escape(name) .. "#" .. fzf.utils.rg_escape(heading) .. "([|][^\\]]*)?\\]\\]",
    cwd = engine.vault_path,
    no_esc = true,
    rg_opts = '--column --line-number --no-heading --color=always --smart-case -C 2 --glob "*.md"',
    prompt = "Heading backlinks to " .. name .. "#" .. heading .. "> ",
    file_icons = true,
    git_icons = false,
  })
end

function M.forwardlinks()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local seen = {}
  local links = {}
  local path_map = {}

  for _, line in ipairs(lines) do
    for link in line:gmatch("%[%[([^%]|#]+)") do
      -- Strip trailing backslash from \| escape used in markdown tables
      local trimmed = vim.trim(link:gsub("\\$", ""))
      if trimmed ~= "" and not seen[trimmed] then
        seen[trimmed] = true
        local path = resolve_link(trimmed)
        if path then
          local rel = path:sub(#engine.vault_path + 2)
          links[#links + 1] = rel
          path_map[rel] = path
        else
          links[#links + 1] = trimmed .. ".md"
          path_map[trimmed .. ".md"] = engine.vault_path .. "/" .. trimmed .. ".md"
        end
      end
    end
  end

  if #links == 0 then
    vim.notify("Vault: no wikilinks found in current buffer", vim.log.levels.INFO)
    return
  end

  table.sort(links)

  local fzf = require("fzf-lua")
  fzf.fzf_exec(links, {
    prompt = "Forward links> ",
    cwd = engine.vault_path,
    file_icons = true,
    git_icons = false,
    previewer = "builtin",
    actions = {
      ["default"] = fzf.actions.file_edit,
      ["ctrl-s"] = fzf.actions.file_split,
      ["ctrl-v"] = fzf.actions.file_vsplit,
    },
  })
end

function M.setup()
  vim.api.nvim_create_user_command("VaultBacklinks", function()
    M.backlinks()
  end, { desc = "Show notes linking to current note" })

  vim.api.nvim_create_user_command("VaultForwardlinks", function()
    M.forwardlinks()
  end, { desc = "List wikilinks in current note" })

  local group = vim.api.nvim_create_augroup("VaultBacklinks", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      vim.keymap.set("n", "<leader>vfb", function()
        M.backlinks()
      end, { buffer = ev.buf, desc = "Find: backlinks", silent = true })

      vim.keymap.set("n", "<leader>vfl", function()
        M.forwardlinks()
      end, { buffer = ev.buf, desc = "Find: forward links", silent = true })

      vim.keymap.set("n", "<leader>vfh", function()
        M.heading_backlinks()
      end, { buffer = ev.buf, desc = "Find: heading backlinks", silent = true })
    end,
  })
end

return M
