local M = {}
M.name = "Asset Note"

local body_template = [==[
# ${name}

**Type:** `${asset_type}`
**Area:** [[${area}]]
**Acquired:** ${acquired}
**Current Value:** ${value}

---

## Key Details

> [!info] Core reference information for this asset
> ⚠️ Do NOT store sensitive credentials here. Use a password manager. Note the account name only.

| Field | Value |
| ----- | ----- |
| Make / Type |  |
| Model / Description |  |
| Year |  |
| Serial # / VIN / Account # |  |
| Location / Institution |  |
| Contact / Agent |  |
| Phone / Website |  |

## Associated Recurring Tasks

```dataview
LIST
FROM "Areas"
WHERE type = "recurring-task" AND contains(file.outlinks, this.file.link)
```

> Manual links:
> - [[]]

## Documents

> [!note] Where are the important documents stored? (physical location or digital path)

| Document | Location | Expiration |
| -------- | -------- | ---------- |
| Title / Deed |  |  |
| Registration |  |  |
| Warranty |  |  |
| Insurance Policy |  |  |
| Manual |  |  |

## Service / Transaction History

| Date | Description | Cost | Provider | Notes |
| ---- | ----------- | ---- | -------- | ----- |
|      |             |      |          |       |

## Upcoming

| Date | Action Needed | Notes |
| ---- | ------------- | ----- |
|      |               |       |

## Notes
]==]

function M.run(e, p)
  local name = e.input({ prompt = "Asset name (e.g., 2019 Honda Civic, 45 Oak Street, Fidelity 401k)" })
  if not name then return end

  local asset_type = e.select(
    { "Vehicle", "Property", "Financial Account", "Insurance Policy", "Equipment", "Other" },
    { prompt = "Asset type" }
  )
  if not asset_type then return end
  local type_map = { Vehicle = "vehicle", Property = "property", ["Financial Account"] = "financial-account", ["Insurance Policy"] = "insurance", Equipment = "equipment", Other = "other" }
  local type_val = type_map[asset_type] or asset_type:lower()

  local area = e.input({ prompt = "Parent area (e.g., Vehicles, Home, Finance)" })
  if not area then return end

  local acquired = e.input({ prompt = "Date acquired (YYYY-MM-DD or approximate)", default = "" })
  local value = e.input({ prompt = "Current/purchase value ($)", default = "" })

  local date = e.today()
  local vars = { name = name, asset_type = type_val, area = area, acquired = acquired or "", value = value or "" }

  local fm = "---\n"
    .. "type: asset\n"
    .. "name: " .. name .. "\n"
    .. "asset_type: " .. type_val .. "\n"
    .. "area: '[[" .. area .. "]]'\n"
    .. "acquired: " .. (acquired or "") .. "\n"
    .. "value: " .. (value or "") .. "\n"
    .. "created: " .. date .. "\n"
    .. "tags:\n"
    .. "  - asset\n"
    .. "---\n"

  e.write_note("Areas/" .. area .. "/" .. name, fm .. "\n" .. e.render(body_template, vars))
end

return M
