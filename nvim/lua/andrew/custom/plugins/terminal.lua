-- =============================================================================
-- Floating Terminal Plugin
-- =============================================================================
-- A custom plugin that provides a toggleable floating terminal window.
-- Features:
-- - Toggle visibility with <leader>tt
-- - Preserves terminal session when hiding (session restoration)
-- - Auto-hides on terminal exit (configurable); the next toggle starts a fresh
--   shell, since a terminal whose job has exited has no session to restore
-- - Toggle reads the real window, so closing the float any other way
--   (<C-w>c, <leader>wd, :q) still leaves <leader>tt working on one press
-- - Rounded border with "Scratch Terminal" title
-- - Exit terminal mode with <C-\><C-n> or jk
--
-- Commands:
--   :FloatingTerminal toggle  - Toggle visibility (default)
--   :FloatingTerminal open    - Show terminal (restore session)
--   :FloatingTerminal hide    - Hide terminal (preserve session)
--   :FloatingTerminal close   - Close and terminate terminal
--   :FloatingTerminal restart - Restart terminal
--   :FloatingTerminal send <cmd> - Send command to terminal

-- =============================================================================
-- Module State
-- =============================================================================
-- Holds the terminal window, buffer, and process IDs

local floating_terminal = {
  -- Window ID of the floating terminal (nil when closed)
  winid = nil,

  -- Buffer ID of the terminal (persists when hidden)
  bufnr = nil,

  -- Process ID of the terminal job
  termpid = nil,

  -- Visibility state: true when window is open
  is_visible = false,

  -- Configuration options
  options = vim.deepcopy({
    -- Window size as ratio of editor dimensions (0.0 to 1.0)
    width_ratio = 0.8, -- 80% of editor width
    height_ratio = 0.8, -- 80% of editor height

    -- Window appearance
    border = "rounded", -- Border style
    winblend = 0, -- Transparency (0=opaque, 100=transparent)
    zindex = 50, -- Stacking order for floating windows

    -- Behavior
    enter_on_open = true, -- Enter insert mode when opening
    hide_on_exit = true, -- Hide instead of close when terminal exits
    shell = vim.o.shell, -- Shell to use for terminal

    -- Title
    title = " Scratch Terminal ",
    title_align = "left",
  }),
}

-- =============================================================================
-- Size and Position Calculations
-- =============================================================================

-- Calculate terminal window dimensions based on editor size
-- @returns width (number): Width in columns
-- @returns height (number): Height in lines
function floating_terminal.get_size()
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = math.floor(columns * floating_terminal.options.width_ratio)
  local height = math.floor(lines * floating_terminal.options.height_ratio)
  return width, height
end

-- Calculate window position to center it on screen
-- @param width (number): Window width in columns
-- @param height (number): Window height in lines
-- @returns row (number): Top row position
-- @returns col (number): Left column position
function floating_terminal.calculate_position(width, height)
  local columns = vim.o.columns
  local lines = vim.o.lines
  local row = math.floor((lines - height) / 2)
  local col = math.floor((columns - width) / 2)
  return row, col
end

-- =============================================================================
-- Window Operations
-- =============================================================================

-- Open the floating terminal
-- Creates a new terminal session or restores an existing one
function floating_terminal.open()
  -- Calculate window geometry
  local width, height = floating_terminal.get_size()
  local row, col = floating_terminal.calculate_position(width, height)

  -- Window configuration for nvim_open_win
  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = floating_terminal.options.border,
    title = floating_terminal.options.title,
    title_pos = floating_terminal.options.title_align,
  }

  -- Check if we have an existing buffer to reuse
  if floating_terminal.bufnr and vim.api.nvim_buf_is_valid(floating_terminal.bufnr) then
    -- Reuse existing buffer (restore session)
    floating_terminal.winid =
      vim.api.nvim_open_win(floating_terminal.bufnr, floating_terminal.options.enter_on_open, opts)
  else
    -- Create new terminal buffer
    floating_terminal.bufnr = vim.api.nvim_create_buf(false, true)
    floating_terminal.winid =
      vim.api.nvim_open_win(floating_terminal.bufnr, floating_terminal.options.enter_on_open, opts)

    -- Configure buffer
    vim.bo[floating_terminal.bufnr].filetype = "floating_terminal"
    vim.bo[floating_terminal.bufnr].buflisted = false
    vim.bo[floating_terminal.bufnr].bufhidden = "hide"

    -- Start terminal process
    floating_terminal.termpid = vim.fn.jobstart(floating_terminal.options.shell, { term = true })

    -- Auto-hide on terminal exit.
    --
    -- The window goes away immediately; the now-dead buffer is dropped on the
    -- next tick so the NEXT toggle starts a fresh shell. Keeping it (which is
    -- what this used to do) meant `<leader>tt` reopened a terminal whose job
    -- had exited: it looked alive, accepted nothing, and the first keypress
    -- made Neovim wipe the finished terminal buffer out from under the module,
    -- after which the toggle needed two more presses to recover. There is no
    -- session left to restore once the shell is gone -- that is what the
    -- hide()/open() path above is for, and it never kills the job.
    if floating_terminal.options.hide_on_exit then
      vim.api.nvim_create_autocmd("TermClose", {
        buffer = floating_terminal.bufnr,
        callback = function()
          floating_terminal.hide()
          -- Deferred: nvim_buf_delete on the buffer whose TermClose is firing
          -- is not allowed from inside the callback.
          vim.schedule(function()
            floating_terminal.close()
          end)
        end,
      })
    end
  end

  -- Configure window appearance
  local winid = floating_terminal.winid
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].spell = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].winblend = floating_terminal.options.winblend

  -- Enter insert mode if not already in it. The old test read 'insertmode',
  -- which was removed from Neovim (the option stub always reports false), so
  -- ask the actual mode instead: "t" means we are already in terminal-insert.
  if vim.api.nvim_get_mode().mode ~= "t" then
    vim.cmd("startinsert")
  end

  -- Configure terminal mode keybindings
  vim.keymap.set(
    "t",
    "<C-\\><C-n>",
    "<C-\\><C-n>",
    { buffer = floating_terminal.bufnr, desc = "Exit terminal mode" }
  )
  vim.keymap.set(
    "t",
    "jk",
    "<C-\\><C-n>",
    { buffer = floating_terminal.bufnr, desc = "Exit terminal mode with jk" }
  )

  -- Update visibility state
  floating_terminal.is_visible = true
end

-- Hide the floating terminal
-- Closes the window but preserves the terminal session (buffer and process)
function floating_terminal.hide()
  if floating_terminal.winid and vim.api.nvim_win_is_valid(floating_terminal.winid) then
    vim.api.nvim_win_close(floating_terminal.winid, true)
  end
  floating_terminal.is_visible = false
end

-- Close and terminate the terminal
-- Destroys the buffer and kills the terminal process
function floating_terminal.close()
  -- Close window if open
  if floating_terminal.winid and vim.api.nvim_win_is_valid(floating_terminal.winid) then
    vim.api.nvim_win_close(floating_terminal.winid, true)
  end

  -- Terminate terminal process
  local job_status = floating_terminal.termpid and vim.fn.jobwait({ floating_terminal.termpid }, 0)[1] or nil
  if job_status == -1 then
    vim.fn.jobstop(floating_terminal.termpid)
  end

  -- Delete buffer
  if floating_terminal.bufnr and vim.api.nvim_buf_is_valid(floating_terminal.bufnr) then
    vim.api.nvim_buf_delete(floating_terminal.bufnr, { force = true })
  end

  -- Clear state
  floating_terminal.bufnr = nil
  floating_terminal.termpid = nil
  floating_terminal.is_visible = false
end

-- Is the floating window actually on screen right now?
--
-- Asked of the window instead of trusting the cached `is_visible` flag: the
-- float can be closed by anything Neovim offers -- `<C-w>c`, `<leader>wd`,
-- `:q`, `:only` -- and none of those routes through hide(), so the flag stayed
-- true while no window existed. toggle() then "hid" nothing and the terminal
-- took TWO presses of <leader>tt to come back.
-- @returns boolean
function floating_terminal.is_open()
  return floating_terminal.winid ~= nil and vim.api.nvim_win_is_valid(floating_terminal.winid)
end

-- Toggle terminal visibility
-- Opens if hidden, hides if visible
function floating_terminal.toggle()
  if floating_terminal.is_open() then
    floating_terminal.hide()
  else
    floating_terminal.open()
  end
end

-- Restart the terminal
-- Closes and reopens with a fresh session
function floating_terminal.restart()
  floating_terminal.close()
  vim.defer_fn(function()
    floating_terminal.open()
  end, 50)
end

-- Send text to the terminal
--
-- Gated on the JOB being alive, not on the window being visible: a hidden
-- terminal is still running and its output accumulates in the buffer, so
-- `:FloatingTerminal send make` after hiding the float is a reasonable thing to
-- do. It used to require visibility and otherwise do nothing at all, with no
-- message -- indistinguishable from the command being broken.
-- @param input (string): Text to send followed by newline
function floating_terminal.send_input(input)
  local job = floating_terminal.termpid
  if not job or vim.fn.jobwait({ job }, 0)[1] ~= -1 then
    vim.notify("FloatingTerminal: no terminal running", vim.log.levels.WARN)
    return
  end
  vim.fn.chansend(job, input .. "\n")
end

-- =============================================================================
-- User Commands
-- =============================================================================

-- Create :FloatingTerminal command with subcommands and completion
vim.api.nvim_create_user_command("FloatingTerminal", function(opts)
  local args = opts.fargs
  if #args > 0 then
    -- Parse subcommands
    if args[1] == "restart" then
      floating_terminal.restart()
    elseif args[1] == "close" then
      floating_terminal.close()
    elseif args[1] == "hide" then
      floating_terminal.hide()
    elseif args[1] == "open" then
      floating_terminal.open()
    elseif args[1] == "toggle" then
      floating_terminal.toggle()
    elseif args[1] == "send" then
      -- Send remaining arguments as command
      table.remove(args, 1)
      floating_terminal.send_input(table.concat(args, " "))
    else
      vim.notify("Unknown command: " .. args[1], vim.log.levels.WARN)
    end
  else
    -- Default: toggle visibility
    floating_terminal.toggle()
  end
end, {
  nargs = "*",
  -- Complete the SUBCOMMAND, so match against ArgLead (the word being typed)
  -- and anchor at position 1. The old version took the second parameter
  -- (CmdLine -- the whole ":FloatingTerminal o" line) and searched for THAT
  -- inside each subcommand name, which can never match: `("open"):find(
  -- "FloatingTerminal o", 1, true)` is nil. The result was a completion
  -- function that always returned {}, so <Tab> offered nothing at all.
  complete = function(arg_lead)
    local cmds = { "open", "close", "hide", "toggle", "restart", "send" }
    local matches = {}
    for _, cmd in ipairs(cmds) do
      if arg_lead == "" or cmd:find(arg_lead, 1, true) == 1 then
        table.insert(matches, cmd)
      end
    end
    return matches
  end,
})

-- =============================================================================
-- Global Keybindings
-- =============================================================================

-- Toggle floating terminal with leader key
vim.keymap.set("n", "<leader>tt", function()
  floating_terminal.toggle()
end, { desc = "Toggle floating terminal" })

-- Toggle floating terminal with <C-/> (quick access, normal + terminal mode).
-- <C-_> is the byte sequence many terminal emulators actually send for Ctrl-/,
-- so map both for compatibility. Terminal-mode mapping lets <C-/> toggle the
-- terminal back off from inside it.
vim.keymap.set({ "n", "t" }, "<C-/>", function()
  floating_terminal.toggle()
end, { desc = "Toggle floating terminal" })
vim.keymap.set({ "n", "t" }, "<C-_>", function()
  floating_terminal.toggle()
end, { desc = "which_key_ignore" })
