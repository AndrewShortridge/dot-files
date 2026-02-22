-- =============================================================================
-- Vault Template Registry
-- =============================================================================
-- Returns all templates in display order for the picker.
-- Each template exports: { name = "...", run = function(engine, pickers) ... end }

return {
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
