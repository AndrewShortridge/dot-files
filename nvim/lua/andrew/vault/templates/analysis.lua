local M = {}
M.name = "Analysis Note"

local body_template = [==[
# ${title}

**Status:** `${status}`
**Project:** [[Projects/${project}/Dashboard|${project}]]
**Created:** ${date}
**Last Updated:** ${date}

---

## Objective

> [!abstract] What question does this analysis answer?
>

## Runs Compared

| Simulation | Key Variable | Relevant Output |
| ---------- | ------------ | --------------- |
| [[]]       |              |                 |
| [[]]       |              |                 |
| [[]]       |              |                 |

## Methods / Approach

> [!info] How was this analysis performed?

- **Tools used:**
- **Scripts:** [[]]
- **Post-processing steps:**

1.

## Results

### Findings



### Key Data

| Condition | Metric 1 | Metric 2 | Notes |
| --------- | -------- | -------- | ----- |
|           |          |          |       |
|           |          |          |       |

### Figures

> Embed or link key plots
> `![[]]`

## Interpretation

> [!tip] What do these results mean physically?
>

## Comparison to Literature

| Source | Their Result | My Result | Agreement? |
| ------ | ------------ | --------- | ---------- |
| [[]]   |              |           |            |

## Implications for Paper

> [!important] How does this shape the narrative?

- **Section affected:**
- **Figure(s) generated:**
- **Key claim supported:**

## Open Questions

- [ ]

## Follow-Up Work Needed

- [ ]

## Feeds Into

- **Draft:** [[]]
- **Changelog:** [[]]
- **Presentation:** [[]]

## Notes
]==]

function M.run(e, p)
  local title = e.input({ prompt = "Analysis title (e.g., Ejection Velocity vs Groove Angle)" })
  if not title then return end

  local status = e.select(
    { "In Progress", "Complete", "Needs Revision", "Superseded" },
    { prompt = "Analysis status" }
  )
  if not status then return end

  local project = p.project(e)
  if not project then return end

  local date = e.today()
  local vars = { title = title, status = status, project = project, date = date }

  local fm = "---\n"
    .. "type: analysis\n"
    .. "title: " .. title .. "\n"
    .. "status: " .. status .. "\n"
    .. "parent-project: '[[Projects/" .. project .. "/Dashboard|" .. project .. "]]'\n"
    .. "date_created: " .. date .. "\n"
    .. "last_updated: " .. date .. "\n"
    .. "tags:\n"
    .. "  - analysis\n"
    .. "---\n"

  e.write_note("Projects/" .. project .. "/Analysis/" .. title, fm .. "\n" .. e.render(body_template, vars))
end

return M
