# 53. Standardize Error Handling Across Vault Modules

## Motivation

The vault codebase currently uses four distinct error handling strategies, chosen
ad hoc on a per-module (sometimes per-function) basis:

1. **`assert()`** -- halts execution with a stack trace.
2. **`pcall()`** -- catches errors, sometimes inspects the result, sometimes
   discards it.
3. **`vim.notify()`** -- surfaces messages to the user at varying severity
   levels.
4. **Silent `return nil` / `return false` / `return {}`** -- swallows the error
   entirely.

The inconsistency makes it difficult to:

- **Debug** issues in the field (a user reports "nothing happened" but there is
  no log entry).
- **Compose** modules (caller A has no way to distinguish "not found" from
  "I/O failure" when callee B returns `nil` for both).
- **Maintain** the codebase (contributors must read each function body to learn
  its error contract).

A standardized protocol, backed by a lightweight centralized logger, will make
error behavior predictable, improve debuggability, and establish a clear
convention for all future code.

---

## Audit of Current Patterns

### Pattern Distribution (across 82 vault Lua files)

| Pattern | Occurrences | Files touched |
|---|---|---|
| `vim.notify()` total | **323** | 55 |
| -- `vim.log.levels.INFO` | 169 | 46 |
| -- `vim.log.levels.WARN` | 90 | 39 |
| -- `vim.log.levels.ERROR` | 29 | 17 |
| -- no explicit level | 35 | ~12 |
| `pcall()` | **110** | 39 |
| `return nil` (silent) | **89** | 35 |
| `return false` (silent) | **64** | 18 |
| `assert()` | **4** | 1 (engine.lua) |

### Per-Module Breakdown

**engine.lua** -- Mixed: all four patterns.
- `assert()` for programmer errors: `register_cache()` requires `spec.name`,
  `engine.input()`/`engine.select()` require a running coroutine (lines 30-31,
  165, 183).
- `pcall()` for resilient autocmd firing (line 78), JSON decode (line 275),
  fs watcher cleanup (line 1038).
- `vim.notify(..., ERROR)` for coroutine resume failures (lines 156, 170, 188),
  vault switch failure (line 117), file write failure (line 381).
- `vim.notify(..., WARN)` for non-critical write failures (lines 283, 329, 344).
- Silent `return nil` / `return {}` for file read helpers (`read_file` returns
  `nil`, `read_file_lines` returns `{}` -- lines 298, 310).

**vault_index.lua** -- Predominantly silent.
- `pcall()` for JSON decode/encode (lines 152, 190), subscriber notification
  (line 125).
- `progress_notify()` wrapper for build progress (line 78-84), but only for
  INFO-level progress updates, never for errors.
- Silent `return false` on load failure (line 147), silent `return` on persist
  failure (lines 191, 194).
- Silent `return nil` when `_parse_file` fails to open or read (line 619).
- No error is ever surfaced when index persistence fails -- the user has no way
  to know their index was not saved.

**wikilinks.lua** -- Mostly silent, some user-facing notifications.
- `vim.notify(..., WARN)` for "heading not found" / "block not found" /
  "file not found" when following links (lines 278, 286, 316, 354, 379, 394).
- `vim.notify(..., INFO)` for "Created: note.md" (line 354).
- `pcall()` for fallback `gf`/`gF` navigation (lines 407, 409).
- `resolve_link()` returns `nil` silently when no match found (line 208) --
  correct for this case since callers handle `nil`.

**embed.lua** -- Defensive pcall-heavy, custom `notify()` wrapper.
- Custom `notify(opts, msg, level)` helper that respects `opts.silent` flag to
  suppress autocmd-triggered messages.
- 11 `pcall()` calls, mostly around Snacks image placement API, terminal env
  detection, and placement cleanup.
- `vim.notify(..., WARN)` for image-not-found, placement-failed (lines 553,
  558, 560).
- Silent `return nil, nil` from `init_snacks_image()` when Snacks unavailable
  (lines 108, 116).

**preview.lua** -- Notification-oriented for user feedback.
- `vim.notify(..., INFO)` for "no wikilink under cursor", "beginning/end of
  history" (lines 450, 485, 495, 524, 627, 633, 735).
- `vim.notify(..., WARN)` for "cannot resolve link", "note not found" (lines
  450, 742).
- `pcall()` for treesitter start, render-markdown call, keymap cleanup, augroup
  deletion (lines 378-381, 586, 591, 809).
- No error logging on pcall failures -- errors are silently swallowed.

**Other notable modules:**
- **rename.lua** (13 vim.notify): Heavily user-facing, uses all three levels
  appropriately for rename workflow feedback.
- **linkcheck.lua** (18 vim.notify): Diagnostic-heavy, good use of WARN/ERROR
  for broken link reports.
- **unlinked.lua** (19 vim.notify): Verbose user feedback for unlinked mention
  workflow.
- **search.lua** (9 vim.notify): Mix of user guidance (INFO) and error
  reporting (ERROR for query parse failures).
- **connections.lua** (9 vim.notify): User-facing connection graph feedback.

### Key Problem Areas

1. **vault_index.lua persistence failures are invisible.** If `_persist()` fails
   (disk full, permissions, JSON encode error), no message is shown. The user
   discovers the problem only on next startup when the stale/missing index
   triggers a full rebuild.

2. **engine.lua `read_file()` vs `read_file_lines()` contract mismatch.**
   `read_file()` returns `nil` on failure; `read_file_lines()` returns `{}`.
   Callers must know which convention each function uses.

3. **embed.lua error suppression in silent mode.** Autocmd-triggered renders
   suppress all notifications via `opts.silent`. Image failures during auto-
   render are invisible unless the user manually runs `:VaultEmbedDebug`.

4. **pcall results discarded across many modules.** Pattern
   `pcall(vim.api.nvim_buf_set_extmark, ...)` appears 30+ times across
   highlight modules -- the error value is never inspected, making it
   impossible to diagnose extmark failures.

5. **No structured error propagation.** Internal functions like
   `resolve_link()`, `resolve_image()`, `_parse_file()` return `nil` for
   multiple distinct failure reasons. Callers cannot distinguish "note does not
   exist" from "index not ready" from "I/O error".

---

## Proposed Standard Protocol

### Principle: Errors Should Be Visible at the Right Level

| Context | Pattern | Rationale |
|---|---|---|
| Internal functions | `return value_or_nil, err_string` | Caller decides how to handle; error reason is preserved. |
| Public API / commands | `pcall()` + `vim.notify()` | User sees actionable feedback; Lua errors are caught. |
| Programmer errors | `assert()` | Invalid arguments, broken invariants. Never for runtime conditions. |
| Debug-level noise | `log.debug()` | Visible only when debug logging is enabled. |

### Rule 1: Internal Functions Return `nil, err_string`

Functions that can fail for runtime reasons (file not found, parse error, index
not ready) must return two values: the result (or `nil` on failure) and an
error string describing the failure.

```lua
-- GOOD: Caller knows exactly what went wrong
local function read_note(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, "cannot open " .. path .. ": " .. err
  end
  local content = f:read("*a")
  f:close()
  return content, nil
end

-- BAD: Caller has no idea why it got nil
local function read_note(path)
  local f = io.open(path, "r")
  if not f then return nil end
  ...
end
```

### Rule 2: Public API Functions Catch and Report

Functions bound to user commands or keymaps should wrap internal calls and
surface errors via `vim.notify()` (or the new logger) at the appropriate level.

```lua
function M.follow_link()
  local target, err = resolve_link(name)
  if not target then
    log.warn("Could not follow link '%s': %s", name, err)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(target))
end
```

### Rule 3: assert() is for Programmer Errors Only

Use `assert()` when a condition indicates a **bug** in the calling code, not a
runtime failure. The current engine.lua usage is a good example:

```lua
-- CORRECT: calling input() outside run() is a programmer mistake
assert(co, "engine.input() must be called within engine.run()")

-- WRONG: file might not exist at runtime -- that's not a bug
assert(io.open(path, "r"), "file not found")  -- DO NOT DO THIS
```

### Rule 4: pcall() Results Must Be Inspected or Logged

When using `pcall()` to guard against exceptions, the error value must be
either handled or logged. Silently discarding it defeats the purpose.

```lua
-- GOOD: Log the error at debug level
local ok, err = pcall(vim.treesitter.start, buf, "markdown")
if not ok then
  log.debug("treesitter start failed for buf %d: %s", buf, err)
end

-- ACCEPTABLE: Cleanup calls where failure is expected and harmless
pcall(vim.api.nvim_del_augroup_by_id, augroup)

-- BAD: Swallowing potentially important errors
local ok = pcall(vim.api.nvim_buf_set_extmark, ...)
-- (no inspection of the error)
```

---

## Proposed Logger Module: `vault_log.lua`

### Design Goals

1. Zero external dependencies (pure Lua + vim.notify).
2. Configurable level threshold (controlled via `config.lua`).
3. Output to `:messages` and optionally to a log file.
4. Stable notification IDs for in-place replacement (snacks.nvim / nvim-notify).
5. Integration with existing `:VaultDebug` / `:VaultEmbedDebug` commands.

### API

```lua
local log = require("andrew.vault.vault_log")

log.debug("Index parsed %d files in %dms", count, elapsed)
log.info("Switched to vault: %s", name)
log.warn("Image not found: %s", image_name)
log.error("Failed to persist index: %s", err)

-- Scoped logger for module-level context
local mlog = log.scope("embed")
mlog.debug("Rendering %d embeds for buf %d", n, bufnr)
-- Output: "[vault:embed] Rendering 5 embeds for buf 3"
```

### Module Skeleton

```lua
-- lua/andrew/vault/vault_log.lua
local M = {}

--- @alias LogLevel "DEBUG"|"INFO"|"WARN"|"ERROR"

local LEVELS = {
  DEBUG = 1,
  INFO  = 2,
  WARN  = 3,
  ERROR = 4,
}

local VIM_LEVELS = {
  DEBUG = vim.log.levels.DEBUG,
  INFO  = vim.log.levels.INFO,
  WARN  = vim.log.levels.WARN,
  ERROR = vim.log.levels.ERROR,
}

-- Default: show WARN and above in vim.notify, log everything to file
local _min_notify_level = LEVELS.WARN
local _min_file_level = LEVELS.DEBUG
local _log_file = nil          -- path, set by configure()
local _log_file_handle = nil   -- io file handle

--- Configure the logger. Called once from init.lua.
---@param opts { notify_level?: LogLevel, file_level?: LogLevel, file?: string }
function M.configure(opts)
  if opts.notify_level and LEVELS[opts.notify_level] then
    _min_notify_level = LEVELS[opts.notify_level]
  end
  if opts.file_level and LEVELS[opts.file_level] then
    _min_file_level = LEVELS[opts.file_level]
  end
  if opts.file then
    _log_file = opts.file
  end
end

--- Format and emit a log message.
---@param level_name LogLevel
---@param fmt string
---@param ... any
local function emit(level_name, prefix, fmt, ...)
  local level_num = LEVELS[level_name]
  local msg = string.format(fmt, ...)
  local full = prefix ~= "" and ("[vault:" .. prefix .. "] " .. msg) or ("[vault] " .. msg)

  -- vim.notify (user-visible)
  if level_num >= _min_notify_level then
    vim.schedule(function()
      vim.notify(full, VIM_LEVELS[level_name], {
        title = "Vault",
      })
    end)
  end

  -- File output
  if _log_file and level_num >= _min_file_level then
    if not _log_file_handle then
      _log_file_handle = io.open(_log_file, "a")
    end
    if _log_file_handle then
      local timestamp = os.date("%Y-%m-%d %H:%M:%S")
      _log_file_handle:write(
        string.format("[%s] [%s] %s\n", timestamp, level_name, full)
      )
      _log_file_handle:flush()
    end
  end
end

--- Close log file handle on exit.
function M.close()
  if _log_file_handle then
    _log_file_handle:close()
    _log_file_handle = nil
  end
end

--- Create log methods for the top-level module.
function M.debug(fmt, ...) emit("DEBUG", "", fmt, ...) end
function M.info(fmt, ...)  emit("INFO",  "", fmt, ...) end
function M.warn(fmt, ...)  emit("WARN",  "", fmt, ...) end
function M.error(fmt, ...) emit("ERROR", "", fmt, ...) end

--- Create a scoped logger that prepends a module name.
---@param module_name string
---@return table
function M.scope(module_name)
  return {
    debug = function(fmt, ...) emit("DEBUG", module_name, fmt, ...) end,
    info  = function(fmt, ...) emit("INFO",  module_name, fmt, ...) end,
    warn  = function(fmt, ...) emit("WARN",  module_name, fmt, ...) end,
    error = function(fmt, ...) emit("ERROR", module_name, fmt, ...) end,
  }
end

--- Get recent log entries (for :VaultDebug integration).
--- Returns the tail of the log file, or instructions if file logging is off.
---@param n? number  Number of lines to return (default 50)
---@return string[]
function M.tail(n)
  n = n or 50
  if not _log_file then
    return { "File logging is disabled. Set config.log.file to enable." }
  end
  local f = io.open(_log_file, "r")
  if not f then
    return { "Log file does not exist yet: " .. _log_file }
  end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  -- Return last n lines
  if #lines <= n then return lines end
  local result = {}
  for i = #lines - n + 1, #lines do
    result[#result + 1] = lines[i]
  end
  return result
end

return M
```

### Config Integration

Add to `config.lua`:

```lua
M.log = {
  --- Minimum level for vim.notify() output.
  --- "DEBUG" shows everything, "ERROR" shows only errors, "WARN" is a good default.
  notify_level = "WARN",
  --- Minimum level for file logging.
  file_level = "DEBUG",
  --- Log file path. nil disables file logging. Set to a path inside the vault
  --- or to a temp path for debugging.
  file = nil,  -- e.g., vim.fn.stdpath("data") .. "/vault.log"
}
```

### VaultDebug Command Integration

Extend the existing `:VaultDebug` family with `:VaultLog`:

```lua
vim.api.nvim_create_user_command("VaultLog", function(cmd)
  local log = require("andrew.vault.vault_log")
  local n = tonumber(cmd.args) or 50
  local lines = log.tail(n)
  -- Show in a scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "log"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
end, { nargs = "?", desc = "Show vault log tail (default 50 lines)" })
```

---

## Migration Strategy

### Phase 1: Create Logger Module (standalone, no breaking changes)

**Scope:** Add `vault_log.lua`, config entries, and `:VaultLog` command.

**Work:**
1. Create `lua/andrew/vault/vault_log.lua` with the skeleton above.
2. Add `M.log` section to `config.lua`.
3. Call `log.configure()` from `init.lua` after config is loaded.
4. Register `VaultLog` command.
5. Register `VimLeavePre` autocmd to call `log.close()`.

**Risk:** None. No existing code is changed.

### Phase 2: Convert Critical Modules

**Scope:** vault_index.lua, engine.lua, wikilinks.lua.

**Target changes per module:**

| Module | Change |
|---|---|
| vault_index.lua | Add `return nil, err` to `_parse_file`, `load`, `_persist`. Log persistence failures via `log.warn()`. |
| engine.lua | Replace `vim.notify("Vault: " .. err, ERROR)` in `run()`/`input()`/`select()` with `log.error()`. Convert `read_file()` and `read_file_lines()` to return consistent `nil, err` on failure. |
| wikilinks.lua | Convert `resolve_link()` to return `nil, reason_string`. Update `follow_link()` to use the reason in its notification. |

**Estimated scope:** ~40 lines changed per module.

### Phase 3: Convert Remaining Modules (gradual, per-PR)

**Priority order based on error density:**

1. **embed.lua** (10 vim.notify, 11 pcall) -- complex error paths, biggest
   debugging benefit.
2. **rename.lua** (13 vim.notify) -- user-facing workflow, benefits from
   structured logging.
3. **linkcheck.lua** (18 vim.notify) -- diagnostic module, natural fit for
   logger scopes.
4. **preview.lua** (8 vim.notify, 5 pcall) -- suppress debug noise in normal
   use.
5. **Highlight modules** (wikilink_highlights, tag_highlights, inline_fields,
   highlights) -- 30+ unlogged pcall sites.
6. **Remaining modules** -- alphabetical sweep.

**Convention:** Each converted module gets a scoped logger at the top:

```lua
local log = require("andrew.vault.vault_log").scope("embed")
```

---

## Example Transformations

### Example 1: vault_index.lua `_persist()` -- Silent Failure to Logged Failure

**Before** (current code, `lua/andrew/vault/vault_index.lua` lines 177-197):

```lua
function M.VaultIndex:_persist()
  cleanup.close_timer(self._persist_timer)
  self._persist_timer = nil

  local dir = self.vault_path .. "/.vault-index"
  vim.fn.mkdir(dir, "p")

  local data = {
    version = SCHEMA_VERSION,
    vault_path = self.vault_path,
    built_at = os.time(),
    files = self.files,
  }
  local ok, json = pcall(vim.json.encode, data)
  if not ok then return end                              -- SILENT

  local f = io.open(self:_index_path(), "w")
  if not f then return end                                -- SILENT
  f:write(json)
  f:close()
end
```

**After:**

```lua
local log = require("andrew.vault.vault_log").scope("index")

function M.VaultIndex:_persist()
  cleanup.close_timer(self._persist_timer)
  self._persist_timer = nil

  local dir = self.vault_path .. "/.vault-index"
  vim.fn.mkdir(dir, "p")

  local data = {
    version = SCHEMA_VERSION,
    vault_path = self.vault_path,
    built_at = os.time(),
    files = self.files,
  }
  local ok, json = pcall(vim.json.encode, data)
  if not ok then
    log.error("JSON encode failed: %s", tostring(json))
    return nil, "JSON encode failed: " .. tostring(json)
  end

  local f, io_err = io.open(self:_index_path(), "w")
  if not f then
    log.error("Cannot write index: %s", io_err or "unknown")
    return nil, "cannot write index: " .. (io_err or "unknown")
  end
  f:write(json)
  f:close()
  log.debug("Persisted index (%d files)", vim.tbl_count(self.files))
  return true, nil
end
```

### Example 2: engine.lua `read_file()` -- Adding Error Reason

**Before** (current code, `lua/andrew/vault/engine.lua` lines 296-302):

```lua
function M.read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end             -- WHY did it fail?
  local content = file:read("*a")
  file:close()
  return content
end
```

**After:**

```lua
function M.read_file(path)
  local file, err = io.open(path, "r")
  if not file then
    return nil, "cannot open " .. path .. ": " .. (err or "unknown")
  end
  local content = file:read("*a")
  file:close()
  if not content then
    return nil, "read returned nil for " .. path
  end
  return content, nil
end
```

### Example 3: wikilinks.lua `follow_link()` -- Structured Error in User Command

**Before** (current code, `lua/andrew/vault/wikilinks.lua` lines 264-357,
abridged):

```lua
local function follow_link()
  local details = link_utils.get_wikilink_under_cursor()
  if details then
    if details.name ~= "" then
      local link = details.name
      local path = resolve_link(link)
      if path then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        if details.heading then
          local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
          local line = link_utils.find_heading_line(lines, details.heading)
          if line then
            vim.api.nvim_win_set_cursor(0, { line, 0 })
          end
          -- Heading not found: SILENTLY ignored
        end
      else
        -- ... create new note or show temporal alias ...
      end
    end
  end
  -- ...
end
```

**After:**

```lua
local log = require("andrew.vault.vault_log").scope("wikilinks")

--- resolve_link now returns (path, nil) or (nil, reason)
local function resolve_link(link_name, bufnr)
  if is_path_like(link_name) then
    local path = resolve_relative(link_name, bufnr)
    if path then return path, nil end
  end

  local idx = vault_index.current()
  if idx and idx:is_ready() then
    local paths = idx:resolve_name(link_name)
    if paths and #paths > 0 then
      return pick_closest(paths), nil
    end
  elseif not idx then
    return nil, "vault index not initialized"
  elseif not idx:is_ready() then
    return nil, "vault index still building"
  end

  local temporal_path = resolve_temporal(link_name)
  if temporal_path then return temporal_path, nil end

  return nil, "no matching note found"
end

local function follow_link()
  local details = link_utils.get_wikilink_under_cursor()
  if details and details.name ~= "" then
    local link = details.name
    local path, err = resolve_link(link)
    if path then
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      if details.heading then
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local line = link_utils.find_heading_line(lines, details.heading)
        if line then
          vim.api.nvim_win_set_cursor(0, { line, 0 })
        else
          log.warn("Heading not found: #%s in %s", details.heading, link)
          vim.notify("Heading not found: #" .. details.heading, vim.log.levels.WARN)
        end
      end
    else
      log.debug("resolve_link('%s') failed: %s", link, err)
      -- ... continue with note creation or temporal alias ...
    end
  end
end
```

### Example 4: Highlight Modules -- Logging Discarded pcall Errors

**Before** (current pattern in `wikilink_highlights.lua`, repeated ~10 times):

```lua
pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, bracket_open_start, {
  end_col = bracket_open_start + 2,
  conceal = "",
})
```

**After:**

```lua
local log = require("andrew.vault.vault_log").scope("wikilink_hl")

local ok, err = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, bracket_open_start, {
  end_col = bracket_open_start + 2,
  conceal = "",
})
if not ok then
  log.debug("extmark failed at row %d col %d: %s", row, bracket_open_start, err)
end
```

Note: For high-frequency extmark calls (called per-line on every redraw), the
`log.debug()` overhead is negligible because file-level logging uses buffered
I/O and notify-level filtering means `vim.notify()` is never called at DEBUG
level in normal operation.

---

## Guidelines for Future Code

### Decision Tree: Which Pattern to Use

```
Is the condition a bug in the calling code?
  YES --> assert(condition, "message")
  NO  --> continue

Is this a user-facing command or keymap handler?
  YES --> pcall(internal_fn) + vim.notify(user_message) or log.warn()/log.error()
  NO  --> continue

Is this an internal function that can fail at runtime?
  YES --> return nil, "reason string"
  NO  --> return the value normally

Should the error be visible during normal operation?
  YES (user needs to act) --> log.warn() or log.error()
  NO  (developer info)    --> log.debug()
```

### Error String Conventions

- Start with a lowercase verb describing what failed: "cannot open", "failed to
  parse", "index not ready".
- Include the relevant context (path, note name, line number).
- Do NOT include the "Vault: " prefix -- the logger adds scope automatically.
- Do NOT include the severity -- the log level conveys it.

```lua
-- GOOD
return nil, "cannot open " .. path .. ": " .. io_err

-- BAD
return nil, "Vault: ERROR: Failed to open file!"
```

### When to Use Each Log Level

| Level | Use for | Example |
|---|---|---|
| `DEBUG` | Internal tracing, pcall error details, cache hit/miss | `log.debug("cache miss for '%s'", name)` |
| `INFO` | Successful user-initiated operations | `log.info("Created note: %s", rel_path)` |
| `WARN` | Recoverable issues the user should be aware of | `log.warn("Image not found: %s", image_name)` |
| `ERROR` | Failures that prevent a requested operation | `log.error("Cannot persist index: %s", err)` |

### pcall Usage Guidelines

1. **Always inspect the return value** unless the call is a best-effort cleanup
   (e.g., closing a window that may already be closed).
2. **Log at DEBUG** for expected failures (extmark on invalid buffer, treesitter
   not available).
3. **Log at WARN/ERROR** for unexpected failures (JSON encode of valid data,
   file write with sufficient permissions).
4. **Never wrap large blocks** in pcall -- wrap the specific call that can throw
   and handle the error precisely.

### Module Template

New vault modules should follow this structure:

```lua
local log = require("andrew.vault.vault_log").scope("module_name")

local M = {}

--- Internal: returns value or nil + error string.
---@return SomeType|nil
---@return string|nil err
local function do_something(arg)
  local result, err = some_operation(arg)
  if not result then
    return nil, "do_something failed: " .. err
  end
  return result, nil
end

--- Public: user command handler.
function M.command()
  local result, err = do_something(arg)
  if not result then
    log.warn("Could not do something: %s", err)
    return
  end
  log.info("Did something successfully")
end

return M
```

---

## Appendix: Files Requiring No Changes

The following modules already follow acceptable patterns and need no migration:

- **config.lua** -- Pure configuration, no error paths.
- **slug.lua** -- Pure computation, no I/O.
- **block_patterns.lua** -- Pure pattern matching.
- **date_utils.lua** -- Pure computation with `nil` returns for invalid input
  (appropriate since invalid dates are expected, not errors).
- **resource_cleanup.lua** -- Best-effort cleanup; pcall usage is correct here.
