local M = {}
M.name = "Task Note"

function M.run(e, p)
  local title = e.input({ prompt = "Task title" })
  if not title then return end

  local status = e.select(
    { "Not Started", "In Progress", "Blocked", "Complete", "Cancelled" },
    { prompt = "Task status" }
  )
  if not status then return end

  local priority = e.input({ prompt = "Priority (1=today, 2=2-4d, 3=7d, 4=30d, 5=no deadline)", default = "3" })
  if not priority then return end

  local due = e.input({ prompt = "Due date (YYYY-MM-DD or leave blank)", default = "" })

  local project = p.project(e)
  if not project then return end

  local blocked_by = e.input({ prompt = "Blocked by (link to note or leave blank)", default = "" })

  local date = e.today()

  local fm = "---\n"
    .. "type: task\n"
    .. "title: " .. title .. "\n"
    .. "status: " .. status .. "\n"
    .. "priority: " .. priority .. "\n"
    .. "due: " .. (due or "") .. "\n"
    .. "parent-project: '[[Projects/" .. project .. "/Dashboard|" .. project .. "]]'\n"
    .. "blocked_by: " .. (blocked_by or "") .. "\n"
    .. "date_created: " .. date .. "\n"
    .. "date_completed:\n"
    .. "tags:\n"
    .. "  - task\n"
    .. "---\n"

  local body = "\n# " .. title .. "\n\n"
    .. "**Status:** `" .. status .. "`\n"
    .. "**Priority:** `" .. priority .. "`\n"
    .. "**Project:** [[Projects/" .. project .. "/Dashboard|" .. project .. "]]\n"
    .. "**Due:** " .. (due or "") .. "\n"
    .. "**Created:** " .. date .. "\n\n"
    .. "---\n\n"
    .. "## Objective\n\n"
    .. "> [!abstract] What does \"done\" look like for this task?\n>\n\n"
    .. "## Subtasks\n\n"
    .. "- [ ] **[due:: ]** : [priority:: ] :\n\n"
    .. "## Context & Dependencies\n\n"
    .. "> [!info] What prerequisite work, resources, or people does this depend on?\n\n"
    .. "- **Blocked by:** " .. (blocked_by or "") .. "\n"
    .. "- **Related notes:** [[]]\n\n"
    .. "## Approach\n\n"
    .. "> [!tip] How will you tackle this? Key steps or strategy.\n\n"
    .. "1.\n\n"
    .. "## Notes\n\n"
    .. "## Log\n\n"
    .. "### " .. date .. "\n"
    .. "- Task created\n"

  e.write_note("Projects/" .. project .. "/Tasks/" .. title, fm .. body)
end

return M
