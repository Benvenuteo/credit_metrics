# Purpose: obtain current dated inputs and value one-year credit migrations.
# Inputs: config/*.csv and fresh Fed, S&P and FRED downloads.
# Outputs: conditional values, exact expected values and sensitivity snapshots.

library(httr2)
library(readr)
library(jsonlite)
library(xml2)

if (!file.exists(file.path("config", "valuation_assumptions.csv"))) {
  stop("Open the credit_metrics project root before running this script.",
       call. = FALSE)
}
for (module in c("issuer_registry.R", "fed_yield_curve.R",
                  "transition_matrix.R", "rating_spreads.R",
                  "migration_valuation.R", "migration_pipeline.R")) {
  source(file.path("R", module))
}

migration_valuation_result <- run_migration_valuation(project_dir = ".")
print(migration_valuation_result$issuer_summary[c(
  "issuer_id", "initial_rating", "initial_value_usd_million",
  "no_migration_value_usd_million", "expected_value_usd_million",
  "expected_credit_loss_usd_million", "model_default_probability"
)])
print(migration_valuation_result$portfolio_summary)
print(migration_valuation_result$sensitivity[c(
  "nr_policy", "recovery_rate", "is_baseline",
  "expected_value_usd_million", "expected_credit_loss_usd_million"
)])
cat("\nProcessed snapshot:", migration_valuation_result$snapshot_dir, "\n")
