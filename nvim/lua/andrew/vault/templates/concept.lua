local config = require("andrew.vault.config")

local M = {}
M.name = "Concept Note"

local body_template = [==[
# {{title}}

**Domain:** [[{{domain}}]]
**Maturity:** `{{maturity}}`

---
## Introduction



## Connections

> [!link] How does this relate to other concepts in your vault?

### Related Concepts

- [[]]

### Related Papers

- [[]]

## Open Questions

- [ ]

## Atomic Literature Notes
]==]

function M.run(e, p)
  local title = e.input({ prompt = "Concept title (e.g., Groove Angle Effects on Ejection)" })
  if not title then return end

  local domain = e.input({ prompt = "Parent domain (e.g., Shock Physics)" })
  if not domain then return end

  local maturity = e.select(
    config.maturity_values,
    { prompt = "Maturity" }
  )
  if not maturity then return end

  local date = e.today()
  local vars = { title = title, domain = domain, maturity = maturity, date = date }

  local fm = "---\n"
    .. "type: concept\n"
    .. "title: " .. title .. "\n"
    .. 'domain: "[[' .. domain .. ']]"\n'
    .. "maturity: " .. maturity .. "\n"
    .. "created: " .. date .. "\n"
    .. "last_updated: " .. date .. "\n"
    .. "tags:\n"
    .. "  - concept\n"
    .. "---\n"

  e.write_note(config.dirs.domains .. "/" .. domain .. "/" .. title, fm .. "\n" .. e.render(body_template, vars))
end

return M
