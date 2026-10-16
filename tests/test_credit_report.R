# Purpose: verify report reconstruction, tamper checks and archive atomicity.
# The render adapter is synthetic; a real Quarto smoke render is separate.

local({
  for (module in c("issuer_registry.R", "issuer_prices.R",
                    "transition_matrix.R", "migration_valuation.R",
                    "credit_simulation.R", "credit_risk_measures.R",
                    "credit_stress.R", "credit_stress_pipeline.R",
                    "var_backtesting.R", "credit_report.R")) {
    source(file.path("R", module), local = TRUE)
  }
  fixture <- tempfile("report_tests_")
  dir.create(fixture)
  on.exit(unlink(fixture, recursive = TRUE), add = TRUE)
  checks <- 0L
  check <- function(condition, label) {
    if (!isTRUE(condition)) stop(paste("FAILED:", label), call. = FALSE)
    checks <<- checks + 1L
  }
  expect_error <- function(expression, pattern) {
    result <- tryCatch(force(expression), error = base::identity)
    check(inherits(result, "error"), paste("expected error:", pattern))
    check(grepl(pattern, conditionMessage(result), ignore.case = TRUE),
          paste("error message:", pattern))
  }
  date <- as.Date("2024-01-16")
  states <- credit_states()
  registry <- data.frame(
    issuer_id = c("ONE", "TWO"), ticker = c("ONE", "TWO"), currency = "USD",
    rating_notch = c("B", "BBB"), rating_bucket = c("B", "BBB"),
    notional_usd_million = 1, maturity_years = 5,
    rating_source_date = as.Date("2023-12-01")
  )
  curve <- data.frame(observation_date = date, maturity_years = c(1, 5),
                       zero_rate_continuous = 0)
  spreads <- data.frame(observation_date = date,
                         rating_bucket = head(states, -1L),
                         spread_decimal_proxy = 0)
  transition <- diag(8)
  dimnames(transition) <- list(states, states)
  transition["B", c("B", "D")] <- c(0.9, 0.1)
  transition["BBB", c("BBB", "D")] <- c(0.8, 0.2)
  correlation <- diag(2)
  dimnames(correlation) <- list(registry$issuer_id, registry$issuer_id)
  inputs <- list(registry = registry, curve = curve, spreads = spreads,
                   transition = transition,
                   assumptions = list(recovery_rate = 0.4, horizon_years = 1),
                   metadata = list(market_observation_date = date))
  settings <- data.frame(n_scenarios = 1000L, batch_size = 177L, seed = 12L,
                          mc_confidence_level = 0.95, min_nominal_tail = 40L)
  metadata <- data.frame(market_observation_date = date, analysis_cutoff = date,
                          n_scenarios = 1000L, batch_size = 177L, seed = 12L,
                          rng = "Mersenne-Twister/Inversion/Rejection")
  bundle <- list(valuation_inputs = inputs, correlation = correlation,
                   settings = settings, risk_levels = c(0.9, 0.95),
                   metadata = metadata)
  definitions <- read_credit_stress_scenarios(
    file.path("config", "stress_scenarios.csv"), 0.4
  )[c(1, 4), ]
  snapshot <- file.path(fixture, "stress")
  dir.create(snapshot)
  saveRDS(list(baseline_inputs = bundle, scenarios = definitions,
                metadata = metadata), file.path(snapshot, "stress_inputs.rds"))
  for (i in seq_len(nrow(definitions))) {
    case <- build_credit_stress_case(inputs, correlation, definitions[i, ])
    simulation <- simulate_credit_migrations(
      case$valuation, transition, case$correlation, 1000L, 177L, 12L,
      benchmark_values = case$benchmark_values
    )
    directory <- file.path(snapshot, definitions$scenario_id[i])
    dir.create(directory)
    saveRDS(list(case = case), file.path(directory, "case_inputs.rds"))
    saveRDS(list(losses = simulation$losses,
                  destinations = simulation$destinations),
             file.path(directory, "scenarios.rds"))
  }
  data <- load_credit_report_data(snapshot, 0.95)
  check(nrow(data$risk) == 4L && nrow(data$contributions) == 8L,
        "report tables reconstruct all saved cases and confidence levels")
  check(length(data$source_paths) == 5L,
        "the exact baseline and per-case RDS inputs are enumerated")
  check(abs(data$portfolios$exact_mean_loss_usd_million[1] - 0.18) < 1e-12,
        "the report's analytical mean retains the independent PD*LGD oracle")
  check(length(data$baseline_losses) == 1000L,
        "the simulated distribution remains available for the report figure")
  expect_error(load_credit_report_data(snapshot, 0.99), "primary confidence")
  saved_path <- file.path(snapshot, "spread_100", "scenarios.rds")
  original <- readRDS(saved_path)
  corrupted <- original
  corrupted$losses[1] <- corrupted$losses[1] + 1
  saveRDS(corrupted, saved_path)
  expect_error(load_credit_report_data(snapshot, 0.95), "do not match")
  saveRDS(original, saved_path)
  case_path <- file.path(snapshot, "spread_100", "case_inputs.rds")
  original_case <- readRDS(case_path)
  corrupted_case <- original_case
  corrupted_case$case$benchmark_values[1] <- 100
  saveRDS(corrupted_case, case_path)
  expect_error(load_credit_report_data(snapshot, 0.95), "differ")
  saveRDS(original_case, case_path)
  check(identical(report_number(c(1.25, NA_real_, Inf)), c("1,25", "—", "—")),
        "missing/undefined values are not displayed as numeric evidence")
  root <- file.path(fixture, "project")
  dir.create(file.path(root, "reports"), recursive = TRUE)
  dir.create(file.path(root, "R"))
  template_names <- c("credit_metrics.qmd", "report.css", "references.bib")
  file.copy(file.path("reports", template_names),
              file.path(root, "reports", template_names))
  file.copy(file.path("R", "credit_report.R"),
              file.path(root, "R", "credit_report.R"))
  calls <- 0L
  fake_renderer <- function(input, output_file, execute_params,
                              execute_dir, ...) {
    prepared <- readRDS(execute_params$report_data_file)
    check(length(prepared$baseline_losses) == 1000L,
          "the renderer receives reconstructed, frozen numeric inputs")
    check(file.exists(input) && file.exists(execute_params$helper_file),
          "the renderer uses archived templates and helper code")
    calls <<- calls + 1L
    writeLines(paste0("<!doctype html><html><body>",
                       "Synthetic render-adapter archive test. ",
                       "This file is not an empirical model validation. ",
                       "No market data were downloaded.</body></html>"),
                 file.path(execute_dir, output_file))
  }
  result <- render_credit_portfolio_report(snapshot, root, primary_level = 0.95,
                                             renderer = fake_renderer)
  check(calls == 1L && file.exists(result$html_file),
        "the completed render is saved in its own report snapshot")
  check(result$backtest_status == "not_performed",
        "missing empirical data cannot turn into a successful backtest")
  manifest <- readr::read_csv(file.path(result$snapshot_dir,
                                         "input_manifest.csv"),
                               show_col_types = FALSE)
  check(nrow(manifest) == 10L && all(nchar(manifest$md5) == 32L),
        "five numeric sources, four templates and prepared data are identified")
  backtest <- data.frame(
    portfolio_id = "SYNTHETIC", forecast_date = as.Date("2020-01-02"),
    horizon_end_date = as.Date("2021-01-02"),
    estimation_end_date = as.Date("2020-01-02"), estimation_window_size = 500,
    var_usd_million = 2, realized_loss_usd_million = 3, confidence_level = 0.95,
    forecast_benchmark = "no_migration_horizon",
    realized_benchmark = "no_migration_horizon",
    outcome_type = "synthetic_example",
    loss_source = "Synthetic input; not historical observations"
  )
  backtest_path <- file.path(fixture, "backtest.csv")
  readr::write_csv(backtest, backtest_path)
  with_backtest <- render_credit_portfolio_report(
    snapshot, root, backtest_path, 0.95, fake_renderer,
    backtest_evaluation_date = as.Date("2021-01-03")
  )
  check(with_backtest$backtest_status == "synthetic_example",
        "an optional example is labeled synthetic, never observed")
  check(file.exists(file.path(with_backtest$snapshot_dir,
                                "var_backtest_tests.csv")),
        "both exact-tail conventions and Kupiec results are retained")
  check(result$snapshot_dir != with_backtest$snapshot_dir &&
          file.exists(result$html_file), "later renders preserve older reports")
  raw_root <- file.path(root, "data", "raw", "reports")
  output_root <- file.path(root, "data", "processed", "reports")
  before_raw <- list.files(raw_root)
  before_output <- list.files(output_root)
  failing_renderer <- function(...) stop("render adapter failed")
  expect_error(render_credit_portfolio_report(
    snapshot, root, primary_level = 0.95, renderer = failing_renderer
  ), "render adapter failed")
  check(identical(list.files(raw_root), before_raw) &&
          identical(list.files(output_root), before_output),
        "failed renders remove partial archives while preserving complete ones")
  cat("Passed", checks, "credit-report checks.\n")
})
