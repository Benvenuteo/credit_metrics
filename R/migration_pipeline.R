# Purpose: obtain dated inputs and save a complete migration-valuation snapshot.
# Run through scripts/03_value_migrations.R; no provider data are committed.

#' Build a reproducible one-year valuation run with fresh source downloads.
#' @param project_dir Existing project root.
#' @param as_of_date Requested cutoff, normally yesterday in New York.
#' @param review_date Date for assessing the manual source/issuer reviews.
#' @param input_downloader HTTPS adapter, injectable for offline tests.
#' @param curve_downloader Fed importer; injectable for offline tests.
#' @return Valuations, source/assumption metadata and the snapshot path.
#' @details Current vintages are not point-in-time historical datasets. Index
#'   spreads approximate flat credit curves. Recovery is a stated assumption,
#'   not an empirical estimate. No VaR or portfolio variance is computed here.
run_migration_valuation <- function(
    project_dir = ".",
    as_of_date = as.Date(format(Sys.time(), "%Y-%m-%d",
                                tz = "America/New_York")) - 1L,
    review_date = Sys.Date(), input_downloader = download_credit_input,
    curve_downloader = download_fed_yield_curve) {
  validate_issuer_date(as_of_date, "as_of_date")
  validate_issuer_date(review_date, "review_date")
  completed_us_day <- as.Date(format(Sys.time(), "%Y-%m-%d",
                                      tz = "America/New_York")) - 1L
  if (as_of_date > completed_us_day || !is.function(input_downloader) ||
      !is.function(curve_downloader)) {
    stop("Use a completed-day cutoff and valid source adapters.", call. = FALSE)
  }
  if (!is.character(project_dir) || length(project_dir) != 1L ||
      is.na(project_dir) || !dir.exists(project_dir)) {
    stop("project_dir must be an existing directory.", call. = FALSE)
  }
  project_dir <- normalizePath(project_dir, winslash = "/", mustWork = TRUE)
  config_names <- c("issuers.csv", "transition_source.csv",
                    "valuation_assumptions.csv")
  config_paths <- file.path(project_dir, "config", config_names)
  registry <- read_issuer_registry(config_paths[1L], review_date)
  descriptor <- read_transition_source(config_paths[2L], review_date)
  assumptions <- read_valuation_assumptions(config_paths[3L])
  if (descriptor$published_on > as_of_date ||
      any(registry$rating_source_date > as_of_date)) {
    stop("The requested cutoff precedes the supporting rating/study sources.",
         call. = FALSE)
  }
  fingerprints <- unname(tools::md5sum(config_paths))
  raw_root <- file.path(project_dir, "data", "raw", "migration_valuation")
  processed_root <- file.path(project_dir, "data", "processed",
                               "migration_valuation")
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
  if (!dir.create(raw_dir)) {
    stop("Cannot create source snapshot.", call. = FALSE)
  }
  created <- c(created, raw_dir)
  if (!all(file.copy(config_paths, file.path(raw_dir, config_names))) ||
      !identical(unname(tools::md5sum(file.path(raw_dir, config_names))),
                  fingerprints)) {
    stop("Cannot preserve unchanged configuration inputs.", call. = FALSE)
  }
  # Bind calculations to the archived bytes even if an editor changes a config.
  registry <- read_issuer_registry(
    file.path(raw_dir, config_names[1L]), review_date
  )
  descriptor <- read_transition_source(
    file.path(raw_dir, config_names[2L]), review_date
  )
  assumptions <- read_valuation_assumptions(
    file.path(raw_dir, config_names[3L])
  )

  message("Downloading Treasury curve, S&P study and rating-index spreads.")
  fed <- curve_downloader(project_dir = project_dir, as_of_date = as_of_date,
                           max_age_days = 14L)
  sp_path <- file.path(raw_dir, "sp_transition_study.html")
  sp_retrieval <- input_downloader(descriptor$source_url, sp_path)
  published <- read_sp_transition_table(
    sp_path, descriptor$study_start_year, descriptor$study_end_year
  )
  transition <- build_transition_matrix(published, assumptions$nr_policy)
  fred_path <- file.path(raw_dir, "fred_rating_oas.csv")
  fred_retrieval <- input_downloader(
    "https://fred.stlouisfed.org/graph/fredgraph.csv", fred_path,
    query = list(id = paste(unname(rating_spread_series()), collapse = ","),
                 cosd = as.character(as_of_date - 30L),
                 coed = as.character(as_of_date))
  )
  spread_history <- read_rating_spread_history(fred_path)
  latest_spreads <- select_rating_spreads(spread_history, as_of_date,
                                          max_age_days = 7L)
  fed_history <- read_fed_yield_history(fed$raw_path)
  aligned <- align_credit_market_inputs(fed_history, spread_history, as_of_date)
  if (descriptor$published_on > aligned$market_date ||
      any(registry$rating_source_date > aligned$market_date)) {
    stop("The common market date precedes the supporting rating/study sources.",
         call. = FALSE)
  }
  valuation <- value_migration_states(
    registry, aligned$curve, aligned$spreads, transition$matrix,
    assumptions$recovery_rate, assumptions$horizon_years
  )
  # Separate NR and recovery assumptions from the primary result.
  sensitivity <- list()
  for (policy in c("condition_on_observed", "nr_to_initial_rating")) {
    alternative <- build_transition_matrix(published, policy)
    for (recovery in sort(unique(c(0.2, assumptions$recovery_rate, 0.6)))) {
      result <- value_migration_states(
        registry, aligned$curve, aligned$spreads, alternative$matrix, recovery
      )
      sensitivity[[length(sensitivity) + 1L]] <- data.frame(
        nr_policy = policy, recovery_rate = recovery,
        is_baseline = policy == assumptions$nr_policy &&
          recovery == assumptions$recovery_rate,
        result$portfolio_summary
      )
    }
  }
  sensitivity <- do.call(rbind, sensitivity)
  metadata <- data.frame(
    requested_cutoff = as_of_date,
    market_observation_date = aligned$market_date,
    market_age_calendar_days = as.integer(as_of_date - aligned$market_date),
    latest_fed_observation = fed$metadata$observation_date,
    latest_spread_observation = latest_spreads$observation_date[1L],
    market_alignment_policy = "Latest shared observed date; no filling",
    study_start_year = descriptor$study_start_year,
    study_end_year = descriptor$study_end_year,
    study_published_on = descriptor$published_on,
    study_review_due_on = descriptor$review_due_on,
    horizon_years = assumptions$horizon_years,
    recovery_rate = assumptions$recovery_rate,
    recovery_policy = "Fixed fraction of face paid at horizon; assumed",
    nr_policy = assumptions$nr_policy,
    spread_policy = assumptions$spread_policy,
    spread_order_monotone =
      all(diff(aligned$spreads$spread_decimal_proxy) >= 0),
    future_curve_policy =
      "Treasury forward curve; frozen flat rating spread proxy",
    probability_measure =
      "Historical physical migrations; explicit NR assumption",
    money_units = "USD million", compounding = "continuous model approximation",
    review_date = review_date,
    created_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    issuer_registry_md5 = fingerprints[1L],
    transition_descriptor_md5 = fingerprints[2L],
    assumptions_md5 = fingerprints[3L],
    r_version = as.character(getRversion()),
    httr2_version = as.character(utils::packageVersion("httr2")),
    readr_version = as.character(utils::packageVersion("readr")),
    jsonlite_version = as.character(utils::packageVersion("jsonlite")),
    xml2_version = as.character(utils::packageVersion("xml2"))
  )
  provenance <- data.frame(
    input = c("Treasury GSW", "S&P transition study",
                "ICE BofA rating OAS via FRED"),
    source_url = c(fed$metadata$source_url, sp_retrieval$source_url,
                    fred_retrieval$source_url),
    downloaded_at_utc = c(fed$metadata$downloaded_at_utc,
                           sp_retrieval$downloaded_at_utc,
                           fred_retrieval$downloaded_at_utc),
    raw_md5 = c(fed$metadata$raw_md5, sp_retrieval$source_md5,
                  fred_retrieval$source_md5),
    raw_file = c(fed$metadata$raw_file,
                   file.path("data", "raw", "migration_valuation", run_name,
                               basename(sp_path)),
                   file.path("data", "raw", "migration_valuation", run_name,
                               basename(fred_path)))
  )
  if (!dir.create(snapshot_dir)) {
    stop("Cannot create processed valuation snapshot.", call. = FALSE)
  }
  created <- c(created, snapshot_dir)
  matrix_table <- function(x) {
    data.frame(from_rating = rownames(x), x, row.names = NULL,
                 check.names = FALSE)
  }
  tables <- list(
    published_transition_percent = published,
    transition_matrix = matrix_table(transition$matrix),
    transition_audit = transition$audit,
    state_values_usd_million = data.frame(
      issuer_id = rownames(valuation$state_values), valuation$state_values,
      row.names = NULL, check.names = FALSE
    ),
    conditional_valuations = valuation$conditional,
    issuer_summary = valuation$issuer_summary,
    portfolio_summary = valuation$portfolio_summary, sensitivity = sensitivity,
    curve = aligned$curve, rating_spreads = aligned$spreads,
    issuer_registry = registry, assumptions = assumptions,
    metadata = metadata, provenance = provenance
  )
  for (name in names(tables)) {
    readr::write_csv(tables[[name]],
                     file.path(snapshot_dir, paste0(name, ".csv")))
  }
  inputs <- list(
    registry = registry, curve = aligned$curve, spreads = aligned$spreads,
    transition = transition$matrix, published = published,
    assumptions = assumptions, descriptor = descriptor,
    metadata = metadata, provenance = provenance
  )
  saveRDS(inputs, file.path(snapshot_dir, "model_inputs.rds"), version = 3)
  completed <- TRUE
  message("Common Treasury/OAS observation: ", aligned$market_date,
          "; requested cutoff: ", as_of_date,
          ". Monetary outputs are USD millions.")
  c(valuation, list(sensitivity = sensitivity, metadata = metadata,
                     inputs = inputs, snapshot_dir = snapshot_dir))
}
