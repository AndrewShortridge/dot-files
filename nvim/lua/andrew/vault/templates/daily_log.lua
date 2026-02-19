local M = {}
M.name = "Daily Log"

function M.run(e, p)
  local date = e.today()
  local yesterday = e.date_offset(-1)
  local tomorrow = e.date_offset(1)
  local weekday_long = e.today_weekday()

  local content = "---\n"
    .. "type: log\n"
    .. "date: " .. date .. "\n"
    .. "tags:\n"
    .. "  - log\n"
    .. "  - daily\n"
    .. "---\n\n"
    .. "<< [[" .. yesterday .. "]] | [[" .. tomorrow .. "]] >>\n\n"
    .. "# " .. weekday_long .. "\n\n"
    .. "---\n\n"
    .. "## Morning Plan\n\n"
    .. "### Today's Focus\n\n"
    .. "> [!target] The single biggest task to complete today. Link to its parent project.\n\n"
    .. "- [ ]\n\n"
    .. "### Other Priorities\n\n"
    .. "- [ ]\n"
    .. "- [ ]\n"
    .. "- [ ]\n\n"
    .. "### Tasks Due Today\n\n"
    .. "```dataview\n"
    .. "TASK FROM \"Projects\"\n"
    .. "WHERE !completed AND due = date(\"" .. date .. "\")\n"
    .. "SORT priority ASC\n"
    .. "```\n\n"
    .. "---\n\n"
    .. "## Work Log\n\n"
    .. "> Add an entry for each work block. Include the time range, project, and what you did.\n\n"
    .. "- **__:__ - __:__** |\n"
    .. "- **__:__ - __:__** |\n"
    .. "- **__:__ - __:__** |\n\n"
    .. "---\n\n"
    .. "## Scratchpad\n\n"
    .. "> Fleeting thoughts, ideas, links, questions \xE2\x80\x94 anything that comes to mind. Process into proper notes later.\n\n"
    .. "-\n\n"
    .. "---\n\n"
    .. "## End of Day\n\n"
    .. "### Completed Today\n\n"
    .. "- [x]\n\n"
    .. "### Blockers & Open Questions\n\n"
    .. "> [!warning] What's preventing progress? What needs to be resolved?\n\n"
    .. "-\n\n"
    .. "### Reflection\n\n"
    .. "> One thing I learned, one decision I made, or one thing that clicked.\n\n"
    .. "-\n\n"
    .. "### Tomorrow's Priorities\n\n"
    .. "- [ ]\n"
    .. "- [ ]\n"
    .. "- [ ]\n"

  e.write_note("Log/" .. date, content)
end

return M
