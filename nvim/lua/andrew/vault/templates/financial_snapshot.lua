local M = {}
M.name = "Financial Snapshot"

local body_template = [==[
# Financial Snapshot — ${period}

**Type:** `${snapshot_type}` Review
**Date:** ${date}

---

## Net Worth Summary

| Category | Amount | Change from Last Period | Notes |
| -------- | ------ | ----------------------- | ----- |
| Checking |  |  |  |
| Savings / Emergency |  |  |  |
| Retirement (401k/IRA) |  |  |  |
| Investments |  |  |  |
| **Total Assets** |  |  |  |
| Credit Cards |  |  |  |
| Student Loans |  |  |  |
| Other Debt |  |  |  |
| **Total Liabilities** |  |  |  |
| **Net Worth** |  |  |  |

## Income

| Source | Amount | Notes |
| ------ | ------ | ----- |
| Stipend / Salary |  |  |
| Side Income |  |  |
| Other |  |  |
| **Total** |  |  |

## Expenses Summary

| Category | Budgeted | Actual | Δ | Notes |
| -------- | -------- | ------ | - | ----- |
| Housing |  |  |  |  |
| Transportation |  |  |  |  |
| Food / Groceries |  |  |  |  |
| Insurance |  |  |  |  |
| Subscriptions |  |  |  |  |
| Health |  |  |  |  |
| Personal |  |  |  |  |
| Business (adaptABILITY) |  |  |  |  |
| **Total** |  |  |  |  |

## Key Events This Period

> [!info] Large purchases, windfalls, unexpected expenses, rate changes

-

## Goals Progress

| Goal | Target | Current | On Track? |
| ---- | ------ | ------- | --------- |
|      |        |         |           |

## Action Items

- [ ]

## Reflection

> [!tip] What went well? What needs to change next period?
>

## Previous Snapshot

- [[]]
]==]

function M.run(e, p)
  local period = e.input({ prompt = "Period (e.g., 2025-Q1, January 2025, 2025)" })
  if not period then return end

  local snapshot_type = e.select(
    { "Monthly", "Quarterly", "Annual" },
    { prompt = "Snapshot type" }
  )
  if not snapshot_type then return end
  local type_val = snapshot_type:lower()

  local date = e.today()
  local vars = { period = period, snapshot_type = type_val, date = date }

  local fm = "---\n"
    .. "type: financial-snapshot\n"
    .. "period: " .. period .. "\n"
    .. "snapshot_type: " .. type_val .. "\n"
    .. "date: " .. date .. "\n"
    .. 'area: "[[Finance]]"\n'
    .. "tags:\n"
    .. "  - finance\n"
    .. "  - snapshot\n"
    .. "---\n"

  e.write_note("Areas/Finance/Financial Snapshot - " .. period, fm .. "\n" .. e.render(body_template, vars))
end

return M
