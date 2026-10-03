-- Unit tests for the vault template system:
--   lua/andrew/vault/templates/init.lua (registry)
--   lua/andrew/vault/templates/{daily_log,weekly_review,person,meeting,concept,literature}.lua
--   lua/andrew/vault/user_templates.lua (parse_template, _parse_yaml_simple, build_frontmatter)
--   lua/andrew/vault/engine_templates.lua (obsidian_to_strftime, format_obsidian, substitute)
-- Run with: nvim --headless -u NONE -l tests/templates_spec.lua

local _H = dofile((debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)[/\\]") .. "/spec_helper.lua")
local test, assert_eq, assert_true, assert_nil =
  _H.test, _H.assert_eq, _H.assert_true, _H.assert_nil

-- spec-local deep_eq (private name avoids collision with shared M.deep_equal)
local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function assert_deep_eq(got, expected, msg)
  if not deep_eq(got, expected) then
    error((msg or "") .. " expected: " .. vim.inspect(expected) .. ", got: " .. vim.inspect(got))
  end
end

--- Plain-text substring assertion (no Lua patterns).
local function assert_contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error((msg or "missing substring") .. ": " .. vim.inspect(needle))
  end
end

local function assert_not_contains(haystack, needle, msg)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    error((msg or "unexpected substring present") .. ": " .. vim.inspect(needle))
  end
end

-- ============================================================================
-- Load modules under test
-- ============================================================================
package.path = vim.fn.stdpath("config") .. "/lua/?.lua;" .. package.path

local config = require("andrew.vault.config")
local engine = require("andrew.vault.engine")
local registry = require("andrew.vault.templates.init")
local daily = require("andrew.vault.templates.daily_log")
local weekly = require("andrew.vault.templates.weekly_review")
local person = require("andrew.vault.templates.person")
local meeting = require("andrew.vault.templates.meeting")
local concept = require("andrew.vault.templates.concept")
local lit = require("andrew.vault.templates.literature")
local ut = require("andrew.vault.user_templates")
local engine_templates = require("andrew.vault.engine_templates")

local EM_DASH = "\226\128\148" -- U+2014

-- ============================================================================
-- Fake engine factory
-- ============================================================================

--- Build a fake engine with scripted inputs/selects and a captured write_note.
--- Date functions are pinned to 2026-02-18 (a Wednesday) for determinism.
---@param opts? { inputs?: string[], selects?: string[], week_number?: string }
---@return table e, table captured
local function make_fake(opts)
  opts = opts or {}
  local inputs = opts.inputs or {}
  local selects = opts.selects or {}
  local input_i, select_i = 0, 0
  local captured = {}
  local e = {
    -- Nonexistent dir: carry-forward scanning finds nothing (deterministic)
    vault_path = vim.fn.tempname() .. "-no-vault",
    today = function() return "2026-02-18" end,
    today_long = function() return "February 18, 2026" end,
    week_number = function() return opts.week_number or "08" end,
    date_offset = function(n) return engine.date_offset_from("2026-02-18", n) end,
    date_offset_from = engine.date_offset_from,
    format_weekday = engine.format_weekday,
    render = engine.render,
    input = function(_)
      input_i = input_i + 1
      return inputs[input_i]
    end,
    select = function(items, _)
      select_i = select_i + 1
      captured.select_items = items
      return selects[select_i]
    end,
    write_note = function(path, content)
      captured.path = path
      captured.content = content
    end,
  }
  return e, captured
end

print("\n=== Template System Tests ===\n")

-- ---------------------------------------------------------------------------
-- 1. Registry: built-in templates
-- ---------------------------------------------------------------------------
test("all() with user templates disabled returns the 24 builtins", function()
  local saved_enabled = config.user_templates.enabled
  config.user_templates.enabled = false
  local ok, err = pcall(function()
    local list = registry.all()
    assert_eq(#list, 24, "builtin count")
    for i, t in ipairs(list) do
      assert_eq(type(t.name), "string", "entry " .. i .. " name type")
      assert_eq(type(t.run), "function", "entry " .. i .. " run type")
    end
    assert_eq(list[1].name, "Daily Log", "first entry")
    assert_eq(list[24].name, "Financial Snapshot", "last entry")
  end)
  config.user_templates.enabled = saved_enabled
  if not ok then error(err) end
end)

test("all() appends separator + wrapped user templates from a temp vault", function()
  local tmp_vault = vim.fn.tempname()
  vim.fn.mkdir(tmp_vault .. "/templates", "p")
  vim.fn.writefile({
    "---",
    "template_name: Quick Note",
    "---",
    "# {{title}}",
  }, tmp_vault .. "/templates/Quick.md")

  local saved_enabled = config.user_templates.enabled
  local saved_vault = engine.vault_path
  config.user_templates.enabled = true
  engine.vault_path = tmp_vault
  ut._cache = {}

  local ok, err = pcall(function()
    local list = registry.all()
    assert_eq(#list, 26, "24 builtins + separator + 1 user template")

    local separators, users = {}, {}
    for _, t in ipairs(list) do
      if t._separator then separators[#separators + 1] = t end
      if t._user_template then users[#users + 1] = t end
    end
    assert_eq(#separators, 1, "exactly one separator")
    assert_eq(separators[1].name, "--- User Templates ---", "separator name")
    assert_eq(#users, 1, "exactly one user template entry")
    assert_eq(users[1].name, "Quick Note", "user template name")
    assert_eq(type(users[1].run), "function", "user template run type")
  end)

  engine.vault_path = saved_vault
  config.user_templates.enabled = saved_enabled
  ut._cache = {}
  vim.fn.delete(tmp_vault, "rf")
  if not ok then error(err) end
end)

-- ---------------------------------------------------------------------------
-- 2. daily_log.generate
-- ---------------------------------------------------------------------------
test("daily_log.generate produces frontmatter + all major sections", function()
  local e = make_fake()
  local content = daily.generate(e, "2026-02-18")
  assert_contains(content, "type: log")
  assert_contains(content, "date: 2026-02-18")
  assert_contains(content, "## Morning Plan")
  assert_contains(content, "## Work Log")
  assert_contains(content, "## Scratchpad")
  assert_contains(content, "## End of Day")
  assert_contains(content, "Tomorrow's Priorities")
  -- No carry-forward section when the log dir does not exist
  assert_not_contains(content, "Carried Forward")
end)

test("daily_log.generate computes prev/next links and the weekday header", function()
  local e = make_fake()
  local content = daily.generate(e, "2026-02-18")
  assert_contains(content, "[[2026-02-17]]", "yesterday link")
  assert_contains(content, "[[2026-02-19]]", "tomorrow link")
  local header = content:match("# (%a+, %a+ %d+, %d+)")
  assert_eq(header, "Wednesday, February 18, 2026", "long weekday header")
end)

-- ---------------------------------------------------------------------------
-- 3. person.run
-- ---------------------------------------------------------------------------
test("person.run writes People/<name> with frontmatter + body sections", function()
  local e, captured = make_fake({
    inputs = { "Dr. Jane Smith", "PhD Advisor", "MIT", "jane@mit.edu" },
  })
  person.run(e, {})
  assert_eq(captured.path, "People/Dr. Jane Smith", "destination path")
  local c = captured.content
  assert_contains(c, "type: person")
  assert_contains(c, "name: Dr. Jane Smith")
  assert_contains(c, "role: PhD Advisor")
  assert_contains(c, "institution: MIT")
  assert_contains(c, "email: jane@mit.edu")
  assert_contains(c, "created: 2026-02-18")
  assert_contains(c, "# Dr. Jane Smith")
  assert_contains(c, "## Context")
  assert_contains(c, "## Shared Projects")
  assert_contains(c, "## Meeting Notes")
  -- Body template vars rendered (no leftover placeholders)
  assert_not_contains(c, "{{name}}")
  assert_contains(c, "**Role:** PhD Advisor")
end)

-- ---------------------------------------------------------------------------
-- 4. concept.run
-- ---------------------------------------------------------------------------
test("concept.run writes Domains/<domain>/<title> with maturity from select", function()
  local e, captured = make_fake({
    inputs = { "Shock Compression", "Shock Physics" },
    selects = { "Mature" },
  })
  concept.run(e, {})
  assert_eq(captured.path, "Domains/Shock Physics/Shock Compression", "destination path")
  -- select() should be offered the configured maturity values
  assert_deep_eq(captured.select_items, { "Seed", "Developing", "Mature", "Evergreen" })
  local c = captured.content
  assert_contains(c, "type: concept")
  assert_contains(c, "title: Shock Compression")
  assert_contains(c, 'domain: "[[Shock Physics]]"')
  assert_contains(c, "maturity: Mature")
  assert_contains(c, "# Shock Compression")
  assert_contains(c, "## Core Idea")
  assert_contains(c, "## Open Questions")
end)

-- ---------------------------------------------------------------------------
-- 5. literature.run
-- ---------------------------------------------------------------------------
-- people.lua talks to the real vault via the real engine, so every literature
-- test must swap its filesystem-backed functions out. Patching the table in
-- place (rather than package.loaded) is required: literature.lua captured the
-- module table as an upvalue when this spec required it.
local people = require("andrew.vault.people")

--- Run fn with people.list_names/exists/create_stub stubbed out.
---@param existing string[] names the picker should offer
---@return table stub_calls  { created = string[] }
local function with_fake_people(existing, fn)
  local real_list, real_exists, real_create = people.list_names, people.exists, people.create_stub
  local calls = { created = {} }
  people.list_names = function() return existing end
  people.exists = function() return false end
  people.create_stub = function(name)
    calls.created[#calls.created + 1] = name
    return "created"
  end
  local ok, err = pcall(fn)
  people.list_names, people.exists, people.create_stub = real_list, real_exists, real_create
  if not ok then error(err) end
  return calls
end

local LIT_NEW = "+ New author..."
local LIT_DONE = "\226\156\147 Done " .. EM_DASH .. " finish author list"

test("literature.run sanitizes the filename and emits citation frontmatter", function()
  local e, captured = make_fake({
    inputs = { "My: Paper/Title*?", "Shengfu Li", "2024", "J. Appl. Phys.", "10.1/x" },
    selects = { "Rongbo Wang", LIT_NEW, LIT_DONE },
  })
  local calls = with_fake_people({ "Rongbo Wang" }, function() lit.run(e, {}) end)

  assert_eq(captured.path, "Library/My - Paper-Title/My - Paper-Title", "sanitized destination")
  local c = captured.content
  assert_contains(c, "type: literature")
  assert_contains(c, 'title: "My: Paper/Title*?"', "frontmatter keeps raw title")
  assert_contains(c, "year: 2024")
  assert_contains(c, 'journal: "J. Appl. Phys."')
  assert_contains(c, "doi: 10.1/x")
  assert_contains(c, "start_date: 2026-02-18")
  assert_contains(c, "completed_date: 2026-02-18")
  assert_contains(c, "  - literature/paper", "nested tag, not an escape sequence")
  assert_contains(c, "> [!cite] Citation")
  assert_contains(c, "## Notes")
  assert_contains(c, "## Related Concepts")
  assert_contains(c, "## Related Papers")

  -- authors: YAML block list of bare, double-quoted person wikilinks.
  -- Two-space indent is load-bearing (patterns.lua FM_LIST_ITEM_CHECK).
  assert_contains(c, 'authors:\n  - "[[Rongbo Wang]]"\n  - "[[Shengfu Li]]"\n')
  -- A picked existing name and a typed new name both get a People note.
  assert_deep_eq(calls.created, { "Rongbo Wang", "Shengfu Li" }, "stubs created")
end)

test("literature.run keeps heading and citation as prose with a serial 'and'", function()
  local e, captured = make_fake({
    inputs = { "Shock Response of Cu", "2021", "J. Appl. Phys.", "" },
    selects = { "Rongbo Wang", "Shengfu Li", "Lihua He", LIT_DONE },
  })
  with_fake_people({ "Lihua He", "Rongbo Wang", "Shengfu Li" }, function() lit.run(e, {}) end)

  local c = captured.content
  local prose = "Rongbo Wang, Shengfu Li, and Lihua He"
  assert_contains(c, "# " .. prose .. " (2021) " .. EM_DASH .. " Shock Response of Cu")
  assert_contains(c, "> " .. prose .. ', "Shock Response of Cu," *J. Appl. Phys.*, 2021.')
  -- The body must never carry wikilink brackets; only frontmatter does.
  local body = c:match("\n%-%-%-\n(.*)$")
  assert_true(body ~= nil, "body found after frontmatter")
  assert_not_contains(body:match("^[^\n]*\n[^\n]*\n([^\n]*)") or "", "[[")
end)

test("literature.run two authors join with 'and', no Oxford comma", function()
  local e, captured = make_fake({
    inputs = { "Paper", "2020", "Nature", "" },
    selects = { "A One", "B Two", LIT_DONE },
  })
  with_fake_people({ "A One", "B Two" }, function() lit.run(e, {}) end)
  assert_contains(captured.content, "# A One and B Two (2020) ")
  assert_contains(captured.content, 'authors:\n  - "[[A One]]"\n  - "[[B Two]]"\n')
end)

test("literature.run dedups a repeated author and skips its second stub", function()
  local e, captured = make_fake({
    inputs = { "Paper", "2020", "Nature", "" },
    selects = { "A One", "A One", LIT_DONE },
  })
  local calls = with_fake_people({ "A One" }, function() lit.run(e, {}) end)
  assert_contains(captured.content, 'authors:\n  - "[[A One]]"\nyear:')
  assert_deep_eq(calls.created, { "A One" }, "duplicate collected only once")
end)

test("literature.run emits a bare authors key when none are given", function()
  local e, captured = make_fake({
    inputs = { "Paper", "2020", "Nature", "" },
    selects = { LIT_DONE },
  })
  local calls = with_fake_people({}, function() lit.run(e, {}) end)
  assert_contains(captured.content, "authors:\nyear: 2020")
  assert_deep_eq(calls.created, {}, "no stubs for an empty author list")
end)

test("literature.run aborts when the new-author prompt is cancelled", function()
  -- input #2 is the free-text author name; nil there abandons the note.
  local e, captured = make_fake({
    inputs = { "Paper" },
    selects = { LIT_NEW },
  })
  local calls = with_fake_people({}, function() lit.run(e, {}) end)
  assert_nil(captured.path, "no note written")
  assert_deep_eq(calls.created, {}, "no stubs created on abort")
end)

test("literature.run strips Templater delimiters from an author name", function()
  -- New People/*.md stubs fire vault.on("create"); Templater parses non-empty
  -- new files in place, so "<% ... %>" in a name would execute as code.
  local e, captured = make_fake({
    inputs = { "Paper", "<% app.foo() %>Evil Name", "2020", "Nature", "" },
    selects = { LIT_NEW, LIT_DONE },
  })
  local calls = with_fake_people({}, function() lit.run(e, {}) end)
  assert_not_contains(captured.content, "<%")
  assert_not_contains(captured.content, "%>")
  assert_contains(captured.content, 'authors:\n  - "[[ app.foo() Evil Name]]"\n')
  assert_deep_eq(calls.created, { " app.foo() Evil Name" }, "sanitized name used for the stub")
end)

test("literature.run double-quotes an author whose name has an apostrophe", function()
  -- Single-quoted YAML would need '' doubling, which the index never un-doubles,
  -- so the link would resolve to the literal "O''Malley" and lose its backlink.
  local e, captured = make_fake({
    inputs = { "Paper", "Sean O'Malley", "2020", "Nature", "" },
    selects = { LIT_NEW, LIT_DONE },
  })
  with_fake_people({}, function() lit.run(e, {}) end)
  assert_contains(captured.content, "authors:\n  - \"[[Sean O'Malley]]\"\n")
  assert_not_contains(captured.content, "O''Malley")
end)

-- ---------------------------------------------------------------------------
-- 6. meeting.run (both branches)
-- ---------------------------------------------------------------------------
test("meeting.run general branch writes to <title> with blank parent-project", function()
  local e, captured = make_fake({ inputs = { "Advisor Check-in", "Dr. Smith" } })
  local fake_p = { project_or_none = function() return false end }
  meeting.run(e, fake_p)
  assert_eq(captured.path, "Advisor Check-in", "general meeting at vault root")
  local c = captured.content
  assert_contains(c, "type: meeting")
  assert_contains(c, "date: 2026-02-18")
  assert_contains(c, "[[Dr. Smith]]")
  assert_contains(c, "## Agenda")
  assert_contains(c, "## Action Items")
  assert_contains(c, "## Decisions Made")
  -- Em-dash Project line, no project link
  assert_contains(c, "**Project:** " .. EM_DASH, "em-dash project line")
  assert_contains(c, "parent-project:\n", "blank parent-project frontmatter")
  assert_not_contains(c, "Dashboard")
end)

test("meeting.run project branch nests under Projects/<proj>/Meetings/<title>", function()
  local e, captured = make_fake({ inputs = { "Sync", "Bob" } })
  local fake_p = { project_or_none = function() return "ProjAlpha" end }
  meeting.run(e, fake_p)
  assert_eq(captured.path, "Projects/ProjAlpha/Meetings/Sync", "nested destination")
  local c = captured.content
  assert_contains(c, "parent-project: '[[Projects/ProjAlpha/Dashboard|ProjAlpha]]'")
  assert_contains(c, "**Project:** [[Projects/ProjAlpha/Dashboard|ProjAlpha]]")
end)

-- ---------------------------------------------------------------------------
-- 7. weekly_review.run
-- ---------------------------------------------------------------------------
test("weekly_review.run writes Log/<title> with weekly-review frontmatter", function()
  local e, captured = make_fake({
    inputs = { "Week 08 Review" },
    week_number = "08",
  })
  weekly.run(e, {})
  assert_eq(captured.path, "Log/Week 08 Review", "destination path")
  local c = captured.content
  assert_contains(c, "type: log")
  assert_contains(c, "subtype: weekly-review")
  assert_contains(c, "week_of: 2026-02-18")
  assert_contains(c, "week_number: 08")
  -- week_ago = date_offset(-6) from the pinned date
  assert_contains(c, "2026-02-12")
  assert_contains(c, "## Research Accomplishments")
  assert_contains(c, "## Next Week's Priorities")
  assert_contains(c, "## Vault Maintenance")
end)

test("weekly_review.run aborts without writing when title prompt is cancelled", function()
  local e, captured = make_fake({ inputs = {} }) -- input() returns nil
  weekly.run(e, {})
  assert_nil(captured.path, "write_note must not be called on cancel")
end)

-- ---------------------------------------------------------------------------
-- 8. user_templates.parse_template
-- ---------------------------------------------------------------------------
test("parse_template parses name/desc/dest, prompts, select options, and body", function()
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({
    "---",
    "template_name: My Tpl",
    "template_desc: A test",
    "template_dest: Notes",
    "prompts:",
    "  - key: title",
    "    prompt: Note title",
    "  - key: choice",
    "    prompt: Pick one",
    "    type: select",
    '    options: ["a", "b"]',
    "frontmatter:",
    "  type: custom",
    "---",
    "# {{title}}",
    "",
    "Body here.",
  }, path)

  local tpl = ut.parse_template(path)
  vim.fn.delete(path)

  assert_true(tpl ~= nil, "template parsed")
  assert_eq(tpl.name, "My Tpl")
  assert_eq(tpl.desc, "A test")
  assert_eq(tpl.dest, "Notes")
  assert_eq(tpl.template_type, "note", "default template_type")
  assert_eq(tpl.filename, "{{title}}", "default filename")
  assert_eq(#tpl.prompts, 2, "prompt count")
  assert_eq(tpl.prompts[1].key, "title")
  assert_eq(tpl.prompts[1].type, "input", "default prompt type")
  assert_eq(tpl.prompts[2].key, "choice")
  assert_eq(tpl.prompts[2].type, "select")
  assert_deep_eq(tpl.prompts[2].options, { "a", "b" }, "select options")
  assert_eq(tpl.note_frontmatter.type, "custom", "nested frontmatter map")
  assert_true(tpl.body:find("{{title}}", 1, true) ~= nil, "body keeps placeholder")
  assert_eq(tpl.source_path, path)
end)

test("parse_template auto-adds a title prompt when body uses {{title}}", function()
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({
    "---",
    "template_name: No Prompts",
    "---",
    "# {{title}}",
  }, path)

  local tpl = ut.parse_template(path)
  vim.fn.delete(path)

  assert_true(tpl ~= nil, "template parsed")
  assert_eq(#tpl.prompts, 1, "auto-added prompt")
  assert_eq(tpl.prompts[1].key, "title")
  assert_eq(tpl.prompts[1].type, "input")
  assert_eq(tpl.filename, "{{title}}")
end)

-- ---------------------------------------------------------------------------
-- 9. user_templates._parse_yaml_simple
-- ---------------------------------------------------------------------------
test("_parse_yaml_simple parses scalars (quote-stripped) and simple lists", function()
  local result = ut._parse_yaml_simple(
    'template_name: X\nfoo: "bar"\nlist:\n  - one\n  - two\n'
  )
  assert_eq(result.template_name, "X")
  assert_eq(result.foo, "bar", "quotes stripped")
  assert_deep_eq(result.list, { "one", "two" }, "simple list")
end)

test("_parse_yaml_simple parses inline lists and list-of-maps", function()
  local result = ut._parse_yaml_simple(
    "tags: [alpha, beta]\nprompts:\n  - key: title\n    prompt: Note title\n  - key: kind\n    type: select\n"
  )
  assert_deep_eq(result.tags, { "alpha", "beta" }, "inline list")
  assert_eq(#result.prompts, 2, "list-of-maps length")
  assert_eq(result.prompts[1].key, "title")
  assert_eq(result.prompts[1].prompt, "Note title")
  assert_eq(result.prompts[2].key, "kind")
  assert_eq(result.prompts[2].type, "select")
end)

-- ---------------------------------------------------------------------------
-- 10. user_templates.build_frontmatter
-- ---------------------------------------------------------------------------
test("build_frontmatter emits scalar and list YAML wrapped in --- fences", function()
  local fm = ut.build_frontmatter({ type = "custom", tags = { "a", "b" } }, {})
  assert_true(vim.startswith(fm, "---\n"), "opening fence")
  assert_true(vim.endswith(fm, "---\n"), "closing fence")
  -- pairs() order is nondeterministic: assert per-line, not full equality
  assert_contains(fm, "\ntype: custom\n")
  assert_contains(fm, "\ntags:\n  - a\n  - b\n", "list block")
end)

test("build_frontmatter interpolates {{var}} placeholders in values", function()
  local fm = ut.build_frontmatter({ title = "{{title}}" }, { title = "Hello" })
  assert_contains(fm, "\ntitle: Hello\n")
end)

-- ---------------------------------------------------------------------------
-- 11. engine_templates.substitute
-- ---------------------------------------------------------------------------
test("substitute resolves explicit {{var}} values from the vars table", function()
  assert_eq(engine_templates.substitute("Hello {{title}}!", { title = "World" }), "Hello World!")
  assert_eq(
    engine_templates.substitute("{{a}}-{{b}}", { a = "x", b = "y" }),
    "x-y"
  )
end)

test("substitute resolves legacy ${var} syntax from the vars table", function()
  assert_eq(engine_templates.substitute("${x} and ${y}", { x = "1", y = "2" }), "1 and 2")
end)

test("substitute leaves unresolved tokens untouched", function()
  assert_eq(engine_templates.substitute("keep {{nope}} here", {}), "keep {{nope}} here")
  assert_eq(engine_templates.substitute("${unknown}", {}), "${unknown}")
end)

test("substitute works with no vars argument", function()
  assert_eq(engine_templates.substitute("plain text"), "plain text")
end)

-- ---------------------------------------------------------------------------
-- 12. engine_templates.obsidian_to_strftime / format_obsidian
-- ---------------------------------------------------------------------------
-- NOTE: these assert the FIXED behavior. The original code emitted doubled
-- percents ("YYYY" -> "%%Y"), which made os.date() return the literal format
-- string instead of the date (product bug, fixed alongside this spec).
test("obsidian_to_strftime maps padded tokens to single-percent strftime codes", function()
  assert_eq(engine_templates.obsidian_to_strftime("YYYY-MM-DD"), "%Y-%m-%d")
  assert_eq(engine_templates.obsidian_to_strftime("HH:mm:ss"), "%H:%M:%S")
  assert_eq(engine_templates.obsidian_to_strftime("dddd"), "%A")
  assert_eq(engine_templates.obsidian_to_strftime("MMMM YYYY"), "%B %Y")
end)

test("obsidian_to_strftime escapes literal percent for os.date", function()
  assert_eq(engine_templates.obsidian_to_strftime("100%"), "100%%")
end)

test("obsidian_to_strftime splices unpadded tokens as runtime digit literals", function()
  -- 'D' (unpadded day) is resolved immediately: result is 1-2 digits, no '%'
  local out = engine_templates.obsidian_to_strftime("D")
  assert_true(out:match("^%d%d?$") ~= nil, "unpadded day should be digits, got " .. out)
end)

test("format_obsidian('YYYY-MM-DD') returns an actual ISO date", function()
  local out = engine_templates.format_obsidian("YYYY-MM-DD")
  assert_true(out:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil, "ISO date expected, got " .. out)
end)

test("substitute resolves {{date}} builtin and {{date:FMT}} to real dates", function()
  -- Relies on config.template_vars (added alongside this spec; previously
  -- missing, which crashed the {{date}}/{{time}} builtin resolvers).
  local out = engine_templates.substitute("d={{date}}", {})
  assert_true(out:match("^d=%d%d%d%d%-%d%d%-%d%d$") ~= nil, "builtin {{date}}, got " .. out)
  local out2 = engine_templates.substitute("y={{date:YYYY}}", {})
  assert_true(out2:match("^y=%d%d%d%d$") ~= nil, "{{date:YYYY}}, got " .. out2)
end)

-- ============================================================================
-- Summary
-- ============================================================================
_H.finish({ style = "results", exit = "os" })
