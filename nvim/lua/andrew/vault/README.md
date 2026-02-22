# Vault — Neovim Obsidian-Compatible Knowledge Management Plugin

A custom Neovim plugin that provides a complete Obsidian-compatible knowledge management system, including structured note templates, a Dataview-compatible query engine, and project/area/domain organization — all without leaving Neovim.

## Architecture

```
lua/andrew/vault/
├── init.lua              # Entry point: keymaps, commands, template dispatch
├── engine.lua            # Core: coroutine I/O, date utilities, file ops, rendering
├── pickers.lua           # UI pickers for projects, areas, domains
├── templates/
│   ├── init.lua          # Template registry (groups all templates)
│   ├── daily_log.lua     # Daily Log
│   ├── weekly_review.lua # Weekly Review
│   ├── task.lua          # Task Note
│   ├── meeting.lua       # Meeting Note
│   ├── simulation.lua    # Simulation Note
│   ├── analysis.lua      # Analysis Note
│   ├── finding.lua       # Finding Note
│   ├── draft.lua         # Draft Note
│   ├── changelog.lua     # Changelog
│   ├── journal.lua       # Journal Entry
│   ├── presentation.lua  # Presentation Note
│   ├── concept.lua       # Concept Note
│   ├── domain_moc.lua    # Domain Map of Content
│   ├── literature.lua    # Literature Note
│   ├── methodology.lua   # Methodology Note
│   ├── person.lua        # Person Note
│   ├── area_dashboard.lua      # Area Dashboard
│   ├── recurring_task.lua      # Recurring Task
│   ├── asset.lua               # Asset Note
│   ├── financial_snapshot.lua  # Financial Snapshot
│   └── project_dashboard.lua   # Project Dashboard
└── query/
    ├── init.lua          # Query entry point: block detection, caching, commands
    ├── api.lua           # Sandboxed Lua environment (dv.* API)
    ├── types.lua         # Date, Duration, Link value types
    ├── parser.lua        # DQL recursive descent parser
    ├── index.lua         # Vault filesystem scanner and indexer
    ├── executor.lua      # DQL query execution engine
    └── render.lua        # Virtual-text result renderer
```

## Vault Root

All notes are stored under:

```
~/Documents/Personal-Vault-Copy-02/
```

Configured in `engine.lua` as `M.vault_path`.

## Vault Directory Structure

```
~/Documents/Personal-Vault-Copy-02/
├── Projects/           # Active projects, each with Dashboard.md
│   └── <ProjectName>/
│       ├── Dashboard.md
│       ├── Tasks/
│       ├── Simulations/
│       ├── Analysis/
│       ├── Meetings/
│       ├── Findings/
│       ├── Drafts/
│       ├── Changelogs/
│       ├── Presentations/
│       └── Journal/
├── Areas/              # Life/work areas (Career, Finance, Health, etc.)
│   └── <AreaName>/
│       ├── Dashboard.md
│       ├── (recurring tasks)
│       └── (assets)
├── Domains/            # Knowledge domains
│   └── <DomainName>/
│       ├── <DomainName>.md   (Map of Content)
│       └── (concept notes)
├── Library/            # Literature notes
├── Methods/            # Methodology notes
├── People/             # Person notes
└── Log/                # Daily logs and weekly reviews
```

## Keybindings

All keybindings are in normal mode under the `<leader>v` prefix.

### Template Quick-Access

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>vn` | New Note | Opens template picker to select any template |
| `<leader>vd` | Daily Log | Creates today's daily log in `Log/YYYY-MM-DD/` |
| `<leader>vw` | Weekly Review | Creates a weekly review in `Log/` |
| `<leader>vt` | Task | Creates a task note under a selected project |
| `<leader>vm` | Meeting | Creates a meeting note (standalone or project-scoped) |
| `<leader>vs` | Simulation | Creates a simulation note (LAMMPS or GEMMS) |
| `<leader>va` | Analysis | Creates an analysis note under a project |
| `<leader>vf` | Finding | Creates a finding note under a project |
| `<leader>vl` | Literature | Creates a literature note in `Library/` |
| `<leader>vp` | Project | Creates a new project dashboard in `Projects/` |
| `<leader>vj` | Journal | Creates a journal entry under a project |
| `<leader>vc` | Concept | Creates a concept note under a domain |

### Query Operations

| Key | Action | Description |
|-----|--------|-------------|
| `<leader>vqr` | Render Query | Executes and renders the query block under the cursor |
| `<leader>vqR` | Render All | Renders all query blocks in the current buffer |
| `<leader>vqc` | Clear Output | Clears rendered output for the block under the cursor |
| `<leader>vqC` | Clear All | Clears all rendered output in the buffer |
| `<leader>vqq` | Toggle | Toggles query output for the block under the cursor |
| `<leader>vqi` | Rebuild Index | Force-rebuilds the vault index |

### User Commands

| Command | Description |
|---------|-------------|
| `:VaultNew` | Create a new note from the template picker |
| `:VaultDaily` | Create today's daily log |
| `:VaultQuery` | Render query block under cursor |
| `:VaultQueryAll` | Render all query blocks in buffer |
| `:VaultQueryClear` | Clear query output under cursor |
| `:VaultQueryClearAll` | Clear all query output in buffer |
| `:VaultQueryToggle` | Toggle query output under cursor |
| `:VaultQueryRebuild` | Force-rebuild the vault index |

## How It Works

### Template System

1. **User triggers a template** via keybinding (e.g., `<leader>vt` for Task).
2. **`engine.run()`** wraps the template execution in a Lua coroutine, enabling async user input via `vim.ui.input()` and `vim.ui.select()`.
3. **The template prompts** for required fields (title, project, status, priority, dates, etc.) using `engine.input()` and `engine.select()`, plus `pickers.project()`, `pickers.area()`, or `pickers.domain()` for organizational context.
4. **Frontmatter and body** are assembled using `engine.render()`, which performs `${variable}` substitution on the template string.
5. **`engine.write_note()`** creates the directory (if needed), writes the `.md` file to the vault, and opens it in the editor.

### Picker System

Pickers scan the vault directory structure to dynamically populate selection lists:

| Picker | Scans | Filter |
|--------|-------|--------|
| `pickers.project()` | `Projects/*/` | Must contain `Dashboard.md` |
| `pickers.project_or_none()` | `Projects/*/` | Same, plus a "None" option |
| `pickers.area()` | `Areas/*/` | Must be a directory |
| `pickers.domain()` | `Domains/*/` | Must be a directory |

### Query Engine

The query engine provides Obsidian Dataview-compatible querying directly in Neovim. It supports two block types:

#### DQL Blocks (Dataview Query Language)

````markdown
```dataview
TABLE status, priority, due
FROM "Projects/MyProject/Tasks"
WHERE status != "Complete"
SORT priority ASC
```
````

**Supported DQL syntax:**

- **Query types:** `TABLE` (with optional `WITHOUT ID`), `LIST`, `TASK`
- **FROM:** folder paths (`"Projects"`), tags (`#tag`), boolean combinations (`"A" OR "B"`, `"A" AND #tag`), negation (`!"Folder"`, `!#tag`)
- **WHERE:** comparisons (`=`, `!=`, `<`, `>`, `<=`, `>=`), boolean logic (`AND`, `OR`, `NOT`), `CONTAINS`, field access (`file.path`, `status`), function calls
- **SORT:** one or more fields with `ASC`/`DESC`
- **GROUP BY:** group by expression with optional `AS` alias
- **FLATTEN:** expand array fields into rows
- **LIMIT:** cap result count

**Built-in functions:** `contains()`, `length()`, `default()`, `choice()`, `date()`, `dur()`, `dateformat()`, `round()`, `min()`, `max()`, `sum()`, `average()`, `lower()`, `upper()`, `split()`, `replace()`, `regexmatch()`, `join()`, `flat()`, `reverse()`, `sort()`, `filter()`, `typeof()`, `number()`, `string()`, `link()`, `nonnull()`, `all()`, `any()`, `none()`, `striptime()`

#### Lua/DataviewJS Blocks

````markdown
```dataviewjs
dv.table({"Name", "Status"}, dv.pages('"Projects"')
  :where(function(p) return p.status == "Active" end)
  :sort("file.name")
  :map(function(p) return {p.file.link, p.status} end))
```
````

**`dv.*` API:**

| Method | Description |
|--------|-------------|
| `dv.pages(source)` | Query pages by folder (`"Folder"`), tag (`#tag`), or boolean expressions |
| `dv.current()` | Get the current file's page object |
| `dv.page(path)` | Get a single page by path or filename |
| `dv.table(headers, rows)` | Render a table |
| `dv.list(items)` | Render a bullet list |
| `dv.paragraph(text)` | Render a text paragraph |
| `dv.header(level, text)` | Render a heading (1–6) |
| `dv.date(str)` | Parse a date (`"today"`, `"2026-02-18"`, etc.) |
| `dv.dur(str)` | Parse a duration (`"7 days"`, `"1 month"`) |
| `dv.file_link(path)` | Create a Link object |
| `dv.compare(a, b)` | Three-way comparator (-1/0/1) |

**PageArray chaining methods:** `.where()`, `.filter()`, `.sort()`, `.map()`, `.flatMap()`, `.limit()`, `.slice()`, `.count()`, `.first()`, `.last()`, `.array()`, `.values()`, `.groupBy()`, `.forEach()`

### Vault Index

The index scans all `.md` files in the vault and extracts:

- **Frontmatter** — YAML key-value pairs between `---` fences
- **Inline fields** — `key:: value`, `[key:: value]`, `(key:: value)` in body text
- **Tags** — from frontmatter `tags:` field and body `#tag` syntax (with hierarchical parent expansion)
- **Wikilinks** — `[[path]]` and `[[path|display]]` for outlinks; inlinks are computed automatically
- **Tasks** — `- [ ] text` and `- [x] text` with inline fields and tags

The index is lazily built on first query and cached for 30 seconds before checking for staleness.

**Skipped directories:** `.obsidian`, `.git`, `.trash`, `node_modules`

### Rendering

Query results are displayed as virtual text (extmarks) directly below the code fence. No buffer modifications are made — output is purely visual.

| Result Type | Rendering |
|-------------|-----------|
| Table | Box-drawing borders (`┌─┬┐│└─┴┘`), header row, max 60-char columns |
| List | Bullet points (`•`) |
| Task List | Grouped by file, `✓` for done, `◯` for open |
| Paragraph | Word-wrapped at 80 characters |
| Header | `#` prefix with heading highlight |
| Error | `✗` symbol with error message |

## Templates Reference

### Logs

| Template | Folder | Type | Key Fields |
|----------|--------|------|------------|
| Daily Log | `Log/{YYYY-MM-DD}` | `log` | date, yesterday/tomorrow nav links, dataview tasks |
| Weekly Review | `Log/{title}` | `log` (subtype: `weekly-review`) | week_of, week_number, dataviewjs aggregation |

### Project Management

| Template | Folder | Type | Key Fields |
|----------|--------|------|------------|
| Project Dashboard | `Projects/{name}/Dashboard` | `project-dashboard` | category, area, status, deadline, target, collaborators |
| Task Note | `Projects/{project}/Tasks/{name}` | `task` | status, priority (1–5), due, parent-project, blocked_by |
| Meeting Note | `Projects/{project}/Meetings/{name}` or standalone | `meeting` | date, attendees, parent-project |
| Simulation Note | `Projects/{project}/Simulations/{name}` | `simulation` | software (LAMMPS/GEMMS), run_id, campaign, hpc_path |
| Analysis Note | `Projects/{project}/Analysis/{name}` | `analysis` | status, parent-project |
| Finding Note | `Projects/{project}/Findings/{name}` | `finding` | status, parent-project |
| Draft Note | `Projects/{project}/Drafts/{name}` | `draft` | version, status, file_location |
| Changelog | `Projects/{project}/Changelogs/{name}` | `changelog` | from_version, to_version, author |
| Journal Entry | `Projects/{project}/Journal/{name}` | `journal-entry` | parent-project |
| Presentation | `Projects/{project}/Presentations/{name}` | `presentation` | event, status, file_location |

### Knowledge Base

| Template | Folder | Type | Key Fields |
|----------|--------|------|------------|
| Concept Note | `Domains/{domain}/{name}` | `concept` | domain, maturity (Seed/Developing/Mature/Evergreen) |
| Domain MOC | `Domains/{domain}/{domain}` | `domain` | domain, dataview queries for projects/methods/lit |
| Literature Note | `Library/{sanitized_title}` | `literature` | authors, year, journal, doi, rating |
| Methodology Note | `Methods/{name}` | `methodology` | method_name, status (Experimental/Validated/Deprecated) |
| Person Note | `People/{name}` | `person` | role, institution, email |

### Areas

| Template | Folder | Type | Key Fields |
|----------|--------|------|------------|
| Area Dashboard | `Areas/{area}/Dashboard` | `area-dashboard` | category, review_frequency |
| Recurring Task | `Areas/{area}/{name}` | `recurring-task` | frequency, next_due |
| Asset Note | `Areas/{area}/{name}` | `asset` | asset_type, acquired, value |
| Financial Snapshot | `Areas/Finance/{period}` | `financial-snapshot` | period, snapshot_type (monthly/quarterly/annual) |

## Task Priority Scale

Used by the Task Note template:

| Priority | Meaning |
|----------|---------|
| 1 | Due today |
| 2 | Due in 2–4 days |
| 3 | Due within 7 days |
| 4 | Due within 30 days |
| 5 | No deadline |

## Simulation Software Support

The Simulation Note template adapts its content based on the selected software:

- **LAMMPS** — Prompts for script name; shows LAMMPS-specific parameter table
- **GEMMS** — Prompts for loading condition; shows GEMMS-specific parameters with conditional sections for Piston Shock, Laser Shock, and TTM/QCGD parameters
