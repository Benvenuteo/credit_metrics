# Purpose: align equity calibration to a saved valuation and archive tail risk.
# Inputs are explicit snapshots; no directory is silently chosen as 'latest'.

#' Read and validate reproducible controls and the requested risk levels.
read_credit_simulation_config <- function(settings_path, levels_path) {
  settings <- suppressWarnings(readr::read_csv(
    settings_path, col_types = readr::cols(.default = readr::col_double()),
    name_repair = "check_unique", show_col_types = FALSE, progress = FALSE
  ))
  columns <- c("n_scenarios", "batch_size", "seed", "mc_confidence_level",
                "min_nominal_tail")
  if (!all(columns %in% names(settings)) || nrow(settings) != 1L ||
      nrow(readr::problems(settings)) || anyNA(settings[columns])) {
    stop("Supply one complete typed simulation-settings row.", call. = FALSE)
  }
  check_simulation_integer(settings$n_scenarios, "n_scenarios", 2L, 50000000L)
  check_simulation_integer(settings$batch_size, "batch_size", 1L, 1000000L)
  check_simulation_integer(settings$seed, "seed", 0L)
  check_simulation_integer(settings$min_nominal_tail, "min_nominal_tail")
  if (settings$mc_confidence_level <= 0 ||
      settings$mc_confidence_level >= 1 ||
      !is.finite(settings$mc_confidence_level)) {
    stop("mc_confidence_level must lie strictly between zero and one.",
         call. = FALSE)
  }
  levels <- suppressWarnings(readr::read_csv(
    levels_path, col_types = readr::cols_only(
      confidence_level = readr::col_double()
    ), show_col_types = FALSE, progress = FALSE
  ))
  if (!"confidence_level" %in% names(levels) ||
      nrow(readr::problems(levels))) {
    stop("risk_levels.csv must contain numeric confidence_level values.",
         call. = FALSE)
  }
  levels <- check_credit_risk_levels(levels$confidence_level)
  if (settings$n_scenarios * (1 - max(levels)) + 1e-8 <
      settings$min_nominal_tail) {
    stop("Too few nominal tail scenarios: increase n_scenarios.",
         call. = FALSE)
  }
  list(settings = as.data.frame(settings[columns]), levels = levels)
}

#' Check a price-adapter result against valuation identities and cutoff.
#' @return The independently recomputed, named common-sample correlation.
validate_simulation_price_inputs <- function(prices, registry, market_date) {
  ids <- registry$issuer_id
  keys <- c("issuer_id", "ticker", "currency", "rating_notch", "rating_bucket",
              "notional_usd_million", "maturity_years")
  if (!is.data.frame(prices$registry) ||
      !all(keys %in% names(prices$registry)) ||
      !setequal(prices$registry$issuer_id, ids)) {
    stop("Price calibration issuer identities differ from valuation.",
         call. = FALSE)
  }
  current <- as.data.frame(prices$registry[
    match(ids, prices$registry$issuer_id), keys, drop = FALSE
  ])
  expected <- as.data.frame(registry[keys])
  rownames(current) <- rownames(expected) <- NULL
  if (!identical(current, expected)) {
    stop("Issuer inputs changed; rebuild the valuation before simulation.",
         call. = FALSE)
  }
  returns <- prices$returns
  if (!is.data.frame(returns) || nrow(returns) < 500L ||
      !all(c("date", "previous_date", ids) %in% names(returns)) ||
      !inherits(returns$date, "Date") || anyNA(returns$date) ||
      !inherits(returns$previous_date, "Date") ||
      anyNA(returns$previous_date) || anyDuplicated(returns$date) ||
      any(returns$date > market_date) || max(returns$date) != market_date ||
      any(returns$previous_date >= returns$date) ||
      !all(vapply(returns[ids], is.numeric, logical(1))) ||
      any(!is.finite(as.matrix(returns[ids])))) {
    stop("Need >=500 common returns ending exactly on the valuation date.",
         call. = FALSE)
  }
  correlation <- stats::cor(as.matrix(returns[ids]), method = "pearson")
  validate_issuer_correlation(correlation)
  supplied <- prices$correlation[ids, ids, drop = FALSE]
  if (!isTRUE(all.equal(correlation, supplied, tolerance = 1e-10))) {
    stop("Supplied correlations do not match the dated return sample.",
         call. = FALSE)
  }
  correlation
}

#' Run current-vintage risk simulation from one explicit valuation snapshot.
#' @param valuation_snapshot_dir Stage-03 directory containing model_inputs.rds.
#' @param project_dir Existing project root with simulation configuration.
#' @param analysis_cutoff Completed-day cutoff or an explicit replay date.
#' @param review_date Date used for the current manual issuer review.
#' @param price_downloader Price adapter, injectable for offline integration.
#' @return Risk measures, allocations, diagnostics and immutable output path.
#' @details Prices are requested only through the valuation date. Historical
#'   cutoffs on new downloads do not establish point-in-time availability.
run_credit_risk_simulation <- function(
    valuation_snapshot_dir, project_dir = ".",
    analysis_cutoff = default_equity_cutoff(), review_date = Sys.Date(),
    price_downloader = download_issuer_prices) {
  validate_issuer_date(analysis_cutoff, "analysis_cutoff")
  validate_issuer_date(review_date, "review_date")
  if (!is.character(project_dir) || length(project_dir) != 1L ||
      is.na(project_dir) || !dir.exists(project_dir) ||
      !is.function(price_downloader) ||
      analysis_cutoff > default_equity_cutoff()) {
    stop("Supply a project root, price adapter and completed-day cutoff.",
         call. = FALSE)
  }
  if (!is.character(valuation_snapshot_dir) ||
      length(valuation_snapshot_dir) != 1L || is.na(valuation_snapshot_dir) ||
      !dir.exists(valuation_snapshot_dir)) {
    stop("Select an existing stage-03 valuation snapshot explicitly.",
         call. = FALSE)
  }
  project_dir <- normalizePath(project_dir, winslash = "/", mustWork = TRUE)
  model_path <- file.path(valuation_snapshot_dir, "model_inputs.rds")
  if (!file.exists(model_path)) {
    stop("The selected snapshot has no model_inputs.rds.", call. = FALSE)
  }
  config_names <- c("simulation_settings.csv", "risk_levels.csv")
  config_paths <- file.path(project_dir, "config", config_names)
  config <- read_credit_simulation_config(config_paths[1L], config_paths[2L])
  fingerprints <- unname(tools::md5sum(c(model_path, config_paths)))
  raw_root <- file.path(project_dir, "data", "raw", "credit_simulation")
  processed_root <- file.path(project_dir, "data", "processed",
                               "credit_simulation")
  for (directory in c(raw_root, processed_root)) {
    if (!dir.exists(directory) && !dir.create(directory, recursive = TRUE)) {
      stop(paste("Cannot create output directory:", directory), call. = FALSE)
    }
  }
  run_name <- basename(tempfile(paste0(
    "run_", format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"), "_"
  ), tmpdir = processed_root))
  raw_dir <- file.path(raw_root, run_name)
  snapshot_dir <- file.path(processed_root, run_name)
  created <- character()
  completed <- FALSE
  on.exit(if (!completed) unlink(created, recursive = TRUE), add = TRUE)
  if (!dir.create(raw_dir)) stop("Cannot create input archive.", call. = FALSE)
  created <- c(created, raw_dir)
  archived_paths <- file.path(raw_dir, c("model_inputs.rds", config_names))
  if (!all(file.copy(c(model_path, config_paths), archived_paths)) ||
      !identical(unname(tools::md5sum(archived_paths)), fingerprints)) {
    stop("Cannot archive unchanged model/settings inputs.", call. = FALSE)
  }
  inputs <- readRDS(archived_paths[1L])
  market_date <- inputs$metadata$market_observation_date
  validate_issuer_date(market_date, "saved market_observation_date")
  if (market_date > analysis_cutoff ||
      as.integer(analysis_cutoff - market_date) > 14L) {
    stop("Valuation date is stale or later than the analysis cutoff.",
         call. = FALSE)
  }
  config <- read_credit_simulation_config(archived_paths[2L],
                                           archived_paths[3L])
  settings <- config$settings
  valuation <- value_migration_states(
    inputs$registry, inputs$curve, inputs$spreads, inputs$transition,
    inputs$assumptions$recovery_rate, inputs$assumptions$horizon_years
  )
  message("Calibrating equity correlation through ", market_date, ".")
  prices <- price_downloader(project_dir = project_dir,
                              as_of_date = market_date,
                              review_as_of_date = review_date)
  correlation <- validate_simulation_price_inputs(
    prices, inputs$registry, market_date
  )
  message("Simulating ", settings$n_scenarios, " correlated migrations.")
  simulation <- simulate_credit_migrations(
    valuation, inputs$transition, correlation, settings$n_scenarios,
    settings$batch_size, settings$seed
  )
  risk <- summarize_credit_tail(
    simulation$losses, config$levels, settings$mc_confidence_level,
    support = simulation$loss_support
  )
  exact_mean <- simulation$diagnostics$exact_mean_loss_usd_million
  risk$var_above_exact_mean_usd_million <- risk$var_usd_million - exact_mean
  risk$es_above_exact_mean_usd_million <- risk$es_usd_million - exact_mean
  contributions <- allocate_credit_es(simulation, valuation, risk)
  convergence <- credit_convergence_table(
    simulation, config$levels, settings$mc_confidence_level
  )
  mean_check <- simulation$diagnostics
  cutoff <- stats::qnorm((1 + settings$mc_confidence_level) / 2)
  mean_check$mean_mc_ci_lower <-
    mean_check$simulated_mean_loss_usd_million -
    cutoff * mean_check$mean_mc_se_usd_million
  mean_check$mean_mc_ci_upper <-
    mean_check$simulated_mean_loss_usd_million +
    cutoff * mean_check$mean_mc_se_usd_million
  metadata <- data.frame(
    market_observation_date = market_date, analysis_cutoff = analysis_cutoff,
    correlation_first_date = min(prices$returns$date),
    correlation_last_date = max(prices$returns$date),
    correlation_observations = nrow(prices$returns),
    n_scenarios = settings$n_scenarios, batch_size = settings$batch_size,
    seed = settings$seed, rng = "Mersenne-Twister/Inversion/Rejection",
    dependence = "Gaussian latent migration; equity correlation proxy",
    loss_benchmark = "No-migration horizon value minus scenario value",
    money_units = "USD million", quantile_method = "Inverse ECDF; R type 1",
    es_method = "Quantile-integral ES; fractional boundary mass",
    var_mc_ci_method = "Binomial order-statistic ranks; conservative at atoms",
    es_mc_ci_method = "Approximate normal excess payoff; resolved VaR only",
    uncertainty_scope = "Monte Carlo only; excludes parameter and model risk",
    mc_confidence_level = settings$mc_confidence_level,
    min_nominal_tail = settings$min_nominal_tail,
    model_inputs_md5 = fingerprints[1L], settings_md5 = fingerprints[2L],
    levels_md5 = fingerprints[3L],
    equity_source_md5 = prices$metadata$source_exports_md5,
    equity_source_file = prices$metadata$source_exports_file,
    created_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    r_version = as.character(getRversion()), platform = R.version$platform,
    lapack_version = La_version()
  )
  if (!dir.create(snapshot_dir)) {
    stop("Cannot create processed simulation snapshot.", call. = FALSE)
  }
  created <- c(created, snapshot_dir)
  correlation_table <- function(x) {
    data.frame(issuer_id = rownames(x), x, row.names = NULL,
                 check.names = FALSE)
  }
  tables <- list(
    risk_estimates = risk, issuer_es_contributions = contributions,
    mean_check = mean_check,
    marginal_diagnostics = simulation$marginal_diagnostics,
    convergence = convergence,
    input_correlation = correlation_table(correlation),
    used_correlation = correlation_table(simulation$gaussian$correlation),
    simulated_latent_correlation =
      correlation_table(simulation$latent_correlation),
    equity_returns = prices$returns, metadata = metadata
  )
  for (name in names(tables)) {
    readr::write_csv(tables[[name]],
                     file.path(snapshot_dir, paste0(name, ".csv")))
  }
  saveRDS(list(losses = simulation$losses,
                destinations = simulation$destinations),
           file.path(snapshot_dir, "scenarios.rds"), version = 3)
  saveRDS(list(valuation_inputs = inputs, correlation = correlation,
                settings = settings, risk_levels = config$levels,
                metadata = metadata),
           file.path(snapshot_dir, "simulation_inputs.rds"), version = 3)
  completed <- TRUE
  message("Credit-risk simulation complete; market date: ", market_date, ".")
  if (!isTRUE(mean_check$mean_within_six_mc_se)) {
    warning("Simulation mean requires review against the analytical mean.",
            call. = FALSE)
  }
  list(risk = risk, contributions = contributions, mean_check = mean_check,
       marginal_diagnostics = simulation$marginal_diagnostics,
       convergence = convergence, metadata = metadata,
       snapshot_dir = snapshot_dir)
}
