# Purpose: check inclusive binomial tails, Kupiec limits and dated inputs.
# Fixtures are synthetic examples, never evidence of model predictive accuracy.

local({
  for (module in c("issuer_registry.R", "credit_simulation.R",
                    "credit_risk_measures.R", "var_backtesting.R")) {
    source(file.path("R", module), local = TRUE)
  }
  checks <- 0L
  check <- function(condition, label) {
    if (!isTRUE(condition)) stop(paste("FAILED:", label), call. = FALSE)
    checks <<- checks + 1L
  }
  close_to <- function(actual, expected, label) {
    check(isTRUE(all.equal(unname(actual), unname(expected),
                             tolerance = 1e-10)), label)
  }
  expect_error <- function(expression, pattern) {
    result <- tryCatch(force(expression), error = base::identity)
    check(inherits(result, "error"), paste("expected error:", pattern))
    check(grepl(pattern, conditionMessage(result), ignore.case = TRUE),
          paste("error message:", pattern))
  }
  regular <- test_var_exception_count(100, 5, 0.95)
  masses <- choose(100, 0:100) * 0.05 ^ (0:100) * 0.95 ^ (100:0)
  close_to(regular$lower_inclusive_probability, sum(masses[1:6]),
           "the lower tail includes the observed exception count")
  close_to(regular$upper_inclusive_probability, sum(masses[6:101]),
           "the upper tail includes the observed exception count")
  close_to(regular$kupiec_lr_uc, 0,
           "an empirical rate equal to the null has zero LR statistic")
  close_to(regular$kupiec_p_value, 1, "zero LR has p-value one")
  check(regular$central_binomial_not_rejected,
        "an expected count is not rejected by either exact tail")
  zero <- test_var_exception_count(100, 0, 0.95)
  close_to(zero$lower_inclusive_probability, 0.95 ^ 100,
           "zero exceptions use the exact boundary probability")
  close_to(zero$upper_inclusive_probability, 1,
           "every count is at least zero")
  close_to(zero$kupiec_lr_uc, -2 * 100 * log(0.95),
           "Kupiec handles zero exceptions without zero times log zero")
  check(zero$reject_too_few && !zero$reject_too_many,
        "an unusually low count is identified in the correct tail")
  all_fail <- test_var_exception_count(100, 100, 0.95)
  close_to(all_fail$kupiec_lr_uc, -2 * 100 * log(0.05),
           "Kupiec handles all exceptions at the other likelihood boundary")
  check(all_fail$reject_too_many && !all_fail$reject_too_few,
        "an unusually high count is identified in the correct tail")
  central <- test_var_exception_count(100, 5, 0.95, 0.025)
  close_to(central$central_size_upper_bound, 0.05,
           "2.5% in each tail gives at most 5% central size")
  for (tail_size in c(0.05, 0.025)) {
    reject <- vapply(0:100, function(m) {
      !test_var_exception_count(100, m, 0.95, tail_size)$
        central_binomial_not_rejected
    }, logical(1))
    check(sum(masses[reject]) <= 2 * tail_size + 1e-12,
          "enumeration verifies conservative central-test size")
  }
  expect_error(test_var_exception_count(0, 0, 0.95), "integer")
  expect_error(test_var_exception_count(10, 11, 0.95), "integer")
  expect_error(test_var_exception_count(10, 1, 1), "confidence")
  expect_error(test_var_exception_count(10, 1, 0.95, 0.5), "significance")
  fixture <- tempfile(fileext = ".csv")
  on.exit(unlink(fixture), add = TRUE)
  starts <- as.Date(c("2020-01-02", "2021-01-02", "2022-01-02"))
  rows <- data.frame(
    portfolio_id = "SYNTHETIC", forecast_date = starts,
    horizon_end_date = as.Date(c("2021-01-02", "2022-01-02", "2023-01-02")),
    estimation_end_date = starts, estimation_window_size = 500,
    var_usd_million = c(2, 2, -1), realized_loss_usd_million = c(2, 3, -2),
    confidence_level = 0.95, forecast_benchmark = "no_migration_horizon",
    realized_benchmark = "no_migration_horizon",
    outcome_type = "synthetic_example",
    loss_source = "Synthetic fixture, not a historical portfolio record"
  )
  read_rows <- function(x = rows, date = as.Date("2023-01-03")) {
    readr::write_csv(x, fixture)
    read_credit_var_backtest(fixture, date)
  }
  result <- read_rows()
  check(identical(result$observations$exception, c(FALSE, TRUE, FALSE)),
        "only strictly larger signed losses count as exceptions")
  check(all(result$summary$n_exceptions == 1) &&
          all(result$summary$n_equal_to_var == 1),
        "ties are audited without becoming exceptions")
  check(identical(result$summary$tail_significance, c(0.05, 0.025)),
        "the input adapter produces both requested testing conventions")
  check(result$outcome_type == "synthetic_example",
        "synthetic provenance is retained rather than relabeled empirical")
  bad <- rows
  bad$forecast_date[2] <- bad$forecast_date[2] - 1L
  bad$estimation_end_date[2] <- bad$forecast_date[2]
  expect_error(read_rows(bad), "overlap")
  bad <- rows
  bad$horizon_end_date <- bad$forecast_date + 1L
  expect_error(read_rows(bad), "annual horizons")
  bad <- rows
  bad$estimation_end_date[1] <- bad$forecast_date[1] + 1L
  expect_error(read_rows(bad), "future estimation")
  bad <- rows
  bad$realized_benchmark <- "current_value"
  expect_error(read_rows(bad), "matching")
  expect_error(read_rows(date = as.Date("2022-01-01")), "completed")
  bad <- rows
  bad$realized_loss_usd_million[1] <- NA_real_
  expect_error(read_rows(bad), "complete typed")
  bad <- rows
  bad$portfolio_id[2] <- "DIFFERENT"
  expect_error(read_rows(bad), "one portfolio")
  cat("Passed", checks, "VaR backtesting checks.\n")
})
