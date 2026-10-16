# Purpose: estimate one-year credit VaR/ES and issuer tail contributions.
# Inputs: the explicitly selected stage-03 snapshot and dated equity prices.
# Outputs: tail estimates, uncertainty, diagnostics and reproducible scenarios.

library(readr)
library(quantmod)

if (!file.exists(file.path("config", "simulation_settings.csv"))) {
  stop("Open the credit_metrics project root before running this script.",
       call. = FALSE)
}
for (module in c("issuer_registry.R", "issuer_prices.R", "transition_matrix.R",
                  "migration_valuation.R", "credit_simulation.R",
                  "credit_risk_measures.R", "credit_simulation_pipeline.R")) {
  source(file.path("R", module))
}
if (!exists("migration_valuation_result", inherits = FALSE) ||
    !is.character(migration_valuation_result$snapshot_dir)) {
  stop(paste0(
    "Run source('scripts/03_value_migrations.R') first, or call ",
    "run_credit_risk_simulation() with an explicit snapshot directory."
  ), call. = FALSE)
}
credit_simulation_result <- run_credit_risk_simulation(
  valuation_snapshot_dir = migration_valuation_result$snapshot_dir,
  project_dir = "."
)
print(credit_simulation_result$risk[c(
  "confidence_level", "var_usd_million", "es_usd_million",
  "var_mc_ci_lower", "var_mc_ci_upper", "es_mc_se_approx"
)])
print(credit_simulation_result$mean_check)
print(credit_simulation_result$contributions[c(
  "confidence_level", "issuer_id", "es_contribution_usd_million", "es_share"
)])
cat("\nProcessed snapshot:", credit_simulation_result$snapshot_dir, "\n")
