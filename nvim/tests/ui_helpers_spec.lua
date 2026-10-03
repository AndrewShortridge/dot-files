-- Unit tests for vault UI helper modules:
--   frontmatter_editor/type_utils, search_group, command_palette,
--   preview/target, preview/breadcrumb, viewport, breadcrumbs, sidebar_meta
-- Run with: nvim --headless -u NONE -l tests/ui_helpers_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

-- spec-local assert_deep_eq uses vim.deep_equal (NOT the canonical deep_equal)
local function assert_deep_eq(got, expected, msg)
  if not vim.deep_equal(got, expected) then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

-- ============================================================================
-- Load modules under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local tu = require("andrew.vault.frontmatter_editor.type_utils")
local sg = require("andrew.vault.search_group")
local palette = require("andrew.vault.command_palette")
local target_mod = require("andrew.vault.preview.target")
local bc = require("andrew.vault.preview.breadcrumb")
local viewport = require("andrew.vault.viewport")
local breadcrumbs = require("andrew.vault.breadcrumbs")
local sidebar_meta = require("andrew.vault.sidebar_meta")
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")

print("\n=== UI Helpers Tests ===\n")

-- ============================================================================
-- 1. type_utils.detect_field_type
-- ============================================================================

test("detect_field_type: cycle field detected by key (status)", function()
  assert_eq(tu.detect_field_type("status", "anything"), "cycle")
end)

test("detect_field_type: cycle for type key regardless of value", function()
  assert_eq(tu.detect_field_type("type", "meeting"), "cycle")
  assert_eq(tu.detect_field_type("priority", 3), "cycle")
  assert_eq(tu.detect_field_type("maturity", "Seed"), "cycle")
end)

test("detect_field_type: boolean", function()
  assert_eq(tu.detect_field_type("done", true), "boolean")
  assert_eq(tu.detect_field_type("done", false), "boolean")
end)

test("detect_field_type: number", function()
  assert_eq(tu.detect_field_type("count", 5), "number")
end)

test("detect_field_type: list (table)", function()
  assert_eq(tu.detect_field_type("tags", { "a", "b" }), "list")
end)

test("detect_field_type: ISO date string", function()
  assert_eq(tu.detect_field_type("created", "2026-01-15"), "date")
end)

test("detect_field_type: datetime still date (anchored prefix)", function()
  assert_eq(tu.detect_field_type("created", "2026-01-15T10:00"), "date")
end)

test("detect_field_type: non-padded date is plain string", function()
  assert_eq(tu.detect_field_type("v", "2026-1-5"), "string")
end)

test("detect_field_type: plain string", function()
  assert_eq(tu.detect_field_type("title", "Hello"), "string")
end)

-- ============================================================================
-- 2. type_utils.format_display_value
-- ============================================================================

test("format_display_value: list joins with comma-space", function()
  assert_eq(tu.format_display_value({ "a", "b", "c" }, "list"), "a, b, c")
end)

test("format_display_value: list of numbers stringified", function()
  assert_eq(tu.format_display_value({ 1, 2, 3 }, "list"), "1, 2, 3")
end)

test("format_display_value: boolean true/false", function()
  assert_eq(tu.format_display_value(true, "boolean"), "true")
  assert_eq(tu.format_display_value(false, "boolean"), "false")
end)

test("format_display_value: number via tostring", function()
  assert_eq(tu.format_display_value(42, "number"), "42")
end)

-- ============================================================================
-- 3. type_utils.max_key_width
-- ============================================================================

test("max_key_width: over plain strings", function()
  assert_eq(tu.max_key_width({ "a", "bbb", "cc" }), 3)
end)

test("max_key_width: over {key=...} objects", function()
  assert_eq(tu.max_key_width({ { key = "x" }, { key = "yyyy" } }), 4)
end)

test("max_key_width: empty list is 0", function()
  assert_eq(tu.max_key_width({}), 0)
end)

-- ============================================================================
-- 4. type_utils.format_yaml_value
-- ============================================================================

test("format_yaml_value: bool and number pass through", function()
  assert_eq(tu.format_yaml_value(true), "true")
  assert_eq(tu.format_yaml_value(false), "false")
  assert_eq(tu.format_yaml_value(42), "42")
end)

test("format_yaml_value: plain string unquoted", function()
  assert_eq(tu.format_yaml_value("hello"), "hello")
end)

test("format_yaml_value: colon triggers quoting", function()
  assert_eq(tu.format_yaml_value("a: b"), '"a: b"')
end)

test("format_yaml_value: escapes internal quotes", function()
  assert_eq(tu.format_yaml_value('say "hi"'), '"say \\"hi\\""')
end)

test("format_yaml_value: hash and bracket quoted", function()
  assert_eq(tu.format_yaml_value("#tag"), '"#tag"')
  assert_eq(tu.format_yaml_value("[x]"), '"[x]"')
end)

-- ============================================================================
-- 5. search_group.resolve_group_key
-- ============================================================================

-- Fixed timestamp: 2025-03-15 12:00 local time (midday avoids TZ day-shift)
local FIXED_TS = os.time({ year = 2025, month = 3, day = 15, hour = 12, min = 0, sec = 0 })

local idx = {
  files = {
    ["Projects/A/Note1.md"] = {
      folder = "Projects/A",
      frontmatter = { type = "Finding", status = "In Progress", author = "Bob" },
      tags = { "work/urgent", "home" },
      mtime = FIXED_TS,
    },
    ["Projects/A/Note2.md"] = {
      folder = "Projects/A",
      frontmatter = { type = "finding" },
      tags = {},
      mtime = FIXED_TS,
    },
    ["Root.md"] = {
      folder = "",
      frontmatter = {},
      tags = {},
      created_ts = FIXED_TS,
    },
  },
}

test("resolve_group_key: folder key for nested path", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "folder", idx)
  assert_eq(key, "Projects/A")
  assert_eq(label, "Projects/A")
end)

test("resolve_group_key: folder root becomes (root)", function()
  local key, label = sg.resolve_group_key("Root.md", "folder", idx)
  assert_eq(key, "(root)")
  assert_eq(label, "(root)")
end)

test("resolve_group_key: folder falls back to dirname when not indexed", function()
  local key, label = sg.resolve_group_key("Sub/Unknown.md", "folder", idx)
  assert_eq(key, "Sub")
  assert_eq(label, "Sub")
end)

test("resolve_group_key: type lowercased key, original-case label", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "type", idx)
  assert_eq(key, "finding")
  assert_eq(label, "Finding")
end)

test("resolve_group_key: missing type sentinel", function()
  local key, label = sg.resolve_group_key("Root.md", "type", idx)
  assert_eq(key, "\xff(no type)")
  assert_eq(label, "(no type)")
end)

test("resolve_group_key: tag uses top-level of first tag", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "tag", idx)
  assert_eq(key, "work")
  assert_eq(label, "work")
end)

test("resolve_group_key: tag with spec.field prefix match", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "tag", idx, { field = "work/" })
  assert_eq(key, "work/urgent")
  assert_eq(label, "work/urgent")
end)

test("resolve_group_key: tag spec.field with no matching tag -> sentinel", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "tag", idx, { field = "zzz/" })
  assert_eq(key, "\xff(no zzz/ tag)")
  assert_eq(label, "(no zzz/ tag)")
end)

test("resolve_group_key: tag_level=full uses full first tag", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "tag", idx, { tag_level = "full" })
  assert_eq(key, "work/urgent")
  assert_eq(label, "work/urgent")
end)

test("resolve_group_key: untagged sentinel", function()
  local key, label = sg.resolve_group_key("Projects/A/Note2.md", "tag", idx)
  assert_eq(key, "\xff(untagged)")
  assert_eq(label, "(untagged)")
end)

test("resolve_group_key: date mode formats fixed mtime", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "date", idx)
  assert_eq(key, "2025-03-15")
  assert_eq(label, "2025-03-15")
end)

test("resolve_group_key: date mode with no mtime -> sentinel", function()
  local key, label = sg.resolve_group_key("Root.md", "date", idx)
  assert_eq(key, "\xff(unknown date)")
  assert_eq(label, "(unknown date)")
end)

test("resolve_group_key: month mode key YYYY-MM, label month name", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "month", idx)
  assert_eq(key, "2025-03")
  -- Label is os.date("%B %Y") which is locale-dependent; assert against
  -- the same fixed timestamp's rendering.
  assert_eq(label, os.date("%B %Y", FIXED_TS))
end)

test("resolve_group_key: created mode uses created_ts", function()
  local key = sg.resolve_group_key("Root.md", "created", idx)
  assert_eq(key, "2025-03-15")
end)

test("resolve_group_key: status lowercased key, original label", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "status", idx)
  assert_eq(key, "in progress")
  assert_eq(label, "In Progress")
end)

test("resolve_group_key: missing status sentinel", function()
  local key, label = sg.resolve_group_key("Root.md", "status", idx)
  assert_eq(key, "\xff(no status)")
  assert_eq(label, "(no status)")
end)

test("resolve_group_key: generic frontmatter field mode", function()
  local key, label = sg.resolve_group_key("Projects/A/Note1.md", "author", idx)
  assert_eq(key, "bob")
  assert_eq(label, "Bob")
end)

test("resolve_group_key: unknown mode/field -> (unknown) sentinel", function()
  local key, label = sg.resolve_group_key("Root.md", "author", idx)
  assert_eq(key, "\xff(unknown)")
  assert_eq(label, "(unknown)")
end)

-- ============================================================================
-- 6. search_group.group_entries / is_header / filter_selected
-- ============================================================================

test("group_entries: mode none is passthrough", function()
  local entries = { "Root.md", "Projects/A/Note1.md" }
  local res = sg.group_entries(entries, "none", idx)
  assert_eq(res.group_count, 0)
  assert_eq(res.total_count, 2)
  assert_deep_eq(res.entries, entries)
end)

test("group_entries: folder grouping interleaves headers, alphabetical order", function()
  local entries = { "Projects/A/Note1.md", "Root.md", "Projects/A/Note2.md" }
  local res = sg.group_entries(entries, "folder", idx)
  assert_eq(res.group_count, 2)
  assert_eq(res.total_count, 3)
  assert_eq(#res.entries, 5, "2 headers + 3 entries")
  -- "(root)" sorts before "Projects/A"
  assert_true(sg.is_header(res.entries[1]), "first line is a header")
  assert_true(res.entries[1]:find("(root)", 1, true) ~= nil, "first header labelled (root)")
  assert_eq(res.entries[2], "Root.md")
  assert_true(sg.is_header(res.entries[3]), "second group header")
  assert_true(res.entries[3]:find("Projects/A", 1, true) ~= nil, "second header labelled Projects/A")
  assert_eq(res.entries[4], "Projects/A/Note1.md")
  assert_eq(res.entries[5], "Projects/A/Note2.md")
end)

test("group_entries: header includes entry count", function()
  local entries = { "Projects/A/Note1.md", "Projects/A/Note2.md" }
  local res = sg.group_entries(entries, "folder", idx)
  assert_eq(res.group_count, 1)
  assert_true(res.entries[1]:find("(2)", 1, true) ~= nil, "header shows count (2)")
end)

test("group_entries: lowercased keys merge Finding/finding", function()
  local entries = { "Projects/A/Note1.md", "Projects/A/Note2.md" }
  local res = sg.group_entries(entries, "type", idx)
  assert_eq(res.group_count, 1, "case-insensitive type keys should merge")
  assert_true(res.entries[1]:find("Finding", 1, true) ~= nil, "label keeps first-seen case")
end)

test("group_entries: sentinel groups sort last", function()
  local entries = { "Root.md", "Projects/A/Note1.md" }
  local res = sg.group_entries(entries, "type", idx)
  assert_eq(res.group_count, 2)
  assert_true(res.entries[1]:find("Finding", 1, true) ~= nil, "real type group first")
  assert_true(res.entries[3]:find("(no type)", 1, true) ~= nil, "(no type) group last")
end)

test("group_entries: extracts rel path from ripgrep-style lines", function()
  local entries = { "Projects/A/Note1.md:3:1:some matched text" }
  local res = sg.group_entries(entries, "folder", idx)
  assert_eq(res.group_count, 1)
  assert_true(res.entries[1]:find("Projects/A", 1, true) ~= nil, "grouped by extracted file's folder")
  assert_eq(res.entries[2], "Projects/A/Note1.md:3:1:some matched text")
end)

test("is_header: true only for HEADER_PREFIX lines", function()
  assert_eq(sg.is_header(sg.HEADER_PREFIX .. "Group (1)"), true)
  assert_eq(sg.is_header("Projects/A/Note1.md"), false)
  assert_eq(sg.is_header(""), false)
end)

test("filter_selected: nil -> empty list", function()
  assert_deep_eq(sg.filter_selected(nil), {})
end)

test("filter_selected: drops headers, keeps file lines", function()
  local sel = { sg.HEADER_PREFIX .. "hdr", "a.md", sg.HEADER_PREFIX .. "hdr2", "b.md" }
  assert_deep_eq(sg.filter_selected(sel), { "a.md", "b.md" })
end)

-- ============================================================================
-- 7. command_palette._infer_category
-- ============================================================================

test("_infer_category: command names dispatch to expected categories", function()
  assert_eq(palette._infer_category("VaultSearch"), "Search")
  assert_eq(palette._infer_category("VaultTaskList"), "Tasks")
  assert_eq(palette._infer_category("VaultGraph"), "Graph")
  assert_eq(palette._infer_category("VaultBacklinks"), "Links")
  assert_eq(palette._infer_category("VaultNewNote"), "Templates")
  assert_eq(palette._infer_category("VaultExport"), "Export")
  assert_eq(palette._infer_category("VaultSidebar"), "Sidebar")
  assert_eq(palette._infer_category("VaultRename"), "Edit")
  assert_eq(palette._infer_category("VaultIndexRebuild"), "Index")
  assert_eq(palette._infer_category("VaultStats"), "Debug")
end)

test("_infer_category: order-dependent dispatch", function()
  -- Daily is caught by the Navigate branch before the Templates branch
  assert_eq(palette._infer_category("VaultDaily"), "Navigate")
  -- Embed branch runs before Debug branch
  assert_eq(palette._infer_category("VaultEmbedDebug"), "Embed")
  -- Tag branch explicitly excludes Sticky; falls through to Meta
  assert_eq(palette._infer_category("VaultStickyTag"), "Meta")
end)

test("_infer_category: keymap-based inference", function()
  assert_eq(palette._infer_category("<leader>vfs"), "Search")
  assert_eq(palette._infer_category("<leader>vx"), "Tasks")
  assert_eq(palette._infer_category("<leader>vd"), "Navigate")
  assert_eq(palette._infer_category("<leader>vS"), "Sidebar")
end)

test("_infer_category: unknown name falls back to Meta", function()
  assert_eq(palette._infer_category("FooBarBaz"), "Meta")
end)

-- ============================================================================
-- 8. command_palette.register / register_command / register_keymap
-- ============================================================================

test("register_command appends a full entry to the registry", function()
  local before = #palette._registry
  local fn = function() end
  palette.register_command("TestCmdXYZ", "test desc", "Search", fn, "<leader>zz")
  assert_eq(#palette._registry, before + 1)
  local e = palette._registry[#palette._registry]
  assert_eq(e.name, "TestCmdXYZ")
  assert_eq(e.command, "TestCmdXYZ")
  assert_eq(e.desc, "test desc")
  assert_eq(e.category, "Search")
  assert_eq(e.keymap, "<leader>zz")
  assert_eq(e.buffer_local, false)
  assert_eq(e.action, fn)
  table.remove(palette._registry) -- restore shared state
  assert_eq(#palette._registry, before)
end)

test("register_keymap appends keymap-only entry (name=desc, no command)", function()
  local before = #palette._registry
  local fn = function() end
  palette.register_keymap("<leader>q1", "My Desc", "Tasks", fn, true)
  assert_eq(#palette._registry, before + 1)
  local e = palette._registry[#palette._registry]
  assert_eq(e.name, "My Desc")
  assert_nil(e.command)
  assert_eq(e.keymap, "<leader>q1")
  assert_eq(e.category, "Tasks")
  assert_eq(e.buffer_local, true)
  table.remove(palette._registry) -- restore shared state
  assert_eq(#palette._registry, before)
end)

test("register_keymap defaults buffer_local to false", function()
  palette.register_keymap("<leader>q2", "Other", "Meta", function() end)
  local e = palette._registry[#palette._registry]
  assert_eq(e.buffer_local, false)
  table.remove(palette._registry)
end)

-- ============================================================================
-- 9. preview.target.resolve
-- ============================================================================

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

test("target.resolve: empty name with no fragment -> nil", function()
  local buf = make_buf({ "# Title", "body" })
  assert_nil(target_mod.resolve({ name = "" }, buf))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("target.resolve: same-file heading resolves from parent buffer", function()
  local buf = make_buf({ "# Title", "body", "", "## Sub", "subbody" })
  local t = target_mod.resolve({ name = "", heading = "Sub" }, buf)
  assert_true(t ~= nil, "target should resolve")
  assert_eq(t.source_buf, buf)
  assert_nil(t.path)
  assert_deep_eq(t.lines, { "## Sub", "subbody" })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("target.resolve: same-file block id strips marker from paragraph", function()
  local buf = make_buf({ "para one ^blk-abc123", "", "other para" })
  local t = target_mod.resolve({ name = "", block_id = "blk-abc123" }, buf)
  assert_true(t ~= nil, "target should resolve")
  assert_eq(t.source_buf, buf)
  assert_deep_eq(t.lines, { "para one" })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("target.resolve: same-file missing heading yields placeholder", function()
  local buf = make_buf({ "# Title", "body" })
  local t = target_mod.resolve({ name = "", heading = "Nope" }, buf)
  assert_true(t ~= nil)
  assert_deep_eq(t.lines, { "[Heading not found: #Nope]" })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("target.resolve: unresolved cross-file name -> placeholder lines, nil path", function()
  local buf = make_buf({ "x" })
  local t = target_mod.resolve({ name = "ZzNonexistentNote12345" }, buf)
  assert_true(t ~= nil)
  assert_nil(t.path)
  assert_eq(t.name, "ZzNonexistentNote12345")
  assert_deep_eq(t.lines, { "[Note does not exist yet]" })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ============================================================================
-- 10. preview.target.resolve_in_preview
-- ============================================================================

test("target.resolve_in_preview: resolves fragment against current entry path", function()
  local tmp = vim.fn.tempname() .. ".md"
  local f = io.open(tmp, "w")
  f:write("# Alpha\nalpha body\n\n## Beta\nbeta body\n")
  f:close()

  local buf = make_buf({ "unrelated" })
  local t = target_mod.resolve_in_preview(
    { name = "", heading = "Beta" },
    { path = tmp },
    buf
  )
  assert_true(t ~= nil, "should resolve in preview")
  assert_eq(t.path, tmp)
  assert_nil(t.source_buf)
  assert_deep_eq(t.lines, { "## Beta", "beta body" })

  vim.api.nvim_buf_delete(buf, { force = true })
  os.remove(tmp)
end)

test("target.resolve_in_preview: empty name and no fragment -> nil", function()
  local buf = make_buf({ "x" })
  assert_nil(target_mod.resolve_in_preview({ name = "" }, { path = "/tmp/whatever.md" }, buf))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("target.resolve_in_preview: delegates to resolve without current entry path", function()
  local buf = make_buf({ "## Frag", "frag body" })
  local t = target_mod.resolve_in_preview({ name = "", heading = "Frag" }, nil, buf)
  assert_true(t ~= nil)
  assert_eq(t.source_buf, buf)
  assert_deep_eq(t.lines, { "## Frag", "frag body" })
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ============================================================================
-- 11. preview.breadcrumb.vault_relative_segments
-- ============================================================================

local saved_vault_path = engine.vault_path
engine.vault_path = "/tmp/myvault"

test("vault_relative_segments: in-vault path gets Vault root prefix", function()
  local segs = bc.vault_relative_segments("/tmp/myvault/Projects/Note.md", nil)
  assert_deep_eq(segs, { "Vault", "Projects", "Note.md" })
end)

test("vault_relative_segments: non-vault path shows basename only", function()
  local segs = bc.vault_relative_segments("/elsewhere/Other.md", nil)
  assert_deep_eq(segs, { "Other.md" })
end)

test("vault_relative_segments: nil path and nil buf -> {Vault}", function()
  assert_deep_eq(bc.vault_relative_segments(nil, nil), { "Vault" })
end)

-- ============================================================================
-- 12. preview.breadcrumb.format
-- ============================================================================

local SEP_HL = "VaultPreviewBreadcrumbSep"
local PATH_HL = "VaultPreviewBreadcrumbPath"
local NOTE_HL = "VaultPreviewBreadcrumbNote"
local FRAG_HL = "VaultPreviewBreadcrumbFragment"

local saved_style = config.preview.breadcrumb_style
local sep = config.preview.breadcrumb_separator or " \u{203A} "

test("breadcrumb.format: full style builds Vault/path/note chunks", function()
  config.preview.breadcrumb_style = "full"
  local target = {
    path = "/tmp/myvault/Projects/Note.md",
    name = "Note", heading = nil, block_id = nil, source_buf = nil,
  }
  local chunks = bc.format(target, "")
  assert_eq(#chunks, 7)
  assert_deep_eq(chunks[1], { " ", SEP_HL })
  assert_deep_eq(chunks[2], { "Vault", PATH_HL })
  assert_deep_eq(chunks[3], { sep, SEP_HL })
  assert_deep_eq(chunks[4], { "Projects", PATH_HL })
  assert_deep_eq(chunks[5], { sep, SEP_HL })
  assert_deep_eq(chunks[6], { "Note", NOTE_HL }) -- .md stripped
  assert_deep_eq(chunks[7], { " ", SEP_HL })
end)

test("breadcrumb.format: heading fragment and history position appended", function()
  config.preview.breadcrumb_style = "full"
  local target = {
    path = "/tmp/myvault/Note.md",
    name = "Note", heading = "Stuff", block_id = nil, source_buf = nil,
  }
  local chunks = bc.format(target, "2/3")
  -- " ", Vault, sep, Note, " #Stuff", " 2/3", " "
  assert_eq(#chunks, 7)
  assert_deep_eq(chunks[5], { " #Stuff", FRAG_HL })
  assert_deep_eq(chunks[6], { " 2/3", SEP_HL })
end)

test("breadcrumb.format: block fragment appended with caret", function()
  config.preview.breadcrumb_style = "full"
  local target = {
    path = "/tmp/myvault/Note.md",
    name = "Note", heading = nil, block_id = "blk-xyz", source_buf = nil,
  }
  local chunks = bc.format(target, "")
  assert_deep_eq(chunks[5], { " ^blk-xyz", FRAG_HL })
end)

test("breadcrumb.format: style none yields single Function chunk", function()
  config.preview.breadcrumb_style = "none"
  local target = { path = nil, name = "Note", heading = "Stuff", source_buf = nil }
  local chunks = bc.format(target, "1/2")
  assert_eq(#chunks, 1)
  assert_deep_eq(chunks[1], { " Note#Stuff 1/2 ", "Function" })
end)

test("breadcrumb.format: style short shows note name only", function()
  config.preview.breadcrumb_style = "short"
  local target = { path = "/tmp/myvault/Projects/Note.md", name = "Note", source_buf = nil }
  local chunks = bc.format(target, "")
  assert_eq(#chunks, 3)
  assert_deep_eq(chunks[2], { "Note", NOTE_HL })
end)

config.preview.breadcrumb_style = saved_style

-- ============================================================================
-- 13. preview.breadcrumb.truncate
-- ============================================================================

test("breadcrumb.truncate: identity when chunks fit", function()
  local chunks = { { " ", SEP_HL }, { "Note", NOTE_HL }, { " ", SEP_HL } }
  local out = bc.truncate(chunks, 100)
  assert_deep_eq(out, chunks)
end)

test("breadcrumb.truncate: identity when no path chunks even if too wide", function()
  local chunks = { { string.rep("x", 50), NOTE_HL } }
  local out = bc.truncate(chunks, 10)
  assert_deep_eq(out, chunks)
end)

test("breadcrumb.truncate: removes path chunks and inserts single ellipsis", function()
  local chunks = {
    { " ", SEP_HL },
    { "Vault", PATH_HL }, { sep, SEP_HL },
    { "AA", PATH_HL }, { sep, SEP_HL },
    { "BB", PATH_HL }, { sep, SEP_HL },
    { "Note", NOTE_HL },
    { " ", SEP_HL },
  }
  local out = bc.truncate(chunks, 12)
  assert_eq(#out, 4)
  assert_deep_eq(out[1], { " ", SEP_HL })
  assert_deep_eq(out[2], { "\u{2026}" .. sep, SEP_HL })
  assert_deep_eq(out[3], { "Note", NOTE_HL })
  assert_deep_eq(out[4], { " ", SEP_HL })
  for _, c in ipairs(out) do
    assert_true(c[2] ~= PATH_HL, "no path chunks should remain")
  end
end)

-- ============================================================================
-- 14. viewport
-- ============================================================================

-- Set up a 300-line buffer in the current window
local vp_buf = vim.api.nvim_create_buf(false, true)
local vp_lines = {}
for i = 1, 300 do vp_lines[i] = "line " .. i end
vim.api.nvim_buf_set_lines(vp_buf, 0, -1, false, vp_lines)
vim.api.nvim_set_current_buf(vp_buf)
local vp_win = vim.api.nvim_get_current_win()

test("viewport.refresh: algebraic invariants hold", function()
  local padding = config.viewport.padding_lines
  local r = viewport.refresh(vp_win)
  assert_true(r.first >= 1, "first >= 1")
  assert_true(r.last >= r.first, "last >= first")
  assert_eq(r.height, r.last - r.first + 1)
  assert_eq(r.pad_first, math.max(1, r.first - padding))
  assert_eq(r.pad_last, math.min(300, r.last + padding))
end)

test("viewport.get_range: returns cached range matching refresh", function()
  local r = viewport.refresh(vp_win)
  local c = viewport.get_range(vp_win)
  assert_eq(c.first, r.first)
  assert_eq(c.last, r.last)
  assert_eq(c.pad_first, r.pad_first)
  assert_eq(c.pad_last, r.pad_last)
end)

test("viewport.get_zones: zone boundaries derived from range", function()
  local mult = config.viewport.prefetch_multiplier
  local z = viewport.get_zones(vp_win)
  local r = viewport.get_range(vp_win)
  local prefetch = math.floor(r.height * mult)
  assert_eq(z.prefetch_size, prefetch)
  assert_eq(z.viewport_height, r.height)
  assert_eq(z.visible.start_line, r.first)
  assert_eq(z.visible.end_line, r.last)
  assert_eq(z.above.start_line, math.max(1, r.first - prefetch))
  assert_eq(z.above.end_line, math.max(0, r.first - 1))
  assert_eq(z.below.start_line, math.min(300 + 1, r.last + 1))
  assert_eq(z.below.end_line, math.min(300, r.last + prefetch))
end)

test("viewport.get_margin_range: same-buffer branch applies render margin", function()
  local margin = config.viewport.render_margin
  local r = viewport.refresh(vp_win)
  local s, e = viewport.get_margin_range(vp_buf, vp_win)
  assert_eq(s, math.max(0, r.first - 1 - margin))
  assert_eq(e, math.min(300, r.last + margin))
end)

test("viewport.get_margin_range: different buffer -> full range", function()
  local other = vim.api.nvim_create_buf(false, true)
  local other_lines = {}
  for i = 1, 30 do other_lines[i] = "x" .. i end
  vim.api.nvim_buf_set_lines(other, 0, -1, false, other_lines)
  local s, e = viewport.get_margin_range(other, vp_win)
  assert_eq(s, 0)
  assert_eq(e, 30)
  vim.api.nvim_buf_delete(other, { force = true })
end)

test("viewport.newly_visible: nil when no previous range exists", function()
  assert_nil(viewport.newly_visible(99999))
end)

test("viewport.newly_visible: reports new range after scrolling down", function()
  viewport.refresh(vp_win) -- establish current range at top
  vim.api.nvim_win_set_cursor(vp_win, { 150, 0 })
  vim.cmd("normal! zt")
  local r = viewport.refresh(vp_win)
  assert_true(r.first > 1, "viewport should have scrolled (first=" .. r.first .. ")")
  local nv = viewport.newly_visible(vp_win)
  assert_true(nv ~= nil, "newly_visible should report ranges after scroll")
  assert_eq(nv[#nv].last, r.pad_last, "new below-range extends to pad_last")
end)

test("viewport.prefetch_zones_changed: first call true, repeat false, partial change", function()
  local zones1 = {
    above = { start_line = 1, end_line = 0 },
    below = { start_line = 11, end_line = 20 },
  }
  local a, b = viewport.prefetch_zones_changed(7777, 8888, zones1)
  assert_eq(a, true, "first call above")
  assert_eq(b, true, "first call below")

  local zones2 = {
    above = { start_line = 1, end_line = 0 },
    below = { start_line = 11, end_line = 20 },
  }
  a, b = viewport.prefetch_zones_changed(7777, 8888, zones2)
  assert_eq(a, false, "identical zones above")
  assert_eq(b, false, "identical zones below")

  local zones3 = {
    above = { start_line = 5, end_line = 9 },
    below = { start_line = 11, end_line = 20 },
  }
  a, b = viewport.prefetch_zones_changed(7777, 8888, zones3)
  assert_eq(a, true, "above changed")
  assert_eq(b, false, "below unchanged")
end)

-- ============================================================================
-- 15. breadcrumbs.compute_breadcrumb
-- ============================================================================

test("compute_breadcrumb: unnamed buffer -> nil", function()
  local buf = vim.api.nvim_create_buf(false, true)
  assert_nil(breadcrumbs.compute_breadcrumb(buf))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("compute_breadcrumb: non-vault path -> nil", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "/elsewhere/NotVault.md")
  assert_nil(breadcrumbs.compute_breadcrumb(buf))
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("compute_breadcrumb: vault note without parent-project -> Vault > note", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "/tmp/myvault/MyNote77.md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Hello" })
  local wb = breadcrumbs.compute_breadcrumb(buf)
  assert_true(wb ~= nil, "winbar should be computed")
  assert_true(wb:find("%1@v:lua._vault_breadcrumb_click@Vault%X", 1, true) ~= nil,
    "Vault segment is clickable")
  assert_true(wb:find("%#VaultBreadcrumbCurrent#MyNote77", 1, true) ~= nil,
    "current note stem highlighted")
  assert_eq(breadcrumbs._click_targets[1], "/tmp/myvault")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("compute_breadcrumb: parent-project frontmatter adds middle segment", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "/tmp/myvault/Projects/Foo/Note88.md")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "---",
    'parent-project: "[[Projects/Foo|Foo Project]]"',
    "---",
    "# Body",
  })
  local wb = breadcrumbs.compute_breadcrumb(buf)
  assert_true(wb ~= nil, "winbar should be computed")
  assert_true(wb:find("Foo Project", 1, true) ~= nil, "wikilink alias used as middle segment")
  assert_true(wb:find("%#VaultBreadcrumbCurrent#Note88", 1, true) ~= nil,
    "note stem is the current segment")
  assert_true(wb:find("%1@v:lua._vault_breadcrumb_click@Vault%X", 1, true) ~= nil,
    "Vault root still clickable")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- ============================================================================
-- 16. sidebar_meta.render
-- ============================================================================

test("sidebar_meta.render: writes aligned frontmatter panel into buffer", function()
  local src = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(src, "/tmp/myvault/MetaNote99.md")
  vim.api.nvim_buf_set_lines(src, 0, -1, false, {
    "---",
    "status: Draft",
    "count: 5",
    "---",
    "# Hello",
  })
  local panel = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace("test_sidebar_meta")

  sidebar_meta.render(panel, 80, src, 0, ns)
  local lines = vim.api.nvim_buf_get_lines(panel, 0, -1, false)

  assert_eq(lines[1], " MetaNote99", "header is note basename")
  assert_eq(lines[3], " Frontmatter")
  -- keys aligned to max key width ("status" = 6 chars)
  assert_eq(lines[4], "  status : Draft")
  assert_eq(lines[5], "  count  : 5")
  assert_eq(lines[7], " Tags")
  assert_eq(lines[8], "  (no tags)", "no vault index headless -> no tags")

  vim.api.nvim_buf_delete(src, { force = true })
  vim.api.nvim_buf_delete(panel, { force = true })
end)

-- Restore engine state
engine.vault_path = saved_vault_path

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
