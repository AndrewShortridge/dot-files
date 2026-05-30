# 09 — Custom User Templates (Vault-Side `.md` Template Files)

## Problem

The vault template system currently consists of 25 hardcoded Lua template files in `lua/andrew/vault/templates/`. Each template is a Lua module that exports `{ name, run }` and is registered in `templates/init.lua`. Creating a new template requires:

1. Writing a new Lua file under `lua/andrew/vault/templates/`.
2. Adding a `require()` line to `templates/init.lua`.
3. Optionally adding a keybinding in `lua/andrew/vault/init.lua`.
4. Restarting Neovim to pick up the changes.

This workflow is developer-centric — it works well for the plugin author but creates a high barrier for ad-hoc template creation. In practice, users accumulate one-off note structures (lab protocol, code review checklist, sprint retro, recipe, etc.) that do not warrant a full Lua module. Obsidian's Templater plugin solves this by scanning a `templates/` directory in the vault for `.md` files with `{{variable}}` interpolation, making template creation as simple as writing a markdown file.

### Current Architecture Summary

| Component | Role | File |
|-----------|------|------|
| **templates/init.lua** | Static registry — returns a flat list of `require()`'d Lua template modules | `lua/andrew/vault/templates/init.lua` |
| **templates/*.lua** (25 files) | Each exports `{ name, run(engine, pickers) }` — the `run` function collects user input via `engine.input()`/`engine.select()`, builds frontmatter + body strings, and calls `engine.write_note()` | `lua/andrew/vault/templates/*.lua` |
| **init.lua (vault)** | `M.new_note()` iterates the template list, presents a picker, calls `t.run(engine, pickers)` on the selected template; `M.run_template(name)` runs a template by name for direct keybindings | `lua/andrew/vault/init.lua` (lines 8-41) |
| **engine.lua** | Coroutine runtime (`M.run`), UI helpers (`M.input`, `M.select`), date helpers (`M.today`, `M.date_offset`, etc.), template substitution (`M.substitute`/`M.render`), file writing (`M.write_note`), built-in variable registry (`BUILTIN_VARS`), custom variable registry (`M._custom_vars`, `M.register_var`) | `lua/andrew/vault/engine.lua` |
| **config.lua** | `M.template_vars` — date/time format defaults; `M.dirs` — vault directory structure | `lua/andrew/vault/config.lua` (lines 87-91) |
| **pickers.lua** | Project/area/domain pickers used by templates that need interactive selection | `lua/andrew/vault/pickers.lua` |
| **fragments.lua** | Insert-at-cursor template fragments — similar concept but for inline insertion into existing notes, not new file creation | `lua/andrew/vault/fragments.lua` |

### How Templates Work Today

Every Lua template follows the same pattern:

1. **Collect user input** — sequential `engine.input()` and `engine.select()` calls (coroutine-yielding).
2. **Build frontmatter** — string concatenation of YAML fields using collected values.
3. **Build body** — either string concatenation or a `[==[...]==]` long string with `{{variable}}` placeholders, rendered via `engine.render(body_template, vars)`.
4. **Write note** — `engine.write_note(rel_path, content)` creates the file and opens it.

The `engine.substitute()` function (lines 589-618 of engine.lua) already handles:
- `{{date:FORMAT}}` and `{{time:FORMAT}}` — Obsidian-style date/time formatting.
- `{{variable}}` — lookup chain: explicit vars table -> `BUILTIN_VARS` -> `M._custom_vars` -> leave as-is.
- `${variable}` — legacy syntax (backward compat).

Built-in variables (engine.lua lines 536-577): `date`, `time`, `title`, `vault`, `vault_path`, `folder`, `date_long`, `date_weekday`, `week`, `year`, `month`, `day`, `yesterday`, `tomorrow`, `timestamp`.

### Limitations

1. **No user-space templates** — users cannot create templates without writing Lua.
2. **No vault-specific templates** — templates are global across all vaults (defined in plugin code, not in vault directories).
3. **Template list is static** — requires Neovim restart to add/remove templates.
4. **No template metadata** — Lua templates embed their name as `M.name` but have no description, category, or sorting metadata.
5. **No "insert template into existing note"** — fragments cover some of this, but there is no way to insert a user-defined `.md` template at the cursor position.

---

## Goal

Add a user template system that:

1. Scans a configurable `templates/` directory inside each vault for `.md` files.
2. Parses optional YAML frontmatter in each template file for metadata (name, description, destination folder, prompted variables).
3. Renders the template body using the existing `engine.substitute()` pipeline (all `{{variable}}` and `{{date:FORMAT}}` syntax works out of the box).
4. Prompts the user for any variables declared in the template's frontmatter `prompts` field.
5. Merges user templates into the existing template picker alongside Lua templates.
6. Supports "insert at cursor" mode (like fragments) as an alternative to "create new file" mode.
7. Reloads templates dynamically when the templates directory changes (no restart required).
8. Works per-vault — each vault can have its own templates directory with different templates.
9. Provides a `:VaultTemplateEdit` command to open/create template files.
10. Provides a `:VaultTemplateReload` command to force-refresh the template list.

---

## Approach

### Template File Format

User templates are `.md` files in `{vault_path}/templates/` (configurable). The file format uses YAML frontmatter for metadata and the rest of the file as the template body:

```markdown
---
template_name: Lab Protocol
template_desc: Standard lab protocol with safety and procedure sections
template_dest: Projects/{{project}}/Protocols
template_filename: "{{title}}"
template_type: note
prompts:
  - key: title
    prompt: "Protocol title"
  - key: project
    prompt: "Select project"
    type: project
  - key: hazard_level
    prompt: "Hazard level"
    type: select
    options: ["Low", "Medium", "High"]
  - key: safety_officer
    prompt: "Safety officer name"
    default: ""
frontmatter:
  type: protocol
  status: Draft
  tags:
    - protocol
    - lab
---
# {{title}}

**Project:** [[Projects/{{project}}/Dashboard|{{project}}]]
**Hazard Level:** `{{hazard_level}}`
**Safety Officer:** {{safety_officer}}
**Date:** {{date}}

---

## Purpose

> [!abstract] What is this protocol for?
>

## Safety Considerations

> [!warning] Hazards and required PPE
>

## Materials

-

## Procedure

1.

## Notes
```

### Template Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `template_name` | string | Yes | Display name in the picker (defaults to filename without `.md` if absent) |
| `template_desc` | string | No | One-line description shown in picker (format_item) |
| `template_dest` | string | No | Destination directory relative to vault root; supports `{{variable}}` interpolation; defaults to vault root |
| `template_filename` | string | No | Output filename (without `.md`); supports `{{variable}}` interpolation; defaults to `{{title}}` |
| `template_type` | string | No | `"note"` (default, creates new file) or `"insert"` (inserts at cursor like a fragment) |
| `prompts` | list | No | Ordered list of variables to prompt the user for before rendering |
| `frontmatter` | map | No | YAML frontmatter to prepend to the rendered note (supports `{{variable}}` interpolation in values) |

### Prompt Entry Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `key` | string | Yes | Variable name used as `{{key}}` in the template |
| `prompt` | string | Yes | Prompt text shown to the user |
| `type` | string | No | `"input"` (default), `"select"`, `"project"`, `"area"`, `"domain"` |
| `options` | list | No | Options for `type: select` |
| `default` | string | No | Default value for `type: input` |

### Architecture

```
Template resolution flow:

  :VaultNew (or <leader>vtn)
       |
       v
  init.lua:new_note()
       |
       v
  Merge: Lua templates + user templates
       |
       v
  engine.select() — unified picker
       |
       +--[Lua template]---> t.run(engine, pickers)  (existing path)
       |
       +--[User template]--> user_templates.run_user_template(template)
                                |
                                v
                           Parse prompts -> engine.input/select for each
                                |
                                v
                           Build vars table (prompts + builtins)
                                |
                                v
                           Render frontmatter (if template_type == "note")
                                |
                                v
                           engine.substitute(body, vars)
                                |
                                v
                           engine.write_note(dest, content)
                             OR
                           Insert at cursor (template_type == "insert")
```

### Module Organization

A single new module `lua/andrew/vault/user_templates.lua` handles all user template functionality. The existing `templates/init.lua` is modified to merge its static list with the user template list.

---

## Implementation

### Step 1: Add Config Section

**File:** `lua/andrew/vault/config.lua`

Add after the existing `template_vars` section (after line 91):

```lua
-- ---------------------------------------------------------------------------
-- User templates (vault-side .md template files)
-- ---------------------------------------------------------------------------
M.user_templates = {
  enabled = true,
  --- Directory name inside vault root containing user template .md files.
  --- Can be a relative path (e.g., "templates" or ".templates").
  dir = "templates",
  --- Prefix for user templates in the picker to distinguish from built-in Lua templates.
  --- Set to "" to show no prefix.
  picker_prefix = "",
  --- Separator between built-in and user templates in the picker.
  --- Set to nil to disable the separator.
  picker_separator = "--- User Templates ---",
}
```

### Step 2: Create `user_templates.lua`

**File:** `lua/andrew/vault/user_templates.lua`

```lua
local engine = require("andrew.vault.engine")
local config = require("andrew.vault.config")
local pickers = require("andrew.vault.pickers")
local fm_parser = require("andrew.vault.frontmatter_parser")

local M = {}

-- Cache of parsed user templates, keyed by vault_path.
-- Each entry is { templates = {...}, mtime = number }.
---@type table<string, { templates: UserTemplate[], dir_mtime: number }>
M._cache = {}

-- =============================================================================
-- Types
-- =============================================================================

---@class UserTemplatePrompt
---@field key string           Variable name for {{key}} substitution
---@field prompt string        Prompt text shown to user
---@field type? string         "input"|"select"|"project"|"area"|"domain" (default: "input")
---@field options? string[]    Options for type="select"
---@field default? string      Default value for type="input"

---@class UserTemplate
---@field name string                Display name in picker
---@field desc? string               Description shown in picker
---@field dest? string               Destination dir (supports {{var}} interpolation)
---@field filename? string           Output filename (supports {{var}} interpolation)
---@field template_type string       "note" or "insert"
---@field prompts UserTemplatePrompt[]
---@field note_frontmatter? table    YAML frontmatter to prepend to rendered note
---@field body string                Template body (raw markdown with {{var}} placeholders)
---@field source_path string         Absolute path to the .md template file

-- =============================================================================
-- Parsing
-- =============================================================================

--- Parse a user template .md file into a UserTemplate struct.
--- Returns nil if the file cannot be read or has no content.
---@param abs_path string  Absolute path to the template .md file
---@return UserTemplate|nil
function M.parse_template(abs_path)
  local raw = engine.read_file(abs_path)
  if not raw or raw == "" then return nil end

  local basename = vim.fn.fnamemodify(abs_path, ":t:r")

  -- Try to parse YAML frontmatter
  local meta = {}
  local body = raw

  local fm_start, fm_end = raw:find("^%-%-%-\n")
  if fm_start then
    local close_start, close_end = raw:find("\n%-%-%-\n", fm_end)
    if not close_start then
      -- Try end-of-file close (no trailing newline after ---)
      close_start, close_end = raw:find("\n%-%-%-$", fm_end)
    end
    if close_start then
      local yaml_str = raw:sub(fm_end + 1, close_start - 1)
      -- Use vim.json + vim.system for YAML parsing, or a simple key-value parser
      local ok, parsed = pcall(function()
        -- Leverage the frontmatter_parser if it can handle raw YAML strings,
        -- otherwise use a minimal parser for the template-specific fields.
        return M._parse_template_yaml(yaml_str)
      end)
      if ok and parsed then
        meta = parsed
      end
      body = raw:sub(close_end + 1)
      -- Strip leading blank line from body
      body = body:gsub("^\n", "")
    end
  end

  -- Build prompts list
  local prompts = {}
  if meta.prompts and type(meta.prompts) == "table" then
    for _, p in ipairs(meta.prompts) do
      if type(p) == "table" and p.key and p.prompt then
        prompts[#prompts + 1] = {
          key = tostring(p.key),
          prompt = tostring(p.prompt),
          type = p.type and tostring(p.type) or "input",
          options = p.options,
          default = p.default and tostring(p.default) or nil,
        }
      end
    end
  end

  -- If no prompts declared but body contains {{title}}, auto-add a title prompt
  if #prompts == 0 and body:find("{{title}}") then
    prompts[#prompts + 1] = {
      key = "title",
      prompt = "Note title",
      type = "input",
    }
  end

  return {
    name = meta.template_name or basename,
    desc = meta.template_desc,
    dest = meta.template_dest,
    filename = meta.template_filename or "{{title}}",
    template_type = meta.template_type or "note",
    prompts = prompts,
    note_frontmatter = meta.frontmatter,
    body = body,
    source_path = abs_path,
  }
end

--- Minimal YAML parser for template frontmatter.
--- Handles the subset of YAML used in template metadata: scalars, lists, maps.
--- This avoids depending on external YAML libraries.
---@param yaml_str string
---@return table
function M._parse_template_yaml(yaml_str)
  -- Use vim.fn.json_decode after converting simple YAML to JSON via yq,
  -- or fall back to a line-by-line parser.
  --
  -- Strategy: try vim.system with yq first (fast, correct).
  -- If yq is not available, fall back to the simple line parser.

  if vim.fn.executable("yq") == 1 then
    local result = vim.system(
      { "yq", "-o", "json", "." },
      { stdin = yaml_str, text = true }
    ):wait()
    if result.code == 0 and result.stdout and result.stdout ~= "" then
      local ok, parsed = pcall(vim.json.decode, result.stdout)
      if ok and type(parsed) == "table" then
        return parsed
      end
    end
  end

  -- Fallback: minimal line-based parser for flat fields + simple lists
  return M._parse_yaml_simple(yaml_str)
end

--- Simple line-based YAML parser sufficient for template metadata.
--- Handles: scalar fields, simple lists (- item), nested maps (one level).
--- Does NOT handle: multi-line strings, anchors, aliases, complex nesting.
---@param yaml_str string
---@return table
function M._parse_yaml_simple(yaml_str)
  local result = {}
  local current_key = nil
  local current_list = nil
  local current_map = nil
  local current_map_list = nil

  for line in (yaml_str .. "\n"):gmatch("([^\n]*)\n") do
    -- Skip comments and blank lines
    if line:match("^%s*#") or line:match("^%s*$") then
      goto continue
    end

    local indent = #(line:match("^(%s*)") or "")

    -- Top-level key: value
    if indent == 0 then
      -- Close any open list/map
      if current_list and current_key then
        result[current_key] = current_list
        current_list = nil
      end
      if current_map_list and current_key then
        result[current_key] = current_map_list
        current_map_list = nil
      end
      current_map = nil

      local key, value = line:match("^([%w_%-]+):%s*(.*)")
      if key then
        current_key = key
        value = vim.trim(value)
        if value == "" then
          -- Could be start of a list or map — wait for next lines
        elseif value:match("^%[") then
          -- Inline list: [a, b, c]
          local items = {}
          for item in value:gmatch('[^,%[%]"]+') do
            item = vim.trim(item)
            if item ~= "" then
              items[#items + 1] = item
            end
          end
          result[key] = items
          current_key = nil
        else
          -- Remove surrounding quotes if present
          value = value:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          result[key] = value
          current_key = nil
        end
      end
    elseif indent >= 2 and current_key then
      local trimmed = vim.trim(line)

      -- List item with map value (prompts list): "- key: value"
      if trimmed:match("^%- %w") then
        local after_dash = trimmed:sub(3)
        local k, v = after_dash:match("^([%w_%-]+):%s*(.*)")
        if k then
          -- Start of a new map entry in a list
          if not current_map_list then
            current_map_list = {}
          end
          current_map = { [k] = vim.trim(v):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1") }
          current_map_list[#current_map_list + 1] = current_map
        else
          -- Simple list item: "- value"
          if not current_list then
            current_list = {}
          end
          local val = trimmed:sub(3)
          val = val:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          current_list[#current_list + 1] = val
        end
      elseif current_map then
        -- Continuation of map entry (nested key: value under a list item)
        local k, v = trimmed:match("^([%w_%-]+):%s*(.*)")
        if k then
          v = vim.trim(v)
          -- Handle inline list in map value: options: ["a", "b"]
          if v:match("^%[") then
            local items = {}
            for item in v:gmatch('[^,%[%]"]+') do
              item = vim.trim(item)
              if item ~= "" then
                items[#items + 1] = item
              end
            end
            current_map[k] = items
          else
            current_map[k] = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          end
        end
      elseif not current_list then
        -- Could be a nested map (frontmatter field)
        local k, v = trimmed:match("^([%w_%-]+):%s*(.*)")
        if k then
          if not result[current_key] or type(result[current_key]) ~= "table" then
            result[current_key] = {}
          end
          v = vim.trim(v)
          if v == "" then
            -- Sub-list under a map key — not supported in simple parser
          else
            result[current_key][k] = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          end
        elseif trimmed:match("^%- ") then
          -- List under a map key
          if not result[current_key] or type(result[current_key]) ~= "table" then
            result[current_key] = {}
          end
          -- If it's a list (not a map), convert
          if not result[current_key][1] then
            -- Check if it's already a map by looking for string keys
            local has_string_keys = false
            for rk, _ in pairs(result[current_key]) do
              if type(rk) == "string" then has_string_keys = true; break end
            end
            if has_string_keys then
              -- Mixed map + list not supported; skip
              goto continue
            end
          end
          local val = trimmed:sub(3):gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
          result[current_key][#result[current_key] + 1] = val
        end
      end
    end

    ::continue::
  end

  -- Close any trailing list/map
  if current_list and current_key then
    result[current_key] = current_list
  end
  if current_map_list and current_key then
    result[current_key] = current_map_list
  end

  return result
end

-- =============================================================================
-- Template Directory Scanning
-- =============================================================================

--- Get the absolute path to the user templates directory for the current vault.
---@return string
function M.templates_dir()
  return engine.vault_path .. "/" .. config.user_templates.dir
end

--- Scan the vault's templates directory and return parsed UserTemplate objects.
--- Results are cached per vault; cache is invalidated when the directory mtime changes.
---@return UserTemplate[]
function M.list()
  if not config.user_templates.enabled then
    return {}
  end

  local dir = M.templates_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  -- Check directory mtime for cache invalidation
  local stat = vim.uv.fs_stat(dir)
  local dir_mtime = stat and stat.mtime.sec or 0

  local cached = M._cache[engine.vault_path]
  if cached and cached.dir_mtime == dir_mtime then
    return cached.templates
  end

  -- Scan directory for .md files
  local entries = vim.fn.readdir(dir)
  local templates = {}

  for _, name in ipairs(entries) do
    if name:match("%.md$") then
      local abs_path = dir .. "/" .. name
      local tpl = M.parse_template(abs_path)
      if tpl then
        templates[#templates + 1] = tpl
      end
    end
  end

  -- Sort by name
  table.sort(templates, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  M._cache[engine.vault_path] = {
    templates = templates,
    dir_mtime = dir_mtime,
  }

  return templates
end

--- Force-reload the user template cache for the current vault.
function M.reload()
  M._cache[engine.vault_path] = nil
  local templates = M.list()
  vim.notify(
    "Vault: reloaded " .. #templates .. " user template(s) from " .. config.user_templates.dir .. "/",
    vim.log.levels.INFO
  )
end

-- =============================================================================
-- Template Execution
-- =============================================================================

--- Collect prompt values from the user for a user template.
--- Must be called from within engine.run() (coroutine context).
---@param template UserTemplate
---@return table<string, string>|nil  vars table, or nil if user cancelled
function M.collect_prompts(template)
  local vars = {}

  for _, p in ipairs(template.prompts) do
    local value

    if p.type == "select" and p.options then
      value = engine.select(p.options, { prompt = p.prompt })
    elseif p.type == "project" then
      value = pickers.project(engine)
    elseif p.type == "area" then
      value = pickers.area(engine)
    elseif p.type == "domain" then
      value = pickers.domain(engine)
    else
      -- Default: text input
      value = engine.input({ prompt = p.prompt, default = p.default or "" })
    end

    if value == nil then
      -- User cancelled
      return nil
    end

    -- project_or_none returns false for "None" — convert to empty string
    if value == false then
      value = ""
    end

    vars[p.key] = tostring(value)
  end

  return vars
end

--- Build the output frontmatter YAML string from the template's frontmatter map.
--- Supports {{variable}} interpolation in values.
---@param fm_map table  The note_frontmatter field from the template
---@param vars table    Variable values for interpolation
---@return string
function M.build_frontmatter(fm_map, vars)
  local lines = { "---" }

  for key, value in pairs(fm_map) do
    if type(value) == "table" then
      -- List value
      lines[#lines + 1] = key .. ":"
      for _, item in ipairs(value) do
        local rendered = engine.substitute(tostring(item), vars)
        lines[#lines + 1] = "  - " .. rendered
      end
    else
      local rendered = engine.substitute(tostring(value), vars)
      lines[#lines + 1] = key .. ": " .. rendered
    end
  end

  lines[#lines + 1] = "---"
  return table.concat(lines, "\n") .. "\n"
end

--- Run a user template to create a new note.
--- Must be called from within engine.run() (coroutine context).
---@param template UserTemplate
function M.run_note(template)
  local vars = M.collect_prompts(template)
  if not vars then return end

  -- Add built-in date variable for convenience
  vars.date = vars.date or engine.today()

  -- Build frontmatter
  local fm_str = ""
  if template.note_frontmatter then
    fm_str = M.build_frontmatter(template.note_frontmatter, vars)
  end

  -- Render body
  local rendered_body = engine.substitute(template.body, vars)

  -- Compute destination
  local dest_dir = template.dest
  if dest_dir then
    dest_dir = engine.substitute(dest_dir, vars)
  end

  local filename = engine.substitute(template.filename or "{{title}}", vars)
  -- Sanitize filename
  filename = filename:gsub(":", " -"):gsub("/", "-"):gsub("[%*%?|<>]", "")

  local rel_path
  if dest_dir and dest_dir ~= "" then
    rel_path = dest_dir .. "/" .. filename
  else
    rel_path = filename
  end

  -- Combine frontmatter + body
  local content = fm_str
  if fm_str ~= "" and not rendered_body:match("^\n") then
    content = content .. "\n"
  end
  content = content .. rendered_body

  engine.write_note(rel_path, content)
end

--- Run a user template in "insert" mode — inserts rendered body at cursor.
--- Must be called from within engine.run() (coroutine context).
---@param template UserTemplate
function M.run_insert(template)
  local vars = M.collect_prompts(template)
  if not vars then return end

  vars.date = vars.date or engine.today()

  -- Render body
  local rendered = engine.substitute(template.body, vars)

  -- Split into lines and insert at cursor
  local lines = vim.split(rendered, "\n", { plain = true })

  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, row, row, false, lines)

  -- Move cursor to first non-empty inserted line
  for idx, line in ipairs(lines) do
    if line ~= "" then
      vim.api.nvim_win_set_cursor(0, { row + idx, #line })
      break
    end
  end

  vim.notify("Inserted template: " .. template.name, vim.log.levels.INFO)
end

--- Run a user template (dispatches based on template_type).
--- Must be called from within engine.run() (coroutine context).
---@param template UserTemplate
function M.run(template)
  if template.template_type == "insert" then
    M.run_insert(template)
  else
    M.run_note(template)
  end
end

-- =============================================================================
-- Setup
-- =============================================================================

function M.setup()
  vim.api.nvim_create_user_command("VaultTemplateReload", function()
    M.reload()
  end, { desc = "Reload user templates from vault templates directory" })

  vim.api.nvim_create_user_command("VaultTemplateEdit", function(opts)
    local dir = M.templates_dir()
    engine.ensure_dir(dir)

    if opts.args and opts.args ~= "" then
      -- Open specific template
      local path = dir .. "/" .. opts.args
      if not path:match("%.md$") then
        path = path .. ".md"
      end
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    else
      -- List existing templates for selection
      local entries = vim.fn.isdirectory(dir) == 1 and vim.fn.readdir(dir) or {}
      local md_files = vim.tbl_filter(function(name)
        return name:match("%.md$")
      end, entries)

      table.insert(md_files, 1, "+ New template...")

      vim.ui.select(md_files, { prompt = "Edit template" }, function(choice)
        if not choice then return end
        if choice == "+ New template..." then
          vim.ui.input({ prompt = "Template filename (without .md)" }, function(name)
            if name and name ~= "" then
              local path = dir .. "/" .. name .. ".md"
              -- Write a starter template
              local starter = table.concat({
                "---",
                "template_name: " .. name,
                "template_desc: ",
                "template_dest: ",
                "template_filename: \"{{title}}\"",
                "template_type: note",
                "prompts:",
                "  - key: title",
                "    prompt: \"Note title\"",
                "frontmatter:",
                "  type: ",
                "  created: \"{{date}}\"",
                "  tags:",
                "    - ",
                "---",
                "",
                "# {{title}}",
                "",
                "**Created:** {{date}}",
                "",
                "---",
                "",
                "## Notes",
                "",
              }, "\n")
              engine.write_file(path, starter)
              vim.cmd("edit " .. vim.fn.fnameescape(path))
            end
          end)
        else
          vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. choice))
        end
      end)
    end
  end, {
    nargs = "?",
    desc = "Edit or create a user template file",
    complete = function()
      local dir = M.templates_dir()
      if vim.fn.isdirectory(dir) == 0 then return {} end
      local entries = vim.fn.readdir(dir)
      return vim.tbl_filter(function(name)
        return name:match("%.md$")
      end, entries)
    end,
  })

  -- List only user templates (for debugging / browsing)
  vim.api.nvim_create_user_command("VaultTemplateList", function()
    local templates = M.list()
    if #templates == 0 then
      vim.notify("No user templates found in " .. config.user_templates.dir .. "/", vim.log.levels.INFO)
      return
    end
    local lines = { "User Templates (" .. #templates .. ")", string.rep("=", 40) }
    for _, t in ipairs(templates) do
      local desc = t.desc and ("  -- " .. t.desc) or ""
      local type_tag = t.template_type == "insert" and " [insert]" or ""
      lines[#lines + 1] = "  " .. t.name .. type_tag .. desc
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "List user templates from vault templates directory" })
end

return M
```

### Step 3: Modify `templates/init.lua` to Merge User Templates

**File:** `lua/andrew/vault/templates/init.lua`

Replace the entire file:

```lua
-- =============================================================================
-- Vault Template Registry
-- =============================================================================
-- Returns all templates in display order for the picker.
-- Each template exports: { name = "...", run = function(engine, pickers) ... end }
-- User templates from the vault's templates/ directory are appended after
-- built-in Lua templates.

local builtin = {
  -- Logs
  require("andrew.vault.templates.daily_log"),
  require("andrew.vault.templates.weekly_review"),
  require("andrew.vault.templates.monthly_review"),
  require("andrew.vault.templates.quarterly_review"),
  require("andrew.vault.templates.yearly_review"),

  -- Project management
  require("andrew.vault.templates.project_dashboard"),
  require("andrew.vault.templates.simulation"),
  require("andrew.vault.templates.analysis"),
  require("andrew.vault.templates.finding"),
  require("andrew.vault.templates.task"),
  require("andrew.vault.templates.meeting"),
  require("andrew.vault.templates.draft"),
  require("andrew.vault.templates.presentation"),
  require("andrew.vault.templates.changelog"),
  require("andrew.vault.templates.journal"),

  -- Knowledge base
  require("andrew.vault.templates.literature"),
  require("andrew.vault.templates.domain_moc"),
  require("andrew.vault.templates.concept"),
  require("andrew.vault.templates.methodology"),
  require("andrew.vault.templates.person"),

  -- Areas
  require("andrew.vault.templates.area_dashboard"),
  require("andrew.vault.templates.asset"),
  require("andrew.vault.templates.recurring_task"),
  require("andrew.vault.templates.financial_snapshot"),
}

local M = {}

--- Get the full template list: built-in Lua templates + user templates.
--- User templates are wrapped to conform to the { name, run } interface.
---@return table[]
function M.all()
  local config = require("andrew.vault.config")
  local list = {}

  -- Add built-in templates
  for _, t in ipairs(builtin) do
    list[#list + 1] = t
  end

  -- Add user templates if enabled
  if config.user_templates.enabled then
    local ut = require("andrew.vault.user_templates")
    local user_list = ut.list()

    if #user_list > 0 and config.user_templates.picker_separator then
      -- Add a separator entry (not runnable)
      list[#list + 1] = {
        name = config.user_templates.picker_separator,
        _separator = true,
        run = function() end,
      }
    end

    local prefix = config.user_templates.picker_prefix or ""
    for _, tpl in ipairs(user_list) do
      list[#list + 1] = {
        name = prefix .. tpl.name,
        desc = tpl.desc,
        _user_template = tpl,
        run = function(e, p)
          ut.run(tpl)
        end,
      }
    end
  end

  return list
end

-- For backward compatibility, the module is callable as a list.
-- This allows existing code that does `for _, t in ipairs(templates)` to work
-- if it re-indexes on each call.
setmetatable(M, {
  __index = function(self, key)
    if type(key) == "number" then
      return self.all()[key]
    end
  end,
  __len = function(self)
    return #self.all()
  end,
  __ipairs = function(self)
    local list = self.all()
    local i = 0
    return function()
      i = i + 1
      if i <= #list then
        return i, list[i]
      end
    end
  end,
})

return M
```

### Step 4: Update `init.lua` to Use New Template Interface

**File:** `lua/andrew/vault/init.lua`

The `new_note()` function (lines 8-27) currently iterates `templates` as a plain list using `ipairs`. With the metatable approach in Step 3, this continues to work. However, for clarity and to support the description display in the picker, update the function:

Replace lines 7-27:

```lua
--- Open the template picker and run the selected template
function M.new_note()
  engine.run(function()
    local all = templates.all()
    local names = {}
    local desc_map = {}
    for _, t in ipairs(all) do
      names[#names + 1] = t.name
      if t.desc then
        desc_map[t.name] = t.desc
      end
    end

    local choice = engine.select(names, {
      prompt = "New vault note",
      format_item = function(item)
        if desc_map[item] then
          return item .. "  --  " .. desc_map[item]
        end
        return item
      end,
    })
    if not choice then
      return
    end

    for _, t in ipairs(all) do
      if t.name == choice and not t._separator then
        t.run(engine, pickers)
        return
      end
    end
  end)
end
```

Also update `run_template()` (lines 30-41) to use `templates.all()`:

```lua
--- Run a specific template by its name (for direct keybindings)
---@param name string template display name
function M.run_template(name)
  local all = templates.all()
  for _, t in ipairs(all) do
    if t.name == name then
      engine.run(function()
        t.run(engine, pickers)
      end)
      return
    end
  end
  vim.notify("Vault: unknown template '" .. name .. "'", vim.log.levels.ERROR)
end
```

### Step 5: Register User Templates Module in `init.lua`

**File:** `lua/andrew/vault/init.lua`

Add after the existing fragment loading (after line 184, `require("andrew.vault.fragments").setup()`):

```lua
-- Load user templates (vault-side .md templates)
require("andrew.vault.user_templates").setup()
```

### Step 6: Add Filesystem Watcher Integration

The existing filesystem watcher in `engine.lua` (line 929) watches the entire vault root recursively. When a `.md` file changes in the templates directory, the watcher fires the debounced invalidation callback. However, the user templates cache uses directory `mtime` for invalidation, which already handles adds/deletes. For file content changes (editing an existing template), we need to invalidate the user template cache explicitly.

**File:** `lua/andrew/vault/user_templates.lua`

Add to the `setup()` function:

```lua
  -- Register with cache registry for automatic invalidation
  engine.register_cache({
    name = "user_templates",
    module = "andrew.vault.user_templates",
    invalidate = function()
      M._cache = {}
    end,
    invalidate_file = function(abs_path)
      local dir = M.templates_dir()
      if vim.startswith(abs_path, dir) then
        M._cache[engine.vault_path] = nil
      end
    end,
    stats = function()
      local cached = M._cache[engine.vault_path]
      return {
        entries = cached and #cached.templates or 0,
        vault = engine.vault_path,
      }
    end,
  })
```

This plugs into the existing `BufWritePost` and `FileChangedShellPost` autocmds in `init.lua` (lines 254-287) which call `engine.invalidate_caches({ scope = "file", path = bufpath })`. When a template `.md` file is saved, the `invalidate_file` callback clears the user templates cache, so the next `list()` call re-scans.

---

## Edge Cases and Considerations

### 1. Template Frontmatter vs. Note Frontmatter

User template files have their own frontmatter (with `template_name`, `template_dest`, etc.) which is **metadata about the template itself**, not frontmatter for the generated note. The generated note's frontmatter is specified separately in the `frontmatter` field of the template's metadata.

This means:
- The template file's frontmatter is stripped during parsing and never appears in output.
- The `frontmatter` map in the template metadata becomes the output note's frontmatter.
- If a user wants no frontmatter in the output, they simply omit the `frontmatter` field.

### 2. Templates Without Frontmatter

A template `.md` file with no YAML frontmatter is still valid. The entire file becomes the body. The template name defaults to the filename (without `.md`). A `{{title}}` prompt is auto-added if the body contains `{{title}}`.

Example — a file named `Quick Note.md` with content:
```markdown
# {{title}}

{{date}}

---

## Notes
```
This renders as a template named "Quick Note" that prompts for a title, then creates a file with that title and today's date.

### 3. Filename Sanitization

The `template_filename` field is interpolated and then sanitized using the same rules as the existing `literature.lua` template (line 107): colons become ` -`, slashes become `-`, and `*?|<>` characters are removed. This prevents filesystem errors from user-entered titles.

### 4. Name Collisions Between Built-in and User Templates

If a user template has the same name as a built-in Lua template, both appear in the picker. The built-in template appears first (it is higher in the list). The `picker_prefix` config option can be used to disambiguate (e.g., setting it to a custom marker). Alternatively, the `picker_separator` visually divides the two sections.

### 5. `yq` Dependency for Complex YAML

The YAML parsing strategy uses `yq` (a common CLI YAML processor) when available for full YAML fidelity. When `yq` is not installed, the fallback simple parser handles the subset of YAML used in template metadata. The simple parser supports:
- Top-level scalar key-value pairs.
- Simple lists (`- item`).
- One level of nested maps (the `prompts` list of maps).
- Inline lists (`[a, b, c]`).

It does **not** support multi-line strings, anchors, aliases, or deeply nested structures. This is sufficient for the template metadata format.

### 6. Vault Switching

When the user switches vaults via `:VaultSwitch`, `engine.invalidate_all_caches()` fires, which clears `M._cache` via the registered cache invalidation callback. The next `templates.all()` call re-scans the new vault's templates directory.

### 7. Templates Directory Does Not Exist

If the configured templates directory does not exist, `M.list()` returns an empty table and no user templates appear in the picker. The `:VaultTemplateEdit` command creates the directory automatically via `engine.ensure_dir()`.

### 8. Recursive Subdirectories

The initial implementation scans only the top-level templates directory (no recursion). This keeps the behavior simple and predictable. A future enhancement could support subdirectories as template categories.

### 9. Interaction with Fragments

User templates with `template_type: insert` overlap in functionality with the hardcoded fragments in `fragments.lua`. The key differences:
- Fragments are Lua functions that can use dynamic logic (e.g., the Callout fragment prompts for callout type).
- User insert templates are static `.md` files with `{{variable}}` substitution.
- Both coexist — fragments for complex/dynamic inline content, user insert templates for simple reusable structures.

A future enhancement could merge the fragment picker with user insert templates into a unified "Insert" picker.

### 10. Template Variable Discovery

If a template body references `{{some_var}}` but no prompt is declared for `some_var` and it is not a built-in variable, the placeholder is left as-is in the output (matching `engine.substitute()` behavior on line 609). The user can then fill it in manually. This is intentional — it allows templates to contain "placeholder" markers that the user fills in after creation.

### 11. Obsidian Compatibility

The template format is designed to be Obsidian-compatible:
- The template files are regular `.md` files that Obsidian can read and edit.
- The `{{variable}}` syntax matches Obsidian Templater's variable syntax.
- The `{{date:FORMAT}}` syntax matches Obsidian's built-in date formatting.
- The `template_*` frontmatter fields are prefixed to avoid collisions with regular note fields.

However, Obsidian Templater uses `<% %>` for JavaScript expressions, which this system does not support. User templates are limited to variable interpolation — no arbitrary code execution.

---

## Testing Strategy

### Unit Tests

1. **YAML parsing** — Test `_parse_yaml_simple()` with:
   - Flat scalar fields
   - Simple lists
   - Nested map lists (the `prompts` format)
   - Inline lists (`[a, b, c]`)
   - Missing fields / empty file
   - Quoted values

2. **Template parsing** — Test `parse_template()` with:
   - Full template file (frontmatter + body)
   - Template with no frontmatter (body only)
   - Template with `{{title}}` but no explicit prompts (auto-prompt)
   - Template with complex prompts (project, select, area)
   - Malformed frontmatter (no closing `---`)

3. **Frontmatter building** — Test `build_frontmatter()` with:
   - Simple key-value pairs
   - List values (tags)
   - `{{variable}}` interpolation in values

4. **Template rendering** — Test full `run_note()` flow with mocked `engine.input()`/`engine.select()`:
   - Variable substitution in body, dest, filename, and frontmatter
   - Filename sanitization
   - Missing prompt cancellation (returns nil)

### Integration Tests

1. **Picker integration** — Verify that `templates.all()` returns built-in + user templates in correct order with separator.
2. **Cache invalidation** — Save a template `.md` file, verify cache is cleared and `list()` returns updated content.
3. **Vault switch** — Switch vaults, verify user templates come from the new vault's directory.
4. **Directory creation** — Run `:VaultTemplateEdit` on a vault with no templates directory, verify it is created.

### Manual Testing Checklist

- [ ] Create a `templates/` directory in vault root
- [ ] Add a simple template `.md` file with prompts
- [ ] Run `:VaultNew` and verify the template appears in the picker after built-in templates
- [ ] Select the user template and verify prompts appear in order
- [ ] Verify the output file has correct frontmatter, body, and filename
- [ ] Verify `{{date}}`, `{{time}}`, `{{date:FORMAT}}` all resolve correctly
- [ ] Edit the template file and verify `:VaultTemplateReload` picks up changes
- [ ] Test `:VaultTemplateEdit` to create a new template with the starter scaffold
- [ ] Test `template_type: insert` — verify content is inserted at cursor
- [ ] Test with no `yq` installed — verify fallback parser works
- [ ] Test with missing/malformed frontmatter — verify graceful degradation
- [ ] Test filename sanitization with special characters in title
- [ ] Verify `:VaultCacheStatus` shows user_templates entry
- [ ] Verify vault switch clears user template cache

---

## Summary of Files Changed

| File | Change |
|------|--------|
| `lua/andrew/vault/config.lua` | Add `M.user_templates` config section |
| `lua/andrew/vault/user_templates.lua` | **New file** — template parsing, scanning, execution, commands |
| `lua/andrew/vault/templates/init.lua` | Refactor from static list to `M.all()` function merging built-in + user templates |
| `lua/andrew/vault/init.lua` | Update `new_note()` and `run_template()` to use `templates.all()`; add `require("andrew.vault.user_templates").setup()` |
