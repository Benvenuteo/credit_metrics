# Purpose: replay one selected baseline and archive comparable stress results.
# The workflow does not download or silently refresh any market observations.

#' Check saved controls and dates before reusing a stage-04 simulation bundle.
validate_credit_stress_source <- function(bundle, analysis_cutoff) {
  settings <- bundle$settings
  columns <- c("n_scenarios", "batch_size", "seed", "mc_confidence_level",
                "min_nominal_tail")
  if (!is.data.frame(settings) || nrow(settings) != 1L ||
      !all(columns %in% names(settings)) || anyNA(settings[columns])) {
    stop("The saved baseline has incomplete simulation settings.",
         call. = FALSE)
  }
  check_simulation_integer(settings$n_scenarios, "n_scenarios", 2L, 50000000L)
  check_simulation_integer(settings$batch_size, "batch_size", 1L, 1000000L)
  check_simulation_integer(settings$seed, "seed", 0L)
  check_simulation_integer(settings$min_nominal_tail, "min_nominal_tail")
  confidence <- settings$mc_confidence_level
  if (!is.numeric(confidence) || !is.finite(confidence) ||
      confidence <= 0 || confidence >= 1) {
    stop("Saved MC confidence must lie strictly between zero and one.",
         call. = FALSE)
  }
  levels <- check_credit_risk_levels(bundle$risk_levels)
  if (settings$n_scenarios * (1 - max(levels)) + 1e-8 <
      settings$min_nominal_tail) {
    stop("The saved baseline has too few nominal tail scenarios.",
         call. = FALSE)
  }
  date <- bundle$metadata$market_observation_date
  validate_issuer_date(date, "saved market_observation_date")
  if (date > analysis_cutoff || as.integer(analysis_cutoff - date) > 14L) {
    stop("The saved baseline market date is stale or beyond the cutoff.",
         call. = FALSE)
  }
  input_date <- bundle$valuation_inputs$metadata$market_observation_date
  curve_date <- unique(bundle$valuation_inputs$curve$observation_date)
  spread_date <- unique(bundle$valuation_inputs$spreads$observation_date)
  if (!identical(date, input_date) ||
      !identical(curve_date, date) || !identical(spread_date, date) ||
      !identical(bundle$metadata$rng,
                   "Mersenne-Twister/Inversion/Rejection") ||
      !isTRUE(bundle$metadata$n_scenarios == settings$n_scenarios) ||
      !isTRUE(bundle$metadata$seed == settings$seed) ||
      !isTRUE(bundle$metadata$batch_size == settings$batch_size)) {
    stop("Saved valuation dates, RNG or settings do not match their metadata.",
         call. = FALSE)
  }
  list(settings = settings, levels = levels, market_date = date)
}

#' Verify replay against the saved baseline, rather than mixing simulation runs.
check_credit_stress_replay <- function(simulation, archived) {
  if (!identical(simulation$destinations, archived$destinations) ||
      !isTRUE(all.equal(simulation$losses, archived$losses,
                         tolerance = 1e-12, check.attributes = TRUE))) {
    stop(paste0(
      "Baseline replay differs from saved scenarios. Rebuild stage 04 ",
      "in this R environment before comparing stresses."
    ), call. = FALSE)
  }
  invisible(NULL)
}

#' Evaluate deterministic sensitivities using the saved stage-04 controls.
#' @param simulation_snapshot_dir Explicit directory from stage 04.
#' @param project_dir Project root containing config/stress_scenarios.csv.
#' @param analysis_cutoff Completed-day cutoff, explicit for historical replay.
#' @return Scenario risks, paired differences, allocations and output path.
#' @details Spread shocks change horizon values. Base no-migration benchmarks
#'   remain fixed for each allocation. Innovations and seed are shared across
#'   cases, with approximate paired ES errors conditional on resolved quantiles.
run_credit_stress_tests <- function(
    simulation_snapshot_dir, project_dir = ".",
    analysis_cutoff = default_equity_cutoff()) {
  validate_issuer_date(analysis_cutoff, "analysis_cutoff")
  if (!is.character(project_dir) || length(project_dir) != 1L ||
      is.na(project_dir) || !dir.exists(project_dir) ||
      !is.character(simulation_snapshot_dir) ||
      length(simulation_snapshot_dir) != 1L ||
      is.na(simulation_snapshot_dir) || !dir.exists(simulation_snapshot_dir) ||
      analysis_cutoff > default_equity_cutoff()) {
    stop("Select an existing project, stage-04 snapshot and valid cutoff.",
         call. = FALSE)
  }
  project_dir <- normalizePath(project_dir, winslash = "/", mustWork = TRUE)
  source_paths <- c(file.path(simulation_snapshot_dir,
                              c("simulation_inputs.rds", "scenarios.rds")),
                    file.path(project_dir, "config", "stress_scenarios.csv"))
  if (!all(file.exists(source_paths))) {
    stop("Stage-04 inputs/scenarios or stress_scenarios.csv are missing.",
         call. = FALSE)
  }
  fingerprints <- unname(tools::md5sum(source_paths))
  raw_root <- file.path(project_dir, "data", "raw", "credit_stress")
  processed_root <- file.path(project_dir, "data", "processed", "credit_stress")
  for (directory in c(raw_root, processed_root)) {
    if (!dir.exists(directory) && !dir.create(directory, recursive = TRUE)) {
      stop(paste("Cannot create directory:", directory), call. = FALSE)
    }
  }
  run_name <- basename(tempfile(paste0(
    "run_", format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC"), "_"
  ), tmpdir = processed_root))
  raw_dir <- file.path(raw_root, run_name)
  snapshot_dir <- file.path(processed_root, run_name)
  created <- character()
  complete <- FALSE
  on.exit(if (!complete) unlink(created, recursive = TRUE), add = TRUE)
  if (!dir.create(raw_dir)) stop("Cannot create stress input archive.",
                                 call. = FALSE)
  created <- c(created, raw_dir)
  archived_paths <- file.path(raw_dir, basename(source_paths))
  if (!all(file.copy(source_paths, archived_paths)) ||
      !identical(unname(tools::md5sum(archived_paths)), fingerprints)) {
    stop("Cannot archive unchanged baseline inputs and stress configuration.",
         call. = FALSE)
  }
  bundle <- readRDS(archived_paths[1L])
  control <- validate_credit_stress_source(bundle, analysis_cutoff)
  inputs <- bundle$valuation_inputs
  scenarios <- read_credit_stress_scenarios(
    archived_paths[3L], inputs$assumptions$recovery_rate
  )
  settings <- control$settings
  if (!dir.create(snapshot_dir)) stop("Cannot create stress output snapshot.",
                                      call. = FALSE)
  created <- c(created, snapshot_dir)
  risk_tables <- comparison_tables <- portfolio_tables <- list()
  contribution_tables <- diagnostic_tables <- correlation_tables <- list()
  tag <- function(x, scenario_id) {
    data.frame(scenario_id = scenario_id, x, row.names = NULL,
                 check.names = FALSE)
  }
  for (i in seq_len(nrow(scenarios))) {
    scenario <- scenarios[i, , drop = FALSE]
    id <- scenario$scenario_id
    message("Stress case ", i, "/", nrow(scenarios), ": ", id, ".")
    case <- build_credit_stress_case(inputs, bundle$correlation, scenario)
    simulation <- simulate_credit_migrations(
      case$valuation, inputs$transition, case$correlation,
      settings$n_scenarios, settings$batch_size, settings$seed,
      benchmark_values = case$benchmark_values
    )
    risk <- summarize_credit_tail(
      simulation$losses, control$levels, settings$mc_confidence_level,
      simulation$loss_support
    )
    exact_mean <- simulation$diagnostics$exact_mean_loss_usd_million
    risk$var_above_exact_mean_usd_million <- risk$var_usd_million - exact_mean
    risk$es_above_exact_mean_usd_million <- risk$es_usd_million - exact_mean
    risk$var_percent_of_face <-
      100 * risk$var_usd_million / case$portfolio$face_usd_million
    risk$es_percent_of_face <-
      100 * risk$es_usd_million / case$portfolio$face_usd_million
    if (i == 1L) {
      check_credit_stress_replay(simulation, readRDS(archived_paths[2L]))
      baseline <- simulation
      baseline_risk <- risk
    } else {
      comparison_tables[[i - 1L]] <- tag(compare_credit_stress_risk(
        baseline, baseline_risk, simulation, risk, settings$mc_confidence_level
      ), id)
      monotone <- scenario$correlation_mix == 0 &&
        scenario$allocation == "original" &&
        scenario$recovery_rate <= inputs$assumptions$recovery_rate
      if (monotone && any(simulation$losses < baseline$losses - 1e-9)) {
        stop("An adverse valuation-only shock reduced a paired loss.",
             call. = FALSE)
      }
    }
    risk_tables[[i]] <- tag(risk, id)
    portfolio_tables[[i]] <- tag(case$portfolio, id)
    contribution_tables[[i]] <- tag(allocate_credit_es(
      simulation, case$valuation, risk
    ), id)
    diagnostic_tables[[i]] <- tag(simulation$diagnostics, id)
    pairs <- expand.grid(issuer_row = rownames(case$correlation),
                           issuer_column = colnames(case$correlation),
                           stringsAsFactors = FALSE)
    pairs$input_correlation <- as.vector(case$correlation)
    pairs$used_correlation <- as.vector(simulation$gaussian$correlation)
    pairs$simulated_latent_correlation <-
      as.vector(simulation$latent_correlation)
    correlation_tables[[i]] <- tag(pairs, id)
    case_dir <- file.path(snapshot_dir, id)
    if (!dir.create(case_dir)) stop("Cannot create scenario archive.",
                                    call. = FALSE)
    saveRDS(list(losses = simulation$losses,
                  destinations = simulation$destinations),
             file.path(case_dir, "scenarios.rds"), version = 3)
    saveRDS(list(case = case, transition = inputs$transition,
                  settings = settings, risk_levels = control$levels,
                  definition = scenario),
             file.path(case_dir, "case_inputs.rds"), version = 3)
    message("Completed ", id, "; exact mean loss: ",
              format(exact_mean, digits = 6), " USD million.")
  }
  risk <- do.call(rbind, risk_tables)
  comparisons <- do.call(rbind, comparison_tables)
  portfolios <- do.call(rbind, portfolio_tables)
  contributions <- do.call(rbind, contribution_tables)
  diagnostics <- do.call(rbind, diagnostic_tables)
  correlations <- do.call(rbind, correlation_tables)
  metadata <- data.frame(
    market_observation_date = control$market_date,
    analysis_cutoff = analysis_cutoff, n_scenarios = settings$n_scenarios,
    seed = settings$seed, batch_size = settings$batch_size,
    rng = "Mersenne-Twister/Inversion/Rejection",
    scenario_count = nrow(scenarios), baseline_replay_verified = TRUE,
    money_units = "USD million",
    benchmark = "Base no-migration horizon value for each allocation",
    spread_shock_timing = "Horizon only; inception prices unchanged",
    correlation_shock = "Convex mixture toward all-ones matrix",
    comparison_method = "Common innovations; paired MC differences",
    interpretation = "Chosen sensitivities; not calibrated macro forecasts",
    uncertainty_scope = "Monte Carlo only; excludes parameter and model risk",
    baseline_inputs_md5 = fingerprints[1L],
    baseline_scenarios_md5 = fingerprints[2L],
    stress_configuration_md5 = fingerprints[3L],
    created_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    r_version = as.character(getRversion()), platform = R.version$platform,
    lapack_version = La_version()
  )
  tables <- list(stress_risk = risk, stress_comparisons = comparisons,
                   portfolio_metrics = portfolios,
                   issuer_es_contributions = contributions,
                   simulation_diagnostics = diagnostics,
                   stress_correlations = correlations,
                   scenario_definitions = scenarios, metadata = metadata)
  for (name in names(tables)) {
    readr::write_csv(tables[[name]],
                     file.path(snapshot_dir, paste0(name, ".csv")))
  }
  saveRDS(list(baseline_inputs = bundle, scenarios = scenarios,
                metadata = metadata),
           file.path(snapshot_dir, "stress_inputs.rds"), version = 3)
  complete <- TRUE
  if (any(!diagnostics$mean_within_six_mc_se)) {
    warning("Review stress simulation means against their analytical values.",
            call. = FALSE)
  }
  list(risk = risk, comparisons = comparisons, portfolios = portfolios,
       contributions = contributions, diagnostics = diagnostics,
       metadata = metadata, snapshot_dir = snapshot_dir)
}
