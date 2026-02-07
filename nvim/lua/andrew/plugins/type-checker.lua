-- =============================================================================
-- Type Checker Integration
-- =============================================================================
-- Provides language-specific type checking commands for various programming languages.
-- Runs type checkers in a terminal split and shows results via notifications.

return {
  -- Use plenary as dependency (harmless, ensures plugin loads)
  "nvim-lua/plenary.nvim",

  -- Load lazily (no specific trigger needed)
  event = "VeryLazy",

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    -- =============================================================================
    -- Terminal Runner Utility
    -- =============================================================================
    -- Opens a command in a bottom split terminal and notifies on completion
    --
    -- @param cmd (table): Command and arguments to run
    -- @param title (string): Title for the notification
    local function run_in_term(cmd, title)
      title = title or table.concat(cmd, " ")

      -- Calculate split height (30% of editor, minimum 10 lines)
      local height = math.max(10, math.floor(vim.o.lines * 0.3))

      -- Create bottom split
      vim.cmd("botright " .. height .. "split")
      vim.cmd("enew")

      -- Configure scratch buffer
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype = "nofile"       -- Not a file buffer
      vim.bo[buf].bufhidden = "wipe"        -- Delete when hidden
      vim.bo[buf].swapfile = false         -- No swap file
      vim.bo[buf].filetype = "typecheck"    -- Syntax highlighting

      -- Run command in terminal
      vim.fn.termopen(cmd, {
        cwd = vim.fn.getcwd(),  -- Use current working directory
        on_exit = function(_, code, _)
          -- Notify on completion (success=info, failure=error)
          local level = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
          local msg = string.format("%s exited with code %d", title, code)
          vim.schedule(function()
            vim.notify(msg, level, { title = "TypeCheck" })
          end)
        end,
      })

      -- Enter insert mode for interaction
      vim.cmd("startinsert")
    end

    -- =============================================================================
    -- Language-Specific Type Checkers
    -- =============================================================================

    -- Python: Run ruff check on current file
    local function typecheck_python()
      local file = vim.api.nvim_buf_get_name(0)
      if file == "" then
        vim.notify("Current buffer has no filename; save it first", vim.log.levels.WARN)
        return
      end

      if vim.fn.executable("ruff") == 1 then
        run_in_term({ "ruff", "check", "--no-cache", file }, "Ruff check (Python file)")
        return
      end

      vim.notify(
        "ruff not found in PATH. Install ruff (e.g. via Mason or your env) to use Python :TypeCheck.",
        vim.log.levels.ERROR
      )
    end

    -- Python: Run Ty type checker on current file
    local function typecheck_python_ty()
      local file = vim.api.nvim_buf_get_name(0)
      if file == "" then
        vim.notify("Current buffer has no filename; save it first", vim.log.levels.WARN)
        return
      end

      if vim.fn.executable("ty") == 0 then
        vim.notify(
          "ty not found in PATH. Install it via Mason (mason-tool-installer: ty) or your env.",
          vim.log.levels.ERROR
        )
        return
      end

      run_in_term({ "ty", "check", file }, "Ty check (Python file)")
    end

    -- TypeScript/JavaScript: Run tsc --noEmit
    local function typecheck_ts()
      local cmd
      if vim.fn.executable("tsc") == 1 then
        cmd = { "tsc", "--noEmit" }
      elseif vim.fn.filereadable("node_modules/.bin/tsc") == 1 then
        cmd = { "node", "node_modules/.bin/tsc", "--noEmit" }
      else
        vim.notify(
          "tsc not found (conda install -c conda-forge typescript OR npm i -D typescript)",
          vim.log.levels.ERROR
        )
        return
      end
      run_in_term(cmd, "tsc --noEmit (TS/JS type check)")
    end

    -- Rust: Run cargo check
    local function typecheck_rust()
      if vim.fn.executable("cargo") == 0 then
        vim.notify(
          "cargo not found in PATH (install Rust toolchain in this conda env)",
          vim.log.levels.ERROR
        )
        return
      end
      run_in_term({ "cargo", "check" }, "cargo check (Rust type check)")
    end

    -- Lua: Run lua-language-server --check
    local function typecheck_lua()
      local exe = "lua-language-server"
      if vim.fn.executable(exe) == 0 then
        local conda_exe = vim.fn.expand("$HOME/miniconda3/bin/lua-language-server")
        if vim.fn.executable(conda_exe) == 0 then
          vim.notify(
            "lua-language-server not found (conda install -c conda-forge lua-language-server)",
            vim.log.levels.ERROR
          )
          return
        end
        exe = conda_exe
      end

      local cwd = vim.fn.getcwd()
      run_in_term({ exe, "--check=" .. cwd }, "lua-language-server --check")
    end

    -- =============================================================================
    -- Fortran Type Checking Configuration
    -- =============================================================================
    -- Track current Fortran type checker (mpif90/gfortran or mpiifx)
    _G.fortran_typechecker = "mpif90"

    -- Compiler paths
    local mpiifx_path = "/gpfs/sharedfs1/admin/hpc2.0/apps/intel/oneapi/2024.2.1/mpi/2021.13/bin/mpiifx"

    -- Helper: Find project root (parent of code/ directory)
    local function get_fortran_project_root()
      local root_markers = { ".git", ".fortls", "code" }
      local path = vim.fn.expand("%:p:h")

      while path ~= "/" do
        for _, marker in ipairs(root_markers) do
          local marker_path = path .. "/" .. marker
          if vim.fn.isdirectory(marker_path) == 1 or vim.fn.filereadable(marker_path) == 1 then
            return path
          end
        end
        path = vim.fn.fnamemodify(path, ":h")
      end
      return vim.fn.expand("%:p:h")
    end

    -- Fortran: Static type checking with mpif90 (MPI wrapper for gfortran)
    local function typecheck_fortran_mpif90()
      local file = vim.api.nvim_buf_get_name(0)
      if file == "" then
        vim.notify("Current buffer has no filename; save it first", vim.log.levels.WARN)
        return
      end

      -- Find MPI wrapper: prefer mpif90, fallback to mpifort, then gfortran
      local compiler
      if vim.fn.executable("mpif90") == 1 then
        compiler = "mpif90"
      elseif vim.fn.executable("mpifort") == 1 then
        compiler = "mpifort"
      elseif vim.fn.executable("gfortran") == 1 then
        compiler = "gfortran"
        vim.notify("Using gfortran (no MPI wrapper found - MPI includes may fail)", vim.log.levels.WARN)
      else
        vim.notify("No Fortran compiler found (mpif90, mpifort, or gfortran)", vim.log.levels.ERROR)
        return
      end

      local project_root = get_fortran_project_root()
      local code_dir = project_root .. "/code"
      local include_path = "-I" .. (vim.fn.isdirectory(code_dir) == 1 and code_dir or project_root)

      local cmd = {
        compiler,
        "-c",                     -- Compile only (don't link)
        "-fsyntax-only",          -- Syntax check only
        "-Wall",                  -- Enable all warnings
        "-Wextra",                -- Extra warnings
        "-Wconversion",           -- Warn about implicit type conversions
        "-Wconversion-extra",     -- Extra conversion warnings
        "-Wimplicit-interface",   -- Warn about calls with implicit interface
        "-Wimplicit-procedure",   -- Warn about implicit procedure references
        "-Winteger-division",     -- Warn about integer division truncation
        "-Wcharacter-truncation", -- Warn about character truncation
        "-Warray-bounds",         -- Check array bounds at compile time
        "-Wuninitialized",        -- Warn about uninitialized variables
        "-fimplicit-none",        -- Require explicit declarations
        include_path,
        file,
      }

      run_in_term(cmd, compiler .. " type check")
    end

    -- Fortran: Static type checking with mpiifx (Intel)
    local function typecheck_fortran_mpiifx()
      local file = vim.api.nvim_buf_get_name(0)
      if file == "" then
        vim.notify("Current buffer has no filename; save it first", vim.log.levels.WARN)
        return
      end

      if vim.fn.executable(mpiifx_path) == 0 then
        vim.notify("mpiifx not found at " .. mpiifx_path, vim.log.levels.ERROR)
        return
      end

      local project_root = get_fortran_project_root()
      local code_dir = project_root .. "/code"
      local include_path = "-I" .. (vim.fn.isdirectory(code_dir) == 1 and code_dir or project_root)

      local cmd = {
        mpiifx_path,
        "-c",                     -- Compile only (don't link)
        "-syntax-only",           -- Syntax check only
        "-warn", "all",           -- Enable all warnings
        "-warn", "interfaces",    -- Check procedure interfaces
        "-warn", "declarations",  -- Require explicit declarations
        "-warn", "unused",        -- Warn about unused variables
        "-warn", "truncated_source", -- Warn about truncated source lines
        "-check", "bounds",       -- Array bounds checking
        include_path,
        file,
      }

      run_in_term(cmd, "mpiifx type check")
    end

    -- Fortran: Dispatch to current type checker
    local function typecheck_fortran()
      if _G.fortran_typechecker == "mpiifx" then
        typecheck_fortran_mpiifx()
      else
        typecheck_fortran_mpif90()
      end
    end

    -- C/C++: Check syntax and warnings (g++ or clang++)
    local function typecheck_cpp()
      local file = vim.api.nvim_buf_get_name(0)
      if file == "" then
        vim.notify("Current buffer has no filename; save it first", vim.log.levels.WARN)
        return
      end

      local compiler
      if vim.fn.executable("g++") == 1 then
        compiler = "g++"
      elseif vim.fn.executable("clang++") == 1 then
        compiler = "clang++"
      end

      if not compiler then
        vim.notify("No C++ compiler (g++ or clang++) found in PATH", vim.log.levels.ERROR)
        return
      end

      local cmd = {
        compiler,
        "-fsyntax-only",  -- Syntax check only (don't compile)
        "-Wall",          -- Enable all warnings
        "-Wextra",        -- Extra warnings
        "-Wpedantic",     -- Strict ISO C compliance
        file,
      }
      run_in_term(cmd, "C/C++ syntax & warnings")
    end

    -- =============================================================================
    -- Dispatcher: Select Type Checker by Filetype
    -- =============================================================================
    local function typecheck_dispatch()
      local ft = vim.bo.filetype

      if ft == "python" then
        typecheck_python()
      elseif
        ft == "typescript"
        or ft == "typescriptreact"
        or ft == "javascript"
        or ft == "javascriptreact"
      then
        typecheck_ts()
      elseif ft == "rust" then
        typecheck_rust()
      elseif ft == "lua" then
        typecheck_lua()
      elseif ft == "fortran" or ft == "fortran_free" or ft == "fortran_fixed" or ft == "f90" or ft == "f95" then
        typecheck_fortran()
      elseif ft == "c" or ft == "cpp" or ft == "cxx" or ft == "cc" then
        typecheck_cpp()
      else
        vim.notify("No type checker configured for filetype: " .. ft, vim.log.levels.WARN)
      end
    end

    -- =============================================================================
    -- User Commands and Keybindings
    -- =============================================================================

    -- Create :TypeCheck command
    vim.api.nvim_create_user_command(
      "TypeCheck",
      typecheck_dispatch,
      { desc = "Run language-specific type checker based on filetype" }
    )

    local map = vim.keymap.set
    local opts = { noremap = true, silent = true }

    -- Dispatch by filetype (all languages)
    map(
      "n",
      "<leader>ac",
      "<cmd>TypeCheck<CR>",
      vim.tbl_extend("force", opts, {
        desc = "Type check (dispatch by filetype)",
      })
    )

    -- Language-specific keybindings
    map(
      "n",
      "<leader>aP",
      typecheck_python,
      vim.tbl_extend("force", opts, {
        desc = "Python type check (current file: ruff check)",
      })
    )

    map(
      "n",
      "<leader>aT",
      typecheck_python_ty,
      vim.tbl_extend("force", opts, {
        desc = "Ty type check (Python current file)",
      })
    )
    map(
      "n",
      "<leader>aR",
      typecheck_rust,
      vim.tbl_extend("force", opts, {
        desc = "cargo check (Rust project)",
      })
    )
    map(
      "n",
      "<leader>aL",
      typecheck_lua,
      vim.tbl_extend("force", opts, {
        desc = "lua-language-server --check (Lua project)",
      })
    )
    map(
      "n",
      "<leader>aF",
      typecheck_fortran,
      vim.tbl_extend("force", opts, {
        desc = "Fortran type check (current compiler)",
      })
    )
    map(
      "n",
      "<leader>aC",
      typecheck_cpp,
      vim.tbl_extend("force", opts, {
        desc = "C/C++ syntax & warnings",
      })
    )

    -- Fortran-specific type checker keybindings
    map(
      "n",
      "<leader>ag",
      typecheck_fortran_mpif90,
      vim.tbl_extend("force", opts, {
        desc = "Fortran type check (mpif90/gfortran)",
      })
    )
    map(
      "n",
      "<leader>ai",
      typecheck_fortran_mpiifx,
      vim.tbl_extend("force", opts, {
        desc = "Fortran type check (mpiifx/Intel)",
      })
    )

    -- Toggle Fortran type checker between mpif90 and mpiifx
    map("n", "<leader>at", function()
      _G.fortran_typechecker = _G.fortran_typechecker == "mpif90" and "mpiifx" or "mpif90"
      vim.notify("Fortran type checker: " .. _G.fortran_typechecker)
    end, vim.tbl_extend("force", opts, {
      desc = "Toggle Fortran type checker (mpif90/mpiifx)",
    }))

    -- Command to set Fortran type checker
    vim.api.nvim_create_user_command("FortranTypeChecker", function(cmd_opts)
      local checker = cmd_opts.args
      if checker == "mpif90" or checker == "mpiifx" then
        _G.fortran_typechecker = checker
        vim.notify("Fortran type checker set to: " .. checker)
      else
        vim.notify("Usage: :FortranTypeChecker mpif90|mpiifx", vim.log.levels.WARN)
      end
    end, {
      nargs = 1,
      complete = function() return { "mpif90", "mpiifx" } end,
      desc = "Set Fortran type checker (mpif90 or mpiifx)",
    })
  end,
}
