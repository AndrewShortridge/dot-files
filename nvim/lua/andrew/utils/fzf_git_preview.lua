-- =============================================================================
-- fzf-lua Git Preview: command output in a Neovim preview window
-- =============================================================================
-- fzf-lua's git pickers (commits, file history, blame, stash, diff) preview
-- with a shell command -- `git show --color {1} | delta ...` -- that fzf runs
-- and prints inside its own window. That leaves fzf-lua a single window to
-- frame, so those pickers were one box with a divider while every picker that
-- previews a FILE got the look's two rounded boxes (andrew/utils/fzf_look.lua).
--
-- This previewer runs the same command but shows its output in fzf-lua's
-- Neovim preview window, through a terminal buffer so git's and delta's
-- colours survive. The pickers then frame, title and scroll like the rest.
--
-- It does not know any git command itself. By the time fzf-lua builds the
-- previewer, the git provider has already written the finished command into
-- `opts.preview`, pager included; that string is the template. What fzf would
-- have done to it for each row -- fill in the `{1}` / `{-1}` / `{}` field
-- placeholders -- is done here instead, which is the one piece of fzf this
-- has to imitate (see split_fields).
--
-- `git_status` is the exception: its previewer is a Lua object that picks
-- between three commands by the file's state, not a command string. fzf-lua
-- can already show that one in a Neovim window (its `vterm` previewer); the
-- second class here is that, plus the title and the length cap the first has.
--
-- Both are switched on in fzf_look.lua.

local M = {}

--- Longest preview shown. A terminal buffer keeps only its last 'scrollback'
--- lines (10000 by default), so a longer one -- the commit that added a lock
--- file -- would lose its START, commit message included.
local MAX_PREVIEW_LINES = 5000

--- Split a picker row into the fields fzf's `{N}` placeholders count.
--- Covers the delimiters fzf-lua's git pickers set: none (runs of whitespace,
--- as in awk), a literal string (a tab, the space after a file icon) and a
--- bracketed set of literal characters (`[:]`). fzf also accepts arbitrary
--- regular expressions there; no git picker uses one.
---@param entry_text string the row, as fzf reports it (colours stripped)
---@param delimiter? string the picker's `--delimiter`
---@return string[]
local function split_fields(entry_text, delimiter)
  if not delimiter then
    return vim.split(vim.trim(entry_text), "%s+")
  end
  local character_set = delimiter:match("^%[(.+)%]$")
  if character_set then
    return vim.split(entry_text, "[" .. character_set:gsub("%W", "%%%0") .. "]")
  end
  return vim.split(entry_text, delimiter, { plain = true })
end

--- Shell invocation for a preview command, cut at MAX_PREVIEW_LINES. `awk`
--- quits at the limit, which also stops git and the pager behind it.
---
--- It also prints a line when the command prints none. fzf-lua only attaches
--- the preview buffer once output arrives and then asserts that it has one,
--- so a silent command -- `git show ^<hash>` for a git_blame row from the
--- repository's first commit -- raised a traceback instead of showing nothing.
---@param command string
---@return string[]
local function capped_shell_command(command)
  local awk_program = (
    'NR <= %d { print; next } { print ""; print "-- preview cut at %d lines --"; exit } '
    .. 'END { if (NR == 0) print "-- no output --" }'
  ):format(MAX_PREVIEW_LINES, MAX_PREVIEW_LINES)
  return { "sh", "-c", ("{ %s; } | awk '%s'"):format(command, awk_program) }
end

---@type table?, table? the previewer classes, built on first use
local git_command_previewer, git_status_previewer

--- The previewer class. Built on demand because it extends a fzf-lua class,
--- and this module is read while fzf-lua's setup() table is still being put
--- together.
local function get_git_command_previewer()
  if git_command_previewer then
    return git_command_previewer
  end

  local GitCommandPreviewer = require("fzf-lua.previewer.builtin").buffer_or_file:extend()

  function GitCommandPreviewer:new(previewer_opts, picker_opts)
    GitCommandPreviewer.super.new(self, previewer_opts, picker_opts)
    -- Read now: fzf-lua replaces `opts.preview` with this previewer's own
    -- callback as soon as the constructor returns.
    self.command_template = picker_opts.preview
    return self
  end

  --- fzf-lua calls this for the row under the cursor. Returning `cmd` makes
  --- it run that command and stream the output into the preview window.
  function GitCommandPreviewer:parse_entry(entry_text)
    if type(self.command_template) ~= "string" then
      return { content = { { { "This picker has no preview command.", "Comment" } } } }
    end

    local fields = split_fields(entry_text, self.opts.fzf_opts["--delimiter"])
    local first_value
    local command = self.command_template:gsub("{(%-?%d*)}", function(field_index)
      local value
      if field_index == "" then
        value = entry_text
      else
        local position = tonumber(field_index)
        if not position then
          return nil -- "{-}" is not a placeholder; leave it as written
        end
        value = fields[position > 0 and position or #fields + position + 1] or ""
      end
      value = vim.trim(value)
      first_value = first_value or value
      return vim.fn.shellescape(value)
    end)

    -- fzf exports these to a preview command; the pager reads the width.
    local preview_window = self.win.layout.preview
    return {
      cmd = capped_shell_command(command),
      cmd_opts = {
        cwd = self.opts.cwd,
        env = {
          FZF_PREVIEW_COLUMNS = preview_window.width,
          FZF_PREVIEW_LINES = preview_window.height,
          COLUMNS = preview_window.width,
          LINES = preview_window.height,
        },
      },
      -- What the row stands for -- a commit hash, a stash, a file -- titles
      -- the preview box the way a file name does in the file pickers.
      title = first_value and (" " .. first_value .. " ") or nil,
      -- Keyed by path in fzf-lua's buffer cache, and these rows have none.
      do_not_cache = true,
    }
  end

  git_command_previewer = GitCommandPreviewer
  return git_command_previewer
end

--- The `git_status` previewer class: fzf-lua's terminal-buffer wrapper around
--- its own status previewer, which is what `previewers.git_diff.vterm = true`
--- would build, with a title and the length cap added to what it returns.
local function get_git_status_previewer()
  if git_status_previewer then
    return git_status_previewer
  end

  local GitStatusPreviewer = require("fzf-lua.previewer.builtin").vterm:extend()

  function GitStatusPreviewer:new(previewer_opts, picker_opts)
    -- `previewer_opts` is fzf-lua's `previewers.git_diff` table, which is the
    -- configuration its status previewer reads (the three commands, the pager).
    local status_commands = require("fzf-lua.previewer.fzf").git_diff(previewer_opts, picker_opts)
    GitStatusPreviewer.super.new(self, previewer_opts, picker_opts, status_commands)
    return self
  end

  function GitStatusPreviewer:parse_entry(status_row)
    local entry = GitStatusPreviewer.super.parse_entry(self, status_row)
    if type(entry.cmd) == "table" and entry.cmd[1] == "sh" and #entry.cmd == 3 then
      entry.cmd = capped_shell_command(entry.cmd[3])
    end
    -- A renamed file is listed as `old -> new`; the diff shown is the new one's.
    local file = self:entry_to_file(status_row:match("%s%->%s(.*)$") or status_row).path
    if file then
      local shown_path = require("fzf-lua.path").relative_to(file, self.opts.cwd or vim.uv.cwd())
      entry.title = " " .. shown_path .. " "
    end
    return entry
  end

  git_status_previewer = GitStatusPreviewer
  return git_status_previewer
end

--- fzf-lua previewer spec: `previewer = fzf_git_preview.previewer` on any
--- picker whose `preview` is a shell command.
M.previewer = { _ctor = get_git_command_previewer }

--- Constructor for fzf-lua's `previewers.git_diff`, the one `git_status` uses.
M.status_previewer = { _ctor = get_git_status_previewer }

return M
