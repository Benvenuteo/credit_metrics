# Purpose: verify fixed benchmarks, horizon shocks and paired stress archives.
# All source data are synthetic; these checks never download market data.
# Run from the project root: source("tests/test_credit_stress.R").

local({
  for (module in c("issuer_registry.R", "issuer_prices.R",
                    "transition_matrix.R", "migration_valuation.R",
                    "credit_simulation.R", "credit_risk_measures.R",
                    "credit_stress.R", "credit_stress_pipeline.R")) {
    source(file.path("R", module), local = TRUE)
  }
  fixture_dir <- tempfile("stress_tests_")
  dir.create(fixture_dir)
  on.exit(unlink(fixture_dir, recursive = TRUE), add = TRUE)
  checks <- 0L
  check <- function(condition, label) {
    if (!isTRUE(condition)) stop(paste("FAILED:", label), call. = FALSE)
    checks <<- checks + 1L
  }
  close_to <- function(actual, expected, label, tolerance = 1e-10) {
    check(isTRUE(all.equal(unname(actual), unname(expected),
                             tolerance = tolerance)), label)
  }
  expect_error <- function(expression, pattern) {
    result <- tryCatch(force(expression), error = base::identity)
    check(inherits(result, "error"), paste("expected error:", pattern))
    check(grepl(pattern, conditionMessage(result), ignore.case = TRUE),
          paste("error message:", pattern))
  }
  states <- credit_states()
  date <- as.Date("2024-01-16")
  registry <- data.frame(
    issuer_id = c("ONE", "TWO"), ticker = c("ONE", "TWO"), currency = "USD",
    rating_notch = c("B", "BBB"), rating_bucket = c("B", "BBB"),
    notional_usd_million = 1, maturity_years = 5
  )
  curve <- data.frame(observation_date = date, maturity_years = c(1, 5),
                       zero_rate_continuous = 0)
  spreads <- data.frame(observation_date = date,
                         rating_bucket = head(states, -1L),
                         spread_decimal_proxy = 0)
  transition <- diag(8)
  dimnames(transition) <- list(states, states)
  correlation <- diag(2)
  dimnames(correlation) <- list(registry$issuer_id, registry$issuer_id)
  value <- function(p = transition, shock = 0, recovery = 0.4) {
    value_migration_states(registry, curve, spreads, p, recovery,
                            horizon_spread_shock_bps = shock)
  }
  baseline_value <- value()
  shocked_value <- value(shock = 100)
  factor <- exp(-0.01 * 4)
  close_to(shocked_value$issuer_summary$initial_value_usd_million, c(1, 1),
           "a horizon spread shock leaves inception prices unchanged")
  close_to(shocked_value$state_values[, head(states, -1L)],
           baseline_value$state_values[, head(states, -1L)] * factor,
           "100 bps discount four remaining years in every surviving state")
  close_to(shocked_value$state_values[, "D"], rep(0.4, 2),
           "spread shocks do not discount the horizon recovery payment")
  benchmark <- c(ONE = 1, TWO = 1)
  no_migration <- simulate_credit_migrations(
    shocked_value, transition, correlation, 2000L, 177L, 12L,
    benchmark_values = benchmark
  )
  close_to(no_migration$losses, rep(2 * (1 - factor), 2000),
           "even without migrations the fixed benchmark captures spread loss")
  close_to(no_migration$diagnostics$exact_mean_loss_usd_million,
           2 * (1 - factor), "the fixed-benchmark analytical mean is correct")
  no_migration_risk <- summarize_credit_tail(
    no_migration$losses, 0.95, support = no_migration$loss_support
  )
  allocation <- allocate_credit_es(no_migration, shocked_value,
                                     no_migration_risk)
  close_to(allocation$es_contribution_usd_million, rep(1 - factor, 2),
           "ES allocation uses the same fixed issuer benchmarks")
  close_to(allocation$exact_mean_loss_usd_million, rep(1 - factor, 2),
           "issuer expected losses also use the fixed benchmarks")
  reordered <- resolve_credit_loss_benchmark(shocked_value, benchmark[2:1])
  check(identical(names(reordered), registry$issuer_id),
        "benchmark names establish identity independently of input ordering")
  expect_error(resolve_credit_loss_benchmark(shocked_value, c(1, 1)), "named")
  expect_error(resolve_credit_loss_benchmark(shocked_value,
                                              c(ONE = -1, TWO = 1)), "named")
  expect_error(value(shock = NA_real_), "finite horizon")

  # PSD-preserving dependence sensitivities have analytical endpoint limits.
  c_input <- matrix(c(1, -0.3, -0.3, 1), 2,
                      dimnames = dimnames(correlation))
  c_half <- stress_credit_correlation(c_input, 0.5)
  close_to(c_half[1, 2], 0.35, "correlation mixing is not an additive bump")
  close_to(diag(c_half), c(1, 1), "correlation mixing preserves unit variance")
  close_to(stress_credit_correlation(c_input, 0), c_input,
           "mixture zero preserves the calibration")
  close_to(stress_credit_correlation(c_input, 1), c_input * 0 + 1,
           "mixture one reaches singular perfect dependence")
  expect_error(stress_credit_correlation(c_input, 1.1), "in \\[0,1\\]")
  original <- registry
  original$notional_usd_million <- c(1.5, 0.5)
  equal <- stress_credit_allocation(original, "equal_face")
  close_to(equal$notional_usd_million, c(1, 1),
           "equal-face allocation preserves the total budget")
  group <- registry[c(1, 1, 2, 2), ]
  group$issuer_id <- c("A", "B", "C", "D")
  group$notional_usd_million <- c(1, 2, 3, 4)
  concentrated <- stress_credit_allocation(group, "weakest_50")
  close_to(sum(concentrated$notional_usd_million[1:2]), 5,
           "the entire weakest rating group receives half the face")
  close_to(concentrated$notional_usd_million[1] /
             concentrated$notional_usd_million[2], 0.5,
           "relative weights within the weakest group are preserved")
  close_to(sum(concentrated$notional_usd_million), 10,
           "concentration does not create additional face exposure")
  same_grade <- registry
  same_grade$rating_bucket <- "B"
  expect_error(stress_credit_allocation(same_grade, "weakest_50"),
               "two recognized rating groups")

  # With fixed quantiles, a deterministic shift has zero paired sampling error.
  base_losses <- rep(c(0, 2, 2, 2, 10), 2000)
  stress_losses <- base_losses + 3
  pair_base <- list(losses = base_losses, diagnostics = data.frame(
    exact_mean_loss_usd_million = mean(base_losses)
  ))
  pair_stress <- list(losses = stress_losses, diagnostics = data.frame(
    exact_mean_loss_usd_million = mean(stress_losses)
  ))
  pair_base_risk <- summarize_credit_tail(base_losses, 0.5)
  pair_stress_risk <- summarize_credit_tail(stress_losses, 0.5)
  paired <- compare_credit_stress_risk(pair_base, pair_base_risk,
                                        pair_stress, pair_stress_risk, 0.95)
  close_to(paired$delta_var_usd_million, 3, "VaR differences retain a shift")
  close_to(paired$delta_es_usd_million, 3, "ES differences retain a shift")
  close_to(paired$paired_es_mc_se_approx, 0,
           "paired excess-payoff differences have zero variance for a shift")
  close_to(c(paired$paired_es_mc_ci_lower_approx,
               paired$paired_es_mc_ci_upper_approx), c(3, 3),
           "a resolved deterministic ES difference has a point MC interval")
  close_to(paired$paired_mean_mc_se, 0,
           "paired mean errors account for dependence between runs")
  unresolved_base <- summarize_credit_tail(c(0, 2, 2, 2, 10), 0.5)
  unresolved_stress <- summarize_credit_tail(c(3, 5, 5, 5, 13), 0.5)
  unresolved <- compare_credit_stress_risk(
    list(losses = c(0, 2, 2, 2, 10), diagnostics = pair_base$diagnostics),
    unresolved_base,
    list(losses = c(3, 5, 5, 5, 13), diagnostics = pair_stress$diagnostics),
    unresolved_stress, 0.95
  )
  check(is.na(unresolved$paired_es_mc_ci_lower_approx),
        "an unresolved quantile suppresses the paired normal ES interval")

  # Independent enumeration: zero rates, unit faces and PDs 10% and 20%.
  transition["B", c("B", "D")] <- c(0.9, 0.1)
  transition["BBB", c("BBB", "D")] <- c(0.8, 0.2)
  inputs <- list(registry = registry, curve = curve, spreads = spreads,
                   transition = transition,
                   assumptions = list(recovery_rate = 0.4, horizon_years = 1),
                   metadata = list(market_observation_date = date))
  config_path <- file.path("config", "stress_scenarios.csv")
  definitions <- read_credit_stress_scenarios(config_path, 0.4)
  check(nrow(definitions) == 8L, "all eight documented sensitivities are typed")
  base_case <- build_credit_stress_case(inputs, correlation, definitions[1, ])
  spread_case <- build_credit_stress_case(inputs, correlation, definitions[4, ])
  recovery_case <- build_credit_stress_case(inputs, correlation,
                                             definitions[5, ])
  dependence_case <- build_credit_stress_case(inputs, correlation,
                                               definitions[2, ])
  close_to(base_case$portfolio$exact_mean_loss_usd_million, 0.3 * 0.6,
           "baseline expectation is PD times fixed LGD for each issuer")
  close_to(spread_case$portfolio$no_migration_shock_loss_usd_million,
           2 * (1 - factor), "deterministic spread loss is reported separately")
  close_to(spread_case$portfolio$exact_mean_loss_usd_million,
           2 - 1.7 * factor - 0.3 * 0.4,
           "the stressed expectation agrees with independent enumeration")
  close_to(recovery_case$portfolio$exact_mean_loss_usd_million, 0.3 * 0.8,
           "a recovery reduction changes expected loss without changing PD")
  close_to(dependence_case$portfolio$exact_mean_loss_usd_million,
           base_case$portfolio$exact_mean_loss_usd_million,
           "correlation alone cannot change the exact linear expectation")
  expected_spread_es <- 1.44 - 0.6 * factor
  enumerated_spread <- c(rep(2 - 2 * factor, 7200),
                          rep(1.6 - factor, 2600), rep(1.2, 200))
  close_to(summarize_credit_tail(enumerated_spread, 0.95)$es_usd_million,
           expected_spread_es, "horizon-shock ES matches independent atoms")
  close_to(summarize_credit_tail(enumerated_spread, 0.99)$es_usd_million, 1.2,
           "spreads leave an all-default extreme tail unchanged")
  check(abs(spread_case$portfolio$exact_mean_loss_usd_million -
              spread_case$portfolio$no_migration_shock_loss_usd_million -
              spread_case$portfolio$expected_migration_component_usd_million) <
          1e-12, "expected loss decomposes into shock and migration components")
  write_scenarios <- function(x) {
    path <- tempfile(tmpdir = fixture_dir, fileext = ".csv")
    readr::write_csv(x, path)
    path
  }
  bad <- definitions
  bad$correlation_mix[2] <- 2
  expect_error(read_credit_stress_scenarios(write_scenarios(bad), 0.4),
               "correlation/recovery")
  bad <- definitions
  bad$category[4] <- "dependence"
  expect_error(read_credit_stress_scenarios(write_scenarios(bad), 0.4),
               "categories")
  bad <- definitions
  bad$scenario_id[2] <- "baseline"
  expect_error(read_credit_stress_scenarios(write_scenarios(bad), 0.4),
               "uniquely")
  expect_error(read_credit_stress_scenarios(config_path, 0.3), "baseline")
  expect_error(read_credit_stress_scenarios(config_path, NA_real_),
               "finite baseline recovery")

  # Full offline archive path with a deliberately saved baseline simulation.
  root <- file.path(fixture_dir, "project")
  dir.create(file.path(root, "config"), recursive = TRUE)
  file.copy(config_path, file.path(root, "config", "stress_scenarios.csv"))
  source_dir <- file.path(root, "simulation")
  dir.create(source_dir)
  settings <- data.frame(n_scenarios = 5000L, batch_size = 177L, seed = 12L,
                          mc_confidence_level = 0.95, min_nominal_tail = 100L)
  metadata <- data.frame(market_observation_date = date,
                          n_scenarios = 5000L, batch_size = 177L, seed = 12L,
                          rng = "Mersenne-Twister/Inversion/Rejection")
  bundle <- list(valuation_inputs = inputs, correlation = correlation,
                   settings = settings, risk_levels = c(0.9, 0.95),
                   metadata = metadata)
  saved <- simulate_credit_migrations(value(), transition, correlation,
                                        5000L, 177L, 12L)
  scenarios_path <- file.path(source_dir, "scenarios.rds")
  saveRDS(list(losses = saved$losses, destinations = saved$destinations),
           scenarios_path)
  bundle_path <- file.path(source_dir, "simulation_inputs.rds")
  saveRDS(bundle, bundle_path)
  result <- run_credit_stress_tests(source_dir, root, date + 1L)
  check(nrow(result$risk) == 16L && nrow(result$comparisons) == 14L,
        "eight cases and both risk levels produce seven paired comparisons")
  check(isTRUE(result$metadata$baseline_replay_verified),
        "the pipeline verifies replay of the selected stage-04 baseline")
  check(all(result$diagnostics$mean_within_six_mc_se),
        "every scenario passes the analytical-mean diagnostic")
  check(all(result$portfolios$face_usd_million == 2),
        "all scenario allocations preserve the face budget")
  for (id in definitions$scenario_id) {
    case_dir <- file.path(result$snapshot_dir, id)
    check(all(file.exists(file.path(case_dir,
                                     c("case_inputs.rds", "scenarios.rds")))),
          paste("scenario archive is complete:", id))
    one <- readRDS(file.path(case_dir, "scenarios.rds"))
    case_inputs <- readRDS(file.path(case_dir, "case_inputs.rds"))
    replay <- simulate_credit_migrations(
      case_inputs$case$valuation, case_inputs$transition,
      case_inputs$case$correlation, 5000L, 177L, 12L,
      benchmark_values = case_inputs$case$benchmark_values
    )
    check(identical(one$losses, replay$losses) &&
            identical(one$destinations, replay$destinations),
          paste("archived inputs replay the scenario:", id))
    rows <- result$contributions[result$contributions$scenario_id == id, ]
    sums <- tapply(rows$es_contribution_usd_million, rows$confidence_level, sum)
    close_to(as.numeric(sums), result$risk$es_usd_million[
      result$risk$scenario_id == id
    ], paste("issuer ES contributions remain additive:", id))
  }
  recovery_saved <- readRDS(file.path(result$snapshot_dir,
                                       "recovery_20", "scenarios.rds"))
  check(identical(recovery_saved$destinations, saved$destinations),
        "valuation-only sensitivities preserve every migration outcome")
  check(all(recovery_saved$losses >= saved$losses - 1e-12),
        "lower recovery cannot improve a paired scenario payoff")
  source_fingerprint <- unname(tools::md5sum(bundle_path))
  check(result$metadata$baseline_inputs_md5 == source_fingerprint,
        "the source bundle is fingerprinted")
  expected_files <- c("stress_risk.csv", "stress_comparisons.csv",
                      "portfolio_metrics.csv", "issuer_es_contributions.csv",
                      "simulation_diagnostics.csv", "stress_correlations.csv",
                      "scenario_definitions.csv", "metadata.csv",
                      "stress_inputs.rds")
  check(all(file.exists(file.path(result$snapshot_dir, expected_files))),
        "the run saves risk, paired uncertainty, concentration and provenance")
  again <- run_credit_stress_tests(source_dir, root, date + 1L)
  check(result$snapshot_dir != again$snapshot_dir &&
          dir.exists(result$snapshot_dir),
        "repeated runs preserve old archives")
  close_to(again$risk$es_usd_million, result$risk$es_usd_million,
           "fixed inputs reproduce all scenario ES estimates")
  raw_root <- file.path(root, "data", "raw", "credit_stress")
  processed_root <- file.path(root, "data", "processed", "credit_stress")
  before_raw <- list.files(raw_root)
  before_processed <- list.files(processed_root)
  corrupt <- list(losses = saved$losses + 1, destinations = saved$destinations)
  saveRDS(corrupt, scenarios_path)
  expect_error(run_credit_stress_tests(source_dir, root, date + 1L),
               "replay differs")
  check(identical(list.files(raw_root), before_raw) &&
          identical(list.files(processed_root), before_processed),
        "a replay failure removes every partial stress output")
  expect_error(run_credit_stress_tests(source_dir, root, date + 20L), "stale")
  bad_bundle <- bundle
  bad_bundle$metadata$seed <- 99L
  expect_error(validate_credit_stress_source(bad_bundle, date + 1L),
               "do not match")
  bad_bundle <- bundle
  bad_bundle$valuation_inputs$curve$observation_date <- date - 1L
  expect_error(validate_credit_stress_source(bad_bundle, date + 1L),
               "do not match")
  cat("Passed", checks, "credit-stress checks.\n")
})
