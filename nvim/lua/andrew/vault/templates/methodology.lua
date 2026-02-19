local M = {}
M.name = "Methodology Note"

local body_template = [==[
# ${title}

**Status:** `${status}`
**Created:** ${date}
**Last Updated:** ${date}

---

## Purpose

> [!abstract] What problem does this method solve?
>

## Approach

### Description



### Implementation Details

- **Software / Tool:**
- **Key commands / functions:**
- **Language / Scripts:** [[]]

### Algorithm / Procedure

1.

### Code Snippet

```
# Key implementation detail
```

## Parameters & Configuration

| Parameter | Value | Justification |
| --------- | ----- | ------------- |
|           |       |               |
|           |       |               |

## Validation

> [!check] How was this method validated?

### Validated Against

- [[]]

### Validation Results

-

## Known Limitations

> [!warning]

1.

## Comparison to Alternatives

| Method | Pros | Cons | When to Use |
| ------ | ---- | ---- | ----------- |
| **This method** |      |      |             |
| [[]]   |      |      |             |
| [[]]   |      |      |             |

## Used In

> [!info] Simulations and papers that use this method

### Simulations

- [[]]

### Papers / Drafts

- [[]]

## References

- [[]]

## Changelog

| Date | Change | Reason |
| ---- | ------ | ------ |
| ${date} | Created | |
|      |        |        |

## Notes
]==]

function M.run(e, p)
  local title = e.input({ prompt = "Method name (e.g., Voronoi Density Calculation)" })
  if not title then return end

  local status = e.select(
    { "Experimental", "Validated", "Deprecated", "Under Review" },
    { prompt = "Status" }
  )
  if not status then return end

  local date = e.today()
  local vars = { title = title, status = status, date = date }

  local fm = "---\n"
    .. "type: methodology\n"
    .. "method_name: " .. title .. "\n"
    .. "status: " .. status .. "\n"
    .. "created: " .. date .. "\n"
    .. "last_updated: " .. date .. "\n"
    .. "tags:\n"
    .. "  - methodology\n"
    .. "---\n"

  e.write_note("Methods/" .. title, fm .. "\n" .. e.render(body_template, vars))
end

return M
