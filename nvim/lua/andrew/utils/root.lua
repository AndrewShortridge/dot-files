-- =============================================================================
-- Project Root Detection
-- =============================================================================
-- Standalone reimplementation of LazyVim's `LazyVim.root()`, used to scope
-- pickers (see <leader>/ in core/keymaps.lua) to the project rather than to
-- whatever directory nvim happened to start in.
--
-- Detectors are tried in order and the first one that yields a path wins:
--   1. "lsp"    - workspace folders / root_dir of attached LSP clients, keeping
--                 only those that actually contain the current buffer
--   2. patterns - nearest ancestor directory holding one of these entries
--   3. "cwd"    - vim.uv.cwd(), the final fallback
--
-- Override the order globally with `vim.g.root_spec`; skip specific LSP client
-- names with `vim.g.root_lsp_ignore`.

local M = {}

-- Detector order. Each entry is "lsp", "cwd", a filename pattern (or list of
-- them) to search for upward, or a function(buf) returning candidate paths.
M.spec = { "lsp", { ".git", "lua" }, "cwd" }

M.detectors = {}

-- Absolute, symlink-resolved path of a buffer, or nil for unnamed/scratch bufs
function M.bufpath(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local real = vim.uv.fs_realpath(name)
  return real and vim.fs.normalize(real) or nil
end

function M.detectors.cwd()
  return { vim.uv.cwd() }
end

-- LSP workspace folders that are ancestors of the buffer
function M.detectors.lsp(buf)
  local bufpath = M.bufpath(buf)
  if not bufpath then
    return {}
  end

  local ignore = vim.g.root_lsp_ignore or {}
  local roots = {}
  for _, client in pairs(vim.lsp.get_clients({ bufnr = buf })) do
    if not vim.tbl_contains(ignore, client.name) then
      -- workspace_folders moved off client.config in newer nvim; accept both
      local folders = client.workspace_folders or (client.config and client.config.workspace_folders)
      for _, ws in pairs(folders or {}) do
        roots[#roots + 1] = vim.uri_to_fname(ws.uri)
      end
      if client.root_dir then
        roots[#roots + 1] = client.root_dir
      end
    end
  end

  -- Keep only roots the buffer actually lives under
  return vim.tbl_filter(function(path)
    path = vim.fs.normalize(path)
    return path ~= "" and bufpath:sub(1, #path) == path
  end, roots)
end

-- Nearest ancestor directory containing one of `patterns`
function M.detectors.pattern(buf, patterns)
  patterns = type(patterns) == "string" and { patterns } or patterns
  local start = M.bufpath(buf) or vim.uv.cwd()

  local match = vim.fs.find(function(name)
    for _, pattern in ipairs(patterns) do
      if name == pattern then
        return true
      end
      -- "*.sln"-style suffix globs
      if pattern:sub(1, 1) == "*" and name:find(vim.pesc(pattern:sub(2)) .. "$") then
        return true
      end
    end
    return false
  end, { path = start, upward = true })[1]

  return match and { vim.fs.dirname(match) } or {}
end

-- Turn a spec entry into a detector function
function M.resolve(spec)
  if type(spec) == "function" then
    return spec
  end
  if type(spec) == "string" and M.detectors[spec] then
    return M.detectors[spec]
  end
  return function(buf)
    return M.detectors.pattern(buf, spec)
  end
end

-- Run detectors in order; first non-empty result wins, longest path preferred
function M.detect(buf)
  local spec = type(vim.g.root_spec) == "table" and vim.g.root_spec or M.spec

  for _, entry in ipairs(spec) do
    local ok, paths = pcall(M.resolve(entry), buf)
    if ok and paths then
      local seen, found = {}, {}
      for _, path in ipairs(paths) do
        local real = vim.uv.fs_realpath(path)
        path = real and vim.fs.normalize(real) or nil
        if path and not seen[path] then
          seen[path] = true
          found[#found + 1] = path
        end
      end
      -- Deepest root is the most specific one
      table.sort(found, function(a, b)
        return #a > #b
      end)
      if found[1] then
        return found[1]
      end
    end
  end

  return vim.uv.cwd()
end

-- Per-buffer memo; cleared by the autocmds below
M.cache = {}

function M.get(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local cached = M.cache[buf]
  if cached then
    return cached
  end
  local root = M.detect(buf)
  M.cache[buf] = root
  return root
end

-- Root can change when an LSP attaches, the file moves, or :cd runs
vim.api.nvim_create_autocmd({ "LspAttach", "BufWritePost", "DirChanged", "BufDelete" }, {
  group = vim.api.nvim_create_augroup("andrew_root_cache", { clear = true }),
  callback = function(event)
    M.cache[event.buf] = nil
    if event.event == "DirChanged" then
      M.cache = {}
    end
  end,
})

-- Allow `require("andrew.utils.root")()` as shorthand for `.get()`
return setmetatable(M, {
  __call = function(_, buf)
    return M.get(buf)
  end,
})
