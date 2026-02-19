local M = {}
M.name = "Finding Note"

local body_template = [==[
# ${title}

**Status:** `${status}`
**Project:** [[${project}/Dashboard]]
**Created:** ${date}

---

## Summary

> [!abstract] What was discovered?
>

## Context

> [!info] What were you doing when this came up?

- **Task / analysis:**
- **Simulation run:** [[]]
- **Relevant data:**

## Details

### Observation



### Root Cause



### Evidence

| Source | What it shows |
| ------ | ------------- |
| [[]]   |               |

## Impact

> [!warning] What does this affect?

- **Affected simulations:**
- **Affected analyses:**
- **Effect on conclusions:**

## Resolution

> [!success] What was done to address this?

1.

## Action Items

- [ ]

## Lessons Learned

> [!tip] What should be done differently next time?

-

## Notes
]==]

function M.run(e, p)
  local title = e.input({ prompt = "Finding title (e.g., 500K EMC Density Mismatch Root Cause)" })
  if not title then return end

  local status = e.select(
    { "In Progress", "Resolved", "Wont Fix", "Needs Investigation" },
    { prompt = "Finding status" }
  )
  if not status then return end

  local project = p.project(e)
  if not project then return end

  local date = e.today()
  local vars = { title = title, status = status, project = project, date = date }

  local fm = "---\n"
    .. "type: finding\n"
    .. "title: " .. title .. "\n"
    .. "status: " .. status .. "\n"
    .. "parent-project: '[[" .. project .. "/Dashboard]]'\n"
    .. "date_created: " .. date .. "\n"
    .. "last_updated: " .. date .. "\n"
    .. "tags:\n"
    .. "  - finding\n"
    .. "---\n"

  e.write_note("Projects/" .. project .. "/Findings/" .. title, fm .. "\n" .. e.render(body_template, vars))
end

return M
