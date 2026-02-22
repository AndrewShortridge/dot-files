-- =============================================================================
-- Snacks.nvim Configuration
-- =============================================================================
-- Utility collection by folke. Modules are opt-in.
-- Currently enabled: input (for opencode.nvim), image (inline rendering).

return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,

  ---@type snacks.Config
  opts = {
    -- Keep input enabled (used by opencode.nvim)
    input = { enabled = true },

    -- Inline image rendering in markdown buffers
    image = {
      enabled = true,

      -- Force rendering even if terminal detection fails.
      -- Set to true if your terminal supports Kitty graphics protocol
      -- but reports as xterm-256color (common with some terminal configs).
      force = false,

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
