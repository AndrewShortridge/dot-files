local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local c = ls.choice_node
local fmt = require("luasnip.extras.fmt").fmt
local tex = require("andrew.utils.tex")

-- Import shared math snippets
local math_snips, math_auto = tex.math_snippets()

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Generate a callout snippet for a given trigger and callout type.
local function callout_snippet(trig, callout_type)
  return s({ trig = trig, desc = callout_type .. " callout" }, {
    t("> [!" .. callout_type .. "] "), i(1, "Title"),
    t({ "", "> " }), i(2, "Content"),
    t({ "", "" }),
  })
end

--- Generate a collapsed callout snippet for a given trigger and callout type.
local function callout_collapsed_snippet(trig, callout_type)
  return s({ trig = trig .. "-", desc = callout_type .. " callout (collapsed)" }, {
    t("> [!" .. callout_type .. "]- "), i(1, "Title"),
    t({ "", "> " }), i(2, "Content"),
    t({ "", "" }),
  })
end

--- Generate an expanded callout snippet for a given trigger and callout type.
local function callout_expanded_snippet(trig, callout_type)
  return s({ trig = trig .. "+", desc = callout_type .. " callout (expanded)" }, {
    t("> [!" .. callout_type .. "]+ "), i(1, "Title"),
    t({ "", "> " }), i(2, "Content"),
    t({ "", "" }),
  })
end

--- Choice-node text entries for callout types.
local function callout_type_choices()
  return c(1, {
    t("NOTE"),
    t("TIP"),
    t("WARNING"),
    t("IMPORTANT"),
    t("CAUTION"),
    t("INFO"),
    t("TODO"),
    t("EXAMPLE"),
    t("QUESTION"),
    t("ABSTRACT"),
    t("BUG"),
    t("SIMULATION"),
    t("FINDING"),
    t("MEETING"),
    t("ANALYSIS"),
    t("LITERATURE"),
    t("CONCEPT"),
  })
end

-------------------------------------------------------------------------------
-- Snippets (explicit trigger via completion)
-------------------------------------------------------------------------------

local snippets = {

  ---------------------------------------------------------------------------
  -- Callout / Admonition snippets
  ---------------------------------------------------------------------------

  -- Generic callout with type picker
  s({ trig = "callout", desc = "Callout (pick type)" }, {
    t("> [!"), callout_type_choices(), t("] "), i(2, "Title"),
    t({ "", "> " }), i(3, "Content"),
    t({ "", "" }),
  }),

  -- Individual callout types
  callout_snippet("note",      "NOTE"),
  callout_snippet("tip",       "TIP"),
  callout_snippet("warning",   "WARNING"),
  callout_snippet("important", "IMPORTANT"),
  callout_snippet("caution",   "CAUTION"),
  callout_snippet("info",      "INFO"),
  callout_snippet("todo",      "TODO"),
  callout_snippet("example",   "EXAMPLE"),
  callout_snippet("question",  "QUESTION"),
  callout_snippet("abstract",  "ABSTRACT"),
  callout_snippet("bug",       "BUG"),

  -- Vault-specific callout types
  callout_snippet("simulation", "SIMULATION"),
  callout_snippet("finding",    "FINDING"),
  callout_snippet("meeting",    "MEETING"),
  callout_snippet("analysis",   "ANALYSIS"),
  callout_snippet("literature", "LITERATURE"),
  callout_snippet("concept",    "CONCEPT"),

  ---------------------------------------------------------------------------
  -- Collapsible callout variants
  ---------------------------------------------------------------------------

  -- Collapsed by default
  s({ trig = "callout-", desc = "Collapsed callout (pick type)" }, {
    t("> [!"), callout_type_choices(), t("]- "), i(2, "Title"),
    t({ "", "> " }), i(3, "Content"),
    t({ "", "" }),
  }),

  -- Expanded by default
  s({ trig = "callout+", desc = "Expanded callout (pick type)" }, {
    t("> [!"), callout_type_choices(), t("]+ "), i(2, "Title"),
    t({ "", "> " }), i(3, "Content"),
    t({ "", "" }),
  }),

  -- Individual collapsed/expanded variants for standard types
  callout_collapsed_snippet("note",      "NOTE"),
  callout_collapsed_snippet("tip",       "TIP"),
  callout_collapsed_snippet("warning",   "WARNING"),
  callout_collapsed_snippet("important", "IMPORTANT"),
  callout_collapsed_snippet("caution",   "CAUTION"),
  callout_collapsed_snippet("info",      "INFO"),
  callout_collapsed_snippet("todo",      "TODO"),
  callout_collapsed_snippet("example",   "EXAMPLE"),
  callout_collapsed_snippet("question",  "QUESTION"),
  callout_collapsed_snippet("abstract",  "ABSTRACT"),
  callout_collapsed_snippet("bug",       "BUG"),

  callout_expanded_snippet("note",      "NOTE"),
  callout_expanded_snippet("tip",       "TIP"),
  callout_expanded_snippet("warning",   "WARNING"),
  callout_expanded_snippet("important", "IMPORTANT"),
  callout_expanded_snippet("caution",   "CAUTION"),
  callout_expanded_snippet("info",      "INFO"),
  callout_expanded_snippet("todo",      "TODO"),
  callout_expanded_snippet("example",   "EXAMPLE"),
  callout_expanded_snippet("question",  "QUESTION"),
  callout_expanded_snippet("abstract",  "ABSTRACT"),
  callout_expanded_snippet("bug",       "BUG"),

  -- Vault-specific collapsed/expanded variants
  callout_collapsed_snippet("simulation", "SIMULATION"),
  callout_collapsed_snippet("finding",    "FINDING"),
  callout_collapsed_snippet("meeting",    "MEETING"),
  callout_collapsed_snippet("analysis",   "ANALYSIS"),
  callout_collapsed_snippet("literature", "LITERATURE"),
  callout_collapsed_snippet("concept",    "CONCEPT"),

  callout_expanded_snippet("simulation", "SIMULATION"),
  callout_expanded_snippet("finding",    "FINDING"),
  callout_expanded_snippet("meeting",    "MEETING"),
  callout_expanded_snippet("analysis",   "ANALYSIS"),
  callout_expanded_snippet("literature", "LITERATURE"),
  callout_expanded_snippet("concept",    "CONCEPT"),

  ---------------------------------------------------------------------------
  -- Dataview snippets
  ---------------------------------------------------------------------------

  s({ trig = "dv", desc = "Dataview TABLE query" }, {
    t({ "```dataview", "TABLE " }), i(1, "field1, field2"),
    t({ "", "FROM " }), i(2, '"folder"'),
    t({ "", "WHERE " }), i(3, "condition"),
    t({ "", "SORT " }), i(4, "field"), t(" ASC"),
    t({ "", "```", "" }),
  }),

  s({ trig = "dvl", desc = "Dataview LIST query" }, {
    t({ "```dataview", "LIST" }),
    t({ "", "FROM " }), i(1, '"folder"'),
    t({ "", "WHERE " }), i(2, "condition"),
    t({ "", "SORT " }), i(3, "field"), t(" ASC"),
    t({ "", "```", "" }),
  }),

  s({ trig = "dvt", desc = "Dataview TASK query" }, {
    t({ "```dataview", "TASK" }),
    t({ "", "FROM " }), i(1, '"folder"'),
    t({ "", "WHERE " }), i(2, "!completed"),
    t({ "", "SORT " }), i(3, "due"), t(" ASC"),
    t({ "", "```", "" }),
  }),

  s({ trig = "dvjs", desc = "Dataviewjs code block" }, {
    t({ "```dataviewjs", "" }), i(1, "// code"),
    t({ "", "```", "" }),
  }),

  ---------------------------------------------------------------------------
  -- Wikilink and embed snippets
  ---------------------------------------------------------------------------

  s({ trig = "wl", desc = "Wikilink [[note]]" }, {
    t("[["), i(1, "note"), t("]]"),
  }),

  s({ trig = "wla", desc = "Wikilink with alias [[note|alias]]" }, {
    t("[["), i(1, "note"), t("|"), i(2, "alias"), t("]]"),
  }),

  s({ trig = "wlh", desc = "Wikilink with heading [[note#heading]]" }, {
    t("[["), i(1, "note"), t("#"), i(2, "heading"), t("]]"),
  }),

  s({ trig = "embed", desc = "Embed ![[note]]" }, {
    t("![["), i(1, "note"), t("]]"),
  }),

  s({ trig = "embedh", desc = "Embed with heading ![[note#heading]]" }, {
    t("![["), i(1, "note"), t("#"), i(2, "heading"), t("]]"),
  }),

  ---------------------------------------------------------------------------
  -- Task snippets
  ---------------------------------------------------------------------------

  s({ trig = "task", desc = "Task checkbox" }, {
    t("- [ ] "), i(1, "task"),
  }),

  s({ trig = "taskd", desc = "Task with due date and priority" }, {
    t("- [ ] "), i(1, "task"),
    t(" [due:: "), i(2, "YYYY-MM-DD"),
    t("] [priority:: "), i(3, "1"), t("]"),
  }),

  s({ trig = "taskp", desc = "Task with priority" }, {
    t("- [ ] "), i(1, "task"),
    t(" [priority:: "), i(2, "1"), t("]"),
  }),

  ---------------------------------------------------------------------------
  -- Code block snippets
  ---------------------------------------------------------------------------

  s({ trig = "mermaid", desc = "Mermaid diagram block" }, {
    t({ "```mermaid", "" }), i(1, "graph TD"),
    t({ "", "```", "" }),
  }),

  s({ trig = "code", desc = "Fenced code block" }, {
    t("```"), c(1, {
      t(""),
      t("lua"),
      t("python"),
      t("javascript"),
      t("typescript"),
      t("bash"),
      t("rust"),
      t("go"),
      t("json"),
      t("yaml"),
      t("sql"),
      t("css"),
      t("html"),
    }),
    t({ "", "" }), i(2),
    t({ "", "```", "" }),
  }),

  ---------------------------------------------------------------------------
  -- Frontmatter snippet
  ---------------------------------------------------------------------------

  s({ trig = "fm", desc = "YAML frontmatter" }, {
    t({ "---", "type: " }), i(1, "note"),
    t({ "", "tags:", "  - " }), i(2, "tag"),
    t({ "", "---", "" }),
  }),

  ---------------------------------------------------------------------------
  -- Inline field snippets
  ---------------------------------------------------------------------------

  s({ trig = "field", desc = "Inline field [key:: value]" }, {
    t("["), i(1, "key"), t(":: "), i(2, "value"), t("]"),
  }),

  s({ trig = "fieldi", desc = "Standalone inline field key:: value" }, {
    i(1, "key"), t(":: "), i(2, "value"),
  }),

  ---------------------------------------------------------------------------
  -- Table snippet
  ---------------------------------------------------------------------------

  s({ trig = "tbl", desc = "Markdown table" }, {
    t("| "), i(1, "Header 1"), t(" | "), i(2, "Header 2"), t({ " |", "" }),
    t({ "| --- | --- |", "" }),
    t("| "), i(3, "Cell"), t(" | "), i(4, "Cell"), t({ " |", "" }),
  }),
}

-- Merge shared math snippets
vim.list_extend(snippets, math_snips)

local autosnippets = {
  -- Math-mode entry (only outside math)
  s({ trig = "mk", snippetType = "autosnippet", desc = "Inline math $...$" },
    { t("$"), i(1), t("$") },
    { condition = tex.not_mathzone }
  ),
  s({ trig = "dm", snippetType = "autosnippet", desc = "Display math $$...$$" },
    { t({ "$$", "" }), i(1), t({ "", "$$" }) },
    { condition = tex.not_mathzone }
  ),
}

-- Merge shared math autosnippets
vim.list_extend(autosnippets, math_auto)

return snippets, autosnippets
