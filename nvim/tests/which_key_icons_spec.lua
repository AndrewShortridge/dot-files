-- Spec for which-key group/rule icons (lua/andrew/plugins/which-key.lua).
--
-- Background: LazyVim defines NO which-key icons of its own -- all 67 of its
-- `group =` entries are bare and every glyph comes from which-key's built-in
-- rule table. Porting "LazyVim's icons" therefore means closing the two gaps
-- the built-ins leave: groups whose names match no pattern, and leaf mappings
-- written in this config's own vocabulary (template/task/query/meta/...).
--
-- This drives the REAL plugin spec with a fake which-key injected into
-- package.loaded to capture both `setup(opts)` and `add(specs)`, then feeds the
-- captured rules into the REAL `which-key.icons` module and resolves each group
-- the same way `which-key/view.lua:M.icon` does. No source introspection.
--
-- Discriminating power (each verified by reintroducing the bug):
--   * Test 2 fails if any icon is blank/whitespace -- the exact regression seen
--     when private-use glyphs were lost in transit and left `icon = " "`, which
--     short-circuits rule lookup and renders an empty column.
--   * Test 5 fails if the rule list is reordered (e.g. "link" before "check").
--   * Test 6 fails if <leader>m loses its explicit icon, because the built-in
--     "ui" rule then matches the *substring* in b-ui-ld.
--
-- Run with: nvim --headless -u NONE -l tests/which_key_icons_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local config_dir = vim.fn.stdpath("config")
local spec_path = config_dir .. "/lua/andrew/plugins/which-key.lua"

print("\n=== Which-Key Icon Tests ===\n")

-- ---------------------------------------------------------------------------
-- Capture the real plugin spec's setup() opts and add() entries.
-- ---------------------------------------------------------------------------
local captured = { opts = nil, entries = {} }
package.loaded["which-key"] = {
  setup = function(o) captured.opts = o end,
  add = function(specs)
    for _, s in ipairs(specs) do captured.entries[#captured.entries + 1] = s end
  end,
}

local plugin = dofile(spec_path)
plugin.config()

local rules = captured.opts and captured.opts.icons and captured.opts.icons.rules or {}

-- Collect every icon string the config declares (rules + explicit group icons).
local function icon_strings()
  local out = {}
  for _, r in ipairs(rules) do
    out[#out + 1] = { what = "rule:" .. tostring(r.pattern), s = r.icon }
  end
  for _, e in ipairs(captured.entries) do
    if type(e.icon) == "table" and e.icon.icon then
      out[#out + 1] = { what = "group:" .. tostring(e.group), s = e.icon.icon }
    end
  end
  return out
end

-- Index of a rule pattern within the ordered list (nil when absent).
local function rule_pos(pattern)
  for i, r in ipairs(rules) do
    if r.pattern == pattern then return i end
  end
end

-- ---------------------------------------------------------------------------
-- Real which-key.icons, driven with the captured rules.
-- ---------------------------------------------------------------------------
local wk_lua = vim.fn.expand("~/.local/share/nvim/lazy/which-key.nvim/lua")
package.path = package.path .. ";" .. wk_lua .. "/?.lua;" .. wk_lua .. "/?/init.lua"
local have_wk, Icons = pcall(require, "which-key.icons")
local WkConfig = have_wk and require("which-key.config") or nil
if have_wk then
  WkConfig.icons = WkConfig.icons or {}
  WkConfig.icons.mappings = true
  WkConfig.icons.colors = true
  WkConfig.icons.rules = rules
end

-- Mirrors which-key/view.lua:M.icon for a single node (explicit icon wins).
local function resolve(entry)
  if entry.icon then return Icons.get(entry.icon) end
  return Icons.get({ desc = entry.group })
end

-- Every group must now resolve from literal glyphs alone. Git used to need an
-- icon PROVIDER (mini.icons / nvim-web-devicons), which is not on the rtp under
-- `-u NONE`; it is now covered by an explicit rule, so no exemptions remain.
local provider_backed = {}

-- ---------------------------------------------------------------------------
test("every registered group resolves to an icon", function()
  if not have_wk then
    print("    (skipped: which-key.nvim not installed)")
    return
  end
  local groups, missing = 0, {}
  for _, e in ipairs(captured.entries) do
    if e.group then
      groups = groups + 1
      if not provider_backed[e.group] and not resolve(e) then
        missing[#missing + 1] = e.group
      end
    end
  end
  assert_true(groups >= 30, "expected the full group set, got " .. groups)
  assert_eq(table.concat(missing, ", "), "", "groups with no icon")
end)

test("no icon is blank or whitespace-only", function()
  local bad = {}
  for _, it in ipairs(icon_strings()) do
    if type(it.s) ~= "string" or it.s:gsub("%s", "") == "" then
      bad[#bad + 1] = it.what
    end
  end
  assert_eq(table.concat(bad, ", "), "", "blank icons (glyph lost?)")
end)

test("every glyph is a non-ASCII private-use codepoint", function()
  local bad = {}
  for _, it in ipairs(icon_strings()) do
    local cp = vim.fn.char2nr(vim.fn.trim(it.s))
    local pua = (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0xFFFFD)
    if not pua then
      bad[#bad + 1] = string.format("%s(U+%X)", it.what, cp)
    end
  end
  assert_eq(table.concat(bad, ", "), "", "non nerd-font glyphs")
end)

test("icon rules are well formed", function()
  local valid_color = {
    azure = true, blue = true, cyan = true, green = true, grey = true,
    orange = true, purple = true, red = true, yellow = true,
  }
  assert_true(#rules >= 20, "expected a substantive rule set, got " .. #rules)
  for _, r in ipairs(rules) do
    assert_true(type(r.pattern) == "string" and #r.pattern > 0, "rule missing pattern")
    assert_true(type(r.icon) == "string" and #r.icon > 0, "rule missing icon: " .. tostring(r.pattern))
    assert_true(valid_color[r.color], "bad color on rule " .. tostring(r.pattern) .. ": " .. tostring(r.color))
    -- A rule must be a valid Lua pattern (which-key calls desc:find(pattern)).
    local ok = pcall(string.find, "probe", r.pattern)
    assert_true(ok, "invalid Lua pattern: " .. tostring(r.pattern))
  end
end)

test("rules are ordered specific-before-generic", function()
  -- which-key scans top-down and takes the FIRST match, so these orderings are
  -- load-bearing: "Template: task" must read as a template, "Check: links" as a
  -- check, and the catch-alls must not swallow anything more specific.
  local function before(a, b)
    local pa, pb = rule_pos(a), rule_pos(b)
    assert_true(pa ~= nil, "missing rule: " .. a)
    assert_true(pb ~= nil, "missing rule: " .. b)
    assert_true(pa < pb, string.format("rule %q must precede %q (%d vs %d)", a, b, pa, pb))
  end
  before("template", "task")
  before("check", "link")
  before("footnote", "note")
  before("sidebar", "vault")
  before("graph", "vault")
  before("vault", "note") -- both catch-alls, but vault is the narrower word
  -- Splits vs windows: "Split window right" contains BOTH words, so the
  -- direction-specific split rules must precede the generic "split", which in
  -- turn must precede "window" -- otherwise every split reads as a window.
  before("split window right", "split")
  before("split window vertical", "split")
  before("split window below", "split")
  before("split", "window")
  -- "Zoom (maximize split)" must keep the zoom glyph, so those precede "split".
  before("zoom", "split")
  before("maximi", "split")
  local last = math.max(rule_pos("vault"), rule_pos("note"))
  for _, p in ipairs({ "template", "task", "query", "meta", "check", "graph", "sidebar" }) do
    assert_true(rule_pos(p) < last, "generic catch-all must come after " .. p)
  end
end)

test("<leader>m has an explicit icon (built-in 'ui' rule misfires on 'Build')", function()
  if not have_wk then return end
  local m
  for _, e in ipairs(captured.entries) do
    if e.lhs == "<leader>m" or e[1] == "<leader>m" then m = e end
  end
  assert_true(m ~= nil, "<leader>m not registered")
  assert_true(type(m.icon) == "table" and m.icon.icon ~= nil, "<leader>m must carry an explicit icon")

  -- Prove the misfire is real: with only the description, "Make/Build" resolves
  -- to the built-in "ui" glyph, because "b-ui-ld" contains "ui". Probe that rule
  -- with a bare "ui" -- the group name "UI/Toggle" would match the *toggle* rule
  -- first, since which-key lists "toggle" ahead of "ui".
  local by_desc = Icons.get({ desc = m.group })
  local ui = Icons.get({ desc = "ui" })
  assert_true(ui ~= nil, "expected the built-in ui rule to resolve")
  assert_eq(by_desc, ui, "expected Make/Build to collide with the ui rule by description")

  -- The explicit icon must therefore differ from what the rules would pick.
  local explicit = Icons.get(m.icon)
  assert_true(explicit ~= nil and explicit ~= ui, "explicit icon must override the ui misfire")
end)

test("this config's vocabulary resolves through the rules", function()
  if not have_wk then return end
  local samples = {
    "Template: daily log", "Tasks: all tasks", "Query: render",
    "Check: links (vault)", "Vault: switch vault", "Vault: local graph",
    "Vault: statistics dashboard", "Vault: frontmatter editor",
    "Grep (root dir)", "All keymaps", "Command history",
    "Set conditional breakpoint", "Step into", "Toggle breakpoint",
    "Edit: rename note", "Edit: export (pandoc)", "Vault: sidebar tags",
    "Split window below", "Split window right", "Split window vertically",
    "Go to left window", "Close all other windows", "Find files",
  }
  local missing = {}
  for _, desc in ipairs(samples) do
    if not Icons.get({ desc = desc }) then missing[#missing + 1] = desc end
  end
  assert_eq(table.concat(missing, ", "), "", "descriptions left without an icon")
end)

test("git uses LazyVim's glyph (mini.icons filetype 'git')", function()
  if not have_wk then return end
  -- LazyVim resolves <leader>g through the built-in
  -- `{ pattern = "%f[%a]git", cat = "filetype", name = "git" }` rule via
  -- mini.icons, which yields U+F02A2 / MiniIconsOrange. nvim-web-devicons
  -- returns a DIFFERENT glyph for that filetype (U+E702), so matching LazyVim
  -- requires the literal codepoint rather than a filetype lookup.
  local LAZYVIM_GIT = 0xF02A2
  local DEVICONS_GIT = 0xE702

  local icon, hl = Icons.get({ desc = "Git" })
  assert_true(icon ~= nil, "Git has no icon")
  local cp = vim.fn.char2nr(vim.fn.trim(icon))
  assert_eq(cp, LAZYVIM_GIT, "Git glyph must match LazyVim (mini.icons nf-md-git)")
  assert_true(cp ~= DEVICONS_GIT, "Git must not fall back to the devicons git logo")
  assert_eq(hl, "WhichKeyIconOrange", "LazyVim renders git in MiniIconsOrange")

  -- The rule must apply across the whole git group, not just the group node.
  for _, desc in ipairs({
    "Git Status", "Git Log", "Git Stash", "Git Blame Line",
    "Git Diff (hunks)", "Git Browse (open)", "Git Current File History",
  }) do
    local i = Icons.get({ desc = desc })
    assert_true(i ~= nil, desc .. " has no icon")
    assert_eq(vim.fn.char2nr(vim.fn.trim(i)), LAZYVIM_GIT, desc .. " must use the git glyph")
  end

  -- Frontier pattern, exactly as upstream: "lazygit" is NOT a git match.
  -- (LazyVim does not give it the git icon either.)
  local lazy_icon = Icons.get({ desc = "Lazygit (cwd)" })
  if lazy_icon then
    assert_true(vim.fn.char2nr(vim.fn.trim(lazy_icon)) ~= LAZYVIM_GIT,
      "%f[%a]git must not match 'lazygit'")
  end
end)

test("split / window / search / find-files are visually distinct", function()
  if not have_wk then return end
  -- Before this change all four collapsed onto two built-in glyphs: U+F002
  -- (magnify) served Search AND Find/Files AND Find files, and U+EB7F served
  -- the Windows group AND every split and resize mapping.
  local function group_icon(name)
    for _, e in ipairs(captured.entries) do
      if e.group == name then return (resolve(e)) end
    end
  end
  -- One probe per CATEGORY: these must not collide with each other.
  local probes = {
    ["Search group"] = group_icon("Search"),
    ["Find/Files group"] = group_icon("Find/Files"),
    ["Windows group"] = group_icon("Windows"),
    ["split below"] = Icons.get({ desc = "Split window below" }),
    ["split right"] = Icons.get({ desc = "Split window right" }),
  }
  local seen = {}
  for what, icon in pairs(probes) do
    assert_true(icon ~= nil and icon ~= "", what .. " has no icon")
    assert_true(seen[icon] == nil,
      string.format("%s collides with %s (both %q)", what, tostring(seen[icon]), icon))
    seen[icon] = what
  end

  -- The flagship "Find files" action SHOULD match its group -- same category.
  assert_eq(Icons.get({ desc = "Find files" }), probes["Find/Files group"],
    "Find files should share the Find/Files group glyph")

  -- A horizontal split and a vertical split must not share a glyph.
  assert_true(probes["split below"] ~= probes["split right"],
    "horizontal and vertical splits must differ")
  -- A split must not resolve to the plain window glyph.
  assert_true(probes["split below"] ~= probes["Windows group"],
    "splits must be distinct from windows")
end)

_H.finish()
