-- =============================================================================
-- Snacks.nvim Configuration
-- =============================================================================
-- Utility collection by folke. Modules are opt-in.
-- Currently enabled: input (for opencode.nvim), image (inline rendering).

-- Set SNACKS_KITTY before ANY Snacks code loads.
-- This must happen at parse time (not in init/config) because Snacks modules
-- may be accessed by other plugins during startup, triggering env() caching
-- before init() runs. The env var causes snacks terminal.env() to force-detect
-- Kitty regardless of DA3 async state.
if not os.getenv("SNACKS_KITTY") then
  if os.getenv("KITTY_WINDOW_ID") or os.getenv("KITTY_PID") then
    vim.env.SNACKS_KITTY = "1"
  end
end

return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,

  init = function()
    -- Safety net: if env() was somehow cached before the env var was set,
    -- invalidate the cache so the next access re-evaluates. This handles
    -- edge cases where another plugin's init() accessed Snacks.image before
    -- this spec was parsed.
    if vim.env.SNACKS_KITTY == "1"
      and Snacks
      and Snacks.image
      and Snacks.image.terminal
    then
      local term = Snacks.image.terminal
      if term._env and not term._env.placeholders then
        -- Cache was poisoned — clear it so next env() call picks up SNACKS_KITTY
        term._env = nil
      end
    end
  end,

  ---@type snacks.Config
  opts = {
    -- Keep input enabled (used by opencode.nvim)
    input = { enabled = true },

    -- Inline image rendering in markdown buffers
    image = {
      enabled = true,

      -- Force rendering: Kitty terminal supports the graphics protocol
      -- but $TERM may report as xterm-256color, causing detection to fail.
      force = true,

      -- Add SVG to supported formats (not in snacks defaults, requires magick)
      formats = {
        "png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "heic", "avif",
        "svg", "mp4", "mov", "avi", "mkv", "webm", "pdf", "icns",
      },

      doc = {
        enabled = true,
        -- Render images inline in the buffer (Kitty/Ghostty required)
        inline = true,
        -- Fallback: show images in floating windows on CursorMoved
        float = true,
        max_width = 80,
        max_height = 40,
        -- Only conceal math expressions, keep image paths visible for editing
        conceal = function(_lang, type)
          return type == "math"
        end,
      },

      -- Directories to search for images (relative to buffer or vault root)
      -- "attachments" matches the vault's image storage convention
      img_dirs = { "attachments", "assets", "images", "img", "media", "static", "public" },

      -- Resolve image paths for the Obsidian vault structure.
      -- Images are stored at <vault_root>/attachments/ but notes live in
      -- subdirectories, so relative paths need vault-root resolution.
      resolve = function(file, src)
        -- Skip Obsidian block refs (^blk-xxx) and heading refs (#Heading)
        -- that treesitter may misidentify as image sources.
        if src:match("^%^") or src:match("^#") or not src:match("%.%w+$") then
          return src -- return as-is; snacks will fail gracefully
        end

        -- Absolute paths and URLs pass through
        if src:match("^/") or src:match("^https?://") then
          return src
        end

        -- First try: resolve relative to the buffer's directory (default behavior)
        local buf_dir = vim.fs.dirname(file)
        local candidate = buf_dir .. "/" .. src
        if vim.uv.fs_stat(candidate) then
          return candidate
        end

        -- Second try: walk up to find the vault root (.obsidian dir) and
        -- resolve relative to it. This handles the common case where
        -- attachments/ lives at the vault root.
        local obsidian_dirs = vim.fs.find(".obsidian", {
          path = buf_dir,
          upward = true,
          type = "directory",
        })
        if obsidian_dirs[1] then
          local vault_root = vim.fs.dirname(obsidian_dirs[1])
          candidate = vault_root .. "/" .. src
          if vim.uv.fs_stat(candidate) then
            return candidate
          end

          -- Third try: search common image directories at vault root.
          -- Handles wikilink embeds like ![[image.png]] where the file
          -- lives in <vault_root>/attachments/image.png.
          for _, dir in ipairs({ "attachments", "assets", "images", "img", "media", "static", "public" }) do
            candidate = vault_root .. "/" .. dir .. "/" .. src
            if vim.uv.fs_stat(candidate) then
              return candidate
            end
          end
        end

        -- Fall through to snacks default resolution
        return nil
      end,

      math = {
        enabled = false,
      },

      convert = {
        notify = true,
      },
    },
  },
}
