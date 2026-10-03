-- =============================================================================
-- snacks.image: don't typeset the equation being edited, never re-run a
-- conversion that already failed
-- =============================================================================
-- Two per-keystroke costs in snacks' inline math pipeline, both fixed here
-- from the config side (the plugin is lazy-managed; edits there would be lost):
--
-- (A) THE STORM. inline.lua attaches `on_lines` behind a hardcoded 100ms
--     debounce (inline.lua:15-35, not configurable) and the math cache key is
--     the sha256 of the generated .tex (doc.lua:329). So every keystroke inside
--     `$...$` / `$$...$$` is a brand-new src -> a brand-new placement -> a
--     fresh pdflatex + convert pair for each transient string, queued three at
--     a time by MAX_PROCS (convert.lua:203), plus one orphan `.tex` written to
--     the cache per keystroke (doc.lua:324-336). 1288 such files had
--     accumulated before this existed.
--
--     Fix: wrap `doc._img` so it returns nil for a generated image (math,
--     ```math, ```mermaid, i.e. anything with a `content` capture) whose node
--     contains the cursor while in Insert/Replace mode. `_img` already returns
--     nil on its own when math is disabled (doc.lua:303-305) and `find` stores
--     the result with `ret[#ret + 1] = ...`, so nil is a supported no-op. Bailing
--     out here, rather than filtering `find_visible`'s result, also skips the
--     sha256 + `.tex` write. inline:update then closes the placement for that
--     equation (inline.lua:137-141), which is the same visual state its own
--     conceal() gives the cursor line: image gone, source shown.
--
--     Re-render: snacks' own ModeChanged handler only calls `conceal()`
--     (inline.lua:24-32), never `update()`, so leaving Insert mode would leave
--     the equation unrendered until the next edit/scroll/write. A ModeChanged
--     `i*:*` / `R*:*` autocmd below calls `update()` once on insert exit. The
--     cursor moving PAST an equation while still typing is covered by
--     `on_lines` itself (the keystroke that moved it re-runs update with the
--     cursor outside). No CursorMovedI hook on purpose: it would bypass the
--     debounce and run a full treesitter query per typed character.
--
-- (B) NO NEGATIVE CACHE. In-session repeats are already deduped: image.lua
--     keys `images[file]` on the output png and returns the cached (failed
--     included) object before `run()` (image.lua:50-57). The gap is
--     cross-session: every new nvim re-runs every permanently-failing job in a
--     document, with one `convert.notify` toast each. An empty `<png>.failed`
--     marker next to the target closes it; `Convert.new` spawns nothing (only
--     `:run()` does, convert.lua:452), so replacing `run` on a known-failed
--     instance is a complete short-circuit and never reaches `Convert:on_done`,
--     i.e. no toast. Restricted to sources UNDER the snacks cache dir: those
--     are content-addressed and therefore deterministic. A plain `![](foo.png)`
--     that does not exist yet ("File not found", convert.lua:457-461) must stay
--     retryable because the file may appear later.
--
--     Only the exact same rendered .tex stays failed -- fixing the equation
--     changes the hash. Fixing the TOOLCHAIN (installing a package, editing the
--     template) needs `:SnacksImageRetryFailed`.
--
-- Pinned to snacks 882c996. On upgrade re-check doc.lua:277 (`M._img`),
-- inline.lua:90 (`M:update`) and convert.lua:496 (`M.convert`).

local M = {}

M.MARKER = ".failed"

---@type table<number, snacks.image.inline>
M._instances = {}
---@type table<string, true>
M._failed = {}

---Pure range test. `range6` is what `vim.treesitter.get_range` returns
---(0-based, end-exclusive); `row0`/`col` are a 0-based cursor.
---Applies the same fix-up as doc.lua:283-287: a node that ends at column 0 of
---a line really ends at the END of the previous line, so the cursor sitting at
---(end_row, 0) -- the line after a closing `$$` -- is NOT inside.
---@param range6 Range6
---@param row0 number
---@param col number
---@return boolean
function M.cursor_in_range(range6, row0, col)
  local sr, sc, er, ec = range6[1], range6[2], range6[4], range6[5]
  if ec == 0 and er > sr then
    er, ec = er - 1, math.huge
  end
  if row0 < sr or row0 > er then
    return false
  end
  if row0 == sr and col < sc then
    return false
  end
  if row0 == er and col > ec then
    return false
  end
  return true
end

---True when `ctx` is a generated image (has a `content` capture) that the
---cursor is inside of while Insert/Replace mode is active in that buffer.
---@param ctx snacks.image.ctx
---@return boolean
function M.editing(ctx)
  if not ctx.content then
    return false -- file-backed ![](x.png): never deferred, never negative-cached
  end
  local mode = vim.api.nvim_get_mode().mode:sub(1, 1)
  if mode ~= "i" and mode ~= "R" then
    return false
  end
  if ctx.buf ~= vim.api.nvim_get_current_buf() then
    return false
  end
  local pos = ctx.pos or ctx.src or ctx.content
  local ok, range6 = pcall(vim.treesitter.get_range, pos.node, ctx.buf, pos.meta)
  if not ok or not range6 then
    return false
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  return M.cursor_in_range(range6, cur[1] - 1, cur[2])
end

---@param src any
---@return boolean
local function generated(src)
  return type(src) == "string"
    and vim.startswith(vim.fs.normalize(src), vim.fs.normalize(Snacks.image.config.cache))
end

---@param file string
local function mark_failed(file)
  if M._failed[file] then
    return
  end
  M._failed[file] = true
  local fd = io.open(file .. M.MARKER, "w")
  if fd then
    fd:close()
  end
end

---@param c snacks.image.Convert
---@return boolean
local function is_failed(c)
  if M._failed[c.file] then
    return true
  end
  if generated(c.src) and (vim.uv or vim.loop).fs_stat(c.file .. M.MARKER) then
    M._failed[c.file] = true
    return true
  end
  return false
end

---Forget every recorded failure (memory + on-disk markers), drop snacks' image
---cache and re-render every attached buffer.
function M.retry_failed()
  M._failed = {}
  local cache = Snacks.image.config.cache
  for _, f in ipairs(vim.fn.glob(cache .. "/*" .. M.MARKER, true, true)) do
    vim.fn.delete(f)
  end
  Snacks.image.image.clear() -- image.lua:212: `images = {}`, failed ones included
  for buf, inline in pairs(M._instances) do
    if vim.api.nvim_buf_is_valid(buf) then
      for id, p in pairs(inline.imgs) do
        p:close()
        inline.imgs[id] = nil
      end
      inline.idx = {}
      inline:update()
    else
      M._instances[buf] = nil
    end
  end
end

function M.setup()
  -- No-op without the image module (image disabled, or a spec driving the
  -- snacks plugin spec against a stub Snacks).
  local Image = type(Snacks) == "table" and Snacks.image or nil
  if type(Image) ~= "table" then
    return
  end
  local doc, inline, convert = Image.doc, Image.inline, Image.convert -- lazy requires (image/init.lua:10-18)

  -- (A) ---------------------------------------------------------------------
  local raw_img = doc._img
  doc._img = function(ctx)
    if M.editing(ctx) then
      return nil
    end
    return raw_img(ctx)
  end

  -- `Snacks.image.inline.new(buf)` (doc.lua:453) discards its return value, so
  -- there is no registry to trigger an update through. `M.__index = M` and
  -- `self:update()` resolve dynamically, so wrapping the class method both
  -- records the instance and keeps every existing caller intact.
  local raw_update = inline.update
  inline.update = function(self)
    M._instances[self.buf] = self
    return raw_update(self)
  end

  local group = vim.api.nvim_create_augroup("andrew_snacks_image_math", { clear = true })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = { "i*:*", "R*:*" }, -- any exit from insert/replace, <C-c> included
    desc = "snacks.image: render the equation left behind on insert exit",
    callback = function(ev)
      local self = M._instances[ev.buf]
      if self then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(ev.buf) then
            self:update()
          end
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(ev)
      M._instances[ev.buf] = nil
    end,
  })

  -- (B) ---------------------------------------------------------------------
  local raw_convert = convert.convert
  convert.convert = function(o)
    local on_done = o.on_done
    o.on_done = function(c)
      if c:error() and not c.aborted and c.file and generated(c.src) then
        mark_failed(c.file)
      end
      if on_done then
        return on_done(c)
      end
    end
    local c = raw_convert(o)
    if c.file and is_failed(c) then
      c.run = function(self)
        -- done + failed, no spawn, and not via Convert:on_done -> no toast.
        self._err = self._err
          or ("conversion failed in an earlier session (%s exists); :SnacksImageRetryFailed to retry"):format(
            vim.fn.fnamemodify(self.file .. M.MARKER, ":t")
          )
        self._done = true
        if self.opts.on_done then
          self.opts.on_done(self)
        end
      end
    end
    return c
  end

  vim.api.nvim_create_user_command("SnacksImageRetryFailed", M.retry_failed, {
    desc = "Snacks image: forget failed conversions and re-render every attached buffer",
  })
end

return M
