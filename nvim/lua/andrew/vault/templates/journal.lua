local M = {}
M.name = "Journal Entry"

local body_template = [==[
# ${title}

**Project:** [[Projects/${project}/Dashboard|${project}]]
**Date:** ${date}

---

## Observations

> [!abstract] What did I notice or learn today?
>

## What Worked

> [!success] What went well? What should I keep doing?
>

## Challenges

> [!warning] What was difficult? What slowed me down?
>

## Open Questions

> [!question] What remains unresolved? What should I investigate next?

- [ ]

## Notes
]==]

function M.run(e, p)
  local title = e.input({ prompt = "Journal entry title (e.g., Shock Reflection at Grain Boundary)" })
  if not title then return end

  local project = p.project(e)
  if not project then return end

  local date = e.today()
  local vars = { title = title, project = project, date = date }

  local fm = "---\n"
    .. "type: journal-entry\n"
    .. "title: " .. title .. "\n"
    .. "parent-project: '[[Projects/" .. project .. "/Dashboard|" .. project .. "]]'\n"
    .. "date_created: " .. date .. "\n"
    .. "tags:\n"
    .. "  - journal-entry\n"
    .. "---\n"

  e.write_note("Projects/" .. project .. "/Journal/" .. title, fm .. "\n" .. e.render(body_template, vars))
end

return M
