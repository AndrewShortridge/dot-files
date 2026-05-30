--- Shared ANSI escape codes for fzf-lua display.
---
--- Single source of truth for ANSI formatting used across vault modules
--- (search_group, connections, tag_tree, search).

return {
  reset   = "\27[0m",
  bold    = "\27[1m",
  dim     = "\27[2m",
  blue    = "\27[34m",
  green   = "\27[32m",
  yellow  = "\27[33m",
  cyan    = "\27[36m",
  magenta = "\27[35m",
}
