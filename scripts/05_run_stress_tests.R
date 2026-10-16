# Purpose: compare one-year credit sensitivity cases on the same saved inputs.
# Input: the explicitly selected stage-04 snapshot and stress_scenarios.csv.
# Output: VaR/ES comparisons, paired MC errors, concentration and case archives.

library(readr)

if (!file.exists(file.path("config", "stress_scenarios.csv"))) {
  stop("Open the credit_metrics project root before running this script.",
       call. = FALSE)
}
for (module in c("issuer_registry.R", "issuer_prices.R", "transition_matrix.R",
                  "migration_valuation.R", "credit_simulation.R",
                  "credit_risk_measures.R", "credit_stress.R",
                  "credit_stress_pipeline.R")) {
  source(file.path("R", module))
}
if (!exists("credit_simulation_result", inherits = FALSE) ||
    !is.character(credit_simulation_result$snapshot_dir)) {
  stop(paste0("Run source('scripts/04_simulate_credit_risk.R') first, or call ",
                "run_credit_stress_tests() with an explicit snapshot."),
       call. = FALSE)
}
credit_stress_result <- run_credit_stress_tests(
  simulation_snapshot_dir = credit_simulation_result$snapshot_dir,
  project_dir = "."
)
print(credit_stress_result$risk[c(
  "scenario_id", "confidence_level", "var_usd_million", "es_usd_million"
)])
print(credit_stress_result$comparisons[c(
  "scenario_id", "confidence_level", "delta_es_usd_million",
  "delta_es_percent", "paired_es_mc_se_approx"
)])
print(credit_stress_result$portfolios[c(
  "scenario_id", "face_hhi", "largest_face_weight",
  "no_migration_shock_loss_usd_million", "exact_mean_loss_usd_million"
)])
cat("\nProcessed snapshot:", credit_stress_result$snapshot_dir, "\n")
