local base = require("andrew.vault.completion_base")
local fm_parser = require("andrew.vault.frontmatter_parser")

return base.create_source({
  name = "frontmatter",
  build = base.build_kv_fields("frontmatter", ": "),

  get_completions = base.kv_get_completions(function(before, ctx, bufnr)
    local cursor_row = ctx.cursor[1]

    -- Only complete inside frontmatter
    if not fm_parser.cursor_in_frontmatter(bufnr, cursor_row - 1) then
      return nil
    end

    -- Value: "key: partial"
    local prop_key = before:match("^([%w_%-]+):%s+")
    if prop_key then return prop_key end

    -- List value: "  - partial" under a YAML list key
    if before:match("^%s+-%s+") then
      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, cursor_row - 1, false)
      for i = #buf_lines, 1, -1 do
        local key = buf_lines[i]:match("^([%w_%-]+):")
        if key then return key end
      end
    end

    -- Name completion fallback
    return false
  end),
})
