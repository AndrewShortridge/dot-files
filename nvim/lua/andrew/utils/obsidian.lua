--- Obsidian-vault awareness for the GENERAL (non-vault-module) pickers.
---
--- The vault module's own pickers get their exclusions from
--- `andrew.vault.engine.vault_search_fzf_opts`. But <leader>ff, <leader>/ and
--- friends are project-wide pickers that just happen to land in the vault when
--- that is where you are working, and they need the same treatment there --
--- without changing anything about how they behave in a code repo.
---
--- Hence the conditional. `.obsidian` could be excluded unconditionally (the
--- folder exists nowhere but an Obsidian vault, so a global exclude is a no-op
--- elsewhere) and in fact is, via the fd `--exclude` in plugins/fzf-lua.lua.
--- "Templates" cannot: it is an ordinary directory name that plenty of code
--- projects use and expect to be able to search.
---
--- Detection is `vim.fs.root(dir, ".obsidian")`, i.e. the presence of Obsidian's
--- own config folder -- the same marker plugins/snacks.lua already uses to find
--- the vault root. This deliberately does NOT consult the vault module's hardcoded
--- vault list, so it works for any vault and, more importantly, requires nothing
--- from the vault engine on a keypress in a non-vault buffer.

local M = {}

--- Vault root containing `dir`, or nil when `dir` is not inside a vault.
---@param dir? string directory to start from (default: current working directory)
---@return string|nil
function M.vault_root(dir)
  dir = dir or vim.uv.cwd()
  if not dir or dir == "" then return nil end
  local ok, root = pcall(vim.fs.root, dir, ".obsidian")
  if not ok then return nil end
  return root
end

--- fzf-lua option fragment applying the vault's search exclusions, but only when
--- the picker will actually run inside a vault.
---
--- Returns a fresh table every call so callers can mutate it freely.
---@param cwd? string directory the picker will run in (default: current working directory)
---@return table opts empty outside a vault
function M.picker_opts(cwd)
  if not M.vault_root(cwd) then return {} end
  local patterns = require("andrew.vault.search_exclude").fzf_patterns()
  if #patterns == 0 then return {} end
  return { file_ignore_patterns = vim.deepcopy(patterns) }
end

--- picker_opts() merged with caller-supplied options. Caller keys win, except
--- `file_ignore_patterns`, which is concatenated (matching fzf-lua's own
--- append-don't-replace semantics for that one option).
---@param extra? table
---@return table
function M.with_picker_opts(extra)
  local opts = M.picker_opts(extra and extra.cwd or nil)
  if not extra then return opts end
  local mine = opts.file_ignore_patterns
  local merged = vim.tbl_extend("force", opts, extra)
  if mine and extra.file_ignore_patterns then
    local both = vim.deepcopy(mine)
    for _, p in ipairs(extra.file_ignore_patterns) do
      both[#both + 1] = p
    end
    merged.file_ignore_patterns = both
  end
  return merged
end

return M
