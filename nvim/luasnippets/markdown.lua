local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local c = ls.choice_node
local f = ls.function_node
local d = ls.dynamic_node
local sn = ls.snippet_node
local fmt = require("luasnip.extras.fmt").fmt
local rep = require("luasnip.extras").rep
local tex = require("andrew.utils.tex")
local footnotes = require("andrew.vault.footnotes")

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
    t("TARGET"),
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
  callout_snippet("target",     "TARGET"),

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
  callout_collapsed_snippet("target",     "TARGET"),

  callout_expanded_snippet("simulation", "SIMULATION"),
  callout_expanded_snippet("finding",    "FINDING"),
  callout_expanded_snippet("meeting",    "MEETING"),
  callout_expanded_snippet("analysis",   "ANALYSIS"),
  callout_expanded_snippet("literature", "LITERATURE"),
  callout_expanded_snippet("concept",    "CONCEPT"),
  callout_expanded_snippet("target",     "TARGET"),

  ---------------------------------------------------------------------------
  -- Nested callout snippets
  ---------------------------------------------------------------------------

  s({ trig = ";callout-nested", desc = "Nested callout (callout inside callout)" }, {
    t("> [!"), callout_type_choices(), t("] "), i(2, "Outer Title"),
    t({ "", "> " }), i(3, "Outer content"),
    t({ "", ">", "> > [!" }), callout_type_choices(), t("] "), i(4, "Inner Title"),
    t({ "", "> > " }), i(5, "Inner content"),
    t({ "", "", "" }),
  }),

  s({ trig = ";note-nested", desc = "Nested NOTE callout" }, {
    t("> [!NOTE] "), i(1, "Outer Title"),
    t({ "", "> " }), i(2, "Outer content"),
    t({ "", ">", "> > [!TIP] " }), i(3, "Inner Title"),
    t({ "", "> > " }), i(4, "Inner content"),
    t({ "", "", "" }),
  }),

  s({ trig = ";warning-nested", desc = "Nested WARNING callout" }, {
    t("> [!WARNING] "), i(1, "Outer Title"),
    t({ "", "> " }), i(2, "Outer content"),
    t({ "", ">", "> > [!IMPORTANT] " }), i(3, "Inner Title"),
    t({ "", "> > " }), i(4, "Inner content"),
    t({ "", "", "" }),
  }),

  s({ trig = ";example-nested", desc = "Nested EXAMPLE with INFO" }, {
    t("> [!EXAMPLE] "), i(1, "Outer Title"),
    t({ "", "> " }), i(2, "Outer content"),
    t({ "", ">", "> > [!INFO] " }), i(3, "Inner Title"),
    t({ "", "> > " }), i(4, "Inner content"),
    t({ "", "", "" }),
  }),

  s({ trig = ";callout-triple", desc = "Triple-nested callout" }, {
    t("> [!"), callout_type_choices(), t("] "), i(2, "Level 1 Title"),
    t({ "", "> " }), i(3, "Level 1 content"),
    t({ "", ">", "> > [!" }), callout_type_choices(), t("] "), i(4, "Level 2 Title"),
    t({ "", "> > " }), i(5, "Level 2 content"),
    t({ "", "> >", "> > > [!" }), callout_type_choices(), t("] "), i(6, "Level 3 Title"),
    t({ "", "> > > " }), i(7, "Level 3 content"),
    t({ "", "", "" }),
  }),

  ---------------------------------------------------------------------------
  -- Callouts with metadata
  ---------------------------------------------------------------------------

  s({ trig = ";callout-meta", desc = "Callout with metadata (date, author, status)" }, {
    t("> [!"), callout_type_choices(), t("] "), i(2, "Title"),
    t({ "", "> **Date:** " }), i(3, "YYYY-MM-DD"),
    t({ "", "> **Author:** " }), i(4, "Name"),
    t({ "", "> **Status:** " }), c(5, {
      t("Draft"),
      t("In Review"),
      t("Final"),
      t("Superseded"),
    }),
    t({ "", ">", "> " }), i(6, "Content"),
    t({ "", "" }),
  }),

  s({ trig = ";finding-meta", desc = "FINDING callout with metadata" }, {
    t("> [!FINDING] "), i(1, "Finding Title"),
    t({ "", "> **Date:** " }), i(2, "YYYY-MM-DD"),
    t({ "", "> **Source:** " }), i(3, "[[Simulation or Analysis]]"),
    t({ "", "> **Status:** " }), c(4, {
      t("In Progress"),
      t("Resolved"),
      t("Needs Investigation"),
    }),
    t({ "", ">", "> " }), i(5, "Description of finding"),
    t({ "", "" }),
  }),

  s({ trig = ";simulation-meta", desc = "SIMULATION callout with metadata" }, {
    t("> [!SIMULATION] "), i(1, "Run Title"),
    t({ "", "> **Run ID:** " }), i(2, "run_id"),
    t({ "", "> **Software:** " }), c(3, { t("LAMMPS"), t("GEMMS") }),
    t({ "", "> **Status:** " }), c(4, {
      t("Queued"),
      t("Running"),
      t("Complete"),
      t("Failed"),
    }),
    t({ "", ">", "> " }), i(5, "Purpose / Key result"),
    t({ "", "" }),
  }),

  s({ trig = ";literature-meta", desc = "LITERATURE callout with metadata" }, {
    t("> [!LITERATURE] "), i(1, "Paper Title"),
    t({ "", "> **Authors:** " }), i(2, "Author(s)"),
    t({ "", "> **Year:** " }), i(3, "2025"),
    t({ "", "> **Journal:** " }), i(4, "Journal"),
    t({ "", "> **DOI:** " }), i(5, "10.xxxx/xxxxx"),
    t({ "", ">", "> " }), i(6, "Key takeaway"),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-meta", desc = "ANALYSIS callout with metadata" }, {
    t("> [!ANALYSIS] "), i(1, "Analysis Title"),
    t({ "", "> **Date:** " }), i(2, "YYYY-MM-DD"),
    t({ "", "> **Status:** " }), c(3, {
      t("In Progress"),
      t("Complete"),
      t("Needs Revision"),
    }),
    t({ "", "> **Project:** " }), i(4, "[[Project]]"),
    t({ "", ">", "> " }), i(5, "Summary"),
    t({ "", "" }),
  }),

  s({ trig = ";meeting-meta", desc = "MEETING callout with metadata" }, {
    t("> [!MEETING] "), i(1, "Meeting Title"),
    t({ "", "> **Date:** " }), i(2, "YYYY-MM-DD"),
    t({ "", "> **Attendees:** " }), i(3, "[[Person]]"),
    t({ "", "> **Project:** " }), i(4, "[[Project]]"),
    t({ "", ">", "> " }), i(5, "Key outcome or decision"),
    t({ "", "" }),
  }),

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

  s({ trig = "dvjs-full", desc = "Dataviewjs block with dv.table() scaffold" }, {
    t({ "```dataviewjs", 'const pages = dv.pages(\'' }), i(1, '"folder"'),
    t({ "')", "  .where(p => " }), i(2, 'p.type === "note"'),
    t({ ")", "  .sort(p => " }), i(3, "p.date"),
    t({ ", '" }), i(4, "desc"), t({ "');", "", "dv.table(", "  [" }),
    i(5, '"Name", "Date"'), t({ "],", "  pages.map(p => [p.file.link, " }),
    i(6, "p.date"), t({ "])", ");", "```", "" }),
  }),

  s({ trig = "vault", desc = "Vault (Lua) code block with dv.* PageArray" }, {
    t({ "```vault", "" }),
    t("dv.table({"), i(1, '"Name", "Status"'), t({ "}, dv.pages('", "" }),
    i(2, '"folder"'), t({ "')", "" }),
    t("  :where(function(p) return "), i(3, 'p.status ~= "Complete"'), t({ " end)", "" }),
    t('  :sort("'), i(4, "file.name"), t({ '")', "" }),
    t("  :map(function(p) return {p.file.link, "), i(5, "p.status"), t({ "} end))", "" }),
    t({ "```", "" }),
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

  s({ trig = "taskdone", desc = "Completed task checkbox" }, {
    t("- [x] "), i(1, "task"),
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

  s({ trig = "cb", desc = "Fenced code block (alias)" }, {
    t("```"), i(1, "language"),
    t({ "", "" }), i(2),
    t({ "", "```", "" }),
  }),

  ---------------------------------------------------------------------------
  -- Frontmatter snippet
  ---------------------------------------------------------------------------

  s({ trig = "fm", desc = "YAML frontmatter" }, {
    t({ "---", "type: " }), i(1, "note"),
    t({ "", "date: " }), f(function() return os.date("%Y-%m-%d") end),
    t({ "", "tags:", "  - " }), i(2, "tag"),
    t({ "", "---", "" }),
  }),

  s({ trig = "fmtask", desc = "Task note frontmatter" }, {
    t({ "---", "type: task", "status: " }),
    c(1, { t("todo"), t("in-progress"), t("done"), t("blocked") }),
    t({ "", "priority: " }),
    c(2, { t("1"), t("2"), t("3"), t("4"), t("5") }),
    t({ "", "due: " }), i(3, "YYYY-MM-DD"),
    t({ "", "project: " }), i(4, "project-name"),
    t({ "", "tags:", "  - " }), i(5, "tag"),
    t({ "", "---", "" }),
  }),

  s({ trig = "fmlit", desc = "Literature note frontmatter" }, {
    t({ "---", "type: literature", "authors:", "  - " }), i(1, "Author Name"),
    t({ "", "year: " }), i(2, "2025"),
    t({ "", "journal: " }), i(3, "Journal Name"),
    t({ "", "doi: " }), i(4, "10.xxxx/xxxxx"),
    t({ "", "tags:", "  - literature", "---", "" }),
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
  -- Footnote snippets
  ---------------------------------------------------------------------------

  s({ trig = "fnr", desc = "Footnote reference [^N]" }, {
    t("[^"),
    f(function() return tostring(footnotes.next_id()) end),
    t("]"),
  }),

  s({ trig = "fnd", desc = "Footnote definition [^N]: ..." }, {
    t("[^"),
    f(function() return tostring(footnotes.next_id()) end),
    t("]: "),
    i(1, "definition"),
  }),

  s({ trig = "fn", desc = "Footnote reference [^id]" }, {
    t("[^"),
    i(1, "id"),
    t("]"),
  }),

  s({ trig = "fndef", desc = "Footnote definition [^id]: ..." }, {
    t("[^"),
    i(1, "id"),
    t("]: "),
    i(2, "definition"),
  }),

  s({ trig = "fnp", desc = "Paired footnote: reference + definition" }, {
    t("[^"),
    i(1, "1"),
    t("]"),
    t({ "", "", "[^" }),
    rep(1),
    t("]: "),
    i(2, "definition"),
  }),

  s({ trig = "fnpa", desc = "Paired footnote (auto-numbered): reference + definition" }, {
    t("[^"),
    f(function() return tostring(footnotes.next_id()) end),
    t({ "]", "", "[^" }),
    f(function() return tostring(footnotes.next_id()) end),
    t("]: "),
    i(1, "definition"),
  }),

  s({ trig = "fni", desc = "Inline footnote ^[...]" }, {
    t("^["),
    i(1, "footnote text"),
    t("]"),
  }),

  ---------------------------------------------------------------------------
  -- Table snippet
  ---------------------------------------------------------------------------

  s({ trig = "tbl", desc = "Markdown table" }, {
    t("| "), i(1, "Header 1"), t(" | "), i(2, "Header 2"), t({ " |", "" }),
    t({ "| --- | --- |", "" }),
    t("| "), i(3, "Cell"), t(" | "), i(4, "Cell"), t({ " |", "" }),
  }),

  s({ trig = "table", desc = "Markdown table (3 columns)" }, {
    t("| "), i(1, "Header 1"), t(" | "), i(2, "Header 2"), t(" | "), i(3, "Header 3"), t({ " |", "" }),
    t({ "| --- | --- | --- |", "" }),
    t("| "), i(4, "Cell"), t(" | "), i(5, "Cell"), t(" | "), i(6, "Cell"), t({ " |", "" }),
  }),

  ---------------------------------------------------------------------------
  -- Dynamic table snippet (dimension-based)
  ---------------------------------------------------------------------------

  s({ trig = "tblx", desc = "Markdown table (dynamic: type CxR then Tab)" }, {
    i(1, "3x2"),
    d(2, function(args)
      local table_gen = require("andrew.utils.table-gen")
      local dim = args[1][1] or "3x2"
      local cols, rows = table_gen.parse_dimensions(dim)
      if not cols then
        cols, rows = 3, 2
      end
      local lines = table_gen.generate(cols, rows)

      -- Build text nodes: first line starts on a new line after the dimension
      local text_lines = { "" } -- blank line after dimension text
      for _, line in ipairs(lines) do
        text_lines[#text_lines + 1] = line
      end

      return sn(nil, {
        t(text_lines),
      })
    end, { 1 }),
  }),

  ---------------------------------------------------------------------------
  -- Heading snippets
  ---------------------------------------------------------------------------

  s({ trig = "h2", desc = "Level 2 heading" }, {
    t("## "), i(1, "Heading"),
    t({ "", "" }),
  }),

  s({ trig = "h3", desc = "Level 3 heading" }, {
    t("### "), i(1, "Heading"),
    t({ "", "" }),
  }),

  s({ trig = "h4", desc = "Level 4 heading" }, {
    t("#### "), i(1, "Heading"),
    t({ "", "" }),
  }),

  ---------------------------------------------------------------------------
  -- Meeting Notes template snippet
  ---------------------------------------------------------------------------

  s({ trig = ";meeting-full", desc = "Meeting notes template (full)" }, {
    t({ "---", "type: meeting", "date: " }), i(1, "YYYY-MM-DD"),
    t({ "", "attendees:", "  - '" }), i(2, "[[Name]]"), t("'"),
    t({ "", "parent-project: " }), i(3),
    t({ "", "tags:", "  - meeting", "---", "", "# Meeting -- " }), i(4, "Title"),
    t({ "", "", "**Attendees:** " }), i(5, "[[Name]]"),
    t({ "", "**Project:** " }), i(6, "[[Project]]"),
    t({ "", "", "---", "", "## Agenda", "", "1. " }), i(7, "Item"),
    t({ "", "", "## Discussion Notes", "", "" }), i(8),
    t({ "", "", "## Feedback / Guidance", "", "> [!important] Specific feedback on drafts, methods, direction", "", "- " }), i(9),
    t({ "", "", "## Action Items", "", "- [ ] " }), i(10),
    t({ "", "- [ ] " }), i(11),
    t({ "", "", "## Decisions Made", "", "| Decision | Rationale |", "| -------- | --------- |", "| " }), i(12), t(" | "), i(13), t({ " |", "" }),
    t({ "", "## Follow-Up", "", "- **Next meeting:** " }), i(14),
    t({ "", "- **Items to prepare:** " }), i(15),
    t({ "", "", "## Notes", "" }),
  }),

  s({ trig = ";meeting-quick", desc = "Quick meeting notes (attendees + actions)" }, {
    t("## Meeting -- "), i(1, "Title"),
    t({ "", "", "**Date:** " }), i(2, "YYYY-MM-DD"),
    t({ "", "**Attendees:** " }), i(3, "[[Name]]"),
    t({ "", "", "### Agenda", "", "1. " }), i(4),
    t({ "", "", "### Action Items", "", "- [ ] " }), i(5),
    t({ "", "- [ ] " }), i(6),
    t({ "", "", "### Decisions", "", "- " }), i(7),
    t({ "", "", "### Notes", "", "" }), i(8),
    t({ "", "" }),
  }),

  ---------------------------------------------------------------------------
  -- Research Article template snippet
  ---------------------------------------------------------------------------

  s({ trig = ";research-article", desc = "Research article reading note" }, {
    t({ "---", "type: literature", 'title: "' }), i(1, "Paper Title"), t('"'),
    t({ "", 'authors: "' }), i(2, "Author(s)"), t('"'),
    t({ "", "year: " }), i(3, "2025"),
    t({ "", 'journal: "' }), i(4, "Journal Name"), t('"'),
    t({ "", "doi: " }), i(5),
    t({ "", "date_read: " }), i(6, "YYYY-MM-DD"),
    t({ "", "rating: /5" }),
    t({ "", "tags:", "  - lit", "---", "" }),
    t({ "", "# " }), i(7, "Authors"), t(" ("), i(8, "Year"), t(") -- "), i(9, "Title"),
    t({ "", "", "> [!cite] Citation", "> " }), i(10, "Full citation here"),
    t({ "", "", "---", "" }),
    t({ "", "## Core Claim / Thesis", "", "> [!summary]", "> " }), i(11),
    t({ "", "", "## Key Results", "", "1. " }), i(12),
    t({ "", "", "## Methodology", "", "- **Simulation / Experimental approach:** " }), i(13),
    t({ "", "- **Potential / Material:** " }), i(14),
    t({ "", "- **Key parameters:** " }), i(15),
    t({ "", "- **Boundary conditions:** " }), i(16),
    t({ "", "", "## Relevance to My Work", "", "> [!important] Why does this paper matter for my research?", "> " }), i(17),
    t({ "", "", "### Points of Agreement", "", "- " }), i(18),
    t({ "", "", "### Points of Difference", "", "- " }), i(19),
    t({ "", "", "### Gaps / Opportunities", "", "> [!tip] What didn't they do that I can?", "> " }), i(20),
    t({ "", "", "## Keywords / Methods", "", "- " }), i(21),
    t({ "", "", "## Questions This Raises", "", "- [ ] " }), i(22),
    t({ "", "", "## Related Papers", "", "- [[" }), i(23), t("]]"),
    t({ "", "", "## Notes", "" }),
  }),

  s({ trig = ";research-quick", desc = "Quick research article note" }, {
    t("## "), i(1, "Authors"), t(" ("), i(2, "Year"), t(") -- "), i(3, "Title"),
    t({ "", "", "**Journal:** " }), i(4),
    t({ "", "**DOI:** " }), i(5),
    t({ "", "", "### Key Findings", "", "1. " }), i(6),
    t({ "", "", "### Relevance", "", "- " }), i(7),
    t({ "", "", "### Methods of Interest", "", "- " }), i(8),
    t({ "", "", "### Notes", "", "" }), i(9),
    t({ "", "" }),
  }),

  ---------------------------------------------------------------------------
  -- Template Section Snippets
  -- Convention: ;templatename-sectionname
  ---------------------------------------------------------------------------

  -- =========================================================================
  -- DAILY LOG sections
  -- =========================================================================

  s({ trig = ";dailylog-focus", desc = "Daily Log: Today's Focus section" }, {
    t({ "### Today's Focus", "", "> [!target] The single biggest task to complete today. Link to its parent project.", "", "- [ ]", "" }),
  }),

  s({ trig = ";dailylog-priorities", desc = "Daily Log: Other Priorities section" }, {
    t({ "### Other Priorities", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "- [ ] " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-worklog", desc = "Daily Log: Work Log section" }, {
    t({ "## Work Log", "", "> Add an entry for each work block. Include the time range, project, and what you did.", "" }),
    t({ "", "- **__:__ - __:__** | " }), i(1),
    t({ "", "- **__:__ - __:__** | " }), i(2),
    t({ "", "- **__:__ - __:__** | " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-scratchpad", desc = "Daily Log: Scratchpad section" }, {
    t({ "## Scratchpad", "", "> Fleeting thoughts, ideas, links, questions. Process into proper notes later.", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-completed", desc = "Daily Log: Completed Today section" }, {
    t({ "### Completed Today", "", "- [x] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-blockers", desc = "Daily Log: Blockers section" }, {
    t({ "### Blockers & Open Questions", "", "> [!warning] What's preventing progress? What needs to be resolved?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-reflection", desc = "Daily Log: Reflection section" }, {
    t({ "### Reflection", "", "> One thing I learned, one decision I made, or one thing that clicked.", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";dailylog-tomorrow", desc = "Daily Log: Tomorrow's Priorities section" }, {
    t({ "### Tomorrow's Priorities", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "- [ ] " }), i(3),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- TASK sections
  -- =========================================================================

  s({ trig = ";task-objective", desc = "Task: Objective section" }, {
    t({ '## Objective', '', '> [!abstract] What does "done" look like for this task?', '>', '', "" }),
  }),

  s({ trig = ";task-subtasks", desc = "Task: Subtasks section" }, {
    t({ "## Subtasks", "", "- [ ] **[due:: ]** : [priority:: ] : " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";task-context", desc = "Task: Context & Dependencies section" }, {
    t({ "## Context & Dependencies", "", "> [!info] What prerequisite work, resources, or people does this depend on?", "" }),
    t({ "", "- **Blocked by:** " }), i(1),
    t({ "", "- **Related notes:** [[" }), i(2), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";task-approach", desc = "Task: Approach section" }, {
    t({ "## Approach", "", "> [!tip] How will you tackle this? Key steps or strategy.", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";task-log", desc = "Task: Log entry" }, {
    t("### "), i(1, "YYYY-MM-DD"),
    t({ "", "- " }), i(2, "Entry"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- MEETING sections
  -- =========================================================================

  s({ trig = ";meeting-agenda", desc = "Meeting: Agenda section" }, {
    t({ "## Agenda", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";meeting-discussion", desc = "Meeting: Discussion Notes section" }, {
    t({ "## Discussion Notes", "", "" }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";meeting-feedback", desc = "Meeting: Feedback / Guidance section" }, {
    t({ "## Feedback / Guidance", "", "> [!important] Specific feedback on drafts, methods, direction", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";meeting-actions", desc = "Meeting: Action Items section" }, {
    t({ "## Action Items", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "" }),
  }),

  s({ trig = ";meeting-decisions", desc = "Meeting: Decisions Made section" }, {
    t({ "## Decisions Made", "", "| Decision | Rationale |", "| -------- | --------- |", "| " }), i(1), t(" | "), i(2), t({ " |", "" }),
  }),

  s({ trig = ";meeting-followup", desc = "Meeting: Follow-Up section" }, {
    t({ "## Follow-Up", "", "- **Next meeting:** " }), i(1),
    t({ "", "- **Items to prepare:** " }), i(2),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- CONCEPT sections
  -- =========================================================================

  s({ trig = ";concept-coreidea", desc = "Concept: Core Idea section" }, {
    t({ "## Core Idea", "", "> [!abstract] State the concept in 2-3 sentences. If you can't, it might need to be split into multiple notes.", ">", "", "" }),
  }),

  s({ trig = ";concept-explanation", desc = "Concept: Explanation section" }, {
    t({ "## Explanation", "", "" }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";concept-evidence", desc = "Concept: Evidence / Support section" }, {
    t({ "## Evidence / Support", "", "> [!check] What observations, data, or literature support this idea?", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";concept-counterpoints", desc = "Concept: Counterpoints / Limitations section" }, {
    t({ "## Counterpoints / Limitations", "", "> [!warning] Where does this idea break down or not apply?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";concept-connections", desc = "Concept: Connections section" }, {
    t({ "## Connections", "", "> [!link] How does this relate to other concepts in your vault?", "" }),
    t({ "", "### Related Concepts", "", "- [[" }), i(1), t("]]"),
    t({ "", "", "### Relevant Methods", "", "- [[" }), i(2), t("]]"),
    t({ "", "", "### Projects Where This Applies", "", "- [[" }), i(3), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";concept-origin", desc = "Concept: Origin section" }, {
    t({ "## Origin", "", "> Where did this idea first come up?", "", "- First noted in: [[" }), i(1), t("]]"),
    t({ "", "- Triggered by: " }), i(2),
    t({ "", "" }),
  }),

  s({ trig = ";concept-questions", desc = "Concept: Open Questions section" }, {
    t({ "## Open Questions", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- LITERATURE sections
  -- =========================================================================

  s({ trig = ";literature-claim", desc = "Literature: Core Claim / Thesis section" }, {
    t({ "## Core Claim / Thesis", "", "> [!summary]", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-results", desc = "Literature: Key Results section" }, {
    t({ "## Key Results", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-methodology", desc = "Literature: Methodology section" }, {
    t({ "## Methodology", "" }),
    t({ "", "- **Simulation / Experimental approach:** " }), i(1),
    t({ "", "- **Potential / Material:** " }), i(2),
    t({ "", "- **Key parameters:** " }), i(3),
    t({ "", "- **Boundary conditions:** " }), i(4),
    t({ "", "" }),
  }),

  s({ trig = ";literature-relevance", desc = "Literature: Relevance to My Work section" }, {
    t({ "## Relevance to My Work", "", "> [!important] Why does this paper matter for my research?", "> " }), i(1),
    t({ "", "", "### Points of Agreement", "", "- " }), i(2),
    t({ "", "", "### Points of Difference", "", "- " }), i(3),
    t({ "", "", "### Gaps / Opportunities", "", "> [!tip] What didn't they do that I can?", "> " }), i(4),
    t({ "", "" }),
  }),

  s({ trig = ";literature-figures", desc = "Literature: Figures Worth Referencing section" }, {
    t({ "## Figures Worth Referencing", "", "| Their Figure | What It Shows | Comparison to My Work |", "| ------------ | ------------- | --------------------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";literature-methods", desc = "Literature: Methods Worth Noting section" }, {
    t({ "## Methods Worth Noting", "", "> [!warning] Methodological choices to be aware of (thermostat, boundary conditions, filtering, etc.)", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-questions", desc = "Literature: Questions This Raises section" }, {
    t({ "## Questions This Raises", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-quotes", desc = "Literature: Quotes / Key Passages section" }, {
    t({ "## Quotes / Key Passages", "", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";literature-related", desc = "Literature: Related Papers section" }, {
    t({ "## Related Papers", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- METHODOLOGY sections
  -- =========================================================================

  s({ trig = ";methodology-purpose", desc = "Methodology: Purpose section" }, {
    t({ "## Purpose", "", "> [!abstract] What problem does this method solve?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";methodology-approach", desc = "Methodology: Approach section" }, {
    t({ "## Approach", "" }),
    t({ "", "### Description", "", "" }), i(1),
    t({ "", "", "### Implementation Details", "" }),
    t({ "", "- **Software / Tool:** " }), i(2),
    t({ "", "- **Key commands / functions:** " }), i(3),
    t({ "", "- **Language / Scripts:** [[" }), i(4), t("]]"),
    t({ "", "", "### Algorithm / Procedure", "", "1. " }), i(5),
    t({ "", "", "### Code Snippet", "", "```", "# Key implementation detail", "```", "" }),
  }),

  s({ trig = ";methodology-params", desc = "Methodology: Parameters & Configuration section" }, {
    t({ "## Parameters & Configuration", "", "| Parameter | Value | Justification |", "| --------- | ----- | ------------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";methodology-validation", desc = "Methodology: Validation section" }, {
    t({ "## Validation", "", "> [!check] How was this method validated?", "" }),
    t({ "", "### Validated Against", "", "- [[" }), i(1), t("]]"),
    t({ "", "", "### Validation Results", "", "- " }), i(2),
    t({ "", "" }),
  }),

  s({ trig = ";methodology-limitations", desc = "Methodology: Known Limitations section" }, {
    t({ "## Known Limitations", "", "> [!warning]", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";methodology-comparison", desc = "Methodology: Comparison to Alternatives section" }, {
    t({ "## Comparison to Alternatives", "", "| Method | Pros | Cons | When to Use |", "| ------ | ---- | ---- | ----------- |", "| **This method** | " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
    t("| [["), i(4), t("]] | "), i(5), t(" | "), i(6), t(" | "), i(7), t({ " |", "" }),
  }),

  s({ trig = ";methodology-usedin", desc = "Methodology: Used In section" }, {
    t({ "## Used In", "", "> [!info] Simulations and papers that use this method", "" }),
    t({ "", "### Simulations", "", "- [[" }), i(1), t("]]"),
    t({ "", "", "### Papers / Drafts", "", "- [[" }), i(2), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";methodology-changelog", desc = "Methodology: Changelog section" }, {
    t({ "## Changelog", "", "| Date | Change | Reason |", "| ---- | ------ | ------ |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  -- =========================================================================
  -- SIMULATION sections
  -- =========================================================================

  s({ trig = ";simulation-purpose", desc = "Simulation: Purpose section" }, {
    t({ "## Purpose", "", "> [!abstract] What question is this run trying to answer?", ">", "", "" }),
  }),

  s({ trig = ";simulation-params", desc = "Simulation: Parameters table" }, {
    t({ "## Parameters", "", "| Parameter | Value |", "| --------- | ----- |", "| Software | " }), i(1),
    t({ " |", "| Potential | " }), i(2),
    t({ " |", "| Material | " }), i(3),
    t({ " |", "| Sample geometry | " }), i(4),
    t({ " |", "| Domain size | " }), i(5),
    t({ " |", "| Timestep | " }), i(6),
    t({ " |", "| Boundary conditions | " }), i(7),
    t({ " |", "" }),
  }),

  s({ trig = ";simulation-inputfiles", desc = "Simulation: Input Files section" }, {
    t({ "## Input Files", "", "- **Script:** " }), i(1),
    t({ "", "- **Data file:** " }), i(2),
    t({ "", "- **Potential file:** " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";simulation-methods", desc = "Simulation: Methods Used section" }, {
    t({ "## Methods Used", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";simulation-results", desc = "Simulation: Results section" }, {
    t({ "## Results", "", "> [!success] Key findings", "" }),
    t({ "", "### Summary", "", "" }), i(1),
    t({ "", "", "### Key Metrics", "", "| Metric | Value | Notes |", "| ------ | ----- | ----- |", "| " }), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
    t({ "", "### Figures", "", "> Embed key output plots here", "", "" }),
  }),

  s({ trig = ";simulation-comparison", desc = "Simulation: Comparison to Previous Runs section" }, {
    t({ "## Comparison to Previous Runs", "", "| Run | Key Difference | Result Difference |", "| --- | -------------- | ----------------- |", "| [[" }), i(1), t("]] | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";simulation-issues", desc = "Simulation: Issues / Troubleshooting section" }, {
    t({ "## Issues / Troubleshooting", "", "> [!bug] Problems encountered during this run", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";simulation-feedsinto", desc = "Simulation: Feeds Into section" }, {
    t({ "## Feeds Into", "", "> [!info] Where do these results go?", "" }),
    t({ "", "- **Draft:** [[" }), i(1), t("]]"),
    t({ "", "- **Figure(s):** " }), i(2),
    t({ "", "- **Analysis:** [[" }), i(3), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";simulation-postprocess", desc = "Simulation: Post-Processing section" }, {
    t({ "## Post-Processing", "", "- [ ] Data extracted", "- [ ] Plots generated", "- [ ] Results documented", "- [ ] Compared against previous runs", "" }),
  }),

  s({ trig = ";simulation-figures", desc = "Simulation: Figures subsection" }, {
    t({ "### Figures", "", "> Embed key output plots here", "", "![[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- ANALYSIS sections
  -- =========================================================================

  s({ trig = ";analysis-objective", desc = "Analysis: Objective section" }, {
    t({ "## Objective", "", "> [!abstract] What question does this analysis answer?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-runs", desc = "Analysis: Runs Compared section" }, {
    t({ "## Runs Compared", "", "| Simulation | Key Variable | Relevant Output |", "| ---------- | ------------ | --------------- |", "| [[" }), i(1), t("]] | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";analysis-methods", desc = "Analysis: Methods / Approach section" }, {
    t({ "## Methods / Approach", "", "> [!info] How was this analysis performed?", "" }),
    t({ "", "- **Tools used:** " }), i(1),
    t({ "", "- **Scripts:** [[" }), i(2), t("]]"),
    t({ "", "- **Post-processing steps:**", "", "1. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-results", desc = "Analysis: Results section" }, {
    t({ "## Results", "", "### Findings", "", "" }), i(1),
    t({ "", "", "### Key Data", "", "| Condition | Metric 1 | Metric 2 | Notes |", "| --------- | -------- | -------- | ----- |", "| " }), i(2), t(" | "), i(3), t(" | "), i(4), t(" | "), i(5), t({ " |", "" }),
    t({ "", "### Figures", "", "> Embed or link key plots", "> `![[]]`", "" }),
  }),

  s({ trig = ";analysis-interpretation", desc = "Analysis: Interpretation section" }, {
    t({ "## Interpretation", "", "> [!tip] What do these results mean physically?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-litcompare", desc = "Analysis: Comparison to Literature section" }, {
    t({ "## Comparison to Literature", "", "| Source | Their Result | My Result | Agreement? |", "| ------ | ------------ | --------- | ---------- |", "| [[" }), i(1), t("]] | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";analysis-implications", desc = "Analysis: Implications for Paper section" }, {
    t({ "## Implications for Paper", "", "> [!important] How does this shape the narrative?" }),
    t({ "", "", "- **Section affected:** " }), i(1),
    t({ "", "- **Figure(s) generated:** " }), i(2),
    t({ "", "- **Key claim supported:** " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-followup", desc = "Analysis: Follow-Up Work Needed section" }, {
    t({ "## Follow-Up Work Needed", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";analysis-feedsinto", desc = "Analysis: Feeds Into section" }, {
    t({ "## Feeds Into", "", "- **Draft:** [[" }), i(1), t("]]"),
    t({ "", "- **Changelog:** [[" }), i(2), t("]]"),
    t({ "", "- **Presentation:** [[" }), i(3), t("]]"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- FINDING sections
  -- =========================================================================

  s({ trig = ";finding-summary", desc = "Finding: Summary section" }, {
    t({ "## Summary", "", "> [!abstract] What was discovered?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";finding-context", desc = "Finding: Context section" }, {
    t({ "## Context", "", "> [!info] What were you doing when this came up?" }),
    t({ "", "", "- **Task / analysis:** " }), i(1),
    t({ "", "- **Simulation run:** [[" }), i(2), t("]]"),
    t({ "", "- **Relevant data:** " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";finding-details", desc = "Finding: Details section" }, {
    t({ "## Details", "", "### Observation", "", "" }), i(1),
    t({ "", "", "### Root Cause", "", "" }), i(2),
    t({ "", "", "### Evidence", "", "| Source | What it shows |", "| ------ | ------------- |", "| [[" }), i(3), t("]] | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";finding-impact", desc = "Finding: Impact section" }, {
    t({ "## Impact", "", "> [!warning] What does this affect?" }),
    t({ "", "", "- **Affected simulations:** " }), i(1),
    t({ "", "- **Affected analyses:** " }), i(2),
    t({ "", "- **Effect on conclusions:** " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";finding-resolution", desc = "Finding: Resolution section" }, {
    t({ "## Resolution", "", "> [!success] What was done to address this?", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";finding-lessons", desc = "Finding: Lessons Learned section" }, {
    t({ "## Lessons Learned", "", "> [!tip] What should be done differently next time?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- CHANGELOG sections
  -- =========================================================================

  s({ trig = ";changelog-summary", desc = "Changelog: Summary section" }, {
    t({ "## Summary", "", "> [!abstract] One-line summary of what this version accomplishes", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";changelog-major", desc = "Changelog: Major Changes section" }, {
    t({ "## Major Changes", "", "### Section-Level Modifications", "", "| Section | Change Type | Description |", "| ------- | ----------- | ----------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
    t({ "", "### Figure Changes", "", "| Figure | Action | Description |", "| ------ | ------ | ----------- |", "| " }), i(4), t(" | "), i(5), t(" | "), i(6), t({ " |", "" }),
  }),

  s({ trig = ";changelog-minor", desc = "Changelog: Minor Changes section" }, {
    t({ "## Minor Changes", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";changelog-motivation", desc = "Changelog: Motivation section" }, {
    t({ "## Motivation", "", "> [!question] Why were these changes made?", "> Sources: advisor feedback, reviewer comments, new data, etc.", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- PRESENTATION sections
  -- =========================================================================

  s({ trig = ";presentation-audience", desc = "Presentation: Audience & Goal section" }, {
    t({ "## Audience & Goal", "", "> [!abstract] Who is this for and what should they walk away understanding?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";presentation-outline", desc = "Presentation: Slide Outline section" }, {
    t({ "## Slide Outline", "", "| # | Slide Title | Content / Key Point | Data Source |", "| - | ----------- | ------------------- | ----------- |", "| 1 | Title slide |  |  |", "| 2 | " }), i(1), t(" | "), i(2), t(" | [["), i(3), t({ "]] |", "" }),
  }),

  s({ trig = ";presentation-talking", desc = "Presentation: Talking Points section" }, {
    t({ "## Talking Points", "", "> [!note] Things to say that aren't on the slides", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";presentation-questions", desc = "Presentation: Anticipated Questions section" }, {
    t({ "## Anticipated Questions", "", "| Question | Prepared Answer |", "| -------- | --------------- |", "| " }), i(1), t(" | "), i(2), t({ " |", "" }),
  }),

  s({ trig = ";presentation-postnotes", desc = "Presentation: Post-Presentation Notes section" }, {
    t({ "## Post-Presentation Notes", "", "> [!people] Feedback received, questions asked, follow-ups needed", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- DRAFT sections
  -- =========================================================================

  s({ trig = ";draft-structure", desc = "Draft: Structure section" }, {
    t({ "## Structure", "", "| Section | Status | Notes |", "| ------- | ------ | ----- |" }),
    t({ "", "| Abstract | " }), i(1), t(" | "), i(2), t(" |"),
    t({ "", "| Introduction | " }), i(3), t(" | "), i(4), t(" |"),
    t({ "", "| Methodology | " }), i(5), t(" | "), i(6), t(" |"),
    t({ "", "| Results | " }), i(7), t(" | "), i(8), t(" |"),
    t({ "", "| Discussion | " }), i(9), t(" | "), i(10), t(" |"),
    t({ "", "| Conclusion | " }), i(11), t(" | "), i(12), t({ " |", "" }),
  }),

  s({ trig = ";draft-figures", desc = "Draft: Figures section" }, {
    t({ "## Figures", "", "| Figure | Source | Description | Status |", "| ------ | ------ | ----------- | ------ |", "| Fig. 1 | [[" }), i(1), t("]] | "), i(2), t({ " | Draft / Final |", "" }),
  }),

  s({ trig = ";draft-feedback", desc = "Draft: Feedback Received section" }, {
    t({ "## Feedback Received", "", "> [!people] Reviewer / advisor comments", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";draft-submission", desc = "Draft: Submission Notes section" }, {
    t({ "## Submission Notes", "", "> [!note] Journal formatting requirements, cover letter status, supplementary materials", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- JOURNAL ENTRY sections
  -- =========================================================================

  s({ trig = ";journal-observations", desc = "Journal: Observations section" }, {
    t({ "## Observations", "", "> [!abstract] What did I notice or learn today?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";journal-worked", desc = "Journal: What Worked section" }, {
    t({ "## What Worked", "", "> [!success] What went well? What should I keep doing?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";journal-challenges", desc = "Journal: Challenges section" }, {
    t({ "## Challenges", "", "> [!warning] What was difficult? What slowed me down?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";journal-questions", desc = "Journal: Open Questions section" }, {
    t({ "## Open Questions", "", "> [!question] What remains unresolved? What should I investigate next?", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- RECURRING TASK sections
  -- =========================================================================

  s({ trig = ";recurring-whatis", desc = "Recurring Task: What This Is section" }, {
    t({ "## What This Is", "", "> [!abstract] What needs to happen, and why does it matter if it's skipped?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";recurring-checklist", desc = "Recurring Task: Checklist section" }, {
    t({ "## Checklist", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "- [ ] " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";recurring-completionlog", desc = "Recurring Task: Completion Log section" }, {
    t({ "## Completion Log", "", "| Date | Notes |", "| ---- | ----- |", "| " }), i(1), t(" | "), i(2), t({ " |", "" }),
  }),

  -- =========================================================================
  -- FINANCIAL SNAPSHOT sections
  -- =========================================================================

  s({ trig = ";financial-networth", desc = "Financial: Net Worth Summary section" }, {
    t({ "## Net Worth Summary", "", "| Category | Amount | Change from Last Period | Notes |", "| -------- | ------ | ----------------------- | ----- |" }),
    t({ "", "| Checking |  |  |  |" }),
    t({ "", "| Savings / Emergency |  |  |  |" }),
    t({ "", "| Retirement (401k/IRA) |  |  |  |" }),
    t({ "", "| Investments |  |  |  |" }),
    t({ "", "| **Total Assets** |  |  |  |" }),
    t({ "", "| Credit Cards |  |  |  |" }),
    t({ "", "| Student Loans |  |  |  |" }),
    t({ "", "| Other Debt |  |  |  |" }),
    t({ "", "| **Total Liabilities** |  |  |  |" }),
    t({ "", "| **Net Worth** |  |  |  |", "" }),
  }),

  s({ trig = ";financial-income", desc = "Financial: Income section" }, {
    t({ "## Income", "", "| Source | Amount | Notes |", "| ------ | ------ | ----- |" }),
    t({ "", "| Stipend / Salary |  |  |" }),
    t({ "", "| Side Income |  |  |" }),
    t({ "", "| Other |  |  |" }),
    t({ "", "| **Total** |  |  |", "" }),
  }),

  s({ trig = ";financial-expenses", desc = "Financial: Expenses Summary section" }, {
    t({ "## Expenses Summary", "", "| Category | Budgeted | Actual | Delta | Notes |", "| -------- | -------- | ------ | ----- | ----- |" }),
    t({ "", "| Housing |  |  |  |  |" }),
    t({ "", "| Transportation |  |  |  |  |" }),
    t({ "", "| Food / Groceries |  |  |  |  |" }),
    t({ "", "| Insurance |  |  |  |  |" }),
    t({ "", "| Subscriptions |  |  |  |  |" }),
    t({ "", "| Health |  |  |  |  |" }),
    t({ "", "| Personal |  |  |  |  |" }),
    t({ "", "| **Total** |  |  |  |  |", "" }),
  }),

  s({ trig = ";financial-goals", desc = "Financial: Goals Progress section" }, {
    t({ "## Goals Progress", "", "| Goal | Target | Current | On Track? |", "| ---- | ------ | ------- | --------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";financial-reflection", desc = "Financial: Reflection section" }, {
    t({ "## Reflection", "", "> [!tip] What went well? What needs to change next period?", "> " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- PROJECT DASHBOARD sections
  -- =========================================================================

  s({ trig = ";project-objective", desc = "Project: Objective section" }, {
    t({ "## Objective", "", '> [!abstract] What is the concrete deliverable and definition of "done"?', "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";project-focus", desc = "Project: Current Focus section" }, {
    t({ "## Current Focus", "", "> [!target] What am I working on right now?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";project-pipeline", desc = "Project: Pipeline Status section" }, {
    t({ "## Pipeline Status", "", "| Stage | Status | Next Action | Blocked By |", "| ----- | ------ | ----------- | ---------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";project-decisionlog", desc = "Project: Decision Log section" }, {
    t({ "## Decision Log", "", "> [!info] Key decisions and their rationale", "", "| Date | Decision | Rationale | Revisit? |", "| ---- | -------- | --------- | -------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";project-resources", desc = "Project: Key Resources section" }, {
    t({ "## Key Resources", "", "> [!info] Links to subfolders, key documents, external tools, repos", "" }),
    t({ "", "- **HPC path:** `" }), i(1), t("`"),
    t({ "", "- **Code repo:** `" }), i(2), t("`"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- AREA DASHBOARD sections
  -- =========================================================================

  s({ trig = ";area-purpose", desc = "Area: Purpose section" }, {
    t({ "## Purpose", "", '> [!abstract] What standard am I maintaining? What does "healthy" look like for this area?', "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";area-status", desc = "Area: Current Status section" }, {
    t({ "## Current Status", "", "> [!target] How is this area doing right now? What needs attention?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";area-deadlines", desc = "Area: Upcoming Deadlines section" }, {
    t({ "## Upcoming Deadlines", "", "| Date | Item | Notes |", "| ---- | ---- | ----- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";area-reviewchecklist", desc = "Area: Review Checklist section" }, {
    t({ "## Review Checklist", "", "> [!check] Run through this list at the review frequency", "" }),
    t({ "", "- [ ] Is the current status accurate?" }),
    t({ "", "- [ ] Are all recurring tasks up to date?" }),
    t({ "", "- [ ] Any upcoming deadlines I'm not tracking?" }),
    t({ "", "- [ ] Any active projects that should be created?" }),
    t({ "", "- [ ] Update `last_reviewed` in frontmatter", "" }),
  }),

  -- =========================================================================
  -- DOMAIN MOC sections
  -- =========================================================================

  s({ trig = ";domain-concepts", desc = "Domain MOC: Core Concepts section" }, {
    t({ "## Core Concepts", "", "> [!info] Foundational ideas and principles", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";domain-subdomains", desc = "Domain MOC: Sub-Domains section" }, {
    t({ "## Sub-Domains", "", "> Narrower areas within this domain", "", "- [[" }), i(1), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";domain-openquestions", desc = "Domain MOC: Open Questions section" }, {
    t({ "## Open Questions", "", "> [!question] Big-picture questions that span individual projects", "", "1. " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";domain-emergingideas", desc = "Domain MOC: Emerging Ideas section" }, {
    t({ "## Emerging Ideas", "", "> [!tip] Ideas that haven't crystallized into concept notes yet", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";domain-resources", desc = "Domain MOC: Resources section" }, {
    t({ "## Resources", "", "> External links, textbooks, course materials, reference documents", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";domain-timeline", desc = "Domain MOC: Timeline / Milestones section" }, {
    t({ "## Timeline / Milestones", "", "> [!calendar] Significant events in your engagement with this domain", "", "| Date | Event |", "| ---- | ----- |", "| " }), i(1), t(" | "), i(2), t({ " |", "" }),
  }),

  -- =========================================================================
  -- PERSON sections
  -- =========================================================================

  s({ trig = ";person-context", desc = "Person: Context section" }, {
    t({ "## Context", "", "> [!info] How do I know this person? What's the working relationship?", "> " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";person-feedback", desc = "Person: Feedback Patterns section" }, {
    t({ "## Feedback Patterns", "", "> [!tip] Recurring themes in their feedback", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";person-preferences", desc = "Person: Preferences & Communication Style section" }, {
    t({ "## Preferences & Communication Style", "", "> How do they prefer to work? What do they care about most?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";person-conversations", desc = "Person: Key Conversations & Decisions section" }, {
    t({ "## Key Conversations & Decisions", "", "| Date | Topic | Outcome |", "| ---- | ----- | ------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  -- =========================================================================
  -- ASSET sections
  -- =========================================================================

  s({ trig = ";asset-details", desc = "Asset: Key Details section" }, {
    t({ "## Key Details", "", "> [!info] Core reference information for this asset", "", "| Field | Value |", "| ----- | ----- |" }),
    t({ "", "| Make / Type | " }), i(1), t(" |"),
    t({ "", "| Model / Description | " }), i(2), t(" |"),
    t({ "", "| Year | " }), i(3), t(" |"),
    t({ "", "| Serial # / VIN / Account # | " }), i(4), t(" |"),
    t({ "", "| Location / Institution | " }), i(5), t(" |"),
    t({ "", "| Contact / Agent | " }), i(6), t({ " |", "" }),
  }),

  s({ trig = ";asset-documents", desc = "Asset: Documents section" }, {
    t({ "## Documents", "", "> [!note] Where are the important documents stored?", "", "| Document | Location | Expiration |", "| -------- | -------- | ---------- |" }),
    t({ "", "| Title / Deed |  |  |" }),
    t({ "", "| Registration |  |  |" }),
    t({ "", "| Warranty |  |  |" }),
    t({ "", "| Insurance Policy |  |  |" }),
    t({ "", "| Manual |  |  |", "" }),
  }),

  s({ trig = ";asset-servicehistory", desc = "Asset: Service / Transaction History section" }, {
    t({ "## Service / Transaction History", "", "| Date | Description | Cost | Provider | Notes |", "| ---- | ----------- | ---- | -------- | ----- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t(" | "), i(5), t({ " |", "" }),
  }),

  s({ trig = ";asset-upcoming", desc = "Asset: Upcoming section" }, {
    t({ "## Upcoming", "", "| Date | Action Needed | Notes |", "| ---- | ------------- | ----- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  -- =========================================================================
  -- WEEKLY REVIEW sections
  -- =========================================================================

  s({ trig = ";weekly-accomplishments", desc = "Weekly: Research Accomplishments section" }, {
    t({ "## Research Accomplishments", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";weekly-personal", desc = "Weekly: Personal / Life Accomplishments section" }, {
    t({ "## Personal / Life Accomplishments", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";weekly-progress", desc = "Weekly: Progress by Project section" }, {
    t({ "## Progress by Project", "", "| Project | Category | What Moved Forward | What Stalled |", "| ------- | -------- | ------------------ | ------------ |", "| [[" }), i(1), t("]] | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";weekly-areas", desc = "Weekly: Areas Check-In section" }, {
    t({ "## Areas Check-In", "", "> [!check] Quick health check on each life area", "", "| Area | Status | Action Needed? |", "| ---- | ------ | -------------- |" }),
    t({ "", "| [[Finance]] |  |  |" }),
    t({ "", "| [[Health & Fitness]] |  |  |" }),
    t({ "", "| [[Career]] |  |  |", "" }),
  }),

  s({ trig = ";weekly-insights", desc = "Weekly: Key Insights section" }, {
    t({ "## Key Insights", "", "> [!tip] Ideas, patterns, or connections that emerged this week", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";weekly-didntwork", desc = "Weekly: What Didn't Work section" }, {
    t({ "## What Didn't Work", "", "> [!warning] Blockers, dead ends, or wasted effort", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";weekly-maintenance", desc = "Weekly: Vault Maintenance section" }, {
    t({ "## Vault Maintenance", "" }),
    t({ "", "- [ ] Process any items in Home quick capture inbox" }),
    t({ "", "- [ ] Review stale project warnings on Home dashboard" }),
    t({ "", "- [ ] Promote any reusable notes out of project folders" }),
    t({ "", "- [ ] Update methodology notes if methods evolved this week" }),
    t({ "", "- [ ] File any loose literature notes into Library" }),
    t({ "", "- [ ] Update `next_due` on any completed recurring tasks", "" }),
  }),

  s({ trig = ";weekly-nextweek", desc = "Weekly: Next Week's Priorities section" }, {
    t({ "## Next Week's Priorities", "", "### Research", "1. " }), i(1),
    t({ "", "", "### Personal", "1. " }), i(2),
    t({ "", "", "### Life Admin", "1. " }), i(3),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- MONTHLY / QUARTERLY / YEARLY REVIEW sections (shared patterns)
  -- =========================================================================

  s({ trig = ";monthly-summary", desc = "Monthly: Summary section" }, {
    t({ "## Monthly Summary", "", "> [!note] High-level summary of the month", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";monthly-goals", desc = "Monthly: Goals for Next Month section" }, {
    t({ "## Goals for Next Month", "", "### Research", "1. " }), i(1),
    t({ "", "", "### Personal", "1. " }), i(2),
    t({ "", "", "### Life Admin", "1. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-overview", desc = "Quarterly: Overview section" }, {
    t({ "## Quarter Overview", "", "> [!note] High-level narrative of the quarter", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-strategic", desc = "Quarterly: Strategic Assessment section" }, {
    t({ "## Strategic Assessment", "", "> [!info] Are you heading in the right direction? What needs to shift?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-okr", desc = "Quarterly: OKR / Goal Progress section" }, {
    t({ "## OKR / Goal Progress", "", "> [!check] Rate progress on each goal: 1 (no progress) to 5 (exceeded)", "", "| Goal | Rating (1-5) | Evidence | Notes |", "| ---- | ------------ | -------- | ----- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t(" | "), i(4), t({ " |", "" }),
  }),

  s({ trig = ";quarterly-wins", desc = "Quarterly: Key Wins section" }, {
    t({ "## Key Wins", "", "> [!tip] The biggest accomplishments of the quarter", "", "1. " }), i(1),
    t({ "", "2. " }), i(2),
    t({ "", "3. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-challenges", desc = "Quarterly: Key Challenges section" }, {
    t({ "## Key Challenges", "", "> [!warning] Biggest obstacles, setbacks, or frustrations", "", "1. " }), i(1),
    t({ "", "2. " }), i(2),
    t({ "", "3. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";quarterly-lessons", desc = "Quarterly: Lessons Learned section" }, {
    t({ "## Lessons Learned", "", "> [!info] What did this quarter teach you?", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-overview", desc = "Yearly: Year Overview section" }, {
    t({ "## Year Overview", "", "> [!note] The year in one paragraph", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-accomplishments", desc = "Yearly: Major Accomplishments section" }, {
    t({ "## Major Accomplishments", "" }),
    t({ "", "### Research", "", "> [!tip] Papers, grants, experiments, discoveries, milestones", "", "1. " }), i(1),
    t({ "", "", "### Personal", "", "> [!tip] Skills, relationships, habits, growth", "", "1. " }), i(2),
    t({ "", "", "### Life", "", "> [!tip] Major life events, purchases, moves, milestones", "", "1. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-lessons", desc = "Yearly: Biggest Lessons section" }, {
    t({ "## Biggest Lessons", "", "> [!info] What did this year teach you?", "", "1. " }), i(1),
    t({ "", "2. " }), i(2),
    t({ "", "3. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-surprises", desc = "Yearly: Biggest Surprises section" }, {
    t({ "## Biggest Surprises", "", "> [!info] What caught you off guard?", "", "1. " }), i(1),
    t({ "", "2. " }), i(2),
    t({ "", "3. " }), i(3),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-different", desc = "Yearly: What I'd Do Differently section" }, {
    t({ "## What I'd Do Differently", "", "> [!warning] Hindsight is 20/20", "", "- " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";yearly-theme", desc = "Yearly: Theme / Word for Next Year section" }, {
    t({ "## Theme / Word for Next Year", "", "> [!target] A single word or phrase to anchor the year ahead", "", "- " }), i(1),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- Generic reusable sections (appear in many templates)
  -- =========================================================================

  s({ trig = ";section-notes", desc = "Generic: Notes section" }, {
    t({ "## Notes", "", "" }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";section-openquestions", desc = "Generic: Open Questions section" }, {
    t({ "## Open Questions", "", "- [ ] " }), i(1),
    t({ "", "" }),
  }),

  s({ trig = ";section-actionitems", desc = "Generic: Action Items section" }, {
    t({ "## Action Items", "", "- [ ] " }), i(1),
    t({ "", "- [ ] " }), i(2),
    t({ "", "" }),
  }),

  s({ trig = ";section-decisionlog", desc = "Generic: Decision Log section" }, {
    t({ "## Decision Log", "", "| Date | Decision | Rationale |", "| ---- | -------- | --------- |", "| " }), i(1), t(" | "), i(2), t(" | "), i(3), t({ " |", "" }),
  }),

  s({ trig = ";section-feedsinto", desc = "Generic: Feeds Into section" }, {
    t({ "## Feeds Into", "", "- **Draft:** [[" }), i(1), t("]]"),
    t({ "", "- **Analysis:** [[" }), i(2), t("]]"),
    t({ "", "- **Presentation:** [[" }), i(3), t("]]"),
    t({ "", "" }),
  }),

  s({ trig = ";section-log", desc = "Generic: Log section with date entry" }, {
    t("## Log"),
    t({ "", "", "### " }), i(1, "YYYY-MM-DD"),
    t({ "", "- " }), i(2, "Entry"),
    t({ "", "" }),
  }),

  -- =========================================================================
  -- Image, HTML, reference link, and misc markdown snippets
  -- =========================================================================

  -- Image link: ![alt](url "title")
  s({ trig = "img", desc = "Image ![alt](url)" }, {
    t("!["), i(1, "alt text"), t("]("), i(2, "url"),
    t(' "'), i(3, "title"), t('")'),
  }),

  -- Image link from clipboard: auto-fills URL from system clipboard
  s({ trig = "imgc", desc = "Image from clipboard ![alt](clipboard)" }, {
    t("!["), i(1, "alt text"), t("]("),
    f(function()
      local clip = vim.fn.getreg("+")
      return vim.trim(clip)
    end),
    t(")"),
  }),

  -- HTML comment (single-line)
  s({ trig = "comment", desc = "HTML comment <!-- -->" }, {
    t("<!-- "), i(1, "comment"), t(" -->"),
  }),

  -- HTML comment block (multi-line)
  s({ trig = "commentblock", desc = "HTML comment block (multi-line)" }, {
    t({ "<!--", "" }), i(1, "comment"), t({ "", "-->" }),
  }),

  -- Reference-style link: [text][id] with definition below
  s({ trig = "reflink", desc = "Reference-style link [text][id] + definition" }, {
    t("["), i(1, "link text"), t("]["), i(2, "ref-id"), t("]"),
    t({ "", "", "[" }), rep(2), t("]: "), i(3, "url"),
  }),

  -- Reference-style image: ![alt][id] with definition below
  s({ trig = "refimg", desc = "Reference-style image ![alt][id] + definition" }, {
    t("!["), i(1, "alt text"), t("]["), i(2, "ref-id"), t("]"),
    t({ "", "", "[" }), rep(2), t("]: "), i(3, "url"), t(' "'), i(4, "title"), t('"'),
  }),

  -- Highlight ==text==
  s({ trig = "hl", desc = "Highlight ==text==" }, {
    t("=="), i(1, "highlighted text"), t("=="),
  }),

  -- Highlight ==text== (alias)
  s({ trig = "mark", desc = "Highlight ==text== (alias)" }, {
    t("=="), i(1, "highlighted text"), t("=="),
  }),

  -- Important highlight ==!text==
  s({ trig = "hl!", desc = "Important highlight ==!text==" }, {
    t("==!"), i(1, "important"), t("=="),
  }),

  -- Question highlight ==?text==
  s({ trig = "hl?", desc = "Question highlight ==?text==" }, {
    t("==?"), i(1, "question"), t("=="),
  }),

  -- Abbreviation *[ABBR]: Full Text
  s({ trig = "abbr", desc = "Abbreviation *[ABBR]: Full Text" }, {
    t("*["), i(1, "ABBR"), t("]: "), i(2, "Full Text"),
  }),

  -- Definition list: term + : definition
  s({ trig = "def", desc = "Definition list (term + definition)" }, {
    i(1, "Term"), t({ "", ": " }), i(2, "Definition"),
  }),

  -- Keyboard key <kbd>key</kbd>
  s({ trig = "kbd", desc = "Keyboard key <kbd>...</kbd>" }, {
    t("<kbd>"), i(1, "key"), t("</kbd>"),
  }),

  -- Keyboard combo <kbd>mod</kbd>+<kbd>key</kbd>
  s({ trig = "kbdc", desc = "Keyboard combo <kbd>mod</kbd>+<kbd>key</kbd>" }, {
    t("<kbd>"), i(1, "Ctrl"), t("</kbd>+<kbd>"), i(2, "key"), t("</kbd>"),
  }),

  -- Collapsible details/summary block
  s({ trig = "details", desc = "Collapsible <details><summary>...</summary>...</details>" }, {
    t({ "<details>", "<summary>" }), i(1, "Click to expand"), t({ "</summary>", "", "" }),
    i(2, "Hidden content here"),
    t({ "", "", "</details>" }),
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
