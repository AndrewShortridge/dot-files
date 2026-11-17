-- Inside tmux, tell snacks.image which terminal it is in by asking TMUX, not
-- the terminal.
--
-- WHY
--
-- snacks identifies the terminal with XTVERSION (`CSI > q`) and, inside tmux,
-- wraps the query in tmux passthrough so that the outer terminal answers
-- rather than tmux (snacks/image/terminal.lua, `M._detect`). Kitty's answer,
-- `ESC P > | kitty(0.49.2) ESC \`, comes back to tmux, and tmux reads an
-- XTVERSION answer once per client: it asked the same question itself when
-- the client attached (tty-keys.c, `tty_keys_extended_device_attributes`
-- returns early on `TTY_HAVEXDA`). A second answer is therefore plain key
-- input:
--
--   ESC P             -> M-P, sent to the pane
--   >|kitty(0.49.2)   -> typed into the pane, i.e. into Neovim
--   ESC \             -> M-\, which ~/.config/tmux/tmux.conf binds to
--                        `split-window -h`
--
-- So the first markdown buffer of a session (the first thing that needs
-- snacks.image) split the tmux pane and typed `>|kitty(0.49.2)` into whatever
-- had focus. Neovim never saw a TermResponse either, so the detection also
-- sat out its 1 s timeout and ended on "unknown".
--
-- snacks already has the fix, behind a condition that is too narrow: with
-- tmux's `extended-keys` on it skips the query and reads the name from tmux
-- (snacks.nvim#2332). The reply leaks with `extended-keys` off just the same.
--
-- WHAT
--
-- `M._detect` is wrapped. Its first call inside tmux fills in `M._terminal`
-- from `#{client_termtype}` -- the XTVERSION answer tmux itself got from the
-- terminal -- so upstream's function finds the terminal already known and
-- sends nothing. The two other things upstream's tmux branch does are kept,
-- taken from snacks' own `tmux` environment entry rather than copied: the
-- pane's `allow-passthrough` is switched on and graphics commands are wrapped
-- in passthrough. Those elicit no answer (snacks sends them with `q=2`).
--
-- Pinned by tests/snacks_tmux_terminal_spec.lua, which also fails once
-- upstream stops sending the query -- drop this file then.

local M = {}

--- A `tmux display-message` that does not answer in this long is killed.
local TMUX_TIMEOUT_MILLISECONDS = 1000

--- The name of the terminal the tmux client is attached from: what it answered
--- to tmux's own XTVERSION query (`kitty(0.49.2)`), else its `$TERM`
--- (`xterm-kitty`), which is what snacks falls back to as well.
local TERMINAL_NAME_FORMAT = "#{?client_termtype,#{client_termtype},#{client_termname}}"

---@return string? name
---@return string? version
local function terminal_name_from_tmux()
  -- pcall: vim.system raises when `tmux` is not on $PATH.
  local is_answered, result = pcall(function()
    return vim
      .system({ "tmux", "display-message", "-p", TERMINAL_NAME_FORMAT }, { text = true })
      :wait(TMUX_TIMEOUT_MILLISECONDS)
  end)
  if not is_answered or result.code ~= 0 then
    return nil
  end
  -- The split snacks applies to an XTVERSION answer: name, then version.
  local name, version = vim.trim(result.stdout or ""):gsub("^xterm%-", ""):match("^(%S+)%s*(.*)$")
  return name, version
end

function M.setup()
  if not vim.env.TMUX then
    return
  end

  local terminal = require("snacks.image.terminal")
  local detect_by_query = terminal._detect

  terminal._detect = function(on_detected)
    if not terminal._terminal then
      for _, environment in ipairs(terminal.envs()) do
        if environment.name == "tmux" then
          environment.setup()
          terminal.transform = environment.transform
        end
      end
      local name, version = terminal_name_from_tmux()
      terminal._terminal = { terminal = name or "unknown", version = version or "unknown" }
    end
    return detect_by_query(on_detected)
  end
end

return M
