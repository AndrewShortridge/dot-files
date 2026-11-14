-- Perf regression spec for the markdown ftplugin once-per-buffer guard.
--
-- On the first markdown open, vault/init.lua's Phase-B re-fires FileType for the
-- current buffer (so deferred modules' freshly-registered autocmds run for it).
-- That re-fire re-sources the ENTIRE ftplugin/markdown.lua, re-running ~40
-- keymap registrations and the per-buffer which-key block redundantly. A
-- buffer-local guard (`vim.b.__md_ftplugin_done`) placed AFTER the window-local
-- opt_local block makes the body run exactly once per buffer, while the cheap
-- idempotent window opts (conceallevel/foldmethod/...) still re-apply on
-- :split / window change because they live BEFORE the guard.
--
-- This drives the REAL ftplugin (ftplugin/markdown.lua) via dofile against
-- markdown buffers in a temp vault, with a FAKE which-key injected into
-- package.loaded. The per-buffer wk.add block (markdown.lua, after the guard)
-- is the 'did the body run?' probe — same recorder pattern as
-- which_key_register_once_spec.lua. No source introspection.
--
-- Discriminating power: removing the guard lines makes Test A's per-buffer
-- wk.add count for a single buffer jump from 1 to 2 -> Test A fails.
--
-- Run with: nvim --headless -u NONE -l tests/ftplugin_guard_once_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local config_dir = vim.fn.stdpath("config")
local ftplugin_path = config_dir .. "/ftplugin/markdown.lua"

print("\n=== Ftplugin Guard Once Tests ===\n")

-- ---------------------------------------------------------------------------
-- Fake which-key recorder: counts buffer-local wk.add calls per buffer. The
-- per-buffer block (markdown.lua) sits AFTER the guard, so a buffer-local
-- wk.add call fires iff the ftplugin body ran for that buffer.
-- ---------------------------------------------------------------------------
local recorder = { buffer_adds = {} } -- bufnr -> count of wk.add calls carrying buffer-local entries

local current_probe_buf = nil

local fake_wk = {
  setup = function() end,
  add = function(specs)
    local has_buffer = false
    for _, spec in ipairs(specs) do
      if spec.buffer ~= nil then
        has_buffer = true
        break
      end
    end
    if has_buffer and current_probe_buf then
      recorder.buffer_adds[current_probe_buf] = (recorder.buffer_adds[current_probe_buf] or 0) + 1
    end
  end,
}

package.loaded["which-key"] = fake_wk

-- Pin the leader so <leader>-prefixed keymaps resolve to a known lhs under -u
-- NONE (otherwise <leader> defaults to "\").
vim.g.mapleader = " "

-- The session-once global which-key block is gated by vim.g.__md_wk_registered.
-- Set it true up front so only the per-buffer block is our probe (mirrors the
-- model spec separating global vs buffer counts).
vim.g.__md_wk_registered = true

local vault = vim.fn.tempname()
vim.fn.mkdir(vault, "p")

-- Helper: make `buf` current, mark it markdown, and source the ftplugin as
-- Neovim would on FileType markdown (dofile evaluates with buffer scope = buf,
-- so vim.b.__md_ftplugin_done resolves per-buffer exactly as the runtime path).
local function source_ftplugin(buf)
  current_probe_buf = buf
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  dofile(ftplugin_path)
end

-- ---------------------------------------------------------------------------
-- Test A (discriminating perf): two sources on the SAME buffer run the body
-- (per-buffer wk.add) exactly ONCE; the guard short-circuits the second.
-- ---------------------------------------------------------------------------
local b1 = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(b1, vault .. "/note_1.md")
vim.b[b1].__md_ftplugin_done = nil

test("body runs once per buffer across a redundant re-source", function()
  source_ftplugin(b1)
  assert_true(vim.b[b1].__md_ftplugin_done == true, "guard flag must be set after first source")
  assert_eq(recorder.buffer_adds[b1], 1, "first source must run the per-buffer body once")

  -- Second source on the SAME buffer (models the Phase-B FileType re-fire).
  source_ftplugin(b1)
  assert_eq(recorder.buffer_adds[b1], 1, "second source must be short-circuited by the guard (still 1)")
end)

-- ---------------------------------------------------------------------------
-- Test B (window opts survive re-source): opt_local is BEFORE the guard, so
-- the fold/conceal opts re-apply on the second source even though the body
-- skipped (models :split into the same buffer re-firing FileType).
-- ---------------------------------------------------------------------------
test("window-local opts re-apply on re-source even when body is skipped", function()
  -- b1 already has the guard flag set (body would skip). Stomp the window opts.
  vim.api.nvim_set_current_buf(b1)
  vim.wo.conceallevel = 0
  vim.wo.foldmethod = "manual"

  source_ftplugin(b1) -- body skips (guard), but the opt block above it must re-run

  assert_eq(recorder.buffer_adds[b1], 1, "body still skipped on this third source")
  assert_eq(vim.wo.conceallevel, 2, "conceallevel must be re-applied by the opt block before the guard")
  assert_eq(vim.wo.foldmethod, "expr", "foldmethod must be re-applied by the opt block before the guard")
  -- Window-scoped opts must land on vim.wo (a wrong scope, e.g. vim.bo.foldlevel,
  -- would be a silent no-op and these would not re-apply).
  assert_eq(vim.wo.foldlevel, 99, "foldlevel (win-scope) must be re-applied via vim.wo")
  assert_eq(vim.wo.foldcolumn, "1", "foldcolumn (win-scope, string) must be re-applied via vim.wo")
  assert_eq(vim.wo.foldnestmax, 6, "foldnestmax (win-scope) must be re-applied via vim.wo")
  -- Buffer-scoped opts must land on vim.bo.
  local bo = vim.bo[b1]
  assert_eq(bo.spelllang, "en_us", "spelllang (buf-scope) must be re-applied via vim.bo")
  assert_true(bo.spellfile:match("/spell/en%.utf%-8%.add$") ~= nil,
    "spellfile (buf-scope) must be re-applied via vim.bo to the spell_dir path")
end)

-- ---------------------------------------------------------------------------
-- Test C (fresh buffer runs full body): a different buffer with the guard
-- unset runs the body (its per-buffer wk.add fires) and registers the expected
-- buffer-local keymaps.
-- ---------------------------------------------------------------------------
test("a fresh buffer runs the full body and registers buffer-local keymaps", function()
  local b2 = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(b2, vault .. "/note_2.md")
  vim.b[b2].__md_ftplugin_done = nil

  source_ftplugin(b2)

  assert_true(vim.b[b2].__md_ftplugin_done == true, "fresh buffer must set the guard flag")
  assert_eq(recorder.buffer_adds[b2], 1, "fresh buffer must run the per-buffer body")

  -- Expected buffer-local keymaps exist (set by the body, after the guard).
  local function has_buffer_keymap(mode, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(b2, mode)) do
      if m.lhs == lhs then
        return true
      end
    end
    return false
  end

  -- mapleader is a space (pinned above), so <leader>mb resolves to " mb".
  assert_true(has_buffer_keymap("n", " mb"), "<leader>mb buffer-local keymap must exist")
  -- Heading nav lives on ]# / [#: ]h / [h are owned by vault/highlights.lua
  -- (==highlight== nav), which binds them buffer-locally AFTER this ftplugin.
  assert_true(has_buffer_keymap("n", "]#"), "]# buffer-local keymap must exist")

  pcall(vim.api.nvim_buf_delete, b2, { force = true })
end)

-- Cleanup.
pcall(vim.api.nvim_buf_delete, b1, { force = true })
vim.g.__md_wk_registered = nil
package.loaded["which-key"] = nil
pcall(vim.fn.delete, vault, "rf")

_H.finish({ style = "results", exit = "os" })
