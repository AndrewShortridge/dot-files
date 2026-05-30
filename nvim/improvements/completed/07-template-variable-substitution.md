# 07 — Template Variable Substitution

## Problem

The vault template system currently uses **two separate, incompatible** approaches for injecting dynamic values into note content:

1. **Lua-side string concatenation** — Most templates (daily_log, task, meeting, weekly_review, monthly_review, quarterly_review, yearly_review, project_dashboard, simulation, area_dashboard) construct content by concatenating Lua strings with variables like `.. date ..` and `.. title ..` inline. The template content is never a standalone string that could be read or edited independently of the Lua code.

2. **`engine.render()` with `${var}` syntax** — A subset of templates (concept, literature, journal, person, domain_moc, methodology, changelog, presentation, draft, analysis, finding, recurring_task, asset, financial_snapshot) use long-string `body_template` constants with `${var_name}` placeholders, passed through `engine.render(template, vars)` at line 289-293 of `engine.lua`.

Neither approach supports Obsidian-compatible `{{variable}}` syntax. This means:

- Templates cannot be shared between Obsidian and Neovim.
- There is no way to use Obsidian's standard `{{date}}`, `{{time}}`, `{{title}}`, or `{{date:FORMAT}}` variables.
- Users cannot define custom variables or format strings without editing Lua code.
- The `engine.render()` function (line 289) only handles `${key}` — a custom syntax that does not exist in Obsidian.

### Current `engine.render()` Implementation

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/engine.lua`, lines 284-293

```lua
--- Simple template variable substitution.
--- Replaces ${var_name} with values from the vars table.
---@param template string
---@param vars table<string, string>
---@return string
function M.render(template, vars)
  return (template:gsub("%${([%w_]+)}", function(key)
    return vars[key] or ("${" .. key .. "}")
  end))
end
```

This uses `${key}` syntax and only supports simple key lookup — no format strings, no built-in variables, no date/time formatting.

### Templates Using `engine.render()`

These templates define `body_template` long strings with `${var}` placeholders and call `e.render(body_template, vars)`:

| Template | File | render() call line |
|----------|------|--------------------|
| Concept Note | `templates/concept.lua` | Line 92 |
| Literature Note | `templates/literature.lua` | Line 109 |
| Journal Entry | `templates/journal.lua` | Line 57 |
| Person Note | `templates/person.lua` | Line 97 |
| Domain MOC | `templates/domain_moc.lua` | Line 123 |
| Methodology | `templates/methodology.lua` | Line 124 |
| Changelog | `templates/changelog.lua` | Line 98 |
| Presentation | `templates/presentation.lua` | Line 95 |
| Draft Note | `templates/draft.lua` | Line 89 |
| Analysis Note | `templates/analysis.lua` | Line 120 |
| Finding Note | `templates/finding.lua` | Line 98 |
| Recurring Task | `templates/recurring_task.lua` | Line 62 |
| Asset Note | `templates/asset.lua` | Line 102 |
| Financial Snapshot | `templates/financial_snapshot.lua` | Line 103 |

### Templates Using Inline Concatenation Only (No `render()`)

These templates build content entirely through Lua string concatenation and do **not** use `engine.render()`:

| Template | File |
|----------|------|
| Daily Log | `templates/daily_log.lua` |
| Task Note | `templates/task.lua` |
| Meeting Note | `templates/meeting.lua` |
| Weekly Review | `templates/weekly_review.lua` |
| Monthly Review | `templates/monthly_review.lua` |
| Quarterly Review | `templates/quarterly_review.lua` |
| Yearly Review | `templates/yearly_review.lua` |
| Project Dashboard | `templates/project_dashboard.lua` |
| Simulation Note | `templates/simulation.lua` |
| Area Dashboard | `templates/area_dashboard.lua` |

---

## Goal

Add Obsidian-compatible template variable substitution using `{{variable}}` syntax, so that:

1. Both `body_template` strings and inline-constructed content can use `{{date}}`, `{{time}}`, `{{title}}`, etc.
2. Custom strftime format strings work: `{{date:YYYY-MM-DD}}`, `{{time:HH:mm}}`.
3. Custom user-defined variables can be registered.
4. The existing `${var}` syntax continues to work (backward compatibility).
5. The substitution function is centralized in `engine.lua` and reusable by all templates and fragments.

---

## Variables to Support

### Core Variables (Obsidian-compatible)

| Variable | Description | Default Format | Example Output |
|----------|-------------|----------------|----------------|
| `{{date}}` | Current date | `YYYY-MM-DD` | `2026-02-25` |
| `{{time}}` | Current time | `HH:mm` | `14:35` |
| `{{title}}` | Note title (from `vars.title` or buffer name) | — | `My Note Title` |
| `{{date:FORMAT}}` | Date with custom format | User-specified | `February 25, 2026` |
| `{{time:FORMAT}}` | Time with custom format | User-specified | `2:35 PM` |

### Extended Variables (Vault-specific)

| Variable | Description | Example Output |
|----------|-------------|----------------|
| `{{vault}}` | Active vault name | `Main` |
| `{{vault_path}}` | Active vault root path | `/home/.../Obsidian-Vault` |
| `{{folder}}` | Destination folder (relative to vault) | `Projects/MyProject/Tasks` |
| `{{date_long}}` | Long date format | `February 25, 2026` |
| `{{date_weekday}}` | Weekday + long date | `Tuesday, February 25, 2026` |
| `{{week}}` | ISO week number | `09` |
| `{{year}}` | Four-digit year | `2026` |
| `{{month}}` | Two-digit month | `02` |
| `{{day}}` | Two-digit day | `25` |
| `{{yesterday}}` | Yesterday's date | `2026-02-24` |
| `{{tomorrow}}` | Tomorrow's date | `2026-02-26` |
| `{{timestamp}}` | ISO timestamp | `2026-02-25T14:35:00` |

### Format String Mapping (Obsidian -> strftime)

Obsidian uses Moment.js-style format tokens. The substitution engine must translate these to Lua `os.date()` strftime codes:

| Obsidian Token | strftime | Meaning |
|---------------|----------|---------|
| `YYYY` | `%Y` | 4-digit year |
| `YY` | `%y` | 2-digit year |
| `MMMM` | `%B` | Full month name |
| `MMM` | `%b` | Abbreviated month |
| `MM` | `%m` | Zero-padded month |
| `M` | (custom) | Month without padding |
| `DDDD` | `%j` | Day of year |
| `DD` | `%d` | Zero-padded day |
| `D` | (custom) | Day without padding |
| `dddd` | `%A` | Full weekday name |
| `ddd` | `%a` | Abbreviated weekday |
| `dd` | `%a` | Abbreviated weekday |
| `HH` | `%H` | 24-hour hour (zero-padded) |
| `H` | (custom) | 24-hour hour (no padding) |
| `hh` | `%I` | 12-hour hour (zero-padded) |
| `h` | (custom) | 12-hour hour (no padding) |
| `mm` | `%M` | Minutes (zero-padded) |
| `m` | (custom) | Minutes (no padding) |
| `ss` | `%S` | Seconds (zero-padded) |
| `s` | (custom) | Seconds (no padding) |
| `A` | `%p` | AM/PM |
| `a` | (custom) | am/pm (lowercase) |

---

## Implementation Plan

### Step 1: Add Format Conversion to `engine.lua`

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/engine.lua`

**Where:** After the existing `M.render()` function (after line 293), add the Obsidian format converter and the new `M.substitute()` function.

```lua
--- Map of Obsidian/Moment.js format tokens to Lua os.date() strftime codes.
--- Order matters: longer tokens must be matched before shorter ones.
--- @type { pattern: string, replacement: string|function }[]
local OBSIDIAN_FORMAT_MAP = {
  { pattern = "YYYY", replacement = "%%Y" },
  { pattern = "YY",   replacement = "%%y" },
  { pattern = "MMMM", replacement = "%%B" },
  { pattern = "MMM",  replacement = "%%b" },
  { pattern = "MM",   replacement = "%%m" },
  { pattern = "M",    replacement = function() return tostring(tonumber(os.date("%m"))) end },
  { pattern = "DDDD", replacement = "%%j" },
  { pattern = "DD",   replacement = "%%d" },
  { pattern = "D",    replacement = function() return tostring(tonumber(os.date("%d"))) end },
  { pattern = "dddd", replacement = "%%A" },
  { pattern = "ddd",  replacement = "%%a" },
  { pattern = "dd",   replacement = "%%a" },
  { pattern = "HH",   replacement = "%%H" },
  { pattern = "H",    replacement = function() return tostring(tonumber(os.date("%H"))) end },
  { pattern = "hh",   replacement = "%%I" },
  { pattern = "h",    replacement = function() return tostring(tonumber(os.date("%I"))) end },
  { pattern = "mm",   replacement = "%%M" },
  { pattern = "m",    replacement = function() return tostring(tonumber(os.date("%M"))) end },
  { pattern = "ss",   replacement = "%%S" },
  { pattern = "s",    replacement = function() return tostring(tonumber(os.date("%S"))) end },
  { pattern = "A",    replacement = "%%p" },
  { pattern = "a",    replacement = function() return os.date("%p"):lower() end },
}

--- Convert an Obsidian/Moment.js format string to a Lua os.date() strftime string.
--- Uses greedy longest-match to avoid ambiguity (e.g., "YYYY" before "YY").
---@param fmt string  Obsidian format (e.g., "YYYY-MM-DD")
---@return string strftime_fmt  (e.g., "%Y-%m-%d")
function M.obsidian_to_strftime(fmt)
  local result = {}
  local i = 1
  local len = #fmt

  while i <= len do
    local matched = false
    -- Try longest patterns first (they are already ordered longest-first per group)
    for _, entry in ipairs(OBSIDIAN_FORMAT_MAP) do
      local pat = entry.pattern
      if fmt:sub(i, i + #pat - 1) == pat then
        local repl = entry.replacement
        if type(repl) == "function" then
          -- For function-based replacements, we cannot embed into strftime.
          -- Instead, mark for post-processing. Use a sentinel.
          result[#result + 1] = "\0FN:" .. pat .. "\0"
        else
          result[#result + 1] = repl
        end
        i = i + #pat
        matched = true
        break
      end
    end
    if not matched then
      -- Literal character — escape % for os.date
      local ch = fmt:sub(i, i)
      if ch == "%" then
        result[#result + 1] = "%%"
      else
        result[#result + 1] = ch
      end
      i = i + 1
    end
  end

  return table.concat(result)
end

--- Evaluate a strftime string that may contain function-sentinel markers.
--- Call os.date() for the strftime parts, then replace sentinel markers with
--- their function results.
---@param strftime_fmt string
---@return string
function M.eval_format(strftime_fmt)
  -- First pass: replace sentinels with unique placeholders, collect function calls
  local fn_results = {}
  local clean_fmt = strftime_fmt:gsub("\0FN:(%w+)\0", function(pat)
    for _, entry in ipairs(OBSIDIAN_FORMAT_MAP) do
      if entry.pattern == pat and type(entry.replacement) == "function" then
        local placeholder = "\x01" .. pat .. "\x01"
        fn_results[placeholder] = entry.replacement()
        return placeholder
      end
    end
    return pat
  end)

  -- Run os.date on the cleaned format
  local dated = os.date(clean_fmt)

  -- Replace function placeholders with their computed values
  for placeholder, value in pairs(fn_results) do
    dated = dated:gsub(placeholder, value)
  end

  return dated
end

--- Format a date/time using an Obsidian format string.
---@param obsidian_fmt string  e.g., "YYYY-MM-DD", "HH:mm", "MMMM D, YYYY"
---@return string
function M.format_obsidian(obsidian_fmt)
  local strftime_fmt = M.obsidian_to_strftime(obsidian_fmt)
  return M.eval_format(strftime_fmt)
end
```

### Step 2: Add the Variable Registry and `substitute()` Function

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/engine.lua`

**Where:** Immediately after the format conversion code added in Step 1.

```lua
--- Registry of custom template variables.
--- Each entry maps a variable name to a function(vars) -> string.
--- @type table<string, fun(vars: table): string>
M._custom_vars = {}

--- Register a custom template variable.
--- The resolver function receives the vars table and returns a string.
---@param name string  Variable name (used as {{name}})
---@param resolver fun(vars: table): string
function M.register_var(name, resolver)
  M._custom_vars[name] = resolver
end

--- Built-in variable resolvers.
--- Each receives the vars table (which may contain title, folder, etc.)
--- and returns a string value.
--- @type table<string, fun(vars: table): string>
local BUILTIN_VARS = {
  date = function(_vars)
    return os.date("%Y-%m-%d")
  end,
  time = function(_vars)
    return os.date("%H:%M")
  end,
  title = function(vars)
    if vars.title then return vars.title end
    -- Fallback: current buffer name without extension
    local bufname = vim.api.nvim_buf_get_name(0)
    if bufname ~= "" then
      return vim.fn.fnamemodify(bufname, ":t:r")
    end
    return "Untitled"
  end,
  vault = function(_vars)
    -- Reverse lookup: find the name of the active vault
    for name, path in pairs(M.vaults) do
      if path == M.vault_path then return name end
    end
    return vim.fn.fnamemodify(M.vault_path, ":t")
  end,
  vault_path = function(_vars)
    return M.vault_path
  end,
  folder = function(vars)
    if vars.folder then return vars.folder end
    -- Derive from destination path if available
    if vars._dest_path then
      local rel = vars._dest_path
      local dir = vim.fn.fnamemodify(rel, ":h")
      return dir ~= "." and dir or ""
    end
    return ""
  end,
  date_long = function(_vars)
    return M.today_long()
  end,
  date_weekday = function(_vars)
    return M.today_weekday()
  end,
  week = function(_vars)
    return M.week_number()
  end,
  year = function(_vars)
    return os.date("%Y")
  end,
  month = function(_vars)
    return os.date("%m")
  end,
  day = function(_vars)
    return os.date("%d")
  end,
  yesterday = function(_vars)
    return M.date_offset(-1)
  end,
  tomorrow = function(_vars)
    return M.date_offset(1)
  end,
  timestamp = function(_vars)
    return os.date("%Y-%m-%dT%H:%M:%S")
  end,
}

--- Perform Obsidian-compatible template variable substitution.
---
--- Supports:
---   {{date}}           -> current date (YYYY-MM-DD)
---   {{time}}           -> current time (HH:mm)
---   {{title}}          -> note title from vars or buffer
---   {{date:FORMAT}}    -> date with Obsidian format string
---   {{time:FORMAT}}    -> time with Obsidian format string
---   {{vault}}          -> active vault name
---   {{folder}}         -> destination folder
---   {{custom_var}}     -> from vars table or custom registry
---   ${legacy_var}      -> backward-compatible with existing render()
---
---@param template string   The template string
---@param vars? table       Variable overrides (key -> string value)
---@return string
function M.substitute(template, vars)
  vars = vars or {}

  -- Pass 1: Handle {{date:FORMAT}} and {{time:FORMAT}}
  local result = template:gsub("{{(date):([^}]+)}}", function(_key, fmt)
    return M.format_obsidian(fmt)
  end)
  result = result:gsub("{{(time):([^}]+)}}", function(_key, fmt)
    return M.format_obsidian(fmt)
  end)

  -- Pass 2: Handle {{variable}} (no format specifier)
  result = result:gsub("{{([%w_]+)}}", function(key)
    -- 1. Check explicit vars table first
    if vars[key] ~= nil then
      return tostring(vars[key])
    end
    -- 2. Check built-in resolvers
    if BUILTIN_VARS[key] then
      return BUILTIN_VARS[key](vars)
    end
    -- 3. Check custom registered variables
    if M._custom_vars[key] then
      return M._custom_vars[key](vars)
    end
    -- 4. Leave unresolved variables intact
    return "{{" .. key .. "}}"
  end)

  -- Pass 3: Backward-compatible ${var} substitution
  result = result:gsub("%${([%w_]+)}", function(key)
    return vars[key] or ("${" .. key .. "}")
  end)

  return result
end
```

### Step 3: Update `engine.render()` to Delegate to `substitute()`

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/engine.lua`

**What:** Replace the existing `M.render()` (lines 284-293) so it delegates to the new `M.substitute()`, preserving backward compatibility.

**Before (lines 284-293):**
```lua
--- Simple template variable substitution.
--- Replaces ${var_name} with values from the vars table.
---@param template string
---@param vars table<string, string>
---@return string
function M.render(template, vars)
  return (template:gsub("%${([%w_]+)}", function(key)
    return vars[key] or ("${" .. key .. "}")
  end))
end
```

**After:**
```lua
--- Template variable substitution.
--- Supports both {{var}} (Obsidian) and ${var} (legacy) syntax.
--- Also supports {{date:FORMAT}} and {{time:FORMAT}} with Obsidian format strings.
---@param template string
---@param vars table<string, string>
---@return string
function M.render(template, vars)
  return M.substitute(template, vars)
end
```

This is a non-breaking change. All 14 templates that call `e.render(body_template, vars)` will continue to work because `M.substitute()` still handles `${var}` syntax in Pass 3.

### Step 4: Add Config for Default Formats

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/config.lua`

**Where:** After the `M.embed` section (after line 68), add:

```lua
-- ---------------------------------------------------------------------------
-- Template variables
-- ---------------------------------------------------------------------------
M.template_vars = {
  date_format = "YYYY-MM-DD",    -- default for {{date}}
  time_format = "HH:mm",          -- default for {{time}}
  timestamp_format = "YYYY-MM-DDTHH:mm:ss",
}
```

Then update the `BUILTIN_VARS.date` and `BUILTIN_VARS.time` resolvers in engine.lua to use these defaults:

```lua
date = function(_vars)
  local cfg = require("andrew.vault.config")
  return M.format_obsidian(cfg.template_vars.date_format)
end,
time = function(_vars)
  local cfg = require("andrew.vault.config")
  return M.format_obsidian(cfg.template_vars.time_format)
end,
```

### Step 5: Apply `substitute()` to Fragment System

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/fragments.lua`

**Where:** In `M.insert_fragment()` (line 248), after `local lines = f.build(engine)` (line 269), add a substitution pass over each line:

```lua
-- After line 269:  local lines = f.build(engine)
if not lines then
  return
end
-- Apply template variable substitution to each line
for i, line in ipairs(lines) do
  lines[i] = engine.substitute(line)
end
```

This allows fragment templates to use `{{date}}`, `{{time}}`, etc. without any changes to their `build()` functions.

---

## Full Code: Substitution Engine

The complete code to add to `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/engine.lua` (insert after the existing `M.render()` at line 293, then replace `M.render()` body):

```lua
-- =============================================================================
-- Obsidian-Compatible Template Variable Substitution
-- =============================================================================

--- Map of Obsidian/Moment.js format tokens to Lua os.date() strftime codes.
--- Ordered longest-first within each letter group to ensure greedy matching.
--- @type { pattern: string, replacement: string|fun(): string }[]
local OBSIDIAN_FORMAT_MAP = {
  -- Year
  { pattern = "YYYY", replacement = "%%Y" },
  { pattern = "YY",   replacement = "%%y" },
  -- Month (name)
  { pattern = "MMMM", replacement = "%%B" },
  { pattern = "MMM",  replacement = "%%b" },
  -- Month (number) — must come after MMMM/MMM
  { pattern = "MM",   replacement = "%%m" },
  -- Day of year
  { pattern = "DDDD", replacement = "%%j" },
  -- Day of month (padded)
  { pattern = "DD",   replacement = "%%d" },
  -- Weekday names — must come before single-char matches
  { pattern = "dddd", replacement = "%%A" },
  { pattern = "ddd",  replacement = "%%a" },
  { pattern = "dd",   replacement = "%%a" },
  -- Hour 24h (padded)
  { pattern = "HH",   replacement = "%%H" },
  -- Hour 12h (padded)
  { pattern = "hh",   replacement = "%%I" },
  -- Minutes (padded)
  { pattern = "mm",   replacement = "%%M" },
  -- Seconds (padded)
  { pattern = "ss",   replacement = "%%S" },
  -- AM/PM
  { pattern = "A",    replacement = "%%p" },
}

--- Unpadded token handlers — evaluated at runtime, not via strftime.
--- Keyed by Obsidian token.
--- @type table<string, fun(): string>
local OBSIDIAN_UNPADDED = {
  M = function() return tostring(tonumber(os.date("%m"))) end,   -- month
  D = function() return tostring(tonumber(os.date("%d"))) end,   -- day
  H = function() return tostring(tonumber(os.date("%H"))) end,   -- 24h hour
  h = function() return tostring(tonumber(os.date("%I"))) end,   -- 12h hour
  m = function() return tostring(tonumber(os.date("%M"))) end,   -- minutes
  s = function() return tostring(tonumber(os.date("%S"))) end,   -- seconds
  a = function() return os.date("%p"):lower() end,               -- am/pm
}

--- Convert an Obsidian/Moment.js format string to a Lua os.date()-compatible
--- string. Tokens that require runtime computation (unpadded values) are
--- resolved immediately and spliced into the format string as literals.
---@param fmt string  Obsidian format (e.g., "YYYY-MM-DD", "MMMM D, YYYY")
---@return string strftime_fmt
function M.obsidian_to_strftime(fmt)
  local parts = {}
  local i = 1
  local len = #fmt

  while i <= len do
    local matched = false

    -- Try multi-char padded tokens (longest match first)
    for _, entry in ipairs(OBSIDIAN_FORMAT_MAP) do
      local pat = entry.pattern
      if fmt:sub(i, i + #pat - 1) == pat then
        parts[#parts + 1] = entry.replacement
        i = i + #pat
        matched = true
        break
      end
    end

    -- Try single-char unpadded tokens (only if no multi-char matched)
    if not matched then
      local ch = fmt:sub(i, i)
      local fn = OBSIDIAN_UNPADDED[ch]
      if fn then
        -- Splice the computed value directly as a literal
        parts[#parts + 1] = fn()
        i = i + 1
        matched = true
      end
    end

    if not matched then
      -- Literal character
      local ch = fmt:sub(i, i)
      if ch == "%" then
        parts[#parts + 1] = "%%%%"  -- escape for os.date
      else
        parts[#parts + 1] = ch
      end
      i = i + 1
    end
  end

  return table.concat(parts)
end

--- Format the current date/time using an Obsidian-style format string.
---@param obsidian_fmt string  e.g., "YYYY-MM-DD", "HH:mm", "MMMM D, YYYY"
---@return string
function M.format_obsidian(obsidian_fmt)
  local strftime_fmt = M.obsidian_to_strftime(obsidian_fmt)
  return os.date(strftime_fmt)
end

-- ---------------------------------------------------------------------------
-- Variable registry
-- ---------------------------------------------------------------------------

--- Registry of user-defined custom template variables.
--- @type table<string, fun(vars: table): string>
M._custom_vars = {}

--- Register a custom template variable.
--- The resolver receives the vars table and must return a string.
---@param name string  Variable name (used as {{name}} in templates)
---@param resolver fun(vars: table): string
function M.register_var(name, resolver)
  M._custom_vars[name] = resolver
end

--- Remove a previously registered custom variable.
---@param name string
function M.unregister_var(name)
  M._custom_vars[name] = nil
end

--- Built-in variable resolvers.
--- @type table<string, fun(vars: table): string>
local BUILTIN_VARS = {
  date = function(_vars)
    return os.date("%Y-%m-%d")
  end,
  time = function(_vars)
    return os.date("%H:%M")
  end,
  title = function(vars)
    if vars.title then return vars.title end
    local bufname = vim.api.nvim_buf_get_name(0)
    if bufname ~= "" then return vim.fn.fnamemodify(bufname, ":t:r") end
    return "Untitled"
  end,
  vault = function(_vars)
    for name, path in pairs(M.vaults) do
      if path == M.vault_path then return name end
    end
    return vim.fn.fnamemodify(M.vault_path, ":t")
  end,
  vault_path = function(_vars)
    return M.vault_path
  end,
  folder = function(vars)
    if vars.folder then return vars.folder end
    if vars._dest_path then
      local dir = vim.fn.fnamemodify(vars._dest_path, ":h")
      return dir ~= "." and dir or ""
    end
    return ""
  end,
  date_long = function(_vars) return M.today_long() end,
  date_weekday = function(_vars) return M.today_weekday() end,
  week = function(_vars) return M.week_number() end,
  year = function(_vars) return os.date("%Y") end,
  month = function(_vars) return os.date("%m") end,
  day = function(_vars) return os.date("%d") end,
  yesterday = function(_vars) return M.date_offset(-1) end,
  tomorrow = function(_vars) return M.date_offset(1) end,
  timestamp = function(_vars) return os.date("%Y-%m-%dT%H:%M:%S") end,
}

--- Perform Obsidian-compatible template variable substitution.
---
--- Supports three syntaxes in order:
---   1. {{date:FORMAT}} / {{time:FORMAT}} — Obsidian format strings
---   2. {{variable}} — built-in, custom-registered, or vars-table lookup
---   3. ${variable} — legacy syntax (backward compat with existing templates)
---
---@param template string   The template string with {{var}} or ${var} placeholders
---@param vars? table       Variable overrides (key -> string value)
---@return string
function M.substitute(template, vars)
  vars = vars or {}

  -- Pass 1: {{date:FORMAT}} and {{time:FORMAT}}
  local result = template:gsub("{{date:([^}]+)}}", function(fmt)
    return M.format_obsidian(fmt)
  end)
  result = result:gsub("{{time:([^}]+)}}", function(fmt)
    return M.format_obsidian(fmt)
  end)

  -- Pass 2: {{variable}}
  result = result:gsub("{{([%w_]+)}}", function(key)
    -- Explicit vars override everything
    if vars[key] ~= nil then return tostring(vars[key]) end
    -- Built-in resolvers
    if BUILTIN_VARS[key] then return BUILTIN_VARS[key](vars) end
    -- Custom registered resolvers
    if M._custom_vars[key] then return M._custom_vars[key](vars) end
    -- Unresolved: leave as-is
    return "{{" .. key .. "}}"
  end)

  -- Pass 3: ${variable} (legacy backward compat)
  result = result:gsub("%${([%w_]+)}", function(key)
    return vars[key] or ("${" .. key .. "}")
  end)

  return result
end
```

Then replace the body of the existing `M.render()` (lines 289-292):

```lua
function M.render(template, vars)
  return M.substitute(template, vars)
end
```

---

## How to Register Custom Variables

Users can register custom variables from their Neovim config or from any module:

```lua
local engine = require("andrew.vault.engine")

-- Simple static value
engine.register_var("author", function(_vars)
  return "Andrew"
end)

-- Dynamic value from environment
engine.register_var("hostname", function(_vars)
  return vim.fn.hostname()
end)

-- Value that depends on other vars
engine.register_var("greeting", function(vars)
  return "Hello, " .. (vars.title or "World")
end)

-- Now these work in any template:
-- {{author}} -> "Andrew"
-- {{hostname}} -> "myhost"
-- {{greeting}} -> "Hello, My Note Title"
```

A good place to add project-wide custom variables is in the vault's `init.lua` (after engine is loaded):

**File:** `/home/andrew-cmmg/.config/nvim/lua/andrew/vault/init.lua`

```lua
-- After line 1: local engine = require("andrew.vault.engine")

-- Register project-specific template variables
engine.register_var("author", function() return "Andrew" end)
```

---

## Template Migration Guide

### For Templates Using `engine.render()` (14 templates)

These templates already have `body_template` strings. Migration is optional but recommended for Obsidian compatibility. Replace `${var}` with `{{var}}` in the template strings.

**Example: `concept.lua` body_template (lines 6-63)**

Before:
```lua
local body_template = [==[
# ${title}

**Domain:** [[${domain}]]
**Maturity:** `${maturity}`
]==]
```

After:
```lua
local body_template = [==[
# {{title}}

**Domain:** [[{{domain}}]]
**Maturity:** `{{maturity}}`
]==]
```

No changes needed to the `M.run()` function — `e.render(body_template, vars)` still works because `M.render()` now delegates to `M.substitute()` which handles both syntaxes.

### For Templates Using Inline Concatenation (10 templates)

These templates are harder to migrate because their content is built programmatically with Lua logic (conditionals, loops, dynamic sections). There are two approaches:

**Approach A: Leave as-is (recommended for complex templates)**

Templates like `daily_log.lua`, `simulation.lua`, and `project_dashboard.lua` have extensive conditional logic that cannot be expressed in a simple template string. Keep their inline concatenation. They already compute dates/titles in Lua and embed them directly.

**Approach B: Wrap final content through `substitute()` (easy win)**

For templates that construct content inline but still want to support `{{var}}` in their static sections, wrap the final content string through `engine.substitute()` before writing.

Example for `task.lua` (line 65):

Before:
```lua
e.write_note(config.dirs.projects .. "/" .. project .. "/Tasks/" .. title, fm .. body)
```

After:
```lua
local content = engine.substitute(fm .. body, {
  title = title,
  date = date,
  project = project,
})
e.write_note(config.dirs.projects .. "/" .. project .. "/Tasks/" .. title, content)
```

### Migration Priority

| Priority | Template | Reason |
|----------|----------|--------|
| 1 (do first) | concept, literature, journal, person | Already use `render()`, simple string replacement |
| 2 | methodology, domain_moc, analysis, finding | Already use `render()`, simple string replacement |
| 3 | changelog, presentation, draft, asset, recurring_task, financial_snapshot | Already use `render()`, simple string replacement |
| 4 (optional) | task, meeting | Moderate concatenation, could benefit from `substitute()` |
| 5 (skip) | daily_log, weekly/monthly/quarterly/yearly_review, project_dashboard, simulation, area_dashboard | Heavy conditional logic; not worth migrating |

### Frontmatter Template Strings

For templates that build frontmatter via concatenation, you can optionally convert them too. For example, in `concept.lua` (lines 81-90):

Before:
```lua
local fm = "---\n"
  .. "type: concept\n"
  .. "title: " .. title .. "\n"
  .. 'domain: "[[' .. domain .. ']]"\n'
  .. "maturity: " .. maturity .. "\n"
  .. "created: " .. date .. "\n"
  .. "last_updated: " .. date .. "\n"
  .. "tags:\n"
  .. "  - concept\n"
  .. "---\n"
```

After:
```lua
local fm = [==[---
type: concept
title: {{title}}
domain: "[[{{domain}}]]"
maturity: {{maturity}}
created: {{date}}
last_updated: {{date}}
tags:
  - concept
---
]==]
```

Then the entire template (frontmatter + body) can be rendered in one pass:

```lua
e.write_note(dest, e.render(fm .. "\n" .. body_template, vars))
```

---

## Testing

### Unit Test: Format Conversion

Create a test file or run these interactively via `:lua`:

```lua
local e = require("andrew.vault.engine")

-- Test basic date format
assert(e.format_obsidian("YYYY-MM-DD") == os.date("%Y-%m-%d"))
print("PASS: YYYY-MM-DD")

-- Test time format
assert(e.format_obsidian("HH:mm:ss") == os.date("%H:%M:%S"))
print("PASS: HH:mm:ss")

-- Test long date
local expected_long = os.date("%B") .. " " .. tostring(tonumber(os.date("%d"))) .. ", " .. os.date("%Y")
assert(e.format_obsidian("MMMM D, YYYY") == expected_long)
print("PASS: MMMM D, YYYY -> " .. expected_long)

-- Test weekday
local expected_weekday = os.date("%A, %B") .. " " .. tostring(tonumber(os.date("%d"))) .. ", " .. os.date("%Y")
assert(e.format_obsidian("dddd, MMMM D, YYYY") == expected_weekday)
print("PASS: dddd, MMMM D, YYYY -> " .. expected_weekday)

-- Test 12-hour time
local expected_12h = tostring(tonumber(os.date("%I"))) .. ":" .. os.date("%M %p"):lower()
local result_12h = e.format_obsidian("h:mm a")
-- Note: "a" lower-case am/pm — this test may vary by locale
print("12h result: " .. result_12h)

print("All format tests passed")
```

### Unit Test: Variable Substitution

```lua
local e = require("andrew.vault.engine")

-- Test {{date}} built-in
local t1 = e.substitute("Today is {{date}}")
assert(t1 == "Today is " .. os.date("%Y-%m-%d"), "FAIL: {{date}}")
print("PASS: {{date}} -> " .. t1)

-- Test {{time}} built-in
local t2 = e.substitute("Now: {{time}}")
assert(t2:match("^Now: %d%d:%d%d$"), "FAIL: {{time}}")
print("PASS: {{time}} -> " .. t2)

-- Test {{title}} from vars
local t3 = e.substitute("# {{title}}", { title = "My Note" })
assert(t3 == "# My Note", "FAIL: {{title}}")
print("PASS: {{title}} -> " .. t3)

-- Test {{date:FORMAT}}
local t4 = e.substitute("Created: {{date:MMMM DD, YYYY}}")
local expected4 = "Created: " .. os.date("%B %d, %Y")
assert(t4 == expected4, "FAIL: {{date:FORMAT}} got " .. t4 .. " expected " .. expected4)
print("PASS: {{date:FORMAT}} -> " .. t4)

-- Test {{time:FORMAT}}
local t5 = e.substitute("At {{time:HH:mm:ss}}")
assert(t5:match("^At %d%d:%d%d:%d%d$"), "FAIL: {{time:FORMAT}}")
print("PASS: {{time:FORMAT}} -> " .. t5)

-- Test ${legacy} backward compat
local t6 = e.substitute("Hello ${name}", { name = "World" })
assert(t6 == "Hello World", "FAIL: ${legacy}")
print("PASS: ${legacy} -> " .. t6)

-- Test mixed syntax
local t7 = e.substitute("{{date}} by ${author}", { author = "Andrew" })
assert(t7:match("^%d%d%d%d%-%d%d%-%d%d by Andrew$"), "FAIL: mixed")
print("PASS: mixed -> " .. t7)

-- Test unresolved variables are left intact
local t8 = e.substitute("{{unknown_var}}")
assert(t8 == "{{unknown_var}}", "FAIL: unresolved")
print("PASS: unresolved -> " .. t8)

-- Test custom variable registration
e.register_var("author", function() return "Andrew" end)
local t9 = e.substitute("By {{author}}")
assert(t9 == "By Andrew", "FAIL: custom var")
print("PASS: custom var -> " .. t9)
e.unregister_var("author")

-- Test vault name
local t10 = e.substitute("Vault: {{vault}}")
print("PASS: {{vault}} -> " .. t10)

-- Test extended vars
local t11 = e.substitute("Week {{week}} of {{year}}")
assert(t11:match("^Week %d%d of %d%d%d%d$"), "FAIL: week/year")
print("PASS: week/year -> " .. t11)

print("\nAll substitution tests passed")
```

### Integration Test: Template Rendering

Verify that existing templates still work after the change:

```vim
" 1. Open Neovim in the vault
" 2. Run :VaultNew
" 3. Select "Concept Note"
" 4. Fill in the prompts
" 5. Verify the generated note has correct dates, title, domain
" 6. Repeat for Literature Note, Journal Entry, Person Note

" Verify daily log still works:
:VaultDaily
" Check that dates, navigation links, frontmatter are all correct
```

### Integration Test: New {{var}} Syntax

After migration, test a template with `{{var}}` syntax:

```lua
-- Temporarily modify concept.lua to use {{title}} instead of ${title}
-- Then run :VaultNew -> Concept Note
-- Verify the title appears correctly in the output
```

### Edge Case Tests

```lua
local e = require("andrew.vault.engine")

-- Empty template
assert(e.substitute("") == "")

-- No variables
assert(e.substitute("Hello world") == "Hello world")

-- Adjacent variables
assert(e.substitute("{{year}}{{month}}{{day}}") == os.date("%Y%m%d"))

-- Variable in code block (should still substitute)
local code = "```\ndate: {{date}}\n```"
assert(e.substitute(code):match("date: %d%d%d%d%-%d%d%-%d%d"))

-- Escaped braces (edge case: {{ without closing }})
assert(e.substitute("{{ not_closed") == "{{ not_closed")

-- Double braces with spaces (should NOT match)
assert(e.substitute("{{ date }}") == "{{ date }}")

print("All edge case tests passed")
```

---

## Summary of Files to Modify

| File | Change | Lines Affected |
|------|--------|---------------|
| `lua/andrew/vault/engine.lua` | Replace `M.render()` body, add `obsidian_to_strftime()`, `format_obsidian()`, `substitute()`, `register_var()`, `unregister_var()`, format mapping tables, built-in variable resolvers | Lines 284-293 (replace), new code after line 293 (~180 lines) |
| `lua/andrew/vault/config.lua` | Add `M.template_vars` config block | After line 68 (~6 lines) |
| `lua/andrew/vault/fragments.lua` | Add `engine.substitute()` pass over built fragment lines | Line 269 (~4 lines) |
| `lua/andrew/vault/init.lua` | (Optional) Register custom vars like `author` | After line 2 (~2 lines) |
| `lua/andrew/vault/templates/*.lua` | (Optional, per migration priority) Replace `${var}` with `{{var}}` in `body_template` strings | Varies per template |

### What Does NOT Need to Change

- The template registry (`templates/init.lua`) — no structural changes.
- The template invocation flow (`init.lua` lines 8-41) — `t.run(engine, pickers)` is unchanged.
- The `pickers.lua` module — completely unaffected.
- Templates that use inline concatenation and do not want `{{var}}` — they work as before.

---

## Future Extensions

1. **`{{date+N:FORMAT}}` / `{{date-N:FORMAT}}`** — Date offsets, matching Obsidian's Natural Language Dates plugin. Implementation: extend the `{{date:...}}` regex to capture an optional `+N` or `-N` before the colon.

2. **`{{prompt:LABEL}}`** — Interactive prompts that pause substitution and ask the user for input, matching Obsidian's Templater plugin. Implementation: integrate with `engine.input()` inside the coroutine.

3. **File-based templates** — Read `.md` template files from a `_templates/` directory in the vault and substitute variables, rather than defining templates in Lua. This would fully match Obsidian's template workflow.

4. **`{{#each}}` / `{{#if}}`** — Conditional and loop blocks. This would require a mini template language parser. Consider this only if file-based templates are adopted.
