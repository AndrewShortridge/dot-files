# Fortran Linting Implementation Guide

This document describes how to implement VS Code Modern Fortran-style linting in Neovim using nvim-lint.

## Overview

The VS Code Modern Fortran extension lints Fortran code by:
1. Spawning the compiler as a subprocess with syntax-check flags
2. Parsing stderr output for diagnostics
3. Pushing diagnostics to the editor's diagnostic system
4. Triggering on file open and file save events

Your current `linting.lua` already implements this pattern. This guide covers enhancements to reach feature parity.

---

## Step 1: Add User-Configurable Settings

Create global variables that users can set in their config to customize linting behavior.

### Implementation

Add this near the top of the `config` function:

```lua
-- =============================================================================
-- User Configuration (set these in your init.lua before loading this plugin)
-- =============================================================================
-- vim.g.fortran_linter_compiler = "gfortran"  -- gfortran | ifort | ifx | nagfor | Disabled
-- vim.g.fortran_linter_compiler_path = nil    -- Custom path to compiler executable
-- vim.g.fortran_linter_include_paths = {}     -- Array of include directories (supports globs)
-- vim.g.fortran_linter_extra_args = {}        -- Additional compiler flags

local config = {
  compiler = vim.g.fortran_linter_compiler or "gfortran",
  compiler_path = vim.g.fortran_linter_compiler_path,
  include_paths = vim.g.fortran_linter_include_paths or {},
  extra_args = vim.g.fortran_linter_extra_args or {},
}
```

---

## Step 2: Add Support for Multiple Compilers

Define linter configurations for each supported compiler.

### Compiler Flag Reference

| Compiler | Syntax-Only Flag | Warning Flag | Include Flag |
|----------|------------------|--------------|--------------|
| gfortran | `-fsyntax-only`  | `-Wall`      | `-I`         |
| ifort    | `-syntax-only`   | `-warn all`  | `-I`         |
| ifx      | `-syntax-only`   | `-warn all`  | `-I`         |
| nagfor   | `-c`             | `-w=all`     | `-I`         |

### Implementation

Replace the single gfortran/mpiifx definitions with a compiler registry:

```lua
-- =============================================================================
-- Compiler Definitions
-- =============================================================================

local compilers = {
  gfortran = {
    cmd = "gfortran",
    args = { "-Wall", "-Wextra", "-fsyntax-only", "-fdiagnostics-plain-output" },
    parser = "gcc",  -- Parser type to use
  },
  ifort = {
    cmd = "ifort",
    args = { "-warn", "all", "-syntax-only" },
    parser = "intel",
  },
  ifx = {
    cmd = "ifx",
    args = { "-warn", "all", "-syntax-only" },
    parser = "intel",
  },
  nagfor = {
    cmd = "nagfor",
    args = { "-w=all", "-c" },
    parser = "nag",
  },
}
```

---

## Step 3: Create Parser Functions for Each Compiler

Each compiler has a different output format. Create dedicated parsers.

### GCC/gfortran Format
```
filename:line:col: severity: message
```

### Intel (ifort/ifx) Format
```
filename(line): severity #number: message
```

### NAG Format
```
severity: filename, line line_num: message
```

### Implementation

```lua
-- =============================================================================
-- Diagnostic Parsers
-- =============================================================================

local parsers = {}

-- GCC/gfortran parser
function parsers.gcc(output, bufnr)
  local diagnostics = {}
  local fname = vim.api.nvim_buf_get_name(bufnr)

  for line in output:gmatch("[^\r\n]+") do
    local file, lnum, col, severity, msg =
      line:match("^(.+):(%d+):(%d+):%s*(%w+):%s*(.+)$")

    if lnum and msg then
      if not file or file == fname or
         vim.fn.fnamemodify(file, ":t") == vim.fn.fnamemodify(fname, ":t") then
        local sev = vim.diagnostic.severity.ERROR
        if severity:lower() == "warning" then
          sev = vim.diagnostic.severity.WARN
        elseif severity:lower() == "note" then
          sev = vim.diagnostic.severity.INFO
        end

        table.insert(diagnostics, {
          lnum = tonumber(lnum) - 1,
          col = tonumber(col) - 1,
          message = msg,
          severity = sev,
          source = "gfortran",
        })
      end
    end
  end
  return diagnostics
end

-- Intel (ifort/ifx) parser
function parsers.intel(output, bufnr)
  local diagnostics = {}
  local fname = vim.api.nvim_buf_get_name(bufnr)

  for line in output:gmatch("[^\r\n]+") do
    local file, lnum, severity, msg =
      line:match("^(.+)%((%d+)%):%s*(%w+)%s*#%d+:%s*(.+)$")

    if lnum and msg then
      if not file or file == fname or
         vim.fn.fnamemodify(file, ":t") == vim.fn.fnamemodify(fname, ":t") then
        local sev = vim.diagnostic.severity.ERROR
        if severity:lower() == "warning" then
          sev = vim.diagnostic.severity.WARN
        elseif severity:lower() == "remark" then
          sev = vim.diagnostic.severity.INFO
        end

        table.insert(diagnostics, {
          lnum = tonumber(lnum) - 1,
          col = 0,
          message = msg,
          severity = sev,
          source = "intel",
        })
      end
    end
  end
  return diagnostics
end

-- NAG parser
function parsers.nag(output, bufnr)
  local diagnostics = {}
  local fname = vim.api.nvim_buf_get_name(bufnr)

  for line in output:gmatch("[^\r\n]+") do
    -- NAG format: "Error: filename, line 123: message"
    local severity, file, lnum, msg =
      line:match("^(%w+):%s*(.+),%s*line%s+(%d+):%s*(.+)$")

    if lnum and msg then
      if not file or file == fname or
         vim.fn.fnamemodify(file, ":t") == vim.fn.fnamemodify(fname, ":t") then
        local sev = vim.diagnostic.severity.ERROR
        if severity:lower() == "warning" then
          sev = vim.diagnostic.severity.WARN
        elseif severity:lower() == "info" or severity:lower() == "extension" then
          sev = vim.diagnostic.severity.INFO
        end

        table.insert(diagnostics, {
          lnum = tonumber(lnum) - 1,
          col = 0,
          message = msg,
          severity = sev,
          source = "nagfor",
        })
      end
    end
  end
  return diagnostics
end
```

---

## Step 4: Implement Include Path Resolution with Glob Support

The VS Code extension supports glob patterns like `${workspaceFolder}/include/**`.

### Implementation

```lua
-- =============================================================================
-- Include Path Resolution
-- =============================================================================

local function expand_include_paths(paths, project_root)
  local expanded = {}

  for _, path in ipairs(paths) do
    -- Replace ${workspaceFolder} with project root
    local resolved = path:gsub("%${workspaceFolder}", project_root)

    -- Check if path contains glob patterns
    if resolved:match("%*") then
      -- Use vim.fn.glob to expand the pattern
      local matches = vim.fn.glob(resolved, false, true)
      for _, match in ipairs(matches) do
        if vim.fn.isdirectory(match) == 1 then
          table.insert(expanded, match)
        end
      end
    else
      -- Direct path - add if it exists
      if vim.fn.isdirectory(resolved) == 1 then
        table.insert(expanded, resolved)
      end
    end
  end

  return expanded
end

local function build_include_args(project_root)
  local args = {}
  local code_dir = project_root .. "/code"

  -- Always include code/ directory if it exists
  if vim.fn.isdirectory(code_dir) == 1 then
    table.insert(args, "-I" .. code_dir)
  end

  -- Add user-configured include paths
  local user_paths = expand_include_paths(config.include_paths, project_root)
  for _, path in ipairs(user_paths) do
    table.insert(args, "-I" .. path)
  end

  return args
end
```

---

## Step 5: Create Dynamic Linter Registration

Register the appropriate linter based on user configuration.

### Implementation

```lua
-- =============================================================================
-- Linter Registration
-- =============================================================================

local function register_fortran_linter()
  if config.compiler == "Disabled" then
    lint.linters_by_ft.fortran = {}
    lint.linters_by_ft["fortran_free"] = {}
    lint.linters_by_ft["fortran_fixed"] = {}
    return
  end

  local compiler_config = compilers[config.compiler]
  if not compiler_config then
    vim.notify("Unknown Fortran compiler: " .. config.compiler, vim.log.levels.ERROR)
    return
  end

  -- Determine command path
  local cmd = config.compiler_path or compiler_config.cmd

  -- Verify compiler exists
  if vim.fn.executable(cmd) ~= 1 then
    vim.notify("Fortran compiler not found: " .. cmd, vim.log.levels.WARN)
    return
  end

  -- Register the linter
  lint.linters[config.compiler] = {
    cmd = cmd,
    args = function()
      local project_root = get_fortran_project_root()
      local args = vim.deepcopy(compiler_config.args)

      -- Add include paths
      local include_args = build_include_args(project_root)
      for _, inc in ipairs(include_args) do
        table.insert(args, inc)
      end

      -- Add user extra args
      for _, arg in ipairs(config.extra_args) do
        table.insert(args, arg)
      end

      return args
    end,
    stdin = false,
    append_fname = true,
    stream = "stderr",
    ignore_exitcode = true,
    parser = parsers[compiler_config.parser],
    cwd = get_fortran_project_root,
  }

  -- Set for all Fortran filetypes
  lint.linters_by_ft.fortran = { config.compiler }
  lint.linters_by_ft["fortran_free"] = { config.compiler }
  lint.linters_by_ft["fortran_fixed"] = { config.compiler }
end
```

---

## Step 6: Set Up Autocommands for Linting Events

Match the VS Code extension's behavior: lint on open and save.

### Implementation

```lua
-- =============================================================================
-- Auto-lint Autocommands
-- =============================================================================

vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
  group = vim.api.nvim_create_augroup("FortranLinting", { clear = true }),
  pattern = { "*.f90", "*.F90", "*.f95", "*.f03", "*.f08", "*.f", "*.F" },
  callback = function()
    require("lint").try_lint()
  end,
})
```

**Note:** The VS Code extension does NOT lint while typing. Diagnostics persist in the editor after save until the next lint run, giving the appearance of real-time feedback.

---

## Step 7: Add User Commands for Runtime Configuration

Allow users to change settings without restarting Neovim.

### Implementation

```lua
-- =============================================================================
-- User Commands
-- =============================================================================

-- Change compiler at runtime
vim.api.nvim_create_user_command("FortranLinter", function(opts)
  local compiler = opts.args
  if compiler == "gfortran" or compiler == "ifort" or
     compiler == "ifx" or compiler == "nagfor" or compiler == "Disabled" then
    config.compiler = compiler
    register_fortran_linter()
    vim.notify("Fortran linter set to: " .. compiler)
    -- Re-lint current buffer
    if compiler ~= "Disabled" then
      require("lint").try_lint()
    end
  else
    vim.notify("Usage: :FortranLinter gfortran|ifort|ifx|nagfor|Disabled", vim.log.levels.WARN)
  end
end, {
  nargs = 1,
  complete = function()
    return { "gfortran", "ifort", "ifx", "nagfor", "Disabled" }
  end,
})

-- Add include path at runtime
vim.api.nvim_create_user_command("FortranAddInclude", function(opts)
  table.insert(config.include_paths, opts.args)
  register_fortran_linter()
  vim.notify("Added include path: " .. opts.args)
end, { nargs = 1 })

-- Show current configuration
vim.api.nvim_create_user_command("FortranLinterInfo", function()
  local info = {
    "Fortran Linter Configuration:",
    "  Compiler: " .. config.compiler,
    "  Path: " .. (config.compiler_path or "(default)"),
    "  Include paths: " .. vim.inspect(config.include_paths),
    "  Extra args: " .. vim.inspect(config.extra_args),
  }
  vim.notify(table.concat(info, "\n"))
end, {})
```

---

## Step 8: Example User Configuration

Users can customize behavior in their `init.lua`:

```lua
-- Set before lazy.nvim loads the linting plugin
vim.g.fortran_linter_compiler = "gfortran"
vim.g.fortran_linter_compiler_path = "/usr/local/bin/gfortran-13"
vim.g.fortran_linter_include_paths = {
  "${workspaceFolder}/include",
  "${workspaceFolder}/modules/**",
  "/usr/local/include/fortran",
}
vim.g.fortran_linter_extra_args = {
  "-fdefault-real-8",
  "-fcheck=bounds",
}
```

---

## Summary

| Feature | VS Code Extension | This Implementation |
|---------|-------------------|---------------------|
| Lint on save | Yes | Yes |
| Lint on open | Yes | Yes |
| Lint while typing | No | No |
| gfortran support | Yes | Yes |
| ifort/ifx support | Yes | Yes |
| nagfor support | Yes | Yes |
| Custom compiler path | Yes | Yes |
| Include paths with globs | Yes | Yes |
| Extra compiler args | Yes | Yes |
| Runtime config commands | N/A | Yes |

---

## Files to Modify

1. `lua/andrew/plugins/linting.lua` - Main implementation file

## Optional Enhancements

- **FYPP preprocessor support** - Run `.fypp` files through preprocessor before linting
- **Per-project config** - Read settings from `.fortls` or `fortran.json` in project root
- **Diagnostic deduplication** - Remove duplicate diagnostics (VS Code extension does this)
