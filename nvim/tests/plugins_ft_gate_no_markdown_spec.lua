-- Perf regression spec for ft-gating four plugins off markdown.
--
-- indent-blankline, nvim-lint, Comment.nvim and todo-comments.nvim used to load
-- eagerly on BufReadPre/BufNewFile (or BufReadPost/BufWritePost for nvim-lint),
-- so they all loaded on markdown buffers — wasting ~4.5ms CPU and, for nvim-lint,
-- attaching a no-op try_lint autocmd that fired on every md buffer event. The
-- fix swaps the `event = {...}` gate for `ft = {...}`:
--   * indent-blankline / Comment / todo-comments  -> ft = lsp_filetypes (shared
--     code-filetype list; markdown/text are absent).
--   * nvim-lint -> ft = the filetypes that actually have a linter configured
--     (python/js/ts/.../c/cpp + fortran variants); lua/markdown are absent.
--
-- This drives the REAL plugin spec tables (dofile). No source introspection.
--
-- Discriminating power:
--   * Reverting any spec to event={"BufReadPre","BufNewFile"} (or the nvim-lint
--     event pair) fails the "event gate removed" + "ft gate present" asserts.
--   * Adding "markdown" to any ft list fails the "no markdown" assert.
--   * Removing exclude.filetypes={"markdown"} from ibl fails its defense-in-depth
--     assert (also covered by ibl_exclude_markdown_spec.lua).
--   * Adding "lua" to nvim-lint's ft (it has no lua linter) fails its "no lua".
--
-- Run with: nvim --headless -u NONE -l tests/plugins_ft_gate_no_markdown_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil = _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

local cfg_dir = vim.fn.stdpath("config") .. "/lua/andrew/plugins/"

local function load(name)
  return dofile(cfg_dir .. name)
end

local function to_set(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

local function contains(list, val)
  for _, v in ipairs(list or {}) do if v == val then return true end end
  return false
end

-- Helper: assert a spec is ft-gated (not event-gated) and never loads markdown.
local function assert_ft_gated_no_md(plug, label, required_fts)
  assert_true(type(plug) == "table", label .. ": spec must return a table")
  assert_nil(plug.event, label .. ": event gate must be removed (replaced by ft)")
  assert_true(type(plug.ft) == "table", label .. ": ft gate must exist")
  local fts = to_set(plug.ft)
  assert_nil(fts["markdown"], label .. ": ft must NOT contain markdown")
  assert_nil(fts["text"], label .. ": ft must NOT contain text")
  for _, ft in ipairs(required_fts) do
    assert_true(fts[ft], label .. ": ft must contain " .. ft)
  end
end

-- The shared code-filetype list the three editor plugins gate on.
local lsp_fts = dofile(vim.fn.stdpath("config") .. "/lua/andrew/lsp_filetypes.lua")
assert(type(lsp_fts) == "table" and #lsp_fts > 0, "lsp_filetypes must be a non-empty list")

test("indent-blankline: ft-gated to shared code list, markdown excluded, exclude kept", function()
  local plug = load("indent-blankline.lua")
  assert_eq(plug[1], "lukas-reineke/indent-blankline.nvim", "spec must point at indent-blankline.nvim")
  assert_ft_gated_no_md(plug, "indent-blankline", { "lua", "python", "c" })
  -- ft must BE the shared list (same length + membership as lsp_filetypes).
  assert_eq(#plug.ft, #lsp_fts, "indent-blankline ft length must match lsp_filetypes")
  -- Defense-in-depth: keep the markdown exclude from the prior pass.
  assert_true(type(plug.opts) == "table", "opts must be a table")
  assert_true(type(plug.opts.exclude) == "table", "opts.exclude must exist")
  assert_true(contains(plug.opts.exclude.filetypes, "markdown"),
    "opts.exclude.filetypes must still contain 'markdown' (defense-in-depth)")
end)

test("comment: ft-gated to shared code list, markdown excluded", function()
  local plug = load("comment.lua")
  assert_eq(plug[1], "numToStr/Comment.nvim", "spec must point at Comment.nvim")
  assert_ft_gated_no_md(plug, "comment", { "lua", "python", "c" })
  assert_eq(#plug.ft, #lsp_fts, "comment ft length must match lsp_filetypes")
end)

test("todo-comments: ft-gated to shared code list, markdown excluded", function()
  local plug = load("todo-comments.lua")
  assert_eq(plug[1], "folke/todo-comments.nvim", "spec must point at todo-comments.nvim")
  assert_ft_gated_no_md(plug, "todo-comments", { "lua", "python", "c" })
  assert_eq(#plug.ft, #lsp_fts, "todo-comments ft length must match lsp_filetypes")
end)

test("nvim-lint: ft-gated to filetypes with a real linter; no lua/markdown", function()
  local plug = load("linting.lua")
  assert_eq(plug[1], "mfussenegger/nvim-lint", "spec must point at nvim-lint")
  -- Must include every linter-having filetype (linters_by_ft + fortran variants).
  assert_ft_gated_no_md(plug, "nvim-lint", {
    "python",
    "javascript", "typescript", "javascriptreact", "typescriptreact", "vue",
    "c", "cpp",
    "fortran", "fortran_free", "fortran_fixed",
  })
  local fts = to_set(plug.ft)
  -- lua has no configured linter, so it must NOT pull nvim-lint in.
  assert_nil(fts["lua"], "nvim-lint ft must NOT contain lua (no lua linter)")
end)

_H.finish({ style = "results", exit = "os" })
