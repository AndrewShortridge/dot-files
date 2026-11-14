-- =============================================================================
-- Debug Adapter Protocol Configuration (nvim-dap)
-- =============================================================================
-- Configures nvim-dap for debugging support in Neovim.
-- Provides breakpoints, stepping, variable inspection, and more.

return {
  -- Plugin: nvim-dap - Debug Adapter Protocol client
  -- Repository: https://github.com/mfussenegger/nvim-dap
  "mfussenegger/nvim-dap",

  -- Load on command or keymap
  lazy = true,

  -- =============================================================================
  -- Early Initialization
  -- =============================================================================
  -- Define signs before plugin loads so they're ready immediately

  init = function()
    -- Breakpoint sign (red circle)
    vim.fn.sign_define("DapBreakpoint", {
      text = "●",
      texthl = "DapBreakpoint",
      linehl = "",
      numhl = "",
    })

    -- Conditional breakpoint sign (yellow circle)
    vim.fn.sign_define("DapBreakpointCondition", {
      text = "●",
      texthl = "DapBreakpointCondition",
      linehl = "",
      numhl = "",
    })

    -- Rejected breakpoint sign (red x)
    vim.fn.sign_define("DapBreakpointRejected", {
      text = "×",
      texthl = "DapBreakpointRejected",
      linehl = "",
      numhl = "",
    })

    -- Stopped at line sign (green arrow)
    vim.fn.sign_define("DapStopped", {
      text = "▶",
      texthl = "DapStopped",
      linehl = "DapStoppedLine",
      numhl = "",
    })

    -- Log point sign (blue circle)
    vim.fn.sign_define("DapLogPoint", {
      text = "◆",
      texthl = "DapLogPoint",
      linehl = "",
      numhl = "",
    })

    -- Define highlight groups for signs.
    -- Re-applied on ColorScheme: a colorscheme starts with `hi clear`, which
    -- wipes these, and nothing else re-creates them -- so before this, one
    -- <leader>ub light/dark switch left every breakpoint sign in the gutter
    -- uncoloured for the rest of the session.
    local function dap_highlights()
      vim.api.nvim_set_hl(0, "DapBreakpoint", { fg = "#e51400" })
      vim.api.nvim_set_hl(0, "DapBreakpointCondition", { fg = "#e5ac00" })
      vim.api.nvim_set_hl(0, "DapBreakpointRejected", { fg = "#e51400" })
      vim.api.nvim_set_hl(0, "DapStopped", { fg = "#98c379" })
      vim.api.nvim_set_hl(0, "DapLogPoint", { fg = "#61afef" })
      vim.api.nvim_set_hl(0, "DapStoppedLine", { bg = "#2e3d2e" })
    end

    dap_highlights()
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = vim.api.nvim_create_augroup("DapHighlights", { clear = true }),
      callback = dap_highlights,
    })
  end,

  -- =============================================================================
  -- Keybindings
  -- =============================================================================
  -- All debug commands are prefixed with <leader>d

  keys = {
    -- Toggle breakpoint on current line
    {
      "<leader>db",
      function()
        require("dap").toggle_breakpoint()
      end,
      desc = "Toggle breakpoint",
    },

    -- Set conditional breakpoint
    {
      "<leader>dB",
      function()
        require("dap").set_breakpoint(vim.fn.input("Breakpoint condition: "))
      end,
      desc = "Set conditional breakpoint",
    },

    -- Start/continue debugging
    {
      "<leader>dc",
      function()
        require("dap").continue()
      end,
      desc = "Start/Continue debugging",
    },

    -- Step over
    {
      "<leader>do",
      function()
        require("dap").step_over()
      end,
      desc = "Step over",
    },

    -- Step into
    {
      "<leader>di",
      function()
        require("dap").step_into()
      end,
      desc = "Step into",
    },

    -- Step out
    {
      "<leader>dO",
      function()
        require("dap").step_out()
      end,
      desc = "Step out",
    },

    -- Terminate debugging session
    {
      "<leader>dt",
      function()
        require("dap").terminate()
      end,
      desc = "Terminate debugging",
    },

    -- Run to cursor
    {
      "<leader>dC",
      function()
        require("dap").run_to_cursor()
      end,
      desc = "Run to cursor",
    },

    -- Restart debugging session
    {
      "<leader>dr",
      function()
        require("dap").restart()
      end,
      desc = "Restart debugging",
    },

    -- Toggle REPL
    {
      "<leader>dR",
      function()
        require("dap").repl.toggle()
      end,
      desc = "Toggle REPL",
    },
  },

  -- =============================================================================
  -- Plugin Configuration
  -- =============================================================================
  config = function()
    local dap = require("dap")

    -- =============================================================================
    -- CodeLLDB Adapter Configuration (via Mason)
    -- =============================================================================
    -- Used for Rust, C, and C++ debugging
    -- Note: Rust debugging is configured via rustaceanvim plugin

    -- Mason installs packages to ~/.local/share/nvim/mason/packages/
    local mason_path = vim.fn.stdpath("data") .. "/mason/packages/codelldb"
    local extension_path = mason_path .. "/extension/"
    local codelldb_path = extension_path .. "adapter/codelldb"

    -- Check if codelldb exists
    if vim.fn.executable(codelldb_path) ~= 1 then
      vim.notify("codelldb not found. Run :MasonInstall codelldb", vim.log.levels.WARN)
      return
    end

    dap.adapters.codelldb = {
      type = "server",
      port = "${port}",
      executable = {
        command = codelldb_path,
        args = { "--port", "${port}" },
      },
    }

    -- =============================================================================
    -- GDB Adapter (for Fortran)
    -- =============================================================================
    -- gdb 14+ speaks DAP natively. Fortran MUST use gdb, not codelldb: lldb has
    -- no Fortran type system, so codelldb cannot read or set any Fortran variable
    -- (the Scopes pane comes up empty). gdb has full Fortran support.
    dap.adapters.gdb = {
      type = "executable",
      command = "gdb",
      args = { "--interpreter=dap" },
    }

    -- =============================================================================
    -- C/C++ Debug Configuration
    -- =============================================================================

    dap.configurations.c = {
      {
        name = "Launch",
        type = "codelldb",
        request = "launch",
        program = function()
          return vim.fn.input("Path to executable: ", vim.fn.getcwd() .. "/", "file")
        end,
        cwd = "${workspaceFolder}",
        stopOnEntry = false,
        args = {},
      },
    }

    dap.configurations.cpp = dap.configurations.c

    -- =============================================================================
    -- Rust Debug Configuration
    -- =============================================================================
    -- Note: You can also use <leader>rd (rustaceanvim debuggables) for Rust

    dap.configurations.rust = {
      {
        name = "Launch",
        type = "codelldb",
        request = "launch",
        program = function()
          -- Build the project first
          vim.fn.system("cargo build")
          -- Try to find the binary name from Cargo.toml
          local cargo_toml = vim.fn.getcwd() .. "/Cargo.toml"
          if vim.fn.filereadable(cargo_toml) == 1 then
            for line in io.lines(cargo_toml) do
              local name = line:match('^name%s*=%s*"([^"]+)"')
              if name then
                local binary = vim.fn.getcwd() .. "/target/debug/" .. name
                if vim.fn.executable(binary) == 1 then
                  return binary
                end
              end
            end
          end
          -- Fallback to manual input
          return vim.fn.input("Path to executable: ", vim.fn.getcwd() .. "/target/debug/", "file")
        end,
        cwd = "${workspaceFolder}",
        stopOnEntry = false,
        args = {},
      },
    }

    -- =============================================================================
    -- Fortran Debug Configuration
    -- =============================================================================
    -- Uses GDB (see adapter above) - codelldb/lldb cannot read Fortran variables.
    -- Compile with debug symbols: -g -O0 (ifx or gfortran).

    dap.configurations.fortran = {
      {
        name = "Launch Fortran (gdb)",
        type = "gdb",
        request = "launch",
        program = function()
          return vim.fn.input("Path to executable: ", vim.fn.getcwd() .. "/", "file")
        end,
        cwd = "${workspaceFolder}",
        stopAtBeginningOfMainSubprogram = false,
      },
      {
        -- Attach to a running process (e.g. one MPI rank). On attach gdb stops
        -- the process so the Scopes pane populates.
        name = "Attach to process (gdb)",
        type = "gdb",
        request = "attach",
        pid = function()
          return require("dap.utils").pick_process()
        end,
        cwd = "${workspaceFolder}",
      },
    }

    -- =============================================================================
    -- DAP UI Auto-open/close Listeners
    -- =============================================================================
    -- Load dapui and set up listeners to auto-open/close UI

    local dapui = require("dapui")

    dap.listeners.before.attach.dapui_config = function()
      dapui.open()
    end

    dap.listeners.before.launch.dapui_config = function()
      dapui.open()
    end

    dap.listeners.before.event_terminated.dapui_config = function()
      dapui.close()
    end

    dap.listeners.before.event_exited.dapui_config = function()
      dapui.close()
    end
  end,
}
