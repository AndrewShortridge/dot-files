-- =============================================================================
-- Vault Template Registry
-- =============================================================================
-- Returns all templates in display order for the picker.
-- Each template exports: { name = "...", run = function(engine, pickers) ... end }
-- User templates from the vault's templates/ directory are appended after
-- built-in Lua templates.

local builtin = {
  -- Logs
  require("andrew.vault.templates.daily_log"),
  require("andrew.vault.templates.weekly_review"),
  require("andrew.vault.templates.monthly_review"),
  require("andrew.vault.templates.quarterly_review"),
  require("andrew.vault.templates.yearly_review"),

  -- Project management
  require("andrew.vault.templates.project_dashboard"),
  require("andrew.vault.templates.simulation"),
  require("andrew.vault.templates.analysis"),
  require("andrew.vault.templates.finding"),
  require("andrew.vault.templates.task"),
  require("andrew.vault.templates.meeting"),
  require("andrew.vault.templates.draft"),
  require("andrew.vault.templates.presentation"),
  require("andrew.vault.templates.changelog"),
  require("andrew.vault.templates.journal"),

  -- Knowledge base
  require("andrew.vault.templates.literature"),
  require("andrew.vault.templates.domain_moc"),
  require("andrew.vault.templates.concept"),
  require("andrew.vault.templates.methodology"),
  require("andrew.vault.templates.person"),

  -- Areas
  require("andrew.vault.templates.area_dashboard"),
  require("andrew.vault.templates.asset"),
  require("andrew.vault.templates.recurring_task"),
  require("andrew.vault.templates.financial_snapshot"),
}

local M = {}

--- Get the full template list: built-in Lua templates + user templates.
--- User templates are wrapped to conform to the { name, run } interface.
---@return table[]
function M.all()
  local cfg = require("andrew.vault.config")
  local list = {}

  -- Add built-in templates
  for _, t in ipairs(builtin) do
    list[#list + 1] = t
  end

  -- Add user templates if enabled
  if cfg.user_templates.enabled then
    local ut = require("andrew.vault.user_templates")
    local user_list = ut.list()

    if #user_list > 0 and cfg.user_templates.picker_separator then
      -- Add a separator entry (not runnable)
      list[#list + 1] = {
        name = cfg.user_templates.picker_separator,
        _separator = true,
        run = function() end,
      }
    end

    local prefix = cfg.user_templates.picker_prefix or ""
    for _, tpl in ipairs(user_list) do
      list[#list + 1] = {
        name = prefix .. tpl.name,
        desc = tpl.desc,
        _user_template = tpl,
        run = function()
          ut.run(tpl)
        end,
      }
    end
  end

  return list
end

return M
