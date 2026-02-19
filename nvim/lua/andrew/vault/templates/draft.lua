local M = {}
M.name = "Draft Note"

local body_template = [==[
# ${version}

**Project:** [[${project}/Dashboard]]
**Status:** `${status}`
**Date:** ${date}
**File:** `${file_location}`

---

## What Changed from Previous Version

> See [[]]  *(link to changelog)*

## Structure

| Section | Status | Notes |
| ------- | ------ | ----- |
| Abstract |  |  |
| Introduction |  |  |
| Methodology |  |  |
| Results |  |  |
| Discussion |  |  |
| Conclusion |  |  |

## Figures

| Figure | Source | Description | Status |
| ------ | ------ | ----------- | ------ |
| Fig. 1 | [[]] |  | Draft / Final |
| Fig. 2 | [[]] |  | Draft / Final |

## Data Dependencies

> [!info] Which simulation runs and analyses feed this draft?

- [[]]

## Feedback Received

> [!people] Reviewer / advisor comments

- [ ]
- [ ]

## Submission Notes

> [!note] Journal formatting requirements, cover letter status, supplementary materials

-

## Notes
]==]

function M.run(e, p)
  local version = e.input({ prompt = "Version label (e.g., Draft v1, Draft v2 - Revised Results)" })
  if not version then return end

  local status = e.select(
    { "In Progress", "With Advisor", "Under Review", "Accepted", "Submitted", "Superseded" },
    { prompt = "Draft status" }
  )
  if not status then return end

  local file_location = e.input({ prompt = "Path to actual manuscript file (e.g., ~/papers/ejection/draft_v2.tex)", default = "" })

  local project = p.project(e)
  if not project then return end

  local date = e.today()
  local vars = { version = version, status = status, file_location = file_location or "", project = project, date = date }

  local fm = "---\n"
    .. "type: draft\n"
    .. "version: " .. version .. "\n"
    .. "status: " .. status .. "\n"
    .. "file_location: " .. (file_location or "") .. "\n"
    .. "project: '[[" .. project .. "/Dashboard]]'\n"
    .. "date: " .. date .. "\n"
    .. "tags:\n"
    .. "  - draft\n"
    .. "---\n"

  e.write_note("Projects/" .. project .. "/Drafts/" .. version, fm .. "\n" .. e.render(body_template, vars))
end

return M
