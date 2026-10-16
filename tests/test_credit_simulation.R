# Purpose: verify Gaussian migrations, discrete tails and snapshot integration.
# All market data are synthetic; no test calls an external data provider.
# Run from the project root: source("tests/test_credit_simulation.R").

local({
  for (module in c("issuer_registry.R", "issuer_prices.R",
                    "transition_matrix.R", "migration_valuation.R",
                    "credit_simulation.R", "credit_risk_measures.R",
                    "credit_simulation_pipeline.R")) {
    source(file.path("R", module), local = TRUE)
  }
  fixture_dir <- tempfile("simulation_tests_")
  dir.create(fixture_dir)
  old_kind <- RNGkind()
  had_seed <- exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)
  if (had_seed) old_seed <- get(".Random.seed", envir = .GlobalEnv)
  on.exit({
    unlink(fixture_dir, recursive = TRUE)
    do.call(RNGkind, as.list(old_kind))
    if (had_seed) {
      assign(".Random.seed", old_seed, envir = .GlobalEnv)
    } else {
      rm(list = ".Random.seed", envir = .GlobalEnv)
    }
  }, add = TRUE)
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

  # The tail needs 1.5 of the three observations at VaR, plus the loss of 10.
  losses <- c(0, 2, 2, 2, 10)
  tail <- summarize_credit_tail(losses, 0.5)
  close_to(tail$var_usd_million, 2, "VaR uses the inverse empirical CDF")
  close_to(tail$es_usd_million, 5.2, "ES includes fractional boundary mass")
  close_to(tail$fraction_of_var_atom_in_tail, 0.5,
           "equal VaR scenarios share boundary mass symmetrically")
  weights <- credit_tail_weights(losses, 0.5, 2)
  close_to(weights, c(0, 0.2, 0.2, 0.2, 0.4), "tail weights are explicit")
  close_to(sum(weights), 1, "tail weights sum to one")
  check(tail$count_equal_to_var == 3L &&
          tail$count_strictly_above_var == 1L, "atom counts are audited")
  check(is.na(tail$es_mc_ci_lower_approx),
        "an unresolved VaR does not produce an ES normal interval")
  gap <- summarize_credit_tail(c(0, 0, 10, 10), 0.5)
  close_to(gap$var_usd_million, 0, "VaR does not interpolate across an atom")
  close_to(gap$es_usd_million, 10, "the tail can exclude the entire VaR atom")
  small_tail <- summarize_credit_tail(losses, 0.9)
  close_to(small_tail$es_usd_million, 10,
           "a tail smaller than one scenario remains well defined")
  constant <- summarize_credit_tail(rep(-3, 1000), c(0.95, 0.99),
                                     support = c(-3, -3))
  check(all(constant$var_usd_million == -3) &&
          all(constant$es_usd_million == -3), "negative losses are retained")
  check(all(constant$es_mc_se_approx == 0) &&
          all(constant$var_resolved_at_mc_confidence),
        "a known constant payoff has no simulation uncertainty")
  shifted <- summarize_credit_tail(losses + 7, 0.5)
  close_to(shifted$es_usd_million, tail$es_usd_million + 7,
           "ES is translation equivariant")
  close_to(shifted$var_usd_million, tail$var_usd_million + 7,
           "VaR is translation equivariant")
  scaled <- summarize_credit_tail(losses * 3, 0.5)
  close_to(scaled$es_usd_million, tail$es_usd_million * 3,
           "ES is positively homogeneous")
  bounded <- summarize_credit_tail(c(0, 1, 2), 0.5, support = c(-4, 8))
  close_to(c(bounded$var_mc_ci_lower, bounded$var_mc_ci_upper), c(-4, 8),
           "out-of-sample ranks use known support, not observed extremes")
  check(is.infinite(tail$var_mc_ci_lower) &&
          is.infinite(tail$var_mc_ci_upper),
        "unknown support stays unbounded for small-sample rank intervals")
  ranked <- summarize_credit_tail(seq_len(200), 0.95)
  ranks <- c(ranked$var_ci_lower_rank, ranked$var_ci_upper_rank)
  coverage <- stats::pbinom(ranks[2] - 1, 200, 0.95) -
    stats::pbinom(ranks[1] - 1, 200, 0.95)
  check(coverage >= 0.95, "binomial ranks attain the stated MC coverage")
  covered <- vapply(0:20, function(k) {
    estimate <- summarize_credit_tail(c(rep(0, 20 - k), rep(1, k)),
                                      0.95, support = c(0, 1))
    estimate$var_mc_ci_lower <= 0 && estimate$var_mc_ci_upper >= 0
  }, logical(1))
  check(sum(stats::dbinom(0:20, 20, 0.04) * covered) >= 0.95,
        "rank intervals remain conservative for a binary loss atom")
  expect_error(summarize_credit_tail(c(1, NA_real_), 0.95), "finite")
  expect_error(summarize_credit_tail(losses, c(0.95, 0.95)), "distinct")
  expect_error(summarize_credit_tail(losses, 1), "confidence")
  expect_error(summarize_credit_tail(losses, 0.95, 1), "MC confidence")
  expect_error(summarize_credit_tail(losses, 0.95, support = c(0, 9)),
               "outside")

  # Two unit exposures, zero rates, zero recovery and PDs of 10% and 20%.
  # Independence implies E[L]=0.3, P(L=2)=0.02 and ES(95%)=1.4.
  states <- credit_states()
  transition <- diag(8)
  dimnames(transition) <- list(states, states)
  transition["B", c("B", "D")] <- c(0.9, 0.1)
  transition["BBB", c("BBB", "D")] <- c(0.8, 0.2)
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
  valuation <- value_migration_states(registry, curve, spreads, transition, 0)
  correlation <- diag(2)
  dimnames(correlation) <- list(registry$issuer_id, registry$issuer_id)
  maps <- make_credit_rating_maps(transition, registry$rating_bucket,
                                   registry$issuer_id)
  close_to(maps$ONE$thresholds, stats::qnorm(0.1),
           "thresholds come from theoretical transition probabilities")
  limits <- map_credit_states(matrix(c(-Inf, -Inf, Inf, Inf),
                                      ncol = 2, byrow = TRUE), maps)
  check(all(limits[1, ] == 8L) && identical(as.integer(limits[2, ]), c(6L, 4L)),
        "low latent values default and high values select surviving grades")
  halfway <- transition
  halfway["B", c("B", "D")] <- 0.5
  boundary_maps <- make_credit_rating_maps(halfway, c("B", "AAA"),
                                            registry$issuer_id)
  boundary <- map_credit_states(matrix(c(0, -Inf, 1e-12, Inf),
                                        ncol = 2, byrow = TRUE), boundary_maps)
  check(boundary[1, 1] == 8L && boundary[2, 1] == 6L,
        "a threshold belongs to the lower, closed interval")
  check(all(boundary[, 2] == 1L),
        "a probability-one state maps both limits without zero-mass states")
  upgrades <- transition
  upgrades["B", ] <- 0
  upgrades["B", c("AAA", "B", "D")] <- c(0.2, 0.5, 0.3)
  upgrade_maps <- make_credit_rating_maps(upgrades, c("B", "AAA"),
                                           registry$issuer_id)
  selected <- map_credit_states(cbind(c(-Inf, 0, Inf), 0), upgrade_maps)
  check(identical(as.integer(selected[, 1]), c(8L, 6L, 1L)),
        "the ordered full-state map separates defaults, survival and upgrades")
  rounding <- matrix(-0.500000001, 3, 3)
  diag(rounding) <- 1
  dimnames(rounding) <- list(c("X", "Y", "Z"), c("X", "Y", "Z"))
  factored <- make_credit_gaussian_factor(rounding, c("X", "Y", "Z"))
  check(factored$clipped_eigenvalue_count == 1L &&
          factored$maximum_reconstruction_change < 1e-8,
        "tiny negative eigenvalues have explicit roundoff diagnostics")
  close_to(diag(factored$correlation), rep(1, 3),
           "roundoff handling preserves unit Gaussian marginal variances")
  rounding[rounding < 0] <- -0.6
  expect_error(make_credit_gaussian_factor(rounding, c("X", "Y", "Z")),
               "positive semidefinite")

  RNGkind("L'Ecuyer-CMRG")
  set.seed(901)
  caller_seed <- .Random.seed
  caller_kind <- RNGkind()
  simulation <- simulate_credit_migrations(
    valuation, transition, correlation, 200000L, 50000L, 20261016L
  )
  check(identical(.Random.seed, caller_seed) &&
          identical(RNGkind(), caller_kind),
        "simulation restores the caller's RNG state and algorithm")
  mean_check <- simulation$diagnostics
  close_to(mean_check$exact_mean_loss_usd_million, 0.3,
           "the analytical mean equals the independent PD*LGD sum")
  check(isTRUE(mean_check$mean_within_six_mc_se),
        "the simulated mean agrees with the analytical mean within MC error")
  joint <- mean(rowSums(simulation$destinations == 8L) == 2L)
  check(abs(joint - 0.02) < 6 * sqrt(0.02 * 0.98 / 200000),
        "independent latent draws give the analytical joint default rate")
  check(mean_check$max_abs_marginal_z < 6,
        "simulated marginal frequencies match the annual matrix")
  check(mean_check$max_latent_correlation_error < 0.02,
        "simulated latent dependence matches the correlation input")
  risk <- summarize_credit_tail(simulation$losses, 0.95,
                                support = simulation$loss_support)
  close_to(risk$var_usd_million, 1, "independent VaR agrees with enumeration")
  check(abs(risk$es_usd_million - 1.4) < 6 * risk$es_mc_se_approx,
        "independent ES agrees with enumeration within MC error")
  check(risk$var_resolved_at_mc_confidence &&
          is.finite(risk$es_mc_ci_lower_approx),
        "a resolved VaR supports an approximate ES MC interval")
  contributions <- allocate_credit_es(simulation, valuation, risk)
  close_to(sum(contributions$es_contribution_usd_million), risk$es_usd_million,
           "issuer contributions sum to portfolio ES")
  expected_contributions <- c((0.02 + 0.03 * 0.08 / 0.26) / 0.05,
                              (0.02 + 0.03 * 0.18 / 0.26) / 0.05)
  check(max(abs(contributions$es_contribution_usd_million -
                  expected_contributions)) < 0.03,
        "issuer tail allocations agree with independent exact enumeration")
  close_to(sum(contributions$es_above_mean_contribution_usd_million),
           risk$es_usd_million - 0.3,
           "ES above exact mean retains additive contributions")
  convergence <- credit_convergence_table(simulation, 0.95)
  check(identical(convergence$n_scenarios, c(10000L, 50000L, 100000L, 200000L)),
        "convergence uses distinct nested prefixes ending at the full run")
  close_to(tail(convergence$es_usd_million, 1), risk$es_usd_million,
           "the final convergence estimate is the full-sample ES")

  first <- simulate_credit_migrations(valuation, transition, correlation,
                                       2000L, 177L, 12L)
  second <- simulate_credit_migrations(valuation, transition, correlation,
                                        2000L, 333L, 12L)
  check(identical(first$destinations, second$destinations) &&
          identical(first$losses, second$losses),
        "batch partitioning preserves seeded scenario draws")
  reordered <- simulate_credit_migrations(
    valuation, transition, correlation[2:1, 2:1], 2000L, 333L, 12L
  )
  check(identical(second$losses, reordered$losses),
        "named correlation reordering preserves issuer identities")
  perfect <- correlation
  perfect[,] <- 1
  dependent <- simulate_credit_migrations(valuation, transition, perfect,
                                           20000L, 5000L, 18L)
  check(!any(dependent$destinations[, 1] == 8L &
               dependent$destinations[, 2] != 8L),
        "perfect positive dependence gives nested default events")
  dependent_risk <- summarize_credit_tail(dependent$losses, 0.95)
  close_to(dependent_risk$es_usd_million, 2,
           "the singular positive-correlation case has analytical ES of two")
  perfect[1, 2] <- perfect[2, 1] <- -1
  opposite <- simulate_credit_migrations(valuation, transition, perfect,
                                          10000L, 2000L, 18L)
  check(!any(rowSums(opposite$destinations == 8L) == 2L),
        "perfect negative dependence excludes simultaneous lower-tail default")
  deterministic <- diag(8)
  dimnames(deterministic) <- list(states, states)
  fixed_value <- value_migration_states(registry, curve, spreads,
                                         deterministic, 0)
  fixed <- simulate_credit_migrations(fixed_value, deterministic,
                                       correlation, 1000L, 177L, 12L)
  check(all(fixed$losses == 0) && fixed$diagnostics$mean_within_six_mc_se,
        "probability-one migration rows preserve a deterministic zero loss")
  bad <- correlation
  rownames(bad)[1] <- "WRONG"
  expect_error(simulate_credit_migrations(valuation, transition, bad), "labels")
  expect_error(simulate_credit_migrations(valuation, transition, correlation,
                                          2.5), "integer")
  inconsistent <- transition
  inconsistent["B", c("B", "D")] <- c(0.7, 0.3)
  expect_error(simulate_credit_migrations(valuation, inconsistent, correlation),
               "do not match")
  expect_error(with_credit_rng(12L, function() stop("callback failed")),
               "callback failed")
  check(identical(.Random.seed, caller_seed),
        "RNG state is restored even when the callback fails")
  rm(list = ".Random.seed", envir = .GlobalEnv)
  with_credit_rng(12L, function() stats::rnorm(3))
  check(!exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE),
        "simulation does not create a persistent seed when none existed")

  # Exercise the dated-price adapter and immutable archives without a network.
  root <- file.path(fixture_dir, "project")
  dir.create(file.path(root, "config"), recursive = TRUE)
  model_dir <- file.path(root, "valuation")
  dir.create(model_dir)
  inputs <- list(registry = registry, curve = curve, spreads = spreads,
                   transition = transition,
                   assumptions = list(recovery_rate = 0, horizon_years = 1),
                   metadata = list(market_observation_date = date))
  model_path <- file.path(model_dir, "model_inputs.rds")
  saveRDS(inputs, model_path)
  settings_path <- file.path(root, "config", "simulation_settings.csv")
  levels_path <- file.path(root, "config", "risk_levels.csv")
  header <- paste0("n_scenarios,batch_size,seed,mc_confidence_level,",
                     "min_nominal_tail")
  writeLines(c(header, "5000,177,20261016,0.95,100"), settings_path)
  writeLines(c("confidence_level", "0.90", "0.95"), levels_path)
  settings <- read_credit_simulation_config(settings_path, levels_path)
  check(settings$settings$n_scenarios == 5000L,
        "typed configuration reads reproducible simulation controls")
  writeLines(c("confidence_level", "0.999"), levels_path)
  expect_error(read_credit_simulation_config(settings_path, levels_path),
               "Too few nominal tail")
  writeLines(c("confidence_level", "0.90", "0.95"), levels_path)
  dates <- seq(date - 800, date, by = "day")
  dates <- tail(dates[as.integer(format(dates, "%u")) <= 5L], 521L)
  synthetic_prices <- do.call(rbind, lapply(seq_len(2L), function(i) {
    movement <- sin(seq_len(520) * (0.17 + i * 0.03)) * 0.01 +
      cos(seq_len(520) * 0.09) * 0.005
    price <- 100 * exp(c(0, cumsum(movement)))
    data.frame(issuer_id = registry$issuer_id[i], ticker = registry$ticker[i],
                 date = dates, open = price, high = price * 1.01,
                 low = price * 0.99, close = price, volume = 1000,
                 adjusted = price)
  }))
  prepared <- prepare_issuer_prices(synthetic_prices, registry,
                                     min(dates), date)
  fake_source <- file.path(root, "source_exports.rds")
  saveRDS(synthetic_prices, fake_source)
  prepared$registry <- registry
  prepared$metadata <- data.frame(
    source_exports_md5 = unname(tools::md5sum(fake_source)),
    source_exports_file = "source_exports.rds"
  )
  calls <- 0L
  fake_downloader <- function(project_dir, as_of_date, review_as_of_date) {
    check(as_of_date == date,
          "correlation is recalibrated through the saved valuation date")
    check(review_as_of_date == date + 1L, "the rating review date is explicit")
    calls <<- calls + 1L
    prepared
  }
  result <- run_credit_risk_simulation(model_dir, root, date + 1L,
                                        date + 1L, fake_downloader)
  check(calls == 1L && nrow(result$risk) == 2L,
        "the complete offline pipeline produces both requested risk levels")
  expected_files <- c("risk_estimates.csv", "issuer_es_contributions.csv",
                      "mean_check.csv", "marginal_diagnostics.csv",
                      "convergence.csv", "input_correlation.csv",
                      "used_correlation.csv",
                      "simulated_latent_correlation.csv",
                      "equity_returns.csv", "metadata.csv", "scenarios.rds",
                      "simulation_inputs.rds")
  check(all(file.exists(file.path(result$snapshot_dir, expected_files))),
        "the completed run saves diagnostics, input calibration and scenarios")
  check(result$metadata$correlation_last_date == date &&
          result$metadata$correlation_observations == 520L,
        "output metadata records the exact dated common calibration sample")
  close_to(result$risk$var_above_exact_mean_usd_million,
           result$risk$var_usd_million - 0.3,
           "unexpected-loss values use the exact analytical mean")
  saved <- readRDS(file.path(result$snapshot_dir, "simulation_inputs.rds"))
  replay <- simulate_credit_migrations(
    valuation, saved$valuation_inputs$transition, saved$correlation,
    saved$settings$n_scenarios, saved$settings$batch_size, saved$settings$seed
  )
  scenarios <- readRDS(file.path(result$snapshot_dir, "scenarios.rds"))
  check(identical(replay$losses, scenarios$losses) &&
          identical(replay$destinations, scenarios$destinations),
        "archived numeric inputs reproduce the saved scenarios exactly")
  check(result$metadata$model_inputs_md5 == unname(tools::md5sum(model_path)),
        "the output links to the fingerprinted valuation input")
  again <- run_credit_risk_simulation(model_dir, root, date + 1L,
                                       date + 1L, fake_downloader)
  check(result$snapshot_dir != again$snapshot_dir &&
          dir.exists(result$snapshot_dir), "repeated runs preserve old outputs")
  close_to(result$risk$es_usd_million, again$risk$es_usd_million,
           "repeated runs with fixed inputs preserve estimated ES")
  bad <- prepared
  bad$registry$rating_notch[1] <- "BB"
  expect_error(validate_simulation_price_inputs(bad, registry, date),
               "inputs changed")
  bad <- prepared
  bad$returns$date[nrow(bad$returns)] <- date + 1L
  expect_error(validate_simulation_price_inputs(bad, registry, date),
               "ending exactly")
  bad <- prepared
  bad$correlation <- correlation
  expect_error(validate_simulation_price_inputs(bad, registry, date),
               "do not match")
  raw_root <- file.path(root, "data", "raw", "credit_simulation")
  processed_root <- file.path(root, "data", "processed", "credit_simulation")
  before_raw <- list.files(raw_root)
  before_processed <- list.files(processed_root)
  failing_downloader <- function(...) stop("provider unavailable")
  expect_error(run_credit_risk_simulation(model_dir, root, date + 1L,
                                           date + 1L, failing_downloader),
               "provider unavailable")
  check(identical(list.files(raw_root), before_raw) &&
          identical(list.files(processed_root), before_processed),
        "a failed run leaves no partial simulation archive")
  calls_before <- calls
  expect_error(run_credit_risk_simulation(model_dir, root, date + 20L,
                                           date + 1L, fake_downloader), "stale")
  check(calls == calls_before, "a stale valuation fails before downloading")
  expect_error(run_credit_risk_simulation(file.path(root, "missing"), root),
               "snapshot explicitly")
  cat("Passed", checks, "credit-simulation checks.\n")
})
