--- Obsidian-style "readable line length" for markdown buffers.
---
--- Neovim has no native max-soft-wrap-width. Verified against the 0.12 docs and
--- by experiment: 'textwidth'/'wrapmargin' are HARD wrap only (they insert real
--- <EOL>s and do not move the soft-wrap point at all), and the gutter route
--- ('foldcolumn' max 9 + 'signcolumn' max yes:9 + 'numberwidth') tops out around
--- 25-30 columns and is left-side-only -- useless as a width cap on a wide
--- terminal. The only way to shrink the text area symmetrically is real windows.
---
--- So: flank the content window with fixed-width scratch "pad" windows.
---
--- Design notes (borrowed from Zed's resize path, crates/editor):
---   * Coalesce before debouncing. apply() computes the desired pad widths and
---     returns early when they already match what is on screen, so a drag-resize
---     that lands on an already-correct width does zero work. This mirrors
---     WrapMap::set_wrap_width returning false on an unchanged width
---     (display_map/wrap_map.rs:154-157) -- the cheapest debounce is an equality
---     check, applied before the timer rather than after it.
---   * Verify by measuring, then give up cleanly. The pad arithmetic is exact
---     (measured across 128 width/gutter combinations), so no corrective
---     iteration is needed -- but the INPUT can be wrong: apply() budgets from
---     window widths, which are still pre-resize values when called in the same
---     tick as a layout change. That over-pads and leaves the text narrower than
---     doing nothing. So the result is measured and the columns handed back
---     rather than half-applied.
---   * Re-entrancy guard. Creating and resizing windows fires WinNew/WinResized,
---     which would re-enter this module; all mutation runs under _applying.
---
--- Layout policy: pads are applied only when the content window has no genuine
--- vertical neighbour. Windows stacked in the same column (a plain :split) are
--- fine and are treated as one column group; a :vsplit of two real buffers
--- disables padding entirely rather than guessing which side to shrink. The
--- vault sidebar is exempt because it sets 'winfixwidth' (sidebar.lua:110).

local M = {}

local config = require("andrew.vault.config")

--- Window-variable marking a pad window. Stored on the window (not in a Lua
--- table) so pads are still identifiable after a config reload drops module
--- state, and so a stale entry can never outlive the window it names.
local PAD_VAR = "vault_readable_pad"

--- Re-entrancy guard: window mutation fires the very events that drive us.
local _applying = false

--- Pending debounce timer (cancel-and-reschedule, one in flight at most).
local _timer = nil

--- User-facing on/off. nil means "follow config.readable_width.enabled".
local _enabled = nil

-- ---------------------------------------------------------------------------
-- Predicates
-- ---------------------------------------------------------------------------

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ""
end

local function is_pad(win)
  local ok, v = pcall(vim.api.nvim_win_get_var, win, PAD_VAR)
  return ok and v == true
end

--- Is this window one we should be centering?
local function is_content(win)
  if is_pad(win) or is_float(win) then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  for _, want in ipairs(config.readable_width.filetypes) do
    if ft == want then return true end
  end
  return false
end

function M.enabled()
  if _enabled ~= nil then return _enabled end
  return config.readable_width.enabled
end

-- ---------------------------------------------------------------------------
-- Layout inspection
-- ---------------------------------------------------------------------------

--- Non-floating windows in the current tabpage.
local function tab_windows()
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and not is_float(win) then
      out[#out + 1] = win
    end
  end
  return out
end

--- Windows sharing `win`'s horizontal extent, i.e. stacked above/below it in the
--- same column (what `:split` produces). Padding one pads the whole stack.
local function column_group(wins, win)
  local col = vim.api.nvim_win_get_position(win)[2]
  local width = vim.api.nvim_win_get_width(win)
  local group = {}
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_get_position(w)[2] == col
      and vim.api.nvim_win_get_width(w) == width then
      group[#group + 1] = w
    end
  end
  return group
end

--- The pads currently flanking `win`, as { left = win|nil, right = win|nil }.
--- A pad qualifies only if it is vertically adjacent to the content column and
--- spans the same rows, so an unrelated pad in another split is never adopted.
local function adjacent_pads(wins, win)
  local pos = vim.api.nvim_win_get_position(win)
  local row, col = pos[1], pos[2]
  local width = vim.api.nvim_win_get_width(win)
  local found = { left = nil, right = nil }
  for _, w in ipairs(wins) do
    if is_pad(w) then
      local wpos = vim.api.nvim_win_get_position(w)
      if wpos[1] == row then
        local wwidth = vim.api.nvim_win_get_width(w)
        -- +1 for the vertical separator column between the two windows.
        if wpos[2] + wwidth + 1 == col then
          found.left = w
        elseif col + width + 1 == wpos[2] then
          found.right = w
        end
      end
    end
  end
  return found
end

-- ---------------------------------------------------------------------------
-- Pad lifecycle
-- ---------------------------------------------------------------------------

local function configure_pad(win, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "vault_readable_pad"

  vim.api.nvim_win_set_var(win, PAD_VAR, true)
  -- winfixwidth is load-bearing twice over: it stops 'equalalways' from
  -- rebalancing the pads away when any new window opens, and it is how
  -- column_group()/the neighbour check tell pads apart from real splits.
  vim.wo[win].winfixwidth = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].cursorline = false
  vim.wo[win].cursorcolumn = false
  vim.wo[win].spell = false
  vim.wo[win].list = false
  vim.wo[win].wrap = false
  -- Blank the '~' end-of-buffer markers so the pad reads as empty margin.
  vim.wo[win].fillchars = "eob: "
  pcall(function() vim.wo[win].winfixbuf = true end)
end

--- Create a pad on `side` of `content_win`. Returns the pad winid, or nil.
local function create_pad(content_win, side)
  local pad
  local ok = pcall(vim.api.nvim_win_call, content_win, function()
    vim.cmd(side == "left" and "leftabove vsplit" or "rightbelow vsplit")
    pad = vim.api.nvim_get_current_win()
  end)
  if not ok or not pad or not vim.api.nvim_win_is_valid(pad) then
    return nil
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(pad, buf)
  configure_pad(pad, buf)
  return pad
end

local function close_pad(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

--- Close every pad in the current tabpage.
local function remove_all_pads()
  for _, win in ipairs(tab_windows()) do
    if is_pad(win) then close_pad(win) end
  end
end

-- ---------------------------------------------------------------------------
-- The apply pass
-- ---------------------------------------------------------------------------

--- Columns consumed by this window's gutter (number/sign/fold/statuscolumn).
local function textoff(win)
  local info = vim.fn.getwininfo(win)
  return (info and info[1] and info[1].textoff) or 0
end

--- Pick the window to centre: prefer the current one, else the sole content
--- window in the tabpage. Returns nil when the choice is ambiguous.
local function pick_content(wins)
  local cur = vim.api.nvim_get_current_win()
  if vim.tbl_contains(wins, cur) and is_content(cur) then
    return cur
  end
  local found
  for _, w in ipairs(wins) do
    if is_content(w) then
      if found then return nil end -- ambiguous: two candidates, no current
      found = w
    end
  end
  return found
end

--- Recompute and apply padding for the current tabpage. Idempotent.
--- @return string status one of: "applied", "unchanged", "removed", "skipped"
function M.apply()
  if _applying then return "skipped" end

  local wins = tab_windows()
  if #wins == 0 then return "skipped" end

  local content = M.enabled() and pick_content(wins) or nil
  if not content then
    -- Disabled, or enabled but nothing to centre (the content window now shows
    -- a non-markdown buffer). Either way stale pads must not outlive the
    -- markdown buffer they were built for: a .txt left centred between two
    -- pads reads as "readable width stuck on".
    local had_pads = false
    for _, w in ipairs(wins) do
      if is_pad(w) then had_pads = true break end
    end
    if not had_pads then return "skipped" end
    _applying = true
    remove_all_pads()
    _applying = false
    return "removed"
  end

  local group = column_group(wins, content)
  local pads = adjacent_pads(wins, content)

  -- Bail out (and clean up) if the content column has a genuine vertical
  -- neighbour: another real buffer split beside it. Pads and 'winfixwidth'
  -- windows (the vault sidebar) do not count.
  for _, w in ipairs(wins) do
    if not is_pad(w) and not vim.tbl_contains(group, w) and not vim.wo[w].winfixwidth then
      _applying = true
      remove_all_pads()
      _applying = false
      return "removed"
    end
  end

  local content_w = vim.api.nvim_win_get_width(content)
  local left_w = pads.left and vim.api.nvim_win_get_width(pads.left) or 0
  local right_w = pads.right and vim.api.nvim_win_get_width(pads.right) or 0
  local n_pads = (pads.left and 1 or 0) + (pads.right and 1 or 0)

  -- Total columns this column group may spend, pads and their separators
  -- included. Reclaiming the existing pads' columns is what makes apply()
  -- idempotent rather than shrinking the content a little on every pass.
  local total = content_w + left_w + right_w + n_pads

  local want_win = config.readable_width.columns + textoff(content)
  local min_pad = config.readable_width.min_pad_width

  -- Not enough room to pad meaningfully -- give every column back to the text.
  if total < want_win + 2 * (min_pad + 1) then
    if n_pads > 0 then
      _applying = true
      close_pad(pads.left)
      close_pad(pads.right)
      _applying = false
      return "removed"
    end
    return "unchanged"
  end

  local spare = total - want_win - 2 -- two separator columns
  local want_left = math.floor(spare / 2)
  local want_right = spare - want_left

  -- Coalesce before debouncing: if the layout already matches, do nothing.
  -- Equivalent to WrapMap::set_wrap_width's unchanged-width early return.
  if pads.left and pads.right and left_w == want_left and right_w == want_right then
    return "unchanged"
  end

  _applying = true
  local ok = pcall(function()
    local left = pads.left or create_pad(content, "left")
    local right = pads.right or create_pad(content, "right")
    if left then vim.api.nvim_win_set_width(left, want_left) end
    if right then vim.api.nvim_win_set_width(right, want_right) end
  end)

  -- Verify by measuring, and give up cleanly rather than half-applying.
  -- `total` is derived from window widths, which are still the PRE-resize
  -- values when apply() runs in the same tick as a layout change (M.schedule
  -- defers precisely to avoid this, but a direct apply() can hit it). Budgeting
  -- from a too-large total over-pads, leaving the text NARROWER than it would
  -- have been with no padding at all -- strictly worse than doing nothing.
  -- So measure the result and hand the columns back instead.
  local short = ok and (vim.api.nvim_win_get_width(content) - textoff(content)) < config.readable_width.columns
  if not ok or short then
    remove_all_pads()
    _applying = false
    return "removed"
  end

  _applying = false
  return "applied"
end

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

--- Debounced apply. Cancel-and-reschedule so a drag-resize collapses into one
--- pass at the end rather than one per frame (cf. DebouncedDelay::fire_new,
--- crates/project/src/debounced_delay.rs).
function M.schedule()
  if _applying then return end
  if _timer then
    _timer:stop()
    _timer:close()
    _timer = nil
  end
  _timer = vim.uv.new_timer()
  _timer:start(config.readable_width.debounce_ms, 0, function()
    if _timer then
      _timer:stop()
      _timer:close()
      _timer = nil
    end
    vim.schedule(function()
      if vim.api.nvim_get_mode().mode:sub(1, 1) == "c" then return end
      M.apply()
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Public control
-- ---------------------------------------------------------------------------

function M.enable()
  _enabled = true
  M.apply()
end

function M.disable()
  _enabled = false
  _applying = true
  remove_all_pads()
  _applying = false
end

function M.toggle()
  if M.enabled() then M.disable() else M.enable() end
  return M.enabled()
end

--- Toggle and report which state we landed in. Shared by the command and the
--- keymap so they can never drift apart.
function M.notify_toggle()
  local on = M.toggle()
  require("andrew.vault.notify").info(
    on and ("readable width on (" .. config.readable_width.columns .. " columns)")
      or "readable width off (full window)"
  )
  return on
end

--- Set the target text width for this session and re-apply.
function M.set_columns(n)
  n = tonumber(n)
  if not n or n < 20 then
    require("andrew.vault.notify").warn("readable width must be >= 20 columns")
    return
  end
  config.readable_width.columns = math.floor(n)
  M.apply()
end

function M.setup()
  local group = vim.api.nvim_create_augroup("VaultReadableWidth", { clear = true })

  -- Layout changed: a window opened, closed, or was resized.
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "WinResized", "VimResized" }, {
    group = group,
    callback = function() M.schedule() end,
  })

  -- A markdown buffer became visible, or focus moved onto one.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = group,
    callback = function() M.schedule() end,
  })

  -- Never leave the cursor parked in a pad. Pads must be stepped THROUGH, not
  -- bounced off: with the sidebar open the layout is [content][pad][sidebar],
  -- so bouncing every entry back to the content window would make the sidebar
  -- unreachable by <C-w>l. Continue in the direction of travel instead, and
  -- only fall back to the content window when there is nothing beyond the pad.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local pad = vim.api.nvim_get_current_win()
      if not is_pad(pad) then return end

      local wins = tab_windows()
      local pad_col = vim.api.nvim_win_get_position(pad)[2]
      local prev = vim.fn.win_getid(vim.fn.winnr("#"))
      -- Direction of travel: +1 when we came from the left, -1 from the right.
      local dir = 1
      if prev ~= 0 and vim.api.nvim_win_is_valid(prev) and prev ~= pad then
        dir = vim.api.nvim_win_get_position(prev)[2] < pad_col and 1 or -1
      end

      -- Nearest non-pad window strictly beyond the pad, in that direction.
      local best, best_col
      for _, w in ipairs(wins) do
        if w ~= pad and not is_pad(w) then
          local col = vim.api.nvim_win_get_position(w)[2]
          if (dir == 1 and col > pad_col) or (dir == -1 and col < pad_col) then
            if not best_col or math.abs(col - pad_col) < math.abs(best_col - pad_col) then
              best, best_col = w, col
            end
          end
        end
      end

      if not best then
        for _, w in ipairs(wins) do
          if is_content(w) then best = w break end
        end
      end
      if best then pcall(vim.api.nvim_set_current_win, best) end
    end,
  })

  vim.api.nvim_create_user_command("VaultReadableWidth", function(opts)
    if opts.args == "" then
      M.notify_toggle()
    else
      M.set_columns(opts.args)
    end
  end, { nargs = "?", desc = "Toggle readable line length, or set its column count" })

  -- Sits in the <leader>u* toggle namespace next to <leader>uw ('wrap'), since
  -- "cap the column" and "wrap at all" are the two knobs on the same feature.
  vim.keymap.set("n", "<leader>uW", function()
    M.notify_toggle()
  end, { desc = "Toggle readable width (full window <-> centred column)" })

  -- Pad the buffer that triggered our own deferred load. setup() runs from a
  -- vim.schedule inside the first markdown FileType (vault/init.lua), i.e.
  -- AFTER that window's BufWinEnter has already fired; init.lua's re-triggers
  -- (FileType/BufReadPost/BufEnter) are events this module does not listen to.
  -- Without this the first note of the session stays full-width until the
  -- next window event of any kind (another note, a picker, a resize), at
  -- which point the pads pop in -- indistinguishable from <leader>uW firing
  -- on its own.
  M.schedule()
end

return M
