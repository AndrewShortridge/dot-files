--- Shared notification helpers for vault modules.
--- Consolidates frequently duplicated vim.notify patterns.
--- Generic helpers (info/warn/error) auto-prefix with "Vault: ".

local M = {}

--- Generic level helpers — auto-prefix with "Vault: "
function M.info(msg) vim.notify("Vault: " .. msg, vim.log.levels.INFO) end
function M.warn(msg) vim.notify("Vault: " .. msg, vim.log.levels.WARN) end
function M.error(msg) vim.notify("Vault: " .. msg, vim.log.levels.ERROR) end

--- Conditional notification — only notifies if opts.silent is not set.
--- When silent, logs the message via the provided log function instead.
---@param opts { silent?: boolean }
---@param msg string message WITHOUT "Vault: " prefix
---@param level? "info"|"warn"|"error" notify level name (default "info")
---@param log_fn? fun(fmt: string, ...: any) optional structured logger (e.g. log.debug)
function M.conditional(opts, msg, level, log_fn)
  if not opts.silent then
    M[level or "info"](msg)
  elseif log_fn then
    log_fn("(silent) [%s] %s", level or "info", msg)
  end
end

--- Multi-line info (for status/debug output built via table.concat)
--- Auto-prefixes the first line with "Vault: " for consistency.
function M.info_lines(lines)
  if #lines == 0 then return end
  local out = { "Vault: " .. lines[1] }
  for i = 2, #lines do out[i] = lines[i] end
  vim.notify(table.concat(out, "\n"), vim.log.levels.INFO)
end

--- Multi-line info with extra opts (e.g. { title = "Vault" })
function M.info_lines_titled(lines, opts) vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, opts) end

--- Toggle ON/OFF notification
function M.toggle(feature, enabled)
  vim.notify("Vault: " .. feature .. " " .. (enabled and "ON" or "OFF"), vim.log.levels.INFO)
end

function M.not_vault_file()
  vim.notify("Vault: not a vault file", vim.log.levels.WARN)
end

function M.index_not_ready(suffix)
  local msg = "index not ready"
  if suffix then msg = msg .. ", " .. suffix end
  vim.notify("Vault: " .. msg, vim.log.levels.WARN)
end

function M.index_not_ready_rebuild()
  vim.notify("Vault: index not ready, run :VaultIndexRebuild first", vim.log.levels.WARN)
end

function M.no_filename()
  vim.notify("Vault: buffer has no filename", vim.log.levels.WARN)
end

function M.no_tags()
  vim.notify("Vault: no tags found", vim.log.levels.INFO)
end

function M.directory_not_found(dirname)
  vim.notify("Vault: " .. dirname .. "/ directory not found", vim.log.levels.WARN)
end

function M.failed_write(path, err)
  vim.notify("Vault: failed to write " .. path .. (err and (": " .. err) or ""), vim.log.levels.ERROR)
end

function M.failed_append(path, err)
  vim.notify("Vault: failed to append to " .. path .. (err and (": " .. err) or ""), vim.log.levels.ERROR)
end

function M.note_created(name)
  vim.notify("Vault: created " .. name .. ".md", vim.log.levels.INFO)
end

function M.links_auto_fixed(count, scope)
  vim.notify("Vault: auto-fixed " .. count .. " link(s)" .. (scope or ""), vim.log.levels.INFO)
end

--- In-place progress notification. Uses a stable ID so plugins that support
--- notification replacement (snacks.nvim, nvim-notify) update in-place.
---@param msg string  Message text (auto-prefixed with "Vault: ")
---@param level number|nil  vim.log.levels.* (defaults to INFO)
---@param id string  Stable notification ID for in-place replacement
function M.progress(msg, level, id)
  vim.notify("Vault: " .. msg, level or vim.log.levels.INFO, {
    title = "Vault Index",
    id = id,
    replace = id,
  })
end

function M.no_search_history()
  vim.notify("Vault: no search history", vim.log.levels.INFO)
end

function M.heading_not_found(heading)
  vim.notify("Vault: heading not found: #" .. heading, vim.log.levels.WARN)
end

function M.block_not_found(block_id)
  vim.notify("Vault: block not found: ^" .. block_id, vim.log.levels.WARN)
end

function M.file_not_found(name)
  vim.notify("Vault: file not found: " .. name, vim.log.levels.WARN)
end

function M.no_backlinks(name, heading)
  local target = heading and (name .. "#" .. heading) or name
  vim.notify("Vault: no backlinks found for " .. target, vim.log.levels.INFO)
end

return M
