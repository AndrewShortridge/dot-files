-- Spec for the nvim-web-devicons icon registrations
-- (lua/andrew/plugins/ui/devicons.lua).
--
-- What this guards
-- ----------------
-- lualine's `filetype` component resolves the statusline icon as
--   devicons.get_icon(vim.fn.expand("%:t"))       -- filename leg
--   devicons.get_icon_by_filetype(vim.bo.filetype) -- filetype leg
--   -- both nil: hardcoded grey U+E612 / DevIconDefault
-- (lualine.nvim/lua/lualine/components/filetype.lua:33-42). The filetype leg
-- needs BOTH set_icon_by_filetype (ft -> key) and set_icon (key -> glyph), so a
-- map pointing at an unregistered key silently falls back to the grey default.
-- Test 2 is what catches that.
--
-- Glyphs must be Plane-15 (U+F0000+). BMP private-use glyphs (U+E000-U+F8FF)
-- get silently stripped when written into a source file, leaving icon = "",
-- and a blank still counts as a HIT -- it renders an empty column rather than
-- falling through to a default. Test 3 makes that unwritable.
--
-- This drives the REAL plugin spec with a fake nvim-web-devicons injected into
-- package.loaded, capturing both payloads. No source introspection.
--
-- Discriminating power (verified by reintroducing each bug):
--   * Test 2 fails if a filetype maps to a key that was never registered.
--   * Test 3 fails on an empty icon or a BMP private-use glyph.
--   * Test 4 fails if a codepoint is absent from the installed font.
--   * Test 5 fails if a filetype this config actually opens loses its mapping.
--
-- Run with: nvim --headless -u NONE -l tests/devicons_font_coverage_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true = _H.test, _H.assert_eq, _H.assert_true

local config_dir = vim.fn.stdpath("config")
local spec_path = config_dir .. "/lua/andrew/plugins/ui/devicons.lua"
local font_path = vim.fn.expand("~/.local/share/fonts/JetBrainsMonoNerdFont-Regular.ttf")

print("\n=== Devicons Icon Registration Tests ===\n")

-- Keys devicons itself ships that this config is allowed to point a filetype at
-- without registering them here.
local DEVICONS_BUILTIN_KEYS = { f90 = true }

local captured = {}
package.loaded["nvim-web-devicons"] = {
  setup = function(o) captured.setup_opts = o end,
  set_icon = function(t) captured.icons = t end,
  set_icon_by_filetype = function(t) captured.filetypes = t end,
}

local plugin = dofile(spec_path)
plugin.config(nil, plugin.opts or {})
local icons = captured.icons or {}
local filetypes = captured.filetypes or {}

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

-- ---------------------------------------------------------------------------
test("the spec registers icons and filetype maps", function()
  assert_true(captured.setup_opts ~= nil, "setup() was not called")
  assert_true(captured.icons ~= nil, "set_icon() was not called")
  assert_true(captured.filetypes ~= nil, "set_icon_by_filetype() was not called")
  assert_true(count(icons) >= 30, "expected a substantive icon set, got " .. count(icons))
  assert_true(count(filetypes) >= 40, "expected a substantive filetype map, got " .. count(filetypes))
end)

test("every filetype maps to a registered icon key", function()
  local dangling = {}
  for _, ft in ipairs(sorted_keys(filetypes)) do
    local key = filetypes[ft]
    assert_true(type(key) == "string" and key ~= "", ft .. " maps to a non-string key")
    -- devicons lower-cases the icon key before lookup, so a capitalised key
    -- would never resolve.
    assert_eq(key, key:lower(), ft .. " maps to a key that is not lower-case:")
    if not icons[key] and not DEVICONS_BUILTIN_KEYS[key] then
      dangling[#dangling + 1] = ft .. " -> " .. key
    end
  end
  assert_eq(table.concat(dangling, ", "), "", "filetypes pointing at unregistered keys")
end)

test("every glyph is a single Plane-15 character", function()
  local bad = {}
  for _, key in ipairs(sorted_keys(icons)) do
    local d = icons[key]
    assert_true(type(d.icon) == "string" and d.icon ~= "", key .. " has no glyph")
    assert_eq(vim.fn.strchars(d.icon), 1, key .. " glyph is not exactly one character:")
    local cp = vim.fn.char2nr(d.icon)
    -- < 0x10000 catches both a stripped glyph collapsing to a space and any
    -- BMP private-use codepoint that would be stripped on the next write.
    if cp < 0x10000 then
      bad[#bad + 1] = string.format("%s(U+%05X)", key, cp)
    end
  end
  assert_eq(table.concat(bad, ", "), "", "glyphs outside Plane-15 will not survive a rewrite")
end)

test("every glyph is present in the installed font", function()
  assert_true(vim.fn.filereadable(font_path) == 1, "font not found at " .. font_path)
  assert_true(vim.fn.executable("python3") == 1, "python3 is required for the cmap check")

  local wanted = {}
  for _, key in ipairs(sorted_keys(icons)) do
    wanted[#wanted + 1] = string.format("%d", vim.fn.char2nr(icons[key].icon))
  end

  local script = table.concat({
    "import sys",
    "from fontTools.ttLib import TTFont",
    "f = TTFont(sys.argv[1], fontNumber=0, lazy=True)",
    "cmap = set()",
    "for t in f['cmap'].tables: cmap |= set(t.cmap.keys())",
    "missing = [c for c in (int(x) for x in sys.argv[2].split(',')) if c not in cmap]",
    "print(','.join('U+%05X' % c for c in sorted(set(missing))))",
  }, "\n")

  local out = vim.fn.system({ "python3", "-c", script, font_path, table.concat(wanted, ",") })
  assert_eq(vim.v.shell_error, 0, "cmap check failed to run: " .. tostring(out))
  assert_eq(vim.trim(out), "", "codepoints absent from JetBrainsMono Nerd Font")
end)

test("the filetypes this config actually opens are mapped", function()
  -- Real file types the user works in, plus the plugin panels this config
  -- installs. Each of these renders as the grey generic page without a map.
  local required = {
    "fortran_free", "fortran_fixed", "gitrebase",
    "snacks_dashboard", "snacks_picker_list", "snacks_picker_input",
    "snacks_terminal", "snacks_notif",
    "fzf", "trouble", "lazy", "mason", "wk", "noice", "yazi",
    "dap-repl", "dapui_scopes", "gitsigns-blame", "opencode_ask",
    "qf", "man", "lspinfo",
    "vault_sidebar", "vault_fm_editor", "vault-collisions", "vault-profiler",
  }
  local absent = {}
  for _, ft in ipairs(required) do
    if not filetypes[ft] then absent[#absent + 1] = ft end
  end
  assert_eq(table.concat(absent, ", "), "", "filetypes with no icon mapping")
end)

test("the extensions this config actually opens are registered", function()
  -- Fortran suffixes devicons does not ship (it has only f90), plus the data
  -- and input-deck extensions from the user's own file history.
  for _, ext in ipairs({ "f95", "f03", "f", "for", "f77", "dat", "nml", "in", "gnu", "gp" }) do
    assert_true(icons[ext] ~= nil, "no icon registered for extension ." .. ext)
  end
end)

test("icon entries carry a colour, cterm colour and name", function()
  for _, key in ipairs(sorted_keys(icons)) do
    local d = icons[key]
    assert_true(type(d.color) == "string" and d.color:match("^#%x%x%x%x%x%x$") ~= nil,
      "bad colour on " .. key .. ": " .. tostring(d.color))
    assert_true(type(d.cterm_color) == "string" and d.cterm_color:match("^%d+$") ~= nil,
      "bad cterm_color on " .. key .. ": " .. tostring(d.cterm_color))
    assert_true(type(d.name) == "string" and #d.name > 0, "missing name on " .. key)
  end
end)

test("file types that already render are left alone", function()
  -- devicons ships working glyphs for these and the installed font renders
  -- them; overriding them would churn icons for no reason.
  for _, key in ipairs({ "lua", "py", "js", "sh", "pdf", "md", "f90", "c", "cpp",
                         "css", "yaml", "yml", "toml", "ipynb" }) do
    assert_true(icons[key] == nil,
      key .. " renders fine already and must not be overridden")
  end
end)

_H.finish()
