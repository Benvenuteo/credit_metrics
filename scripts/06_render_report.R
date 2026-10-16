# Purpose: render a frozen-input report with explicit validation status.
# Input: a stage-05 snapshot; optional dated backtest data are separate.
# Output: one self-contained HTML file and an immutable input manifest.

library(readr)
library(knitr)
library(rmarkdown)
library(quarto)

for (module in c("issuer_registry.R", "issuer_prices.R", "transition_matrix.R",
                  "migration_valuation.R", "credit_simulation.R",
                  "credit_risk_measures.R", "credit_stress.R",
                  "credit_stress_pipeline.R", "var_backtesting.R",
                  "credit_report.R")) {
  source(file.path("R", module))
}
if (!exists("credit_stress_result", inherits = FALSE) ||
    !is.character(credit_stress_result$snapshot_dir)) {
  stop("Run stage 05 first or call render_credit_portfolio_report() directly.",
       call. = FALSE)
}
credit_report_result <- render_credit_portfolio_report(
  stress_snapshot_dir = credit_stress_result$snapshot_dir, project_dir = "."
)
cat("\nHTML report:", credit_report_result$html_file, "\n")
cat("Empirical backtest status:", credit_report_result$backtest_status, "\n")
