local M = {}
M.name = "Area Dashboard"

function M.run(e, p)
  local title = e.input({ prompt = "Area name (e.g., Finance, Health & Fitness, Vehicles, Home)" })
  if not title then return end

  local category = e.select(
    { "Personal", "Professional", "Shared" },
    { prompt = "Category" }
  )
  if not category then return end
  local cat_val = category:lower()

  local frequency = e.select(
    { "Weekly", "Biweekly", "Monthly", "Quarterly", "Annually" },
    { prompt = "Review frequency" }
  )
  if not frequency then return end
  local freq_val = frequency:lower()

  local date = e.today()

  local fm = "---\n"
    .. "type: area-dashboard\n"
    .. "area: " .. title .. "\n"
    .. "category: " .. cat_val .. "\n"
    .. "review_frequency: " .. freq_val .. "\n"
    .. "created: " .. date .. "\n"
    .. "last_reviewed: " .. date .. "\n"
    .. "tags:\n"
    .. "  - area\n"
    .. "---\n"

  -- The dataview query uses tp.file.folder(true) in Obsidian.
  -- Since we know the folder, we hardcode it.
  local folder_path = "Areas/" .. title

  local body = "\n# " .. title .. "\n\n"
    .. "**Category:** `" .. cat_val .. "`\n"
    .. "**Review Frequency:** `" .. freq_val .. "`\n"
    .. "**Last Reviewed:** " .. date .. "\n\n"
    .. "---\n\n"
    .. "## Purpose\n\n"
    .. "> [!abstract] What standard am I maintaining? What does \"healthy\" look like for this area?\n>\n\n"
    .. "## Current Status\n\n"
    .. "> [!target] How is this area doing right now? What needs attention?\n>\n\n"
    .. "---\n\n"
    .. "## Active Projects\n\n"
    .. "```dataview\n"
    .. "LIST\n"
    .. "FROM \"Projects\"\n"
    .. "WHERE type = \"project-dashboard\" AND status != \"Archived\" AND contains(file.outlinks, this.file.link)\n"
    .. "```\n\n"
    .. "> Manual links:\n"
    .. "> - [[]]\n\n"
    .. "## Recurring Tasks & Maintenance\n\n"
    .. "```dataview\n"
    .. "TABLE WITHOUT ID\n"
    .. "  link(file.link, file.name) AS \"Task\",\n"
    .. "  frequency AS \"Frequency\",\n"
    .. "  next_due AS \"Next Due\",\n"
    .. "  status AS \"Status\"\n"
    .. "FROM \"" .. folder_path .. "\"\n"
    .. "WHERE type = \"recurring-task\"\n"
    .. "SORT next_due ASC\n"
    .. "```\n\n"
    .. "> Manual links:\n"
    .. "> - [[]]\n\n"
    .. "## Key Documents & References\n\n"
    .. "> [!info] Important files, account numbers, contacts, reference info\n"
    .. "> Store sensitive details in a password manager \xE2\x80\x94 link to the entry or note the account name, not the credentials.\n\n"
    .. "-\n\n"
    .. "## Key People / Contacts\n\n"
    .. "- [[]]\n\n"
    .. "## Upcoming Deadlines\n\n"
    .. "| Date | Item | Notes |\n"
    .. "| ---- | ---- | ----- |\n"
    .. "|      |      |       |\n\n"
    .. "## Decision Log\n\n"
    .. "> [!info] Significant decisions and their rationale\n\n"
    .. "| Date | Decision | Rationale | Outcome |\n"
    .. "| ---- | -------- | --------- | ------- |\n"
    .. "|      |          |           |         |\n\n"
    .. "## Review Checklist\n\n"
    .. "> [!check] Run through this list at the review frequency above\n\n"
    .. "- [ ] Is the current status accurate?\n"
    .. "- [ ] Are all recurring tasks up to date?\n"
    .. "- [ ] Any upcoming deadlines I'm not tracking?\n"
    .. "- [ ] Any active projects that should be created?\n"
    .. "- [ ] Update `last_reviewed` in frontmatter\n\n"
    .. "## Notes\n"

  e.write_note(folder_path .. "/Dashboard", fm .. body)
end

return M
