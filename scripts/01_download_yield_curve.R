# Purpose: obtain the latest available USD base curve for CreditMetrics.
# Run from the project root: source("scripts/01_download_yield_curve.R").
# Outputs: raw CSV, processed curve.csv, and provenance metadata.csv.

library(httr2)
library(readr)

module_path <- file.path("R", "fed_yield_curve.R")
if (!file.exists(module_path)) {
  stop("Open the credit_metrics project root before running this script.",
       call. = FALSE)
}
source(module_path)

# Two calendar weeks allow for the provider's usual weekly publication lag.
yield_curve_result <- download_fed_yield_curve(
  project_dir = ".", as_of_date = Sys.Date(), max_age_days = 14L
)
print(yield_curve_result$curve)
cat("\nSource observation:",
    as.character(yield_curve_result$metadata$observation_date), "\n")
cat("Processed snapshot:", yield_curve_result$snapshot_dir, "\n")
