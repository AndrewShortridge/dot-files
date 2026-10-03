-- =============================================================================
-- nvim 0.12 compatibility shim for nvim-treesitter (master) query handlers
-- =============================================================================
-- nvim-treesitter's `master` branch is archived/frozen. Its custom treesitter
-- directive/predicate handlers (lua/nvim-treesitter/query_predicates.lua) index
-- `match[id]` as a single TSNode. They relied on the `all = false` registration
-- option to receive single nodes, but Neovim 0.12 REMOVED that option -- handlers
-- now always get a node LIST (`{node}`). As a result, handlers such as
-- `set-lang-from-info-string!` passed a table `{node}` to `vim.treesitter.get_node_text`,
-- which then called `:range()` on a table and crashed:
--
--   vim/treesitter.lua:196: attempt to call method 'range' (a nil value)
--
-- This surfaced whenever an injection query ran (markdown code blocks, etc.),
-- e.g. Trouble / fzf-lua / colorizer previews triggering a treesitter parse.
--
-- Fix: re-register nvim-treesitter's handlers through a wrapper that normalizes a
-- node-list back to a single node before calling the original handler. We restore
-- the real registration functions afterwards so any OTHER plugin's (possibly
-- new-API) handlers are left untouched.

local M = {}

-- Collapse `match[id]` node-lists ({node, ...}) back to a single TSNode, matching
-- the legacy (all=false) shape the archived handlers expect.
local function normalize(match)
  if type(match) ~= "table" then
    return match
  end
  local out = {}
  for id, v in pairs(match) do
    if type(v) == "table" then
      out[id] = v[#v]
    else
      out[id] = v
    end
  end
  return out
end

function M.apply()
  local ok, query = pcall(require, "vim.treesitter.query")
  if not ok then
    return
  end

  local real_add_predicate = query.add_predicate
  local real_add_directive = query.add_directive

  query.add_predicate = function(name, handler, o)
    return real_add_predicate(name, function(m, ...)
      return handler(normalize(m), ...)
    end, o)
  end
  query.add_directive = function(name, handler, o)
    return real_add_directive(name, function(m, ...)
      return handler(normalize(m), ...)
    end, o)
  end

  -- Force nvim-treesitter to re-run its registration file through the wrappers
  -- above. Its handlers register with `force = true`, so this overrides the
  -- already-registered (broken) ones.
  package.loaded["nvim-treesitter.query_predicates"] = nil
  pcall(require, "nvim-treesitter.query_predicates")

  -- Restore the genuine registration functions for everyone else.
  query.add_predicate = real_add_predicate
  query.add_directive = real_add_directive
end

return M
