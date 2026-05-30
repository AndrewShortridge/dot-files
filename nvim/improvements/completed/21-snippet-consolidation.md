# 21 — Markdown Snippet Consolidation

## Problem

Markdown snippets are maintained in **two separate formats** that are both loaded simultaneously:

1. **VS Code JSON** — `snippets/markdown.json` (24 snippets), loaded by `luasnip.loaders.from_vscode` via `snippets/package.json`.
2. **LuaSnip Lua** — `luasnippets/markdown.lua` (~200+ snippets), loaded by `luasnip.loaders.from_lua`.

Both are registered in `lua/andrew/plugins/blink-cmp.lua` inside the LuaSnip config:

```lua
-- Load VSCode-style snippets from friendly-snippets
require("luasnip.loaders.from_vscode").lazy_load()
-- Load custom snippets (Modern Fortran style with full keywords)
require("luasnip.loaders.from_vscode").lazy_load({
  paths = { vim.fn.stdpath("config") .. "/snippets" },
})
-- Load Lua snippets (math autosnippets for tex/markdown)
require("luasnip.loaders.from_lua").lazy_load({
  paths = { vim.fn.stdpath("config") .. "/luasnippets" },
})
```

This causes several issues:

1. **Duplicate triggers** — When both files define the same trigger (e.g., `note`, `wl`, `fm`), the completion menu shows two entries. The user must guess which format will expand.
2. **Inconsistent behavior** — JSON snippets use VS Code variable syntax (`$CURRENT_YEAR`) and choice syntax (`${6|ASC,DESC|}`). LuaSnip snippets use native Lua nodes (`choice_node`, `insert_node`). They expand differently.
3. **Maintenance burden** — Adding a new callout or frontmatter snippet requires checking both files. Easy to add in one and forget the other.
4. **LuaSnip is strictly more capable** — The Lua format supports `choice_node`, `function_node`, conditions, dynamic content, and autosnippets. The JSON format cannot do any of these. Every JSON snippet can be expressed in Lua, but not vice versa.

### Current State

| Component | File | Snippet Count | Format |
|-----------|------|---------------|--------|
| VS Code JSON | `snippets/markdown.json` | 24 | VS Code JSON (`$1`, `${1\|a,b\|}`) |
| LuaSnip Lua | `luasnippets/markdown.lua` | ~200+ (explicit) + math snippets | LuaSnip Lua API |
| Package manifest | `snippets/package.json` | Registers `markdown.json` for VS Code loader | JSON |
| Completion config | `lua/andrew/plugins/blink-cmp.lua` | Loads both loaders | Lua |

---

## Goal

1. Consolidate all markdown snippets into `luasnippets/markdown.lua` as the single source of truth.
2. Port any JSON-only snippets to LuaSnip Lua format.
3. Delete `snippets/markdown.json`.
4. Remove `markdown.json` from `snippets/package.json`.
5. Verify blink-cmp completion continues to work for all markdown snippets.

---

## Snippet Comparison Table

The following table maps every snippet in `markdown.json` (JSON) to its equivalent in `markdown.lua` (Lua).

| # | JSON Name | JSON Trigger | Lua Trigger | Match? | Notes |
|---|-----------|-------------|-------------|--------|-------|
| 1 | Callout Note | `note` | `note` | EXACT | JSON uses lowercase `note` type; Lua uses uppercase `NOTE`. Minor output difference. |
| 2 | Callout Tip | `tip` | `tip` | EXACT | Same as above. |
| 3 | Callout Warning | `warning` | `warning` | EXACT | Same as above. |
| 4 | Callout Important | `important` | `important` | EXACT | Same as above. |
| 5 | Callout Info | `info` | `info` | EXACT | Same as above. |
| 6 | Callout Question | `question` | `question` | EXACT | Same as above. |
| 7 | Callout Example | `example` | `example` | EXACT | Same as above. |
| 8 | Callout Abstract | `abstract` | `abstract` | EXACT | Same as above. |
| 9 | Callout Target | `target` | **MISSING** | **NO MATCH** | JSON-only. Not in Lua. Described as "daily logs" callout. |
| 10 | Dataview Table | `dvtable` | `dv` | DIFFERENT TRIGGER | JSON uses `dvtable`; Lua uses `dv`. Lua is shorter but less descriptive. |
| 11 | Dataview List | `dvlist` | `dvl` | DIFFERENT TRIGGER | JSON uses `dvlist`; Lua uses `dvl`. |
| 12 | Dataview Task | `dvtask` | `dvt` | DIFFERENT TRIGGER | JSON uses `dvtask`; Lua uses `dvt`. |
| 13 | Dataview JS | `dvjs` | `dvjs` | DIFFERENT BODY | Same trigger. JSON has full `dv.table()` scaffold; Lua has minimal `// code` placeholder. |
| 14 | Vault Lua Block | `vault` | **MISSING** | **NO MATCH** | JSON-only. `vault` code block with `dv.*` PageArray chaining. Not in Lua. |
| 15 | Frontmatter Basic | `fm` | `fm` | DIFFERENT BODY | JSON includes `date:` field with `$CURRENT_YEAR-$CURRENT_MONTH-$CURRENT_DATE`; Lua has only `type:` and `tags:`. |
| 16 | Frontmatter Task | `fmtask` | **MISSING** | **NO MATCH** | JSON-only. Task frontmatter with status, priority, due, project fields. |
| 17 | Frontmatter Literature | `fmlit` | **MISSING** | **NO MATCH** | JSON-only. Literature frontmatter with authors, year, journal, doi fields. |
| 18 | Task Item | `task` | `task` | DIFFERENT BODY | JSON includes `[due:: date] [priority:: 1]` inline fields; Lua is bare `- [ ] task`. Lua has separate `taskd` for the detailed version. |
| 19 | Task Done | `taskdone` | **MISSING** | **NO MATCH** | JSON-only. `- [x] description` completed task. |
| 20 | Wiki Link | `wl` | `wl` | EXACT | Both produce `[[note]]`. |
| 21 | Wiki Link Aliased | `wla` | `wla` | EXACT | Both produce `[[note\|alias]]`. |
| 22 | Embed | `embed` | `embed` | EXACT | Both produce `![[note]]`. |
| 23 | Heading 2 | `h2` | **MISSING** | **NO MATCH** | JSON-only. `## Heading` with blank line after. |
| 24 | Heading 3 | `h3` | **MISSING** | **NO MATCH** | JSON-only. `### Heading` with blank line after. |
| 25 | Code Block | `cb` | `code` | DIFFERENT TRIGGER | JSON uses `cb`; Lua uses `code` with language choice node. |
| 26 | Table | `table` | `tbl` | DIFFERENT TRIGGER | JSON uses `table` (3 cols); Lua uses `tbl` (2 cols). |

### Summary

| Category | Count |
|----------|-------|
| Exact matches (same trigger, same output) | 5 (`wl`, `wla`, `embed`, + partial callouts) |
| Same trigger, different body | 4 (`fm`, `task`, `dvjs`, callout casing) |
| Different trigger, similar function | 4 (`dvtable`/`dv`, `dvlist`/`dvl`, `cb`/`code`, `table`/`tbl`) |
| **JSON-only (missing from Lua)** | **7** (`target`, `vault`, `fmtask`, `fmlit`, `taskdone`, `h2`, `h3`) |

---

## Migration Plan

### Step 1: Port missing JSON snippets to LuaSnip

Add the following 7 snippets to `luasnippets/markdown.lua`.

#### 1a. Callout Target (`target`)

Add to the callout section, after the existing `callout_snippet("concept", ...)` line:

```lua
-- In the individual callout types block:
callout_snippet("target", "TARGET"),

-- In the collapsed/expanded variants:
callout_collapsed_snippet("target", "TARGET"),
callout_expanded_snippet("target", "TARGET"),
```

Also add `t("TARGET")` to the `callout_type_choices()` function:

```lua
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
    t("TARGET"),     -- <-- ADD
  })
end
```

#### 1b. Vault Lua Block (`vault`)

Add to the Dataview section:

```lua
s({ trig = "vault", desc = "Vault (Lua) code block with dv.* PageArray" }, {
  t({ "```vault", "" }),
  t('dv.table({'), i(1, '"Name", "Status"'), t("}, dv.pages('"),
  i(2, '"folder"'), t({ "')", "" }),
  t('  :where(function(p) return '), i(3, 'p.status ~= "Complete"'), t({ " end)", "" }),
  t('  :sort("'), i(4, "file.name"), t({ '")', "" }),
  t("  :map(function(p) return {p.file.link, "), i(5, "p.status"), t({ "} end))", "" }),
  t({ "```", "" }),
}),
```

#### 1c. Frontmatter Task (`fmtask`)

Add to the frontmatter section, after the existing `fm` snippet:

```lua
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
```

#### 1d. Frontmatter Literature (`fmlit`)

```lua
s({ trig = "fmlit", desc = "Literature note frontmatter" }, {
  t({ "---", "type: literature", "authors:", "  - " }), i(1, "Author Name"),
  t({ "", "year: " }), i(2, "2025"),
  t({ "", "journal: " }), i(3, "Journal Name"),
  t({ "", "doi: " }), i(4, "10.xxxx/xxxxx"),
  t({ "", "tags:", "  - literature", "---", "" }),
}),
```

#### 1e. Task Done (`taskdone`)

Add to the task section:

```lua
s({ trig = "taskdone", desc = "Completed task checkbox" }, {
  t("- [x] "), i(1, "task"),
}),
```

#### 1f. Heading 2 (`h2`)

Add a new headings section:

```lua
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
```

#### 1g. Heading 3 (`h3`)

Included above with `h2`.

### Step 2: Enhance existing Lua snippets with JSON parity

These changes improve existing Lua snippets to cover functionality that was better in the JSON version.

#### 2a. Enrich `fm` snippet with date field

The JSON `fm` included a `date:` line using `$CURRENT_YEAR-$CURRENT_MONTH-$CURRENT_DATE`. LuaSnip can do this with `function_node`:

```lua
local f = require("luasnip").function_node

s({ trig = "fm", desc = "YAML frontmatter" }, {
  t({ "---", "type: " }), i(1, "note"),
  t({ "", "date: " }), f(function() return os.date("%Y-%m-%d") end),
  t({ "", "tags:", "  - " }), i(2, "tag"),
  t({ "", "---", "" }),
}),
```

#### 2b. Enrich `dvjs` snippet with scaffold

The JSON version had a full `dv.table()` scaffold. Consider replacing or adding a separate `dvjs-full`:

```lua
s({ trig = "dvjs-full", desc = "Dataviewjs block with dv.table() scaffold" }, {
  t({ "```dataviewjs", "const pages = dv.pages('" }), i(1, '"folder"'),
  t({ "')", "  .where(p => " }), i(2, 'p.type === "note"'),
  t({ ")", "  .sort(p => " }), i(3, "p.date"),
  t({ ", '" }), i(4, "desc"), t({ "');", "", "dv.table(", "  [" }),
  i(5, '"Name", "Date"'), t({ "],", "  pages.map(p => [p.file.link, " }),
  i(6, "p.date"), t({ "])", ");", "```", "" }),
}),
```

#### 2c. Add `cb` as alias for `code`

To preserve muscle memory for anyone who used the JSON `cb` trigger:

```lua
s({ trig = "cb", desc = "Fenced code block (alias for code)" }, {
  t("```"), i(1, "language"),
  t({ "", "" }), i(2),
  t({ "", "```", "" }),
}),
```

#### 2d. Add `table` as alias for `tbl`

```lua
s({ trig = "table", desc = "Markdown table (3 columns)" }, {
  t("| "), i(1, "Header 1"), t(" | "), i(2, "Header 2"), t(" | "), i(3, "Header 3"), t({ " |", "" }),
  t({ "| --- | --- | --- |", "" }),
  t("| "), i(4, "Cell"), t(" | "), i(5, "Cell"), t(" | "), i(6, "Cell"), t({ " |", "" }),
}),
```

### Step 3: Delete `snippets/markdown.json`

```bash
rm ~/.config/nvim/snippets/markdown.json
```

### Step 4: Remove markdown entry from `snippets/package.json`

**Before:**

```json
{
  "name": "custom-snippets",
  "contributes": {
    "snippets": [
      {
        "language": "fortran",
        "path": "./fortran.json"
      },
      {
        "language": "fortran",
        "path": "./new-snippets.json"
      },
      {
        "language": "markdown",
        "path": "./markdown.json"
      }
    ]
  }
}
```

**After:**

```json
{
  "name": "custom-snippets",
  "contributes": {
    "snippets": [
      {
        "language": "fortran",
        "path": "./fortran.json"
      },
      {
        "language": "fortran",
        "path": "./new-snippets.json"
      }
    ]
  }
}
```

### Step 5: Verify blink-cmp integration

No changes needed to `lua/andrew/plugins/blink-cmp.lua`. The two relevant loader calls remain:

```lua
-- This loads friendly-snippets + Fortran JSON snippets (no longer includes markdown.json)
require("luasnip.loaders.from_vscode").lazy_load()
require("luasnip.loaders.from_vscode").lazy_load({
  paths = { vim.fn.stdpath("config") .. "/snippets" },
})

-- This loads the consolidated markdown.lua (and any other Lua snippet files)
require("luasnip.loaders.from_lua").lazy_load({
  paths = { vim.fn.stdpath("config") .. "/luasnippets" },
})
```

The VS Code loader path stays because it still serves the Fortran JSON snippets. Removing `markdown.json` from `package.json` means the VS Code loader will simply skip it.

---

## Implementation Checklist

- [ ] **Port `target` callout** to `callout_snippet()` + collapsed/expanded variants + choice node
- [ ] **Port `vault` snippet** (Vault Lua code block with `dv.*` PageArray chaining)
- [ ] **Port `fmtask` snippet** (Task frontmatter with choice nodes for status/priority)
- [ ] **Port `fmlit` snippet** (Literature frontmatter with authors, year, journal, doi)
- [ ] **Port `taskdone` snippet** (`- [x]` completed task)
- [ ] **Port `h2` and `h3` snippets** (headings with blank line after)
- [ ] **Enhance `fm` snippet** with `function_node` for auto-date (`os.date("%Y-%m-%d")`)
- [ ] **Add `dvjs-full` snippet** with full `dv.table()` scaffold (preserve simple `dvjs`)
- [ ] **Add `cb` alias** for `code` snippet (backward compatibility)
- [ ] **Add `table` alias** for `tbl` snippet (3-column version matching JSON)
- [ ] **Delete `snippets/markdown.json`**
- [ ] **Update `snippets/package.json`** to remove markdown entry
- [ ] **Restart Neovim and verify:**
  - [ ] All former JSON triggers still work: `note`, `tip`, `warning`, `important`, `info`, `question`, `example`, `abstract`, `target`, `dvtable`/`dv`, `dvlist`/`dvl`, `dvtask`/`dvt`, `dvjs`, `vault`, `fm`, `fmtask`, `fmlit`, `task`, `taskdone`, `wl`, `wla`, `embed`, `h2`, `h3`, `cb`, `table`
  - [ ] No duplicate entries in completion menu for any trigger
  - [ ] Choice nodes work (e.g., `fmtask` status picker, `code` language picker)
  - [ ] Autosnippets still work (`mk`, `dm` for math)
  - [ ] Fortran JSON snippets still load (VS Code loader path unchanged)
  - [ ] `:LuaSnipListAvailable` shows all markdown snippets under one source

---

## Before / After

### Before

```
snippets/
  markdown.json          <-- 24 VS Code JSON markdown snippets
  package.json           <-- registers markdown.json for VS Code loader
  fortran.json           <-- Fortran snippets (unchanged)
  new-snippets.json      <-- Fortran snippets (unchanged)
  ...

luasnippets/
  markdown.lua           <-- ~200+ LuaSnip Lua markdown snippets
```

**Result:** Two sources loaded. Duplicate triggers in completion. Inconsistent behavior.

### After

```
snippets/
  package.json           <-- registers ONLY Fortran snippets
  fortran.json           <-- Fortran snippets (unchanged)
  new-snippets.json      <-- Fortran snippets (unchanged)
  ...
  (markdown.json DELETED)

luasnippets/
  markdown.lua           <-- ~210+ LuaSnip Lua markdown snippets (single source of truth)
```

**Result:** One source. No duplicates. Full LuaSnip feature set (choice nodes, function nodes, autosnippets).

---

## Edge Cases

| Case | Expected Behavior |
|------|-------------------|
| User types `note` in markdown file | Single completion entry from LuaSnip; expands to `> [!NOTE] Title` |
| User types `fm` in markdown file | Single entry; expands with auto-filled date via `os.date()` |
| User types `fmtask` in markdown file | Single entry; choice node for status, priority |
| User types `dvjs` in markdown file | Simple version; `dvjs-full` available for scaffold version |
| User types `cb` in markdown file | Alias expands to ``` block with language placeholder |
| User types `table` in markdown file | 3-column table (JSON parity); `tbl` also available for 2-column |
| User types `target` in markdown file | Callout expands to `> [!TARGET] Title` |
| Fortran file | Fortran JSON snippets still work; no markdown snippets leak |
| Math autosnippets | `mk` and `dm` still trigger in markdown; math snippets merged as before |
| `callout` trigger | Choice node now includes `TARGET` among options |

---

## Risk Assessment

**Risk: Low**

- The JSON snippets are a strict subset of what LuaSnip can express. No functionality is lost.
- The VS Code loader path (`snippets/`) remains for Fortran; only the `package.json` manifest changes.
- `blink-cmp.lua` requires zero changes. The `snippets` source and `preset = "luasnip"` continue to work.
- If any snippet is missed, it can be added to `markdown.lua` without touching any other file.
- Rollback is trivial: restore `markdown.json` and re-add the `package.json` entry.

---

## Dependencies

| Module | How It's Used | Required? |
|--------|-------------|-----------|
| `luasnip` | Snippet engine | Yes |
| `luasnip.loaders.from_lua` | Loads `luasnippets/markdown.lua` | Yes |
| `luasnip.loaders.from_vscode` | Loads Fortran snippets (no longer markdown) | Yes (for Fortran) |
| `blink-cmp` | Completion UI; `snippets` source with `preset = "luasnip"` | Yes |
| `andrew.utils.tex` | Provides math snippet helpers; merged into same file | Yes (existing) |

---

## Key Files Modified

| File | Change |
|------|--------|
| `luasnippets/markdown.lua` | Add 7 new snippets, enhance `fm`, add aliases `cb`/`table`, add `dvjs-full` |
| `snippets/markdown.json` | **Deleted** |
| `snippets/package.json` | Remove `markdown` entry from `contributes.snippets` array |
