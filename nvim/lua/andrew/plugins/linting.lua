-- =============================================================================
-- Linter Configuration (nvim-lint)
-- =============================================================================
-- Configures nvim-lint for running external linters on code.
-- Linters run automatically on buffer read/write and insert leave.

return {
  -- Plugin: nvim-lint - Asynchronous linter plugin for Neovim
  -- Repository: https://github.com/mfussenegger/nvim-lint
  "mfussenegger/nvim-lint",

  -- Filetypes: only load for filetypes that actually have a configured linter
  -- (see linters_by_ft below + register_fortran_linter). Server-less / linter-less
  -- filetypes (markdown, text, ...) never drag nvim-lint in and avoid a no-op
  -- try_lint autocmd firing on every buffer event.
  ft = {
    "python",
    "javascript", "typescript", "javascriptreact", "typescriptreact", "vue",
    "c", "cpp",
    "fortran", "fortran_free", "fortran_fixed",
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- Load lint module
    local lint = require("lint")
    local lua_dirname = require("andrew.vault.link_utils").lua_dirname

    -- =============================================================================
    -- Missing-linter Guard
    -- =============================================================================
    -- nvim-lint spawns its command unconditionally. When the binary is not
    -- installed, uv.spawn fails and nvim-lint raises an ERROR notification from
    -- inside whatever autocmd invoked it -- which aborts the autocmd chain and
    -- surfaces as e.g.
    --   Error in BufReadPost Autocommands for "*": Error running eslint: ENOENT
    -- on EVERY file open of that filetype. The linters below are optional tools
    -- that may or may not be present on a given machine (eslint and cppcheck are
    -- not installed here), so a missing one must be a silent no-op, not an error.
    --
    -- `filter` is nvim-lint's supported hook: it runs after the linter table is
    -- resolved, so `linter.cmd` is available (and may itself be a function).
    local function linter_available(linter)
      local cmd = linter.cmd
      if type(cmd) == "function" then
        local ok, resolved = pcall(cmd)
        if not ok then
          return false
        end
        cmd = resolved
      end
      return type(cmd) == "string" and cmd ~= "" and vim.fn.executable(cmd) == 1
    end

    -- Lint with missing binaries skipped. Automatic (autocmd) callers stay
    -- silent; manual callers pass notify_missing to learn why nothing ran,
    -- since silence in response to an explicit keypress reads as a broken key.
    local function try_lint_available(names, notify_missing)
      if notify_missing then
        local wanted = names
        if type(wanted) == "string" then
          wanted = { wanted }
        end
        wanted = wanted or lint.linters_by_ft[vim.bo.filetype] or {}
        local missing = {}
        for _, name in ipairs(wanted) do
          local l = lint.linters[name]
          if type(l) == "function" then
            local ok, resolved = pcall(l)
            l = ok and resolved or nil
          end
          if not l or not linter_available(l) then
            table.insert(missing, name)
          end
        end
        if #missing > 0 then
          vim.notify(
            "Lint: not installed, skipped: " .. table.concat(missing, ", "),
            vim.log.levels.WARN
          )
        end
      end
      lint.try_lint(names, { filter = linter_available })
    end

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
        -- -Wno-do-subscript: gfortran evaluates DO-loop subscript ranges
        -- without looking at the branch guards inside the loop, so this
        -- project's pervasive `DO nbb = 1,26 / IF(nbb.le.18) THEN
        -- longarray(nbb)` idiom reports as out of bounds every time. Four
        -- false positives on Share-EAM.f90 alone and no true positive found;
        -- the check cannot be made right from outside gfortran.
        --
        -- -fopenmp: without it `!$OMP` is an ordinary comment and a malformed
        -- directive is silently ignored, which compiles and then runs
        -- single-threaded. It also implies -frecursive, which suppresses the
        -- -Wsurprising "moved from stack to static storage" warnings -- a real
        -- change to current output, and the right one, since that hazard only
        -- exists under threading. See andrew.fortran.openmp.
        --
        -- The Intel and NAG equivalents (-qopenmp, -openmp) are deliberately
        -- NOT set: neither compiler works on this machine (the conda mpiifort
        -- wrapper cannot find mpiifx), so the flags cannot be verified, and an
        -- unverified flag in an arg list breaks linting outright rather than
        -- degrading.
        --
        -- -fallow-argument-mismatch: gfortran builds an implicit interface for
        -- an external procedure from its FIRST call site, then hard-errors on
        -- every later call whose argument types differ. The F77 MPI bindings
        -- are typeless by design -- MPI_BCAST takes a buffer of any type -- so
        -- Bcast-suppl.f90 alone trips it 15 times. Measured 42 false errors
        -- across the corpus and no true positive. GCC 10+ demotes them to
        -- warnings with this flag. Adding the mpif.h include path removed one
        -- fatal error per file and introduced these in its place; the two
        -- changes belong together.
        --
        -- The -Wno- flags below suppress categories that are pure volume on
        -- this codebase, all verified against the 86-file corpus:
        --   -Wno-tabs             1032 hits; the source is uniformly
        --                         tab-indented, so this fires on style only.
        --   -Wno-unused-parameter mpif.h declares ~200 PARAMETER constants and
        --                         every file including it is warned about each
        --                         one it does not use (~1900 hits).
        --   -Wno-conversion       REAL->INTEGER narrowing is deliberate
        --   -Wno-integer-division and pervasive in the cell-indexing math.
        -- -Wunused-variable is deliberately KEPT: 205 of its hits point at the
        -- .f90 itself rather than the included headers, so it still carries
        -- signal.
        --
        -- Measured over the 86-file corpus with these flags added:
        --   errors                     134 -> 52
        --   warnings                14772 -> 402
        --   diagnostics reaching a buffer 1115 -> 373
        args = {
          "-Wall",
          "-Wextra",
          "-Wno-do-subscript",
          "-fallow-argument-mismatch",
          "-Wno-tabs",
          "-Wno-unused-parameter",
          "-Wno-conversion",
          "-Wno-integer-division",
          "-fopenmp",
          "-fsyntax-only",
          "-fdiagnostics-plain-output",
        },
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

    -- Unused-name tagging. gfortran already reports these under -Wall and the
    -- parsers below already match the lines; the tag and the real source span
    -- are added by andrew.fortran.unused, which documents why the field is
    -- `_tags` and not the LSP wire spelling `tags`.
    local unused = require("andrew.fortran.unused")

    -- Two-location gfortran warnings arrive as a bare "(1)" line alongside the
    -- real message; see andrew.fortran.diag.is_location_marker.
    local diag_filter = require("andrew.fortran.diag")

    local parsers = {}

    -- GCC/gfortran parser
    function parsers.gcc(output, bufnr)
      local diagnostics = {}
      local fname = vim.api.nvim_buf_get_name(bufnr)

      for line in output:gmatch("[^\r\n]+") do
        -- Pattern handles both "Error:" and "Fatal Error:" formats
        local file, lnum, col, severity, msg =
          line:match("^(.+):(%d+):(%d+):%s*(%w+%s*%w*):%s*(.+)$")

        if lnum and msg and not diag_filter.is_location_marker(msg) then
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

            local diag = {
              lnum = tonumber(lnum) - 1,
              col = tonumber(col) - 1,
              message = msg,
              severity = sev,
              source = "gfortran",
            }
            table.insert(diagnostics, unused.tag(diag, unused.buf_line(bufnr, diag.lnum)))
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

        if lnum and msg and not diag_filter.is_location_marker(msg) then
          if not file or file == fname or
             vim.fn.fnamemodify(file, ":t") == vim.fn.fnamemodify(fname, ":t") then
            local sev = vim.diagnostic.severity.ERROR
            if severity:lower() == "warning" then
              sev = vim.diagnostic.severity.WARN
            elseif severity:lower() == "remark" then
              sev = vim.diagnostic.severity.INFO
            end

            local diag = {
              lnum = tonumber(lnum) - 1,
              col = 0,
              message = msg,
              severity = sev,
              source = "intel",
            }
            table.insert(diagnostics, unused.tag(diag, unused.buf_line(bufnr, diag.lnum)))
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

        if lnum and msg and not diag_filter.is_location_marker(msg) then
          if not file or file == fname or
             vim.fn.fnamemodify(file, ":t") == vim.fn.fnamemodify(fname, ":t") then
            local sev = vim.diagnostic.severity.ERROR
            if severity:lower() == "warning" then
              sev = vim.diagnostic.severity.WARN
            elseif severity:lower() == "info" or severity:lower() == "extension" then
              sev = vim.diagnostic.severity.INFO
            end

            local diag = {
              lnum = tonumber(lnum) - 1,
              col = 0,
              message = msg,
              severity = sev,
              source = "nagfor",
            }
            table.insert(diagnostics, unused.tag(diag, unused.buf_line(bufnr, diag.lnum)))
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
      -- Terminate on a FIXED POINT, not just on "/". link_utils.lua_dirname
      -- returns its argument unchanged when the pattern finds no parent, and it
      -- does that at the first level below root: lua_dirname("/tmp") == "/tmp".
      -- The old `while path ~= "/"` therefore span forever for any file with no
      -- marker anywhere above it (e.g. /tmp/scratch/foo.f90), hanging nvim hard.
      -- Latent until the linter actually started running.
      while path ~= "/" and path ~= "" do
        for _, marker in ipairs(root_markers) do
          local marker_path = path .. "/" .. marker
          if vim.fn.isdirectory(marker_path) == 1 or vim.fn.filereadable(marker_path) == 1 then
            return path
          end
        end
        local parent = lua_dirname(path)
        if parent == path then
          break
        end
        path = parent
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

      -- Wherever mpif.h lives. Without this, every file carrying
      -- `INCLUDE 'mpif.h'` -- 229 of them in this project -- produced one
      -- FATAL error and no other diagnostic at all, because a failed INCLUDE
      -- terminates the parse. See andrew.fortran.mpi for why the mpif90
      -- wrapper cannot be used instead. mpif.h's own ~294 unused-PARAMETER
      -- warnings never reach a buffer: the parsers below keep only
      -- diagnostics whose basename matches the file being linted.
      local ok_mpi, mpi = pcall(require, "andrew.fortran.mpi")
      if ok_mpi then
        for _, dir in ipairs(mpi.include_dirs()) do
          table.insert(args, "-I" .. dir)
        end
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

    -- Returns true when fortran_config.compiler was actually registered (the
    -- "Disabled" path counts as success: it is a valid, fully-applied state) and
    -- false when it could not be -- unknown compiler, or binary not executable.
    -- Callers MUST check the result: they write fortran_config.compiler BEFORE
    -- calling, so a false return means the config now names a compiler that has
    -- no linter behind it and the caller has to roll the field back.
    local function register_fortran_linter()
      if fortran_config.compiler == "Disabled" then
        lint.linters_by_ft.fortran = {}
        lint.linters_by_ft["fortran_free"] = {}
        lint.linters_by_ft["fortran_fixed"] = {}
        return true
      end

      local compiler_config = compilers[fortran_config.compiler]
      if not compiler_config then
        vim.notify("Unknown Fortran compiler: " .. fortran_config.compiler, vim.log.levels.ERROR)
        return false
      end

      -- Determine command path
      local cmd = fortran_config.compiler_path or compiler_config.cmd

      -- Verify compiler exists
      if vim.fn.executable(cmd) ~= 1 then
        vim.notify("Fortran compiler not found: " .. cmd, vim.log.levels.WARN)
        return false
      end

      -- Compiler flags, rebuilt per lint run so include paths and user extra
      -- args pick up :FortranAddIncludePath and friends without a restart.
      local function build_fortran_args()
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
      end

      -- Register the linter.
      --
      -- This MUST be a function returning the linter table, not a table with
      -- `args = function() ... end`. nvim-lint treats `args` as a LIST and maps
      -- its evaluator over the elements (lint.lua:381,
      -- `vim.tbl_map(eval, linter.args)`), so individual elements may be
      -- functions but the whole field may not -- passing one threw
      -- "t: expected table, got function" out of vim.tbl_map on every Fortran
      -- BufReadPost/BufWritePre/InsertLeave, swallowed by try_lint's pcall and
      -- surfacing only as a stray error message. Linting never actually ran.
      --
      -- A function-valued LINTER is supported: nvim-lint calls it in
      -- lookup_linter (lint.lua:83) before use, which gives the same per-run
      -- freshness the old `args` function was reaching for.
      lint.linters[fortran_config.compiler] = function()
        return {
          cmd = cmd,
          args = build_fortran_args(),
          stdin = false,
          append_fname = true,
          stream = "stderr",
          ignore_exitcode = true,
          parser = parsers[compiler_config.parser],
          -- Must be a STRING, not a function. nvim-lint types cwd as a string
          -- and hands it straight to uv.spawn (lint.lua:400) and to vim.cmd.cd
          -- in with_cwd; a function there wedges the spawn. It went unnoticed
          -- only because the args bug above meant this linter never actually
          -- ran. Resolving it here is equivalent -- the enclosing function is
          -- re-evaluated by nvim-lint on every lint.
          cwd = get_fortran_project_root(),
        }
      end

      -- Set for all Fortran filetypes
      lint.linters_by_ft.fortran = { fortran_config.compiler }
      lint.linters_by_ft["fortran_free"] = { fortran_config.compiler }
      lint.linters_by_ft["fortran_fixed"] = { fortran_config.compiler }

      return true
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
        -- Roll back on failure. register_fortran_linter() bails out on an
        -- unknown or non-executable compiler, which used to leave
        -- fortran_config.compiler naming a compiler with no linter registered --
        -- <leader>Ll then threw E475 on the next run.
        local previous = fortran_config.compiler
        fortran_config.compiler = compiler
        if not register_fortran_linter() then
          fortran_config.compiler = previous
          register_fortran_linter()
          vim.notify("Fortran linter left at: " .. previous, vim.log.levels.WARN)
          return
        end
        vim.notify("Fortran linter set to: " .. compiler)
        -- Re-lint current buffer
        if compiler ~= "Disabled" then
          try_lint_available(nil, true)
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
        try_lint_available()
      end,
    })

    -- Fortran-specific linting (matches VS Code Modern Fortran behavior)
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
      group = vim.api.nvim_create_augroup("FortranLinting", { clear = true }),
      pattern = { "*.f90", "*.F90", "*.f95", "*.f03", "*.f08", "*.f", "*.F" },
      callback = function()
        try_lint_available()
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
    keymap.set("n", "<leader>Ll", function()
      local ft = vim.bo.filetype

      -- For non-Fortran files, use nvim-lint
      if ft ~= "fortran" and ft ~= "fortran_free" and ft ~= "fortran_fixed" then
        try_lint_available(nil, true)
        return
      end

      -- House capitalization rule (andrew.fortran.case) runs alongside the
      -- compiler, not instead of it. It publishes into its own diagnostic
      -- namespace, so the two sets coexist and :FortranCaseClear removes only
      -- the style findings.
      require("andrew.fortran.case").check(0)

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

      -- gfortran exits 0 when it only emitted WARNINGS, so exit code alone says
      -- nothing about whether anything was reported. Without this flag on_exit
      -- printed "Lint: no issues" immediately after on_stderr had already
      -- published (and reported) real diagnostics.
      local reported = false

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
                reported = true
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
              if not reported then
                vim.notify("Lint: no issues", vim.log.levels.INFO)
              end
            end)
          end
        end,
      })
    end, { desc = "Lint: run linters for current buffer" })

    -- Run ruff specifically for Python files
    keymap.set("n", "<leader>Lm", function()
      -- Guard the filetype: ruff is a PYTHON linter, but nvim-lint runs whatever
      -- it is handed. Without this it happily parsed e.g. a Fortran buffer as
      -- Python and published a screenful of bogus parse errors.
      if vim.bo.filetype ~= "python" then
        vim.notify(
          "Lint: ruff only applies to Python buffers (this is " .. vim.bo.filetype .. ")",
          vim.log.levels.WARN
        )
        return
      end
      try_lint_available("ruff", true)
    end, { desc = "Lint: run ruff (Python)" })

    -- Toggle Fortran linter between available compilers
    keymap.set("n", "<leader>Lf", function()
      local current = fortran_config.compiler
      local order = { "gfortran", "mpiifx", "ifort", "ifx", "nagfor", "Disabled" }
      local start = 0
      for i, comp in ipairs(order) do
        if comp == current then
          start = i
          break
        end
      end

      -- Walk the cycle from just after the current entry and stop at the first
      -- candidate that actually registers. Blindly taking the next entry left
      -- fortran_config.compiler pointing at a compiler that is not installed on
      -- this machine, with no linter behind it.
      for step = 1, #order do
        local candidate = order[((start + step - 1) % #order) + 1]
        if candidate ~= current then
          fortran_config.compiler = candidate
          if register_fortran_linter() then
            vim.notify("Fortran linter: " .. candidate)
            return
          end
        end
      end

      -- Nothing else is usable: put the original back and say so.
      fortran_config.compiler = current
      register_fortran_linter()
      vim.notify(
        "Fortran linter: no other compiler available (still " .. current .. ")",
        vim.log.levels.WARN
      )
    end, { desc = "Lint: Toggle Fortran linter" })

    -- Debug: Run Fortran linter explicitly with verbose output
    keymap.set("n", "<leader>LF", function()
      local ft = vim.bo.filetype
      local linters = lint.linters_by_ft[ft]
      vim.notify("Filetype: " .. ft .. ", Linters: " .. vim.inspect(linters))
      if linters and #linters > 0 then
        local linter = lint.linters[linters[1]]
        -- The Fortran linter is registered as a function (see the note at its
        -- definition); resolve it the same way nvim-lint's lookup_linter does.
        if type(linter) == "function" then
          local ok, resolved = pcall(linter)
          linter = ok and resolved or nil
        end
        if linter then
          vim.notify("CWD: " .. (type(linter.cwd) == "function" and linter.cwd() or (linter.cwd or "nil")))
          local args = type(linter.args) == "function" and linter.args() or linter.args
          vim.notify("Args: " .. vim.inspect(args))
        end
        try_lint_available(nil, true)
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
    keymap.set("n", "<leader>Lw", function()
      -- Capitalization rule across the project. quickfix is left to the
      -- compiler pass below, which is about to claim the list.
      require("andrew.fortran.case").check_workspace(function(count, files)
        if count > 0 then
          vim.notify(
            string.format("Fortran case: %d name(s) to capitalize in %d file(s)", count, files),
            vim.log.levels.WARN
          )
        end
      end, { quickfix = false })

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

      -- gfortran exits 0 when it only emitted WARNINGS, so on_exit must not
      -- treat code == 0 as "nothing found": it used to overwrite
      -- _G.fortran_workspace_diagnostics (the lualine counts) back to zeros and
      -- print "no issues" right after on_stderr had published the real set.
      local reported = false

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

                -- Diagnostics from the MPI headers are dropped here rather
                -- than in the parser: this path groups by the reported name
                -- and calls vim.fn.bufnr(name, true), so keeping them would
                -- fabricate an empty `mpif.h` buffer holding ~294 warnings on
                -- lines it does not have.
                if
                  file
                  and lnum
                  and not diag_filter.is_location_marker(msg)
                  and not require("andrew.fortran.mpi").is_external(file, project_root)
                then
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
                  -- No source line here: the diagnostic may belong to a file
                  -- that is not loaded, so the span comes from the caret
                  -- arithmetic alone (see andrew.fortran.unused.name_span).
                  table.insert(diagnostics_by_file[file], unused.tag({
                    lnum = tonumber(lnum) - 1,
                    col = (tonumber(col) or 1) - 1,
                    message = msg or "",
                    severity = sev,
                    source = fortran_config.compiler,
                  }, nil))
                end
              end

              vim.schedule(function()
                reported = true

                -- Update global diagnostics count
                _G.fortran_workspace_diagnostics = {
                  errors = error_count,
                  warnings = warn_count,
                  info = info_count,
                }

                -- Set diagnostics for each file
                for file, diags in pairs(diagnostics_by_file) do
                  -- Get or create buffer for file
                  local bufnr = vim.fn.bufnr(file, true)
                  vim.fn.bufload(bufnr)
                  vim.diagnostic.set(workspace_ns, bufnr, diags)
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
              if not reported then
                _G.fortran_workspace_diagnostics = { errors = 0, warnings = 0, info = 0 }
                vim.notify("Workspace lint complete - no issues", vim.log.levels.INFO)
              end
            end)
          end
        end,
      })
    end, { desc = "Lint: Lint entire Fortran workspace" })

    -- Clear workspace diagnostics
    keymap.set("n", "<leader>LW", function()
      -- Clear all workspace diagnostics
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        vim.diagnostic.reset(workspace_ns, bufnr)
      end
      _G.fortran_workspace_diagnostics = { errors = 0, warnings = 0, info = 0 }
      vim.fn.setqflist({})
      vim.notify("Workspace diagnostics cleared", vim.log.levels.INFO)
    end, { desc = "Lint: Clear workspace diagnostics" })

    -- =============================================================================
    -- Fortran Capitalization Rule
    -- =============================================================================
    -- House style: intrinsics and project-defined procedures are written in
    -- full capitals. Implemented in andrew.fortran.case, which owns its own
    -- diagnostic namespace; these are the Lint-group front doors for it.
    -- The workspace FIX is deliberately command-only (:FortranCaseFix
    -- workspace) -- it rewrites every file in the project, and files that are
    -- not open in a buffer get no undo history.

    keymap.set("n", "<leader>Lc", function()
      require("andrew.fortran.case").check(0, function(count)
        vim.notify(count == 0
          and "Fortran case: clean"
          or string.format("Fortran case: %d name(s) to capitalize", count))
      end)
    end, { desc = "Lint: Check Fortran capitalization" })

    keymap.set("n", "<leader>LC", function()
      require("andrew.fortran.case").fix(0, function(count)
        vim.notify(string.format("Fortran case: capitalized %d name(s)", count))
      end)
    end, { desc = "Lint: Fix Fortran capitalization (buffer)" })

    keymap.set("n", "<leader>Lt", function()
      vim.cmd("FortranCaseToggle")
    end, { desc = "Lint: Toggle Fortran capitalization check" })

    -- =============================================================================
    -- ftnchek: cross-file argument and COMMON-layout checking
    -- =============================================================================
    -- The one class of Fortran bug nothing else here can see. gfortran
    -- compiles a file at a time and fortls never compares a call against its
    -- callee, so a CALL with the wrong argument count and a COMMON block laid
    -- out differently in two files are both invisible. ftnchek reads the whole
    -- program at once and finds them.
    --
    -- Project-wide and slow-ish, so it is a deliberate keypress, never an
    -- autocmd. It is also a FORTRAN 77 tool -- see the header of
    -- andrew.fortran.ftnchek for why it is pointed only at fixed-form sources.

    keymap.set("n", "<leader>Lk", function()
      require("andrew.fortran.ftnchek").check()
    end, { desc = "Lint: ftnchek project (args + COMMON layout)" })

    keymap.set("n", "<leader>LK", function()
      require("andrew.fortran.ftnchek").clear()
      vim.notify("ftnchek diagnostics cleared", vim.log.levels.INFO)
    end, { desc = "Lint: Clear ftnchek diagnostics" })

    vim.api.nvim_create_user_command("FortranCheck", function(o)
      require("andrew.fortran.ftnchek").check({
        root = o.args ~= "" and vim.fn.fnamemodify(o.args, ":p") or nil,
      })
    end, {
      nargs = "?",
      complete = "dir",
      desc = "ftnchek: cross-file argument and COMMON-layout check",
    })

    vim.api.nvim_create_user_command("FortranCheckClear", function()
      require("andrew.fortran.ftnchek").clear()
    end, { desc = "ftnchek: clear diagnostics" })

    -- =============================================================================
    -- MPI include discovery
    -- =============================================================================
    --
    -- Worth being able to see, because when it finds nothing the symptom is
    -- one FATAL "Cannot open included file 'mpif.h'" per file and no other
    -- diagnostic at all -- which reads as a broken linter rather than a
    -- missing include path.

    vim.api.nvim_create_user_command("FortranMpiStatus", function()
      local mpi = require("andrew.fortran.mpi")
      local dirs = mpi.include_dirs()
      local lines = { "MPI include discovery", "" }
      if #dirs == 0 then
        lines[#lines + 1] = "  No mpif.h found."
        lines[#lines + 1] = ""
        lines[#lines + 1] = "  Files with INCLUDE 'mpif.h' will report a FATAL"
        lines[#lines + 1] = "  include error and nothing else."
        lines[#lines + 1] = ""
        lines[#lines + 1] = "  Set vim.g.fortran_mpi_include_dirs = { '/path/to/include' }"
        lines[#lines + 1] = "  or install an MPI providing mpif.h."
      else
        for _, d in ipairs(dirs) do
          lines[#lines + 1] = "  " .. d .. "/mpif.h"
        end
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Searched " .. #mpi.candidates() .. " candidate directories."
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end, { desc = "MPI: show the discovered mpif.h include path" })

    vim.api.nvim_create_user_command("FortranMpiRescan", function()
      local mpi = require("andrew.fortran.mpi")
      mpi.invalidate()
      local dirs = mpi.include_dirs()
      if #dirs == 0 then
        vim.notify("MPI: still no mpif.h found", vim.log.levels.WARN)
      else
        vim.notify("MPI: using " .. dirs[1] .. "/mpif.h", vim.log.levels.INFO)
      end
      -- fortls reads its include dirs from the command line at startup, so a
      -- rescan only reaches the linter until the server is restarted.
    end, { desc = "MPI: re-run mpif.h discovery (restart LSP to reach fortls)" })
  end,
}
