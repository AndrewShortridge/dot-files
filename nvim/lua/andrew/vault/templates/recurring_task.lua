local M = {}
M.name = "Recurring Task"

local body_template = [[
# ${title}

> **Frequency:** `${frequency}` | **Next Due:** `${next_due}` | **Area:** ${area}

---

## What This Is

> [!abstract] What needs to happen, and why does it matter if it's skipped?
>

## Checklist

- [ ]
- [ ]
- [ ]

## Completion Log

| Date | Notes |
| ---- | ----- |
|      |       |
]]

function M.run(e, p)
  local title = e.input({ prompt = "Task name" })
  if not title then return end

  local area = e.input({ prompt = "Area (e.g., Career, Finance, Health-Wellness)" })
  if not area then return end

  local frequency = e.select(
    { "Weekly", "Biweekly", "Monthly", "Quarterly", "Semi-annually", "Annually", "As Needed" },
    { prompt = "Frequency" }
  )
  if not frequency then return end
  local freq_val = frequency:lower():gsub(" ", "-")

  local next_due = e.input({ prompt = "Next due date (YYYY-MM-DD)" })
  if not next_due then return end

  local date = e.today()
  local vars = { title = title, area = area, frequency = freq_val, next_due = next_due }

  local fm = "---\n"
    .. "type: recurring-task\n"
    .. "title: " .. title .. "\n"
    .. "area: " .. area .. "\n"
    .. "frequency: " .. freq_val .. "\n"
    .. "next_due: " .. next_due .. "\n"
    .. "created: " .. date .. "\n"
    .. "tags:\n"
    .. "  - recurring\n"
    .. "---\n"

  e.write_note("Areas/" .. area .. "/" .. title, fm .. "\n" .. e.render(body_template, vars))
end

return M
