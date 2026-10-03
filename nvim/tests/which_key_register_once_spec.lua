-- Perf regression spec for the markdown ftplugin which-key registration.
--
-- The ftplugin used to run ONE wk.add({ ...~70 specs... }) with `buffer = 0`
-- on EVERY load of the markdown ftplugin (every FileType markdown / :e /
-- split), re-building which-key's per-buffer trie each time. The static,
-- decorative entries (icons/labels for keys that exist only in markdown
-- buffers and have no global which-key label) are now registered ONCE per
-- session, guarded by vim.g.__md_wk_registered. Only the few keys that collide
-- with the global "Make/Build" labels (<leader>m, mb, mc, ml and visual
-- m/mb/mc) still register per buffer so they relabel the popup locally without
-- leaking the markdown icon onto Make elsewhere.
--
-- This drives the REAL ftplugin (ftplugin/markdown.lua) against markdown
-- buffers in a temp vault, with a FAKE which-key injected into package.loaded
-- so we can count and classify every wk.add call. No source introspection.
--
-- Discriminating power: reintroducing the bug (dropping the guard / moving the
-- static entries back under buffer=0) makes the global-entry count jump from a
-- single one-time registration to N, failing Test 1.
--
-- Run with: nvim --headless -u NONE -l tests/which_key_register_once_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local config_dir = vim.fn.stdpath("config")
local ftplugin_path = config_dir .. "/ftplugin/markdown.lua"

print("\n=== Which-Key Register-Once Tests ===\n")

-- ---------------------------------------------------------------------------
-- Fake which-key recorder: installed BEFORE the ftplugin loads.
-- Records, per wk.add call, how many global (buffer==nil) vs buffer-local
-- (buffer~=nil) entries it received, plus the union of all entries seen.
-- ---------------------------------------------------------------------------
local recorder = {
  calls = {},          -- per-call: { global = N, buffer = M, specs = {...} }
  all_entries = {},    -- union of every spec table ever registered
}

local fake_wk = {
  setup = function() end,
  add = function(specs)
    local g, b = 0, 0
    for _, spec in ipairs(specs) do
      if spec.buffer ~= nil then
        b = b + 1
      else
        g = g + 1
      end
      recorder.all_entries[#recorder.all_entries + 1] = spec
    end
    recorder.calls[#recorder.calls + 1] = { global = g, buffer = b, specs = specs }
  end,
}

-- Inject the fake so the ftplugin's `require("which-key")` resolves to it.
package.loaded["which-key"] = fake_wk

-- Build a temp vault and run the REAL ftplugin against N markdown buffers.
local vault = vim.fn.tempname()
vim.fn.mkdir(vault, "p")
local N = 8
local bufs = {}

vim.g.__md_wk_registered = nil

for i = 1, N do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vault .. "/note_" .. i .. ".md")
  bufs[i] = buf
  -- Make the buffer current and run the ftplugin body as Neovim would on
  -- FileType markdown. dofile evaluates ftplugin/markdown.lua with buffer
  -- scope = this buffer (buffer=0 resolves to it).
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  dofile(ftplugin_path)
end

-- ---------------------------------------------------------------------------
-- Test 1 (discriminating perf): global/static block registers exactly once.
-- ---------------------------------------------------------------------------
test("static (global) entries register exactly once across N opens", function()
  local global_calls_with_entries = 0
  for _, c in ipairs(recorder.calls) do
    if c.global > 0 then
      global_calls_with_entries = global_calls_with_entries + 1
    end
  end
  -- The discriminating assertion: exactly ONE wk.add call carried global
  -- (buffer-less) entries, even though the ftplugin ran N times.
  assert_eq(global_calls_with_entries, 1, "global block must register once, not per-buffer")
  assert_true(vim.g.__md_wk_registered == true, "guard flag must be set after global registration")
end)

test("per-buffer (buffer-local) block registers on every open, small + constant", function()
  local buffer_calls_with_entries = 0
  local per_open_count = nil
  for _, c in ipairs(recorder.calls) do
    if c.buffer > 0 then
      buffer_calls_with_entries = buffer_calls_with_entries + 1
      if per_open_count == nil then
        per_open_count = c.buffer
      else
        -- Every per-buffer block must be identical in size.
        assert_eq(c.buffer, per_open_count, "per-buffer block size must be constant")
      end
    end
  end
  assert_eq(buffer_calls_with_entries, N, "buffer-local block must register once per open")
  -- The per-buffer block is the small collision-only set (~7), far below ~70.
  assert_true(per_open_count and per_open_count < 20, "per-buffer block must be the small collision set, not the full ~70")
end)

-- ---------------------------------------------------------------------------
-- Test 2 (behavior-identical): union of all registered entries matches the
-- full original spec set, and no colliding key leaks into the global block.
-- ---------------------------------------------------------------------------

-- The full original spec set (key/mode/icon/color/desc/group tuples), verbatim
-- from the pre-split ftplugin. The union of (global block + ONE buffer block)
-- must equal this exactly.
local EXPECTED = {
  { "<leader>m", group = "Markdown", icon = "", color = "blue" },
  { "<leader>mb", icon = "󰉿", color = "yellow" },
  { "<leader>mi", icon = "󰉿", color = "yellow" },
  { "<leader>ms", icon = "󰉿", color = "yellow" },
  { "<leader>mc", icon = "", color = "yellow" },
  { "<leader>m1", icon = "󰉫", color = "purple" },
  { "<leader>m2", icon = "󰉬", color = "purple" },
  { "<leader>m3", icon = "󰉭", color = "purple" },
  { "<leader>m4", icon = "󰉮", color = "purple" },
  { "<leader>m5", icon = "󰉯", color = "purple" },
  { "<leader>m6", icon = "󰉰", color = "purple" },
  { "<leader>mf", icon = "", color = "cyan" },
  { "<leader>mu", icon = "", color = "cyan" },
  { "<leader>ml", icon = "", color = "cyan" },
  { "<leader>mq", icon = "", color = "green" },
  { "<leader>mQ", icon = "", color = "green" },
  { "<leader>mC", icon = "", color = "green" },
  { "<leader>mz", icon = "", color = "green" },
  { "<leader>mZ", icon = "", color = "green" },
  { "<leader>mP", icon = "", color = "orange" },
  { "<leader>mx", icon = "", color = "red" },
  { "<leader>mp", icon = "", color = "azure" },
  { "<leader>mj", icon = "", color = "orange" },
  { "<leader>mn", icon = "", color = "orange" },
  { "<leader>mS", icon = "󰓆", color = "grey" },
  { "<leader>m", mode = "v", group = "Markdown", icon = "", color = "blue" },
  { "<leader>mb", mode = "v", icon = "󰉿", color = "yellow" },
  { "<leader>mi", mode = "v", icon = "󰉿", color = "yellow" },
  { "<leader>ms", mode = "v", icon = "󰉿", color = "yellow" },
  { "<leader>mc", mode = "v", icon = "", color = "yellow" },
  { "<leader>mq", mode = "v", icon = "", color = "green" },
  { "<leader>mQ", mode = "v", icon = "", color = "green" },
  { "<leader>mC", mode = "v", icon = "", color = "green" },
  { "<leader>mk", mode = "v", icon = "", color = "orange" },
  { "<leader>mK", mode = "v", icon = "", color = "orange" },
  { "<leader>mP", mode = "x", icon = "", color = "orange" },
  { "<leader>T", group = "Table" },
  { "<leader>Tc", desc = "Create table (interactive)" },
  { "<leader>Ti", group = "Insert" },
  { "<leader>Td", group = "Delete" },
  { "<leader>Tir", desc = "Insert row below" },
  { "<leader>Tdt", desc = "Delete entire table" },
  { "<CR>", mode = "i", desc = "Smart list continue" },
  { "]s", desc = "Next misspelling" },
  { "[s", desc = "Prev misspelling" },
  { "z=", desc = "Spell suggestions" },
  { "zg", desc = "Add word to spellfile" },
  { "zw", desc = "Mark word as bad" },
  { "zug", desc = "Undo add to spellfile" },
  -- Heading nav is on ]# / [#; ]h / [h belong to vault/highlights.lua.
  { "]#", desc = "Next heading" },
  { "[#", desc = "Previous heading" },
}

-- Canonical key for a recorded wk.add spec: lhs + mode + icon + color + desc + group.
local function entry_key(spec)
  local lhs = spec[1]
  local mode = spec.mode or "n"
  local icon = type(spec.icon) == "table" and spec.icon.icon or ""
  local color = type(spec.icon) == "table" and spec.icon.color or ""
  return table.concat({ lhs, mode, icon, color, spec.desc or "", spec.group or "" }, "|")
end

-- Canonical key for an EXPECTED tuple (flat icon/color fields).
local function expected_key(e)
  return table.concat({ e[1], e.mode or "n", e.icon or "", e.color or "", e.desc or "", e.group or "" }, "|")
end

-- Build the union from ONE buffer-block plus the single global block. Since
-- the buffer block is identical on every open, taking the dedup set of all
-- recorded entries equals (global block ∪ one buffer block).
local function build_seen()
  local seen = {}
  for _, spec in ipairs(recorder.all_entries) do
    seen[entry_key(spec)] = true
  end
  return seen
end

test("union of all registered entries equals the full original spec set", function()
  local seen = build_seen()
  -- Every expected entry must be present (none dropped/altered by the split).
  for _, e in ipairs(EXPECTED) do
    local key = expected_key(e)
    assert_true(seen[key], "missing/altered entry: " .. key)
  end
  -- And no extra entries beyond the expected set (split introduced nothing).
  local expected_set = {}
  for _, e in ipairs(EXPECTED) do
    expected_set[expected_key(e)] = true
  end
  for key in pairs(seen) do
    assert_true(expected_set[key], "unexpected entry registered: " .. key)
  end
end)

test("colliding keys never appear in the session-global block", function()
  -- Keys that shadow the global Make labels must stay buffer-local.
  local colliding = {
    ["<leader>m|n"] = true,
    ["<leader>mb|n"] = true,
    ["<leader>mc|n"] = true,
    ["<leader>ml|n"] = true,
    -- mj/mn have GLOBAL footnote keymaps (vault/init.lua), so a buffer-less
    -- icon registration leaks the markdown glyph into every buffer's popup.
    ["<leader>mj|n"] = true,
    ["<leader>mn|n"] = true,
    -- mf/mu have buffer-local fold keymaps in ftplugin/tex.lua, so a
    -- buffer-less markdown icon leaks the cyan fold glyph into the tex popup.
    ["<leader>mf|n"] = true,
    ["<leader>mu|n"] = true,
    ["<leader>m|v"] = true,
    ["<leader>mb|v"] = true,
    ["<leader>mc|v"] = true,
  }
  for _, c in ipairs(recorder.calls) do
    if c.global > 0 then
      -- This is the global block: assert none of its entries collide.
      for _, spec in ipairs(c.specs) do
        if spec.buffer == nil then
          local lhs = spec[1]
          local mode = spec.mode or "n"
          assert_true(not colliding[lhs .. "|" .. mode], "colliding key leaked into global block: " .. lhs .. "|" .. mode)
        end
      end
    end
  end
end)

-- ---------------------------------------------------------------------------
-- Test 3 (cross-filetype behavior, strongest discriminator): the markdown fold
-- icons (mf/mu) must NOT be registered buffer-less. A buffer-less wk.add spec
-- is merged into EVERY buffer's which-key tree (which-key/buf.lua Mode:has:
-- `not mapping.buffer` matches any buffer), and view.lua prioritizes
-- node.mapping.icon. ftplugin/tex.lua maps <leader>mf/<leader>mu buffer-locally
-- ("Fold all"/"Unfold all"), so a buffer-less markdown cyan fold icon on those
-- keys would render in a tex buffer's popup — a cross-filetype behavior leak.
-- Therefore the mf/mu icon specs must carry a buffer field (buffer = 0).
--
-- Discriminating power: moving the mf/mu specs back into the buffer-less
-- `if not vim.g.__md_wk_registered` block (dropping buffer=0) makes this test
-- AND the augmented "colliding keys" test fail; Test 1's count still passes.
-- ---------------------------------------------------------------------------
test("markdown fold icons (mf/mu) must NOT leak buffer-less (would decorate tex popup)", function()
  local leaked = {}
  for _, spec in ipairs(recorder.all_entries) do
    local lhs, mode = spec[1], (spec.mode or "n")
    if (lhs == "<leader>mf" or lhs == "<leader>mu") and mode == "n" and spec.buffer == nil then
      leaked[#leaked + 1] = lhs
    end
  end
  assert_eq(#leaked, 0, "markdown fold icon leaked buffer-less: " .. table.concat(leaked, ","))
end)

-- Cleanup.
for _, buf in ipairs(bufs) do
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end
vim.g.__md_wk_registered = nil
package.loaded["which-key"] = nil
pcall(vim.fn.delete, vault, "rf")

_H.finish({ style = "results", exit = "os" })
