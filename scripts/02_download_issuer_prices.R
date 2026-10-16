# Purpose: collect issuer prices and estimate a reproducible correlation proxy.
# Run from the project root: source("scripts/02_download_issuer_prices.R").

library(readr)
library(quantmod)

if (!file.exists(file.path("config", "issuers.csv"))) {
  stop("Open the credit_metrics project root before running this script.",
       call. = FALSE)
}
source(file.path("R", "issuer_registry.R"))
source(file.path("R", "issuer_prices.R"))

issuer_prices_result <- download_issuer_prices(project_dir = ".")
print(issuer_prices_result$registry[c("issuer_name", "ticker", "rating_notch",
                                    "rating_bucket", "notional_usd_million")])
print(issuer_prices_result$quality)
print(round(issuer_prices_result$correlation, 3))
cat("\nProcessed snapshot:", issuer_prices_result$snapshot_dir, "\n")
cat("Source export:", issuer_prices_result$raw_path, "\n")
