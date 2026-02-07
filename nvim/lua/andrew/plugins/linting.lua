-- =============================================================================
-- Linter Configuration (nvim-lint)
-- =============================================================================
-- Configures nvim-lint for running external linters on code.
-- Linters run automatically on buffer read/write and insert leave.

return {
  -- Plugin: nvim-lint - Asynchronous linter plugin for Neovim
  -- Repository: https://github.com/mfussenegger/nvim-lint
  "mfussenegger/nvim-lint",

  -- Events: Load and run linters when reading or writing files
  event = { "BufReadPost", "BufWritePost" },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load lint module
    local lint = require("lint")

    -- =============================================================================
    -- User Configuration (set these in your init.lua before loading this plugin)
    -- =============================================================================
    -- vim.g.fortran_linter_compiler = "gfortran"  -- gfortran | ifort | ifx | nagfor | Disabled
    -- vim.g.fortran_linter_compiler_path = nil    -- Custom path to compiler executable
    -- vim.g.fortran_linter_include_paths = {}     -- Array of include directories (supports globs)
    -- vim.g.fortran_linter_extra_args = {}        -- Additional compiler flags

    local fortran_config = {
      compiler = vim.g.fortran_linter_compiler or "gfortran",
      compiler_path = vim.g.fortran_linter_compiler_path,
      include_paths = vim.g.fortran_linter_include_paths or {},
      extra_args = vim.g.fortran_linter_extra_args or {},
    }

    -- =============================================================================
    -- Compiler Definitions
    -- =============================================================================

    local compilers = {
      gfortran = {
        cmd = "gfortran",
        args = { "-Wall", "-Wextra", "-fsyntax-only", "-fdiagnostics-plain-output" },
        parser = "gcc",
      },
      mpiifx = {
        cmd = "mpiifx",
        args = { "-warn", "all", "-syntax-only" },
        parser = "intel",
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

    -- =============================================================================
    -- Diagnostic Parsers
    -- =============================================================================

    local parsers = {}

    -- GCC/gfortran parser
    function parsers.gcc(output, bufnr)
      local diagnostics = {}
      local fname = vim.api.nvim_buf_get_name(bufnr)

      -- DEBUG: See if parser is called and what output it receives
      vim.schedule(function()
        vim.notify("Parser called! Output length: " .. #output, vim.log.levels.INFO)
        if #output > 0 then
          vim.notify("First 200 chars: " .. output:sub(1, 200), vim.log.levels.INFO)
        end
      end)

      for line in output:gmatch("[^\r\n]+") do
        -- Pattern handles both "Error:" and "Fatal Error:" formats
        local file, lnum, col, severity, msg =
          line:match("^(.+):(%d+):(%d+):%s*(%w+%s*%w*):%s*(.+)$")

        if lnum and msg then
          if not file or file == fname or
             vim.fn.fnamemodify(file, ":t") == vim.fn.fnamemodify(fname, ":t") then
            local sev = vim.diagnostic.severity.ERROR
            local sev_lower = severity:lower()
            if sev_lower == "warning" then
              sev = vim.diagnostic.severity.WARN
            elseif sev_lower == "note" then
              sev = vim.diagnostic.severity.INFO
            end
            -- "error" and "fatal error" both map to ERROR (default)

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

    -- =============================================================================
    -- Helper Functions
    -- =============================================================================

    -- Helper: Find project root (parent of code/ directory)
    local function get_fortran_project_root()
      local root_markers = { ".git", ".fortls", "code" }
      local path = vim.fn.expand("%:p:h")  -- Start from current file's directory

      -- Walk up directory tree looking for markers
      while path ~= "/" do
        for _, marker in ipairs(root_markers) do
          local marker_path = path .. "/" .. marker
          if vim.fn.isdirectory(marker_path) == 1 or vim.fn.filereadable(marker_path) == 1 then
            return path
          end
        end
        path = vim.fn.fnamemodify(path, ":h")
      end
      -- Fallback: use directory of current file
      return vim.fn.expand("%:p:h")
    end

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
      local user_paths = expand_include_paths(fortran_config.include_paths, project_root)
      for _, path in ipairs(user_paths) do
        table.insert(args, "-I" .. path)
      end

      return args
    end

    -- =============================================================================
    -- Linter Registration
    -- =============================================================================

    local function register_fortran_linter()
      if fortran_config.compiler == "Disabled" then
        lint.linters_by_ft.fortran = {}
        lint.linters_by_ft["fortran_free"] = {}
        lint.linters_by_ft["fortran_fixed"] = {}
        return
      end

      local compiler_config = compilers[fortran_config.compiler]
      if not compiler_config then
        vim.notify("Unknown Fortran compiler: " .. fortran_config.compiler, vim.log.levels.ERROR)
        return
      end

      -- Determine command path
      local cmd = fortran_config.compiler_path or compiler_config.cmd

      -- Verify compiler exists
      if vim.fn.executable(cmd) ~= 1 then
        vim.notify("Fortran compiler not found: " .. cmd, vim.log.levels.WARN)
        return
      end

      -- Register the linter
      lint.linters[fortran_config.compiler] = {
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
          for _, arg in ipairs(fortran_config.extra_args) do
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
      lint.linters_by_ft.fortran = { fortran_config.compiler }
      lint.linters_by_ft["fortran_free"] = { fortran_config.compiler }
      lint.linters_by_ft["fortran_fixed"] = { fortran_config.compiler }
    end

    -- =============================================================================
    -- Ruff Configuration (Python Linter)
    -- =============================================================================
    -- Configure Ruff linter with conda path and extended rule selection

    -- Pin ruff to miniconda3 binary for consistent behavior
    if lint.linters.ruff then
      local conda_ruff = vim.fn.expand("$HOME/miniconda3/bin/ruff")
      if vim.fn.executable(conda_ruff) == 1 then
        lint.linters.ruff.cmd = conda_ruff
      end
    end

    -- =============================================================================
    -- ESLint Configuration
    -- =============================================================================
    -- Configure eslint arguments for consistent output format

    if lint.linters.eslint then
      lint.linters.eslint.args = {
        "--format", "unix",      -- Unix-style output
        "--stdin",               -- Read from stdin
        "--stdin-filename", "$FILENAME",  -- Pass filename for config resolution
      }
    end

    -- =============================================================================
    -- Linter Mapping by File Type
    -- =============================================================================
    -- Maps file types to their appropriate linters

    lint.linters_by_ft = {
      -- Python: Use ruff for linting
      python = { "ruff" },

      -- JavaScript/TypeScript: Use eslint from conda environment
      javascript = { "eslint" },
      typescript = { "eslint" },
      javascriptreact = { "eslint" },
      typescriptreact = { "eslint" },
      vue = { "eslint" },

      -- C/C++: Use cppcheck for static analysis
      c = { "cppcheck" },
      cpp = { "cppcheck" },
    }

    -- Register Fortran linter based on user configuration
    register_fortran_linter()

    -- =============================================================================
    -- User Commands
    -- =============================================================================

    -- Change compiler at runtime
    vim.api.nvim_create_user_command("FortranLinter", function(opts)
      local compiler = opts.args
      if compiler == "gfortran" or compiler == "mpiifx" or compiler == "ifort" or
         compiler == "ifx" or compiler == "nagfor" or compiler == "Disabled" then
        fortran_config.compiler = compiler
        register_fortran_linter()
        vim.notify("Fortran linter set to: " .. compiler)
        -- Re-lint current buffer
        if compiler ~= "Disabled" then
          require("lint").try_lint()
        end
      else
        vim.notify("Usage: :FortranLinter gfortran|mpiifx|ifort|ifx|nagfor|Disabled", vim.log.levels.WARN)
      end
    end, {
      nargs = 1,
      complete = function()
        return { "gfortran", "mpiifx", "ifort", "ifx", "nagfor", "Disabled" }
      end,
    })

    -- Add include path at runtime
    vim.api.nvim_create_user_command("FortranAddInclude", function(opts)
      table.insert(fortran_config.include_paths, opts.args)
      register_fortran_linter()
      vim.notify("Added include path: " .. opts.args)
    end, { nargs = 1 })

    -- Show current configuration
    vim.api.nvim_create_user_command("FortranLinterInfo", function()
      local info = {
        "Fortran Linter Configuration:",
        "  Compiler: " .. fortran_config.compiler,
        "  Path: " .. (fortran_config.compiler_path or "(default)"),
        "  Include paths: " .. vim.inspect(fortran_config.include_paths),
        "  Extra args: " .. vim.inspect(fortran_config.extra_args),
      }
      vim.notify(table.concat(info, "\n"))
    end, {})

    -- =============================================================================
    -- Auto-lint Autocommands
    -- =============================================================================
    -- Run linters automatically on various events

    -- General linting autocommand (all filetypes)
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "InsertLeave", "FileType" }, {
      group = vim.api.nvim_create_augroup("AndrewLinting", { clear = true }),
      callback = function()
        require("lint").try_lint()
      end,
    })

    -- Fortran-specific linting (matches VS Code Modern Fortran behavior)
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
      group = vim.api.nvim_create_augroup("FortranLinting", { clear = true }),
      pattern = { "*.f90", "*.F90", "*.f95", "*.f03", "*.f08", "*.f", "*.F" },
      callback = function()
        require("lint").try_lint()
      end,
    })

    -- =============================================================================
    -- Manual Lint Keybindings
    -- =============================================================================

    local keymap = vim.keymap

    -- Namespace for single-file Fortran diagnostics
    local single_file_ns = vim.api.nvim_create_namespace("fortran_single_file_lint")

    -- Configure diagnostics for single-file namespace
    vim.diagnostic.config({
      virtual_text = true,
      signs = true,
      underline = true,
      update_in_insert = false,
      severity_sort = true,
    }, single_file_ns)

    -- Run linter for current buffer (direct implementation for Fortran)
    keymap.set("n", "<leader>ll", function()
      local ft = vim.bo.filetype

      -- For non-Fortran files, use nvim-lint
      if ft ~= "fortran" and ft ~= "fortran_free" and ft ~= "fortran_fixed" then
        require("lint").try_lint()
        return
      end

      -- Direct Fortran linting (same approach as workspace lint)
      local compiler_cfg = compilers[fortran_config.compiler]
      if not compiler_cfg then
        vim.notify("No Fortran compiler configured", vim.log.levels.WARN)
        return
      end

      local cmd = fortran_config.compiler_path or compiler_cfg.cmd
      local project_root = get_fortran_project_root()
      local file = vim.api.nvim_buf_get_name(0)

      -- Build args
      local args = vim.deepcopy(compiler_cfg.args)
      local include_args = build_include_args(project_root)
      for _, inc in ipairs(include_args) do
        table.insert(args, inc)
      end
      for _, arg in ipairs(fortran_config.extra_args) do
        table.insert(args, arg)
      end
      table.insert(args, file)

      -- Clear previous diagnostics for this buffer
      vim.diagnostic.reset(single_file_ns, 0)

      -- Run linter
      vim.fn.jobstart({ cmd, unpack(args) }, {
        cwd = project_root,
        stderr_buffered = true,
        on_stderr = function(_, data)
          if data and #data > 0 then
            local output = table.concat(data, "\n")
            if output ~= "" then
              local diagnostics = parsers[compiler_cfg.parser](output, 0)
              vim.schedule(function()
                vim.diagnostic.set(single_file_ns, 0, diagnostics)
                if #diagnostics > 0 then
                  vim.notify(string.format("Lint: %d issue(s) found", #diagnostics), vim.log.levels.WARN)
                else
                  vim.notify("Lint: no issues", vim.log.levels.INFO)
                end
              end)
            end
          end
        end,
        on_exit = function(_, code)
          if code == 0 then
            vim.schedule(function()
              vim.notify("Lint: no issues", vim.log.levels.INFO)
            end)
          end
        end,
      })
    end, { desc = "Lint: run linters for current buffer" })

    -- Run ruff specifically for Python files
    keymap.set("n", "<leader>lm", function()
      require("lint").try_lint("ruff")
    end, { desc = "Lint: run ruff (Python)" })

    -- Toggle Fortran linter between available compilers
    keymap.set("n", "<leader>lf", function()
      local current = fortran_config.compiler
      local order = { "gfortran", "mpiifx", "ifort", "ifx", "nagfor", "Disabled" }
      local next_idx = 1
      for i, comp in ipairs(order) do
        if comp == current then
          next_idx = (i % #order) + 1
          break
        end
      end
      local new = order[next_idx]
      fortran_config.compiler = new
      register_fortran_linter()
      vim.notify("Fortran linter: " .. new)
    end, { desc = "Lint: Toggle Fortran linter" })

    -- Debug: Run Fortran linter explicitly with verbose output
    keymap.set("n", "<leader>lF", function()
      local ft = vim.bo.filetype
      local linters = lint.linters_by_ft[ft]
      vim.notify("Filetype: " .. ft .. ", Linters: " .. vim.inspect(linters))
      if linters and #linters > 0 then
        local linter = lint.linters[linters[1]]
        if linter then
          vim.notify("CWD: " .. (type(linter.cwd) == "function" and linter.cwd() or (linter.cwd or "nil")))
          local args = type(linter.args) == "function" and linter.args() or linter.args
          vim.notify("Args: " .. vim.inspect(args))
        end
        lint.try_lint()
      end
    end, { desc = "Lint: Run Fortran linter (debug)" })

    -- Namespace for workspace diagnostics
    local workspace_ns = vim.api.nvim_create_namespace("fortran_workspace_lint")

    -- Configure diagnostics for workspace namespace (enable virtual text, signs, etc.)
    vim.diagnostic.config({
      virtual_text = true,
      signs = true,
      underline = true,
      update_in_insert = false,
      severity_sort = true,
    }, workspace_ns)

    -- Global table to store workspace diagnostic counts (accessible from lualine)
    _G.fortran_workspace_diagnostics = { errors = 0, warnings = 0, info = 0 }

    -- Lint entire Fortran workspace (all files in code/ directory)
    keymap.set("n", "<leader>lw", function()
      local project_root = get_fortran_project_root()
      local code_dir = project_root .. "/code"

      -- Find all Fortran files
      local files = vim.fn.globpath(code_dir, "*.f90", false, true)
      vim.list_extend(files, vim.fn.globpath(code_dir, "*.F90", false, true))
      vim.list_extend(files, vim.fn.globpath(code_dir, "*.f95", false, true))
      vim.list_extend(files, vim.fn.globpath(code_dir, "*.f03", false, true))
      vim.list_extend(files, vim.fn.globpath(code_dir, "*.f08", false, true))

      if #files == 0 then
        vim.notify("No Fortran files found in " .. code_dir, vim.log.levels.WARN)
        return
      end

      -- Get current compiler configuration
      local compiler_cfg = compilers[fortran_config.compiler]
      if not compiler_cfg then
        vim.notify("No Fortran compiler configured", vim.log.levels.WARN)
        return
      end

      local cmd = fortran_config.compiler_path or compiler_cfg.cmd
      local include_args = build_include_args(project_root)

      -- Build args
      local args = vim.deepcopy(compiler_cfg.args)
      for _, inc in ipairs(include_args) do
        table.insert(args, inc)
      end
      for _, arg in ipairs(fortran_config.extra_args) do
        table.insert(args, arg)
      end

      -- Add all files to args
      for _, file in ipairs(files) do
        table.insert(args, file)
      end

      vim.notify("Linting " .. #files .. " Fortran files with " .. fortran_config.compiler .. "...")

      -- Run linter asynchronously
      vim.fn.jobstart({ cmd, unpack(args) }, {
        cwd = project_root,
        stderr_buffered = true,
        on_stderr = function(_, data)
          if data and #data > 0 then
            local output = table.concat(data, "\n")
            if output ~= "" then
              -- Parse results and group by file
              local qf_items = {}
              local diagnostics_by_file = {}
              local error_count = 0
              local warn_count = 0
              local info_count = 0

              local parser_type = compiler_cfg.parser

              for line in output:gmatch("[^\r\n]+") do
                local file, lnum, col, severity, msg

                if parser_type == "intel" then
                  -- Intel format: filename(line): severity #num: message
                  file, lnum, severity, msg = line:match("^(.+)%((%d+)%):%s*(%w+)%s*#%d+:%s*(.+)$")
                  col = 1
                elseif parser_type == "nag" then
                  -- NAG format: severity: filename, line 123: message
                  severity, file, lnum, msg = line:match("^(%w+):%s*(.+),%s*line%s+(%d+):%s*(.+)$")
                  col = 1
                else
                  -- GCC format: filename:line:col: severity: message
                  -- Pattern handles both "Error:" and "Fatal Error:" formats
                  file, lnum, col, severity, msg = line:match("^(.+):(%d+):(%d+):%s*(%w+%s*%w*):%s*(.+)$")
                end

                if file and lnum then
                  -- Quickfix item
                  table.insert(qf_items, {
                    filename = file,
                    lnum = tonumber(lnum),
                    col = tonumber(col) or 1,
                    text = (severity or "error") .. ": " .. (msg or ""),
                    type = (severity or "E"):sub(1, 1):upper(),
                  })

                  -- Determine severity
                  local sev = vim.diagnostic.severity.ERROR
                  local sev_lower = (severity or ""):lower()
                  if sev_lower == "warning" then
                    sev = vim.diagnostic.severity.WARN
                    warn_count = warn_count + 1
                  elseif sev_lower == "note" or sev_lower == "remark" or sev_lower == "info" then
                    sev = vim.diagnostic.severity.INFO
                    info_count = info_count + 1
                  else
                    error_count = error_count + 1
                  end

                  -- Group diagnostics by file
                  if not diagnostics_by_file[file] then
                    diagnostics_by_file[file] = {}
                  end
                  table.insert(diagnostics_by_file[file], {
                    lnum = tonumber(lnum) - 1,
                    col = (tonumber(col) or 1) - 1,
                    message = msg or "",
                    severity = sev,
                    source = fortran_config.compiler,
                  })
                end
              end

              vim.schedule(function()
                -- Update global diagnostics count
                _G.fortran_workspace_diagnostics = {
                  errors = error_count,
                  warnings = warn_count,
                  info = info_count,
                }

                -- DEBUG: Show parsed diagnostics
                local file_count = 0
                for _ in pairs(diagnostics_by_file) do file_count = file_count + 1 end
                vim.notify("DEBUG: Parsed " .. (error_count + warn_count + info_count) .. " diagnostics across " .. file_count .. " files", vim.log.levels.INFO)

                -- Set diagnostics for each file
                for file, diags in pairs(diagnostics_by_file) do
                  -- Get or create buffer for file
                  local bufnr = vim.fn.bufnr(file, true)
                  vim.fn.bufload(bufnr)
                  vim.diagnostic.set(workspace_ns, bufnr, diags)
                  vim.notify("DEBUG: Set " .. #diags .. " diagnostics for buffer " .. bufnr .. " (" .. file .. ")", vim.log.levels.INFO)
                end

                -- Set quickfix list
                if #qf_items > 0 then
                  vim.fn.setqflist(qf_items)
                  vim.cmd("copen")
                  vim.notify(string.format("Workspace: %d errors, %d warnings", error_count, warn_count), vim.log.levels.WARN)
                else
                  vim.notify("No issues found in workspace", vim.log.levels.INFO)
                end
              end)
            else
              vim.schedule(function()
                _G.fortran_workspace_diagnostics = { errors = 0, warnings = 0, info = 0 }
                vim.notify("No issues found in workspace", vim.log.levels.INFO)
              end)
            end
          end
        end,
        on_exit = function(_, code)
          if code == 0 then
            vim.schedule(function()
              _G.fortran_workspace_diagnostics = { errors = 0, warnings = 0, info = 0 }
              vim.notify("Workspace lint complete - no issues", vim.log.levels.INFO)
            end)
          end
        end,
      })
    end, { desc = "Lint: Lint entire Fortran workspace" })

    -- Clear workspace diagnostics
    keymap.set("n", "<leader>lW", function()
      -- Clear all workspace diagnostics
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        vim.diagnostic.reset(workspace_ns, bufnr)
      end
      _G.fortran_workspace_diagnostics = { errors = 0, warnings = 0, info = 0 }
      vim.fn.setqflist({})
      vim.notify("Workspace diagnostics cleared", vim.log.levels.INFO)
    end, { desc = "Lint: Clear workspace diagnostics" })
  end,
}
